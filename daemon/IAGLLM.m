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
/// 初始化时快照下来的 baseUrl：**只读**，保证多线程下请求构造不会读到被改写的值。
/// 模型体检会用一份"覆盖了 baseUrl"的临时 IAGConfig 创建实例，所以这里必须缓存。
@property (nonatomic, copy)   NSString *baseURL;
@property (nonatomic, strong) NSURLSessionTask *currentTask;
@property (nonatomic, strong) NSURLSession *currentSession;
@property (nonatomic, assign) BOOL cancelled;
@end

@implementation IAGLLM

- (instancetype)initWithConfig:(IAGConfig *)config
{
    self = [super init];
    if (self) {
        _config = config;
        _baseURL = [[config baseURL] copy];
    }
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

/// <baseURL> + /chat/completions 或 /models。baseURL 允许带 /v1、带子路径，也允许
/// 直接写成完整的 .../chat/completions。
+ (NSURL *)endpointURLForBase:(NSString *)base suffix:(NSString *)suffix
{
    if (base.length == 0) base = @"https://api.openai.com/v1";
    if (suffix.length == 0) suffix = @"chat/completions";

    if ([base hasSuffix:@"/chat/completions"]) {
        if ([suffix isEqualToString:@"chat/completions"]) return [NSURL URLWithString:base];
        base = [base substringToIndex:base.length - @"/chat/completions".length];
    }
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];

    NSURLComponents *components = [NSURLComponents componentsWithString:base];
    if (!components) return nil;

    NSString *path = components.path ?: @"";
    if (path.length <= 1) {
        // Bare host: assume the conventional /v1 prefix.
        path = [@"/v1/" stringByAppendingString:suffix];
    } else if ([path hasSuffix:@"/"]) {
        path = [path stringByAppendingString:suffix];
    } else {
        path = [path stringByAppendingFormat:@"/%@", suffix];
    }
    components.path = path;
    return components.URL;
}

- (NSMutableURLRequest *)requestWithBody:(NSDictionary *)body
{
    return [self requestWithBody:body baseURL:self.baseURL apiKey:[self.config apiKey]];
}

- (NSMutableURLRequest *)requestWithBody:(NSDictionary *)body
                                 baseURL:(NSString *)baseURL
                                  apiKey:(NSString *)apiKey
{
    NSURL *url = [IAGLLM endpointURLForBase:baseURL suffix:@"chat/completions"];
    if (!url) url = [NSURL URLWithString:@"https://api.openai.com/v1/chat/completions"];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    // 空闲超时：流式响应里这是"两个数据包之间"的上限。原来写 600 秒，
    // 结果是用户发消息后界面十分钟什么都不显示 —— 时间必须短到能当错误报出来。
    request.timeoutInterval = 60;
    [request setValue:@"application/json" forKey:@"Content-Type"];
    [request setValue:@"text/event-stream" forKey:@"Accept"];
    [request setValue:@"iAgent/1.0 (iOS)" forKey:@"User-Agent"];
    if (apiKey.length) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forKey:@"Authorization"];
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
    // 只用于错误文案：让用户看到"到底请求了哪个 URL"。
    NSString *endpoint = request.URL.absoluteString ?: self.baseURL ?: @"";

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
                @"或模型本身太慢。", (long)320, endpoint]
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
                       endpoint, bodyText];
        } else if (status == 429) {
            message = [NSString stringWithFormat:@"请求过于频繁或额度不足 (HTTP 429)。\n%@", bodyText];
        } else if (status == 0) {
            message = [NSString stringWithFormat:@"无法连接 %@\n%@ [%@ %ld]",
                       endpoint,
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
    result.statusCode = session.statusCode;
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
    NSMutableArray<NSString *> *variantLabels = [NSMutableArray array];
    NSMutableDictionary *full = [base mutableCopy];
    full[@"stream_options"] = @{ @"include_usage": @YES };
    [variants addObject:full];
    [variantLabels addObject:@"流式 + stream_options"];
    [variants addObject:[base copy]];
    [variantLabels addObject:@"流式"];

    NSMutableDictionary *noToolChoice = [base mutableCopy];
    [noToolChoice removeObjectForKey:@"tool_choice"];
    [variants addObject:noToolChoice];
    [variantLabels addObject:@"流式（不带 tool_choice）"];

    NSMutableDictionary *nonStreaming = [noToolChoice mutableCopy];
    nonStreaming[@"stream"] = @NO;
    [variants addObject:nonStreaming];
    [variantLabels addObject:@"非流式"];

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

        // 成功判定必须收紧：HTTP 200 但 content/toolCalls/reasoning 三者全空，说明这个
        // 组合没被端点接受（最典型的是"忽略 stream:true 又没有可解析内容"），必须继续
        // 尝试下一个变体（尤其是最后的非流式），否则用户拿到的是空回复。
        // 注意：performRequestWithBody: 里的非流式兜底解析会先把内容塞回 session.content，
        // 能救回来的请求在这里就是"有内容"，不会被误判成失败。
        BOOL emptySuccess = NO;
        if (result && result.content.length == 0 && result.toolCalls.count == 0 && result.reasoning.length == 0) {
            emptySuccess = YES;
            attemptError = [self errorWithMessage:
                @"端点返回 HTTP 200 但没有内容（可能不支持流式，或模型名/参数不被接受）" code:502];
            result = nil;
        }

        if (result) {
            if (attempt > 0) {
                IAGLogWarn(@"模型请求在第 %lu 次尝试后成功（%@）",
                           (unsigned long)(attempt + 1), variantLabels[attempt]);
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
        // "200 但没有内容"永远值得换下一个变体。
        NSString *message = attemptError.localizedDescription ?: @"";
        BOOL retryable = emptySuccess ||
                         [message containsString:@"HTTP 400"] ||
                         [message containsString:@"HTTP 422"] ||
                         [message containsString:@"HTTP 500"] ||
                         [message containsString:@"HTTP 502"] ||
                         [message containsString:@"HTTP 503"];
        if (!retryable) break;
        IAGLogWarn(@"模型请求失败（%@），降级重试: %@", variantLabels[attempt], message);
    }

    NSString *tried = [variantLabels componentsJoinedByString:@" → "];
    NSString *reason = lastError.localizedDescription ?: @"未知原因";
    IAGLogError(@"模型请求失败：已尝试 %lu 种组合（%@）；最后一次原因: %@",
                (unsigned long)variants.count, tried, reason);

    if (error) {
        *error = [self errorWithMessage:[NSString stringWithFormat:
            @"模型请求失败：已尝试 %lu 种组合（%@）。最后一次的原因: %@",
            (unsigned long)variants.count, tried, reason]
                                   code:lastError ? lastError.code : 502];
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

#pragma mark 模型体检（POST /api/model/check）

+ (NSArray<NSString *> *)modelIdentifiersFromData:(NSData *)data
{
    if (data.length == 0) return nil;
    id json = IAGJSONDecode(data, NULL);
    if (![json isKindOfClass:[NSDictionary class]]) return nil;

    NSArray *entries = IAGDictArray(json, @"data");
    if (![entries isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (id entry in entries) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        // 兼容两种写法：{"data":[{"id":"gpt-4o"}]} 与 {"data":["gpt-4o"]}。
        id identifier = entry[@"id"];
        if (![identifier isKindOfClass:[NSString class]]) identifier = entry[@"name"];
        if (![identifier isKindOfClass:[NSString class]] || [identifier length] == 0) continue;
        if (![identifiers containsObject:identifier]) [identifiers addObject:identifier];
    }
    return identifiers;
}

+ (NSArray<NSString *> *)fetchModelIdentifiersWithBaseURL:(NSString *)baseURL
                                                   apiKey:(NSString *)apiKey
                                               statusCode:(NSInteger *)statusCode
                                                    error:(NSError **)error
{
    if (statusCode) *statusCode = 0;
    NSString *base = baseURL.length ? baseURL : @"https://api.openai.com/v1";
    NSURL *url = [self endpointURLForBase:base suffix:@"models"];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:@"iagent.llm" code:-1000
                                    userInfo:@{ NSLocalizedDescriptionKey:
                                        [NSString stringWithFormat:@"Base URL 不是合法 URL: %@", base] }];
        }
        return nil;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 30;
    [request setValue:@"application/json" forKey:@"Accept"];
    [request setValue:@"iAgent/1.0 (iOS)" forKey:@"User-Agent"];
    if (apiKey.length) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forKey:@"Authorization"];
    }

    __block NSData *responseData = nil;
    __block NSURLResponse *responseObject = nil;
    __block NSError *transportError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:request
                                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
            responseData = data;
            responseObject = response;
            transportError = taskError;
            dispatch_semaphore_signal(semaphore);
        }];
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)));

    NSInteger status = [responseObject isKindOfClass:[NSHTTPURLResponse class]]
        ? ((NSHTTPURLResponse *)responseObject).statusCode : 0;
    if (statusCode) *statusCode = status;

    if (transportError) {
        if (error) *error = transportError;
        return nil;
    }
    if (status < 200 || status >= 300) {
        NSString *body = IAGTruncateString([[NSString alloc] initWithData:responseData
                                                                 encoding:NSUTF8StringEncoding] ?: @"", 500);
        if (error) {
            *error = [NSError errorWithDomain:@"iagent.llm" code:status
                                    userInfo:@{ NSLocalizedDescriptionKey:
                                        [NSString stringWithFormat:@"HTTP %ld %@", (long)status, body] }];
        }
        return nil;
    }

    NSArray<NSString *> *identifiers = [self modelIdentifiersFromData:responseData];
    if (!identifiers) {
        // 200 但没有 data[] 列表：给出原文，方便判断是不是 baseUrl 多/少了一层 /v1。
        NSString *preview = IAGTruncateString([[NSString alloc] initWithData:responseData
                                                                    encoding:NSUTF8StringEncoding] ?: @"", 300);
        if (error) {
            *error = [NSError errorWithDomain:@"iagent.llm" code:status
                                    userInfo:@{ NSLocalizedDescriptionKey:
                                        [NSString stringWithFormat:@"HTTP %ld 的响应里没有 data[] 列表: %@",
                                         (long)status, preview.length ? preview : @"(空响应)"] }];
        }
        return nil;
    }
    return identifiers;
}

+ (BOOL)probeStreamingWithBaseURL:(NSString *)baseURL
                           apiKey:(NSString *)apiKey
                            model:(NSString *)model
                     firstDeltaMs:(NSInteger *)firstDeltaMs
                          totalMs:(NSInteger *)totalMs
                      sawSSEEvent:(BOOL *)sawSSEEvent
                       statusCode:(NSInteger *)statusCode
                            error:(NSError **)error
{
    if (firstDeltaMs) *firstDeltaMs = 0;
    if (totalMs) *totalMs = 0;
    if (sawSSEEvent) *sawSSEEvent = NO;
    if (statusCode) *statusCode = 0;

    // 复用聊天那套请求/SSE 解析，只把 baseUrl/apiKey/model 换成体检用的临时值：
    // 临时 IAGConfig 只活在本次进程内，不写盘（见 initWithBaseConfig:overrides:）。
    IAGConfig *override = [[IAGConfig alloc] initWithBaseConfig:[IAGConfig shared]
                                                     overrides:@{ kIAGKeyBaseURL: baseURL ?: @"",
                                                                  kIAGKeyAPIKey:  apiKey ?: @"",
                                                                  kIAGKeyModel:   model ?: @"" }];
    IAGLLM *llm = [[IAGLLM alloc] initWithConfig:override];

    __block NSInteger firstDelta = 0;
    NSTimeInterval started = [NSDate date].timeIntervalSince1970;

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"model"] = model ?: @"";
    body[@"messages"] = @[ @{ @"role": @"user", @"content": @"hi" } ];
    body[@"max_tokens"] = @1;
    body[@"temperature"] = @0;
    body[@"stream"] = @YES;

    NSError *probeError = nil;
    IAGLLMResult *result = [llm performRequestWithBody:body
                                          deltaHandler:^(NSString *kind, NSString *text) {
        // 体检只关心"有没有真的收到流式增量"，内容还是推理都算。
        (void)kind;
        if (firstDelta == 0 && text.length > 0) {
            firstDelta = (NSInteger)(([NSDate date].timeIntervalSince1970 - started) * 1000.0);
        }
    }
                                      toolCallHandler:nil
                                                 error:&probeError];

    NSInteger elapsed = (NSInteger)(([NSDate date].timeIntervalSince1970 - started) * 1000.0);
    if (result) result.duration = [NSDate date].timeIntervalSince1970 - started;

    if (firstDeltaMs) *firstDeltaMs = firstDelta;
    if (totalMs) *totalMs = elapsed;
    if (statusCode) *statusCode = result ? result.statusCode : 0;

    if (firstDelta > 0) {
        if (sawSSEEvent) *sawSSEEvent = YES;
        return YES;
    }
    if (error) {
        *error = probeError ?: [NSError errorWithDomain:@"iagent.llm" code:502
                                              userInfo:@{ NSLocalizedDescriptionKey:
                                                  @"请求结束了，但没有收到任何流式内容" }];
    }
    return NO;
}

@end
