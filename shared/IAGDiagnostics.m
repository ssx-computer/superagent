//
//  IAGDiagnostics.m
//  iAgent
//
//  实现见头文件里的动机说明。这里只强调三条实现纪律：
//
//    * marker 文件用裸 open()/ftruncate()/write()/fdatasync() 写，因为它必须在
//      **信号处理函数里**（SIGTERM/SIGINT/SIGHUP，以及崩溃信号）可用，不能依赖
//      Foundation/ARC/任何会加锁的东西。
//    * 崩溃日志用预打开并缓存的 fd（gCrashFD）追加写，同样是为了信号安全。
//    * 只有守护进程会安装 handler；插件不调用 IAGInstallCrashHandlers()。
//
//  已知取舍：崩溃信号处理函数里调用了 backtrace_symbols()（会 malloc），严格意义上不是
//  异步信号安全的——万一崩溃发生在 malloc 内部，这一行可能拿不到符号（最坏情况是卡住）。
//  但它能换到"崩溃时到底死在哪"这个关键信息，而且只在崩溃路径上执行一次，值得。
//

#import "IAGDiagnostics.h"
#import "IAGPaths.h"
#import "IAGJSON.h"
#import "IAGLog.h"

#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#pragma mark - 常量与全局状态

static const NSUInteger kIAGCrashTailLines   = 20;        // lastCrash.detail 取崩溃日志最后几行
static const NSUInteger kIAGCrashDetailMax   = 1500;      // 单条 detail 的字符上限
static const unsigned long long kIAGCrashLogRotateBytes = 512ULL * 1024ULL;

static int gMarkerFD = -1;             // marker 文件 fd（信号处理函数里用）
static int gCrashFD  = -1;             // 崩溃日志 fd（信号处理函数里用）
static int gFatalSignals[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
static const int gFatalSignalCount = (int)(sizeof(gFatalSignals) / sizeof(gFatalSignals[0]));

static volatile sig_atomic_t gCrashRecorded = 0;   // 保证一次崩溃只追加一次崩溃日志
static volatile sig_atomic_t gInstalled = 0;

static BOOL gMarked = NO;              // 本次运行是否写过 marker
static NSInteger gPID = 0;
static NSTimeInterval gStartedAt = 0;
static NSInteger gRestarts = 0;
static BOOL gLastExitClean = YES;
static NSDictionary *gLastCrash = nil; // nil 表示"没有上一次崩溃记录"

#pragma mark - 路径

NSString *IAGCrashLogPath(void)
{
    return [IAGLogDir() stringByAppendingPathComponent:@"iagentd-crash.log"];
}

NSString *IAGRunningMarkerPath(void)
{
    return [IAGLogDir() stringByAppendingPathComponent:@"running.marker"];
}

NSString *IAGRestartCountPath(void)
{
    return [IAGLogDir() stringByAppendingPathComponent:@"restarts.count"];
}

#pragma mark - 低层写文件（信号安全）

/// 全量写：处理 EINTR 与短写。
static BOOL IAGWriteAllFD(int fd, const void *bytes, size_t length)
{
    const char *cursor = (const char *)bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written > 0) {
            cursor += written;
            remaining -= (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        return NO;
    }
    return YES;
}

static int IAGOpenAppend(const char *path, mode_t mode)
{
    if (!path) return -1;
    return open(path, O_WRONLY | O_CREAT | O_APPEND, mode);
}

/// marker 文件内容。时间戳可以在信号处理函数里安全调用（time() 是异步信号安全的）。
/// 格式（单行紧凑 JSON，改写时先截断再写，不会留下旧尾巴）：
///     {"pid":1234,"at":1712345678,"clean":0}
/// `crash` 为 NULL 时不写信号名；崩溃时写成 SIGSEGV 这样的名字，便于下次启动直读。
static size_t IAGFormatMarker(char *out, size_t capacity, int clean, const char *crash)
{
    if (!out || capacity < 64) return 0;

    int n = snprintf(out, capacity, "{\"pid\":%ld,\"at\":%lld,\"clean\":%d",
                     (long)getpid(), (long long)time(NULL), clean ? 1 : 0);
    if (n <= 0) return 0;
    size_t used = (size_t)n;
    if (used >= capacity) used = capacity - 1;      // 理论上不会发生（capacity >= 64）

    if (crash && used + 16 < capacity) {
        size_t room = capacity - used;
        int extra = snprintf(out + used, room, ",\"crash\":\"%s\"", crash);
        if (extra <= 0) return 0;
        if ((size_t)extra >= room) return 0;        // 被截断了：宁可不写，也不写坏 JSON
        used += (size_t)extra;
    }

    if (used + 2 >= capacity) return 0;
    out[used++] = '}';
    out[used++] = '\n';
    return used;
}

static void IAGCloseMarker(void)
{
    if (gMarkerFD >= 0) {
        close(gMarkerFD);
        gMarkerFD = -1;
    }
}

/// 原地覆盖 marker：先 ftruncate 再 pwrite(0)，这样短的新内容不会留下旧尾巴。
static BOOL IAGWriteMarkerBytes(const char *bytes, size_t length)
{
    if (!bytes || length == 0) return NO;
    if (gMarkerFD < 0) {
        gMarkerFD = IAGOpenAppend(IAGRunningMarkerPath().fileSystemRepresentation, 0644);
        if (gMarkerFD < 0) return NO;
    }
    if (ftruncate(gMarkerFD, 0) != 0) {
        IAGCloseMarker();
        return NO;
    }
    if (!IAGWriteAllFD(gMarkerFD, bytes, length)) {
        IAGCloseMarker();
        return NO;
    }
    fdatasync(gMarkerFD);
    return YES;
}

#pragma mark - 崩溃日志

/// fd 已经打开时用 fd，否则打开（仅信号处理函数之外的路径会走到这里）。
static void IAGAppendCrashText(const char *bytes, size_t length)
{
    if (!bytes || length == 0) return;
    if (gCrashFD < 0) {
        gCrashFD = IAGOpenAppend(IAGCrashLogPath().fileSystemRepresentation, 0644);
        if (gCrashFD < 0) return;
    }
    IAGWriteAllFD(gCrashFD, bytes, length);
    fdatasync(gCrashFD);
}

/// 一行式时间戳，避免在信号处理函数里用 localtime_r 之外的分配。
static void IAGCrashStamp(char *out, size_t capacity)
{
    time_t seconds = time(NULL);
    struct tm tmBuffer;
    memset(&tmBuffer, 0, sizeof(tmBuffer));
    localtime_r(&seconds, &tmBuffer);
    strftime(out, capacity, "%Y-%m-%d %H:%M:%S", &tmBuffer);
}

static const char *IAGSignalName(int signalNumber)
{
    switch (signalNumber) {
        case SIGSEGV: return "SIGSEGV";
        case SIGABRT: return "SIGABRT";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGFPE:  return "SIGFPE";
        case SIGTRAP: return "SIGTRAP";
        default:      return "SIGUNKNOWN";
    }
}

/// 把上一次崩溃现场写进崩溃日志（异常路径，非信号上下文）。
static void IAGAppendCrashLine(NSString *text)
{
    NSString *line = [text stringByAppendingString:@"\n"];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length) IAGAppendCrashText(data.bytes, data.length);
}

#pragma mark - 信号 handler

static void IAGHandleFatalSignal(int signalNumber)
{
    if (gCrashRecorded == 0) {
        gCrashRecorded = 1;

        // 1) 先把现场钉在 marker 上：下次启动一眼看出是哪个信号干掉了守护进程。
        char marker[256];
        size_t markerLength = IAGFormatMarker(marker, sizeof(marker), 0, IAGSignalName(signalNumber));
        if (markerLength) IAGWriteMarkerBytes(marker, markerLength);

        // 2) 再写崩溃日志（预打开 fd，不做任何内存分配以外的事情）。
        char stamp[32];
        IAGCrashStamp(stamp, sizeof(stamp));

        char header[256];
        int headerLength = snprintf(header, sizeof(header),
                                    "\n===== %s 收到 %s(%d)，pid=%ld =====\n调用栈:\n",
                                    stamp, IAGSignalName(signalNumber), signalNumber, (long)getpid());
        if (headerLength > 0) IAGAppendCrashText(header, (size_t)headerLength);

        void *frames[64];
        int frameCount = backtrace(frames, 64);
        if (frameCount > 0) {
            char **symbols = backtrace_symbols(frames, frameCount);
            if (symbols) {
                for (int i = 0; i < frameCount; i++) {
                    char line[512];
                    int n = snprintf(line, sizeof(line), "  #%-2d %s\n", i, symbols[i] ? symbols[i] : "?");
                    if (n > 0) IAGAppendCrashText(line, (size_t)((n < (int)sizeof(line)) ? n : (int)sizeof(line) - 1));
                }
                free(symbols);
            } else {
                const char *fallback = "  (backtrace_symbols 失败)\n";
                IAGAppendCrashText(fallback, strlen(fallback));
            }
        }
    }

    // 3) 恢复默认行为后重新触发，进程仍然按"信号致死"正常终止（退出码/信号语义不变，
    //    不吞掉 crash report），但现场已经留下了。
    signal(signalNumber, SIG_DFL);
    raise(signalNumber);
}

static void IAGHandleUncaughtException(NSException *exception)
{
    // 异常处理器不是异步信号上下文，可以用 Foundation，但仍然要短、不能抛。
    @try {
        NSString *name = exception.name ?: @"NSException";
        NSString *reason = exception.reason ?: @"";
        NSArray<NSString *> *stack = [exception callStackSymbols];

        NSMutableString *text = [NSMutableString string];
        [text appendFormat:@"uncaught exception: %@: %@\n", name, reason];
        if (stack.count) {
            [text appendString:@"调用栈:\n"];
            NSUInteger limit = MIN(stack.count, (NSUInteger)40);
            for (NSUInteger i = 0; i < limit; i++) {
                [text appendFormat:@"  %@\n", stack[i]];
            }
        }
        IAGAppendCrashLine(text);
        IAGLogError(@"未捕获异常: %@: %@", name, reason);
    } @catch (NSException *ignored) {
        (void)ignored;
    }
}

#pragma mark - 安装

void IAGInstallCrashHandlers(void)
{
    if (gInstalled) return;
    gInstalled = 1;

    IAGEnsureDirectory(IAGLogDir());

    NSString *crashPath = IAGCrashLogPath();
    struct stat crashStat;
    if (stat(crashPath.fileSystemRepresentation, &crashStat) == 0 &&
        (unsigned long long)crashStat.st_size > kIAGCrashLogRotateBytes) {
        NSString *rotated = [crashPath stringByAppendingString:@".1"];
        unlink(rotated.fileSystemRepresentation);
        rename(crashPath.fileSystemRepresentation, rotated.fileSystemRepresentation);
    }
    gCrashFD = IAGOpenAppend(crashPath.fileSystemRepresentation, 0644);
    if (gCrashFD < 0) {
        IAGLogWarn(@"崩溃日志不可写: %@", crashPath);
    }

    // 注意：这里**不要**预先创建 marker 文件。IAGDaemonMarkStart() 要靠"marker 是否
    // 存在"来判断上一次是否干净退出，安装 handler 时顺手创建一个空文件会被误判成
    // 上一次崩溃。marker 的 fd 由 IAGWriteMarkerBytes() 在真正要写的时候懒打开。
    for (int i = 0; i < gFatalSignalCount; i++) {
        signal(gFatalSignals[i], IAGHandleFatalSignal);
    }
    NSSetUncaughtExceptionHandler(&IAGHandleUncaughtException);
}

#pragma mark - 上一次退出的现场取证

/// kill(pid, 0) 探活：EPERM 说明进程存在但不属于我们（守护进程是 root，几乎不会遇到）。
static BOOL IAGProcessIsAlive(pid_t pid)
{
    if (pid <= 0) return NO;
    if (kill(pid, 0) == 0) return YES;
    return errno == EPERM;
}

static NSInteger IAGReadRestartCount(void)
{
    NSString *text = [NSString stringWithContentsOfFile:IAGRestartCountPath()
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    NSInteger value = text.length ? (NSInteger)[text integerValue] : 0;   // 非法内容按 0 处理
    return value < 0 ? 0 : value;
}

static BOOL IAGWriteRestartCount(NSInteger value)
{
    if (!IAGEnsureDirectory(IAGLogDir())) return NO;
    NSString *text = [NSString stringWithFormat:@"%ld\n", (long)value];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return [data writeToFile:IAGRestartCountPath() atomically:YES];
}

/// 崩溃日志最后几行（截断），给 lastCrash.detail 用。
static NSString *IAGCrashLogTail(void)
{
    NSData *data = [NSData dataWithContentsOfFile:IAGCrashLogPath()];
    if (data.length == 0) return nil;

    // 大文件只读尾部 32 KB，避免一次崩溃日志读进几十 MB。
    NSUInteger maxBytes = 32 * 1024;
    NSRange range = NSMakeRange(0, data.length);
    if (data.length > maxBytes) range = NSMakeRange(data.length - maxBytes, maxBytes);

    NSString *text = [[NSString alloc] initWithData:[data subdataWithRange:range]
                                           encoding:NSUTF8StringEncoding];
    if (text.length == 0) return nil;

    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length) [kept addObject:trimmed];
    }
    if (kept.count == 0) return nil;

    NSUInteger start = kept.count > kIAGCrashTailLines ? kept.count - kIAGCrashTailLines : 0;
    NSArray<NSString *> *tail = [kept subarrayWithRange:NSMakeRange(start, kept.count - start)];
    return IAGTruncateString([tail componentsJoinedByString:@"\n"], kIAGCrashDetailMax);
}

/// marker 文件自上次启动以来新增的崩溃日志（有就取最后几行）。
static NSString *IAGNewCrashLogExcerpt(unsigned long long baseline)
{
    NSString *path = IAGCrashLogPath();
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) return nil;
    if ((unsigned long long)st.st_size <= baseline) return nil;
    return IAGCrashLogTail();
}

static NSDictionary *IAGParsePreviousMarker(void)
{
    NSData *data = [NSData dataWithContentsOfFile:IAGRunningMarkerPath()];
    if (data.length == 0) return nil;
    id json = IAGJSONDecode(data, NULL);
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

#pragma mark - 启动 / 退出

BOOL IAGDaemonMarkStart(void)
{
    gPID = (NSInteger)getpid();
    gStartedAt = [NSDate date].timeIntervalSince1970;
    gRestarts = IAGReadRestartCount();
    gLastExitClean = YES;
    gLastCrash = nil;

    IAGEnsureDirectory(IAGLogDir());
    unsigned long long baseline = 0;
    struct stat crashStat;
    if (stat(IAGCrashLogPath().fileSystemRepresentation, &crashStat) == 0) {
        baseline = (unsigned long long)crashStat.st_size;
    }

    NSDictionary *previous = IAGParsePreviousMarker();
    if (previous) {
        NSInteger previousPID = IAGDictInteger(previous, @"pid", -1);
        BOOL previousClean = IAGDictBool(previous, @"clean", NO);
        BOOL previousAlive = IAGProcessIsAlive((pid_t)previousPID);

        if (previousClean || previousAlive) {
            // clean=1 是正常退出（SIGTERM/SIGINT/SIGHUP 已经清理过现场）；
            // previousAlive 说明是同一时间跑着的另一个实例（例如手动前台启动），
            // 不该算成崩溃。
            gLastExitClean = YES;
            if (previousAlive && !previousClean) {
                IAGLogWarn(@"检测到另一个 iagentd 实例仍在运行 (pid %ld)，本次不计入重启",
                           (long)previousPID);
            }
        } else {
            gLastExitClean = NO;

            NSString *crashName = IAGDictString(previous, @"crash", nil);
            NSString *exceptionName = IAGDictString(previous, @"exception", nil);
            NSString *exceptionReason = IAGDictString(previous, @"exceptionReason", nil);
            NSString *excerpt = IAGNewCrashLogExcerpt(baseline);

            NSMutableDictionary *crash = [NSMutableDictionary dictionary];
            NSInteger at = IAGDictInteger(previous, @"at", 0);
            crash[@"at"] = @(at > 0 ? at : (NSInteger)gStartedAt);
            crash[@"signal"] = crashName.length ? crashName : (id)[NSNull null];
            if (exceptionName.length) crash[@"exception"] = exceptionName;
            if (exceptionReason.length) crash[@"exceptionReason"] = IAGTruncateString(exceptionReason, 500);
            // detail 只取"本次启动新增的崩溃日志"，避免把很久以前的一次崩溃误报成这次的原因。
            crash[@"detail"] = excerpt.length ? excerpt
                : @"没有新增的崩溃日志（进程可能是被 SIGKILL / 系统强制结束，或被 launchd 停止）";
            gLastCrash = crash;

            gRestarts += 1;
            IAGWriteRestartCount(gRestarts);
            IAGLogWarn(@"检测到上一次运行非正常退出（pid %ld，信号 %@），累计重启 %ld 次",
                       (long)previousPID, crashName.length ? crashName : @"未知", (long)gRestarts);
        }
    } else if (IAGPathExists(IAGRunningMarkerPath())) {
        // marker 存在却读不出内容（被截断/写坏）：按"非正常退出"处理，宁可多报一次
        // 重启，也不要漏报一次崩溃。
        gLastExitClean = NO;
        gRestarts += 1;
        IAGWriteRestartCount(gRestarts);
        gLastCrash = @{ @"at": @((NSInteger)gStartedAt),
                        @"signal": [NSNull null],
                        @"detail": @"运行标记损坏或为空，无法确认上一次是否正常退出" };
        IAGLogWarn(@"运行标记 %@ 无法解析，按非正常退出处理（累计重启 %ld 次）",
                   IAGRunningMarkerPath(), (long)gRestarts);
    }

    char marker[256];
    size_t markerLength = IAGFormatMarker(marker, sizeof(marker), 0, NULL);
    gMarked = (markerLength > 0) && IAGWriteMarkerBytes(marker, markerLength);
    if (!gMarked) {
        IAGLogWarn(@"无法写入运行标记 %@，崩溃重启检测将不可用", IAGRunningMarkerPath());
    }
    return gMarked;
}

BOOL IAGDaemonHandleTerminationSignal(int signalNumber)
{
    if (!gMarked) return NO;

    // 只做异步信号安全的三件事：ftruncate + pwrite + fdatasync。
    char marker[256];
    size_t markerLength = IAGFormatMarker(marker, sizeof(marker), 1, NULL);
    if (markerLength == 0) return NO;

    BOOL ok = IAGWriteMarkerBytes(marker, markerLength);
    if (!ok) gMarked = NO;
    return ok;
}

#pragma mark - /api/health 快照

NSDictionary *IAGDaemonHealthInfo(void)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"pid"] = @(gPID > 0 ? gPID : (NSInteger)getpid());
    info[@"startedAt"] = @((NSInteger)(gStartedAt > 0 ? gStartedAt : [NSDate date].timeIntervalSince1970));
    info[@"restarts"] = @(gRestarts);
    info[@"lastExitClean"] = @(gLastExitClean);
    if (gLastCrash) {
        info[@"lastCrash"] = gLastCrash;
    } else {
        info[@"lastCrash"] = [NSNull null];
    }
    return info;
}
