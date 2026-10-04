//
//  IAGTerminal.m
//  iAgent
//

#import "IAGTerminal.h"
#import "IAGProcess.h"
#import "IAGPaths.h"
#import "IAGUtil.h"
#import "IAGLog.h"

#import <poll.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <dlfcn.h>
#import <termios.h>
#import <sys/ioctl.h>
#import <sys/wait.h>
#import <sys/stat.h>

static const NSUInteger kIAGTerminalBufferBytes = 512 * 1024;
static const NSUInteger kIAGTerminalMaxSessions = 8;

// forkpty lives in libSystem on Darwin but is not declared by the iOS SDK.
typedef int (*IAGForkPTYFn)(int *amaster, char *name, struct termios *termp, struct winsize *winp);

static IAGForkPTYFn IAGForkPTYFunction(void)
{
    static IAGForkPTYFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (IAGForkPTYFn)dlsym(RTLD_DEFAULT, "forkpty");
    });
    return fn;
}

static char **IAGBuildCStringArray(NSArray<NSString *> *strings)
{
    char **array = calloc(strings.count + 1, sizeof(char *));
    if (!array) return NULL;
    for (NSUInteger i = 0; i < strings.count; i++) {
        array[i] = strdup([strings[i] UTF8String] ?: "");
        if (!array[i]) {
            for (NSUInteger j = 0; j < i; j++) free(array[j]);
            free(array);
            return NULL;
        }
    }
    array[strings.count] = NULL;
    return array;
}

static void IAGFreeCStringArray(char **array)
{
    if (!array) return;
    for (NSUInteger i = 0; array[i]; i++) free(array[i]);
    free(array);
}

#pragma mark -

@interface IAGTerminalSession ()
@property (nonatomic, copy, readwrite)   NSString *sessionId;
@property (nonatomic, assign, readwrite) pid_t pid;
@property (nonatomic, assign, readwrite) int columns;
@property (nonatomic, assign, readwrite) int rows;
@property (nonatomic, copy, readwrite)   NSString *shellPath;
@property (nonatomic, assign) int masterFD;
@end

@implementation IAGTerminalSession {
    NSMutableData *_buffer;
    NSUInteger _totalWritten;
    NSLock *_lock;
    BOOL _alive;
    NSInteger _exitCode;
    BOOL _readerRunning;
    NSTimeInterval _startedAt;
    NSDate *_lastActivity;
}

- (instancetype)initWithIdentifier:(NSString *)sessionId
                                fd:(int)fd
                               pid:(pid_t)pid
                           columns:(int)columns
                              rows:(int)rows
                             shell:(NSString *)shell
{
    self = [super init];
    if (self) {
        _sessionId = [sessionId copy];
        _masterFD = fd;
        _pid = pid;
        _columns = columns;
        _rows = rows;
        _shellPath = [shell copy];
        _buffer = [NSMutableData dataWithCapacity:16384];
        _totalWritten = 0;
        _lock = [[NSLock alloc] init];
        _alive = YES;
        _exitCode = NSNotFound;
        _startedAt = [NSDate date].timeIntervalSince1970;
        _lastActivity = [NSDate date];
    }
    return self;
}

- (void)dealloc
{
    if (_masterFD >= 0) close(_masterFD);
}

#pragma mark accessors

- (BOOL)alive
{
    [_lock lock];
    BOOL value = _alive;
    [_lock unlock];
    return value;
}

- (NSInteger)exitCode
{
    [_lock lock];
    NSInteger value = _exitCode;
    [_lock unlock];
    return value;
}

- (NSUInteger)cursor
{
    [_lock lock];
    NSUInteger value = _totalWritten;
    [_lock unlock];
    return value;
}

- (NSDictionary *)statusJSON
{
    [_lock lock];
    NSDictionary *json = @{
        @"sessionId": self.sessionId ?: @"",
        @"pid": @(self.pid),
        @"columns": @(self.columns),
        @"rows": @(self.rows),
        @"shell": self.shellPath ?: @"",
        @"alive": @(_alive),
        @"exitCode": (_exitCode == NSNotFound) ? (id)[NSNull null] : @(_exitCode),
        @"cursor": @(_totalWritten),
        @"startedAt": @(_startedAt),
    };
    [_lock unlock];
    return json;
}

#pragma mark reader

- (void)startReader
{
    _readerRunning = YES;
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        [self readerLoop];
    }];
    thread.name = [NSString stringWithFormat:@"iagent.term.%@", self.sessionId ?: @"?"];
    thread.qualityOfService = NSQualityOfServiceUserInitiated;
    [thread start];
}

- (void)appendBytes:(const uint8_t *)bytes length:(NSUInteger)length
{
    [_lock lock];
    [_buffer appendBytes:bytes length:length];
    _totalWritten += length;
    if (_buffer.length > kIAGTerminalBufferBytes) {
        NSUInteger drop = _buffer.length - kIAGTerminalBufferBytes;
        [_buffer replaceBytesInRange:NSMakeRange(0, drop) withBytes:NULL length:0];
    }
    _lastActivity = [NSDate date];
    [_lock unlock];
}

- (void)readerLoop
{
    while (_readerRunning) {
        struct pollfd pfd = { .fd = self.masterFD, .events = POLLIN, .revents = 0 };
        int ready = poll(&pfd, 1, 200);
        if (!_readerRunning) break;
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ready == 0) {
            // Idle tick: notice a child that exited without closing the pty.
            int status = 0;
            pid_t waited = waitpid(self.pid, &status, WNOHANG);
            if (waited == self.pid) {
                [self finishWithStatus:status];
                return;
            }
            continue;
        }
        uint8_t temp[8192];
        ssize_t got = read(self.masterFD, temp, sizeof(temp));
        if (got > 0) {
            [self appendBytes:temp length:(NSUInteger)got];
            continue;
        }
        if (got == 0) break;
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
        break;   // EIO on a pty means the child is gone
    }

    int status = 0;
    pid_t waited = 0;
    for (int attempt = 0; attempt < 50; attempt++) {
        waited = waitpid(self.pid, &status, WNOHANG);
        if (waited == self.pid) break;
        usleep(10000);
    }
    [self finishWithStatus:(waited == self.pid) ? status : 0];
}

- (void)finishWithStatus:(int)status
{
    [_lock lock];
    if (_alive) {
        _alive = NO;
        if (WIFEXITED(status)) {
            _exitCode = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            _exitCode = 128 + WTERMSIG(status);
        } else {
            _exitCode = 0;
        }
    }
    int fd = _masterFD;
    _masterFD = -1;
    [_lock unlock];

    if (fd >= 0) close(fd);

    NSString *message = [NSString stringWithFormat:@"\r\n[iAgent] 进程已结束 (exit=%ld)\r\n",
                         (long)(_exitCode == NSNotFound ? -1 : _exitCode)];
    [self appendBytes:(const uint8_t *)message.UTF8String length:strlen(message.UTF8String)];
    IAGLogInfo(@"终端会话 %@ 结束, pid=%d, exit=%ld", self.sessionId, self.pid, (long)_exitCode);
}

#pragma mark io

- (NSDictionary *)readSince:(NSUInteger)cursor
{
    [_lock lock];
    NSUInteger bufferStart = _totalWritten - _buffer.length;
    NSUInteger from = cursor;
    if (from < bufferStart) from = bufferStart;
    if (from > _totalWritten) from = _totalWritten;

    NSData *slice = [_buffer subdataWithRange:NSMakeRange(from - bufferStart, _totalWritten - from)];
    NSUInteger consumed = 0;
    NSString *text = IAGStringFromUTF8Lossy(slice, &consumed);

    NSDictionary *out = @{
        @"data": text ?: @"",
        @"cursor": @(from + consumed),
        @"alive": @(_alive),
        @"exitCode": (_exitCode == NSNotFound) ? (id)[NSNull null] : @(_exitCode),
        @"truncatedHead": @(cursor < bufferStart),
    };
    [_lock unlock];
    return out;
}

- (void)writeData:(NSData *)data
{
    if (data.length == 0) return;
    [_lock lock];
    int fd = _masterFD;
    [_lock unlock];
    if (fd < 0) return;

    const uint8_t *bytes = data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written > 0) {
            bytes += written;
            remaining -= (size_t)written;
            continue;
        }
        if (written < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
            if (poll(&pfd, 1, 1000) > 0) continue;
            return;
        }
        return;
    }
}

- (void)writeString:(NSString *)text
{
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    [self writeData:data];
}

- (void)resizeToColumns:(int)columns rows:(int)rows
{
    if (columns < 1) columns = 1;
    if (rows < 1) rows = 1;
    if (columns > 1000) columns = 1000;
    if (rows > 1000) rows = 1000;

    [_lock lock];
    self.columns = columns;
    self.rows = rows;
    int fd = _masterFD;
    [_lock unlock];
    if (fd < 0) return;

    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_col = (unsigned short)columns;
    size.ws_row = (unsigned short)rows;
    ioctl(fd, TIOCSWINSZ, &size);
    kill(self.pid, SIGWINCH);
}

- (void)close
{
    pid_t pid = self.pid;
    _readerRunning = NO;

    [_lock lock];
    BOOL wasAlive = _alive;
    [_lock unlock];

    if (wasAlive && pid > 0) {
        kill(pid, SIGHUP);
        for (int attempt = 0; attempt < 30; attempt++) {
            int status = 0;
            if (waitpid(pid, &status, WNOHANG) == pid) {
                wasAlive = NO;
                break;
            }
            usleep(10000);
        }
        if (wasAlive) {
            kill(-pid, SIGKILL);
            kill(pid, SIGKILL);
        }
    }

    [_lock lock];
    if (_masterFD >= 0) {
        close(_masterFD);
        _masterFD = -1;
    }
    _alive = NO;
    if (_exitCode == NSNotFound) _exitCode = 0;
    [_lock unlock];
}

@end

#pragma mark -

@implementation IAGTerminalManager {
    NSMutableDictionary<NSString *, IAGTerminalSession *> *_sessions;
    NSLock *_lock;
    NSUInteger _counter;
}

+ (instancetype)shared
{
    static IAGTerminalManager *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IAGTerminalManager alloc] init]; });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _sessions = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
        _counter = 0;
    }
    return self;
}

- (IAGTerminalSession *)openWithColumns:(int)columns
                                   rows:(int)rows
                                  shell:(NSString *)shell
                                  error:(NSString **)error
{
    if (columns < 2) columns = 80;
    if (rows < 2) rows = 24;

    NSString *shellPath = shell.length ? shell : nil;
    if (!shellPath) {
        // Prefer a real interactive shell from the jailbreak, fall back to sh.
        for (NSString *candidate in @[ @"/bin/zsh", @"/var/jb/bin/zsh", @"/bin/bash",
                                       @"/var/jb/bin/bash", @"/bin/sh" ]) {
            NSString *resolved = IAGResolveRootlessPath(candidate);
            if (IAGPathExists(resolved)) { shellPath = resolved; break; }
        }
    }
    if (!shellPath || !IAGPathExists(shellPath)) {
        shellPath = @"/bin/sh";
    }

    // Reap finished sessions, keeping at most a handful around for history.
    [self pruneSessions];

    [_lock lock];
    NSUInteger live = 0;
    for (IAGTerminalSession *session in _sessions.allValues) {
        if (session.alive) live++;
    }
    [_lock unlock];
    if (live >= kIAGTerminalMaxSessions) {
        if (error) *error = [NSString stringWithFormat:@"终端数量已达上限（%lu）", (unsigned long)kIAGTerminalMaxSessions];
        return nil;
    }

    NSString *shellName = shellPath.lastPathComponent;
    NSString *loginArgv0 = [@"-" stringByAppendingString:shellName ?: @"sh"];

    NSDictionary *environment = [IAGProcess defaultEnvironment];
    NSMutableArray<NSString *> *envList = [NSMutableArray array];
    for (NSString *key in environment) {
        [envList addObject:[NSString stringWithFormat:@"%@=%@", key, environment[key]]];
    }
    [envList addObject:@"IAG_TERMINAL=1"];

    char **argv = IAGBuildCStringArray(@[ loginArgv0 ]);
    char **envp = IAGBuildCStringArray(envList);
    if (!argv || !envp) {
        IAGFreeCStringArray(argv);
        IAGFreeCStringArray(envp);
        if (error) *error = @"内存不足";
        return nil;
    }

    int masterFD = -1;
    pid_t pid = -1;
    int savedErrno = 0;

    IAGForkPTYFn forkptyFn = IAGForkPTYFunction();
    if (forkptyFn) {
        struct winsize size;
        memset(&size, 0, sizeof(size));
        size.ws_col = (unsigned short)columns;
        size.ws_row = (unsigned short)rows;
        pid = forkptyFn(&masterFD, NULL, NULL, &size);
        savedErrno = errno;
        if (pid == 0) {
            // Child: only async-signal-safe calls from here on.
            execve(shellPath.fileSystemRepresentation, argv, envp);
            _exit(127);
        }
    } else {
        // Manual PTY setup for the unlikely case forkpty is unavailable.
        masterFD = posix_openpt(O_RDWR | O_NOCTTY);
        if (masterFD >= 0 && grantpt(masterFD) == 0 && unlockpt(masterFD) == 0) {
            char *slaveName = ptsname(masterFD);
            if (slaveName) {
                int slaveFD = open(slaveName, O_RDWR | O_NOCTTY);
                if (slaveFD >= 0) {
                    pid = fork();
                    savedErrno = errno;
                    if (pid == 0) {
                        setsid();
                        ioctl(slaveFD, TIOCSCTTY, 0);
                        dup2(slaveFD, STDIN_FILENO);
                        dup2(slaveFD, STDOUT_FILENO);
                        dup2(slaveFD, STDERR_FILENO);
                        if (slaveFD > STDERR_FILENO) close(slaveFD);
                        if (masterFD > STDERR_FILENO) close(masterFD);
                        execve(shellPath.fileSystemRepresentation, argv, envp);
                        _exit(127);
                    }
                    close(slaveFD);
                }
            }
        }
    }

    IAGFreeCStringArray(argv);
    IAGFreeCStringArray(envp);

    if (pid < 0 || masterFD < 0) {
        if (masterFD >= 0) close(masterFD);
        if (error) {
            *error = [NSString stringWithFormat:@"创建 PTY 失败: %s", strerror(savedErrno ?: EIO)];
        }
        return nil;
    }

    // Keep the master end blocking for writes, poll-driven for reads.
    int flags = fcntl(masterFD, F_GETFL, 0);
    if (flags >= 0) fcntl(masterFD, F_SETFL, flags & ~O_NONBLOCK);

    [_lock lock];
    _counter++;
    NSString *sessionId = [NSString stringWithFormat:@"t%lu", (unsigned long)_counter];
    IAGTerminalSession *session = [[IAGTerminalSession alloc] initWithIdentifier:sessionId
                                                                             fd:masterFD
                                                                            pid:pid
                                                                        columns:columns
                                                                           rows:rows
                                                                          shell:shellPath];
    _sessions[sessionId] = session;
    [_lock unlock];

    [session startReader];
    IAGLogInfo(@"终端会话已创建: %@ pid=%d shell=%@", sessionId, pid, shellPath);
    return session;
}

- (IAGTerminalSession *)sessionWithIdentifier:(NSString *)sessionId
{
    if (sessionId.length == 0) return nil;
    [_lock lock];
    IAGTerminalSession *session = _sessions[sessionId];
    [_lock unlock];
    return session;
}

- (NSArray<IAGTerminalSession *> *)allSessions
{
    [_lock lock];
    NSArray *all = _sessions.allValues;
    [_lock unlock];
    return [all sortedArrayUsingComparator:^NSComparisonResult(IAGTerminalSession *a, IAGTerminalSession *b) {
        return [a.sessionId compare:b.sessionId options:NSNumericSearch];
    }];
}

- (void)pruneSessions
{
    [_lock lock];
    NSMutableArray<NSString *> *dead = [NSMutableArray array];
    for (NSString *key in _sessions) {
        if (!_sessions[key].alive) [dead addObject:key];
    }
    // Keep the two most recent dead sessions for post-mortem output.
    [dead sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a compare:b options:NSNumericSearch];
    }];
    while (dead.count > 2) {
        NSString *key = dead.firstObject;
        [dead removeObjectAtIndex:0];
        [_sessions removeObjectForKey:key];
    }
    [_lock unlock];
}

- (void)closeAll
{
    [_lock lock];
    NSArray *all = _sessions.allValues;
    [_sessions removeAllObjects];
    [_lock unlock];
    for (IAGTerminalSession *session in all) [session close];
}

@end
