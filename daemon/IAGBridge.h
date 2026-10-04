//
//  IAGBridge.h
//  iAgent
//
//  The daemon side of the SpringBoard bridge.
//
//  The daemon never injects touches itself: HID event injection has to run
//  inside a process that already holds the relevant entitlements, which is
//  SpringBoard. So UI automation (and pretty notifications) are queued here and
//  collected by the tweak through a long-poll on GET /api/bridge/poll; results
//  come back through POST /api/bridge/result.
//
//  Everything is in-memory: no shared files, no permissions problems between a
//  root daemon and a mobile tweak.
//

#ifndef IAG_BRIDGE_H
#define IAG_BRIDGE_H

#import <Foundation/Foundation.h>

@interface IAGBridgeCommand : NSObject
@property (nonatomic, copy, readonly)   NSString *commandId;
@property (nonatomic, copy, readonly)   NSString *action;
@property (nonatomic, strong, readonly) NSDictionary *parameters;
@property (nonatomic, assign)           BOOL delivered;
@property (nonatomic, strong)           NSDictionary *result;
@property (nonatomic, assign)           NSTimeInterval createdAt;
@end

@interface IAGBridge : NSObject

+ (instancetype)shared;

/// Queue an action for the tweak and block until it answers (or `timeout`
/// elapses). Returns { ok: BOOL, output: String } / { ok: NO, error: String }.
- (NSDictionary *)performAction:(NSString *)action
                     parameters:(NSDictionary *)parameters
                        timeout:(NSTimeInterval)timeout;

/// Long-poll used by GET /api/bridge/poll.
/// { commands: [ { id, action, parameters } ], cursor: Number }
- (NSDictionary *)pollSince:(NSUInteger)cursor wait:(NSTimeInterval)wait;

/// Called by POST /api/bridge/result.
- (BOOL)submitResult:(NSDictionary *)result;

/// GET /api/bridge/status payload.
- (NSDictionary *)statusJSON;

/// true when the tweak polled us recently.
- (BOOL)connected;

/// Capabilities reported by the most recent poll (hid / ax / notify).
- (NSDictionary *)capabilities;

/// Record the capabilities the tweak advertised on its last poll.
- (void)noteCapabilities:(NSDictionary *)capabilities;

/// Wake every long-poll (used on shutdown).
- (void)cancelAll;

@end

#endif /* IAG_BRIDGE_H */
