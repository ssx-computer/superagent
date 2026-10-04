//
//  IAGProcess.m
//  iAgent
//

#import "IAGProcess.h"
#import "IAGPaths.h"
#import "IAGUtil.h"
#import "IAGLog.h"

#import <spawn.h>
#import <poll.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <dlfcn.h>
#import <sys/wait.h>
#import <sys/stat.h>

extern char **environ;

@implementation IAGProcessResult

- (BOOL)succeeded { return self.exitCode == 0 && self.launchError == nil && !self.timedOut; }

- (NSString *)combinedOutput
{
    NSString *out = _standardOutput ?: @"";
    NSString *err = _standardError ?: @"";
    if (out.length && err.length) return [NSString stringWithFormat:@"%@\n[stderr]\n%@", out, err];
    if (out.length) return out;
    return err;
}

@end

#pragma mark -

@implementation IAGProcess

#pragma mark environment

+ (NSDictionary<NSString *, NSString *> *)defaultEnvironment
{
    NSMutableDictionary<NSString *, NSString *> *env = [NSMutableDictionary dictionary];

    NSString *jailbreakRoot = IAGJailbreakRoot();
    NSMutableArray<NSString *> *pathComponents = [NSMutableArray array];
    if (jailbreakRoot.length && ![jailbreakRoot isEqualToString:@"/"]) {
        [pathComponents addObject:[jailbreakRoot stringByAppendingPathComponent:@"usr/bin"]];
        [pathComponents addObject:[jailbreakRoot stringByAppendingPathComponent:@"bin"]];
        [pathComponents addObject:[jailbreakRoot stringByAppendingPathComponent:@"usr/sbin"]];
        [pathComponents addObject:[jailbreakRoot stringByAppendingPathComponent:@"sbin"]];
    } else {
        [pathComponents addObject:@"/usr/local/bin"];
    }
    [pathComponents addObjectsFromArray:@[ @"/usr/bin", @"/bin", @"/usr/sbin", @"/sbin" ]];

    env[@"PATH"] = [pathComponents componentsJoinedByString:@":"];
    env[@"HOME"] = IAGIsRoot() ? @"/var/root" : @"/var/mobile";
    env[@"USER"] = IAGUserName();
    env[@"LOGNAME"] = IAGUserName();
    env[@"SHELL"] = @"/bin/sh";
    env[@"TERM"] = @"xterm-256color";
    env[@"LANG"] = @"zh_CN.UTF-8";
    env[@"LC_ALL"] = @"zh_CN.UTF-8";
    env[@"TMPDIR"] = NSTemporaryDirectory() ?: @"/tmp";
    // Handy for scripts written by the agent: never hardcode /var/jb.
    env[@"IAG_JBROOT"] = jailbreakRoot.length ? jailbreakRoot : @"/";
    env[@"IAG_ROOTLESS"] = IAGIsRootless() ? @"1" : @"0";
    env[@"IAG_USER"] = IAGUserName();
    return env;
}

#pragma mark spawn plumbing

/// posix_spawn_file_actions_addchdir_np is not declared in every SDK, so bind it
/// dynamically instead of guessing at availability macros.
static int IAGSpawnAddChdir(posix_spawn_file_actions_t *actions, const char *path)
{
    static int (*addChdir)(posix_spawn_file_actions_t *, const char *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        addChdir = (int (*)(posix_spawn_file_actions_t *, const char *))
            dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
    });
    if (addChdir) return addChdir(actions, path);
    return -1;
}

static char **IAGBuildArgv(NSArray<NSString *> *arguments)
{
    NSUInteger count = arguments.count;
    char **argv = calloc(count + 1, sizeof(char *));
    if (!argv) return NULL;
    for (NSUInteger i = 0; i < count; i++) {
        argv[i] = strdup([arguments[i] UTF8String] ?: "");
        if (!argv[i]) {
            for (NSUInteger j = 0; j < i; j++) free(argv[j]);
            free(argv);
            return NULL;
        }
    }
    argv[count] = NULL;
    return argv;
}

static void IAGFreeArgv(char **argv)
{
    if (!argv) return;
    for (NSUInteger i = 0; argv[i]; i++) free(argv[i]);
    free(argv);
}

static char **IAGBuildEnvp(NSDictionary<NSString *, NSString *> *environment)
{
    if (environment.count == 0) return NULL;
    char **envp = calloc(environment.count + 1, sizeof(char *));
    if (!envp) return NULL;
    NSUInteger index = 0;
    for (NSString *key in environment) {
        NSString *entry = [NSString stringWithFormat:@"%@=%@", key, environment[key]];
        envp[index] = strdup(entry.UTF8String ?: "");
        if (!envp[index]) {
            for (NSUInteger j = 0; j < index; j++) free(envp[j]);
            free(envp);
            return NULL;
        }
        index++;
    }
    envp[index] = NULL;
    return envp;
}

static void IAGFreeEnvp(char **envp)
{
    if (!envp) return;
    for (NSUInteger i = 0; envp[i]; i++) free(envp[i]);
    free(envp);
}

static NSInteger IAGExitCodeFromStatus(int status)
{
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

#pragma mark core runner

+ (IAGProcessResult *)runExecutable:(NSString *)executable
                          arguments:(NSArray<NSString *> *)arguments
                          directory:(NSString *)directory
                            timeout:(NSTimeInterval)timeout
                          maxOutput:(NSUInteger)maxOutput
                        environment:(NSDictionary<NSString *, NSString *> *)environment
{
    IAGProcessResult *result = [[IAGProcessResult alloc] init];
    result.exitCode = -1;
    if (maxOutput == 0) maxOutput = 512 * 1024;
    if (timeout <= 0) timeout = 30;

    NSTimeInterval start = [NSDate date].timeIntervalSince1970;

    if (executable.length == 0 || !IAGPathExists(executable)) {
        result.launchError = [NSString stringWithFormat:@"可执行文件不存在: %@", executable ?: @"(nil)"];
        result.duration = 0;
        return result;
    }

    int outPipe[2] = { -1, -1 };
    int errPipe[2] = { -1, -1 };
    if (pipe(outPipe) != 0 || pipe(errPipe) != 0) {
        result.launchError = [NSString stringWithFormat:@"pipe() 失败: %s", strerror(errno)];
        if (outPipe[0] >= 0) { close(outPipe[0]); close(outPipe[1]); }
        return result;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outPipe[0]);
    posix_spawn_file_actions_addclose(&actions, errPipe[0]);
    posix_spawn_file_actions_addclose(&actions, outPipe[1]);
    posix_spawn_file_actions_addclose(&actions, errPipe[1]);
    if (directory.length) {
        if (IAGSpawnAddChdir(&actions, directory.fileSystemRepresentation) != 0) {
            IAGLogWarn(@"无法设置子进程工作目录: %@", directory);
        }
    }

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    short flags = POSIX_SPAWN_SETPGROUP;
    posix_spawnattr_setflags(&attributes, flags);
    posix_spawnattr_setpgroup(&attributes, 0);   // new process group: kill() takes the whole tree

    NSMutableArray<NSString *> *argvList = [NSMutableArray arrayWithObject:executable];
    [argvList addObjectsFromArray:arguments ?: @[]];

    char **argv = IAGBuildArgv(argvList);
    char **envp = IAGBuildEnvp(environment ?: [self defaultEnvironment]);

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, executable.fileSystemRepresentation,
                                  &actions, &attributes, argv, envp);

    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    IAGFreeArgv(argv);
    IAGFreeEnvp(envp);

    close(outPipe[1]);
    close(errPipe[1]);

    if (spawnResult != 0) {
        close(outPipe[0]);
        close(errPipe[0]);
        result.launchError = [NSString stringWithFormat:@"posix_spawn 失败: %s", strerror(spawnResult)];
        result.duration = [NSDate date].timeIntervalSince1970 - start;
        return result;
    }

    result.pid = pid;

    // Drain both pipes until EOF or the deadline.
    int fds[2] = { outPipe[0], errPipe[0] };
    BOOL eof[2] = { NO, NO };
    NSMutableData *buffers[2] = { [NSMutableData data], [NSMutableData data] };
    NSUInteger stored[2] = { 0, 0 };
    NSTimeInterval deadline = start + timeout;

    while (!(eof[0] && eof[1])) {
        NSTimeInterval remaining = deadline - [NSDate date].timeIntervalSince1970;
        if (remaining <= 0) {
            result.timedOut = YES;
            break;
        }
        struct pollfd pollFDs[2];
        int map[2];
        nfds_t count = 0;
        for (int i = 0; i < 2; i++) {
            if (eof[i]) continue;
            pollFDs[count].fd = fds[i];
            pollFDs[count].events = POLLIN;
            pollFDs[count].revents = 0;
            map[count] = i;
            count++;
        }
        if (count == 0) break;

        int ready = poll(pollFDs, count, (int)(remaining * 1000.0));
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ready == 0) {
            result.timedOut = YES;
            break;
        }
        for (nfds_t k = 0; k < count; k++) {
            if (!(pollFDs[k].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            uint8_t temp[8192];
            ssize_t got = read(pollFDs[k].fd, temp, sizeof(temp));
            if (got > 0) {
                int which = map[k];
                if (stored[which] + (NSUInteger)got <= maxOutput) {
                    [buffers[which] appendBytes:temp length:(NSUInteger)got];
                    stored[which] += (NSUInteger)got;
                } else if (stored[which] < maxOutput) {
                    NSUInteger room = maxOutput - stored[which];
                    [buffers[which] appendBytes:temp length:room];
                    stored[which] = maxOutput;
                    result.outputTruncated = YES;
                } else {
                    result.outputTruncated = YES;
                }
            } else if (got == 0) {
                eof[map[k]] = YES;
            } else {
                if (errno == EINTR || errno == EAGAIN) continue;
                eof[map[k]] = YES;
            }
        }
    }

    // Reap the child. Timeout means: kill the process group, then the child.
    int status = 0;
    pid_t waited = 0;
    if (result.timedOut) {
        kill(-pid, SIGKILL);
        kill(pid, SIGKILL);
    }
    for (int attempt = 0; attempt < 100; attempt++) {
        waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid || (waited < 0 && errno == ECHILD)) break;
        usleep(10000);   // 10ms
    }
    if (waited != pid) {
        // Last resort: give up on the exit code rather than block forever.
        kill(-pid, SIGKILL);
        kill(pid, SIGKILL);
        result.exitCode = -1;
    } else {
        result.exitCode = IAGExitCodeFromStatus(status);
    }

    close(fds[0]);
    close(fds[1]);

    NSUInteger consumedOut = 0, consumedErr = 0;
    result.standardOutput = IAGStringFromUTF8Lossy(buffers[0], &consumedOut);
    result.standardError = IAGStringFromUTF8Lossy(buffers[1], &consumedErr);
    result.duration = [NSDate date].timeIntervalSince1970 - start;

    if (result.timedOut) {
        IAGLogWarn(@"命令超时(%0.fs) pid=%d: %@ %@", timeout, pid, executable, arguments);
    }
    return result;
}

+ (IAGProcessResult *)runShell:(NSString *)command
                     directory:(NSString *)directory
                       timeout:(NSTimeInterval)timeout
                     maxOutput:(NSUInteger)maxOutput
                   environment:(NSDictionary<NSString *, NSString *> *)environment
{
    if (command.length == 0) {
        IAGProcessResult *empty = [[IAGProcessResult alloc] init];
        empty.exitCode = 0;
        empty.standardOutput = @"";
        empty.standardError = @"";
        return empty;
    }

    NSString *shell = IAGResolveRootlessPath(@"/bin/sh");
    if (!IAGPathExists(shell)) shell = @"/bin/sh";

    return [self runExecutable:shell
                     arguments:@[ @"-c", command ]
                     directory:directory
                       timeout:timeout
                     maxOutput:maxOutput
                   environment:environment];
}

#pragma mark which

+ (NSString *)which:(NSString *)program
{
    if (program.length == 0) return nil;
    if ([program hasPrefix:@"/"]) {
        return IAGPathExists(program) ? program : nil;
    }
    NSDictionary *env = [self defaultEnvironment];
    NSArray<NSString *> *components = [env[@"PATH"] componentsSeparatedByString:@":"];
    for (NSString *directory in components) {
        NSString *candidate = [directory stringByAppendingPathComponent:program];
        struct stat st;
        if (stat(candidate.fileSystemRepresentation, &st) == 0 && (st.st_mode & S_IXUSR)) {
            return candidate;
        }
    }
    return nil;
}

@end
