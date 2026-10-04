//
//  IAGTool.h
//  iAgent
//
//  Tool protocol + registry. A tool is a stateless class; everything it needs at
//  call time arrives in an IAGToolContext.
//

#ifndef IAG_TOOL_H
#define IAG_TOOL_H

#import <Foundation/Foundation.h>

@class IAGConfig;
@class IAGBridge;
@class IAGTerminalManager;

/// Everything a tool may need. Created per run and passed down.
@interface IAGToolContext : NSObject
@property (nonatomic, strong) IAGConfig *config;
@property (nonatomic, copy)   NSString *sessionId;
@property (nonatomic, strong) IAGBridge *bridge;
+ (instancetype)contextWithConfig:(IAGConfig *)config
                        sessionId:(NSString *)sessionId
                           bridge:(IAGBridge *)bridge;
@end

@protocol IAGTool <NSObject>
@required
/// Snake_case tool name exposed to the model.
+ (NSString *)toolName;
/// One or two sentences for the model, in Chinese (the model answers in Chinese).
+ (NSString *)toolDescription;
/// JSON Schema object describing the parameters.
+ (NSDictionary *)parametersSchema;
/// "shell" | "file" | "app" | "notify" | "cron" | "ui" | "http" — matches the
/// toolsEnabled config keys.
+ (NSString *)category;
/// YES when a single call can destroy data, kill processes or drive the UI.
+ (BOOL)isDangerous;
/// Execute. Returns { ok: BOOL, output: String } or { ok: NO, error: String }.
+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                               context:(IAGToolContext *)context;
@end

@interface IAGToolRegistry : NSObject

+ (instancetype)shared;

/// Registers every built-in tool (idempotent).
- (void)registerDefaults;

/// Used by the per-category registration functions below.
- (void)registerToolClass:(Class)toolClass;

/// OpenAI `tools` array, filtered by the current configuration.
- (NSArray<NSDictionary *> *)openAIToolDefinitionsWithConfig:(IAGConfig *)config;

/// Metadata for GET /api/tools: every registered tool plus an `enabled` flag,
/// because the UI must be able to show (and switch on) disabled ones. Only
/// -openAIToolDefinitionsWithConfig: filters by the configuration.
- (NSArray<NSDictionary *> *)toolListWithConfig:(IAGConfig *)config;

/// Run a tool by name. Always returns a dictionary with `ok`; failures carry
/// `error`. Adds `durationMs`, `name` and `dangerous`.
- (NSDictionary *)executeTool:(NSString *)name
                    arguments:(NSDictionary *)arguments
                      context:(IAGToolContext *)context;

/// Lookup helpers used by the approval policy.
- (BOOL)toolExists:(NSString *)name;
- (BOOL)isDangerousTool:(NSString *)name;
- (NSString *)categoryForTool:(NSString *)name;
- (NSString *)descriptionForTool:(NSString *)name;

/// Heuristic used for the "dangerous" approval mode: does this shell command
/// look destructive?
+ (BOOL)commandLooksDangerous:(NSString *)command;

/// Extra reason text when a call needs confirmation, else nil.
- (NSString *)approvalReasonForTool:(NSString *)name
                          arguments:(NSDictionary *)arguments
                             config:(IAGConfig *)config;

/// Non-nil when the call is unconditionally forbidden (config blocklist).
- (NSString *)blockedReasonForTool:(NSString *)name
                         arguments:(NSDictionary *)arguments
                            config:(IAGConfig *)config;

@end

/// Convenience for tool implementations.
extern NSDictionary *IAGToolSuccess(NSString *output);
extern NSDictionary *IAGToolFailure(NSString *error);

#endif /* IAG_TOOL_H */
