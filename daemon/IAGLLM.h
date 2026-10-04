//
//  IAGLLM.h
//  iAgent
//
//  Minimal OpenAI-compatible chat client: /chat/completions with streaming SSE
//  and tool calling. Deliberately provider-agnostic — anything that speaks the
//  OpenAI wire format (OpenAI, DeepSeek, Moonshot, Zhipu, OpenRouter, Ollama,
//  vLLM, LM Studio, ...) works by setting baseUrl.
//
//  The client is synchronous and reports progress through blocks, because the
//  agent loop already runs on the HTTP connection's own thread and the SSE
//  writer must observe events in order.
//

#ifndef IAG_LLM_H
#define IAG_LLM_H

#import <Foundation/Foundation.h>

@class IAGConfig;

@interface IAGToolCall : NSObject
@property (nonatomic, copy) NSString *callId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *arguments;     // raw JSON string from the model
@property (nonatomic, assign) NSInteger index;
- (NSDictionary *)parsedArguments;                    // nil when the JSON is broken
- (NSDictionary *)asOpenAIMessageToolCall;            // for the assistant message
@end

@interface IAGLLMResult : NSObject
@property (nonatomic, copy)   NSString *content;
@property (nonatomic, copy)   NSString *reasoning;    // reasoning_content, when provided
@property (nonatomic, copy)   NSString *finishReason;
@property (nonatomic, strong) NSArray<IAGToolCall *> *toolCalls;
@property (nonatomic, strong) NSDictionary *usage;    // prompt_tokens / completion_tokens / total_tokens
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, copy)   NSString *model;
@end

typedef void (^IAGLLMDeltaBlock)(NSString *kind, NSString *text);          // kind: content | reasoning
typedef void (^IAGLLMToolCallBlock)(NSString *phase, IAGToolCall *call);   // phase: start | delta | end

@interface IAGLLM : NSObject

- (instancetype)initWithConfig:(IAGConfig *)config;

/// Blocking call. `delta` and `toolCall` blocks run on the calling thread.
- (IAGLLMResult *)chatWithMessages:(NSArray<NSDictionary *> *)messages
                             tools:(NSArray<NSDictionary *> *)tools
                      deltaHandler:(IAGLLMDeltaBlock)delta
                  toolCallHandler:(IAGLLMToolCallBlock)toolCall
                             error:(NSError **)error;

/// Ask the server to abort an in-flight request.
- (void)cancel;
- (BOOL)isCancelled;

/// Cheap connectivity probe used by GET /api/health and the settings page.
+ (void)probeConfiguration:(IAGConfig *)config completion:(void (^)(BOOL ok, NSString *message))completion;

@end

#endif /* IAG_LLM_H */
