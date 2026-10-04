//
//  main.m
//  iagentd — the iAgent daemon.
//
//  Runs from launchd (see layout/Library/LaunchDaemons/com.dsh.iagent.daemon.plist)
//  as root and serves the loopback control plane plus the static web UI.
//

#import <Foundation/Foundation.h>

#import "IAGDaemon.h"
#import "IAGConfig.h"
#import "IAGDiagnostics.h"
#import "IAGPaths.h"
#import "IAGLog.h"
#import "IAGVersion.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static IAGDaemon *gDaemon = nil;

static void IAGHandleTerminationSignal(int signalNumber)
{
    // Async-signal-safe path: mark a clean exit in the running marker, stop the
    // socket, then leave. Writing the marker is what tells the *next* start that
    // this exit was intentional (a missing/dirty marker means "crashed", which
    // bumps the restart counter shown in /api/health).
    IAGDaemonHandleTerminationSignal(signalNumber);
    if (gDaemon) {
        @try { [gDaemon stop]; } @catch (NSException *exception) { (void)exception; }
    }
    IAGLogMessage(IAGLogLevelInfo, __FILE__, __LINE__, @"收到信号 %d，进程退出", signalNumber);
    _exit(0);
}

static void IAGInstallSignalHandlers(void)
{
    signal(SIGPIPE, SIG_IGN);       // a browser closing an SSE stream is normal
    signal(SIGTERM, IAGHandleTerminationSignal);
    signal(SIGINT,  IAGHandleTerminationSignal);
    signal(SIGHUP,  IAGHandleTerminationSignal);

    // 崩溃诊断：未捕获异常 + SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP 写
    // logs/iagentd-crash.log（含 backtrace），并让下一次启动能看出是哪个信号
    // 杀死了守护进程。SIGTERM/SIGINT/SIGHUP 不在此列——那些是"正常停止"。
    IAGInstallCrashHandlers();
}

static void IAGPrintUsage(const char *argv0)
{
    printf("iAgent daemon %s (build %s)\n\n", IAG_VERSION_STRING.UTF8String, IAG_BUILD_STRING.UTF8String);
    printf("用法:\n");
    printf("  %s [选项]\n\n", argv0);
    printf("选项:\n");
    printf("  --port <端口>    临时覆盖监听端口（不写入配置，默认取配置里的 %d）\n", IAG_DEFAULT_PORT);
    printf("  --print-paths    打印运行时路径后退出（排查安装问题用）\n");
    printf("  --version        打印版本后退出\n");
    printf("  --help           显示本帮助\n\n");
    printf("配置与数据目录: %s\n", IAGDataDir().UTF8String);
    printf("Web 控制面板:   http://%s:<端口>/\n", IAG_DEFAULT_HOST.UTF8String);
}

static void IAGPrintPaths(void)
{
    printf("version        : %s (build %s)\n", IAG_VERSION_STRING.UTF8String, IAG_BUILD_STRING.UTF8String);
    printf("executable     : %s\n", NSBundle.mainBundle.executablePath.UTF8String);
    printf("jailbreak root : %s\n", IAGJailbreakRoot().UTF8String);
    printf("rootfs         : %s\n", IAGRootfs().UTF8String);
    printf("rootless       : %s\n", IAGIsRootless() ? "yes" : "no");
    printf("running as     : %s (euid %d)\n", IAGUserName().UTF8String, (int)geteuid());
    printf("data dir       : %s\n", IAGDataDir().UTF8String);
    printf("config file    : %s\n", IAGConfigPath().UTF8String);
    printf("cron file      : %s\n", IAGCronPath().UTF8String);
    printf("sessions dir   : %s\n", IAGSessionsDir().UTF8String);
    printf("log file       : %s\n", IAGLogPath().UTF8String);
    printf("crash log      : %s\n", IAGCrashLogPath().UTF8String);
    printf("running marker : %s\n", IAGRunningMarkerPath().UTF8String);
    printf("restart count  : %s\n", IAGRestartCountPath().UTF8String);
    printf("web root       : %s\n", IAGWebRoot().UTF8String);
    printf("web index      : %s\n", [IAGWebRoot() stringByAppendingPathComponent:@"index.html"].UTF8String);
    printf("device         : %s (%s) iOS %s\n", IAGDeviceModelIdentifier().UTF8String,
           IAGDeviceModelName().UTF8String, IAGSystemVersion().UTF8String);
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        uint16_t portOverride = 0;
        BOOL printPaths = NO;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--version") == 0) {
                printf("%s\n", IAG_VERSION_STRING.UTF8String);
                return 0;
            }
            if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
                IAGPrintUsage(argv[0]);
                return 0;
            }
            if (strcmp(argv[i], "--print-paths") == 0) {
                printPaths = YES;
                continue;
            }
            if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
                int value = atoi(argv[++i]);
                if (value > 0 && value < 65536) portOverride = (uint16_t)value;
                else fprintf(stderr, "iagentd: 端口 %s 非法，已忽略\n", argv[i]);
                continue;
            }
            // launchd passes no arguments; anything else is a typo worth reporting.
            fprintf(stderr, "iagentd: 未知参数 %s（用 --help 查看用法）\n", argv[i]);
        }

        if (printPaths) {
            IAGPrintPaths();
            return 0;
        }

        IAGInstallSignalHandlers();
        IAGLogSetMirrorToStderr(YES);
        IAGLogInfo(@"iagentd %@ (build %@) 正在启动", IAG_VERSION_STRING, IAG_BUILD_STRING);

        // 写运行标记并检测"上一次是否非正常退出"：标记文件路径 logs/running.marker，
        // 计数持久化在 logs/restarts.count，结论会出现在 /api/health 里。
        if (!IAGDaemonMarkStart()) {
            IAGLogWarn(@"无法写入运行标记（%@），重启检测与崩溃取证将不可用", IAGRunningMarkerPath());
        }

        gDaemon = [IAGDaemon shared];
        if (portOverride) gDaemon.portOverride = portOverride;

        NSError *error = nil;
        if (![gDaemon startWithError:&error]) {
            IAGLogError(@"启动失败: %@", error.localizedDescription ?: @"未知错误");
            fprintf(stderr, "iagentd: 启动失败: %s\n",
                    (error.localizedDescription ?: @"未知错误").UTF8String);
            // 主动退出（例如端口被别的实例占着）不该被下一次启动当成"崩溃重启"，
            // 所以这里也把运行标记清成干净退出。
            IAGDaemonHandleTerminationSignal(SIGTERM);
            return 1;
        }

        IAGLogInfo(@"iagentd 已就绪，监听 127.0.0.1:%u", gDaemon.port);
        dispatch_main();

        // dispatch_main() never returns.
        return 0;
    }
}
