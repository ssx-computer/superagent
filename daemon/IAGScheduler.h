//
//  IAGScheduler.h
//  iAgent
//
//  A small cron implementation for on-device scheduled commands.
//  Supports the classic five fields with `*`, `a`, `a-b`, `a,b,c`, `*/n` and
//  `a-b/n`, evaluated in the device's local time zone.
//

#ifndef IAG_SCHEDULER_H
#define IAG_SCHEDULER_H

#import <Foundation/Foundation.h>

@interface IAGCronTask : NSObject
@property (nonatomic, copy)   NSString *taskId;
@property (nonatomic, copy)   NSString *schedule;
@property (nonatomic, copy)   NSString *command;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) NSTimeInterval lastRun;      // unix seconds, 0 = never
@property (nonatomic, assign) NSTimeInterval nextRun;
@property (nonatomic, copy)   NSString *lastResult;
@property (nonatomic, assign) NSInteger lastExitCode;
@property (nonatomic, assign) NSTimeInterval createdAt;
- (NSDictionary *)json;
@end

@interface IAGScheduler : NSObject

+ (instancetype)shared;

- (void)start;
- (void)stop;

- (NSArray<IAGCronTask *> *)tasks;
- (IAGCronTask *)taskWithIdentifier:(NSString *)taskId;

- (IAGCronTask *)addTaskWithSchedule:(NSString *)schedule
                             command:(NSString *)command
                             enabled:(BOOL)enabled
                               error:(NSString **)error;

- (BOOL)removeTask:(NSString *)taskId;
- (BOOL)setTask:(NSString *)taskId enabled:(BOOL)enabled;
- (void)runTaskNow:(NSString *)taskId;

- (void)reload;
- (void)save;

+ (BOOL)isValidSchedule:(NSString *)schedule;
/// 0 when no matching time was found within ~2 years.
+ (NSTimeInterval)nextRunForSchedule:(NSString *)schedule after:(NSTimeInterval)reference;

@end

#endif /* IAG_SCHEDULER_H */
