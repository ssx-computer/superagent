//
//  IAGLLM.m
//  iAgent
//

#import "IAGLLM.h"
#import "IAGConfig.h"
#import "IAGJSON.h"
#import "IAGLog.h"
#import "IAGPaths.h"

#pragma mark - tool call

// 注意：IAGToolCall 的属性在公共头文件里已经是可读写的，这里不能再"重新声明"
// （类扩展里重复声明只允许在 primary 是 readonly、扩展是 readwrite 时使用）。
@implementation IAGToolCall

- (NSDictionary *)parsedArguments
{
    if (self.arguments.length == 0) return @{};
    id parsed = IAGJSONDecodeString(self.arguments, NULL);
    if ([parsed isKindOfClass:[NSDictionary class]]) return parsed;
    // A few models double-encode the arguments object as a JSON string.
    if ([parsed isKindOfClass:[NSString class]]) {
        id again = IAGJSONDecodeString(parsed, NULL);
        if ([again isKindOfClass:[NSDictionary class]]) return again;
    }
    return nil;
}

- (NSDictionary *)asOpenAIMessageToolCall
{
    return @{
        @"id": self.callId ?: @"",
        @"type": @"function",
        @"function": @{
            @"name": self.name ?: @"",
            @"arguments": self.arguments.length ? self.arguments : @"{}",
        },
    };
}

@end

#pragma mark - result

@implementation IAGLLMResult
- (instancetype)init
{
    self = [super init];
    if (self) _toolCalls = @[];
    return self;
}
@end

#pragma mark - streaming session

@interface IAGLLMStreamSession : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableData *lineBuffer;
@property (nonatomic, strong) NSMutableString *content;
@property (nonatomic, strong) NSMutableString *reasoning;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, IAGToolCall *> *toolCallsByIndex;
@property (nonatomic, copy)   NSString *finishReason;
@property (nonatomic, strong) NSDictionary *usage;
@property (nonatomic, strong) NSMutableData *rawBody;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong) NSError *transportError;
@property (nonatomic, assign) BOOL streaming;
@property (nonatomic, assign) BOOL sawDone;
@property (nonatomic, copy)   NSString *model;
@property (nonatomic, copy)   IAGLLMDeltaBlock deltaBlock;
@property (nonatomic, copy)   IAGLLMToolCallBlock toolCallBlock;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, weak)   NSURLSessionTask *task;
- (void)emitToolCallEnds;
@end

@implementation IAGLLMStreamSession

- (instancetype)init
{
    self = [super init];
    if (self) {
        _lineBuffer = [NSMutableData data];
        _content = [NSMutableString string];
        _reasoning = [NSMutableString string];
        _toolCallsByIndex = [NSMutableDictionary dictionary];
        _rawBody = [NSMutableData data];
        _semaphore = dispatch_semaphore_create(0);
        _streaming = YES;
        _statusCode = 0;
    }
    return self;
}

#pragma mark URLSession delegate

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        self.statusCode = ((NSHTTPURLResponse *)response).statusCode;
    }
    if (self.statusCode != 200) {
        // Collect the error body instead of trying to parse it as SSE.
        self.streaming = NO;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    // 无论状态码都留一份原始 body（上限 1 MB）：端点可能不理会 stream:true，直接返回
    // 一整段 JSON，那时 SSE 解析器一个事件都收不到，只能靠原文兜底解析。
    if (self.rawBody.length < 1024 * 1024) [self.rawBody appendData:data];
    if (!self.streaming) return;
    [self consumeBytes:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (error) self.transportError = error;
    if (self.streaming && self.lineBuffer.length > 0) {
        NSString *tail = [[NSString alloc] initWithData:self.lineBuffer encoding:NSUTF8StringEncoding];
        if (tail.length) [self handleSSELine:[tail stringByTrimmingCharactersInSet:
                                              [NSCharacterSet newlineCharacterSet]]];
        [self.lineBuffer setLength:0];
    }
    dispatch_semaphore_signal(self.semaphore);
}

#pragma mark SSE parsing

- (void)consumeBytes:(NSData *)data
{
    [self.lineBuffer appendData:data];
    NSData *newline = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    for (;;) {
        NSRange range = [self.lineBuffer rangeOfData:newline options:0
                                               range:NSMakeRange(0, self.lineBuffer.length)];
        if (range.location == NSNotFound) break;
        NSData *lineData = [self.lineBuffer subdataWithRange:NSMakeRange(0, range.location)];
        [self.lineBuffer replaceBytesInRange:NSMakeRange(0, range.location + range.length)
                                   withBytes:NULL length:0];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (line == nil) continue;
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        [self handleSSELine:line];
    }
}

- (void)handleSSELine:(NSString *)line
{
    if (line.length == 0) return;
    if ([line hasPrefix:@":"]) return;                 // comment / keep-alive

    NSString *payload = nil;
    if ([line hasPrefix:@"data:"]) {
        payload = [[line substringFromIndex:5]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    } else if ([line hasPrefix:@"{"]) {
        // A few gateways forget the "data: " prefix.
        payload = line;
    }
    if (payload.length == 0) return;
    if ([payload isEqualToString:@"[DONE]"]) {
        self.sawDone = YES;
        return;
    }

    id object = IAGJSONDecodeString(payload, NULL);
    if (![object isKindOfClass:[NSDictionary class]]) return;

    if (!self.model) {
        NSString *model = IAGDictString(object, @"model", nil);
        if (model.length) self.model = model;
    }

    NSDictionary *usage = IAGDictDictionary(object, @"usage");
    if (usage.count) self.usage = usage;

    NSArray *choices = IAGDictArray(object, @"choices");
    NSDictionary *choice = choices.count ? choices.firstObject : nil;
    if (![choice isKindOfClass:[NSDictionary class]]) return;

    NSString *finishReason = IAGDictString(choice, @"finish_reason", nil);
    if (finishReason.length) self.finishReason = finishReason;

    NSDictionary *delta = IAGDictDictionary(choice, @"delta");
    if (!delta) delta = IAGDictDictionary(choice, @"message");
    if (!delta) return;

    NSString *contentDelta = IAGDictString(delta, @"content", nil);
    if (contentDelta.length) {
        [self.content appendString:contentDelta];
        if (self.deltaBlock) self.deltaBlock(@"content", contentDelta);
    }

    NSString *reasoningDelta = IAGDictStringAny(delta, @[ @"reasoning_content", @"reasoning" ], nil);
    if (reasoningDelta.length) {
        [self.reasoning appendString:reasoningDelta];
        if (self.deltaBlock) self.deltaBlock(@"reasoning", reasoningDelta);
    }

    NSArray *toolCalls = IAGDictArray(delta, @"tool_calls");
    for (NSDictionary *entry in toolCalls) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSInteger index = IAGDictInteger(entry, @"index", 0);
        NSNumber *key = @(index);

        IAGToolCall *call = self.toolCallsByIndex[key];
        BOOL isNew = NO;
        if (!call) {
            call = [[IAGToolCall alloc] init];
            call.index = index;
            call.arguments = @"";
            self.toolCallsByIndex[key] = call;
            isNew = YES;
        }

        NSString *identifier = IAGDictString(entry, @"id", nil);
        if (identifier.length) call.callId = identifier;

        NSDictionary *function = IAGDictDictionary(entry, @"function");
        if (function) {
            NSString *name = IAGDictString(function, @"name", nil);
            if (name.length) call.name = name;
            NSString *argumentChunk = IAGDictString(function, @"arguments", nil);
            if (argumentChunk.length) {
                call.arguments = [(call.arguments ?: @"") stringByAppendingString:argumentChunk];
            }
        }

        if (self.toolCallBlock) {
            if (isNew) self.toolCallBlock(@"start", call);
            self.toolCallBlock(@"delta", call);
        }
    }
}

- (void)emitToolCallEnds
{
    if (!self.toolCallBlock) return;
    NSArray<NSNumber *> *keys = [self.toolCallsByIndex.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *key in keys) {
        self.toolCallBlock(@"end", self.toolCallsByIndex[key]);
    }
}

- (NSArray<IAGToolCall *> *)orderedToolCalls
{
    NSArray<NSNumber *> *keys = [self.toolCallsByIndex.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<IAGToolCall *> *ordered = [NSMutableArray array];
    for (NSNumber *key in keys) {
        IAGToolCall *call = self.toolCallsByIndex[key];
        if (call.name.length == 0) continue;
        if (call.callId.length == 0) {
            call.callId = [NSString stringWithFormat:@"call_%ld_%lu",
                           (long)call.index, (unsigned long)([NSDate date].timeIntervalSince1970 * 1000) % 100000];
        }
        [ordered addObject:call];
    }
    return ordered;
}

@end

#pragma mark - client

@interface IAGLLM ()
@property (nonatomic, strong) IAGConfig *config;
@property (nonatomic, strong) NSURLSessionTask *currentTask;
@property (nonatomic, strong) NSURLSession *currentSession;
@property (nonatomic, assign) BOOL cancelled;
@end

@implementation IAGLLM

- (instancetype)initWithConfig:(IAGConfig *)config
{
    self = [super init];
    if (self) _config = config;
    return self;
}

- (void)cancel
{
    self.cancelled = YES;
    [self.currentTask cancel];
    [self.currentSession invalidateAndCancel];
    self.currentTask = nil;
    self.currentSession = nil;
}

- (BOOL)isCancelled { return self.cancelled; }

#pragma mark URL helpers

- (NSURL *)endpointURL
{
    NSString *base = [self.config baseURL];
    if (base.length == 0) base = @"https://api.openai.com/v1";

    if ([base hasSuffix:@"/chat/completions"]) return [NSURL URLWithString:base];

    NSURLComponents *components = [NSURLComponents componentsWithString:base];
    NSString *path = components.path ?: @"";
    if (path.length <= 1) {
        // Bare host: assume the conventional /v1 prefix.
        path = @"/v1/chat/completions";
    } else if ([path hasSuffix:@"/"]) {
        path = [path stringByAppendingString:@"chat/completions"];
    } else {
        path = [path stringByAppendingString:@"/chat/completions"];
    }
    components.path = path;
    return components.URL ?: [NSURL URLWithString:@"https://api.openai.com/v1/chat/completions"];
}

- (NSMutableURLRequest *)requestWithBody:(NSDictionary *)body
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self endpointURL]];
    request.HTTPMethod = @"POST";
    // 空闲超时：流式响应里这是"两个数据包之间"的上限。原来写 600 秒，
    // 结果是用户发消息后界面十分钟什么都不显示 —— 时间必须短到能当错误报出来。
    request.timeoutInterval = 60;
    [request setValue:@"application/json" forKey:@"Content-Type"];
    [request setValue:@"text/event-stream" forKey:@"Accept"];
    [request setValue:@"iAgent/1.0 (iOS)" forKey:@"User-Agent"];
    NSString *key = [self.config apiKey];
    if (key.length) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", key] forKey:@"Authorization"];
    }
    NSData *payload = IAGJSONEncode(body, NO);
    request.HTTPBody = payload;
    return request;
}

- (NSError *)errorWithMessage:(NSString *)message code:(NSInteger)code
{
    return [NSError errorWithDomain:@"iagent.llm" code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message ?: @"模型请求失败" }];
}

#pragma mark request execution

- (IAGLLMResult *)performRequestWithBody:(NSDictionary *)body
                            deltaHandler:(IAGLLMDeltaBlock)delta
                        toolCallHandler:(IAGLLMToolCallBlock)toolCall
                                   error:(NSError **)error
{
    NSMutableURLRequest *request = [self requestWithBody:body];

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 60;    // 空闲 60 秒即失败
    configuration.timeoutIntervalForResource = 300;  // 单次请求最长 5 分钟（长回答也够）
    configuration.HTTPShouldUsePipelining = NO;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    IAGLLMStreamSession *session = [[IAGLLMStreamSession alloc] init];
    session.deltaBlock = delta;
    session.toolCallBlock = toolCall;

    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;
    queue.name = @"iagent.llm.session";

    NSURLSession *urlSession = [NSURLSession sessionWithConfiguration:configuration
                                                            delegate:session
                                                       delegateQueue:queue];
    self.currentSession = urlSession;
    NSURLSessionDataTask *task = [urlSession dataTaskWithRequest:request];
    session.task = task;
    self.currentTask = task;

    NSTimeInterval started = [NSDate date].timeIntervalSince1970;
    [task resume];

    // Never block the agent loop forever, even if the network stack misbehaves.
    long waitResult = dispatch_semaphore_wait(session.semaphore,
                                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(320 * NSEC_PER_SEC)));
    if (waitResult != 0) {
        [task cancel];
        [urlSession invalidateAndCancel];
        self.currentTask = nil;
        self.currentSession = nil;
        if (error) {
            *error = [self errorWithMessage:[NSString stringWithFormat:
                @"模型请求超时（%ld 秒内没有完成）。地址 %@\n可能原因：base_url 不可达、被网络拦截、"
                @"或模型本身太慢。", (long)320, [self endpointURL].absoluteString]
                                       code:-1001];
        }
        return nil;
    }
    self.currentTask = nil;
    [urlSession finishTasksAndInvalidate];
    self.currentSession = nil;

    if (self.cancelled) {
        if (error) *error = [self errorWithMessage:@"已取消" code:-999];
        return nil;
    }

    NSInteger status = session.statusCode;

    if (status != 200) {
        NSString *bodyText = [[NSString alloc] initWithData:session.rawBody encoding:NSUTF8StringEncoding];
        bodyText = IAGTruncateString(bodyText ?: @"", 800);
        NSString *message;
        if (status == 401 || status == 403) {
            message = [NSString stringWithFormat:@"鉴权失败 (HTTP %ld)。请检查 API Key。\n%@",
                       (long)status, bodyText];
        } else if (status == 404) {
            message = [NSString stringWithFormat:@"接口不存在 (HTTP 404)。请检查 Base URL 是否为 %@\n%@",
                       [self endpointURL].absoluteString, bodyText];
        } else if (status == 429) {
            message = [NSString stringWithFormat:@"请求过于频繁或额度不足 (HTTP 429)。\n%@", bodyText];
        } else if (status == 0) {
            message = [NSString stringWithFormat:@"无法连接 %@\n%@ [%@ %ld]",
                       [self endpointURL].absoluteString,
                       session.transportError.localizedDescription ?: @"网络不可达",
                       session.transportError.domain ?: @"NSURLErrorDomain",
                       (long)session.transportError.code];
        } else {
            message = [NSString stringWithFormat:@"模型返回 HTTP %ld\n%@", (long)status, bodyText];
        }
        IAGLogError(@"模型请求失败: %@", message);
        if (error) *error = [self errorWithMessage:message code:status ?: 1];
        return nil;
    }

    if (session.transportError && session.content.length == 0 && session.toolCallsByIndex.count == 0) {
        NSString *message = [NSString stringWithFormat:@"连接中断: %@ [%@ %ld]",
                             session.transportError.localizedDescription ?: @"未知",
                             session.transportError.domain ?: @"NSURLErrorDomain",
                             (long)session.transportError.code];
        IAGLogError(@"%@", message);
        if (error) *error = [self errorWithMessage:message code:session.transportError.code];
        return nil;
    }

    // 兜底：有些自建/中转端点不理会 stream:true，直接返回一整段非流式 JSON。这种情况下
    // SSE 解析器收不到任何事件，用户看到的就是"发了消息毫无反应"。这里把原文按
    // OpenAI 非流式响应解析出来，并当作 delta 推给界面。
    if (session.content.length == 0 && session.toolCallsByIndex.count == 0 && session.rawBody.length > 0) {
        id json = IAGJSONDecode(session.rawBody, NULL);
        NSDictionary *choice = nil;
        if ([json isKindOfClass:[NSDictionary class]]) {
            NSArray *choices = json[@"choices"];
            if ([choices isKindOfClass:[NSArray class]] && choices.count > 0 &&
                [choices.firstObject isKindOfClass:[NSDictionary class]]) {
                choice = choices.firstObject;
            }
        }
        NSDictionary *msg = [choice[@"message"] isKindOfClass:[NSDictionary class]] ? choice[@"message"] : nil;
        NSString *reasonText = msg ? IAGDictStringAny(msg, @[ @"reasoning_content", @"reasoning" ], nil) : nil;
        NSString *text = msg ? IAGDictStringAny(msg, @[ @"content" ], nil) : nil;
        if (reasonText.length > 0 && delta) delta(@"reasoning", reasonText);
        if (text.length > 0) {
            [session.content appendString:text];
            if (delta) delta(@"content", text);
            IAGLogInfo(@"端点未按 SSE 返回，已按非流式响应解析出 %lu 字符",
                       (unsigned long)text.length);
        } else if (msg[@"tool_calls"]) {
            IAGLogWarn(@"端点未按 SSE 返回，且带 tool_calls —— 非流式工具调用暂不支持");
        } else {
            NSString *preview = IAGTruncateString([[NSString alloc] initWithData:session.rawBody
                                                                        encoding:NSUTF8StringEncoding] ?: @"", 200);
            IAGLogWarn(@"端点返回 200，但既没有 SSE 事件也没有可解析内容（%lu 字节）：%@",
                       (unsigned long)session.rawBody.length, preview);
        }
    }

    [session emitToolCallEnds];

    IAGLLMResult *result = [[IAGLLMResult alloc] init];
    result.content = session.content;
    result.reasoning = session.reasoning;
    result.finishReason = session.finishReason;
    result.toolCalls = [session orderedToolCalls];
    result.usage = session.usage;
    result.model = session.model;
    result.duration = [NSDate date].timeIntervalSince1970 - started;
    return result;
}

#pragma mark public API

- (IAGLLMResult *)chatWithMessages:(NSArray<NSDictionary *> *)messages
                             tools:(NSArray<NSDictionary *> *)tools
                      deltaHandler:(IAGLLMDeltaBlock)delta
                  toolCallHandler:(IAGLLMToolCallBlock)toolCall
                             error:(NSError **)error
{
    self.cancelled = NO;

    NSString *model = [self.config model];
    double temperature = [self.config doubleForKey:kIAGKeyTemperature fallback:0.3];
    NSInteger maxTokens = [self.config integerForKey:kIAGKeyMaxTokens fallback:2048];

    NSMutableDictionary *base = [NSMutableDictionary dictionary];
    base[@"model"] = model;
    base[@"messages"] = messages ?: @[];
    base[@"temperature"] = @(temperature);
    base[@"max_tokens"] = @(maxTokens);
    base[@"stream"] = @YES;
    if (tools.count) {
        base[@"tools"] = tools;
        base[@"tool_choice"] = @"auto";
    }

    // Provider quirks are real: retry with progressively fewer optional fields
    // instead of failing outright on a strict gateway.
    NSMutableArray<NSDictionary *> *variants = [NSMutableArray array];
    NSMutableDictionary *full = [base mutableCopy];
    full[@"stream_options"] = @{ @"include_usage": @YES };
    [variants addObject:full];
    [variants addObject:[base copy]];

    NSMutableDictionary *noToolChoice = [base mutableCopy];
    [noToolChoice removeObjectForKey:@"tool_choice"];
    [variants addObject:noToolChoice];

    NSMutableDictionary *nonStreaming = [noToolChoice mutableCopy];
    nonStreaming[@"stream"] = @NO;
    [variants addObject:nonStreaming];

    NSError *lastError = nil;
    for (NSUInteger attempt = 0; attempt < variants.count; attempt++) {
        if (self.cancelled) {
            if (error) *error = [self errorWithMessage:@"已取消" code:-999];
            return nil;
        }
        NSError *attemptError = nil;
        IAGLLMResult *result = [self performRequestWithBody:variants[attempt]
                                               deltaHandler:delta
                                           toolCallHandler:toolCall
                                                      error:&attemptError];
        if (result) {
            if (attempt > 0) {
                IAGLogWarn(@"模型请求在第 %lu 次尝试后成功", (unsigned long)(attempt + 1));
            }
            if ([self.config requestLogging]) {
                IAGLogInfo(@"模型响应: %lu 字符, %lu 个工具调用, %.2fs",
                           (unsigned long)result.content.length,
                           (unsigned long)result.toolCalls.count,
                           result.duration);
            }
            return result;
        }
        lastError = attemptError;
        if (self.cancelled) break;

        // Only retry for server-side complaints; auth/network errors are final.
        NSString *message = attemptError.localizedDescription ?: @"";
        BOOL retryable = [message containsString:@"HTTP 400"] ||
                         [message containsString:@"HTTP 422"] ||
                         [message containsString:@"HTTP 500"] ||
                         [message containsString:@"HTTP 502"] ||
                         [message containsString:@"HTTP 503"];
        if (!retryable) break;
        IAGLogWarn(@"模型请求失败，降级重试: %@", message);
    }

    if (error) {
        *error = lastError ?: [self errorWithMessage:@"模型请求失败" code:1];
    }
    return nil;
}

#pragma mark health probe

+ (void)probeConfiguration:(IAGConfig *)config completion:(void (^)(BOOL, NSString *))completion
{
    NSString *base = [config baseURL];
    if ([base hasSuffix:@"/chat/completions"]) {
        base = [base substringToIndex:base.length - @"/chat/completions".length];
    }
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    if (![base hasSuffix:@"/v1"] && ![base containsString:@"/v1"] && ![base containsString:@"/api"]) {
        base = [base stringByAppendingString:@"/v1"];
    }
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/models"]];

    if (!url || [config apiKey].length == 0) {
        if (completion) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                completion(NO, [config apiKey].length ? @"Base URL 无效" : @"尚未配置 API Key");
            });
        }
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 20;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", [config apiKey]] forKey:@"Authorization"];
    if ([config requestLogging]) IAGLogInfo(@"探测模型端点: %@", url.absoluteString);

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:request
                                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                if (completion) completion(NO, [NSString stringWithFormat:@"连接失败: %@", error.localizedDescription]);
                return;
            }
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (status == 200) {
                if (completion) completion(YES, @"连接正常");
                return;
            }
            NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (completion) {
                completion(NO, [NSString stringWithFormat:@"HTTP %ld %@", (long)status,
                                IAGTruncateString(body ?: @"", 200)]);
            }
        }];
    [task resume];
}

@end
