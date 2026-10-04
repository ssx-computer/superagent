//
//  IAGLog.m
//  iAgent
//

#import "IAGLog.h"
#import "IAGPaths.h"

#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>
#import <fcntl.h>
#import <pthread.h>
#import <string.h>
#import <stdlib.h>

static const unsigned long long kIAGLogRotateBytes = 4ULL * 1024ULL * 1024ULL;

static IAGLogLevel gLevel = IAGLogLevelInfo;
static BOOL gMirror = NO;
static int gLogFD = -1;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static NSString *gProcessTag = nil;

static void IAGLogOpenLocked(void)
{
    if (gLogFD >= 0) return;

    if (!gProcessTag) {
        NSString *name = NSProcessInfo.processInfo.processName ?: @"iagent";
        gProcessTag = [name copy];
    }

    NSString *path = IAGLogPath();
    IAGEnsureDirectory([path stringByDeletingLastPathComponent]);

    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) == 0 && (unsigned long long)st.st_size > kIAGLogRotateBytes) {
        NSString *rotated = [path stringByAppendingString:@".1"];
        unlink(rotated.fileSystemRepresentation);
        rename(path.fileSystemRepresentation, rotated.fileSystemRepresentation);
    }

    gLogFD = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
}

void IAGLogSetLevel(IAGLogLevel level)
{
    pthread_mutex_lock(&gLogLock);
    gLevel = level;
    pthread_mutex_unlock(&gLogLock);
}

IAGLogLevel IAGLogGetLevel(void)
{
    pthread_mutex_lock(&gLogLock);
    IAGLogLevel l = gLevel;
    pthread_mutex_unlock(&gLogLock);
    return l;
}

void IAGLogSetMirrorToStderr(BOOL mirror)
{
    pthread_mutex_lock(&gLogLock);
    gMirror = mirror;
    pthread_mutex_unlock(&gLogLock);
}

static const char *IAGLevelName(IAGLogLevel level)
{
    switch (level) {
        case IAGLogLevelDebug: return "DEBUG";
        case IAGLogLevelInfo:  return "INFO ";
        case IAGLogLevelWarn:  return "WARN ";
        case IAGLogLevelError: return "ERROR";
    }
    return "?????";
}

void IAGLogMessage(IAGLogLevel level, const char *file, int line, NSString *format, ...)
{
    @autoreleasepool {
        pthread_mutex_lock(&gLogLock);
        BOOL enabled = (level >= gLevel);
        BOOL mirror = gMirror;

        if (!enabled) {
            pthread_mutex_unlock(&gLogLock);
            return;
        }

        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);

        const char *base = file ? strrchr(file, '/') : NULL;
        base = base ? base + 1 : (file ?: "?");

        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct tm tmbuf;
        time_t secs = tv.tv_sec;
        localtime_r(&secs, &tmbuf);
        char stamp[32];
        strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tmbuf);

        NSString *lineString = [NSString stringWithFormat:@"%s.%03d [%s] [%s] %s:%d %@\n",
                                stamp, (int)(tv.tv_usec / 1000), IAGLevelName(level),
                                gProcessTag.UTF8String ?: "iagent", base, line, message];

        IAGLogOpenLocked();
        if (gLogFD >= 0) {
            NSData *data = [lineString dataUsingEncoding:NSUTF8StringEncoding];
            if (data.length) {
                ssize_t ignored = write(gLogFD, data.bytes, data.length);
                (void)ignored;
            }
        }
        if (mirror) {
            fputs(lineString.UTF8String, stderr);
            fflush(stderr);
        }
        pthread_mutex_unlock(&gLogLock);
    }
}

NSArray<NSString *> *IAGLogTail(NSUInteger maxLines)
{
    if (maxLines == 0) maxLines = 200;
    if (maxLines > 5000) maxLines = 5000;

    NSString *path = IAGLogPath();
    NSString *contents = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if (contents.length == 0) return @[];

    NSArray<NSString *> *all = [contents componentsSeparatedByString:@"\n"];
    if (all.count <= maxLines) return all;
    return [all subarrayWithRange:NSMakeRange(all.count - maxLines, maxLines)];
}

void IAGLogClear(void)
{
    pthread_mutex_lock(&gLogLock);
    if (gLogFD >= 0) {
        close(gLogFD);
        gLogFD = -1;
    }
    unlink(IAGLogPath().fileSystemRepresentation);
    pthread_mutex_unlock(&gLogLock);
}
