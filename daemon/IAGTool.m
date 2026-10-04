//
//  IAGTool.m
//  iAgent
//

#import "IAGTool.h"
#import "IAGConfig.h"
#import "IAGBridge.h"
#import "IAGJSON.h"
#import "IAGLog.h"

// Per-category registration entry points (defined in the IAGTool*.m files).
void IAGRegisterShellTools(IAGToolRegistry *registry);
void IAGRegisterFileTools(IAGToolRegistry *registry);
void IAGRegisterDeviceTools(IAGToolRegistry *registry);

NSDictionary *IAGToolSuccess(NSString *output)
{
    return @{ @"ok": @YES, @"output": output ?: @"" };
}

NSDictionary *IAGToolFailure(NSString *error)
{
    return @{ @"ok": @NO, @"error": error ?: @"工具执行失败", @"output": @"" };
}

#pragma mark - context

@implementation IAGToolContext

+ (instancetype)contextWithConfig:(IAGConfig *)config
                        sessionId:(NSString *)sessionId
                           bridge:(IAGBridge *)bridge
{
    IAGToolContext *context = [[IAGToolContext alloc] init];
    context.config = config;
    context.sessionId = sessionId;
    context.bridge = bridge;
    return context;
}

@end

#pragma mark - registry

@interface IAGToolRegistry ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, Class> *classes;
@end

@implementation IAGToolRegistry

+ (instancetype)shared
{
    static IAGToolRegistry *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IAGToolRegistry alloc] init]; });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _classes = [NSMutableDictionary dictionary];
        [self registerDefaults];
    }
    return self;
}

- (void)registerToolClass:(Class)toolClass
{
    if (!toolClass || ![toolClass conformsToProtocol:@protocol(IAGTool)]) return;
    NSString *name = [toolClass toolName];
    if (name.length == 0) return;
    self.classes[name] = toolClass;
    IAGLogDebug(@"注册工具: %@ (类别 %@)", name, [toolClass category]);
}

- (void)registerDefaults
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        IAGRegisterShellTools(self);
        IAGRegisterFileTools(self);
        IAGRegisterDeviceTools(self);
        IAGLogInfo(@"已注册 %lu 个工具", (unsigned long)self.classes.count);
    });
}

#pragma mark definitions

- (NSArray<NSDictionary *> *)openAIToolDefinitionsWithConfig:(IAGConfig *)config
{
    NSMutableArray *definitions = [NSMutableArray array];
    NSArray<NSString *> *names = [self.classes.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        Class toolClass = self.classes[name];
        NSString *category = [toolClass category];
        if (config && ![config toolEnabled:category]) continue;

        NSMutableDictionary *function = [NSMutableDictionary dictionary];
        function[@"name"] = name;
        function[@"description"] = [toolClass toolDescription] ?: @"";
        NSDictionary *schema = [toolClass parametersSchema];
        function[@"parameters"] = schema ?: @{ @"type": @"object", @"properties": @{} };
        [definitions addObject:@{ @"type": @"function", @"function": function }];
    }
    return definitions;
}

- (NSArray<NSDictionary *> *)toolListWithConfig:(IAGConfig *)config
{
    NSMutableArray *list = [NSMutableArray array];
    NSArray<NSString *> *names = [self.classes.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        Class toolClass = self.classes[name];
        NSString *category = [toolClass category];
        [list addObject:@{
            @"name": name,
            @"description": [toolClass toolDescription] ?: @"",
            @"category": category ?: @"",
            @"dangerous": @([toolClass isDangerous]),
            @"enabled": @(config ? [config toolEnabled:category] : YES),
            @"parameters": [toolClass parametersSchema] ?: @{},
        }];
    }
    return list;
}

#pragma mark execution

- (NSDictionary *)executeTool:(NSString *)name
                    arguments:(NSDictionary *)arguments
                      context:(IAGToolContext *)context
{
    Class toolClass = self.classes[name];
    if (!toolClass) {
        return IAGToolFailure([NSString stringWithFormat:@"未知工具: %@", name ?: @"(nil)"]);
    }

    NSTimeInterval started = [NSDate date].timeIntervalSince1970;
    NSDictionary *result = nil;
    @try {
        result = [toolClass executeWithArguments:arguments ?: @{} context:context];
    } @catch (NSException *exception) {
        IAGLogError(@"工具 %@ 抛出异常: %@", name, exception.reason);
        result = IAGToolFailure([NSString stringWithFormat:@"工具内部异常: %@", exception.reason ?: @"unknown"]);
    }
    if (![result isKindOfClass:[NSDictionary class]]) {
        result = IAGToolFailure(@"工具返回值格式错误");
    }

    NSMutableDictionary *enriched = [result mutableCopy];
    enriched[@"name"] = name;
    enriched[@"dangerous"] = @([toolClass isDangerous]);
    enriched[@"durationMs"] = @((NSInteger)(([NSDate date].timeIntervalSince1970 - started) * 1000.0));
    if (enriched[@"ok"] == nil) enriched[@"ok"] = @NO;
    return enriched;
}

- (BOOL)toolExists:(NSString *)name
{
    return name.length ? self.classes[name] != nil : NO;
}

- (BOOL)isDangerousTool:(NSString *)name
{
    Class toolClass = self.classes[name];
    return toolClass ? [toolClass isDangerous] : NO;
}

- (NSString *)categoryForTool:(NSString *)name
{
    return [self.classes[name] category];
}

- (NSString *)descriptionForTool:(NSString *)name
{
    return [self.classes[name] toolDescription];
}

#pragma mark approval policy

+ (BOOL)commandLooksDangerous:(NSString *)command
{
    if (command.length == 0) return NO;
    NSString *lower = [command lowercaseString];

    NSArray<NSString *> *patterns = @[
        @"rm -rf /", @"rm -fr /", @"rm -r /", @"rm -rf ~", @"rm -rf /var", @"rm -rf /system",
        @"rm -rf /private", @"rm -rf /applications", @"rm -rf /library",
        @"mkfs", @"dd if=", @"dd of=/dev/disk", @"> /dev/disk",
        @"shutdown", @"reboot", @"halt", @"sbreload", @"respring", @"userspaceReboot",
        @"launchctl bootout", @"launchctl unload", @"launchctl disable",
        @"killall -9", @"kill -9 1", @"killall springboard", @"killall backboardd",
        @"chmod -r 000", @"chown -r", @":(){", @"fork bomb",
        @"dpkg -r", @"dpkg --remove", @"apt remove", @"apt-get remove", @"sileo",
        @"nvram", @"mount -uw", @"mount -o rw", @"snapshot", @"erase all",
        @"passwd", @"/etc/passwd", @"sudo rm", @"sudo dd",
        @"mv /system", @"mv /var", @"mv /library",
        // Piping a download straight into a shell is the classic foot-gun; a
        // plain curl/wget is left alone so ordinary network use is not noisy.
        @"| sh", @"|sh", @"| bash", @"|bash", @"| zsh",
        @"curl -o /", @"curl -O /", @"wget -O /", @"wget -o /",
        @"ssh ", @"scp ",
    ];

    for (NSString *pattern in patterns) {
        if ([lower containsString:pattern]) return YES;
    }

    // A bare `>` redirect to a system path is destructive too.
    if ([lower containsString:@" >/"] || [lower containsString:@" > /"]) return YES;

    return NO;
}

- (NSString *)blockedReasonForTool:(NSString *)name
                         arguments:(NSDictionary *)arguments
                            config:(IAGConfig *)config
{
    if ([name isEqualToString:@"shell_exec"]) {
        NSString *command = IAGDictString(arguments, @"command", @"");
        NSString *lower = [command lowercaseString];
        for (NSString *pattern in [config blockedCommandPatterns]) {
            if ([lower containsString:[pattern lowercaseString]]) {
                return [NSString stringWithFormat:@"命令命中不可执行黑名单规则「%@」", pattern];
            }
        }
    }
    return nil;
}

- (NSString *)approvalReasonForTool:(NSString *)name
                          arguments:(NSDictionary *)arguments
                             config:(IAGConfig *)config
{
    NSString *mode = [config approvalMode];
    BOOL dangerousTool = [self isDangerousTool:name];

    if ([mode isEqualToString:@"always"]) {
        return @"审批模式为「全部确认」";
    }
    if (![mode isEqualToString:@"dangerous"]) {
        return nil;   // auto
    }

    if ([name isEqualToString:@"shell_exec"]) {
        NSString *command = IAGDictString(arguments, @"command", @"");
        if ([[self class] commandLooksDangerous:command]) {
            return @"命令疑似具有破坏性（删除/重启/系统目录写入等）";
        }
        return nil;
    }

    if ([name isEqualToString:@"fs_delete"]) {
        return @"删除文件";
    }
    if ([name isEqualToString:@"fs_write"]) {
        // 必须在"展开之前"的原始路径上判断：~ / $IAG_JBROOT / 相对路径同样可能
        // 落到系统目录，只查 /System|/private 前缀会被绕过。
        NSString *path = IAGDictString(arguments, @"path", @"");
        BOOL jailbreakRoot = ([path hasPrefix:@"$IAG_JBROOT"] || [path hasPrefix:@"${IAG_JBROOT}"]);
        BOOL relative = !([path hasPrefix:@"/"] || [path hasPrefix:@"~"] || jailbreakRoot);
        if (jailbreakRoot) {
            return [NSString stringWithFormat:@"写入越狱根目录内的路径 %@", path];
        }
        if ([path hasPrefix:@"/System"] || [path hasPrefix:@"/var/jb/Library"] ||
            [path hasPrefix:@"/private"]) {
            return [NSString stringWithFormat:@"写入系统路径 %@", path];
        }
        if (relative) {
            return [NSString stringWithFormat:@"写入相对路径 %@（目标由 workDir 决定）", path];
        }
        return nil;
    }
    if ([name hasPrefix:@"ui_"]) {
        return @"将操作设备界面（模拟点击/输入）";
    }
    if ([name isEqualToString:@"app_launch"] && dangerousTool) {
        return @"启动应用";
    }
    if ([name isEqualToString:@"cron_add"]) {
        return @"创建定时任务（将在后台自动执行命令）";
    }
    if ([name isEqualToString:@"notify_send"]) {
        return nil;
    }
    return dangerousTool ? @"该工具被标记为高风险" : nil;
}

@end
