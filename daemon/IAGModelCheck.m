//
//  IAGModelCheck.m
//  iAgent
//
//  实现说明（为什么这么写）：
//
//    * 全程顺序执行、失败即短路，但**步骤本身永远存在**——后续步骤写成
//      "未执行（上一步失败）"，前端不必再判断数组长度。
//    * 网络连通与接口鉴权共用**同一个** GET /models 请求（省一次往返），但分成两步
//      报告：连接层的错误（NSURLErrorDomain -1004 等）算"网络不通"，HTTP 401/403
//      算"鉴权失败"。用户最容易搞错的就是这两者的区别。
//    * 流式对话用 IAGLLM 现成的 SSE 通道发一个 max_tokens=1 的真实请求，
//      验证"至少收到一个 delta"——端点返回 200 却一个 SSE 事件都没有（忽略
//      stream:true 的中转）会被单独识别出来。
//    * 无论哪一步失败，返回值都是 HTTP 200 + 固定结构（路由层保证），因为这是
//      "体检报告"，不是"接口调用失败"。
//

#import "IAGModelCheck.h"
#import "IAGConfig.h"
#import "IAGLLM.h"
#import "IAGJSON.h"
#import "IAGLog.h"
#import "IAGUtil.h"

static const NSUInteger kIAGCheckDetailLimit = 500;   // detail 字符上限
static const NSUInteger kIAGCheckHintModelCount = 10; // hint 里建议的模型个数

/// 一步的结果：名字、是否通过、明细、耗时。
@interface IAGModelCheckStep : NSObject
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, assign) BOOL ok;
@property (nonatomic, copy)   NSString *detail;
@property (nonatomic, assign) NSInteger ms;
- (NSDictionary *)json;
@end

@implementation IAGModelCheckStep

- (NSDictionary *)json
{
    return @{
        @"name": self.name ?: @"",
        @"ok": @(self.ok),
        @"detail": IAGTruncateString(IAGCollapseWhitespace(self.detail ?: @""), kIAGCheckDetailLimit),
        @"ms": @(self.ms),
    };
}

@end

#pragma mark - 小工具

/// 网络错误的一行式描述："NSURLErrorDomain -1004 无法连接到服务器"。
static NSString *IAGDescribeNetworkError(NSError *error)
{
    if (!error) return @"未知网络错误";
    NSString *domain = error.domain.length ? error.domain : @"NSError";
    NSString *reason = IAGCollapseWhitespace(error.localizedDescription ?: @"");
    return [NSString stringWithFormat:@"%@ %ld %@", domain, (long)error.code, reason];
}

/// 把远端响应体压成一行预览。
static NSString *IAGPreviewBody(NSData *data, NSUInteger limit)
{
    if (data.length == 0) return @"";
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length == 0) text = @"(非 UTF-8 响应)";
    return IAGCollapseWhitespace(IAGTruncateString(text, limit));
}

/// 掩码显示 key：既能让用户确认"用的是哪把 key"，又不把完整密钥写进响应/日志。
static NSString *IAGMaskKey(NSString *key)
{
    if (key.length == 0) return @"未设置";
    if (key.length <= 10) return [NSString stringWithFormat:@"已设置(%@****)", [key substringToIndex:MIN((NSUInteger)2, key.length)]];
    return [NSString stringWithFormat:@"已设置(%@…%@)",
            [key substringToIndex:6], [key substringFromIndex:key.length - 4]];
}

static BOOL IAGIsAuthError(NSError *error, NSInteger statusCode)
{
    if (statusCode == 401 || statusCode == 403) return YES;
    if (![error.domain isEqualToString:@"iagent.llm"]) return NO;
    return error.code == 401 || error.code == 403;
}

#pragma mark - 体检

@implementation IAGModelCheck

+ (NSDictionary *)runWithConfig:(IAGConfig *)config overrides:(NSDictionary *)overrides
{
    // 用一份临时的、不落盘的配置承载前端传来的覆盖值。
    IAGConfig *effective = [[IAGConfig alloc] initWithBaseConfig:config overrides:overrides];

    NSString *baseURL = [effective baseURL] ?: @"";
    NSString *apiKey  = [effective apiKey]  ?: @"";
    NSString *model   = [effective model]   ?: @"";

    NSMutableArray<IAGModelCheckStep *> *steps = [NSMutableArray array];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *models = [NSMutableArray array];

    NSString *verdict = @"不可用：未知错误";
    NSString *hint = @"";
    BOOL overallOK = NO;

    // ---------- 1. 配置检查 ----------
    IAGModelCheckStep *configStep = [[IAGModelCheckStep alloc] init];
    configStep.name = @"配置检查";
    NSTimeInterval stepStarted = [NSDate date].timeIntervalSince1970;

    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    if (baseURL.length == 0) [missing addObject:@"baseUrl"];
    if (model.length == 0) [missing addObject:@"model"];
    if (apiKey.length == 0) [missing addObject:@"apiKey"];

    NSDictionary *configDetail = @{
        @"baseUrl": baseURL.length ? baseURL : @"(空)",
        @"model": model.length ? model : @"(空)",
        @"key": IAGMaskKey(apiKey),
        @"missing": [missing copy],
    };

    if (missing.count > 0) {
        configStep.ok = NO;
        configStep.ms = (NSInteger)(([NSDate date].timeIntervalSince1970 - stepStarted) * 1000.0);
        configStep.detail = [NSString stringWithFormat:@"缺少 %@；baseUrl=%@  model=%@  key=%@",
                             [missing componentsJoinedByString:@"、"],
                             configDetail[@"baseUrl"], configDetail[@"model"], configDetail[@"key"]];
        [steps addObject:configStep];

        verdict = [NSString stringWithFormat:@"不可用：配置不完整（缺少 %@）",
                   [missing componentsJoinedByString:@"、"]];
        if ([missing containsObject:@"baseUrl"]) {
            hint = @"在设置页填写 Base URL，例如 https://api.openai.com/v1（通常需要带 /v1）";
        } else if ([missing containsObject:@"model"]) {
            hint = @"在设置页填写模型名，例如 gpt-4o-mini；也可以用 GET /api/models 拉取可用列表";
        } else {
            hint = @"在设置页填写 API Key（Authorization: Bearer <key>）";
        }
    } else {
        configStep.ok = YES;
        configStep.ms = (NSInteger)(([NSDate date].timeIntervalSince1970 - stepStarted) * 1000.0);
        configStep.detail = [NSString stringWithFormat:@"baseUrl=%@  model=%@  key=%@",
                             configDetail[@"baseUrl"], configDetail[@"model"], configDetail[@"key"]];
        [steps addObject:configStep];

        // ---------- 2/3/4. 网络连通 + 接口鉴权 + 模型列表（共用一次 GET /models）----------
        IAGModelCheckStep *networkStep = [[IAGModelCheckStep alloc] init];
        networkStep.name = @"网络连通";

        IAGModelCheckStep *authStep = [[IAGModelCheckStep alloc] init];
        authStep.name = @"接口鉴权";

        IAGModelCheckStep *listStep = [[IAGModelCheckStep alloc] init];
        listStep.name = @"模型列表";

        NSURLComponents *components = [NSURLComponents componentsWithString:baseURL];
        NSString *host = components.host.length ? components.host : baseURL;

        NSInteger statusCode = 0;
        NSError *modelsError = nil;
        NSArray<NSString *> *fetched = nil;
        NSTimeInterval networkStarted = [NSDate date].timeIntervalSince1970;

        @try {
            fetched = [IAGLLM fetchModelIdentifiersWithBaseURL:baseURL
                                                        apiKey:apiKey
                                                    statusCode:&statusCode
                                                         error:&modelsError];
        } @catch (NSException *exception) {
            // 体检绝不能因为一个异常就 500：记下来当成"网络/接口"失败处理。
            modelsError = [NSError errorWithDomain:@"iagent.llm" code:-1
                                          userInfo:@{ NSLocalizedDescriptionKey:
                                              [NSString stringWithFormat:@"请求 %@ 时发生异常: %@",
                                               baseURL, exception.reason ?: @"未知"] }];
            IAGLogError(@"模型体检：/models 请求异常: %@", exception.reason ?: @"未知");
        }
        NSInteger networkMs = (NSInteger)(([NSDate date].timeIntervalSince1970 - networkStarted) * 1000.0);

        BOOL connectionFailed = NO;
        BOOL authFailed = NO;

        if (modelsError && statusCode == 0) {
            // 连接层就失败了：DNS/超时/TLS/端口不通。
            connectionFailed = YES;
            networkStep.ok = NO;
            networkStep.ms = networkMs;
            networkStep.detail = [NSString stringWithFormat:@"无法连接 %@ (%@)",
                                  host, IAGDescribeNetworkError(modelsError)];
        } else if (modelsError && IAGIsAuthError(modelsError, statusCode)) {
            networkStep.ok = YES;
            networkStep.ms = networkMs;
            networkStep.detail = [NSString stringWithFormat:@"已连通 %@（HTTP %ld）", host, (long)statusCode];
            authFailed = YES;
            authStep.ok = NO;
            authStep.ms = networkMs;
            authStep.detail = IAGCollapseWhitespace(modelsError.localizedDescription ?: @"鉴权失败");
        } else if (modelsError) {
            networkStep.ok = YES;
            networkStep.ms = networkMs;
            networkStep.detail = [NSString stringWithFormat:@"已连通 %@（HTTP %ld）", host, (long)statusCode];
            authStep.ok = NO;
            authStep.ms = networkMs;
            authStep.detail = IAGCollapseWhitespace(modelsError.localizedDescription ?: @"/models 请求失败");
        } else {
            networkStep.ok = YES;
            networkStep.ms = networkMs;
            networkStep.detail = [NSString stringWithFormat:@"已连通 %@（HTTP %ld，%ld ms）",
                                  host, (long)statusCode, (long)networkMs];
            authStep.ok = YES;
            authStep.ms = networkMs;
            authStep.detail = [NSString stringWithFormat:@"HTTP %ld，Authorization 已接受", (long)statusCode];
        }

        [steps addObject:networkStep];
        [steps addObject:authStep];

        if (connectionFailed) {
            listStep.ok = NO;
            listStep.ms = 0;
            listStep.detail = @"未执行（上一步失败）";
            [steps addObject:listStep];

            verdict = [NSString stringWithFormat:@"不可用：网络不通（%@）", host];
            hint = [NSString stringWithFormat:
                    @"检查 Base URL 是否写错（当前 %@）、设备网络是否可用；错误详情：%@",
                    baseURL, IAGDescribeNetworkError(modelsError)];
        } else if (authFailed) {
            listStep.ok = NO;
            listStep.ms = 0;
            listStep.detail = @"未执行（上一步失败）";
            [steps addObject:listStep];

            verdict = [NSString stringWithFormat:@"不可用：鉴权失败 (HTTP %ld)", (long)statusCode];
            hint = @"检查 API Key 是否正确、是否有该模型的权限（中转端点还要确认它是否支持 /models 接口）";
        } else if (modelsError) {
            listStep.ok = NO;
            listStep.ms = 0;
            listStep.detail = IAGCollapseWhitespace(modelsError.localizedDescription ?: @"/models 请求失败");
            [steps addObject:listStep];

            verdict = [NSString stringWithFormat:@"不可用：/models 接口异常 (HTTP %ld)", (long)statusCode];
            hint = [NSString stringWithFormat:
                    @"确认 Base URL 是否需要带 /v1（当前 %@）；有些中转不提供 /models，"
                    @"此时可以跳过这一步，直接看最后一步「流式对话」的结果", baseURL];
        } else {
            [models addObjectsFromArray:fetched ?: @[]];

            BOOL found = NO;
            for (NSString *identifier in models) {
                if ([identifier isEqualToString:model] ||
                    [identifier caseInsensitiveCompare:model] == NSOrderedSame) {
                    found = YES;
                    break;
                }
            }

            if (found) {
                listStep.ok = YES;
                listStep.ms = networkMs;
                listStep.detail = [NSString stringWithFormat:@"发现 %lu 个模型，包含 %@",
                                   (unsigned long)models.count, model];
            } else {
                listStep.ok = NO;
                listStep.ms = networkMs;
                listStep.detail = [NSString stringWithFormat:@"发现 %lu 个模型，但没有 %@",
                                   (unsigned long)models.count, model];

                NSUInteger suggestionCount = MIN(models.count, kIAGCheckHintModelCount);
                NSArray<NSString *> *suggestions = suggestionCount > 0
                    ? [models subarrayWithRange:NSMakeRange(0, suggestionCount)] : @[];
                verdict = [NSString stringWithFormat:@"不可用：模型名 %@ 不在端点提供的列表里", model];
                hint = suggestions.count
                    ? [NSString stringWithFormat:@"可用模型（前 %lu 个）：%@",
                       (unsigned long)suggestions.count, [suggestions componentsJoinedByString:@", "]]
                    : @"该端点没有返回任何可用模型，检查 Base URL 是否正确（是否需要 /v1）";
            }
            [steps addObject:listStep];

            // ---------- 5. 流式对话 ----------
            if (listStep.ok) {
                IAGModelCheckStep *streamStep = [[IAGModelCheckStep alloc] init];
                streamStep.name = @"流式对话";

                NSInteger firstDeltaMs = 0, totalMs = 0, probeStatus = 0;
                BOOL sawSSE = NO;
                NSError *probeError = nil;
                @try {
                    [IAGLLM probeStreamingWithBaseURL:baseURL
                                               apiKey:apiKey
                                                model:model
                                         firstDeltaMs:&firstDeltaMs
                                              totalMs:&totalMs
                                          sawSSEEvent:&sawSSE
                                           statusCode:&probeStatus
                                                error:&probeError];
                } @catch (NSException *exception) {
                    probeError = [NSError errorWithDomain:@"iagent.llm" code:-1
                                                 userInfo:@{ NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"流式请求异常: %@",
                                                      exception.reason ?: @"未知"] }];
                    IAGLogError(@"模型体检：流式请求异常: %@", exception.reason ?: @"未知");
                }

                streamStep.ms = totalMs;
                if (sawSSE && firstDeltaMs > 0) {
                    streamStep.ok = YES;
                    streamStep.detail = [NSString stringWithFormat:@"首字 %ld ms，本次请求 %ld ms",
                                         (long)firstDeltaMs, (long)totalMs];
                    verdict = [NSString stringWithFormat:@"可用：%@ 流式对话正常", model];
                    hint = @"";
                    overallOK = YES;
                } else if (probeStatus == 200) {
                    streamStep.ok = NO;
                    streamStep.detail = @"端点返回 200 但没有 SSE 数据（可能不支持流式）";
                    verdict = [NSString stringWithFormat:@"不可用：%@ 的端点不返回流式数据", model];
                    hint = @"换一个支持 stream:true 的端点（或关闭流式），"
                           @"部分中转会忽略 stream 参数直接返回整段 JSON";
                } else {
                    streamStep.ok = NO;
                    NSString *reason = probeError
                        ? IAGDescribeNetworkError(probeError)
                        : [NSString stringWithFormat:@"HTTP %ld 且没有收到流式内容", (long)probeStatus];
                    streamStep.detail = [NSString stringWithFormat:@"HTTP %ld，%@",
                                         (long)probeStatus, reason];
                    verdict = [NSString stringWithFormat:@"不可用：流式对话失败 (HTTP %ld)", (long)probeStatus];
                    hint = probeError
                        ? [NSString stringWithFormat:@"%@；检查模型名、max_tokens 等参数是否被端点接受", reason]
                        : @"检查模型名是否正确、该 key 是否有调用权限";
                }
                [steps addObject:streamStep];
            } else {
                IAGModelCheckStep *streamStep = [[IAGModelCheckStep alloc] init];
                streamStep.name = @"流式对话";
                streamStep.ok = NO;
                streamStep.ms = 0;
                streamStep.detail = @"未执行（上一步失败）";
                [steps addObject:streamStep];
            }
        }
    }

    // 失败短路时补齐后面的步骤，保证 steps 数组永远是 5 项、顺序固定。
    NSArray<NSString *> *expectedOrder = @[ @"配置检查", @"网络连通", @"接口鉴权", @"模型列表", @"流式对话" ];
    for (NSString *name in expectedOrder) {
        BOOL present = NO;
        for (IAGModelCheckStep *step in steps) {
            if ([step.name isEqualToString:name]) { present = YES; break; }
        }
        if (present) continue;

        IAGModelCheckStep *placeholder = [[IAGModelCheckStep alloc] init];
        placeholder.name = name;
        placeholder.ok = NO;
        placeholder.ms = 0;
        placeholder.detail = @"未执行（上一步失败）";
        [steps addObject:placeholder];
    }
    [steps sortUsingComparator:^NSComparisonResult(IAGModelCheckStep *a, IAGModelCheckStep *b) {
        NSUInteger indexA = [expectedOrder indexOfObject:a.name];
        NSUInteger indexB = [expectedOrder indexOfObject:b.name];
        if (indexA == indexB) return NSOrderedSame;
        return indexA < indexB ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSMutableArray *stepsJSON = [NSMutableArray array];
    for (IAGModelCheckStep *step in steps) [stepsJSON addObject:[step json]];

    result[@"ok"] = @(overallOK);
    result[@"verdict"] = verdict;
    result[@"hint"] = hint;
    result[@"steps"] = stepsJSON;
    result[@"models"] = [models copy];

    // 一行摘要落日志：用户报"用不了"时，IAGLogPath() 里直接能看到结论。
    IAGLogInfo(@"模型体检: %@ | baseUrl=%@ model=%@ key=%@ | %@",
               overallOK ? @"通过" : @"未通过", baseURL, model, IAGMaskKey(apiKey), verdict);

    return result;
}

@end
