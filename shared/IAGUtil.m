//
//  IAGUtil.m
//  iAgent
//

#import "IAGUtil.h"

NSString *IAGStringFromUTF8Lossy(NSData *data, NSUInteger *consumedBytes)
{
    if (data.length == 0) {
        if (consumedBytes) *consumedBytes = 0;
        return @"";
    }

    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (string) {
        if (consumedBytes) *consumedBytes = data.length;
        return string;
    }

    // Walk backwards over the last (at most) three bytes looking for a byte that
    // could start a multi-byte sequence, then retry without it.
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    NSUInteger keep = length;
    for (NSUInteger back = 1; back <= 3 && back <= length; back++) {
        uint8_t b = bytes[length - back];
        if ((b & 0x80) == 0x00) break;              // plain ASCII: nothing truncated
        if ((b & 0xC0) == 0xC0) {                   // leading byte of a sequence
            NSUInteger needed = (b >= 0xF0) ? 4 : (b >= 0xE0) ? 3 : 2;
            if (needed > back) keep = length - back;
            break;
        }
    }

    if (keep == 0) {
        // Nothing decodable at all (very unlikely): drop one byte to make progress.
        keep = 0;
        NSString *lossy = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        if (consumedBytes) *consumedBytes = 1;
        return lossy.length > 1 ? [lossy substringToIndex:1] : @"";
    }

    NSData *slice = [data subdataWithRange:NSMakeRange(0, keep)];
    NSString *decoded = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
    if (!decoded) {
        decoded = [[NSString alloc] initWithData:slice encoding:NSISOLatin1StringEncoding];
    }
    if (consumedBytes) *consumedBytes = keep;
    return decoded ?: @"";
}

NSString *IAGShellQuote(NSString *string)
{
    if (string == nil) return @"''";
    if (string.length == 0) return @"''";
    // Fast path: nothing that needs quoting.
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:
                            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:@%+"];
    if ([string rangeOfCharacterFromSet:[safe invertedSet]].location == NSNotFound) {
        return string;
    }
    NSString *escaped = [string stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

NSString *IAGBase64Encode(NSData *data)
{
    if (data.length == 0) return @"";
    return [data base64EncodedStringWithOptions:0];
}

NSData *IAGBase64Decode(NSString *string)
{
    if (string.length == 0) return [NSData data];
    return [[NSData alloc] initWithBase64EncodedString:string
                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

NSString *IAGFormatBytes(long long bytes)
{
    if (bytes < 0) return @"未知";
    double value = (double)bytes;
    NSArray *units = @[ @"B", @"KB", @"MB", @"GB", @"TB" ];
    NSUInteger index = 0;
    while (value >= 1024.0 && index + 1 < units.count) {
        value /= 1024.0;
        index++;
    }
    if (index == 0) return [NSString stringWithFormat:@"%lld B", bytes];
    return [NSString stringWithFormat:@"%.2f %@", value, units[index]];
}

NSString *IAGCollapseWhitespace(NSString *string)
{
    if (string.length == 0) return @"";
    NSArray<NSString *> *parts = [string componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length) [kept addObject:part];
    }
    return [kept componentsJoinedByString:@" "];
}

NSString *IAGTruncateForModel(NSString *string, NSUInteger maxLength)
{
    if (string.length <= maxLength || maxLength < 64) return string ?: @"";
    NSUInteger headLength = (NSUInteger)(maxLength * 0.55);
    NSUInteger tailLength = maxLength - headLength - 64;
    NSUInteger dropped = string.length - headLength - tailLength;
    return [NSString stringWithFormat:@"%@\n\n… [中间省略 %lu 字符] …\n\n%@",
            [string substringToIndex:headLength],
            (unsigned long)dropped,
            [string substringFromIndex:string.length - tailLength]];
}

NSString *IAGHTMLToText(NSString *html)
{
    if (html.length == 0) return @"";
    NSMutableString *text = [html mutableCopy];

    // Remove script/style bodies entirely.
    for (NSString *tag in @[ @"script", @"style", @"noscript", @"svg", @"head" ]) {
        NSString *pattern = [NSString stringWithFormat:@"(?is)<%@[^>]*>.*?</%@>", tag, tag];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                              options:0 error:NULL];
        [regex replaceMatchesInString:text options:0
                                range:NSMakeRange(0, text.length) withTemplate:@""];
    }

    // Block level tags become newlines.
    NSRegularExpression *blocks = [NSRegularExpression
        regularExpressionWithPattern:@"(?i)</?(p|div|br|li|tr|h[1-6]|section|article|header|footer)[^>]*>"
                             options:0 error:NULL];
    [blocks replaceMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@"\n"];

    // Everything else is unwrapped.
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>"
                                                                        options:0 error:NULL];
    [tags replaceMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];

    NSArray<NSArray<NSString *> *> *entities = @[
        @[ @"&nbsp;", @" " ], @[ @"&amp;", @"&" ], @[ @"&lt;", @"<" ], @[ @"&gt;", @">" ],
        @[ @"&quot;", @"\"" ], @[ @"&#39;", @"'" ], @[ @"&apos;", @"'" ], @[ @"&mdash;", @"—" ],
        @[ @"&ndash;", @"–" ], @[ @"&hellip;", @"…" ], @[ @"&ldquo;", @"“" ], @[ @"&rdquo;", @"”" ],
    ];
    for (NSArray<NSString *> *pair in entities) {
        [text replaceOccurrencesOfString:pair[0] withString:pair[1]
                                 options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
    }

    // Collapse blank lines and trailing spaces.
    NSRegularExpression *spaces = [NSRegularExpression regularExpressionWithPattern:@"[ \t]+"
                                                                           options:0 error:NULL];
    [spaces replaceMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@" "];
    NSRegularExpression *blankLines = [NSRegularExpression regularExpressionWithPattern:@"\n{3,}"
                                                                               options:0 error:NULL];
    [blankLines replaceMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@"\n\n"];

    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

void IAGRunOnMainSync(dispatch_block_t block)
{
    if (!block) return;
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}
