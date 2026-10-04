//
//  IAGConfig.m
//  iAgent
//

#import "IAGConfig.h"
#import "IAGPaths.h"
#import "IAGJSON.h"
#import "IAGLog.h"
#import "IAGVersion.h"

#import <sys/stat.h>
#import <unistd.h>

NSString *const kIAGKeyBaseURL          = @"baseUrl";
NSString *const kIAGKeyAPIKey           = @"apiKey";
NSString *const kIAGKeyModel            = @"model";
NSString *const kIAGKeyTemperature      = @"temperature";
NSString *const kIAGKeyMaxTokens        = @"maxTokens";
NSString *const kIAGKeySystemPrompt     = @"systemPrompt";
NSString *const kIAGKeyPort             = @"port";
NSString *const kIAGKeyAuthToken        = @"authToken";
NSString *const kIAGKeyApprovalMode     = @"approvalMode";
NSString *const kIAGKeyMaxSteps         = @"maxSteps";
NSString *const kIAGKeyShellTimeout     = @"shellTimeout";
NSString *const kIAGKeyWorkDir          = @"workDir";
NSString *const kIAGKeyToolsEnabled     = @"toolsEnabled";
NSString *const kIAGKeyRequestLogging   = @"requestLogging";
NSString *const kIAGKeyLogLevel         = @"logLevel";
NSString *const kIAGKeyOpenInSafari     = @"openInSafari";
NSString *const kIAGKeyHistoryLimit     = @"historyLimit";
NSString *const kIAGKeyBlockedCommands  = @"blockedCommands";
NSString *const kIAGKeyTopButtonSide    = @"bubbleSide";

static NSString *const kIAGDefaultSystemPrompt =
    @"你是 iAgent，一个运行在 iOS 设备上的原生 AI Agent。你可以通过工具直接操作这台已越狱的 iPhone。\n"
    @"\n"
    @"工作原则：\n"
    @"1. 先了解现状再行动：不确定路径、进程或文件是否存在时，先用 shell_exec 或 fs_list 确认，不要猜测。\n"
    @"2. 用最小代价完成任务：优先用一条精确的命令，而不是一串试探性命令。\n"
    @"3. 每一步都基于上一步的真实输出，命令执行失败时必须读取 stderr 并修正，不要重复执行同样的失败命令。\n"
    @"4. 只有在确实需要操作图形界面时才使用 ui_* 工具；能用 shell 或文件工具完成的，不要用界面自动化。\n"
    @"5. 涉及删除、覆盖、重启、杀进程、修改系统配置等破坏性操作时，先简要说明你要做什么，再执行。\n"
    @"6. 回答用简体中文，简洁、直接，给出实际执行的命令和关键输出，不要编造未执行的结果。\n"
    @"\n"
    @"工具使用约定：\n"
    @"- shell_exec 的命令在 posix_spawn 的 /bin/sh -c 中执行，支持管道与重定向，但**没有交互式 TTY**；需要交互式会话时改用终端工具（用户界面上的终端页）。\n"
    @"- 长输出会被截断，必要时用 head/tail/grep 缩小范围。\n"
    @"- 当任务需要多步时，一次只调用必要的工具，看到结果后再决定下一步。";

@interface IAGConfig ()
@property (nonatomic, strong) NSMutableDictionary *values;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation IAGConfig

+ (instancetype)shared
{
    static IAGConfig *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IAGConfig alloc] init]; });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _values = [NSMutableDictionary dictionary];
        [self loadDefaults];
        [self reload];
    }
    return self;
}

#pragma mark - defaults & persistence

- (NSDictionary *)defaults
{
    return @{
        kIAGKeyBaseURL:        @"https://api.openai.com/v1",
        kIAGKeyAPIKey:         @"",
        kIAGKeyModel:          @"gpt-4o-mini",
        kIAGKeyTemperature:    @0.3,
        kIAGKeyMaxTokens:      @2048,
        kIAGKeySystemPrompt:   kIAGDefaultSystemPrompt,
        kIAGKeyPort:           @(IAG_DEFAULT_PORT),
        kIAGKeyAuthToken:      @"",
        kIAGKeyApprovalMode:   @"dangerous",
        kIAGKeyMaxSteps:       @12,
        kIAGKeyShellTimeout:   @30,
        kIAGKeyWorkDir:        @"/var/mobile",
        kIAGKeyToolsEnabled:   @{
            @"shell":  @YES,
            @"file":   @YES,
            @"app":    @YES,
            @"notify": @YES,
            @"cron":   @YES,
            @"ui":     @YES,
            @"http":   @YES,
        },
        kIAGKeyRequestLogging: @NO,
        kIAGKeyLogLevel:       @(IAGLogLevelInfo),
        kIAGKeyOpenInSafari:   @NO,
        kIAGKeyHistoryLimit:   @24,
        kIAGKeyTopButtonSide:  @"right",
        kIAGKeyBlockedCommands: @[
            @"rm -rf /",
            @"rm -rf /var",
            @"rm -rf /System",
            @"rm -rf /private",
            @"mkfs",
            @"dd if=/dev/zero of=/dev/disk",
            @":(){ :|:& };:",
            @"mv /System",
            @"chmod -R 000 /",
            @"nvram",
        ],
    };
}

- (void)loadDefaults
{
    [_values addEntriesFromDictionary:[self defaults]];
}

- (void)reload
{
    NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:IAGConfigPath()];
    [self.lock lock];
    [self loadDefaults];
    if ([disk isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in disk) {
            id value = disk[key];
            if (value == nil || value == [NSNull null]) continue;
            // Tools dict is merged key by key so new tools appear with defaults.
            if ([key isEqualToString:kIAGKeyToolsEnabled] && [value isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:_values[key]];
                [merged addEntriesFromDictionary:value];
                _values[key] = merged;
            } else {
                _values[key] = value;
            }
        }
    }
    [self.lock unlock];
}

- (void)save
{
    NSDictionary *copy;
    [self.lock lock];
    copy = [_values copy];
    [self.lock unlock];

    if (!IAGEnsureDirectory(IAGDataDir())) {
        IAGLogError(@"配置目录不可写: %@", IAGDataDir());
        return;
    }
    // writeToFile: returns NO for permission problems (the RootHide sandbox can
    // deny a tweak write); never let that take the process down.
    BOOL wrote = NO;
    @try {
        wrote = [copy writeToFile:IAGConfigPath() atomically:YES];
    } @catch (NSException *exception) {
        IAGLogWarn(@"配置写入异常: %@", exception.reason);
        wrote = NO;
    }
    if (!wrote) {
        IAGLogError(@"配置写入失败: %@", IAGConfigPath());
        return;
    }
    // The tweak runs as mobile and must be able to read it.
    chmod(IAGConfigPath().fileSystemRepresentation, 0644);
}

#pragma mark - accessors

- (NSDictionary *)snapshot
{
    [self.lock lock];
    NSDictionary *copy = [_values copy];
    [self.lock unlock];
    return copy;
}

- (NSString *)maskedApiKey
{
    NSString *key = [self stringForKey:kIAGKeyAPIKey fallback:@""];
    if (key.length == 0) return @"";
    if (key.length <= 10) return [NSString stringWithFormat:@"%@****", [key substringToIndex:2]];
    return [NSString stringWithFormat:@"%@…%@",
            [key substringToIndex:6], [key substringFromIndex:key.length - 4]];
}

- (NSDictionary *)publicSnapshot
{
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:[self snapshot]];
    NSString *key = IAGStringOrEmpty(out[kIAGKeyAPIKey]);
    out[kIAGKeyAPIKey] = @"";
    out[@"apiKeyMasked"] = [self maskedApiKey];
    out[@"hasApiKey"] = @(key.length > 0);
    return out;
}

- (NSArray<NSString *> *)applyPatch:(NSDictionary *)patch
{
    if (![patch isKindOfClass:[NSDictionary class]] || patch.count == 0) return @[];

    NSMutableArray<NSString *> *changed = [NSMutableArray array];
    [self.lock lock];
    for (NSString *key in patch) {
        // Never let the UI write computed/masked fields through.
        if ([key isEqualToString:@"apiKeyMasked"] || [key isEqualToString:@"hasApiKey"]) continue;

        id value = patch[key];
        // 密钥/长文本类字段：空字符串 = 保持不变，"__CLEAR__" = 清空。
        if ([key isEqualToString:kIAGKeyAPIKey] || [key isEqualToString:kIAGKeyAuthToken] ||
            [key isEqualToString:kIAGKeySystemPrompt]) {
            NSString *string = IAGStringOrEmpty(value);
            if (string.length == 0) continue;              // "leave unchanged"
            if ([string isEqualToString:@"__CLEAR__"]) string = @"";
            NSString *old = IAGStringOrEmpty(_values[key]);
            if ([old isEqualToString:string]) continue;
            _values[key] = string;
            [changed addObject:key];
            continue;
        }

        if (value == nil || value == [NSNull null]) continue;

        if ([key isEqualToString:kIAGKeyToolsEnabled] && [value isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:_values[key]];
            for (NSString *tool in value) merged[tool] = @(IAGDictBool(value, tool, YES));
            if ([merged isEqualToDictionary:_values[key]]) continue;
            _values[key] = merged;
            [changed addObject:key];
            continue;
        }

        // Clamp a few known ranges so a bad UI value cannot brick the daemon.
        if ([key isEqualToString:kIAGKeyPort]) {
            NSInteger port = IAGDictInteger(patch, key, IAG_DEFAULT_PORT);
            if (port < 1 || port > 65535) port = IAG_DEFAULT_PORT;
            value = @(port);
        } else if ([key isEqualToString:kIAGKeyMaxSteps]) {
            NSInteger steps = IAGDictInteger(patch, key, 12);
            value = @(MAX(1, MIN(50, steps)));
        } else if ([key isEqualToString:kIAGKeyShellTimeout]) {
            NSInteger timeout = IAGDictInteger(patch, key, 30);
            value = @(MAX(1, MIN(1800, timeout)));
        } else if ([key isEqualToString:kIAGKeyTemperature]) {
            double temp = IAGDictDouble(patch, key, 0.3);
            value = @(MAX(0.0, MIN(2.0, temp)));
        } else if ([key isEqualToString:kIAGKeyMaxTokens]) {
            NSInteger tokens = IAGDictInteger(patch, key, 2048);
            value = @(MAX(64, MIN(32000, tokens)));
        } else if ([key isEqualToString:kIAGKeyLogLevel]) {
            NSInteger level = IAGDictInteger(patch, key, IAGLogLevelInfo);
            value = @(MAX(0, MIN(3, level)));
        } else if ([key isEqualToString:kIAGKeyHistoryLimit]) {
            NSInteger limit = IAGDictInteger(patch, key, 24);
            value = @(MAX(2, MIN(200, limit)));
        }

        if ([_values[key] isEqual:value]) continue;
        _values[key] = value;
        [changed addObject:key];
    }

    BOOL logLevelChanged = [changed containsObject:kIAGKeyLogLevel];
    NSInteger newLevel = IAGDictInteger(_values, kIAGKeyLogLevel, IAGLogLevelInfo);
    [self.lock unlock];

    if (logLevelChanged) IAGLogSetLevel((IAGLogLevel)newLevel);
    if (changed.count) [self save];
    return changed;
}

- (NSString *)stringForKey:(NSString *)key fallback:(NSString *)fallback
{
    [self.lock lock];
    id value = _values[key];
    [self.lock unlock];
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return fallback;
}

- (NSInteger)integerForKey:(NSString *)key fallback:(NSInteger)fallback
{
    [self.lock lock];
    id value = _values[key];
    [self.lock unlock];
    if ([value isKindOfClass:[NSNumber class]]) return [value integerValue];
    if ([value isKindOfClass:[NSString class]]) return [value integerValue];
    return fallback;
}

- (double)doubleForKey:(NSString *)key fallback:(double)fallback
{
    [self.lock lock];
    id value = _values[key];
    [self.lock unlock];
    if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue];
    if ([value isKindOfClass:[NSString class]]) return [value doubleValue];
    return fallback;
}

- (BOOL)boolForKey:(NSString *)key fallback:(BOOL)fallback
{
    [self.lock lock];
    id value = _values[key];
    [self.lock unlock];
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [value lowercaseString];
        return [lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"] || [lower isEqualToString:@"1"];
    }
    return fallback;
}

- (NSString *)baseURL
{
    NSString *url = [self stringForKey:kIAGKeyBaseURL fallback:@"https://api.openai.com/v1"];
    while ([url hasSuffix:@"/"]) url = [url substringToIndex:url.length - 1];
    return url;
}

- (NSString *)apiKey          { return [self stringForKey:kIAGKeyAPIKey fallback:@""]; }
- (NSString *)model           { return [self stringForKey:kIAGKeyModel fallback:@"gpt-4o-mini"]; }
- (NSString *)approvalMode    { return [self stringForKey:kIAGKeyApprovalMode fallback:@"dangerous"]; }
- (NSInteger)port             { return [self integerForKey:kIAGKeyPort fallback:IAG_DEFAULT_PORT]; }
- (NSString *)authToken       { return [self stringForKey:kIAGKeyAuthToken fallback:@""]; }
- (NSInteger)maxSteps         { return [self integerForKey:kIAGKeyMaxSteps fallback:12]; }
- (NSInteger)shellTimeout     { return [self integerForKey:kIAGKeyShellTimeout fallback:30]; }
- (NSString *)workDir         { return [self stringForKey:kIAGKeyWorkDir fallback:@"/var/mobile"]; }
- (NSInteger)historyLimit     { return [self integerForKey:kIAGKeyHistoryLimit fallback:24]; }
- (BOOL)requestLogging        { return [self boolForKey:kIAGKeyRequestLogging fallback:NO]; }
- (NSString *)systemPrompt    { return [self stringForKey:kIAGKeySystemPrompt fallback:kIAGDefaultSystemPrompt]; }

- (BOOL)toolEnabled:(NSString *)toolName
{
    [self.lock lock];
    NSDictionary *tools = _values[kIAGKeyToolsEnabled];
    [self.lock unlock];
    if (![tools isKindOfClass:[NSDictionary class]]) return YES;
    id value = tools[toolName];
    if (value == nil) return YES;
    return [value boolValue];
}

- (NSArray<NSString *> *)blockedCommandPatterns
{
    [self.lock lock];
    NSArray *patterns = _values[kIAGKeyBlockedCommands];
    [self.lock unlock];
    return [patterns isKindOfClass:[NSArray class]] ? patterns : @[];
}

- (NSString *)effectiveSystemPrompt
{
    NSMutableString *prompt = [NSMutableString stringWithString:[self systemPrompt]];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    NSString *name = IAGDeviceName();
    [prompt appendFormat:
        @"\n\n--- 运行环境（由 iAgent 自动注入，实时准确）---\n"
        @"设备：%@ (%@)%@\n"
        @"系统：iOS %@\n"
        @"越狱环境：%@（RootHide/Dopamine 等 rootless 布局；jailbreak root = %@）\n"
        @"进程身份：%@%@\n"
        @"工作目录：%@\n"
        @"当前时间：%@\n"
        @"可用工具：shell_exec、fs_read/fs_write/fs_list/fs_search、app_list/app_launch、"
        @"notify_send、cron_add/cron_list/cron_remove、ui_describe/ui_tap/ui_type/ui_swipe/ui_open_url、http_fetch\n"
        @"注意：iOS 上的 shell 是 busybox/bash 混合环境，部分 GNU 参数不存在（例如没有 `--help`、`sed -i` 需带后缀）；"
        @"越狱 root 路径不要硬编码，使用 `IAG_JBROOT` 环境变量或上面给出的 jailbreak root。\n",
        IAGDeviceModelName(), IAGDeviceModelIdentifier(),
        name.length ? [NSString stringWithFormat:@"（%@）", name] : @"",
        IAGSystemVersion(),
        IAGIsRootless() ? @"rootless" : @"rootful",
        IAGJailbreakRoot(),
        IAGUserName(),
        IAGIsRoot() ? @"（拥有 root 权限，可操作受保护路径）" : @"（普通用户权限，需要 root 的操作请先用 sudo 或提示用户）",
        [self workDir],
        [formatter stringFromDate:[NSDate date]]];

    return prompt;
}

@end
