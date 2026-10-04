//
//  IAGAutomation.m
//  iAgent — SpringBoard side.
//

#import "IAGAutomation.h"
#import "IAGUtil.h"

#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <UIKit/UIKit.h>

#pragma mark - private IOKit declarations
//
// Signatures and field offsets below were verified against XXTouch's
// IOKitSPI.h / STHIDEventGenerator.m and ZXTouch's Touch.xm:
// IOHIDEventFieldBase(type) == (type << 16) and kIOHIDEventTypeDigitizer == 11,
// so the digitizer fields start at 0xB0000. The sender id is the constant
// XXTouch stamps on synthetic events.
//

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

enum {
    kIAGFieldDigitizerX                   = 0xB0000,
    kIAGFieldDigitizerY                   = 0xB0001,
    kIAGFieldDigitizerIdentity            = 0xB0006,
    kIAGFieldDigitizerEventMask           = 0xB0007,
    kIAGFieldDigitizerRange               = 0xB0008,
    kIAGFieldDigitizerTouch               = 0xB0009,
    kIAGFieldDigitizerMajorRadius         = 0xB0014,
    kIAGFieldDigitizerMinorRadius         = 0xB0015,
    kIAGFieldDigitizerIsDisplayIntegrated = 0xB0019,
    kIAGFieldIsBuiltIn                    = 0x4,      // IOHIDEventFieldBase(type NULL) | 4
};

// Child event masks, exactly as ZXTouch uses them.
enum {
    kIAGTouchMaskDown = 3,   // Range | Touch
    kIAGTouchMaskMove = 4,   // Position
    kIAGTouchMaskUp   = 2,   // Touch
};

enum {
    kIAGHIDPageKeyboardOrKeypad = 0x07,
    kIAGHIDUsageLeftShift       = 0xE1,
    kIAGHIDUsageLeftGUI         = 0xE3,
    kIAGHIDUsageKeyV            = 0x19,
};

typedef IOHIDEventRef (*IAGCreateDigitizerEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                                   uint32_t, uint32_t, uint32_t, double, double,
                                                   double, double, double, Boolean, Boolean, uint32_t);
typedef IOHIDEventRef (*IAGCreateDigitizerFingerEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                                         uint32_t, double, double, double, double,
                                                         double, Boolean, Boolean, uint32_t);
typedef IOHIDEventRef (*IAGCreateKeyboardEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                                  Boolean, uint32_t);
typedef void (*IAGEventSetIntegerValueFn)(IOHIDEventRef, uint32_t, CFIndex);
typedef void (*IAGEventSetFloatValueFn)(IOHIDEventRef, uint32_t, double);
typedef void (*IAGEventAppendEventFn)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*IAGEventSetSenderIDFn)(IOHIDEventRef, uint64_t);
typedef IOHIDEventSystemClientRef (*IAGEventSystemClientCreateFn)(CFAllocatorRef);
typedef void (*IAGEventSystemClientDispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);

static const uint64_t kIAGSenderID = 0x8000000817319372ULL;

#pragma mark - objc_msgSend helpers

static id IAGSendObject(id target, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static BOOL IAGSendBool(id target, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector) ? YES : NO;
}

static CGRect IAGSendRect(id target, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return CGRectZero;
    return ((CGRect (*)(id, SEL))objc_msgSend)(target, selector);
}

#pragma mark - IAGHID

@implementation IAGHID {
    BOOL _prepared;
    BOOL _available;
    NSString *_backend;

    void *_iokitHandle;

    IAGCreateDigitizerEventFn _createDigitizerEvent;
    IAGCreateDigitizerFingerEventFn _createDigitizerFingerEvent;
    IAGCreateKeyboardEventFn _createKeyboardEvent;
    IAGEventSetIntegerValueFn _setIntegerValue;
    IAGEventSetFloatValueFn _setFloatValue;
    IAGEventAppendEventFn _appendEvent;
    IAGEventSetSenderIDFn _setSenderID;
    IAGEventSystemClientCreateFn _systemClientCreate;
    IAGEventSystemClientDispatchFn _systemClientDispatch;

    IOHIDEventSystemClientRef _client;
    uint32_t _fingerIndex;
}

+ (instancetype)shared
{
    static IAGHID *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[IAGHID alloc] init];
        [shared prepare];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) _fingerIndex = 1;
    return self;
}

- (void)prepare
{
    if (_prepared) return;
    _prepared = YES;

    _iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!_iokitHandle) _iokitHandle = dlopen("IOKit", RTLD_LAZY);

    void *handle = _iokitHandle;
    if (handle) {
        _createDigitizerEvent = (IAGCreateDigitizerEventFn)dlsym(handle, "IOHIDEventCreateDigitizerEvent");
        _createDigitizerFingerEvent = (IAGCreateDigitizerFingerEventFn)dlsym(handle, "IOHIDEventCreateDigitizerFingerEvent");
        _createKeyboardEvent = (IAGCreateKeyboardEventFn)dlsym(handle, "IOHIDEventCreateKeyboardEvent");
        _setIntegerValue = (IAGEventSetIntegerValueFn)dlsym(handle, "IOHIDEventSetIntegerValue");
        _setFloatValue = (IAGEventSetFloatValueFn)dlsym(handle, "IOHIDEventSetFloatValue");
        _appendEvent = (IAGEventAppendEventFn)dlsym(handle, "IOHIDEventAppendEvent");
        _setSenderID = (IAGEventSetSenderIDFn)dlsym(handle, "IOHIDEventSetSenderID");
        // XXTouch and ZXTouch both use IOHIDEventSystemClientCreate; the
        // "...SimpleClient" spelling is only a fallback probe.
        _systemClientCreate = (IAGEventSystemClientCreateFn)dlsym(handle, "IOHIDEventSystemClientCreate");
        if (!_systemClientCreate) {
            _systemClientCreate = (IAGEventSystemClientCreateFn)dlsym(handle, "IOHIDEventSystemClientCreateSimpleClient");
        }
        _systemClientDispatch = (IAGEventSystemClientDispatchFn)dlsym(handle, "IOHIDEventSystemClientDispatchEvent");
    }

    BOOL hasDigitizer = (_createDigitizerFingerEvent != NULL && _createDigitizerEvent != NULL);
    if (_systemClientCreate && _systemClientDispatch && hasDigitizer) {
        _client = _systemClientCreate(kCFAllocatorDefault);
        _available = (_client != NULL);
    }

    _backend = [NSString stringWithFormat:@"client=%@ finger=%@ keyboard=%@ sender=%@",
                _client ? @"ok" : @"missing",
                _createDigitizerFingerEvent ? @"ok" : @"missing",
                _createKeyboardEvent ? @"ok" : @"missing",
                _setSenderID ? @"ok" : @"missing"];
    NSLog(@"[iAgent] HID backend: %@ available=%@", _backend, _available ? @"yes" : @"no");
}

- (BOOL)available { [self prepare]; return _available; }
- (NSString *)backendDescription { [self prepare]; return _backend ?: @"unknown"; }

#pragma mark touch

/// One synthetic finger event: a parent digitizer event carrying a finger child
/// event, dispatched from the main queue (the way XXTouch does it).
- (BOOL)sendTouchWithMask:(uint32_t)mask
                    range:(BOOL)range
                    touch:(BOOL)touch
                    point:(CGPoint)point
{
    if (!_available) return NO;

    CGSize screen = CGSizeMake(390, 844);
    UIScreen *mainScreen = [UIScreen mainScreen];
    if (mainScreen) screen = mainScreen.bounds.size;
    if (screen.width < 1) screen.width = 390;
    if (screen.height < 1) screen.height = 844;

    double nx = MAX(0.0, MIN(1.0, point.x / screen.width));
    double ny = MAX(0.0, MIN(1.0, point.y / screen.height));

    uint32_t index = _fingerIndex;
    _fingerIndex = (_fingerIndex % 8) + 1;

    IOHIDEventRef child = _createDigitizerFingerEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                      index,   // finger index
                                                      3,       // identity
                                                      mask,
                                                      nx, ny, 0.0,
                                                      0.0,     // tip pressure
                                                      0.0,     // twist
                                                      range ? 1 : 0,
                                                      touch ? 1 : 0,
                                                      0);
    if (!child) return NO;

    if (_setFloatValue) {
        _setFloatValue(child, kIAGFieldDigitizerMajorRadius, 0.04f);
        _setFloatValue(child, kIAGFieldDigitizerMinorRadius, 0.04f);
    }
    if (_setIntegerValue) {
        _setIntegerValue(child, kIAGFieldIsBuiltIn, 1);
        _setIntegerValue(child, kIAGFieldDigitizerIsDisplayIntegrated, 1);
        _setIntegerValue(child, kIAGFieldDigitizerIdentity, 3);
    }

    IOHIDEventRef parent = _createDigitizerEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                 3,     // transducer type
                                                 99,    // index
                                                 1,     // identity
                                                 0,     // event mask
                                                 0,     // button mask
                                                 nx, ny, 0.0,
                                                 0.0,   // tip pressure
                                                 0.0,   // twist
                                                 0, 0, 0);
    if (parent) {
        if (_setIntegerValue) {
            _setIntegerValue(parent, kIAGFieldDigitizerIsDisplayIntegrated, 1);
            _setIntegerValue(parent, kIAGFieldIsBuiltIn, 1);
            _setIntegerValue(parent, kIAGFieldDigitizerEventMask, 0x23);
            _setIntegerValue(parent, kIAGFieldDigitizerRange, 1);
            _setIntegerValue(parent, kIAGFieldDigitizerTouch, 1);
        }
        if (_appendEvent) _appendEvent(parent, child, 0);
    }

    IOHIDEventRef dispatched = parent ?: child;
    CFRetain(dispatched);

    IAGRunOnMainSync(^{
        if (self->_setSenderID) self->_setSenderID(dispatched, kIAGSenderID);
        self->_systemClientDispatch(self->_client, dispatched);
        CFRelease(dispatched);
    });

    if (parent) CFRelease(parent);
    CFRelease(child);
    return YES;
}

- (BOOL)tapAtPoint:(CGPoint)point longPress:(BOOL)longPress
{
    [self prepare];
    if (!_available) return NO;

    if (![self sendTouchWithMask:kIAGTouchMaskDown range:YES touch:YES point:point]) return NO;
    usleep(longPress ? 900000 : 50000);
    [self sendTouchWithMask:kIAGTouchMaskUp range:NO touch:NO point:point];
    return YES;
}

- (BOOL)swipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)duration
{
    [self prepare];
    if (!_available) return NO;
    if (duration <= 0.05) duration = 0.3;
    if (duration > 5.0) duration = 5.0;

    if (![self sendTouchWithMask:kIAGTouchMaskDown range:YES touch:YES point:from]) return NO;

    const int steps = MAX(6, (int)(duration * 60.0));
    NSTimeInterval stepDelay = duration / (NSTimeInterval)steps;
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / (double)steps;
        CGPoint point = CGPointMake(from.x + (to.x - from.x) * t,
                                    from.y + (to.y - from.y) * t);
        [self sendTouchWithMask:kIAGTouchMaskMove range:YES touch:YES point:point];
        usleep((useconds_t)(stepDelay * 1000000.0));
    }

    [self sendTouchWithMask:kIAGTouchMaskUp range:NO touch:NO point:to];
    return YES;
}

#pragma mark keyboard

- (BOOL)pressKeyUsage:(uint32_t)usage
{
    if (!_available || !_createKeyboardEvent || !_systemClientDispatch) return NO;

    IOHIDEventRef down = _createKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                              kIAGHIDPageKeyboardOrKeypad, usage, true, 0);
    if (!down) return NO;
    IOHIDEventRef up = _createKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                            kIAGHIDPageKeyboardOrKeypad, usage, false, 0);

    IAGRunOnMainSync(^{
        self->_systemClientDispatch(self->_client, down);
        if (up) self->_systemClientDispatch(self->_client, up);
    });

    CFRelease(down);
    if (up) CFRelease(up);
    usleep(12000);
    return YES;
}

- (BOOL)pressKeyUsage:(uint32_t)usage withShift:(BOOL)shift
{
    if (!shift) return [self pressKeyUsage:usage];

    IOHIDEventRef shiftDown = _createKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                   kIAGHIDPageKeyboardOrKeypad, kIAGHIDUsageLeftShift, true, 0);
    if (shiftDown) {
        IAGRunOnMainSync(^{ self->_systemClientDispatch(self->_client, shiftDown); });
        CFRelease(shiftDown);
        usleep(10000);
    }

    BOOL ok = [self pressKeyUsage:usage];

    IOHIDEventRef shiftUp = _createKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                 kIAGHIDPageKeyboardOrKeypad, kIAGHIDUsageLeftShift, false, 0);
    if (shiftUp) {
        IAGRunOnMainSync(^{ self->_systemClientDispatch(self->_client, shiftUp); });
        CFRelease(shiftUp);
    }
    return ok;
}

/// USB HID keyboard usage for a character. Returns 0 when there is no mapping.
static uint32_t IAGKeyUsageForCharacter(unichar character, BOOL *needsShift)
{
    if (needsShift) *needsShift = NO;

    if (character >= 'a' && character <= 'z') return 0x04 + (uint32_t)(character - 'a');
    if (character >= 'A' && character <= 'Z') {
        if (needsShift) *needsShift = YES;
        return 0x04 + (uint32_t)(character - 'A');
    }
    if (character >= '1' && character <= '9') return 0x1E + (uint32_t)(character - '1');
    if (character == '0') return 0x27;

    switch (character) {
        case '\n': case '\r': return 0x28;
        case 0x1B: return 0x29;
        case 0x7F: case '\b': return 0x2A;
        case '\t': return 0x2B;
        case ' ': return 0x2C;
        case '-': return 0x2D;
        case '=': return 0x2E;
        case '[': return 0x2F;
        case ']': return 0x30;
        case '\\': return 0x31;
        case ';': return 0x33;
        case '\'': return 0x34;
        case '`': return 0x35;
        case ',': return 0x36;
        case '.': return 0x37;
        case '/': return 0x38;
        case '!': if (needsShift) *needsShift = YES; return 0x1E;
        case '@': if (needsShift) *needsShift = YES; return 0x1F;
        case '#': if (needsShift) *needsShift = YES; return 0x20;
        case '$': if (needsShift) *needsShift = YES; return 0x21;
        case '%': if (needsShift) *needsShift = YES; return 0x22;
        case '^': if (needsShift) *needsShift = YES; return 0x23;
        case '&': if (needsShift) *needsShift = YES; return 0x24;
        case '*': if (needsShift) *needsShift = YES; return 0x25;
        case '(': if (needsShift) *needsShift = YES; return 0x26;
        case ')': if (needsShift) *needsShift = YES; return 0x27;
        case '_': if (needsShift) *needsShift = YES; return 0x2D;
        case '+': if (needsShift) *needsShift = YES; return 0x2E;
        case '{': if (needsShift) *needsShift = YES; return 0x2F;
        case '}': if (needsShift) *needsShift = YES; return 0x30;
        case '|': if (needsShift) *needsShift = YES; return 0x31;
        case ':': if (needsShift) *needsShift = YES; return 0x33;
        case '"': if (needsShift) *needsShift = YES; return 0x34;
        case '~': if (needsShift) *needsShift = YES; return 0x35;
        case '<': if (needsShift) *needsShift = YES; return 0x36;
        case '>': if (needsShift) *needsShift = YES; return 0x37;
        case '?': if (needsShift) *needsShift = YES; return 0x38;
        default: return 0;
    }
}

- (BOOL)typeText:(NSString *)text
{
    [self prepare];
    if (text.length == 0 || !_available) return NO;

    BOOL asciiOnly = YES;
    for (NSUInteger i = 0; i < text.length; i++) {
        if ([text characterAtIndex:i] > 0x7E) { asciiOnly = NO; break; }
    }

    if (asciiOnly) {
        for (NSUInteger i = 0; i < text.length; i++) {
            BOOL shift = NO;
            uint32_t usage = IAGKeyUsageForCharacter([text characterAtIndex:i], &shift);
            if (usage == 0) continue;
            if (![self pressKeyUsage:usage withShift:shift]) return NO;
            usleep(15000);
        }
        return YES;
    }

    // Non-ASCII (CJK and friends) cannot be produced by HID key usages.
    if ([[IAGAX shared] setFocusedText:text]) return YES;

    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    NSString *previous = pasteboard.string;
    pasteboard.string = text;
    usleep(80000);

    IOHIDEventRef commandDown = _createKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                     kIAGHIDPageKeyboardOrKeypad, kIAGHIDUsageLeftGUI, true, 0);
    IOHIDEventRef vDown = _createKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                               kIAGHIDPageKeyboardOrKeypad, kIAGHIDUsageKeyV, true, 0);
    IOHIDEventRef vUp = _createKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                             kIAGHIDPageKeyboardOrKeypad, kIAGHIDUsageKeyV, false, 0);
    IOHIDEventRef commandUp = _createKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                   kIAGHIDPageKeyboardOrKeypad, kIAGHIDUsageLeftGUI, false, 0);

    IAGRunOnMainSync(^{
        if (commandDown) self->_systemClientDispatch(self->_client, commandDown);
        if (vDown) self->_systemClientDispatch(self->_client, vDown);
        if (vUp) self->_systemClientDispatch(self->_client, vUp);
        if (commandUp) self->_systemClientDispatch(self->_client, commandUp);
    });

    IOHIDEventRef events[] = { commandDown, vDown, vUp, commandUp };
    for (size_t i = 0; i < sizeof(events) / sizeof(events[0]); i++) {
        if (events[i]) CFRelease(events[i]);
    }

    if (previous.length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIPasteboard generalPasteboard].string = previous;
        });
    }
    return YES;
}

@end

#pragma mark - IAGAXElement

@implementation IAGAXElement

- (NSString *)oneLineDescription
{
    NSMutableString *line = [NSMutableString string];
    [line appendString:[@"" stringByPaddingToLength:(NSUInteger)(self.depth * 2) withString:@" " startingAtIndex:0]];
    [line appendString:self.identifier.length ? self.identifier : @"element"];

    NSString *text = self.label.length ? self.label : self.value;
    if (text.length) {
        text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        if (text.length > 80) text = [[text substringToIndex:80] stringByAppendingString:@"…"];
        [line appendFormat:@" \"%@\"", text];
    }
    if (self.bundleId.length) [line appendFormat:@" [%@]", self.bundleId];

    if (!CGRectIsEmpty(self.frame)) {
        [line appendFormat:@" @ (%.0f,%.0f) %.0fx%.0f",
            self.frame.origin.x, self.frame.origin.y, self.frame.size.width, self.frame.size.height];
    }
    return line;
}

@end

#pragma mark - IAGAX

@implementation IAGAX {
    BOOL _prepared;
    Class _elementClass;
    NSString *_backend;

    NSInteger _searchIndex;
    NSString *_searchText;
    BOOL _searchHit;
    BOOL _searchActivated;
    CGPoint _searchPoint;
    NSString *_searchLabel;
}

+ (instancetype)shared
{
    static IAGAX *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[IAGAX alloc] init];
        [shared prepare];
    });
    return shared;
}

- (void)prepare
{
    if (_prepared) return;
    _prepared = YES;

    const char *candidates[] = {
        "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        dlopen(candidates[i], RTLD_LAZY);
    }

    _elementClass = NSClassFromString(@"AXElement");
    _backend = [NSString stringWithFormat:@"AXElement=%@",
                _elementClass ? NSStringFromClass(_elementClass) : @"missing"];
    NSLog(@"[iAgent] AX backend: %@", _backend);
}

- (BOOL)available { [self prepare]; return _elementClass != Nil; }
- (NSString *)backendDescription { [self prepare]; return _backend ?: @"unknown"; }
- (BOOL)lastLocateActivated { return _searchActivated; }

- (id)systemWideElement
{
    [self prepare];
    if (!_elementClass) return nil;
    return IAGSendObject(_elementClass, @"systemWideElement");
}

- (id)frontmostApplicationElement
{
    id systemWide = [self systemWideElement];
    if (!systemWide) return nil;

    id application = IAGSendObject(systemWide, @"currentApplication");
    if (application) return application;
    application = IAGSendObject(systemWide, @"application");
    if (application) return application;
    return systemWide;
}

#pragma mark traversal

- (void)walkElement:(id)element
              depth:(NSInteger)depth
           maxDepth:(NSInteger)maxDepth
              lines:(NSMutableArray<NSString *> *)lines
             budget:(NSInteger *)budget
{
    if (!element || *budget <= 0 || depth > maxDepth) return;

    NSString *label = IAGSendObject(element, @"label");
    NSString *value = IAGSendObject(element, @"value");
    NSString *identifier = IAGSendObject(element, @"identifier");
    NSString *bundleId = IAGSendObject(element, @"bundleId");
    CGRect frame = IAGSendRect(element, @"frame");

    if (![label isKindOfClass:[NSString class]]) label = nil;
    if (![value isKindOfClass:[NSString class]]) value = nil;
    if (![identifier isKindOfClass:[NSString class]]) identifier = nil;
    if (![bundleId isKindOfClass:[NSString class]]) bundleId = nil;

    BOOL interesting = (label.length > 0 || value.length > 0 || identifier.length > 0) &&
                       !CGRectIsEmpty(frame);

    if (interesting) {
        IAGAXElement *node = [[IAGAXElement alloc] init];
        node.depth = depth;
        node.label = label ?: @"";
        node.value = value ?: @"";
        node.identifier = identifier ?: @"";
        node.bundleId = bundleId ?: @"";
        node.frame = frame;
        [lines addObject:[node oneLineDescription]];
        (*budget)--;
    }

    if (_searchText.length && !_searchHit) {
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@",
                              label ?: @"", value ?: @"", identifier ?: @""];
        if ([haystack rangeOfString:_searchText options:NSCaseInsensitiveSearch].location != NSNotFound) {
            if (_searchIndex <= 0 && !CGRectIsEmpty(frame)) {
                _searchHit = YES;
                _searchPoint = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
                _searchLabel = [NSString stringWithFormat:@"%@ %@",
                                identifier.length ? identifier : @"element",
                                label.length ? label : (value ?: @"")];
                // Prefer activating the element itself over a coordinate tap.
                _searchActivated = IAGSendBool(element, @"press");
                return;
            }
            if (_searchIndex > 0) _searchIndex--;
        }
    }

    if (*budget <= 0) return;

    NSArray *children = IAGSendObject(element, @"children");
    if (![children isKindOfClass:[NSArray class]]) return;
    for (id child in children) {
        if (*budget <= 0 || _searchHit) break;
        [self walkElement:child depth:depth + 1 maxDepth:maxDepth lines:lines budget:budget];
    }
}

- (NSString *)describeWithMaxElements:(NSInteger)maxElements
{
    [self prepare];
    if (!_elementClass) {
        return [NSString stringWithFormat:
                @"无障碍接口不可用（%@）。请改用 ui_tap 的 x/y 坐标方式操作界面。", _backend ?: @"unknown"];
    }
    if (maxElements <= 0) maxElements = 60;

    id root = [self frontmostApplicationElement];
    if (!root) {
        return @"AXElement 未能返回前台应用（无障碍服务不可达）。请改用 ui_tap 的 x/y 坐标方式操作界面。";
    }

    _searchText = nil;
    _searchHit = NO;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSInteger budget = maxElements;
    [self walkElement:root depth:0 maxDepth:8 lines:lines budget:&budget];

    if (lines.count == 0) {
        return @"前台界面没有可读元素（可能是全屏画面或无障碍树为空）。请改用 ui_tap 的 x/y 坐标方式操作界面。";
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (BOOL)locateText:(NSString *)text index:(NSInteger)index point:(CGPoint *)point label:(NSString **)label
{
    [self prepare];
    if (!_elementClass || text.length == 0) return NO;

    id root = [self frontmostApplicationElement];
    if (!root) return NO;

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSInteger budget = 500;
    _searchText = text;
    _searchIndex = MAX(0, index);
    _searchHit = NO;
    _searchActivated = NO;

    [self walkElement:root depth:0 maxDepth:8 lines:lines budget:&budget];
    _searchText = nil;

    if (!_searchHit) return NO;
    if (point) *point = _searchPoint;
    if (label) *label = _searchLabel;
    return YES;
}

- (BOOL)setFocusedText:(NSString *)text
{
    [self prepare];
    if (!_elementClass || text.length == 0) return NO;

    id application = [self frontmostApplicationElement];
    if (!application) return NO;

    id responder = IAGSendObject(application, @"firstResponder");
    if (!responder) return NO;
    if (![responder respondsToSelector:NSSelectorFromString(@"setValue:")]) return NO;

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(responder, NSSelectorFromString(@"setValue:"), text);
    } @catch (NSException *exception) {
        NSLog(@"[iAgent] setValue: on the first responder failed: %@", exception.reason);
        return NO;
    }

    NSString *current = IAGSendObject(responder, @"value");
    return ([current isKindOfClass:[NSString class]] && current.length > 0);
}

@end
