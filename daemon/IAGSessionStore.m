//
//  IAGSessionStore.m
//  iAgent
//

#import "IAGSessionStore.h"
#import "IAGPaths.h"
#import "IAGJSON.h"
#import "IAGUtil.h"
#import "IAGLog.h"

static const NSUInteger kIAGMaxMessagesPerSession = 400;

@implementation IAGSession

- (instancetype)init
{
    self = [super init];
    if (self) _messages = [NSMutableArray array];
    return self;
}

- (NSDictionary *)summaryJSON
{
    return @{
        @"id": self.sessionId ?: @"",
        @"title": self.title ?: @"",
        @"createdAt": @(self.createdAt),
        @"updatedAt": @(self.updatedAt),
        @"messageCount": @(self.messages.count),
    };
}

- (NSDictionary *)fullJSON
{
    NSMutableDictionary *json = [[self summaryJSON] mutableCopy];
    json[@"messages"] = self.messages ?: @[];
    return json;
}

@end

#pragma mark -

@implementation IAGSessionStore {
    NSMutableDictionary<NSString *, IAGSession *> *_sessions;
    NSLock *_lock;
    NSUInteger _counter;
}

+ (instancetype)shared
{
    static IAGSessionStore *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IAGSessionStore alloc] init]; });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _sessions = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
        [self loadAll];
    }
    return self;
}

#pragma mark disk

- (void)loadAll
{
    IAGEnsureDirectory(IAGSessionsDir());
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray<NSString *> *files = [manager contentsOfDirectoryAtPath:IAGSessionsDir() error:NULL];
    NSUInteger counter = 0;

    for (NSString *file in files) {
        if (![file hasSuffix:@".json"]) continue;
        NSString *path = [IAGSessionsDir() stringByAppendingPathComponent:file];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length == 0) continue;
        NSDictionary *json = IAGJSONDecode(data, NULL);
        if (![json isKindOfClass:[NSDictionary class]]) continue;

        IAGSession *session = [[IAGSession alloc] init];
        session.sessionId = IAGDictString(json, @"id", file.stringByDeletingPathExtension);
        session.title = IAGDictString(json, @"title", @"未命名会话");
        session.createdAt = IAGDictDouble(json, @"createdAt", 0);
        session.updatedAt = IAGDictDouble(json, @"updatedAt", session.createdAt);
        NSArray *messages = IAGDictArray(json, @"messages");
        for (NSDictionary *message in messages) {
            if ([message isKindOfClass:[NSDictionary class]]) [session.messages addObject:message];
        }

        NSString *suffix = [[session.sessionId componentsSeparatedByString:@"-"] lastObject];
        NSUInteger numeric = (NSUInteger)suffix.integerValue;
        if (numeric > counter) counter = numeric;

        _sessions[session.sessionId] = session;
    }

    _counter = counter;
    if (_sessions.count) {
        IAGLogInfo(@"已加载 %lu 个会话", (unsigned long)_sessions.count);
    }
}

- (void)saveSession:(IAGSession *)session
{
    if (!session.sessionId.length) return;
    IAGEnsureDirectory(IAGSessionsDir());
    NSData *data = IAGJSONEncode([session fullJSON], NO);
    if (!data) return;
    @try {
        [data writeToFile:IAGSessionPath(session.sessionId) atomically:YES];
    } @catch (NSException *exception) {
        IAGLogError(@"会话写入失败 %@: %@", session.sessionId, exception.reason);
    }
}

#pragma mark queries

- (NSArray<IAGSession *> *)sessions
{
    [_lock lock];
    NSArray *all = _sessions.allValues;
    [_lock unlock];
    return [all sortedArrayUsingComparator:^NSComparisonResult(IAGSession *a, IAGSession *b) {
        if (a.updatedAt > b.updatedAt) return NSOrderedAscending;
        if (a.updatedAt < b.updatedAt) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

- (IAGSession *)sessionWithIdentifier:(NSString *)sessionId
{
    if (sessionId.length == 0) return nil;
    [_lock lock];
    IAGSession *session = _sessions[sessionId];
    [_lock unlock];
    return session;
}

- (NSUInteger)sessionCount
{
    [_lock lock];
    NSUInteger count = _sessions.count;
    [_lock unlock];
    return count;
}

#pragma mark mutations

- (IAGSession *)createSessionWithTitle:(NSString *)title
{
    IAGSession *session = [[IAGSession alloc] init];
    [_lock lock];
    _counter++;
    session.sessionId = [NSString stringWithFormat:@"s-%lu-%ld",
                         (unsigned long)_counter, (long)[NSDate date].timeIntervalSince1970];
    session.createdAt = [NSDate date].timeIntervalSince1970;
    session.updatedAt = session.createdAt;
    session.title = title.length ? title : @"新会话";
    _sessions[session.sessionId] = session;
    [_lock unlock];

    [self saveSession:session];
    return session;
}

- (BOOL)deleteSession:(NSString *)sessionId
{
    if (sessionId.length == 0) return NO;
    [_lock lock];
    IAGSession *session = _sessions[sessionId];
    [_sessions removeObjectForKey:sessionId];
    [_lock unlock];
    if (!session) return NO;

    [[NSFileManager defaultManager] removeItemAtPath:IAGSessionPath(sessionId) error:NULL];
    IAGLogInfo(@"已删除会话 %@", sessionId);
    return YES;
}

- (BOOL)renameSession:(NSString *)sessionId title:(NSString *)title
{
    IAGSession *session = [self sessionWithIdentifier:sessionId];
    if (!session) return NO;
    session.title = title.length ? title : session.title;
    session.updatedAt = [NSDate date].timeIntervalSince1970;
    [self saveSession:session];
    return YES;
}

- (void)appendMessage:(NSDictionary *)message toSession:(NSString *)sessionId
{
    if (![message isKindOfClass:[NSDictionary class]]) return;
    IAGSession *session = [self sessionWithIdentifier:sessionId];
    if (!session) return;

    NSMutableDictionary *stored = [message mutableCopy];
    if (stored[@"createdAt"] == nil) stored[@"createdAt"] = @([NSDate date].timeIntervalSince1970);

    [_lock lock];
    [session.messages addObject:stored];
    if (session.messages.count > kIAGMaxMessagesPerSession) {
        NSUInteger drop = session.messages.count - kIAGMaxMessagesPerSession;
        [session.messages removeObjectsInRange:NSMakeRange(0, drop)];
    }
    session.updatedAt = [NSDate date].timeIntervalSince1970;

    // Auto-title from the first user message.
    if ([IAGDictString(stored, @"role", @"") isEqualToString:@"user"] &&
        ([session.title isEqualToString:@"新会话"] || session.title.length == 0)) {
        session.title = [self suggestTitleFromMessage:IAGDictString(stored, @"content", @"")];
    }
    NSDictionary *snapshot = [session fullJSON];
    [_lock unlock];

    NSData *data = IAGJSONEncode(snapshot, NO);
    if (data) [data writeToFile:IAGSessionPath(sessionId) atomically:YES];
}

- (NSString *)suggestTitleFromMessage:(NSString *)message
{
    NSString *collapsed = IAGCollapseWhitespace(message ?: @"");
    if (collapsed.length == 0) return @"新会话";
    if (collapsed.length <= 24) return collapsed;
    return [[collapsed substringToIndex:24] stringByAppendingString:@"…"];
}

#pragma mark model view

- (NSArray<NSDictionary *> *)modelMessagesForSession:(IAGSession *)session limit:(NSInteger)limit
{
    if (!session) return @[];
    [_lock lock];
    NSArray<NSDictionary *> *messages = [session.messages copy];
    [_lock unlock];

    NSMutableArray<NSDictionary *> *model = [NSMutableArray array];
    NSInteger start = 0;
    if (limit > 0 && (NSInteger)messages.count > limit) {
        start = (NSInteger)messages.count - limit;
        // Never start the window on a tool result whose assistant call was cut off.
        while (start < (NSInteger)messages.count &&
               [IAGDictString(messages[start], @"role", @"") isEqualToString:@"tool"]) {
            start++;
        }
    }

    for (NSInteger i = start; i < (NSInteger)messages.count; i++) {
        NSDictionary *message = messages[i];
        NSString *role = IAGDictString(message, @"role", @"");
        if (role.length == 0) continue;

        NSMutableDictionary *clean = [NSMutableDictionary dictionary];
        clean[@"role"] = role;
        NSString *content = IAGDictString(message, @"content", @"");
        if ([role isEqualToString:@"assistant"]) {
            NSArray *toolCalls = IAGDictArray(message, @"toolCalls");
            if (toolCalls.count) {
                clean[@"tool_calls"] = toolCalls;
                // Some gateways reject a null content next to tool_calls.
                clean[@"content"] = content.length ? content : @"";
            } else {
                clean[@"content"] = content;
            }
        } else if ([role isEqualToString:@"tool"]) {
            clean[@"tool_call_id"] = IAGDictString(message, @"toolCallId", @"");
            clean[@"content"] = content;
            NSString *name = IAGDictString(message, @"name", @"");
            if (name.length) clean[@"name"] = name;
        } else {
            clean[@"content"] = content;
        }
        [model addObject:clean];
    }
    return model;
}

@end
