//
//  IAGTweak.m
//  iAgent — SpringBoard entry point.
//
//  A plain constructor dylib (no Logos, no substrate, no hooking):
//
//    * a draggable floating bubble above everything else,
//    * a WKWebView panel that loads the daemon's control panel, with an
//      automatic fallback to Safari when the in-process web view cannot render,
//    * the bridge client that long-polls the daemon and executes UI automation /
//      notifications inside SpringBoard, where HID and AX access live.
//
//  Everything is best-effort: if SpringBoard changes shape in a future iOS
//  release the bubble simply does not appear, and nothing else breaks.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "IAGAutomation.h"
#import "IAGConfig.h"
#import "IAGPaths.h"
#import "IAGVersion.h"
#import "IAGLog.h"
#import "IAGJSON.h"

static const CGFloat kIAGBubbleSize = 54.0;
// Above the keyboard window (~1e7) so the bubble stays reachable everywhere.
static const UIWindowLevel kIAGBubbleWindowLevel = 10000001.0;
static const UIWindowLevel kIAGPanelWindowLevel = 10000002.0;

#pragma mark - helpers

static UIWindowScene *IAGActiveWindowScene(void)
{
    UIApplication *application = [UIApplication sharedApplication];
    if (!application) return nil;

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
    }
    for (UIScene *scene in application.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
    }
    return nil;
}

/// Synchronous JSON request. Used only from the bridge thread.
static NSDictionary *IAGHTTPJSON(NSString *method, NSString *urlString, NSDictionary *body,
                                 NSString *token, NSTimeInterval timeout)
{
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    request.timeoutInterval = timeout;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    if (token.length) [request setValue:token forHTTPHeaderField:IAG_TOKEN_HEADER];
    if (body) {
        NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
        if (payload) {
            request.HTTPBody = payload;
            [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        }
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData *responseData = nil;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            responseData = data;
            dispatch_semaphore_signal(semaphore);
        }];
    [task resume];

    long waitSeconds = (long)(timeout + 10);
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, waitSeconds * NSEC_PER_SEC)) != 0) {
        [task cancel];
        return nil;
    }
    if (!responseData.length) return nil;

    id json = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:NULL];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

#pragma mark - touch pass-through window

@interface IAGFloatingWindow : UIWindow
/// Only this view (and its subviews) accepts touches; everywhere else the window
/// is invisible to the touch system, so the UI underneath keeps working.
@property (nonatomic, weak) UIView *interactiveView;
@end

@implementation IAGFloatingWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit) return nil;
    if (hit == self) return nil;

    UIView *interactive = self.interactiveView;
    if (interactive && ![hit isDescendantOfView:interactive]) return nil;
    return hit;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *interactive = self.interactiveView;
    if (interactive) {
        return CGRectContainsPoint(interactive.frame, point) ? [super pointInside:point withEvent:event] : NO;
    }
    return [super pointInside:point withEvent:event];
}

@end

#pragma mark - the tweak

@interface IAGTweak : NSObject <WKNavigationDelegate>
+ (instancetype)shared;
- (void)start;
@end

@implementation IAGTweak {
    BOOL _started;
    BOOL _bubbleVisible;

    IAGFloatingWindow *_bubbleWindow;
    UIView *_bubbleView;
    UILabel *_bubbleLabel;
    BOOL _dragged;

    IAGFloatingWindow *_panelWindow;
    WKWebView *_webView;
    UILabel *_panelStatus;
    NSTimer *_panelTimeout;

    NSThread *_bridgeThread;
    BOOL _bridgeRunning;
    NSUInteger _bridgeCursor;
    BOOL _bridgeConnected;
    BOOL _forceSafari;
}

+ (instancetype)shared
{
    static IAGTweak *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IAGTweak alloc] init]; });
    return shared;
}

#pragma mark lifecycle

- (void)start
{
    if (_started) return;
    _started = YES;

    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (bundleIdentifier.length && ![bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        IAGLogInfo(@"iAgent: 跳过非 SpringBoard 进程 %@", bundleIdentifier);
        return;
    }

    IAGLogInfo(@"iAgent tweak %@ 已载入 SpringBoard", IAG_VERSION_STRING);
    [[IAGHID shared] prepare];
    [[IAGAX shared] prepare];

    [self showBubble];
    [self startBridge];
}

- (void)showBubble
{
    if (_bubbleVisible) return;
    _bubbleVisible = YES;

    UIWindowScene *scene = IAGActiveWindowScene();
    if (scene) _bubbleWindow = [[IAGFloatingWindow alloc] initWithWindowScene:scene];
    else _bubbleWindow = [[IAGFloatingWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    _bubbleWindow.windowLevel = kIAGBubbleWindowLevel;
    _bubbleWindow.backgroundColor = [UIColor clearColor];
    // Deliberately NOT makeKeyAndVisible: that would steal focus from the app.
    _bubbleWindow.hidden = NO;

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    root.view.frame = _bubbleWindow.bounds;
    _bubbleWindow.rootViewController = root;

    _bubbleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kIAGBubbleSize, kIAGBubbleSize)];
    _bubbleView.backgroundColor = [UIColor colorWithRed:0.06 green:0.36 blue:0.78 alpha:0.92];
    _bubbleView.layer.cornerRadius = kIAGBubbleSize / 2.0;
    _bubbleView.layer.shadowColor = [UIColor blackColor].CGColor;
    _bubbleView.layer.shadowOpacity = 0.35;
    _bubbleView.layer.shadowRadius = 6;
    _bubbleView.layer.shadowOffset = CGSizeMake(0, 2);
    _bubbleView.layer.borderWidth = 1.0;
    _bubbleView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    _bubbleView.userInteractionEnabled = YES;

    _bubbleLabel = [[UILabel alloc] initWithFrame:_bubbleView.bounds];
    _bubbleLabel.text = @"AI";
    _bubbleLabel.textColor = [UIColor whiteColor];
    _bubbleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _bubbleLabel.textAlignment = NSTextAlignmentCenter;
    [_bubbleView addSubview:_bubbleLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bubbleTapped)];
    [_bubbleView addGestureRecognizer:tap];

    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
                                           initWithTarget:self action:@selector(bubbleLongPressed:)];
    press.minimumPressDuration = 0.6;
    [_bubbleView addGestureRecognizer:press];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(bubblePanned:)];
    [_bubbleView addGestureRecognizer:pan];

    [root.view addSubview:_bubbleView];
    _bubbleWindow.interactiveView = _bubbleView;
    [self layoutBubbleAnimated:NO];
}

- (void)layoutBubbleAnimated:(BOOL)animated
{
    if (!_bubbleView || !_bubbleWindow) return;

    CGRect bounds = _bubbleWindow.bounds;
    if (CGRectIsEmpty(bounds)) bounds = [UIScreen mainScreen].bounds;

    CGFloat safeTop = 60, safeBottom = 40;
    if (@available(iOS 11.0, *)) {
        UIEdgeInsets insets = _bubbleWindow.safeAreaInsets;
        safeTop = MAX(insets.top, 44) + 8;
        safeBottom = MAX(insets.bottom, 20) + 12;
    }

    BOOL leftSide = ![[[[IAGConfig shared] stringForKey:kIAGKeyTopButtonSide fallback:@"right"]
                        lowercaseString] isEqualToString:@"right"];

    CGFloat x = leftSide ? 10 : CGRectGetWidth(bounds) - kIAGBubbleSize - 10;
    CGFloat storedY = [[IAGConfig shared] doubleForKey:@"bubbleY" fallback:0];
    CGFloat y = storedY > 0 ? storedY : CGRectGetHeight(bounds) * 0.42;
    y = MAX(safeTop, MIN(CGRectGetHeight(bounds) - safeBottom - kIAGBubbleSize, y));

    void (^changes)(void) = ^{
        self->_bubbleView.frame = CGRectMake(x, y, kIAGBubbleSize, kIAGBubbleSize);
    };
    if (animated) [UIView animateWithDuration:0.22 animations:changes];
    else changes();
}

- (void)hideBubble
{
    // Session-scoped: a respring brings it back, so the user can never lock
    // themselves out of the UI by accident.
    _bubbleVisible = NO;
    [_bubbleWindow removeFromSuperview];
    _bubbleWindow.hidden = YES;
    _bubbleWindow = nil;
    _bubbleView = nil;
    IAGLogInfo(@"iAgent: 悬浮球已在本次会话内隐藏");
}

#pragma mark bubble gestures

- (void)bubblePanned:(UIPanGestureRecognizer *)pan
{
    if (!_bubbleView || !_bubbleWindow) return;

    CGPoint translation = [pan translationInView:_bubbleWindow];
    CGPoint center = CGPointMake(_bubbleView.center.x + translation.x,
                                _bubbleView.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:_bubbleWindow];

    CGRect bounds = _bubbleWindow.bounds;
    CGFloat half = kIAGBubbleSize / 2.0;
    center.x = MAX(half + 4, MIN(CGRectGetWidth(bounds) - half - 4, center.x));
    center.y = MAX(half + 40, MIN(CGRectGetHeight(bounds) - half - 40, center.y));
    _bubbleView.center = center;

    if (pan.state == UIGestureRecognizerStateBegan) _dragged = YES;

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        BOOL leftSide = center.x < CGRectGetWidth(bounds) / 2.0;
        [[IAGConfig shared] applyPatch:@{
            kIAGKeyTopButtonSide: leftSide ? @"left" : @"right",
            @"bubbleY": @(center.y),
        }];
        [self layoutBubbleAnimated:YES];

        // The tap recognizer fires right after a small drag; ignore it.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ self->_dragged = NO; });
    }
}

- (void)bubbleTapped
{
    if (_dragged) return;
    [self openPanel];
}

- (void)bubbleLongPressed:(UILongPressGestureRecognizer *)press
{
    if (press.state != UIGestureRecognizerStateBegan) return;
    if (_dragged) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"iAgent"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"打开控制面板" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) { [self openPanelInProcess]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"在浏览器中打开" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) { [self openInSafari]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"隐藏悬浮球（重启发后恢复）" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) { [self hideBubble]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // Present from whatever SpringBoard currently has on screen: the bubble
    // window is deliberately not the key window.
    UIViewController *presenter = [UIApplication sharedApplication].keyWindow.rootViewController;
    if (!presenter) presenter = _bubbleWindow.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) return;

    // iPad / action sheets need an anchor.
    sheet.popoverPresentationController.sourceView = _bubbleView;
    sheet.popoverPresentationController.sourceRect = _bubbleView.bounds;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

#pragma mark control panel

- (NSString *)panelURLString
{
    NSInteger port = [[IAGConfig shared] port];
    NSString *token = [[IAGConfig shared] authToken];
    NSMutableString *url = [NSMutableString stringWithFormat:@"http://%s:%ld/", IAG_DEFAULT_HOST.UTF8String, (long)port];
    if (token.length) {
        [url appendFormat:@"?token=%@", [token stringByAddingPercentEncodingWithAllowedCharacters:
                                        [NSCharacterSet URLQueryAllowedCharacterSet]]];
    }
    return url;
}

- (void)openPanel
{
    if ([[IAGConfig shared] boolForKey:kIAGKeyOpenInSafari fallback:NO] || _forceSafari) {
        [self openInSafari];
        return;
    }

    // Is the daemon up? If not, Safari would show the same error but with a
    // worse explanation, so say it here instead.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 探活必须打 /api/health：只有它是 JSON（IAGHTTPJSON 要求能解析成字典），
        // 而且它免鉴权。以前这里探的是面板地址，返回的是 index.html，
        // 解析必然失败，于是单击悬浮球永远被误判成"守护进程未运行"。
        NSString *healthURL = [NSString stringWithFormat:@"http://%s:%ld/api/health",
                               IAG_DEFAULT_HOST.UTF8String, (long)[[IAGConfig shared] port]];
        NSDictionary *health = IAGHTTPJSON(@"GET", healthURL, nil, [[IAGConfig shared] authToken], 3);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (health) [self openPanelInProcess];
            else {
                [self notifyWithTitle:@"iAgent" message:@"守护进程 iagentd 未在运行，无法打开控制面板。" duration:5];
            }
        });
    });
}

- (void)openInSafari
{
    NSURL *url = [NSURL URLWithString:[self panelURLString]];
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)openPanelInProcess
{
    if (_panelWindow) {
        _panelWindow.hidden = NO;
        return;
    }

    UIWindowScene *scene = IAGActiveWindowScene();
    if (scene) _panelWindow = [[IAGFloatingWindow alloc] initWithWindowScene:scene];
    else _panelWindow = [[IAGFloatingWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    _panelWindow.windowLevel = kIAGPanelWindowLevel;
    _panelWindow.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.98];
    _panelWindow.hidden = NO;

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.98];
    root.view.frame = _panelWindow.bounds;
    _panelWindow.rootViewController = root;

    CGRect bounds = _panelWindow.bounds;
    if (CGRectIsEmpty(bounds)) bounds = [UIScreen mainScreen].bounds;

    CGFloat headerHeight = 46;
    if (@available(iOS 11.0, *)) headerHeight += MAX(_panelWindow.safeAreaInsets.top, 20);

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(bounds), headerHeight)];
    header.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, headerHeight - 36, CGRectGetWidth(bounds) - 200, 24)];
    title.text = @"iAgent 控制面板";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [header addSubview:title];

    UIButton *reload = [UIButton buttonWithType:UIButtonTypeSystem];
    reload.frame = CGRectMake(CGRectGetWidth(bounds) - 168, headerHeight - 38, 44, 28);
    [reload setTitle:@"刷新" forState:UIControlStateNormal];
    [reload addTarget:self action:@selector(reloadPanel) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:reload];

    UIButton *safari = [UIButton buttonWithType:UIButtonTypeSystem];
    safari.frame = CGRectMake(CGRectGetWidth(bounds) - 116, headerHeight - 38, 52, 28);
    [safari setTitle:@"浏览器" forState:UIControlStateNormal];
    [safari addTarget:self action:@selector(openInSafari) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:safari];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(CGRectGetWidth(bounds) - 58, headerHeight - 38, 44, 28);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:close];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    [root.view addSubview:header];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.allowsInlineMediaPlayback = YES;
    WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectMake(0, headerHeight,
                                                                    CGRectGetWidth(bounds),
                                                                    CGRectGetHeight(bounds) - headerHeight)
                                            configuration:configuration];
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    webView.navigationDelegate = self;
    webView.opaque = NO;
    webView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
    [root.view addSubview:webView];
    _webView = webView;

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(20, CGRectGetMidY(bounds) - 20,
                                                                CGRectGetWidth(bounds) - 40, 40)];
    status.text = @"正在加载控制面板…";
    status.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    status.textAlignment = NSTextAlignmentCenter;
    status.font = [UIFont systemFontOfSize:13];
    [root.view addSubview:status];
    _panelStatus = status;

    _panelWindow.interactiveView = root.view;

    NSURL *url = [NSURL URLWithString:[self panelURLString]];
    if (url) [webView loadRequest:[NSURLRequest requestWithURL:url]];

    // SpringBoard-embedded WKWebView has known blank-rendering problems on
    // iOS 15/16: if the page never finishes loading, fall back to Safari once.
    _panelTimeout = [NSTimer scheduledTimerWithTimeInterval:6.0
                                                     target:self
                                                   selector:@selector(panelLoadTimedOut)
                                                   userInfo:nil
                                                    repeats:NO];

    IAGLogInfo(@"iAgent: 已在 SpringBoard 内打开控制面板");
}

- (void)reloadPanel
{
    if (_webView) [_webView reload];
}

- (void)closePanel
{
    [_panelTimeout invalidate];
    _panelTimeout = nil;
    [_webView stopLoading];
    _webView = nil;
    _panelStatus = nil;
    _panelWindow.hidden = YES;
    _panelWindow = nil;
}

- (void)panelLoadTimedOut
{
    _panelTimeout = nil;
    if (!_panelWindow) return;

    _forceSafari = YES;   // stop trying the embedded web view this session
    IAGLogWarn(@"iAgent: WKWebView 未能在 SpringBoard 内渲染，回退到浏览器");
    [self notifyWithTitle:@"iAgent" message:@"内置面板渲染失败，已改用浏览器打开。下次点击悬浮球将直接使用浏览器。" duration:4];
    [self openInSafari];
    [self closePanel];
}

#pragma mark WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    [_panelTimeout invalidate];
    _panelTimeout = nil;
    if (_panelStatus) {
        [_panelStatus removeFromSuperview];
        _panelStatus = nil;
    }
    // Belt and braces: if the page somehow renders blank, the user can still
    // reach the browser from the header button.
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    if (_panelStatus) _panelStatus.text = [NSString stringWithFormat:@"加载失败：%@", error.localizedDescription];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    if (_panelStatus) _panelStatus.text = [NSString stringWithFormat:@"无法连接：%@", error.localizedDescription];
}

#pragma mark notifications

- (void)notifyWithTitle:(NSString *)title message:(NSString *)message duration:(NSInteger)duration
{
    if (duration < 1) duration = 4;
    NSDictionary *options = @{
        (__bridge NSString *)kCFUserNotificationAlertHeaderKey: title ?: @"iAgent",
        (__bridge NSString *)kCFUserNotificationAlertMessageKey: message ?: @"",
        (__bridge NSString *)kCFUserNotificationAlertTopMostKey: @YES,
        (__bridge NSString *)kCFUserNotificationDefaultButtonTitleKey: @"好",
    };
    SInt32 errorCode = 0;
    CFUserNotificationRef notification = CFUserNotificationCreate(kCFAllocatorDefault,
                                                                 (CFTimeInterval)duration,
                                                                 kCFUserNotificationNoteAlertLevel,
                                                                 &errorCode,
                                                                 (__bridge CFDictionaryRef)options);
    if (notification) CFRelease(notification);
}

#pragma mark bridge client

- (void)startBridge
{
    if (_bridgeRunning) return;
    _bridgeRunning = YES;
    [_bridgeThread cancel];
    _bridgeThread = [[NSThread alloc] initWithTarget:self selector:@selector(bridgeLoop) object:nil];
    _bridgeThread.name = @"com.dsh.iagent.bridge";
    _bridgeThread.qualityOfService = NSQualityOfServiceUtility;
    [_bridgeThread start];
}

- (void)stopBridge
{
    _bridgeRunning = NO;
    [_bridgeThread cancel];
}

- (void)bridgeLoop
{
    NSUInteger pollCount = 0;
    while (_bridgeRunning && !_bridgeThread.cancelled) {
        @autoreleasepool {
            IAGConfig *config = [IAGConfig shared];
            if (pollCount % 15 == 0) [config reload];   // pick up port/token changes
            pollCount++;

            NSInteger port = [config port];
            NSString *token = [config authToken];
            NSString *capabilities = [NSString stringWithFormat:@"hid:%@,ax:%@,notify:cf",
                                      [IAGHID shared].available ? @"1" : @"0",
                                      [IAGAX shared].available ? @"1" : @"0"];
            NSString *url = [NSString stringWithFormat:@"http://%s:%ld/api/bridge/poll?since=%lu&wait=20&caps=%@",
                             IAG_DEFAULT_HOST.UTF8String, (long)port, (unsigned long)_bridgeCursor, capabilities];

            NSDictionary *response = IAGHTTPJSON(@"GET", url, nil, token, 30);
            if (![response isKindOfClass:[NSDictionary class]]) {
                if (_bridgeConnected) {
                    _bridgeConnected = NO;
                    IAGLogWarn(@"iAgent: 与控制面板的连接中断");
                }
                [NSThread sleepForTimeInterval:3.0];
                continue;
            }

            if (!_bridgeConnected) {
                _bridgeConnected = YES;
                IAGLogInfo(@"iAgent: 已连接到控制面板");
            }

            NSNumber *cursor = response[@"cursor"];
            if ([cursor isKindOfClass:[NSNumber class]]) _bridgeCursor = cursor.unsignedIntegerValue;

            NSArray *commands = response[@"commands"];
            if (![commands isKindOfClass:[NSArray class]]) continue;

            for (NSDictionary *command in commands) {
                if (![command isKindOfClass:[NSDictionary class]]) continue;
                NSString *commandId = IAGDictString(command, @"id", @"");
                NSString *action = IAGDictString(command, @"action", @"");
                NSDictionary *parameters = IAGDictDictionary(command, @"parameters") ?: @{};

                NSDictionary *result = [self executeAction:action parameters:parameters];
                IAGHTTPJSON(@"POST", [NSString stringWithFormat:@"http://%s:%ld/api/bridge/result",
                                      IAG_DEFAULT_HOST.UTF8String, (long)port],
                            @{ @"id": commandId,
                               @"ok": result[@"ok"] ?: @NO,
                               @"output": result[@"output"] ?: @"",
                               @"error": result[@"error"] ?: @"" },
                            token, 10);
            }
        }
    }
}

/// Runs the action on the main thread with a timeout, because HID dispatch and
/// every UI operation must happen there.
- (NSDictionary *)executeAction:(NSString *)action parameters:(NSDictionary *)parameters
{
    NSTimeInterval timeout = 20.0;
    if ([action isEqualToString:@"notify"]) timeout = 6.0;
    else if ([action isEqualToString:@"open_url"] || [action isEqualToString:@"launch_app"]) timeout = 8.0;
    else if ([action isEqualToString:@"ui_type"]) timeout = 25.0;

    __block NSDictionary *result = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            result = [self performAction:action parameters:parameters];
        } @catch (NSException *exception) {
            result = @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"%@ 执行异常: %@", action, exception.reason] };
        }
        if (!result) result = @{ @"ok": @NO, @"error": @"操作没有返回结果" };
        dispatch_semaphore_signal(semaphore);
    });

    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"%@ 在 %.0f 秒内没有完成（界面可能被占用）", action, timeout] };
    }
    return result ?: @{ @"ok": @NO, @"error": @"未知错误" };
}

- (NSDictionary *)performAction:(NSString *)action parameters:(NSDictionary *)parameters
{
    IAGHID *hid = [IAGHID shared];
    IAGAX *ax = [IAGAX shared];

    if ([action isEqualToString:@"ping"]) {
        return @{ @"ok": @YES, @"output": @"pong" };
    }

    if ([action isEqualToString:@"caps"]) {
        return @{ @"ok": @YES, @"output": [NSString stringWithFormat:@"hid=%@ ax=%@",
                                           [hid backendDescription], [ax backendDescription]] };
    }

    if ([action isEqualToString:@"notify"]) {
        NSString *title = IAGDictString(parameters, @"title", @"iAgent");
        NSString *message = IAGDictString(parameters, @"message", @"");
        NSInteger duration = IAGDictInteger(parameters, @"duration", 4);
        [self notifyWithTitle:title message:message duration:duration];
        return @{ @"ok": @YES, @"output": [NSString stringWithFormat:@"已显示提示: %@", message] };
    }

    if ([action isEqualToString:@"ui_describe"]) {
        NSInteger maxElements = IAGDictInteger(parameters, @"max_elements", 60);
        if (!ax.available) {
            return @{ @"ok": @NO, @"error": [NSString stringWithFormat:
                     @"无障碍接口不可用（%@）。请用 ui_tap 的 x/y 坐标方式操作。", [ax backendDescription]] };
        }
        return @{ @"ok": @YES, @"output": [ax describeWithMaxElements:maxElements] };
    }

    if ([action isEqualToString:@"ui_tap"]) {
        NSString *text = IAGDictString(parameters, @"text", @"");
        BOOL longPress = IAGDictBool(parameters, @"long_press", NO);

        if (text.length) {
            NSInteger index = IAGDictInteger(parameters, @"index", 0);
            CGPoint point = CGPointZero;
            NSString *label = nil;
            if ([ax locateText:text index:index point:&point label:&label]) {
                if ([ax lastLocateActivated]) {
                    return @{ @"ok": @YES, @"output": [NSString stringWithFormat:@"已通过无障碍动作点击 %@", label ?: text] };
                }
                if (!CGPointEqualToPoint(point, CGPointZero)) {
                    if ([hid tapAtPoint:point longPress:longPress]) {
                        return @{ @"ok": @YES, @"output": [NSString stringWithFormat:
                                 @"已在 (%.0f,%.0f) 点击 %@", point.x, point.y, label ?: text] };
                    }
                    return @{ @"ok": @NO, @"error": @"触摸注入不可用（HID 后端缺失）" };
                }
            }
            return @{ @"ok": @NO, @"error": [NSString stringWithFormat:
                     @"当前界面没有找到包含「%@」的可点击元素，请用 ui_describe 查看元素或改用 x/y 坐标", text] };
        }

        if (parameters[@"x"] == nil || parameters[@"y"] == nil) {
            return @{ @"ok": @NO, @"error": @"需要 x/y 坐标，或提供 text 让插件查找元素" };
        }
        CGPoint point = CGPointMake(IAGDictDouble(parameters, @"x", 0), IAGDictDouble(parameters, @"y", 0));
        if (![hid tapAtPoint:point longPress:longPress]) {
            return @{ @"ok": @NO, @"error": @"触摸注入不可用（HID 后端缺失）" };
        }
        return @{ @"ok": @YES, @"output": [NSString stringWithFormat:@"已在 (%.0f,%.0f) 点击", point.x, point.y] };
    }

    if ([action isEqualToString:@"ui_type"]) {
        NSString *text = IAGStringOrEmpty(parameters[@"text"]);
        if (text.length == 0) return @{ @"ok": @NO, @"error": @"缺少 text 参数" };
        if (![hid typeText:text]) {
            return @{ @"ok": @NO, @"error": @"输入失败：HID 键盘不可用或当前没有输入焦点" };
        }
        return @{ @"ok": @YES, @"output": [NSString stringWithFormat:@"已输入 %lu 个字符", (unsigned long)text.length] };
    }

    if ([action isEqualToString:@"ui_swipe"]) {
        CGPoint from = CGPointMake(IAGDictDouble(parameters, @"x1", 0), IAGDictDouble(parameters, @"y1", 0));
        CGPoint to = CGPointMake(IAGDictDouble(parameters, @"x2", 0), IAGDictDouble(parameters, @"y2", 0));
        NSTimeInterval duration = IAGDictDouble(parameters, @"duration", 0.3);
        if (![hid swipeFrom:from to:to duration:duration]) {
            return @{ @"ok": @NO, @"error": @"触摸注入不可用（HID 后端缺失）" };
        }
        return @{ @"ok": @YES, @"output": [NSString stringWithFormat:@"已从 (%.0f,%.0f) 滑动到 (%.0f,%.0f)",
                                           from.x, from.y, to.x, to.y] };
    }

    if ([action isEqualToString:@"open_url"]) {
        NSString *urlString = IAGDictString(parameters, @"url", @"");
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) return @{ @"ok": @NO, @"error": @"URL 非法" };
        __block BOOL opened = NO;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
            opened = success;
            dispatch_semaphore_signal(semaphore);
        }];
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        if (!opened) return @{ @"ok": @NO, @"error": @"系统拒绝打开该 URL" };
        return @{ @"ok": @YES, @"output": [NSString stringWithFormat:@"已打开 %@", urlString] };
    }

    if ([action isEqualToString:@"launch_app"]) {
        NSString *bundleIdentifier = IAGDictString(parameters, @"bundle_id", @"");
        if (bundleIdentifier.length == 0) return @{ @"ok": @NO, @"error": @"缺少 bundle_id" };

        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!workspaceClass) {
            dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
            workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        }
        id workspace = workspaceClass ? ((id (*)(id, SEL))objc_msgSend)(workspaceClass,
                                                                       NSSelectorFromString(@"defaultWorkspace")) : nil;
        SEL selector = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (workspace && [workspace respondsToSelector:selector]) {
            BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, selector, bundleIdentifier);
            if (ok) return @{ @"ok": @YES, @"output": [NSString stringWithFormat:@"已启动 %@", bundleIdentifier] };
        }
        return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"无法启动 %@（未安装或被系统拒绝）", bundleIdentifier] };
    }

    return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"插件不认识的动作: %@", action] };
}

@end

#pragma mark - entry point

__attribute__((constructor)) static void IAGTweakInitialize(void)
{
    @autoreleasepool {
        // The MobileSubstrate filter already restricts this dylib to SpringBoard;
        // double-check anyway so a stray load can never paint a bubble in an app.
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (bundleIdentifier.length && ![bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

        // Give SpringBoard time to finish launching its scene.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[IAGTweak shared] start];
        });
    }
}
