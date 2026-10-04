//
//  IAGHTTPServer.h
//  iAgent
//
//  A dependency-free HTTP/1.1 server bound to loopback, with just enough
//  features for the agent's local control plane:
//
//    * keep-alive, Content-Length and chunked request bodies
//    * Expect: 100-continue (curl sends it)
//    * chunked Server-Sent Events for streaming model output
//    * a thread per connection, capped by a semaphore
//
//  It is deliberately small: this socket only ever serves 127.0.0.1.
//

#ifndef IAG_HTTP_SERVER_H
#define IAG_HTTP_SERVER_H

#import <Foundation/Foundation.h>

@class IAGHTTPStream;

#pragma mark - Request

@interface IAGHTTPRequest : NSObject
@property (nonatomic, copy)   NSString *method;
@property (nonatomic, copy)   NSString *path;         // percent-decoded, no query
@property (nonatomic, copy)   NSString *rawPath;
@property (nonatomic, copy)   NSString *queryString;
@property (nonatomic, copy)   NSString *httpVersion;
@property (nonatomic, copy)   NSDictionary<NSString *, NSString *> *headers;  // keys lowercased
@property (nonatomic, copy)   NSDictionary<NSString *, NSString *> *query;
@property (nonatomic, strong) NSData *body;
@property (nonatomic, copy)   NSString *remoteAddress;

- (NSString *)header:(NSString *)name;
- (NSString *)queryParam:(NSString *)name;

/// Body decoded as JSON (nil when the body is not valid JSON).
- (id)jsonBody;
/// Body decoded as UTF-8.
- (NSString *)textBody;
/// Cookie-free access token: X-IAG-Token header or ?token= query parameter.
- (NSString *)accessToken;

@end

#pragma mark - Buffered response

@interface IAGHTTPResponse : NSObject
@property (nonatomic, assign) NSInteger status;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong) NSMutableData *body;

+ (instancetype)responseWithStatus:(NSInteger)status;
- (void)setHeader:(NSString *)value forKey:(NSString *)key;
- (void)setJSON:(id)object;
- (void)setText:(NSString *)text;
- (void)setData:(NSData *)data contentType:(NSString *)contentType;
- (void)setError:(NSString *)message status:(NSInteger)status;
@end

#pragma mark - Streaming (SSE) response

@interface IAGHTTPStream : NSObject

/// Take over the connection. Must be called before the server writes anything.
- (BOOL)beginWithStatus:(NSInteger)status contentType:(NSString *)contentType;
/// "event: <name>\ndata: <json>\n\n"
- (BOOL)sendEvent:(NSString *)event data:(id)object;
/// ": <comment>\n\n" — used as a keep-alive heartbeat.
- (BOOL)sendComment:(NSString *)comment;
- (BOOL)sendRaw:(NSData *)data;
- (void)end;

@property (nonatomic, readonly) BOOL started;
@property (nonatomic, readonly) BOOL open;      // NO once the peer went away
@property (nonatomic, readonly) NSTimeInterval startedAt;

@end

#pragma mark - Server

typedef void (^IAGHTTPHandler)(IAGHTTPRequest *request, IAGHTTPResponse *response, IAGHTTPStream *stream);

@interface IAGHTTPServer : NSObject

- (instancetype)initWithPort:(uint16_t)port;
- (void)setHandler:(IAGHTTPHandler)handler;

- (BOOL)start:(NSError **)error;
- (void)stop;

@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) NSUInteger activeConnections;
@property (nonatomic, readonly) NSUInteger totalRequests;

@end

#endif /* IAG_HTTP_SERVER_H */
