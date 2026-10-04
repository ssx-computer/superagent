//
//  IAGDaemon.m
//  iAgent
//

#import "IAGDaemon.h"
#import "IAGHTTPServer.h"
#import "IAGConfig.h"
#import "IAGAgent.h"
#import "IAGBridge.h"
#import "IAGLLM.h"
#import "IAGModelCheck.h"
#import "IAGPaths.h"
#import "IAGProcess.h"
#import "IAGScheduler.h"
#import "IAGSessionStore.h"
#import "IAGTerminal.h"
#import "IAGTool.h"
#import "IAGJSON.h"
#import "IAGLog.h"
#import "IAGUtil.h"
#import "IAGVersion.h"
#import "IAGDiagnostics.h"

static NSString *IAGContentTypeForExtension(NSString *extension)
{
    NSString *lower = [extension lowercaseString];
    if ([lower isEqualToString:@"html"] || [lower isEqualToString:@"htm"]) return @"text/html; charset=utf-8";
    if ([lower isEqualToString:@"js"])   return @"application/javascript; charset=utf-8";
    if ([lower isEqualToString:@"css"])  return @"text/css; charset=utf-8";
    if ([lower isEqualToString:@"json"]) return @"application/json; charset=utf-8";
    if ([lower isEqualToString:@"svg"])  return @"image/svg+xml";
    if ([lower isEqualToString:@"png"])  return @"image/png";
    if ([lower isEqualToString:@"jpg"] || [lower isEqualToString:@"jpeg"]) return @"image/jpeg";
    if ([lower isEqualToString:@"webp"]) return @"image/webp";
    if ([lower isEqualToString:@"ico"])  return @"image/x-icon";
    if ([lower isEqualToString:@"woff2"]) return @"font/woff2";
    if ([lower isEqualToString:@"txt"] || [lower isEqualToString:@"md"]) return @"text/plain; charset=utf-8";
    return @"application/octet-stream";
}

@implementation IAGDaemon {
    IAGHTTPServer *_server;
    NSTimeInterval _startedAt;
}

+ (instancetype)shared
{
    static IAGDaemon *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IAGDaemon alloc] init]; });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _startedAt = [NSDate date].timeIntervalSince1970;
    }
    return self;
}

- (uint16_t)port { return _server ? _server.port : 0; }
- (BOOL)running { return _server.running; }
- (NSTimeInterval)startedAt { return _startedAt; }

#pragma mark - lifecycle

- (BOOL)startWithError:(NSError **)error
{
    IAGEnsureDirectory(IAGDataDir());
    IAGEnsureDirectory(IAGSessionsDir());
    IAGEnsureDirectory(IAGLogDir());

    IAGConfig *config = [IAGConfig shared];
    IAGLogSetLevel((IAGLogLevel)[config integerForKey:kIAGKeyLogLevel fallback:IAGLogLevelInfo]);
    IAGLogSetMirrorToStderr(YES);
    IAGLogInfo(@"iAgent daemon %@ 启动中（%@ / jailbreak root %@ / %@）",
               IAG_VERSION_STRING, IAGDeviceModelIdentifier(), IAGJailbreakRoot(), IAGUserName());

    [[IAGToolRegistry shared] registerDefaults];

    uint16_t port = _portOverride ? _portOverride : (uint16_t)[config port];
    _server = [[IAGHTTPServer alloc] initWithPort:port];

    __weak typeof(self) weakSelf = self;
    [_server setHandler:^(IAGHTTPRequest *request, IAGHTTPResponse *response, IAGHTTPStream *stream) {
        [weakSelf handleRequest:request response:response stream:stream];
    }];

    NSError *startError = nil;
    if (![_server start:&startError]) {
        if (error) *error = startError;
        IAGLogError(@"HTTP 服务启动失败: %@", startError.localizedDescription);
        _server = nil;
        return NO;
    }

    [[IAGScheduler shared] start];
    IAGLogInfo(@"控制面板: http://127.0.0.1:%u/", _server.port);
    return YES;
}

- (void)stop
{
    [[IAGScheduler shared] stop];
    [[IAGTerminalManager shared] closeAll];
    [[IAGApprovalCenter shared] cancelAll];
    [[IAGBridge shared] cancelAll];
    [_server stop];
    _server = nil;
}

#pragma mark - routing helpers

- (BOOL)isAuthorized:(IAGHTTPRequest *)request
{
    NSString *token = [[IAGConfig shared] authToken];
    if (token.length == 0) return YES;
    if ([request.path isEqualToString:@"/api/health"]) return YES;   // lets the UI detect the daemon
    NSString *provided = [request accessToken];
    return [provided isEqualToString:token];
}

/// Returns the id for "/api/xxx/<id>" style paths, else nil.
- (NSString *)identifierFromPath:(NSString *)path prefix:(NSString *)prefix
{
    if (![path hasPrefix:prefix]) return nil;
    NSString *rest = [path substringFromIndex:prefix.length];
    if (rest.length == 0) return nil;
    return [rest stringByRemovingPercentEncoding] ?: rest;
}

- (void)serveStatic:(IAGHTTPRequest *)request response:(IAGHTTPResponse *)response
{
    NSString *webRoot = IAGWebRoot();
    NSString *relative = [request.path isEqualToString:@"/"] ? @"index.html" : [request.path substringFromIndex:1];
    if ([relative isEqualToString:@"favicon.ico"]) {
        response.status = 204;
        [response setData:[NSData data] contentType:@"image/x-icon"];
        return;
    }

    // Resolve inside the web root only.
    NSString *candidate = [[webRoot stringByAppendingPathComponent:relative] stringByStandardizingPath];
    NSString *normalizedRoot = [webRoot stringByStandardizingPath];
    if (![candidate hasPrefix:normalizedRoot]) {
        [response setError:@"路径非法" status:403];
        return;
    }

    NSData *data = [NSData dataWithContentsOfFile:candidate];
    if (!data) {
        [response setError:[NSString stringWithFormat:@"未找到 %@", request.path] status:404];
        return;
    }

    [response setData:data contentType:IAGContentTypeForExtension(candidate.pathExtension)];
    [response setHeader:@"no-cache, no-store, must-revalidate" forKey:@"Cache-Control"];
}

#pragma mark - main dispatcher

- (void)handleRequest:(IAGHTTPRequest *)request
             response:(IAGHTTPResponse *)response
               stream:(IAGHTTPStream *)stream
{
    NSString *path = request.path;
    NSString *method = request.method;

    // 服务端 handler 用 __weak self 捕获（避免 IAGHTTPServer ↔ IAGDaemon 循环引用）。
    // 万一 self 已经释放，这里必须自己给出响应，否则客户端会看到一个没有 body 的 200。
    if (self == nil) {
        [response setError:@"守护进程正在关闭" status:503];
        return;
    }

    if (![path hasPrefix:@"/api/"]) {
        [self serveStatic:request response:response];
        return;
    }

    if (![self isAuthorized:request]) {
        response.status = 401;
        [response setJSON:@{ @"error": @"需要有效的访问 token（X-IAG-Token）", @"needToken": @YES }];
        return;
    }

    @try {
        if ([self routeHealth:request response:response path:path method:method]) return;
        if ([self routeConfig:request response:response path:path method:method]) return;
        if ([self routeModels:request response:response path:path method:method]) return;
        if ([self routeSessions:request response:response path:path method:method]) return;
        if ([self routeChat:request response:response stream:stream path:path method:method]) return;
        if ([self routeTools:request response:response path:path method:method]) return;
        if ([self routeExec:request response:response path:path method:method]) return;
        if ([self routeTerminal:request response:response path:path method:method]) return;
        if ([self routeCron:request response:response path:path method:method]) return;
        if ([self routeBridge:request response:response path:path method:method]) return;
        if ([self routeLogs:request response:response path:path method:method]) return;
    } @catch (NSException *exception) {
        IAGLogError(@"路由 %@ %@ 异常: %@", method, path, exception.reason);
        [response setError:@"内部错误" status:500];
        return;
    }

    [response setError:[NSString stringWithFormat:@"未知接口 %@ %@", method, path] status:404];
}

#pragma mark - /api/health

- (BOOL)routeHealth:(IAGHTTPRequest *)request response:(IAGHTTPResponse *)response
               path:(NSString *)path method:(NSString *)method
{
    if (![path isEqualToString:@"/api/health"]) return NO;
    if (![method isEqualToString:@"GET"]) {
        [response setError:@"仅支持 GET" status:405];
        return YES;
    }

    IAGConfig *config = [IAGConfig shared];
    NSMutableArray *tools = [NSMutableArray array];
    for (NSDictionary *tool in [[IAGToolRegistry shared] toolListWithConfig:config]) {
        [tools addObject:@{ @"name": tool[@"name"] ?: @"",
                            @"description": tool[@"description"] ?: @"",
                            @"dangerous": tool[@"dangerous"] ?: @NO,
                            @"enabled": tool[@"enabled"] ?: @YES }];
    }

    NSDictionary *device = @{
        @"model": IAGDeviceModelIdentifier(),
        @"name": IAGDeviceModelName(),
        @"deviceName": IAGDeviceName() ?: @"",
        @"systemName": @"iOS",
        @"systemVersion": IAGSystemVersion(),
        @"freeDisk": @(IAGFreeDiskSpace()),
        @"bootUUID": IAGBootUUID(),
    };

    // 存活/重启信息：前端可以据此提示"守护进程刚刚重启过"。
    // 键名固定为 pid / startedAt / restarts / lastCrash / lastExitClean
    // （由 IAGDiagnostics 提供，见 shared/IAGDiagnostics.h）。
    NSDictionary *diagnostics = IAGDaemonHealthInfo();

    [response setJSON:@{
        @"ok": @YES,
        @"version": IAG_VERSION_STRING,
        @"build": IAG_BUILD_STRING,
        @"uptimeSec": @((NSInteger)([NSDate date].timeIntervalSince1970 - _startedAt)),
        @"processUptime": IAGProcessUptime(),
        @"pid": diagnostics[@"pid"],
        @"startedAt": diagnostics[@"startedAt"],
        @"restarts": diagnostics[@"restarts"],
        @"lastCrash": diagnostics[@"lastCrash"],
        @"lastExitClean": diagnostics[@"lastExitClean"],
        @"jbRoot": IAGJailbreakRoot(),
        @"rootfs": IAGRootfs(),
        @"rootless": @(IAGIsRootless()),
        @"runningAsRoot": @(IAGIsRoot()),
        @"user": IAGUserName(),
        @"device": device,
        @"model": @{
            @"baseUrl": [config baseURL],
            @"model": [config model],
            @"hasKey": @([config apiKey].length > 0),
            @"apiKeyMasked": [config publicSnapshot][@"apiKeyMasked"] ?: @"",
            @"approvalMode": [config approvalMode],
        },
        @"authRequired": @([config authToken].length > 0),
        @"tools": tools,
        @"sessions": @([[IAGSessionStore shared] sessionCount]),
        @"terminalSessions": @([[IAGTerminalManager shared] allSessions].count),
        @"runningSessions": [[IAGAgent shared] runningSessions],
        @"pendingApprovals": @([[IAGApprovalCenter shared] pendingCount]),
        @"bridge": [[IAGBridge shared] statusJSON],
        @"http": @{
            @"port": @(_server.port),
            @"totalRequests": @(_server.totalRequests),
            @"activeConnections": @(_server.activeConnections),
        },
        @"webRoot": IAGWebRoot(),
        @"dataDir": IAGDataDir(),
        @"time": @((NSInteger)[NSDate date].timeIntervalSince1970),
    }];
    return YES;
}

#pragma mark - /api/config

- (BOOL)routeConfig:(IAGHTTPRequest *)request response:(IAGHTTPResponse *)response
               path:(NSString *)path method:(NSString *)method
{
    if (![path isEqualToString:@"/api/config"]) return NO;
    IAGConfig *config = [IAGConfig shared];

    if ([method isEqualToString:@"GET"]) {
        [response setJSON:[config publicSnapshot]];
        return YES;
    }
    if ([method isEqualToString:@"POST"]) {
        NSDictionary *patch = [request jsonBody];
        if (![patch isKindOfClass:[NSDictionary class]]) {
            [response setError:@"请求体必须是 JSON 对象" status:400];
            return YES;
        }
        NSArray<NSString *> *changed = [config applyPatch:patch];
        if ([changed containsObject:kIAGKeyLogLevel]) {
            IAGLogSetLevel((IAGLogLevel)[config integerForKey:kIAGKeyLogLevel fallback:IAGLogLevelInfo]);
        }
        IAGLogInfo(@"配置已更新: %@", [changed componentsJoinedByString:@", "]);
        NSMutableDictionary *json = [[config publicSnapshot] mutableCopy];
        json[@"changed"] = changed;
        [response setJSON:json];
        return YES;
    }

    [response setError:@"仅支持 GET/POST" status:405];
    return YES;
}

#pragma mark - /api/models 与 /api/model/check

- (BOOL)routeModels:(IAGHTTPRequest *)request response:(IAGHTTPResponse *)response
               path:(NSString *)path method:(NSString *)method
{
    // 只接管 /api/models 与 /api/model/check 这两个精确路径：
    // 其它 /api/model* 前缀（例如手滑写成 /api/model/checks）交给后面的路由去报 404，
    // 免得这里的"未知接口"抢了别人的诊断信息。
    if (![path isEqualToString:@"/api/models"] && ![path isEqualToString:@"/api/model/check"]) {
        return NO;
    }

    // GET /api/models：把远端 /models 的结果直接给前端做下拉选择。
    if ([path isEqualToString:@"/api/models"]) {
        if (![method isEqualToString:@"GET"]) {
            [response setError:@"仅支持 GET" status:405];
            return YES;
        }

        IAGConfig *config = [IAGConfig shared];
        NSInteger statusCode = 0;
        NSError *error = nil;
        NSArray<NSString *> *models = nil;
        @try {
            models = [IAGLLM fetchModelIdentifiersWithBaseURL:[config baseURL]
                                                       apiKey:[config apiKey]
                                                   statusCode:&statusCode
                                                        error:&error];
        } @catch (NSException *exception) {
            error = [NSError errorWithDomain:@"iagent.llm" code:-1
                                    userInfo:@{ NSLocalizedDescriptionKey:
                                        [NSString stringWithFormat:@"获取模型列表异常: %@",
                                         exception.reason ?: @"未知"] }];
        }

        if (!models) {
            NSString *reason = error.localizedDescription ?: @"获取模型列表失败";
            IAGLogError(@"GET /api/models 失败: %@", reason);
            [response setJSON:@{ @"ok": @NO, @"models": @[], @"error": reason ?: @"" }];
            return YES;
        }
        [response setJSON:@{ @"ok": @YES, @"models": models, @"error": [NSNull null] }];
        return YES;
    }

    // POST /api/model/check：分步体检。**无论成功失败都返回 HTTP 200**，body 结构固定，
    // 因为它是"体检报告"而不是"接口调用结果"。
    if ([path isEqualToString:@"/api/model/check"]) {
        if (![method isEqualToString:@"POST"]) {
            [response setError:@"仅支持 POST" status:405];
            return YES;
        }

        NSDictionary *body = [request jsonBody];
        NSDictionary *overrides = nil;
        if ([body isKindOfClass:[NSDictionary class]] && body.count > 0) {
            // 只接受这三个键，其余忽略（避免前端误传把临时配置搞脏）。
            NSMutableDictionary *filtered = [NSMutableDictionary dictionary];
            for (NSString *key in @[ kIAGKeyBaseURL, kIAGKeyAPIKey, kIAGKeyModel ]) {
                id value = body[key];
                if ([value isKindOfClass:[NSString class]] && [value length] > 0) filtered[key] = value;
            }
            if (filtered.count) overrides = filtered;
        }

        NSDictionary *report = nil;
        @try {
            report = [IAGModelCheck runWithConfig:[IAGConfig shared] overrides:overrides];
        } @catch (NSException *exception) {
            IAGLogError(@"模型体检异常: %@", exception.reason ?: @"未知");
            report = @{
                @"ok": @NO,
                @"verdict": [NSString stringWithFormat:@"不可用：体检过程异常（%@）",
                             exception.reason ?: @"未知"],
                @"hint": @"查看 logs/iagent.log 里的「模型体检」相关日志",
                @"steps": @[],
                @"models": @[],
            };
        }

        [response setJSON:report ?: @{ @"ok": @NO, @"verdict": @"不可用：未知错误",
                                       @"hint": @"", @"steps": @[], @"models": @[] }];
        return YES;
    }

    return NO;
}

#pragma mark - /api/sessions

- (BOOL)routeSessions:(IAGHTTPRequest *)request response:(IAGHTTPResponse *)response
                 path:(NSString *)path method:(NSString *)method
{
    if (![path hasPrefix:@"/api/sessions"]) return NO;
    IAGSessionStore *store = [IAGSessionStore shared];

    if ([path isEqualToString:@"/api/sessions"]) {
        if ([method isEqualToString:@"GET"]) {
            NSMutableArray *list = [NSMutableArray array];
            for (IAGSession *session in [store sessions]) [list addObject:[session summaryJSON]];
            [response setJSON:list];
            return YES;
        }
        if ([method isEqualToString:@"POST"]) {
            NSDictionary *body = [request jsonBody];
            NSString *title = IAGDictString(body, @"title", nil);
            IAGSession *session = [store createSessionWithTitle:title];
            [response setJSON:[session summaryJSON]];
            return YES;
        }
        [response setError:@"仅支持 GET/POST" status:405];
        return YES;
    }

    NSString *sessionId = [self identifierFromPath:path prefix:@"/api/sessions/"];
    if (sessionId.length == 0) {
        [response setError:@"缺少会话 id" status:400];
        return YES;
    }

    if ([method isEqualToString:@"GET"]) {
        IAGSession *session = [store sessionWithIdentifier:sessionId];
        if (!session) {
            [response setError:@"会话不存在" status:404];
            return YES;
        }
        [response setJSON:[session fullJSON]];
        return YES;
    }
    if ([method isEqualToString:@"DELETE"]) {
        if (![store deleteSession:sessionId]) {
            [response setError:@"会话不存在" status:404];
            return YES;
        }
        [response setJSON:IAGOkObject()];
        return YES;
    }
    if ([method isEqualToString:@"PATCH"] || [method isEqualToString:@"POST"]) {
        NSDictionary *body = [request jsonBody];
        NSString *title = IAGDictString(body, @"title", nil);
        if (![store renameSession:sessionId title:title]) {
            [response setError:@"会话不存在" status:404];
            return YES;
        }
        [response setJSON:[[store sessionWithIdentifier:sessionId] summaryJSON]];
        return YES;
    }

    [response setError:@"不支持的方法" status:405];
    return YES;
}

#pragma mark - /api/chat

- (BOOL)routeChat:(IAGHTTPRequest *)request response:(IAGHTTPResponse *)response
           stream:(IAGHTTPStream *)stream path:(NSString *)path method:(NSString *)method
{
    if ([path isEqualToString:@"/api/abort"]) {
        if (![method isEqualToString:@"POST"]) {
            [response setError:@"仅支持 POST" status:405];
            return YES;
        }
        NSString *sessionId = IAGDictString([request jsonBody], @"sessionId", @"");
        [[IAGAgent shared] abortSession:sessionId];
        [response setJSON:IAGOkObject()];
        return YES;
    }

    if ([path isEqualToString:@"/api/approve"]) {
        if (![method isEqualToString:@"POST"]) {
            [response setError:@"仅支持 POST" status:405];
            return YES;
        }
        NSDictionary *body = [request jsonBody];
        NSString *identifier = IAGDictString(body, @"id", @"");
        BOOL allow = IAGDictBool(body, @"allow", NO);
        BOOL resolved = [[IAGApprovalCenter shared] resolveApprovalForIdentifier:identifier allow:allow];
        if (!resolved) {
            [response setError:@"没有等待中的审批请求（可能已超时）" status:404];
            return YES;
        }
        [response setJSON:IAGOkObject()];
        return YES;
    }

    if (![path isEqualToString:@"/api/chat"]) return NO;
    if (![method isEqualToString:@"POST"]) {
        [response setError:@"仅支持 POST" status:405];
        return YES;
    }

    NSDictionary *body = [request jsonBody];
    if (![body isKindOfClass:[NSDictionary class]]) {
        [response setError:@"请求体必须是 JSON 对象" status:400];
        return YES;
    }

    NSString *sessionId = IAGDictString(body, @"sessionId", @"");
    NSString *message = IAGDictString(body, @"message", @"");
    if (message.length == 0) {
        [response setError:@"message 不能为空" status:400];
        return YES;
    }

    IAGSession *session = [[IAGSessionStore shared] sessionWithIdentifier:sessionId];
    if (!session) {
        session = [[IAGSessionStore shared] createSessionWithTitle:nil];
        sessionId = session.sessionId;
    }

    BOOL wantsStream = IAGDictBool(body, @"stream", YES);
    if (!wantsStream && ![stream started]) {
        // Non-streaming: collect events and answer with one JSON document.
        NSMutableString *text = [NSMutableString string];
        NSMutableArray *toolCalls = [NSMutableArray array];
        __block NSDictionary *usage = nil;
        __block NSInteger steps = 0;
        __block NSString *errorMessage = nil;

        [[IAGAgent shared] runSession:sessionId message:message eventHandler:^(NSString *event, NSDictionary *payload) {
            if ([event isEqualToString:@"delta"]) [text appendString:IAGStringOrEmpty(payload[@"text"])];
            else if ([event isEqualToString:@"tool_call"]) [toolCalls addObject:payload];
            else if ([event isEqualToString:@"done"]) {
                usage = payload[@"usage"];
                steps = IAGDictInteger(payload, @"steps", 0);
            } else if ([event isEqualToString:@"error"]) errorMessage = IAGStringOrEmpty(payload[@"message"]);
        }];

        if (errorMessage) {
            [response setError:errorMessage status:502];
            return YES;
        }
        [response setJSON:@{ @"sessionId": sessionId, @"text": text,
                             @"toolCalls": toolCalls, @"usage": usage ?: @{},
                             @"steps": @(steps) }];
        return YES;
    }

    if (![stream beginWithStatus:200 contentType:@"text/event-stream; charset=utf-8"]) {
        return YES;
    }

    // Keep proxies/clients from timing out during long tool executions.
    dispatch_queue_t heartbeatQueue = dispatch_queue_create("com.dsh.iagent.sse.heartbeat", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, heartbeatQueue);
    dispatch_source_set_timer(heartbeat, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                              10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(heartbeat, ^{
        [stream sendComment:@"keepalive"];
    });
    dispatch_resume(heartbeat);

    [stream sendEvent:@"session" data:@{ @"sessionId": sessionId }];

    // 事件流的收尾保证：**任何一次 /api/chat 的 SSE 流都必须恰好以一个 done 事件结束**。
    // 预检失败（会话不存在、没配 API Key）等路径只发 error 就 return，前端会看到
    // "收到 error 然后连接被关闭"，从而再叠加一条"连接被提前关闭（daemon 可能被杀/
    // 崩溃）"的误导提示——用户以为守护进程崩了。这里兜底补一个 done。
    __block BOOL sawDone = NO;
    __block BOOL sawError = NO;
    void (^emitTerminalDone)(void) = ^{
        if (sawDone || !stream.open) return;
        sawDone = YES;
        [stream sendEvent:@"done" data:@{
            @"sessionId": sessionId,
            @"steps": @0,
            @"partial": @YES,
            @"reason": sawError ? @"error" : @"unknown",
        }];
    };

    [[IAGAgent shared] runSession:sessionId message:message eventHandler:^(NSString *event, NSDictionary *payload) {
        // 客户端断开后不要继续往坏掉的 socket 写：stream.open 变 NO 就停止推送，
        // 让 agent 循环尽快跑完（它自己会在每步检查 isAborted）。
        if (!stream.open) return;
        if ([event isEqualToString:@"done"]) sawDone = YES;
        if ([event isEqualToString:@"error"]) sawError = YES;
        [stream sendEvent:event data:payload];
    }];

    // 走到这里说明 agent 循环结束了：没发过 done 就补一个（正常路径下 IAGAgent 已发）。
    emitTerminalDone();

    dispatch_source_cancel(heartbeat);
    [stream end];
    return YES;
}

#pragma mark - /api/tools

- (BOOL)routeTools:(IAGHTTPRequest *)request response:(IAGHTTPResponse *)response
              path:(NSString *)path method:(NSString *)method
{
    if (![path hasPrefix:@"/api/tools"]) return NO;

    IAGConfig *config = [IAGConfig shared];
    IAGToolRegistry *registry = [IAGToolRegistry shared];

    if ([path isEqualToString:@"/api/tools"]) {
        if (![method isEqualToString:@"GET"]) {
            [response setError:@"仅支持 GET" status:405];
            return YES;
        }
        [response setJSON:@{ @"tools": [registry toolListWithConfig:config] }];
        return YES;
    }

    if ([path isEqualToString:@"/api/tools/call"]) {
        if (![method isEqualToString:@"POST"]) {
            [response setError:@"仅支持 POST" status:405];
            return YES;
        }
        NSDictionary *body = [request jsonBody];
        NSString *name = IAGDictString(body, @"name", @"");
        NSDictionary *arguments = IAGDictDictionary(body, @"arguments") ?: @{};
        if (![registry toolExists:name]) {
            [response setError:[NSString stringWithFormat:@"未知工具 %@", name] status:404];
            return YES;
        }
        NSString *blocked = [registry blockedReasonForTool:name arguments:arguments config:config];
        if (blocked.length) {
            [response setError:blocked status:403];
            return YES;
        }
        IAGToolContext *context = [IAGToolContext contextWithConfig:config
                                                          sessionId:@"manual"
                                                             bridge:[IAGBridge shared]];
        NSDictionary *result = [registry executeTool:name arguments:arguments context:context];
        [response setJSON:result];
        return YES;
    }

    [response setError:@"未知接口" status:404];
    return YES;
}

#pragma mark - /api/exec

- (BOOL)routeExec:(IAGHTTPRequest *)request response:(IAGHTTPResponse *)response
             path:(NSString *)path method:(NSString *)method
{
    if (![path isEqualToString:@"/api/exec"]) return NO;
    if (![method isEqualToString:@"POST"]) {
        [response setError:@"仅支持 POST" status:405];
        return YES;
    }

    NSDictionary *body = [request jsonBody];
    NSString *command = IAGDictString(body, @"command", @"");
    if (command.length == 0) {
        [response setError:@"command 不能为空" status:400];
        return YES;
    }

    IAGConfig *config = [IAGConfig shared];

    // 配置里的硬黑名单对所有 shell 入口一致生效。审批不适用：这里是用户本人
    // 在敲命令，不需要再向他自己确认。
    NSString *lowercased = command.lowercaseString;
    for (NSString *pattern in [config blockedCommandPatterns]) {
        if (pattern.length == 0) continue;
        if ([lowercased containsString:pattern.lowercaseString]) {
            [response setError:[NSString stringWithFormat:@"命令命中黑名单规则「%@」", pattern] status:403];
            return YES;
        }
    }

    NSString *cwd = IAGDictString(body, @"cwd", nil);
    if (cwd.length == 0) cwd = [config workDir];
    NSInteger timeout = IAGDictInteger(body, @"timeout", [config shellTimeout]);
    if (timeout <= 0) timeout = [config shellTimeout];

    IAGProcessResult *result = [IAGProcess runShell:command
                                          directory:cwd
                                            timeout:(NSTimeInterval)timeout
                                          maxOutput:1024 * 1024
                                        environment:nil];

    [response setJSON:@{
        @"exitCode": @(result.exitCode),
        @"stdout": IAGTruncateString(result.standardOutput ?: @"", 200000),
        @"stderr": IAGTruncateString(result.standardError ?: @"", 200000),
        @"durationMs": @((NSInteger)(result.duration * 1000)),
        @"timedOut": @(result.timedOut),
        @"launchError": result.launchError ?: @"",
        @"cwd": cwd,
    }];
    return YES;
}

#pragma mark - /api/term

- (BOOL)routeTerminal:(IAGHTTPRequest *)request response:(IAGHTTPResponse *)response
                 path:(NSString *)path method:(NSString *)method
{
    if (![path hasPrefix:@"/api/term"]) return NO;
    IAGTerminalManager *manager = [IAGTerminalManager shared];

    if ([path isEqualToString:@"/api/term/list"]) {
        NSMutableArray *list = [NSMutableArray array];
        for (IAGTerminalSession *session in [manager allSessions]) [list addObject:[session statusJSON]];
        [response setJSON:list];
        return YES;
    }

    if ([path isEqualToString:@"/api/term/open"]) {
        NSDictionary *body = [request jsonBody];
        int columns = (int)IAGDictInteger(body, @"cols", 80);
        int rows = (int)IAGDictInteger(body, @"rows", 24);
        NSString *shell = IAGDictString(body, @"shell", nil);
        NSString *error = nil;
        IAGTerminalSession *session = [manager openWithColumns:columns rows:rows shell:shell error:&error];
        if (!session) {
            [response setError:error ?: @"无法创建终端" status:500];
            return YES;
        }
        [response setJSON:@{ @"sessionId": session.sessionId,
                             @"pid": @(session.pid),
                             @"shell": session.shellPath }];
        return YES;
    }

    if ([path isEqualToString:@"/api/term/read"]) {
        NSString *sessionId = [request queryParam:@"sessionId"];
        NSInteger since = [[request queryParam:@"since"] integerValue];
        IAGTerminalSession *session = [manager sessionWithIdentifier:sessionId];
        if (!session) {
            [response setError:@"终端会话不存在" status:404];
            return YES;
        }
        [response setJSON:[session readSince:(NSUInteger)MAX(0, since)]];
        return YES;
    }

    NSDictionary *body = [request jsonBody];
    NSString *sessionId = IAGDictString(body, @"sessionId", @"");
    IAGTerminalSession *session = [manager sessionWithIdentifier:sessionId];
    if (!session) {
        [response setError:@"终端会话不存在" status:404];
        return YES;
    }

    if ([path isEqualToString:@"/api/term/input"]) {
        NSString *data = IAGDictString(body, @"data", @"");
        NSString *base64 = IAGDictString(body, @"data_base64", @"");
        if (base64.length) {
            [session writeData:IAGBase64Decode(base64)];
        } else {
            [session writeString:data];
        }
        [response setJSON:IAGOkObject()];
        return YES;
    }

    if ([path isEqualToString:@"/api/term/resize"]) {
        [session resizeToColumns:(int)IAGDictInteger(body, @"cols", 80)
                            rows:(int)IAGDictInteger(body, @"rows", 24)];
        [response setJSON:IAGOkObject()];
        return YES;
    }

    if ([path isEqualToString:@"/api/term/close"]) {
        [session close];
        [response setJSON:IAGOkObject()];
        return YES;
    }

    [response setError:@"未知终端接口" status:404];
    return YES;
}

#pragma mark - /api/cron

- (BOOL)routeCron:(IAGHTTPRequest *)request response:(IAGHTTPResponse *)response
             path:(NSString *)path method:(NSString *)method
{
    if (![path hasPrefix:@"/api/cron"]) return NO;
    IAGScheduler *scheduler = [IAGScheduler shared];

    if ([path isEqualToString:@"/api/cron"]) {
        if ([method isEqualToString:@"GET"]) {
            NSMutableArray *list = [NSMutableArray array];
            for (IAGCronTask *task in [scheduler tasks]) [list addObject:[task json]];
            [response setJSON:list];
            return YES;
        }
        if ([method isEqualToString:@"POST"]) {
            NSDictionary *body = [request jsonBody];
            NSString *schedule = IAGDictString(body, @"schedule", @"");
            NSString *command = IAGDictString(body, @"command", @"");
            BOOL enabled = IAGDictBool(body, @"enabled", YES);
            NSString *error = nil;
            IAGCronTask *task = [scheduler addTaskWithSchedule:schedule command:command
                                                       enabled:enabled error:&error];
            if (!task) {
                [response setError:error ?: @"创建失败" status:400];
                return YES;
            }
            [response setJSON:[task json]];
            return YES;
        }
        [response setError:@"仅支持 GET/POST" status:405];
        return YES;
    }

    NSString *taskId = [self identifierFromPath:path prefix:@"/api/cron/"];
    if (taskId.length == 0) {
        [response setError:@"缺少任务 id" status:400];
        return YES;
    }

    if ([method isEqualToString:@"DELETE"]) {
        if (![scheduler removeTask:taskId]) {
            [response setError:@"任务不存在" status:404];
            return YES;
        }
        [response setJSON:IAGOkObject()];
        return YES;
    }
    if ([method isEqualToString:@"POST"] || [method isEqualToString:@"PATCH"]) {
        NSDictionary *body = [request jsonBody];
        if (body[@"enabled"] != nil) {
            [scheduler setTask:taskId enabled:IAGDictBool(body, @"enabled", YES)];
        }
        if (IAGDictBool(body, @"runNow", NO)) {
            [scheduler runTaskNow:taskId];
        }
        [response setJSON:[[scheduler taskWithIdentifier:taskId] json] ?: IAGOkObject()];
        return YES;
    }

    [response setError:@"不支持的方法" status:405];
    return YES;
}

#pragma mark - /api/bridge

/// caps 接受两种形式：JSON 字典 `{"hid":1}`，或紧凑列表 `hid:1,ax:1,notify:cf`。
/// 插件用后者——把 JSON 塞进 query string 需要额外转义，容易出错。
static NSDictionary *IAGParseBridgeCapabilities(NSString *raw)
{
    NSString *decoded = [raw stringByRemovingPercentEncoding] ?: raw;
    id json = IAGJSONCoerce(decoded);
    if ([json isKindOfClass:[NSDictionary class]]) return json;

    NSCharacterSet *spaces = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *pair in [decoded componentsSeparatedByString:@","]) {
        NSArray<NSString *> *parts = [pair componentsSeparatedByString:@":"];
        NSString *key = [[parts.firstObject stringByTrimmingCharactersInSet:spaces] lowercaseString];
        if (key.length == 0) continue;
        NSString *value = parts.count > 1 ? [parts[1] stringByTrimmingCharactersInSet:spaces] : @"1";
        result[key] = value.length ? value : @"1";
    }
    return result.count ? result : nil;
}

- (BOOL)routeBridge:(IAGHTTPRequest *)request response:(IAGHTTPResponse *)response
               path:(NSString *)path method:(NSString *)method
{
    if (![path hasPrefix:@"/api/bridge"]) return NO;
    IAGBridge *bridge = [IAGBridge shared];

    if ([path isEqualToString:@"/api/bridge/poll"]) {
        NSString *caps = [request queryParam:@"caps"];
        if (caps.length) {
            NSDictionary *parsed = IAGParseBridgeCapabilities(caps);
            if (parsed) [bridge noteCapabilities:parsed];
        }
        NSInteger since = [[request queryParam:@"since"] integerValue];
        NSInteger wait = [[request queryParam:@"wait"] integerValue];
        if (wait <= 0) wait = 20;
        [response setJSON:[bridge pollSince:(NSUInteger)MAX(0, since) wait:(NSTimeInterval)wait]];
        return YES;
    }

    if ([path isEqualToString:@"/api/bridge/result"]) {
        NSDictionary *body = [request jsonBody];
        BOOL accepted = [bridge submitResult:body ?: @{}];
        [response setJSON:@{ @"ok": @(accepted) }];
        return YES;
    }

    if ([path isEqualToString:@"/api/bridge/status"]) {
        [response setJSON:[bridge statusJSON]];
        return YES;
    }

    [response setError:@"未知桥接接口" status:404];
    return YES;
}

#pragma mark - /api/logs

- (BOOL)routeLogs:(IAGHTTPRequest *)request response:(IAGHTTPResponse *)response
             path:(NSString *)path method:(NSString *)method
{
    if (![path hasPrefix:@"/api/logs"]) return NO;

    if ([path isEqualToString:@"/api/logs"] && [method isEqualToString:@"GET"]) {
        NSInteger lines = [[request queryParam:@"lines"] integerValue];
        if (lines <= 0) lines = 200;
        [response setJSON:@{ @"lines": IAGLogTail((NSUInteger)lines) ?: @[],
                             @"path": IAGLogPath() }];
        return YES;
    }

    if ([path isEqualToString:@"/api/logs/clear"] && [method isEqualToString:@"POST"]) {
        IAGLogClear();
        [response setJSON:IAGOkObject()];
        return YES;
    }

    [response setError:@"不支持的方法" status:405];
    return YES;
}

@end
