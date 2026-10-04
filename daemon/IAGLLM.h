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
//  空值标注：整个头文件包在 NS_ASSUME_NONNULL 区间里，只有真的可以为 nil 的指针
//  才写 _Nullable。为什么必须这样：Clang 的 -Wnullability-completeness（CI 里是
//  -Werror）只要在文件里看到一处空值标注，就会要求同一文件里的**所有**指针都有
//  标注——属性、块参数、以及 out 参数的里外两层（NSError * _Nullable * _Nullable）。
//  漏一个就编译不过；加上这个区间后，默认是非空，只有显式写出的地方才允许为空。
//

#ifndef IAG_LLM_H
#define IAG_LLM_H

#import <Foundation/Foundation.h>

@class IAGConfig;

NS_ASSUME_NONNULL_BEGIN

@interface IAGToolCall : NSObject
@property (nonatomic, copy, nullable) NSString *callId;
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic, copy, nullable) NSString *arguments;     // raw JSON string from the model
@property (nonatomic, assign) NSInteger index;
- (nullable NSDictionary *)parsedArguments;                    // nil when the JSON is broken
- (NSDictionary *)asOpenAIMessageToolCall;                    // for the assistant message
@end

@interface IAGLLMResult : NSObject
@property (nonatomic, copy, nullable)   NSString *content;
@property (nonatomic, copy, nullable)   NSString *reasoning;    // reasoning_content, when provided
@property (nonatomic, copy, nullable)   NSString *finishReason;
@property (nonatomic, strong, nullable) NSArray<IAGToolCall *> *toolCalls;
@property (nonatomic, strong, nullable) NSDictionary *usage;    // prompt_tokens / completion_tokens / total_tokens
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, copy, nullable)   NSString *model;
@property (nonatomic, assign) NSInteger statusCode;             // HTTP status of the final response
@end

typedef void (^IAGLLMDeltaBlock)(NSString * _Nullable kind, NSString * _Nullable text);          // kind: content | reasoning
typedef void (^IAGLLMToolCallBlock)(NSString * _Nullable phase, IAGToolCall * _Nullable call);   // phase: start | delta | end

@interface IAGLLM : NSObject

- (instancetype)initWithConfig:(nullable IAGConfig *)config;

/// Blocking call. `delta` and `toolCall` blocks run on the calling thread.
/// delta/toolCall 传 nil 表示不关心这类事件；messages/tools 传 nil 按空数组处理。
- (nullable IAGLLMResult *)chatWithMessages:(nullable NSArray<NSDictionary *> *)messages
                                      tools:(nullable NSArray<NSDictionary *> *)tools
                               deltaHandler:(nullable IAGLLMDeltaBlock)delta
                           toolCallHandler:(nullable IAGLLMToolCallBlock)toolCall
                                      error:(NSError * _Nullable * _Nullable)error;

/// Ask the server to abort an in-flight request.
- (void)cancel;
- (BOOL)isCancelled;

/// Cheap connectivity probe used by GET /api/health and the settings page.
+ (void)probeConfiguration:(IAGConfig *)config
                completion:(nullable void (^)(BOOL ok, NSString * _Nullable message))completion;

#pragma mark - 模型体检（POST /api/model/check 用）

/// GET <baseUrl>/models，返回模型 id 数组（顺序与远端一致）。
/// baseURL 与 apiKey 显式传入，方便体检时用前端给的临时值而不动共享配置。
/// 失败时返回 nil，并把原因写进 *error / *statusCode（statusCode 为 0 表示连接层失败）。
+ (nullable NSArray<NSString *> *)fetchModelIdentifiersWithBaseURL:(nullable NSString *)baseURL
                                                            apiKey:(nullable NSString *)apiKey
                                                        statusCode:(NSInteger * _Nullable)statusCode
                                                             error:(NSError * _Nullable * _Nullable)error;

/// 极小的真实流式请求（max_tokens 1、messages 一条 "hi"），验证"至少收到一个 SSE delta"。
/// 注意：**不重试、不降级**——体检要如实反映端点的行为。
/// 返回 YES 表示真的收到了流式数据；返回 NO 时 *error 说明原因，*sawSSEEvent 说明
/// 是否"HTTP 200 但一个 SSE 事件都没有"（典型的中转端点忽略 stream:true）。
/// firstDeltaMs 是首个 delta 的耗时（毫秒，收不到时为 0），totalMs 是整次请求耗时。
+ (BOOL)probeStreamingWithBaseURL:(nullable NSString *)baseURL
                           apiKey:(nullable NSString *)apiKey
                            model:(nullable NSString *)model
                     firstDeltaMs:(NSInteger * _Nullable)firstDeltaMs
                          totalMs:(NSInteger * _Nullable)totalMs
                      sawSSEEvent:(BOOL * _Nullable)sawSSEEvent
                       statusCode:(NSInteger * _Nullable)statusCode
                            error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif /* IAG_LLM_H */
