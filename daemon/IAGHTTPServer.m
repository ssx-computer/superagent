//
//  IAGHTTPServer.m
//  iAgent
//

#import "IAGHTTPServer.h"
#import "IAGJSON.h"
#import "IAGLog.h"
#import "IAGVersion.h"

#import <sys/socket.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <poll.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>

static const NSUInteger kIAGMaxHeaderBytes = 64 * 1024;
static const NSUInteger kIAGMaxBodyBytes   = 32 * 1024 * 1024;
static const int kIAGConnectionLimit       = 32;

#pragma mark - low level socket helpers

static BOOL IAGWriteAll(int fd, const void *bytes, size_t length)
{
    const uint8_t *cursor = (const uint8_t *)bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = send(fd, cursor, remaining, 0);
        if (written > 0) {
            cursor += written;
            remaining -= (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
            if (poll(&pfd, 1, 30000) > 0) continue;
            return NO;
        }
        return NO;
    }
    return YES;
}

static BOOL IAGWriteString(int fd, NSString *string)
{
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) return YES;
    return IAGWriteAll(fd, data.bytes, data.length);
}

static const char *IAGStatusText(NSInteger status)
{
    switch (status) {
        case 200: return "OK";
        case 201: return "Created";
        case 202: return "Accepted";
        case 204: return "No Content";
        case 301: return "Moved Permanently";
        case 302: return "Found";
        case 304: return "Not Modified";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 408: return "Request Timeout";
        case 409: return "Conflict";
        case 413: return "Payload Too Large";
        case 429: return "Too Many Requests";
        case 500: return "Internal Server Error";
        case 501: return "Not Implemented";
        case 503: return "Service Unavailable";
        default:  return "OK";
    }
}

#pragma mark - buffered connection reader

@interface IAGConnBuffer : NSObject
@property (nonatomic, assign) int fd;
@property (nonatomic, strong) NSMutableData *buffer;
@end

@implementation IAGConnBuffer

- (instancetype)initWithFD:(int)fd
{
    self = [super init];
    if (self) {
        _fd = fd;
        _buffer = [NSMutableData dataWithCapacity:8192];
    }
    return self;
}

/// Reads whatever is available. Returns NO on EOF, timeout or error.
- (BOOL)fillWithTimeout:(int)timeoutMs
{
    if (timeoutMs <= 0) return NO;
    struct pollfd pfd = { .fd = _fd, .events = POLLIN, .revents = 0 };
    int ready = poll(&pfd, 1, timeoutMs);
    if (ready <= 0) return NO;
    if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
        // Drain anything that might still be buffered in the kernel first.
        if (!(pfd.revents & POLLIN)) return NO;
    }
    uint8_t temp[16384];
    ssize_t n = recv(_fd, temp, sizeof(temp), 0);
    if (n <= 0) return NO;
    [_buffer appendBytes:temp length:(NSUInteger)n];
    return YES;
}

- (nullable NSData *)lineWithTimeout:(int)timeoutMs maxLength:(NSUInteger)maxLength
{
    NSTimeInterval deadline = [NSDate date].timeIntervalSince1970 + (timeoutMs / 1000.0);
    for (;;) {
        const uint8_t *bytes = _buffer.bytes;
        NSUInteger length = _buffer.length;
        for (NSUInteger i = 0; i < length; i++) {
            if (bytes[i] == '\n') {
                NSUInteger lineLength = i;
                if (lineLength > 0 && bytes[lineLength - 1] == '\r') lineLength--;
                NSData *line = [_buffer subdataWithRange:NSMakeRange(0, lineLength)];
                [_buffer replaceBytesInRange:NSMakeRange(0, i + 1) withBytes:NULL length:0];
                return line;
            }
        }
        if (_buffer.length > maxLength) return nil;
        int remaining = (int)((deadline - [NSDate date].timeIntervalSince1970) * 1000.0);
        if (remaining <= 0) return nil;
        if (![self fillWithTimeout:remaining]) return nil;
    }
}

- (nullable NSData *)exactBytes:(NSUInteger)count timeout:(int)timeoutMs
{
    if (count == 0) return [NSData data];
    NSTimeInterval deadline = [NSDate date].timeIntervalSince1970 + (timeoutMs / 1000.0);
    while (_buffer.length < count) {
        int remaining = (int)((deadline - [NSDate date].timeIntervalSince1970) * 1000.0);
        if (remaining <= 0) return nil;
        if (![self fillWithTimeout:remaining]) return nil;
    }
    NSData *out = [_buffer subdataWithRange:NSMakeRange(0, count)];
    [_buffer replaceBytesInRange:NSMakeRange(0, count) withBytes:NULL length:0];
    return out;
}

@end

#pragma mark - request

@implementation IAGHTTPRequest

- (NSString *)header:(NSString *)name
{
    return _headers[[name lowercaseString]];
}

- (NSString *)queryParam:(NSString *)name
{
    return _query[name];
}

- (id)jsonBody
{
    if (_body.length == 0) return nil;
    return IAGJSONDecode(_body, NULL);
}

- (NSString *)textBody
{
    if (_body.length == 0) return @"";
    NSString *string = [[NSString alloc] initWithData:_body encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

- (NSString *)accessToken
{
    NSString *header = [self header:IAG_TOKEN_HEADER];
    if (header.length) return header;
    NSString *query = [self queryParam:@"token"];
    return query.length ? query : nil;
}

@end

#pragma mark - response

@implementation IAGHTTPResponse

+ (instancetype)responseWithStatus:(NSInteger)status
{
    IAGHTTPResponse *response = [[IAGHTTPResponse alloc] init];
    response.status = status;
    response.headers = [NSMutableDictionary dictionary];
    response.body = [NSMutableData data];
    return response;
}

- (void)setHeader:(NSString *)value forKey:(NSString *)key
{
    if (key.length == 0) return;
    if (value.length == 0) {
        [_headers removeObjectForKey:key];
    } else {
        _headers[key] = value;
    }
}

- (void)setData:(NSData *)data contentType:(NSString *)contentType
{
    _body = [NSMutableData dataWithData:data ?: [NSData data]];
    [self setHeader:contentType ?: @"application/octet-stream" forKey:@"Content-Type"];
}

- (void)setJSON:(id)object
{
    NSData *data = IAGJSONEncode(object, NO);
    if (!data) {
        [self setError:@"响应序列化失败" status:500];
        return;
    }
    [self setData:data contentType:@"application/json; charset=utf-8"];
}

- (void)setText:(NSString *)text
{
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    [self setData:data contentType:@"text/plain; charset=utf-8"];
}

- (void)setError:(NSString *)message status:(NSInteger)status
{
    self.status = status;
    [self setJSON:IAGErrorObject(message)];
}

@end

#pragma mark - stream

@implementation IAGHTTPStream {
    int _fd;
    NSLock *_lock;
    BOOL _started;
    BOOL _open;
    NSTimeInterval _startedAt;
}

- (instancetype)initWithFD:(int)fd
{
    self = [super init];
    if (self) {
        _fd = fd;
        _lock = [[NSLock alloc] init];
        _started = NO;
        _open = NO;
        _startedAt = 0;
    }
    return self;
}

- (BOOL)started { return _started; }
- (BOOL)open    { return _open; }
- (NSTimeInterval)startedAt { return _startedAt; }

- (BOOL)beginWithStatus:(NSInteger)status contentType:(NSString *)contentType
{
    [_lock lock];
    if (_started) {
        [_lock unlock];
        return NO;
    }
    _started = YES;
    _open = YES;
    _startedAt = [NSDate date].timeIntervalSince1970;

    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %s\r\n"
        @"Content-Type: %@\r\n"
        @"Cache-Control: no-cache, no-store, must-revalidate\r\n"
        @"Pragma: no-cache\r\n"
        @"X-Accel-Buffering: no\r\n"
        @"Connection: keep-alive\r\n"
        @"Transfer-Encoding: chunked\r\n"
        @"Server: iAgent\r\n"
        @"\r\n",
        (long)status, IAGStatusText(status),
        contentType ?: @"text/event-stream; charset=utf-8"];
    BOOL ok = IAGWriteString(_fd, head);
    if (!ok) _open = NO;
    [_lock unlock];
    return ok;
}

- (BOOL)writeChunkLocked:(NSData *)data
{
    if (!_open) return NO;
    if (data.length == 0) return YES;
    NSString *prefix = [NSString stringWithFormat:@"%lx\r\n", (unsigned long)data.length];
    if (!IAGWriteString(_fd, prefix) ||
        !IAGWriteAll(_fd, data.bytes, data.length) ||
        !IAGWriteString(_fd, @"\r\n")) {
        _open = NO;
        return NO;
    }
    return YES;
}

- (BOOL)sendRaw:(NSData *)data
{
    [_lock lock];
    BOOL ok = [self writeChunkLocked:data];
    [_lock unlock];
    return ok;
}

- (BOOL)sendEvent:(NSString *)event data:(id)object
{
    NSMutableData *payload = [NSMutableData data];
    if (event.length) {
        [payload appendData:[[NSString stringWithFormat:@"event: %@\n", event]
                             dataUsingEncoding:NSUTF8StringEncoding]];
    }
    NSString *json;
    if ([object isKindOfClass:[NSString class]]) {
        json = (NSString *)object;
    } else if (object == nil) {
        json = @"{}";
    } else {
        json = IAGJSONEncodeString(object);
    }
    // SSE forbids raw newlines inside a data field: encode them.
    json = [json stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    json = [json stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    [payload appendData:[[NSString stringWithFormat:@"data: %@\n\n", json]
                         dataUsingEncoding:NSUTF8StringEncoding]];
    return [self sendRaw:payload];
}

- (BOOL)sendComment:(NSString *)comment
{
    NSString *line = [NSString stringWithFormat:@": %@\n\n", comment ?: @""];
    return [self sendRaw:[line dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)end
{
    [_lock lock];
    if (_open) {
        IAGWriteString(_fd, @"0\r\n\r\n");
        _open = NO;
    }
    [_lock unlock];
}

@end

#pragma mark - server

@implementation IAGHTTPServer {
    uint16_t _port;
    int _listenFD;
    IAGHTTPHandler _handler;
    NSThread *_acceptThread;
    dispatch_semaphore_t _connectionSemaphore;
    NSLock *_statsLock;
    NSUInteger _totalRequests;
    NSUInteger _activeConnections;
    BOOL _running;
}

- (instancetype)initWithPort:(uint16_t)port
{
    self = [super init];
    if (self) {
        _port = port;
        _listenFD = -1;
        _connectionSemaphore = dispatch_semaphore_create(kIAGConnectionLimit);
        _statsLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)setHandler:(IAGHTTPHandler)handler
{
    _handler = [handler copy];
}

- (uint16_t)port { return _port; }
- (BOOL)running { return _running; }

- (NSUInteger)activeConnections
{
    [_statsLock lock];
    NSUInteger value = _activeConnections;
    [_statsLock unlock];
    return value;
}

- (NSUInteger)totalRequests
{
    [_statsLock lock];
    NSUInteger value = _totalRequests;
    [_statsLock unlock];
    return value;
}

- (BOOL)start:(NSError **)error
{
    if (_running) return YES;

    // A dead SSE client must never kill the daemon.
    signal(SIGPIPE, SIG_IGN);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                                            userInfo:@{ NSLocalizedDescriptionKey: @"无法创建 socket" }];
        return NO;
    }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(_port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // loopback only, by design

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        int saved = errno;
        close(fd);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved
                                    userInfo:@{ NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"端口 %u 绑定失败: %s", _port, strerror(saved)] }];
        }
        return NO;
    }

    if (listen(fd, 16) != 0) {
        int saved = errno;
        close(fd);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved
                                    userInfo:@{ NSLocalizedDescriptionKey: @"listen 失败" }];
        }
        return NO;
    }

    // Discover the real port when 0 was requested.
    if (_port == 0) {
        struct sockaddr_in bound;
        socklen_t len = sizeof(bound);
        if (getsockname(fd, (struct sockaddr *)&bound, &len) == 0) {
            _port = ntohs(bound.sin_port);
        }
    }

    _listenFD = fd;
    _running = YES;

    _acceptThread = [[NSThread alloc] initWithTarget:self selector:@selector(acceptLoop) object:nil];
    _acceptThread.name = @"iagent.http.accept";
    _acceptThread.qualityOfService = NSQualityOfServiceUserInitiated;
    [_acceptThread start];

    IAGLogInfo(@"HTTP 服务已启动: http://127.0.0.1:%u", _port);
    return YES;
}

- (void)stop
{
    if (!_running) return;
    _running = NO;
    if (_listenFD >= 0) {
        shutdown(_listenFD, SHUT_RDWR);
        close(_listenFD);
        _listenFD = -1;
    }
    IAGLogInfo(@"HTTP 服务已停止");
}

- (void)acceptLoop
{
    while (_running) {
        struct pollfd pfd = { .fd = _listenFD, .events = POLLIN, .revents = 0 };
        int ready = poll(&pfd, 1, 500);
        if (!_running) break;
        if (ready <= 0) continue;

        struct sockaddr_in peer;
        socklen_t peerLen = sizeof(peer);
        int clientFD = accept(_listenFD, (struct sockaddr *)&peer, &peerLen);
        if (clientFD < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            if (!_running) break;
            continue;
        }

        if (dispatch_semaphore_wait(_connectionSemaphore, DISPATCH_TIME_NOW) != 0) {
            // Too many concurrent connections: shed this one politely.
            IAGWriteString(clientFD, @"HTTP/1.1 503 Service Unavailable\r\n"
                                     @"Content-Length: 0\r\nConnection: close\r\n\r\n");
            close(clientFD);
            continue;
        }

        [_statsLock lock];
        _activeConnections++;
        [_statsLock unlock];

        NSString *remote = [NSString stringWithFormat:@"%s:%u",
                            inet_ntoa(peer.sin_addr), ntohs(peer.sin_port)];
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            [self serveConnection:clientFD remote:remote];
            [self->_statsLock lock];
            self->_activeConnections--;
            [self->_statsLock unlock];
            dispatch_semaphore_signal(self->_connectionSemaphore);
        }];
        thread.name = @"iagent.http.conn";
        [thread start];
    }
}

#pragma mark - request parsing

- (IAGHTTPRequest *)readRequest:(IAGConnBuffer *)conn keepAlive:(BOOL *)keepAliveOut
{
    NSData *requestLineData = [conn lineWithTimeout:15000 maxLength:kIAGMaxHeaderBytes];
    if (!requestLineData) return nil;
    NSString *requestLine = [[NSString alloc] initWithData:requestLineData encoding:NSUTF8StringEncoding];
    if (requestLine.length == 0) return nil;   // peer closed

    NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
    if (parts.count < 3) return nil;

    IAGHTTPRequest *request = [[IAGHTTPRequest alloc] init];
    request.method = parts[0];
    request.rawPath = parts[1];
    request.httpVersion = parts[2];

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSUInteger headerBytes = requestLineData.length;
    for (;;) {
        NSData *lineData = [conn lineWithTimeout:15000 maxLength:kIAGMaxHeaderBytes];
        if (!lineData) return nil;
        headerBytes += lineData.length;
        if (headerBytes > kIAGMaxHeaderBytes) return nil;
        if (lineData.length == 0) break;

        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[line substringToIndex:colon.location]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [[line substringFromIndex:colon.location + 1]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        name = [name lowercaseString];
        NSString *existing = headers[name];
        headers[name] = existing.length ? [NSString stringWithFormat:@"%@, %@", existing, value] : value;
    }
    request.headers = headers;

    // Split path / query.
    NSString *rawPath = request.rawPath;
    NSRange questionMark = [rawPath rangeOfString:@"?"];
    if (questionMark.location != NSNotFound) {
        request.queryString = [rawPath substringFromIndex:questionMark.location + 1];
        rawPath = [rawPath substringToIndex:questionMark.location];
    }
    NSString *decodedPath = [rawPath stringByRemovingPercentEncoding] ?: rawPath;
    request.path = decodedPath.length ? decodedPath : @"/";

    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    for (NSString *pair in [request.queryString componentsSeparatedByString:@"&"]) {
        if (pair.length == 0) continue;
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location];
        NSString *value = equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1];
        key = [key stringByReplacingOccurrencesOfString:@"+" withString:@" "];
        value = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
        key = [key stringByRemovingPercentEncoding] ?: key;
        value = [value stringByRemovingPercentEncoding] ?: value;
        if (key.length) query[key] = value;
    }
    request.query = query;

    // Body.
    NSString *transferEncoding = [headers[@"transfer-encoding"] lowercaseString] ?: @"";
    NSString *contentLength = headers[@"content-length"];
    NSString *expect = [headers[@"expect"] lowercaseString] ?: @"";

    if ([expect containsString:@"100-continue"]) {
        IAGWriteString(conn.fd, @"HTTP/1.1 100 Continue\r\n\r\n");
    }

    if ([transferEncoding containsString:@"chunked"]) {
        NSMutableData *body = [NSMutableData data];
        for (;;) {
            NSData *sizeLineData = [conn lineWithTimeout:15000 maxLength:1024];
            if (!sizeLineData) return nil;
            NSString *sizeLine = [[NSString alloc] initWithData:sizeLineData encoding:NSUTF8StringEncoding];
            NSRange semicolon = [sizeLine rangeOfString:@";"];
            if (semicolon.location != NSNotFound) sizeLine = [sizeLine substringToIndex:semicolon.location];
            unsigned long long chunkSize = strtoull(sizeLine.UTF8String, NULL, 16);
            if (chunkSize == 0) {
                // Consume trailer headers.
                while (1) {
                    NSData *trailer = [conn lineWithTimeout:5000 maxLength:1024];
                    if (!trailer || trailer.length == 0) break;
                }
                break;
            }
            if (body.length + chunkSize > kIAGMaxBodyBytes) return nil;
            NSData *chunk = [conn exactBytes:(NSUInteger)chunkSize timeout:20000];
            if (!chunk) return nil;
            [body appendData:chunk];
            [conn lineWithTimeout:5000 maxLength:16];   // trailing CRLF
        }
        request.body = body;
    } else if (contentLength.length) {
        unsigned long long length = strtoull(contentLength.UTF8String, NULL, 10);
        if (length > kIAGMaxBodyBytes) return nil;
        NSData *body = [conn exactBytes:(NSUInteger)length timeout:30000];
        if (!body) return nil;
        request.body = body;
    } else {
        request.body = [NSData data];
    }

    BOOL keepAlive = YES;
    NSString *connection = [headers[@"connection"] lowercaseString] ?: @"";
    if ([connection containsString:@"close"]) keepAlive = NO;
    if ([request.httpVersion isEqualToString:@"HTTP/1.0"] && ![connection containsString:@"keep-alive"]) {
        keepAlive = NO;
    }
    if (keepAliveOut) *keepAliveOut = keepAlive;

    return request;
}

#pragma mark - connection handling

- (void)serveConnection:(int)fd remote:(NSString *)remote
{
    int one = 1;
    // 双保险：进程级已经忽略了 SIGPIPE，但这里再给每个客户端 socket 单独关掉它。
    // 浏览器关掉一个 SSE 流之后我们还会继续写（心跳/收尾），没有这一条，某些
    // 路径下 write 会直接以 SIGPIPE 杀掉整个守护进程 —— 那就是用户看到的
    // "连接被提前关闭（daemon 可能被杀/崩溃）"。
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) != 0) {
        // 参数不支持不算致命（进程级 SIG_IGN 仍然兜着），但值得留一行日志。
        IAGLogWarn(@"SO_NOSIGPIPE 设置失败: %s", strerror(errno));
    }
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct timeval sendTimeout = { .tv_sec = 30, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, sizeof(sendTimeout));

    IAGConnBuffer *conn = [[IAGConnBuffer alloc] initWithFD:fd];

    while (_running) {
        @autoreleasepool {
            BOOL keepAlive = NO;
            IAGHTTPRequest *request = nil;
            @try {
                request = [self readRequest:conn keepAlive:&keepAlive];
            } @catch (NSException *exception) {
                IAGLogError(@"解析请求异常: %@", exception.reason);
                request = nil;
            }
            if (!request) break;
            request.remoteAddress = remote;

            [_statsLock lock];
            _totalRequests++;
            [_statsLock unlock];

            IAGHTTPResponse *response = [IAGHTTPResponse responseWithStatus:200];
            IAGHTTPStream *stream = [[IAGHTTPStream alloc] initWithFD:fd];

            @try {
                if (_handler) {
                    _handler(request, response, stream);
                } else {
                    [response setError:@"服务未就绪" status:503];
                }
            } @catch (NSException *exception) {
                IAGLogError(@"处理 %@ %@ 异常: %@", request.method, request.path, exception.reason);
                if (!stream.started) [response setError:@"内部错误" status:500];
            }

            if (stream.started) {
                [stream end];
                break;   // the streaming response owns the connection
            }

            BOOL headOnly = [request.method isEqualToString:@"HEAD"];
            [response setHeader:@"iAgent" forKey:@"Server"];
            if (!response.headers[@"Content-Type"]) {
                [response setHeader:@"application/json; charset=utf-8" forKey:@"Content-Type"];
            }
            [response setHeader:[@(response.body.length) stringValue] forKey:@"Content-Length"];
            [response setHeader:(keepAlive ? @"keep-alive" : @"close") forKey:@"Connection"];

            NSMutableString *head = [NSMutableString stringWithFormat:
                @"HTTP/1.1 %ld %s\r\n", (long)response.status, IAGStatusText(response.status)];
            for (NSString *key in response.headers) {
                [head appendFormat:@"%@: %@\r\n", key, response.headers[key]];
            }
            [head appendString:@"\r\n"];

            if (!IAGWriteString(fd, head)) break;
            if (!headOnly && response.body.length) {
                if (!IAGWriteAll(fd, response.body.bytes, response.body.length)) break;
            }
            if (!keepAlive) break;
        }
    }

    shutdown(fd, SHUT_RDWR);
    close(fd);
}

@end
