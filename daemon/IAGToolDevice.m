//
//  IAGToolDevice.m
//  iAgent
//
//  Device-facing tools:
//    app_list / app_launch          — LaunchServices (dlopen, no hard link)
//    notify_send                    — SpringBoard banner via the bridge, with a
//                                     CFUserNotification fallback
//    cron_add / cron_list / cron_remove
//    ui_describe / ui_tap / ui_type / ui_swipe / ui_open_url  — executed inside
//                                     SpringBoard by the tweak, because HID event
//                                     injection needs SpringBoard's entitlements
//

#import "IAGTool.h"
#import "IAGConfig.h"
#import "IAGBridge.h"
#import "IAGScheduler.h"
#import "IAGProcess.h"
#import "IAGPaths.h"
#import "IAGUtil.h"
#import "IAGJSON.h"
#import "IAGLog.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>

#pragma mark - LaunchServices bridge

static id IAGLSWorkspace(void)
{
    static Class workspaceClass = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *candidates[] = {
            // LSApplicationWorkspace lives in CoreServices on iOS 15/16; the
            // other two paths are opened as a safety net and dlopen failures
            // are silently ignored.
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            "/System/Library/PrivateFrameworks/CoreServices.framework/CoreServices",
            "/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices",
            "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
            "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
        };
        for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
            dlopen(candidates[i], RTLD_LAZY);
        }
        workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    });
    if (workspaceClass == Nil) return nil;
    static id workspace = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL selector = NSSelectorFromString(@"defaultWorkspace");
        if ([workspaceClass respondsToSelector:selector]) {
            workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, selector);
        }
    });
    return workspace;
}

static BOOL IAGLaunchBundleIdentifier(NSString *bundleIdentifier)
{
    id workspace = IAGLSWorkspace();
    if (workspace) {
        SEL selector = NSSelectorFromString(@"openApplicationWithBundleID:");
        if ([workspace respondsToSelector:selector]) {
            BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, selector, bundleIdentifier);
            if (ok) return YES;
        }
    }

    // Deliberately no raw SBSLaunchApplicationWithIdentifier fallback here: its
    // ABI differs between iOS releases and a wrong guess would take the root
    // daemon down. The SpringBoard tweak's launch_app action (tried first by the
    // caller) is the reliable path for anything LaunchServices refuses.
    return NO;
}

static BOOL IAGOpenURL(NSString *urlString)
{
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;

    id workspace = IAGLSWorkspace();
    if (workspace) {
        SEL sensitive = NSSelectorFromString(@"openSensitiveURL:withOptions:");
        if ([workspace respondsToSelector:sensitive]) {
            BOOL ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(workspace, sensitive, url, nil);
            if (ok) return YES;
        }
        SEL plain = NSSelectorFromString(@"openURL:");
        if ([workspace respondsToSelector:plain]) {
            BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, plain, url);
            if (ok) return YES;
        }
    }

    // Last resort: the jailbreak's `open` helper if one is installed.
    NSString *openTool = [IAGProcess which:@"open"];
    if (openTool) {
        IAGProcessResult *result = [IAGProcess runExecutable:openTool
                                                   arguments:@[ urlString ]
                                                   directory:nil
                                                     timeout:10
                                                   maxOutput:8192
                                                 environment:nil];
        return result.exitCode == 0;
    }
    return NO;
}

static NSArray<NSDictionary *> *IAGInstalledApplications(void)
{
    NSMutableArray<NSDictionary *> *applications = [NSMutableArray array];
    id workspace = IAGLSWorkspace();
    if (workspace) {
        SEL selector = NSSelectorFromString(@"allInstalledApplications");
        if (![workspace respondsToSelector:selector]) {
            selector = NSSelectorFromString(@"allApplications");
        }
        if ([workspace respondsToSelector:selector]) {
            NSArray *all = ((id (*)(id, SEL))objc_msgSend)(workspace, selector);
            for (id proxy in all) {
                NSString *bundleIdentifier = nil;
                NSString *name = nil;
                if ([proxy respondsToSelector:NSSelectorFromString(@"bundleIdentifier")]) {
                    bundleIdentifier = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"bundleIdentifier"));
                }
                if ([proxy respondsToSelector:NSSelectorFromString(@"localizedName")]) {
                    name = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"localizedName"));
                }
                if (![bundleIdentifier isKindOfClass:[NSString class]] || bundleIdentifier.length == 0) continue;
                [applications addObject:@{
                    @"bundleId": bundleIdentifier,
                    @"name": [name isKindOfClass:[NSString class]] ? name : @"",
                }];
            }
        }
    }

    if (applications.count == 0) {
        // Fallback: walk the app containers. Slower, but always available.
        NSArray<NSString *> *roots = @[
            @"/var/containers/Bundle/Application",
            @"/Applications",
            [IAGJailbreakRoot() stringByAppendingPathComponent:@"Applications"],
        ];
        NSFileManager *manager = [NSFileManager defaultManager];
        for (NSString *root in roots) {
            NSArray<NSString *> *entries = [manager contentsOfDirectoryAtPath:root error:NULL];
            for (NSString *entry in entries) {
                NSString *bundlePath = [root stringByAppendingPathComponent:entry];
                NSArray<NSString *> *inner = [manager contentsOfDirectoryAtPath:bundlePath error:NULL];
                for (NSString *candidate in inner) {
                    if (![candidate hasSuffix:@".app"]) continue;
                    NSString *infoPath = [[bundlePath stringByAppendingPathComponent:candidate]
                                          stringByAppendingPathComponent:@"Info.plist"];
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                    NSString *bundleIdentifier = IAGDictString(info, @"CFBundleIdentifier", nil);
                    if (bundleIdentifier.length == 0) continue;
                    NSString *name = IAGDictStringAny(info, @[ @"CFBundleDisplayName", @"CFBundleName" ], @"");
                    [applications addObject:@{ @"bundleId": bundleIdentifier, @"name": name }];
                }
            }
        }
    }

    [applications sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"bundleId"] compare:b[@"bundleId"]];
    }];
    return applications;
}

#pragma mark - app_list

@interface IAGToolAppList : NSObject <IAGTool>
@end

@implementation IAGToolAppList

+ (NSString *)toolName { return @"app_list"; }
+ (NSString *)toolDescription
{
    return @"列出这台设备上已安装的应用（bundle id 与显示名）。用于在 app_launch 之前确认正确的 bundle id。";
}
+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"filter": @{ @"type": @"string", @"description": @"可选：按 bundle id 或名称做不区分大小写的子串过滤" },
        },
    };
}
+ (NSString *)category { return @"app"; }
+ (BOOL)isDangerous { return NO; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *filter = [IAGDictString(arguments, @"filter", @"") lowercaseString];
    NSArray<NSDictionary *> *applications = IAGInstalledApplications();

    NSMutableString *output = [NSMutableString string];
    NSUInteger shown = 0;
    for (NSDictionary *application in applications) {
        NSString *bundleIdentifier = application[@"bundleId"];
        NSString *name = application[@"name"];
        if (filter.length) {
            if (![[bundleIdentifier lowercaseString] containsString:filter] &&
                ![[name lowercaseString] containsString:filter]) continue;
        }
        [output appendFormat:@"%@\t%@\n", bundleIdentifier, name];
        shown++;
        if (shown >= 400) break;
    }

    if (shown == 0) {
        return IAGToolSuccess([NSString stringWithFormat:@"没有找到匹配 %@ 的应用（共扫描到 %lu 个）",
                               filter.length ? filter : @"(全部)", (unsigned long)applications.count]);
    }
    return IAGToolSuccess([NSString stringWithFormat:@"共 %lu 个应用%@：\n%@",
                           (unsigned long)shown, filter.length ? @"（已过滤）" : @"", output]);
}

@end

#pragma mark - app_launch

@interface IAGToolAppLaunch : NSObject <IAGTool>
@end

@implementation IAGToolAppLaunch

+ (NSString *)toolName { return @"app_launch"; }
+ (NSString *)toolDescription
{
    return @"启动一个已安装的应用（按 bundle id），或打开一个 URL / URL Scheme。"
            "例如 app_launch bundle_id=com.apple.Preferences 打开设置，url=prefs:root=WIFI 直接跳到 WiFi 设置。";
}
+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"bundle_id": @{ @"type": @"string", @"description": @"应用的 bundle id（与 url 二选一）" },
            @"url": @{ @"type": @"string", @"description": @"要打开的 URL 或 scheme（与 bundle_id 二选一）" },
        },
    };
}
+ (NSString *)category { return @"app"; }
+ (BOOL)isDangerous { return NO; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *bundleIdentifier = IAGDictString(arguments, @"bundle_id", @"");
    NSString *urlString = IAGDictString(arguments, @"url", @"");

    if (bundleIdentifier.length == 0 && urlString.length == 0) {
        return IAGToolFailure(@"请提供 bundle_id 或 url 之一");
    }

    if (urlString.length) {
        if (IAGOpenURL(urlString)) {
            return IAGToolSuccess([NSString stringWithFormat:@"已打开 URL: %@", urlString]);
        }
        // A bare scheme can also be an app's scheme: try it through the bridge.
        NSDictionary *bridged = [context.bridge performAction:@"open_url"
                                                   parameters:@{ @"url": urlString }
                                                      timeout:8];
        if ([bridged[@"ok"] boolValue]) return bridged;
        return IAGToolFailure([NSString stringWithFormat:@"无法打开 URL: %@（%@）",
                               urlString, bridged[@"error"] ?: @"LaunchServices 拒绝"]);
    }

    if (IAGLaunchBundleIdentifier(bundleIdentifier)) {
        return IAGToolSuccess([NSString stringWithFormat:@"已启动 %@", bundleIdentifier]);
    }
    NSDictionary *bridged = [context.bridge performAction:@"launch_app"
                                               parameters:@{ @"bundle_id": bundleIdentifier }
                                                  timeout:8];
    if ([bridged[@"ok"] boolValue]) return bridged;
    return IAGToolFailure([NSString stringWithFormat:@"无法启动 %@（%@）",
                           bundleIdentifier, bridged[@"error"] ?: @"未找到该应用或系统拒绝"]);
}

@end

#pragma mark - notify_send

@interface IAGToolNotifySend : NSObject <IAGTool>
@end

@implementation IAGToolNotifySend

+ (NSString *)toolName { return @"notify_send"; }
+ (NSString *)toolDescription
{
    return @"在设备上弹出一条可见提示（横幅/弹窗），用于提醒用户注意。"
            "如果 SpringBoard 桥接未连接，会退回使用 CFUserNotification。";
}
+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"title": @{ @"type": @"string", @"description": @"标题，默认 iAgent" },
            @"message": @{ @"type": @"string", @"description": @"正文内容" },
            @"duration": @{ @"type": @"integer", @"description": @"显示秒数，默认 4" },
        },
        @"required": @[ @"message" ],
    };
}
+ (NSString *)category { return @"notify"; }
+ (BOOL)isDangerous { return NO; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *message = IAGDictString(arguments, @"message", @"");
    if (message.length == 0) return IAGToolFailure(@"缺少 message 参数");
    NSString *title = IAGDictString(arguments, @"title", @"iAgent");
    NSInteger duration = IAGDictInteger(arguments, @"duration", 4);
    if (duration < 1) duration = 1;
    if (duration > 60) duration = 60;

    NSDictionary *bridged = [context.bridge performAction:@"notify"
                                              parameters:@{ @"title": title, @"message": message,
                                                            @"duration": @(duration) }
                                                 timeout:5];
    if ([bridged[@"ok"] boolValue]) {
        return IAGToolSuccess([NSString stringWithFormat:@"已通过 SpringBoard 显示提示：%@", message]);
    }

    // Fallback: 用 CoreFoundation 的 user notification 在本进程弹一条提示。
    // 这些符号在公开 iOS SDK 头文件里被标记为"iOS 不可用"，所以既不引用它的常量
    // 也不做链接期依赖：用 dlsym 解析函数 + 自己写键名（值就是公开文档里的字符串）。
    typedef CFTypeRef (*IAGUserNotificationCreateFn)(CFAllocatorRef, CFTimeInterval,
                                                     CFOptionFlags, SInt32 *, CFDictionaryRef);
    static IAGUserNotificationCreateFn createFn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
                              RTLD_LAZY);
        createFn = (IAGUserNotificationCreateFn)dlsym(handle ?: RTLD_DEFAULT,
                                                      "CFUserNotificationCreate");
    });

    if (createFn) {
        SInt32 errorCode = 0;
        NSDictionary *options = @{
            @"AlertHeader": title,
            @"AlertMessage": message,
            @"AlertTopMost": @YES,
            @"DefaultButtonTitle": @"好",
        };
        // kCFUserNotificationNoteAlertLevel == 1
        CFTypeRef notification = createFn(kCFAllocatorDefault, (CFTimeInterval)duration, 1,
                                          &errorCode, (__bridge CFDictionaryRef)options);
        if (notification) {
            CFRelease(notification);
            return IAGToolSuccess([NSString stringWithFormat:@"已通过 CFUserNotification 显示提示（%@）: %@",
                                   bridged[@"error"] ?: @"桥接不可用", message]);
        }
        return IAGToolFailure([NSString stringWithFormat:@"无法显示提示（%@，CFUserNotification 错误码 %d）",
                               bridged[@"error"] ?: @"桥接不可用", (int)errorCode]);
    }

    return IAGToolFailure([NSString stringWithFormat:@"无法显示提示：%@（且本进程拿不到 CFUserNotification）",
                           bridged[@"error"] ?: @"SpringBoard 桥接未连接"]);
}

@end

#pragma mark - cron_add

@interface IAGToolCronAdd : NSObject <IAGTool>
@end

@implementation IAGToolCronAdd

+ (NSString *)toolName { return @"cron_add"; }
+ (NSString *)toolDescription
{
    return @"创建一个定时任务，按 cron 表达式重复执行 shell 命令（设备本地时区）。"
            "5 个字段：分 时 日 月 周，支持 * a a-b a,b */n a-b/n。"
            "例如 \"*/10 * * * *\" 每 10 分钟；\"0 8 * * 1-5\" 工作日 8:00。";
}
+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"schedule": @{ @"type": @"string", @"description": @"cron 表达式，5 个字段" },
            @"command": @{ @"type": @"string", @"description": @"要执行的 shell 命令" },
            @"enabled": @{ @"type": @"boolean", @"description": @"是否立即启用，默认 true" },
        },
        @"required": @[ @"schedule", @"command" ],
    };
}
+ (NSString *)category { return @"cron"; }
+ (BOOL)isDangerous { return YES; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *schedule = IAGDictString(arguments, @"schedule", @"");
    NSString *command = IAGDictString(arguments, @"command", @"");
    BOOL enabled = IAGDictBool(arguments, @"enabled", YES);

    NSString *error = nil;
    IAGCronTask *task = [[IAGScheduler shared] addTaskWithSchedule:schedule
                                                          command:command
                                                          enabled:enabled
                                                            error:&error];
    if (!task) return IAGToolFailure(error ?: @"创建定时任务失败");

    return IAGToolSuccess([NSString stringWithFormat:
        @"已创建定时任务 %@\n表达式: %@\n命令: %@\n启用: %@\n下次运行: %@",
        task.taskId, task.schedule, task.command, task.enabled ? @"是" : @"否",
        task.nextRun > 0 ? [NSDateFormatter localizedStringFromDate:
                            [NSDate dateWithTimeIntervalSince1970:task.nextRun]
                                                          dateStyle:NSDateFormatterMediumStyle
                                                          timeStyle:NSDateFormatterMediumStyle] : @"未计算"]);
}

@end

#pragma mark - cron_list

@interface IAGToolCronList : NSObject <IAGTool>
@end

@implementation IAGToolCronList

+ (NSString *)toolName { return @"cron_list"; }
+ (NSString *)toolDescription { return @"列出当前所有定时任务及其上次执行结果、下次运行时间。"; }
+ (NSDictionary *)parametersSchema { return @{ @"type": @"object", @"properties": @{} }; }
+ (NSString *)category { return @"cron"; }
+ (BOOL)isDangerous { return NO; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSArray<IAGCronTask *> *tasks = [[IAGScheduler shared] tasks];
    if (tasks.count == 0) return IAGToolSuccess(@"当前没有定时任务。");

    NSMutableString *output = [NSMutableString string];
    for (IAGCronTask *task in tasks) {
        [output appendFormat:@"%@ [%@] %@\n  命令: %@\n  上次: %@ (exit=%ld) %@\n  下次: %@\n",
            task.taskId, task.enabled ? @"启用" : @"暂停", task.schedule, task.command,
            task.lastRun > 0 ? [NSDateFormatter localizedStringFromDate:
                                [NSDate dateWithTimeIntervalSince1970:task.lastRun]
                                                              dateStyle:NSDateFormatterShortStyle
                                                              timeStyle:NSDateFormatterShortStyle] : @"从未",
            (long)task.lastExitCode, task.lastResult ?: @"",
            task.nextRun > 0 ? [NSDateFormatter localizedStringFromDate:
                                [NSDate dateWithTimeIntervalSince1970:task.nextRun]
                                                              dateStyle:NSDateFormatterShortStyle
                                                              timeStyle:NSDateFormatterShortStyle] : @"—"];
    }
    return IAGToolSuccess(output);
}

@end

#pragma mark - cron_remove

@interface IAGToolCronRemove : NSObject <IAGTool>
@end

@implementation IAGToolCronRemove

+ (NSString *)toolName { return @"cron_remove"; }
+ (NSString *)toolDescription { return @"删除一个定时任务（需要任务 id，可用 cron_list 查询）。"; }
+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{ @"id": @{ @"type": @"string", @"description": @"任务 id，如 cron-1" } },
        @"required": @[ @"id" ],
    };
}
+ (NSString *)category { return @"cron"; }
+ (BOOL)isDangerous { return YES; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *taskId = IAGDictString(arguments, @"id", @"");
    if (taskId.length == 0) return IAGToolFailure(@"缺少 id 参数");
    if (![[IAGScheduler shared] removeTask:taskId]) {
        return IAGToolFailure([NSString stringWithFormat:@"没有找到定时任务 %@", taskId]);
    }
    return IAGToolSuccess([NSString stringWithFormat:@"已删除定时任务 %@", taskId]);
}

@end

#pragma mark - ui_describe

@interface IAGToolUIDescribe : NSObject <IAGTool>
@end

@implementation IAGToolUIDescribe

+ (NSString *)toolName { return @"ui_describe"; }
+ (NSString *)toolDescription
{
    return @"获取当前前台界面的可交互元素列表（无障碍树），包含元素文字与屏幕坐标。"
            "做界面操作前先用它确认目标元素的位置，然后用 ui_tap 的 x/y 或 text 参数点击。"
            "需要 SpringBoard 桥接已连接。";
}
+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"max_elements": @{ @"type": @"integer", @"description": @"最多返回元素数，默认 60" },
        },
    };
}
+ (NSString *)category { return @"ui"; }
+ (BOOL)isDangerous { return NO; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSInteger maxElements = IAGDictInteger(arguments, @"max_elements", 60);
    NSDictionary *result = [context.bridge performAction:@"ui_describe"
                                              parameters:@{ @"max_elements": @(maxElements) }
                                                 timeout:12];
    if (![result[@"ok"] boolValue]) {
        return IAGToolFailure(result[@"error"] ?: @"无法读取界面");
    }
    return IAGToolSuccess(IAGTruncateForModel(IAGStringOrEmpty(result[@"output"]), 12000));
}

@end

#pragma mark - ui_tap

@interface IAGToolUITap : NSObject <IAGTool>
@end

@implementation IAGToolUITap

+ (NSString *)toolName { return @"ui_tap"; }
+ (NSString *)toolDescription
{
    return @"在屏幕上模拟一次点击。可以用 x/y 指定绝对坐标，也可以给 text 让插件在当前界面里查找匹配文字的元素并点击它。"
            "坐标基于当前屏幕方向；先用 ui_describe 获取准确坐标更可靠。";
}
+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"x": @{ @"type": @"number", @"description": @"横坐标（点）" },
            @"y": @{ @"type": @"number", @"description": @"纵坐标（点）" },
            @"text": @{ @"type": @"string", @"description": @"要查找并点击的元素文字（与 x/y 二选一）" },
            @"index": @{ @"type": @"integer", @"description": @"匹配到多个元素时选择第几个，从 0 开始，默认 0" },
            @"long_press": @{ @"type": @"boolean", @"description": @"是否长按，默认 false" },
        },
    };
}
+ (NSString *)category { return @"ui"; }
+ (BOOL)isDangerous { return YES; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    BOOL hasText = IAGDictString(arguments, @"text", @"").length > 0;
    BOOL hasCoordinates = arguments[@"x"] != nil && arguments[@"y"] != nil;
    if (!hasText && !hasCoordinates) return IAGToolFailure(@"请提供 x/y 或 text");

    NSDictionary *result = [context.bridge performAction:@"ui_tap"
                                              parameters:arguments ?: @{}
                                                 timeout:12];
    if (![result[@"ok"] boolValue]) return IAGToolFailure(result[@"error"] ?: @"点击失败");
    return IAGToolSuccess(IAGStringOrEmpty(result[@"output"]) ?: @"已点击");
}

@end

#pragma mark - ui_type

@interface IAGToolUIType : NSObject <IAGTool>
@end

@implementation IAGToolUIType

+ (NSString *)toolName { return @"ui_type"; }
+ (NSString *)toolDescription
{
    return @"向当前获得焦点的输入框输入文本（先点击输入框获得焦点，再调用本工具）。"
            "如果需要发送回车，请在 text 里带上 \\n；删除字符用 \\u007f。";
}
+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"text": @{ @"type": @"string", @"description": @"要输入的文本" },
        },
        @"required": @[ @"text" ],
    };
}
+ (NSString *)category { return @"ui"; }
+ (BOOL)isDangerous { return YES; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *text = IAGStringOrEmpty(arguments[@"text"]);
    if (text.length == 0) return IAGToolFailure(@"缺少 text 参数");

    NSDictionary *result = [context.bridge performAction:@"ui_type"
                                              parameters:@{ @"text": text }
                                                 timeout:15];
    if (![result[@"ok"] boolValue]) return IAGToolFailure(result[@"error"] ?: @"输入失败");
    return IAGToolSuccess([NSString stringWithFormat:@"已输入 %lu 个字符",
                           (unsigned long)text.length]);
}

@end

#pragma mark - ui_swipe

@interface IAGToolUISwipe : NSObject <IAGTool>
@end

@implementation IAGToolUISwipe

+ (NSString *)toolName { return @"ui_swipe"; }
+ (NSString *)toolDescription
{
    return @"在屏幕上滑动（用于滚动列表、切换页面）。给出起点与终点坐标以及持续时间（秒，默认 0.3）。";
}
+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"x1": @{ @"type": @"number", @"description": @"起点横坐标" },
            @"y1": @{ @"type": @"number", @"description": @"起点纵坐标" },
            @"x2": @{ @"type": @"number", @"description": @"终点横坐标" },
            @"y2": @{ @"type": @"number", @"description": @"终点纵坐标" },
            @"duration": @{ @"type": @"number", @"description": @"持续秒数，默认 0.3" },
        },
        @"required": @[ @"x1", @"y1", @"x2", @"y2" ],
    };
}
+ (NSString *)category { return @"ui"; }
+ (BOOL)isDangerous { return YES; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSDictionary *result = [context.bridge performAction:@"ui_swipe"
                                              parameters:arguments ?: @{}
                                                 timeout:15];
    if (![result[@"ok"] boolValue]) return IAGToolFailure(result[@"error"] ?: @"滑动失败");
    return IAGToolSuccess(IAGStringOrEmpty(result[@"output"]) ?: @"已滑动");
}

@end

#pragma mark - ui_open_url

@interface IAGToolUIOpenURL : NSObject <IAGTool>
@end

@implementation IAGToolUIOpenURL

+ (NSString *)toolName { return @"ui_open_url"; }
+ (NSString *)toolDescription
{
    return @"打开一个 URL 或 URL Scheme（会离开当前应用，例如 prefs:root=WIFI、App-Prefs:、shortcuts:// 等）。"
            "想直接打开某个 App 请用 app_launch。";
}
+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{ @"url": @{ @"type": @"string", @"description": @"要打开的 URL" } },
        @"required": @[ @"url" ],
    };
}
+ (NSString *)category { return @"ui"; }
+ (BOOL)isDangerous { return NO; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *urlString = IAGDictString(arguments, @"url", @"");
    if (urlString.length == 0) return IAGToolFailure(@"缺少 url 参数");

    if (IAGOpenURL(urlString)) {
        return IAGToolSuccess([NSString stringWithFormat:@"已打开 %@", urlString]);
    }
    NSDictionary *result = [context.bridge performAction:@"open_url"
                                              parameters:@{ @"url": urlString }
                                                 timeout:8];
    if ([result[@"ok"] boolValue]) return IAGToolSuccess(IAGStringOrEmpty(result[@"output"]));
    return IAGToolFailure([NSString stringWithFormat:@"无法打开 %@（%@）",
                           urlString, result[@"error"] ?: @"系统拒绝"]);
}

@end

#pragma mark - registration

void IAGRegisterDeviceTools(IAGToolRegistry *registry)
{
    [registry registerToolClass:[IAGToolAppList class]];
    [registry registerToolClass:[IAGToolAppLaunch class]];
    [registry registerToolClass:[IAGToolNotifySend class]];
    [registry registerToolClass:[IAGToolCronAdd class]];
    [registry registerToolClass:[IAGToolCronList class]];
    [registry registerToolClass:[IAGToolCronRemove class]];
    [registry registerToolClass:[IAGToolUIDescribe class]];
    [registry registerToolClass:[IAGToolUITap class]];
    [registry registerToolClass:[IAGToolUIType class]];
    [registry registerToolClass:[IAGToolUISwipe class]];
    [registry registerToolClass:[IAGToolUIOpenURL class]];
}
