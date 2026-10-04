//
//  IAGUtil.h
//  iAgent
//
//  Small shared utilities: safe UTF-8 decoding of byte streams that may be cut
//  mid-character (PTY output), POSIX shell quoting, base64 and formatting.
//

#ifndef IAG_UTIL_H
#define IAG_UTIL_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Decode UTF-8, tolerating a truncated multi-byte sequence at the end.
/// `consumedBytes` (optional) receives how many bytes were actually decoded, so
/// the caller can re-read the tail next time.
NSString *IAGStringFromUTF8Lossy(NSData *data, NSUInteger *consumedBytes);

/// POSIX single-quote a string so it can be embedded in a shell command.
NSString *IAGShellQuote(NSString *string);

NSString *IAGBase64Encode(NSData *data);
NSData *IAGBase64Decode(NSString *string);

/// "1.2 MB" style formatting.
NSString *IAGFormatBytes(long long bytes);

/// Collapse runs of whitespace and trim, for one-line log/UI summaries.
NSString *IAGCollapseWhitespace(NSString *string);

/// Truncate for a language model: keeps the head (context) and the tail (where
/// errors usually are) and inserts a marker with the number of dropped bytes.
NSString *IAGTruncateForModel(NSString *string, NSUInteger maxLength);

/// Strip HTML down to readable text (drops script/style, unwraps tags, decodes
/// the handful of entities that actually matter).
NSString *IAGHTMLToText(NSString *html);

/// Run a block on the main thread synchronously unless we are already there.
void IAGRunOnMainSync(dispatch_block_t block);

#ifdef __cplusplus
}
#endif

#endif /* IAG_UTIL_H */
