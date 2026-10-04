//
//  IAGTerminal.h
//  iAgent
//
//  Real interactive PTY sessions (forkpty when available, posix_openpt + fork
//  otherwise) so the web UI can offer an actual terminal, not a command runner.
//
//  Output is kept in a bounded ring buffer and addressed by a monotonically
//  increasing byte cursor, which makes the client side a trivial poll loop and
//  tolerates a truncated multi-byte character at the end of a read.
//

#ifndef IAG_TERMINAL_H
#define IAG_TERMINAL_H

#import <Foundation/Foundation.h>
#import <sys/types.h>

@interface IAGTerminalSession : NSObject

@property (nonatomic, copy, readonly)   NSString *sessionId;
@property (nonatomic, assign, readonly) pid_t pid;
@property (nonatomic, assign, readonly) int columns;
@property (nonatomic, assign, readonly) int rows;
@property (nonatomic, copy, readonly)   NSString *shellPath;

- (BOOL)alive;
- (NSInteger)exitCode;          // NSNotFound while still running

/// Total number of bytes ever produced by this terminal.
- (NSUInteger)cursor;

/// { data: String, cursor: Number, alive: Bool, exitCode: Number|null }
- (NSDictionary *)readSince:(NSUInteger)cursor;

- (void)writeString:(NSString *)text;
- (void)writeData:(NSData *)data;
- (void)resizeToColumns:(int)columns rows:(int)rows;
- (void)close;

- (NSDictionary *)statusJSON;

@end

@interface IAGTerminalManager : NSObject

+ (instancetype)shared;

- (IAGTerminalSession *)openWithColumns:(int)columns
                                   rows:(int)rows
                                  shell:(NSString *)shell
                                  error:(NSString **)error;

- (IAGTerminalSession *)sessionWithIdentifier:(NSString *)sessionId;
- (NSArray<IAGTerminalSession *> *)allSessions;
- (void)closeAll;

@end

#endif /* IAG_TERMINAL_H */
