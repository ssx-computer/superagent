//
//  IAGAgent.h
//  iAgent
//
//  The agent loop: model -> tool calls -> tool results -> model, until the model
//  answers without asking for another tool (or the step budget runs out).
//
//  Runs synchronously on the caller's thread (the HTTP connection thread) so the
//  SSE writer observes every event in order.
//

#ifndef IAG_AGENT_H
#define IAG_AGENT_H

#import <Foundation/Foundation.h>

/// event: delta | reason | tool_call | tool_result | approval_required | done | error
typedef void (^IAGAgentEventBlock)(NSString *event, NSDictionary *payload);

/// Blocks the run until the user approves/denies (or the timeout expires).
@interface IAGApprovalCenter : NSObject
+ (instancetype)shared;
- (BOOL)requestApprovalForIdentifier:(NSString *)identifier timeout:(NSTimeInterval)timeout;
- (BOOL)resolveApprovalForIdentifier:(NSString *)identifier allow:(BOOL)allow;
- (NSUInteger)pendingCount;
- (void)cancelAll;
@end

@interface IAGAgent : NSObject

+ (instancetype)shared;

- (void)runSession:(NSString *)sessionId
           message:(NSString *)message
      eventHandler:(IAGAgentEventBlock)eventHandler;

- (void)abortSession:(NSString *)sessionId;
- (BOOL)isRunningSession:(NSString *)sessionId;
- (NSArray<NSString *> *)runningSessions;

@end

#endif /* IAG_AGENT_H */
