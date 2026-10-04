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
@property (nonatomic, assign) NSInteger statusCode;   // HTTP status of the final response
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

#pragma mark - 模型体检（POST /api/model/check 用）

/// GET <baseUrl>/models，返回模型 id 数组（顺序与远端一致）。
/// baseURL 与 apiKey 显式传入，方便体检时用前端给的临时值而不动共享配置。
/// 失败时返回 nil，并把原因写进 *error / *statusCode（statusCode 为 0 表示连接层失败）。
+ (nullable NSArray<NSString *> *)fetchModelIdentifiersWithBaseURL:(NSString *)baseURL
                                                            apiKey:(NSString *)apiKey
                                                          statusCode:(NSInteger *)statusCode
                                                               error:(NSError **)error;

/// 极小的真实流式请求（max_tokens 1、messages 一条 "hi"），验证"至少收到一个 SSE delta"。
/// 注意：**不重试、不降级**——体检要如实反映端点的行为。
/// 返回 YES 表示真的收到了流式数据；返回 NO 时 *error 说明原因，*sawSSEEvent 说明
/// 是否"HTTP 200 但一个 SSE 事件都没有"（典型的中转端点忽略 stream:true）。
/// firstDeltaMs 是首个 delta 的耗时（毫秒，收不到时为 0），totalMs 是整次请求耗时。
+ (BOOL)probeStreamingWithBaseURL:(NSString *)baseURL
                           apiKey:(NSString *)apiKey
                            model:(NSString *)model
                     firstDeltaMs:(NSInteger *)firstDeltaMs
                          totalMs:(NSInteger *)totalMs
                      sawSSEEvent:(BOOL *)sawSSEEvent
                        statusCode:(NSInteger *)statusCode
                             error:(NSError **)error;

@end

#endif /* IAG_LLM_H */
