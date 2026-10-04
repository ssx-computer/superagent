//
//  IAGDiagnostics.h
//  iAgent
//
//  "守护进程为什么没了" 的现场取证工具。
//
//  为什么需要它：Web 面板上那句「连接被提前关闭（daemon 可能被杀/崩溃）」以前
//  完全无法定位——进程死了以后什么都不留下，用户只能反复重装。这个模块做三件事：
//
//    1. 崩溃诊断：未捕获异常与致命信号（SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/
//       SIGTRAP）都写进 logs/iagentd-crash.log，带信号名与 backtrace() 调用栈。
//    2. 非正常退出检测：进程启动时写一个 marker 文件（pid + 时间 + 干净退出标志），
//       **下一次启动**读它就能判断上一次是否有机会清理现场。没清理过 → restarts
//       计数 +1（计数持久化在 logs/restarts.count），并把信号名/崩溃日志尾部记成
//       lastCrash。
//    3. 把上面这些事实暴露给 /api/health（pid / startedAt / restarts / lastCrash /
//       lastExitClean），前端据此提示"守护进程刚重启过"。
//
//  重要约束：只有**守护进程**会调用 InstallCrashHandlers()，插件（SpringBoard 里
//  的 iagent.dylib）绝不安装进程级 handler —— 那会抢走 SpringBoard 自己的崩溃处理。
//

#ifndef IAG_DIAGNOSTICS_H
#define IAG_DIAGNOSTICS_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 崩溃日志（纯文本，追加写）。
NSString *IAGCrashLogPath(void);
/// 启动标记文件（pid + 时间 + 干净退出标志）。
NSString *IAGRunningMarkerPath(void);
/// 累计重启计数文件（纯数字文本）。
NSString *IAGRestartCountPath(void);

/// 安装 NSSetUncaughtExceptionHandler + SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/
/// SIGTRAP 的 handler。只应在守护进程启动最早期调用一次；调用后自己会记录
/// `installed = YES`，重复调用无副作用。
void IAGInstallCrashHandlers(void);

/// 启动时调用：检测上一次是否非正常退出，并写下本次运行的 marker。
/// 返回 NO 表示数据目录不可写（诊断功能降级，但不影响守护进程启动）。
BOOL IAGDaemonMarkStart(void);

/// 收到 SIGTERM/SIGINT/SIGHUP 时调用：**异步信号安全**，只做一次 pwrite + fdatasync，
/// 把 marker 标记成"干净退出"。之后抓不到这个 marker 就会算成一次崩溃重启。
/// 返回 NO 表示没有可用的 marker（例如还没 MarkStart）。
BOOL IAGDaemonHandleTerminationSignal(int signalNumber);

/// /api/health 用的只读快照，键为：
///   pid(NSNumber) startedAt(NSNumber) restarts(NSNumber)
///   lastExitClean(BOOL) lastCrash(NSDictionary 或 NSNull)
/// lastCrash = { "at": 秒, "signal": "SIGSEGV" 或 null, "detail": 日志尾部(截断) }
/// 或 { "at": 秒, "exception": "名称", "detail": "原因" }
NSDictionary *IAGDaemonHealthInfo(void);

#ifdef __cplusplus
}
#endif

#endif /* IAG_DIAGNOSTICS_H */
