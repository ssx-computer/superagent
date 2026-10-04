//
//  IAGBridge.m
//  iAgent
//

#import "IAGBridge.h"
#import "IAGJSON.h"
#import "IAGLog.h"
#import "IAGUtil.h"

/// Small local helper so this file does not need the tool header.
static NSDictionary *IAGToolFailureHelper(NSString *message)
{
    return @{ @"ok": @NO, @"error": message ?: @"bridge 调用失败", @"output": @"" };
}

static const NSTimeInterval kIAGCommandRetention = 300;   // seconds
static const NSTimeInterval kIAGConnectedWindow  = 20;

@interface IAGBridgeCommand ()
@property (nonatomic, copy, readwrite)   NSString *commandId;
@property (nonatomic, copy, readwrite)   NSString *action;
@property (nonatomic, strong, readwrite) NSDictionary *parameters;
@property (nonatomic, assign)            NSUInteger sequence;
@end

@implementation IAGBridgeCommand
@end

@implementation IAGBridge {
    NSMutableArray<IAGBridgeCommand *> *_commands;
    NSMutableDictionary<NSString *, IAGBridgeCommand *> *_byId;
    NSCondition *_condition;
    NSUInteger _sequence;
    NSTimeInterval _lastPollAt;
    NSDictionary *_capabilities;
    NSUInteger _completedCount;
    NSUInteger _failedCount;
}

+ (instancetype)shared
{
    static IAGBridge *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IAGBridge alloc] init]; });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _commands = [NSMutableArray array];
        _byId = [NSMutableDictionary dictionary];
        _condition = [[NSCondition alloc] init];
        _sequence = 0;
        _lastPollAt = 0;
        _capabilities = @{};
    }
    return self;
}

#pragma mark - daemon side

- (NSDictionary *)performAction:(NSString *)action
                     parameters:(NSDictionary *)parameters
                        timeout:(NSTimeInterval)timeout
{
    if (action.length == 0) return IAGToolFailureHelper(@"缺少动作名称");

    IAGBridgeCommand *command = [[IAGBridgeCommand alloc] init];
    command.commandId = [[NSUUID UUID].UUIDString lowercaseString];
    command.action = action;
    command.parameters = parameters ?: @{};
    command.createdAt = [NSDate date].timeIntervalSince1970;

    [_condition lock];
    if (![self connectedLocked]) {
        [_condition unlock];
        return IAGToolFailureHelper(@"SpringBoard 桥接未连接：请确认 iAgent 的 SpringBoard 插件已加载（重新注销或重启后生效）");
    }
    _sequence++;
    command.sequence = _sequence;
    [_commands addObject:command];
    _byId[command.commandId] = command;
    [_condition broadcast];
    [_condition unlock];

    if (timeout <= 0) timeout = 10;

    NSTimeInterval deadline = [NSDate date].timeIntervalSince1970 + timeout;
    [_condition lock];
    while (command.result == nil) {
        NSTimeInterval remaining = deadline - [NSDate date].timeIntervalSince1970;
        if (remaining <= 0) break;
        [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:remaining]];
    }
    NSDictionary *result = command.result;
    [_condition unlock];

    if (result) return result;

    [self discardCommand:command.commandId];
    return IAGToolFailureHelper([NSString stringWithFormat:@"SpringBoard 未在 %.0f 秒内响应动作 %@", timeout, action]);
}

- (void)discardCommand:(NSString *)commandId
{
    [_condition lock];
    IAGBridgeCommand *command = _byId[commandId];
    command.result = IAGToolFailureHelper(@"已放弃等待");
    [_byId removeObjectForKey:commandId];
    [_commands removeObject:command];
    [_condition broadcast];
    [_condition unlock];
}

#pragma mark - tweak side

- (NSDictionary *)pollSince:(NSUInteger)cursor wait:(NSTimeInterval)wait
{
    if (wait < 0) wait = 0;
    if (wait > 25) wait = 25;

    NSTimeInterval deadline = [NSDate date].timeIntervalSince1970 + wait;

    [_condition lock];
    _lastPollAt = [NSDate date].timeIntervalSince1970;
    NSArray<IAGBridgeCommand *> *ready = [self readyCommandsSince:cursor locked:YES];

    if (ready.count == 0 && wait > 0) {
        NSTimeInterval remaining = deadline - [NSDate date].timeIntervalSince1970;
        if (remaining > 0) {
            [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:remaining]];
        }
        ready = [self readyCommandsSince:cursor locked:YES];
    }

    NSMutableArray *payload = [NSMutableArray array];
    for (IAGBridgeCommand *command in ready) {
        command.delivered = YES;
        [payload addObject:@{
            @"id": command.commandId,
            @"action": command.action,
            @"parameters": command.parameters,
        }];
    }
    NSUInteger returnedCursor = _sequence;
    [self pruneLocked];
    [_condition unlock];

    return @{ @"commands": payload, @"cursor": @(returnedCursor) };
}

- (NSArray<IAGBridgeCommand *> *)readyCommandsSince:(NSUInteger)cursor locked:(BOOL)locked
{
    (void)locked;   // 调用方已持锁，这里只是把约定写进签名
    NSMutableArray *ready = [NSMutableArray array];
    for (IAGBridgeCommand *command in _commands) {
        if (command.delivered) continue;
        if (command.result != nil) continue;
        if (command.sequence <= cursor) continue;
        [ready addObject:command];
    }
    [ready sortUsingComparator:^NSComparisonResult(IAGBridgeCommand *a, IAGBridgeCommand *b) {
        if (a.sequence < b.sequence) return NSOrderedAscending;
        if (a.sequence > b.sequence) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return ready;
}

- (BOOL)submitResult:(NSDictionary *)result
{
    NSString *commandId = IAGDictString(result, @"id", nil);
    if (commandId.length == 0) return NO;

    [_condition lock];
    IAGBridgeCommand *command = _byId[commandId];
    if (!command) {
        [_condition unlock];
        return NO;   // late or duplicate result
    }

    BOOL ok = IAGDictBool(result, @"ok", NO);
    NSString *output = IAGDictString(result, @"output", @"");
    NSString *error = IAGDictString(result, @"error", @"");
    command.result = ok ? @{ @"ok": @YES, @"output": output ?: @"" }
                        : @{ @"ok": @NO, @"error": error.length ? error : @"SpringBoard 执行失败",
                             @"output": output ?: @"" };
    if (ok) _completedCount++; else _failedCount++;
    [_byId removeObjectForKey:commandId];
    [_condition broadcast];
    [_condition unlock];

    if (!ok) IAGLogWarn(@"桥接动作失败 %@: %@", command.action, error);
    return YES;
}

- (void)noteCapabilities:(NSDictionary *)capabilities
{
    if (![capabilities isKindOfClass:[NSDictionary class]]) return;
    [_condition lock];
    _capabilities = [capabilities copy];
    _lastPollAt = [NSDate date].timeIntervalSince1970;
    [_condition unlock];
}

- (NSDictionary *)capabilities
{
    [_condition lock];
    NSDictionary *copy = _capabilities;
    [_condition unlock];
    return copy;
}

#pragma mark - status

- (BOOL)connected
{
    [_condition lock];
    BOOL value = [self connectedLocked];
    [_condition unlock];
    return value;
}

- (BOOL)connectedLocked
{
    if (_lastPollAt <= 0) return NO;
    return ([NSDate date].timeIntervalSince1970 - _lastPollAt) < kIAGConnectedWindow;
}

- (NSDictionary *)statusJSON
{
    [_condition lock];
    NSInteger pending = 0;
    for (IAGBridgeCommand *command in _commands) {
        if (command.result == nil) pending++;
    }
    NSDictionary *json = @{
        @"connected": @([self connectedLocked]),
        @"lastSeen": @(_lastPollAt),
        @"pending": @(pending),
        @"completed": @(_completedCount),
        @"failed": @(_failedCount),
        @"capabilities": _capabilities ?: @{},
    };
    [_condition unlock];
    return json;
}

- (void)pruneLocked
{
    NSTimeInterval cutoff = [NSDate date].timeIntervalSince1970 - kIAGCommandRetention;
    NSMutableArray *keep = [NSMutableArray array];
    for (IAGBridgeCommand *command in _commands) {
        if (command.result == nil || command.createdAt > cutoff) {
            [keep addObject:command];
        }
    }
    if (keep.count != _commands.count) {
        [_commands setArray:keep];
    }
}

- (void)cancelAll
{
    [_condition lock];
    for (IAGBridgeCommand *command in _commands) {
        if (command.result == nil) command.result = IAGToolFailureHelper(@"daemon 正在退出");
    }
    [_byId removeAllObjects];
    [_condition broadcast];
    [_condition unlock];
}

@end
