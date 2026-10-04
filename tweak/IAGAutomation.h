//
//  IAGAutomation.h
//  iAgent — SpringBoard side.
//
//  Touch / keyboard injection and the accessibility tree dump.
//
//  Notes that drove this implementation (verified against XXTouch, ZXTouch and
//  the AXRuntime headers — see docs/research/ios-private-apis.md):
//
//    * Touch injection uses IOHIDEventCreateDigitizerFingerEvent with
//      NORMALISED coordinates (0..1), wrapped in a parent digitizer event, and
//      dispatched from the main queue. HID dispatch is also possible from a root
//      daemon holding the HID entitlements, but running it here keeps the
//      daemon's entitlement footprint tiny and reuses SpringBoard's own.
//    * There is no usable C AXUIElement API on iOS. The practical entry point is
//      the Objective-C AXElement class in AXRuntime.framework.
//    * Everything is resolved with dlopen / NSClassFromString: no private
//      framework is linked and no private SDK header is required.
//

#ifndef IAG_AUTOMATION_H
#define IAG_AUTOMATION_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#pragma mark - HID (touch + keyboard injection)

@interface IAGHID : NSObject

+ (instancetype)shared;

/// Resolve the private IOKit symbols. Safe to call repeatedly.
- (void)prepare;

@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly) NSString *backendDescription;

/// A tap at a point in screen coordinates (UIKit points, origin top-left).
/// Returns NO when the HID stack is unavailable.
- (BOOL)tapAtPoint:(CGPoint)point longPress:(BOOL)longPress;
- (BOOL)swipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)duration;

/// Type text into whatever currently has keyboard focus.
/// ASCII goes through HID keyboard events; anything else is written through the
/// accessibility first responder and, failing that, the pasteboard + ⌘V (the
/// only reliable way to enter CJK from outside the foreground app).
- (BOOL)typeText:(NSString *)text;

@end

#pragma mark - Accessibility (AXRuntime's Objective-C AXElement)

@interface IAGAXElement : NSObject
@property (nonatomic, copy)   NSString *label;
@property (nonatomic, copy)   NSString *value;
@property (nonatomic, copy)   NSString *identifier;
@property (nonatomic, copy)   NSString *bundleId;
@property (nonatomic, assign) CGRect frame;
@property (nonatomic, assign) NSInteger depth;
- (NSString *)oneLineDescription;
@end

@interface IAGAX : NSObject

+ (instancetype)shared;
- (void)prepare;

@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly) NSString *backendDescription;

/// Human/model readable dump of the frontmost interface. Never returns nil.
- (NSString *)describeWithMaxElements:(NSInteger)maxElements;

/// Find the `index`-th element whose label/value/identifier contains `text`.
/// When the element supports activation it is pressed directly; the caller also
/// gets the element centre so it can fall back to a synthetic tap.
- (BOOL)locateText:(NSString *)text index:(NSInteger)index point:(CGPoint *)point label:(NSString **)label;

/// Whether the last locateText: call managed to activate the element in place.
- (BOOL)lastLocateActivated;

/// Write into the focused text field through the accessibility API.
- (BOOL)setFocusedText:(NSString *)text;

@end

#endif /* IAG_AUTOMATION_H */
