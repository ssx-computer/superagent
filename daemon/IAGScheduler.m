//
//  IAGScheduler.m
//  iAgent
//

#import "IAGScheduler.h"
#import "IAGPaths.h"
#import "IAGProcess.h"
#import "IAGConfig.h"
#import "IAGJSON.h"
#import "IAGLog.h"
#import "IAGUtil.h"

#import <time.h>

#pragma mark - cron parsing

typedef struct {
    BOOL wildcard;
    BOOL values[64];
} IAGCronField;

typedef struct {
    BOOL valid;
    IAGCronField minute;   // 0-59
    IAGCronField hour;     // 0-23
    IAGCronField dom;      // 1-31
    IAGCronField month;    // 1-12
    IAGCronField dow;      // 0-6 (0 = Sunday)
} IAGCronSpec;

static void IAGCronFieldClear(IAGCronField *field)
{
    memset(field, 0, sizeof(*field));
}

static BOOL IAGCronParseField(NSString *text, int minimum, int maximum, IAGCronField *field)
{
    IAGCronFieldClear(field);
    if (text.length == 0) return NO;
    if ([text isEqualToString:@"*"]) {
        field->wildcard = YES;
        for (int i = minimum; i <= maximum; i++) field->values[i] = YES;
        return YES;
    }

    for (NSString *piece in [text componentsSeparatedByString:@","]) {
        NSString *part = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (part.length == 0) return NO;

        int step = 1;
        NSRange slash = [part rangeOfString:@"/"];
        if (slash.location != NSNotFound) {
            NSString *stepText = [part substringFromIndex:slash.location + 1];
            step = stepText.intValue;
            if (step <= 0) return NO;
            part = [part substringToIndex:slash.location];
        }

        int low = minimum, high = maximum;
        if ([part isEqualToString:@"*"]) {
            low = minimum;
            high = maximum;
        } else {
            NSRange dash = [part rangeOfString:@"-"];
            if (dash.location != NSNotFound) {
                low = [part substringToIndex:dash.location].intValue;
                high = [part substringFromIndex:dash.location + 1].intValue;
            } else {
                low = part.intValue;
                high = (slash.location != NSNotFound) ? maximum : low;
            }
        }

        if (low < minimum || high > maximum || low > high) return NO;
        for (int i = low; i <= high; i += step) field->values[i] = YES;
    }
    return YES;
}

static BOOL IAGCronParse(NSString *schedule, IAGCronSpec *spec)
{
    memset(spec, 0, sizeof(*spec));
    if (schedule.length == 0) return NO;

    NSArray<NSString *> *fields = [schedule componentsSeparatedByCharactersInSet:
                                   [NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *field in fields) {
        if (field.length) [parts addObject:field];
    }
    if (parts.count != 5) return NO;

    if (!IAGCronParseField(parts[0], 0, 59, &spec->minute)) return NO;
    if (!IAGCronParseField(parts[1], 0, 23, &spec->hour)) return NO;
    if (!IAGCronParseField(parts[2], 1, 31, &spec->dom)) return NO;
    if (!IAGCronParseField(parts[3], 1, 12, &spec->month)) return NO;
    if (!IAGCronParseField(parts[4], 0, 6, &spec->dow)) return NO;
    spec->valid = YES;
    return YES;
}

static BOOL IAGCronMatches(const IAGCronSpec *spec, const struct tm *time)
{
    if (!spec->minute.values[time->tm_min]) return NO;
    if (!spec->hour.values[time->tm_hour]) return NO;
    if (!spec->month.values[time->tm_mon + 1]) return NO;

    BOOL domMatch = spec->dom.values[time->tm_mday];
    BOOL dowMatch = spec->dow.values[time->tm_wday];

    if (spec->dom.wildcard && spec->dow.wildcard) return YES;
    if (spec->dom.wildcard) return dowMatch;
    if (spec->dow.wildcard) return domMatch;
    return domMatch || dowMatch;   // classic cron ORs the two day fields
}

#pragma mark - task

@implementation IAGCronTask

- (NSDictionary *)json
{
    return @{
        @"id": self.taskId ?: @"",
        @"schedule": self.schedule ?: @"",
        @"command": self.command ?: @"",
        @"enabled": @(self.enabled),
        @"lastRun": @(self.lastRun),
        @"nextRun": @(self.nextRun),
        @"lastResult": self.lastResult ?: @"",
        @"lastExitCode": @(self.lastExitCode),
        @"createdAt": @(self.createdAt),
    };
}

@end

#pragma mark - scheduler

@implementation IAGScheduler {
    NSMutableArray<IAGCronTask *> *_tasks;
    NSLock *_lock;
    dispatch_source_t _timer;
    dispatch_queue_t _queue;
    NSUInteger _counter;
}

+ (instancetype)shared
{
    static IAGScheduler *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IAGScheduler alloc] init]; });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _tasks = [NSMutableArray array];
        _lock = [[NSLock alloc] init];
        _queue = dispatch_queue_create("com.dsh.iagent.scheduler", DISPATCH_QUEUE_SERIAL);
        [self reload];
    }
    return self;
}

#pragma mark persistence

- (void)reload
{
    NSArray *stored = [NSArray arrayWithContentsOfFile:IAGCronPath()];
    NSMutableArray<IAGCronTask *> *loaded = [NSMutableArray array];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSUInteger maxCounter = 0;

    for (NSDictionary *entry in stored) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        IAGCronTask *task = [[IAGCronTask alloc] init];
        task.taskId = IAGDictString(entry, @"id", nil);
        task.schedule = IAGDictString(entry, @"schedule", @"");
        task.command = IAGDictString(entry, @"command", @"");
        task.enabled = IAGDictBool(entry, @"enabled", YES);
        task.lastRun = IAGDictDouble(entry, @"lastRun", 0);
        task.lastResult = IAGDictString(entry, @"lastResult", @"");
        task.lastExitCode = IAGDictInteger(entry, @"lastExitCode", 0);
        task.createdAt = IAGDictDouble(entry, @"createdAt", now);
        if (task.taskId.length == 0) {
            task.taskId = [NSString stringWithFormat:@"cron-%lu",
                           (unsigned long)(++maxCounter)];
        }
        NSString *suffix = [[task.taskId componentsSeparatedByString:@"-"] lastObject];
        NSUInteger numeric = (NSUInteger)suffix.integerValue;
        if (numeric > maxCounter) maxCounter = numeric;
        task.nextRun = [IAGScheduler nextRunForSchedule:task.schedule after:now];
        [loaded addObject:task];
    }

    [_lock lock];
    [_tasks setArray:loaded];
    _counter = maxCounter;
    [_lock unlock];

    if (loaded.count) IAGLogInfo(@"已加载 %lu 个定时任务", (unsigned long)loaded.count);
}

- (void)save
{
    [_lock lock];
    NSMutableArray *array = [NSMutableArray array];
    for (IAGCronTask *task in _tasks) [array addObject:[task json]];
    [_lock unlock];

    IAGEnsureDirectory(IAGDataDir());
    if (![array writeToFile:IAGCronPath() atomically:YES]) {
        IAGLogError(@"定时任务写入失败: %@", IAGCronPath());
    }
}

#pragma mark lifecycle

- (void)start
{
    if (_timer) return;

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                              15 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        [weakSelf tick];
    });
    dispatch_resume(_timer);
    IAGLogInfo(@"定时任务调度器已启动（%lu 个任务）", (unsigned long)self.tasks.count);
}

- (void)stop
{
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

- (void)tick
{
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSMutableArray<IAGCronTask *> *due = [NSMutableArray array];

    [_lock lock];
    for (IAGCronTask *task in _tasks) {
        if (!task.enabled) continue;
        if (task.nextRun <= 0) continue;
        if (task.nextRun <= now) [due addObject:task];
    }
    [_lock unlock];

    for (IAGCronTask *task in due) {
        [self executeTask:task];
    }
}

- (void)executeTask:(IAGCronTask *)task
{
    NSString *command = [task.command copy];
    NSString *taskId = [task.taskId copy];
    IAGLogInfo(@"执行定时任务 %@: %@", taskId, IAGCollapseWhitespace(command));

    dispatch_async(_queue, ^{
        IAGProcessResult *result = [IAGProcess runShell:command
                                              directory:[[IAGConfig shared] workDir]
                                                timeout:600
                                              maxOutput:128 * 1024
                                            environment:nil];
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;

        [self->_lock lock];
        IAGCronTask *current = nil;
        for (IAGCronTask *candidate in self->_tasks) {
            if ([candidate.taskId isEqualToString:taskId]) { current = candidate; break; }
        }
        if (current) {
            current.lastRun = now;
            current.lastExitCode = result.exitCode;
            NSString *combined = [result combinedOutput];
            NSMutableString *summary = [NSMutableString string];
            [summary appendFormat:@"exit=%ld %.1fs ", (long)result.exitCode, result.duration];
            if (result.timedOut) [summary appendString:@"[超时] "];
            if (result.launchError.length) [summary appendFormat:@"[启动失败: %@] ", result.launchError];
            [summary appendString:IAGTruncateString(IAGCollapseWhitespace(combined), 500)];
            current.lastResult = summary;
            current.nextRun = [IAGScheduler nextRunForSchedule:current.schedule after:now];
        }
        [self->_lock unlock];

        [self save];
    });
}

#pragma mark CRUD

- (NSArray<IAGCronTask *> *)tasks
{
    [_lock lock];
    NSArray *copy = [_tasks copy];
    [_lock unlock];
    return copy;
}

- (IAGCronTask *)taskWithIdentifier:(NSString *)taskId
{
    if (taskId.length == 0) return nil;
    [_lock lock];
    IAGCronTask *found = nil;
    for (IAGCronTask *task in _tasks) {
        if ([task.taskId isEqualToString:taskId]) { found = task; break; }
    }
    [_lock unlock];
    return found;
}

- (IAGCronTask *)addTaskWithSchedule:(NSString *)schedule
                             command:(NSString *)command
                             enabled:(BOOL)enabled
                               error:(NSString **)error
{
    if (![IAGScheduler isValidSchedule:schedule]) {
        if (error) *error = @"cron 表达式无效（需要 5 个字段：分 时 日 月 周）";
        return nil;
    }
    if (command.length == 0) {
        if (error) *error = @"命令不能为空";
        return nil;
    }

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    IAGCronTask *task = [[IAGCronTask alloc] init];
    [_lock lock];
    _counter++;
    task.taskId = [NSString stringWithFormat:@"cron-%lu", (unsigned long)_counter];
    [_lock unlock];
    task.schedule = schedule;
    task.command = command;
    task.enabled = enabled;
    task.createdAt = now;
    task.nextRun = [IAGScheduler nextRunForSchedule:schedule after:now];

    [_lock lock];
    [_tasks addObject:task];
    [_lock unlock];

    [self save];
    IAGLogInfo(@"新增定时任务 %@ (%@) 下次运行: %.0f", task.taskId, schedule, task.nextRun);
    return task;
}

- (BOOL)removeTask:(NSString *)taskId
{
    if (taskId.length == 0) return NO;
    BOOL removed = NO;
    [_lock lock];
    for (NSUInteger i = 0; i < _tasks.count; i++) {
        if ([_tasks[i].taskId isEqualToString:taskId]) {
            [_tasks removeObjectAtIndex:i];
            removed = YES;
            break;
        }
    }
    [_lock unlock];
    if (removed) [self save];
    return removed;
}

- (BOOL)setTask:(NSString *)taskId enabled:(BOOL)enabled
{
    IAGCronTask *task = [self taskWithIdentifier:taskId];
    if (!task) return NO;
    task.enabled = enabled;
    if (enabled) {
        task.nextRun = [IAGScheduler nextRunForSchedule:task.schedule after:[NSDate date].timeIntervalSince1970];
    }
    [self save];
    return YES;
}

- (void)runTaskNow:(NSString *)taskId
{
    IAGCronTask *task = [self taskWithIdentifier:taskId];
    if (task) [self executeTask:task];
}

#pragma mark schedule math

+ (BOOL)isValidSchedule:(NSString *)schedule
{
    IAGCronSpec spec;
    return IAGCronParse(schedule, &spec);
}

+ (NSTimeInterval)nextRunForSchedule:(NSString *)schedule after:(NSTimeInterval)reference
{
    IAGCronSpec spec;
    if (!IAGCronParse(schedule, &spec)) return 0;

    time_t start = (time_t)reference + 60;
    struct tm time;
    localtime_r(&start, &time);
    time.tm_sec = 0;
    start = mktime(&time);

    // Two years of minutes, which is more than enough for any cron expression.
    for (long i = 0; i < 527040L * 2; i++) {
        struct tm current;
        localtime_r(&start, &current);
        if (IAGCronMatches(&spec, &current)) return (NSTimeInterval)start;
        start += 60;
    }
    return 0;
}

@end
