//
//  IAGJSON.h
//  iAgent
//
//  Defensive JSON helpers. Every accessor tolerates a missing key, a nil
//  dictionary or a value of the wrong class, because tool arguments come from a
//  language model and are frequently malformed.
//

#ifndef IAG_JSON_H
#define IAG_JSON_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NSData *IAGJSONEncode(id object, BOOL pretty);
NSString *IAGJSONEncodeString(id object);
id IAGJSONDecode(NSData *data, NSError **error);
id IAGJSONDecodeString(NSString *string, NSError **error);

/// JSON *literal* (quoted and escaped) for the given string, safe to embed.
NSString *IAGJSONLiteral(NSString *string);

// Safe dictionary accessors.
NSString *IAGDictString(NSDictionary *dict, NSString *key, NSString *fallback);
NSInteger IAGDictInteger(NSDictionary *dict, NSString *key, NSInteger fallback);
double IAGDictDouble(NSDictionary *dict, NSString *key, double fallback);
BOOL IAGDictBool(NSDictionary *dict, NSString *key, BOOL fallback);
NSArray *IAGDictArray(NSDictionary *dict, NSString *key);
NSDictionary *IAGDictDictionary(NSDictionary *dict, NSString *key);

/// First key of `keys` that is present and non-empty.
NSString *IAGDictStringAny(NSDictionary *dict, NSArray<NSString *> *keys, NSString *fallback);

NSString *IAGStringOrEmpty(id value);
NSString *IAGTruncateString(NSString *string, NSUInteger maxLength);

/// {"error": "..."} — the single error shape used across the HTTP API.
NSDictionary *IAGErrorObject(NSString *message);
NSDictionary *IAGOkObject(void);

/// Coerce arbitrary JSON-ish input into a JSON object tree (dictionary/array).
/// Returns nil when the input cannot be interpreted.
id IAGJSONCoerce(id value);

#ifdef __cplusplus
}
#endif

#endif /* IAG_JSON_H */
