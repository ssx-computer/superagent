//
//  IAGSessionStore.h
//  iAgent
//
//  Conversation persistence: one JSON file per session under
//  /var/mobile/Library/iAgent/sessions/. Messages are stored in the OpenAI wire
//  shape (role / content / tool_calls / tool_call_id) plus a few local extras so
//  the UI can render them without guessing.
//

#ifndef IAG_SESSION_STORE_H
#define IAG_SESSION_STORE_H

#import <Foundation/Foundation.h>

@interface IAGSession : NSObject
@property (nonatomic, copy)   NSString *sessionId;
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, assign) NSTimeInterval createdAt;
@property (nonatomic, assign) NSTimeInterval updatedAt;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *messages;

- (NSDictionary *)summaryJSON;    // for the session list
- (NSDictionary *)fullJSON;       // includes messages
@end

@interface IAGSessionStore : NSObject

+ (instancetype)shared;

- (NSArray<IAGSession *> *)sessions;                       // newest first
- (IAGSession *)sessionWithIdentifier:(NSString *)sessionId;
- (IAGSession *)createSessionWithTitle:(NSString *)title;
- (BOOL)deleteSession:(NSString *)sessionId;
- (BOOL)renameSession:(NSString *)sessionId title:(NSString *)title;

- (void)appendMessage:(NSDictionary *)message toSession:(NSString *)sessionId;
- (void)saveSession:(IAGSession *)session;

/// Messages shaped for the model: local-only keys removed, oldest trimmed.
- (NSArray<NSDictionary *> *)modelMessagesForSession:(IAGSession *)session limit:(NSInteger)limit;

- (NSUInteger)sessionCount;
- (NSString *)suggestTitleFromMessage:(NSString *)message;

@end

#endif /* IAG_SESSION_STORE_H */
