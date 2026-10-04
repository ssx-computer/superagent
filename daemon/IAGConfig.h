//
//  IAGConfig.h
//  iAgent
//
//  Configuration store shared by the daemon and the SpringBoard tweak.
//  Persisted as a plist at /var/mobile/Library/iAgent/config.plist so both
//  processes (and the web UI) read exactly the same file.
//

#ifndef IAG_CONFIG_H
#define IAG_CONFIG_H

#import <Foundation/Foundation.h>

// Keys (also used verbatim by the REST API).
extern NSString *const kIAGKeyBaseURL;
extern NSString *const kIAGKeyAPIKey;
extern NSString *const kIAGKeyModel;
extern NSString *const kIAGKeyTemperature;
extern NSString *const kIAGKeyMaxTokens;
extern NSString *const kIAGKeySystemPrompt;
extern NSString *const kIAGKeyPort;
extern NSString *const kIAGKeyAuthToken;
extern NSString *const kIAGKeyApprovalMode;      // auto | dangerous | always
extern NSString *const kIAGKeyMaxSteps;
extern NSString *const kIAGKeyShellTimeout;
extern NSString *const kIAGKeyWorkDir;
extern NSString *const kIAGKeyToolsEnabled;
extern NSString *const kIAGKeyRequestLogging;
extern NSString *const kIAGKeyLogLevel;
extern NSString *const kIAGKeyOpenInSafari;
extern NSString *const kIAGKeyHistoryLimit;
extern NSString *const kIAGKeyBlockedCommands;
extern NSString *const kIAGKeyTopButtonSide;     // tweak bubble hint: left | right

@interface IAGConfig : NSObject

+ (instancetype)shared;

/// Full internal snapshot, including the plaintext API key.
- (NSDictionary *)snapshot;

/// Snapshot suitable for the web UI: the API key is replaced by a mask and a
/// `hasApiKey` boolean is added.
- (NSDictionary *)publicSnapshot;

/// Merge a partial update. Returns the list of keys that actually changed.
/// `apiKey` = "" means "leave unchanged", "__CLEAR__" removes it.
- (NSArray<NSString *> *)applyPatch:(NSDictionary *)patch;

- (void)reload;
- (void)save;

- (NSString *)stringForKey:(NSString *)key fallback:(NSString *)fallback;
- (NSInteger)integerForKey:(NSString *)key fallback:(NSInteger)fallback;
- (double)doubleForKey:(NSString *)key fallback:(double)fallback;
- (BOOL)boolForKey:(NSString *)key fallback:(BOOL)fallback;

- (NSString *)baseURL;
- (NSString *)apiKey;
- (NSString *)model;
- (NSString *)approvalMode;
- (NSInteger)port;
- (NSString *)authToken;
- (NSInteger)maxSteps;
- (NSInteger)shellTimeout;
- (NSString *)workDir;
- (NSInteger)historyLimit;
- (BOOL)toolEnabled:(NSString *)toolName;
- (BOOL)requestLogging;
- (NSString *)systemPrompt;
- (NSArray<NSString *> *)blockedCommandPatterns;

/// Effective system prompt: the user's prompt plus a freshly generated runtime
/// context block (device, iOS version, user, jailbreak root, working dir, date).
- (NSString *)effectiveSystemPrompt;

@end

#endif /* IAG_CONFIG_H */
