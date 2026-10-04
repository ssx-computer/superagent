//
//  IAGDaemon.h
//  iAgent
//
//  Wires configuration, the tool registry, the agent, the PTY manager, the cron
//  scheduler, the SpringBoard bridge and the loopback HTTP server together, and
//  implements the REST/SSE control plane described in docs/api.md.
//

#ifndef IAG_DAEMON_H
#define IAG_DAEMON_H

#import <Foundation/Foundation.h>

@interface IAGDaemon : NSObject

+ (instancetype)shared;

- (BOOL)startWithError:(NSError **)error;
- (void)stop;

/// Temporary listen-port override (command line only; never persisted).
@property (nonatomic, assign) uint16_t portOverride;

@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) NSTimeInterval startedAt;

@end

#endif /* IAG_DAEMON_H */
