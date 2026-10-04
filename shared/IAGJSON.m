//
//  IAGJSON.m
//  iAgent
//

#import "IAGJSON.h"

NSData *IAGJSONEncode(id object, BOOL pretty)
{
    if (object == nil) return nil;
    if (![NSJSONSerialization isValidJSONObject:object]) {
        // Wrap unencodable leaves (dates, custom objects) instead of failing.
        object = @{ @"value": [object description] ?: @"" };
    }
    NSError *error = nil;
    NSJSONWritingOptions options = pretty ? NSJSONWritingPrettyPrinted : 0;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:options error:&error];
    if (!data) {
        return nil;
    }
    return data;
}

NSString *IAGJSONEncodeString(id object)
{
    NSData *data = IAGJSONEncode(object, NO);
    if (!data) return @"null";
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return string ?: @"null";
}

id IAGJSONDecode(NSData *data, NSError **error)
{
    if (data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"iagent.json" code:1
                                     userInfo:@{ NSLocalizedDescriptionKey: @"empty body" }];
        }
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:data
                                           options:NSJSONReadingMutableContainers
                                             error:error];
}

id IAGJSONDecodeString(NSString *string, NSError **error)
{
    if (string.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"iagent.json" code:1
                                     userInfo:@{ NSLocalizedDescriptionKey: @"empty string" }];
        }
        return nil;
    }
    return IAGJSONDecode([string dataUsingEncoding:NSUTF8StringEncoding], error);
}

NSString *IAGJSONLiteral(NSString *string)
{
    if (string == nil) return @"null";
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[ string ] options:0 error:NULL];
    if (!data) return @"\"\"";
    NSString *array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (array.length < 2) return @"\"\"";
    return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}

NSString *IAGDictString(NSDictionary *dict, NSString *key, NSString *fallback)
{
    if (![dict isKindOfClass:[NSDictionary class]]) return fallback;
    id value = dict[key];
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return fallback;
}

NSString *IAGDictStringAny(NSDictionary *dict, NSArray<NSString *> *keys, NSString *fallback)
{
    for (NSString *key in keys) {
        NSString *value = IAGDictString(dict, key, nil);
        if (value.length) return value;
    }
    return fallback;
}

NSInteger IAGDictInteger(NSDictionary *dict, NSString *key, NSInteger fallback)
{
    if (![dict isKindOfClass:[NSDictionary class]]) return fallback;
    id value = dict[key];
    if ([value isKindOfClass:[NSNumber class]]) return [value integerValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSInteger parsed = [value integerValue];
        return parsed;
    }
    return fallback;
}

double IAGDictDouble(NSDictionary *dict, NSString *key, double fallback)
{
    if (![dict isKindOfClass:[NSDictionary class]]) return fallback;
    id value = dict[key];
    if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue];
    if ([value isKindOfClass:[NSString class]]) return [value doubleValue];
    return fallback;
}

BOOL IAGDictBool(NSDictionary *dict, NSString *key, BOOL fallback)
{
    if (![dict isKindOfClass:[NSDictionary class]]) return fallback;
    id value = dict[key];
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [value lowercaseString];
        if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"] ||
            [lower isEqualToString:@"1"] || [lower isEqualToString:@"on"]) {
            return YES;
        }
        if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"no"] ||
            [lower isEqualToString:@"0"] || [lower isEqualToString:@"off"]) {
            return NO;
        }
    }
    return fallback;
}

NSArray *IAGDictArray(NSDictionary *dict, NSString *key)
{
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    id value = dict[key];
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

NSDictionary *IAGDictDictionary(NSDictionary *dict, NSString *key)
{
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    id value = dict[key];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

NSString *IAGStringOrEmpty(id value)
{
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    if (value == nil || value == [NSNull null]) return @"";
    return [value description] ?: @"";
}

NSString *IAGTruncateString(NSString *string, NSUInteger maxLength)
{
    if (string.length <= maxLength) return string ?: @"";
    if (maxLength <= 32) return [string substringToIndex:maxLength];
    NSUInteger head = maxLength - 28;
    NSString *omitted = [NSString stringWithFormat:@"\n… [%lu 字符已截断] …\n",
                         (unsigned long)(string.length - maxLength)];
    return [NSString stringWithFormat:@"%@%@%@",
            [string substringToIndex:head], omitted,
            [string substringFromIndex:string.length - 20]];
}

NSDictionary *IAGErrorObject(NSString *message)
{
    return @{ @"error": message ?: @"unknown error" };
}

NSDictionary *IAGOkObject(void)
{
    return @{ @"ok": @YES };
}

id IAGJSONCoerce(id value)
{
    if (value == nil) return nil;
    if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *trimmed = [value stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) return nil;
        return IAGJSONDecodeString(trimmed, NULL);
    }
    return nil;
}
