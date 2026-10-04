//
//  IAGToolShell.m
//  iAgent
//
//  shell_exec  — run a command through /bin/sh -c on the device
//  http_fetch  — fetch a URL and hand readable text back to the model
//

#import "IAGTool.h"
#import "IAGConfig.h"
#import "IAGProcess.h"
#import "IAGPaths.h"
#import "IAGUtil.h"
#import "IAGJSON.h"
#import "IAGLog.h"

#pragma mark - shell_exec

@interface IAGToolShellExec : NSObject <IAGTool>
@end

@implementation IAGToolShellExec

+ (NSString *)toolName { return @"shell_exec"; }

+ (NSString *)toolDescription
{
    return @"在这台 iOS 设备上执行一条 shell 命令（通过 /bin/sh -c，支持管道、重定向、变量）。"
            "返回退出码、标准输出与标准错误。没有交互式 TTY：需要交互的程序（top、vi、ssh 登录等）"
            "要用非交互参数（如 `top -l 1`、`ssh -o BatchMode=yes`）。"
            @"越狱根目录请用环境变量 $IAG_JBROOT（例如 \"$IAG_JBROOT/usr/bin\"），不要硬编码 /var/jb。";
}

+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"command": @{ @"type": @"string", @"description": @"要执行的 shell 命令" },
            @"cwd": @{ @"type": @"string", @"description": @"工作目录，默认使用设置里的工作目录" },
            @"timeout": @{ @"type": @"integer", @"description": @"超时秒数，默认取设置值（最长 1800）" },
        },
        @"required": @[ @"command" ],
    };
}

+ (NSString *)category { return @"shell"; }
+ (BOOL)isDangerous { return YES; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *command = IAGDictString(arguments, @"command", @"");
    if (command.length == 0) return IAGToolFailure(@"缺少 command 参数");

    NSString *cwd = IAGDictString(arguments, @"cwd", nil);
    if (cwd.length == 0) cwd = [context.config workDir];
    if (!IAGPathIsDirectory(cwd)) {
        // Fall back rather than failing: a missing cwd is usually a model slip.
        cwd = IAGPathIsDirectory([context.config workDir]) ? [context.config workDir] : @"/var/mobile";
    }

    NSInteger timeout = IAGDictInteger(arguments, @"timeout", 0);
    if (timeout <= 0) timeout = [context.config shellTimeout];
    if (timeout > 1800) timeout = 1800;

    IAGProcessResult *result = [IAGProcess runShell:command
                                          directory:cwd
                                            timeout:(NSTimeInterval)timeout
                                          maxOutput:512 * 1024
                                        environment:nil];

    if (result.launchError.length) {
        return IAGToolFailure([NSString stringWithFormat:@"命令启动失败: %@", result.launchError]);
    }

    NSMutableString *output = [NSMutableString string];
    [output appendFormat:@"exit_code: %ld\n", (long)result.exitCode];
    [output appendFormat:@"duration: %.2fs\n", result.duration];
    [output appendFormat:@"cwd: %@\n", cwd];
    if (result.timedOut) {
        [output appendFormat:@"timeout: 是（超过 %ld 秒后已被 SIGKILL）\n", (long)timeout];
    }
    if (result.outputTruncated) [output appendString:@"note: 输出超过 512KB，已截断\n"];

    NSString *stdoutText = result.standardOutput ?: @"";
    NSString *stderrText = result.standardError ?: @"";
    if (stdoutText.length) {
        [output appendFormat:@"\n--- stdout ---\n%@", stdoutText];
    }
    if (stderrText.length) {
        [output appendFormat:@"\n--- stderr ---\n%@", stderrText];
    }
    if (stdoutText.length == 0 && stderrText.length == 0) {
        [output appendString:@"\n(无输出)"];
    }

    return IAGToolSuccess(IAGTruncateForModel(output, 24000));
}

@end

#pragma mark - http_fetch

@interface IAGToolHTTPFetch : NSObject <IAGTool>
@end

@implementation IAGToolHTTPFetch

+ (NSString *)toolName { return @"http_fetch"; }

+ (NSString *)toolDescription
{
    return @"发起一次 HTTP 请求并返回响应（默认 GET）。HTML 会被转换成纯文本后再返回，"
            "因此可以直接用来阅读网页内容。用于查询接口、下载小文件、确认网络连通性。";
}

+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"url": @{ @"type": @"string", @"description": @"完整 URL，必须包含 http:// 或 https://" },
            @"method": @{ @"type": @"string", @"description": @"HTTP 方法，默认 GET",
                          @"enum": @[ @"GET", @"POST", @"PUT", @"PATCH", @"DELETE", @"HEAD" ] },
            @"headers": @{ @"type": @"object", @"description": @"额外请求头（键值都是字符串）" },
            @"body": @{ @"type": @"string", @"description": @"请求体（POST/PUT 时使用）" },
            @"timeout": @{ @"type": @"integer", @"description": @"超时秒数，默认 30" },
            @"max_bytes": @{ @"type": @"integer", @"description": @"最多读取的字节数，默认 262144" },
        },
        @"required": @[ @"url" ],
    };
}

+ (NSString *)category { return @"http"; }
+ (BOOL)isDangerous { return NO; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *urlString = IAGDictString(arguments, @"url", @"");
    if (urlString.length == 0) return IAGToolFailure(@"缺少 url 参数");
    if (![urlString hasPrefix:@"http://"] && ![urlString hasPrefix:@"https://"]) {
        urlString = [@"https://" stringByAppendingString:urlString];
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return IAGToolFailure([NSString stringWithFormat:@"URL 无效: %@", urlString]);

    NSString *method = [IAGDictString(arguments, @"method", @"GET") uppercaseString];
    NSInteger timeout = IAGDictInteger(arguments, @"timeout", 30);
    if (timeout <= 0) timeout = 30;
    if (timeout > 300) timeout = 300;
    NSInteger maxBytes = IAGDictInteger(arguments, @"max_bytes", 262144);
    if (maxBytes < 1024) maxBytes = 1024;
    if (maxBytes > 4 * 1024 * 1024) maxBytes = 4 * 1024 * 1024;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    request.timeoutInterval = timeout;
    [request setValue:@"iAgent/1.0 (iOS; +on-device agent)" forKey:@"User-Agent"];
    [request setValue:@"text/html,application/json,text/plain,*/*" forKey:@"Accept"];

    NSDictionary *headers = IAGDictDictionary(arguments, @"headers");
    for (NSString *key in headers) {
        id value = headers[key];
        if ([value isKindOfClass:[NSString class]]) [request setValue:value forKey:key];
    }

    NSString *body = IAGDictString(arguments, @"body", nil);
    if (body.length) {
        request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
        if (!headers[@"Content-Type"] && !headers[@"content-type"]) {
            [request setValue:@"application/json" forKey:@"Content-Type"];
        }
    }

    __block NSData *responseData = nil;
    __block NSURLResponse *responseObject = nil;
    __block NSError *transportError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:request
                                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            responseData = data;
            responseObject = response;
            transportError = error;
            dispatch_semaphore_signal(semaphore);
        }];
    [task resume];

    long waited = dispatch_semaphore_wait(semaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 10) * NSEC_PER_SEC)));
    if (waited != 0) {
        [task cancel];
        return IAGToolFailure([NSString stringWithFormat:@"请求超时（%ld 秒）: %@", (long)timeout, urlString]);
    }
    if (transportError) {
        return IAGToolFailure([NSString stringWithFormat:@"请求失败: %@", transportError.localizedDescription]);
    }

    NSInteger status = [responseObject isKindOfClass:[NSHTTPURLResponse class]]
        ? ((NSHTTPURLResponse *)responseObject).statusCode : 0;
    NSDictionary *responseHeaders = [responseObject isKindOfClass:[NSHTTPURLResponse class]]
        ? ((NSHTTPURLResponse *)responseObject).allHeaderFields : @{};
    NSString *contentType = @"";
    for (NSString *key in responseHeaders) {
        if ([[key lowercaseString] isEqualToString:@"content-type"]) {
            contentType = IAGStringOrEmpty(responseHeaders[key]);
            break;
        }
    }

    NSData *slice = responseData.length > (NSUInteger)maxBytes
        ? [responseData subdataWithRange:NSMakeRange(0, (NSUInteger)maxBytes)] : responseData;
    NSUInteger consumed = 0;
    NSString *text = IAGStringFromUTF8Lossy(slice ?: [NSData data], &consumed);

    NSString *lowerContentType = [contentType lowercaseString];
    BOOL isHTML = [lowerContentType containsString:@"html"];
    BOOL isText = isHTML || [lowerContentType containsString:@"text"] ||
                  [lowerContentType containsString:@"json"] || [lowerContentType containsString:@"xml"] ||
                  contentType.length == 0;

    NSMutableString *output = [NSMutableString string];
    [output appendFormat:@"status: %ld\n", (long)status];
    [output appendFormat:@"url: %@\n", url.absoluteString];
    if (contentType.length) [output appendFormat:@"content_type: %@\n", contentType];
    [output appendFormat:@"bytes: %lu%@\n", (unsigned long)(responseData.length),
                        responseData.length > (NSUInteger)maxBytes ? @" (已截断)" : @""];

    if (!isText) {
        [output appendFormat:@"\n(二进制响应，%lu 字节，未作为文本返回)", (unsigned long)(responseData.length)];
        return IAGToolSuccess(output);
    }

    NSString *payload = isHTML ? IAGHTMLToText(text) : text;
    if (payload.length == 0) payload = @"(空响应)";
    [output appendFormat:@"\n--- body ---\n%@", payload];

    return IAGToolSuccess(IAGTruncateForModel(output, 24000));
}

@end

#pragma mark - registration

void IAGRegisterShellTools(IAGToolRegistry *registry)
{
    [registry registerToolClass:[IAGToolShellExec class]];
    [registry registerToolClass:[IAGToolHTTPFetch class]];
}
