//
//  IAGProcess.h
//  iAgent
//
//  Non-interactive subprocess execution built on posix_spawn. Nothing here uses
//  NSTask (unavailable to App Store code and unnecessary), and no shell string is
//  ever built without quoting.
//

#ifndef IAG_PROCESS_H
#define IAG_PROCESS_H

#import <Foundation/Foundation.h>
#import <sys/types.h>

@interface IAGProcessResult : NSObject
@property (nonatomic, assign) NSInteger exitCode;        // -1 when launch failed
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, copy)   NSString *standardOutput;
@property (nonatomic, copy)   NSString *standardError;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) BOOL timedOut;
@property (nonatomic, assign) BOOL outputTruncated;
@property (nonatomic, copy)   NSString *launchError;     // non-nil when spawn failed

/// stdout, then stderr, in that order, with a separator when both are non-empty.
- (NSString *)combinedOutput;
/// true when the process ran and returned 0.
- (BOOL)succeeded;
@end

@interface IAGProcess : NSObject

+ (IAGProcessResult *)runShell:(NSString *)command
                     directory:(NSString *)directory
                       timeout:(NSTimeInterval)timeout
                     maxOutput:(NSUInteger)maxOutput
                   environment:(NSDictionary<NSString *, NSString *> *)environment;

+ (IAGProcessResult *)runExecutable:(NSString *)executable
                          arguments:(NSArray<NSString *> *)arguments
                          directory:(NSString *)directory
                            timeout:(NSTimeInterval)timeout
                          maxOutput:(NSUInteger)maxOutput
                        environment:(NSDictionary<NSString *, NSString *> *)environment;

/// PATH is rebuilt from the detected jailbreak root so that /var/jb/bin and the
/// hidden RootHide equivalent both work.
+ (NSDictionary<NSString *, NSString *> *)defaultEnvironment;

/// Fully resolved absolute path of a program, searching PATH and the jailbreak
/// root. Returns nil when nothing executable was found.
+ (NSString *)which:(NSString *)program;

@end

#endif /* IAG_PROCESS_H */
