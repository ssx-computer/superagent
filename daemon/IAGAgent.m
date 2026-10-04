//
//  IAGAgent.m
//  iAgent
//

#import "IAGAgent.h"
#import "IAGConfig.h"
#import "IAGLLM.h"
#import "IAGSessionStore.h"
#import "IAGTool.h"
#import "IAGBridge.h"
#import "IAGJSON.h"
#import "IAGUtil.h"
#import "IAGLog.h"

static const NSUInteger kIAGToolOutputLimit = 16000;

#pragma mark - approval center

@implementation IAGApprovalCenter {
    NSMutableDictionary<NSString *, NSNumber *> *_decisions;   // id -> @(BOOL) once decided
    NSMutableSet<NSString *> *_pending;
    NSCondition *_condition;
}

+ (instancetype)shared
{
    static IAGApprovalCenter *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IAGApprovalCenter alloc] init]; });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _decisions = [NSMutableDictionary dictionary];
        _pending = [NSMutableSet set];
        _condition = [[NSCondition alloc] init];
    }
    return self;
}

- (BOOL)requestApprovalForIdentifier:(NSString *)identifier timeout:(NSTimeInterval)timeout
{
    if (identifier.length == 0) return NO;
    if (timeout <= 0) timeout = 180;

    [_condition lock];
    [_pending addObject:identifier];
    [_decisions removeObjectForKey:identifier];
    [_condition unlock];

    NSTimeInterval deadline = [NSDate date].timeIntervalSince1970 + timeout;
    BOOL allowed = NO;

    [_condition lock];
    while (1) {
        NSNumber *decision = _decisions[identifier];
        if (decision) {
            allowed = decision.boolValue;
            break;
        }
        NSTimeInterval remaining = deadline - [NSDate date].timeIntervalSince1970;
        if (remaining <= 0) break;
        [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(remaining, 2.0)]];
    }
    [_pending removeObject:identifier];
    [_decisions removeObjectForKey:identifier];
    [_condition unlock];

    IAGLogInfo(@"审批 %@: %@", identifier, allowed ? @"允许" : @"拒绝/超时");
    return allowed;
}

- (BOOL)resolveApprovalForIdentifier:(NSString *)identifier allow:(BOOL)allow
{
    if (identifier.length == 0) return NO;
    [_condition lock];
    BOOL wasPending = [_pending containsObject:identifier];
    if (wasPending) _decisions[identifier] = @(allow);
    [_condition broadcast];
    [_condition unlock];
    return wasPending;
}

- (NSUInteger)pendingCount
{
    [_condition lock];
    NSUInteger count = _pending.count;
    [_condition unlock];
    return count;
}

- (void)cancelAll
{
    [_condition lock];
    for (NSString *identifier in _pending) _decisions[identifier] = @NO;
    [_condition broadcast];
    [_condition unlock];
}

@end

#pragma mark - agent

@implementation IAGAgent {
    NSMutableDictionary<NSString *, IAGLLM *> *_runs;
    NSMutableSet<NSString *> *_aborted;
    NSLock *_lock;
    NSUInteger _runCounter;
}

+ (instancetype)shared
{
    static IAGAgent *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IAGAgent alloc] init]; });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _runs = [NSMutableDictionary dictionary];
        _aborted = [NSMutableSet set];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

#pragma mark run registry

- (void)registerRun:(IAGLLM *)llm forSession:(NSString *)sessionId
{
    [_lock lock];
    _runs[sessionId] = llm;
    [_aborted removeObject:sessionId];
    [_lock unlock];
}

- (void)unregisterRunForSession:(NSString *)sessionId
{
    [_lock lock];
    [_runs removeObjectForKey:sessionId];
    [_lock unlock];
}

- (BOOL)isAborted:(NSString *)sessionId
{
    [_lock lock];
    BOOL aborted = [_aborted containsObject:sessionId];
    [_lock unlock];
    return aborted;
}

- (void)abortSession:(NSString *)sessionId
{
    if (sessionId.length == 0) return;
    [_lock lock];
    [_aborted addObject:sessionId];
    IAGLLM *llm = _runs[sessionId];
    [_lock unlock];
    [llm cancel];
    IAGLogInfo(@"已请求中止会话 %@ 的运行", sessionId);
}

- (BOOL)isRunningSession:(NSString *)sessionId
{
    [_lock lock];
    BOOL running = _runs[sessionId] != nil;
    [_lock unlock];
    return running;
}

- (NSArray<NSString *> *)runningSessions
{
    [_lock lock];
    NSArray *keys = _runs.allKeys;
    [_lock unlock];
    return keys;
}

#pragma mark loop

- (NSArray<NSDictionary *> *)messagesForSession:(IAGSession *)session config:(IAGConfig *)config
{
    NSMutableArray<NSDictionary *> *messages = [NSMutableArray array];
    [messages addObject:@{ @"role": @"system", @"content": [config effectiveSystemPrompt] }];
    [messages addObjectsFromArray:[[IAGSessionStore shared] modelMessagesForSession:session
                                                                             limit:[config historyLimit]]];
    return messages;
}

- (void)runSession:(NSString *)sessionId
           message:(NSString *)message
      eventHandler:(IAGAgentEventBlock)eventHandler
{
    void (^emit)(NSString *, NSDictionary *) = ^(NSString *event, NSDictionary *payload) {
        if (eventHandler) eventHandler(event, payload ?: @{});
    };

    IAGConfig *config = [IAGConfig shared];
    IAGSessionStore *store = [IAGSessionStore shared];
    IAGSession *session = [store sessionWithIdentifier:sessionId];
    if (!session) {
        emit(@"error", @{ @"message": @"会话不存在" });
        return;
    }
    if ([config apiKey].length == 0) {
        emit(@"error", @{ @"message": @"尚未配置 API Key，请打开设置页填写模型接口信息" });
        return;
    }

    // Persist the user's turn first so history always contains it.
    if (message.length) {
        [store appendMessage:@{ @"role": @"user", @"content": message } toSession:sessionId];
    }

    IAGLLM *llm = [[IAGLLM alloc] initWithConfig:config];
    [self registerRun:llm forSession:sessionId];

    IAGToolRegistry *registry = [IAGToolRegistry shared];
    IAGToolContext *context = [IAGToolContext contextWithConfig:config
                                                      sessionId:sessionId
                                                         bridge:[IAGBridge shared]];

    NSInteger promptTokens = 0, completionTokens = 0, totalTokens = 0;
    NSInteger steps = 0, toolCallCount = 0;
    NSString *finalContent = @"";
    BOOL aborted = NO;

    @try {
        for (steps = 1; steps <= MAX(1, [config maxSteps]); steps++) {
            if ([self isAborted:sessionId]) { aborted = YES; break; }

            NSArray<NSDictionary *> *messages = [self messagesForSession:session
                                                                  config:config];
            NSArray<NSDictionary *> *tools = [registry openAIToolDefinitionsWithConfig:config];

            if ([config requestLogging]) {
                IAGLogInfo(@"第 %ld 步：发送 %lu 条消息 / %lu 个工具",
                           (long)steps, (unsigned long)messages.count, (unsigned long)tools.count);
            }

            NSError *error = nil;
            IAGLLMResult *result = [llm chatWithMessages:messages
                                                   tools:tools
                                            deltaHandler:^(NSString *kind, NSString *text) {
                emit([kind isEqualToString:@"reasoning"] ? @"reason" : @"delta", @{ @"text": text ?: @"" });
            }
                                        toolCallHandler:^(NSString *phase, IAGToolCall *call) {
                if ([phase isEqualToString:@"start"]) {
                    emit(@"tool_call", @{
                        @"id": call.callId ?: @"",
                        @"name": call.name ?: @"",
                        @"arguments": [call parsedArguments] ?: @{},
                    });
                }
            }
                                                   error:&error];

            if (!result) {
                if ([self isAborted:sessionId]) { aborted = YES; break; }
                emit(@"error", @{ @"message": error.localizedDescription ?: @"模型请求失败" });
                break;
            }

            NSDictionary *usage = result.usage;
            if (usage.count) {
                promptTokens += IAGDictInteger(usage, @"prompt_tokens", 0);
                completionTokens += IAGDictInteger(usage, @"completion_tokens", 0);
                totalTokens += IAGDictInteger(usage, @"total_tokens", 0);
            }

            finalContent = result.content ?: @"";

            if (result.toolCalls.count == 0) {
                NSMutableDictionary *assistant = [NSMutableDictionary dictionary];
                assistant[@"role"] = @"assistant";
                assistant[@"content"] = finalContent;
                if (result.reasoning.length) assistant[@"reasoning"] = result.reasoning;
                [store appendMessage:assistant toSession:sessionId];
                break;
            }

            // Record the assistant turn that requested the tools.
            NSMutableArray *toolCallsJSON = [NSMutableArray array];
            for (IAGToolCall *call in result.toolCalls) [toolCallsJSON addObject:[call asOpenAIMessageToolCall]];
            NSMutableDictionary *assistant = [NSMutableDictionary dictionary];
            assistant[@"role"] = @"assistant";
            assistant[@"content"] = finalContent;
            assistant[@"toolCalls"] = toolCallsJSON;
            if (result.reasoning.length) assistant[@"reasoning"] = result.reasoning;
            [store appendMessage:assistant toSession:sessionId];

            for (IAGToolCall *call in result.toolCalls) {
                if ([self isAborted:sessionId]) { aborted = YES; break; }
                toolCallCount++;

                NSString *name = call.name ?: @"";
                NSDictionary *arguments = [call parsedArguments];
                NSDictionary *toolResult = nil;

                if (arguments == nil) {
                    toolResult = IAGToolFailure([NSString stringWithFormat:
                        @"参数不是合法 JSON，原始内容: %@", IAGTruncateString(call.arguments ?: @"", 400)]);
                } else if (![registry toolExists:name]) {
                    toolResult = IAGToolFailure([NSString stringWithFormat:@"不存在名为 %@ 的工具", name]);
                } else {
                    NSString *blocked = [registry blockedReasonForTool:name arguments:arguments config:config];
                    if (blocked.length) {
                        toolResult = IAGToolFailure(blocked);
                        IAGLogWarn(@"工具 %@ 被黑名单拦截: %@", name, blocked);
                    } else {
                        NSString *reason = [registry approvalReasonForTool:name
                                                                 arguments:arguments
                                                                    config:config];
                        BOOL allowed = YES;
                        if (reason.length) {
                            emit(@"approval_required", @{
                                @"id": call.callId ?: @"",
                                @"name": name,
                                @"arguments": arguments,
                                @"reason": reason,
                            });
                            allowed = [[IAGApprovalCenter shared] requestApprovalForIdentifier:call.callId
                                                                                       timeout:300];
                        }
                        if (!allowed) {
                            toolResult = IAGToolFailure(@"用户拒绝执行该操作（或确认超时），请换一种方式或询问用户");
                        } else {
                            toolResult = [registry executeTool:name arguments:arguments context:context];
                        }
                    }
                }

                BOOL ok = [toolResult[@"ok"] boolValue];
                NSString *output = IAGStringOrEmpty(toolResult[@"output"]);
                NSString *errorText = IAGStringOrEmpty(toolResult[@"error"]);

                NSMutableDictionary *eventPayload = [NSMutableDictionary dictionary];
                eventPayload[@"id"] = call.callId ?: @"";
                eventPayload[@"name"] = name;
                eventPayload[@"ok"] = @(ok);
                eventPayload[@"output"] = output;
                if (errorText.length) eventPayload[@"error"] = errorText;
                if (toolResult[@"durationMs"]) eventPayload[@"durationMs"] = toolResult[@"durationMs"];
                if (toolResult[@"exitCode"]) eventPayload[@"exitCode"] = toolResult[@"exitCode"];
                emit(@"tool_result", eventPayload);

                NSString *modelContent;
                if (ok) {
                    modelContent = IAGTruncateForModel(output, kIAGToolOutputLimit);
                } else {
                    modelContent = [NSString stringWithFormat:@"工具执行失败: %@",
                                    errorText.length ? errorText : @"未知错误"];
                }

                NSMutableDictionary *toolMessage = [NSMutableDictionary dictionary];
                toolMessage[@"role"] = @"tool";
                toolMessage[@"toolCallId"] = call.callId ?: @"";
                toolMessage[@"name"] = name;
                toolMessage[@"content"] = modelContent.length ? modelContent : @"(无输出)";
                [store appendMessage:toolMessage toSession:sessionId];
            }

            if (aborted) break;
        }
    } @finally {
        [self unregisterRunForSession:sessionId];
    }

    if (aborted) {
        emit(@"done", @{ @"messageId": sessionId, @"steps": @(steps),
                         @"aborted": @YES, @"usage": @{ @"total_tokens": @(totalTokens) } });
        IAGLogInfo(@"会话 %@ 的运行已被用户中止", sessionId);
        return;
    }

    if (steps > MAX(1, [config maxSteps])) {
        NSString *note = [NSString stringWithFormat:@"（已达到最大步数 %ld，任务可能未完成）",
                          (long)[config maxSteps]];
        finalContent = [finalContent stringByAppendingFormat:@"\n\n%@", note];
        emit(@"delta", @{ @"text": [@"\n\n" stringByAppendingString:note] });
        [store appendMessage:@{ @"role": @"assistant", @"content": note } toSession:sessionId];
    }

    NSMutableDictionary *usageJSON = [NSMutableDictionary dictionary];
    usageJSON[@"prompt_tokens"] = @(promptTokens);
    usageJSON[@"completion_tokens"] = @(completionTokens);
    usageJSON[@"total_tokens"] = @(totalTokens);

    emit(@"done", @{
        @"messageId": sessionId,
        @"steps": @(MAX(0, steps - 1)),
        @"toolCalls": @(toolCallCount),
        @"contentLength": @(finalContent.length),
        @"usage": usageJSON,
    });

    if ([config requestLogging]) {
        IAGLogInfo(@"会话 %@ 完成: %ld 步, %ld 次工具调用, %ld tokens",
                   sessionId, (long)(steps - 1), (long)toolCallCount, (long)totalTokens);
    }
}

@end
