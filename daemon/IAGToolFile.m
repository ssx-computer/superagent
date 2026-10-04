//
//  IAGToolFile.m
//  iAgent
//
//  File tools: fs_read / fs_write / fs_list / fs_search / fs_delete.
//  Implemented with Foundation + POSIX directly (no dependence on busybox
//  flags, which differ between iOS builds).
//

#import "IAGTool.h"
#import "IAGConfig.h"
#import "IAGPaths.h"
#import "IAGUtil.h"
#import "IAGJSON.h"
#import "IAGLog.h"

#import <sys/stat.h>
#import <dirent.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

#pragma mark - helpers

/// Expand ~, $IAG_JBROOT and relative paths into an absolute on-disk path.
static NSString *IAGExpandPath(NSString *path, IAGConfig *config)
{
    if (path.length == 0) return @"";

    NSString *result = path;
    if ([result hasPrefix:@"~/"]) {
        result = [NSHomeDirectory() stringByAppendingString:[result substringFromIndex:1]];
    } else if ([result isEqualToString:@"~"]) {
        result = NSHomeDirectory();
    }

    if ([result containsString:@"$IAG_JBROOT"]) {
        result = [result stringByReplacingOccurrencesOfString:@"$IAG_JBROOT"
                                                   withString:IAGJailbreakRoot()];
    }
    if ([result containsString:@"${IAG_JBROOT}"]) {
        result = [result stringByReplacingOccurrencesOfString:@"${IAG_JBROOT}"
                                                   withString:IAGJailbreakRoot()];
    }

    if (![result hasPrefix:@"/"]) {
        NSString *base = [config workDir];
        if (base.length == 0) base = @"/var/mobile";
        result = [base stringByAppendingPathComponent:result];
    }

    return [result stringByStandardizingPath];
}

/// Paths the agent must never delete, no matter what the model asks for.
static BOOL IAGPathIsProtectedFromDelete(NSString *path)
{
    NSString *normalized = [path stringByStandardizingPath];
    while (normalized.length > 1 && [normalized hasSuffix:@"/"]) {
        normalized = [normalized substringToIndex:normalized.length - 1];
    }

    NSArray<NSString *> *exact = @[
        @"/", @"/var", @"/System", @"/private", @"/Applications", @"/usr", @"/bin", @"/sbin",
        @"/etc", @"/Library", @"/var/jb", @"/var/mobile", @"/var/containers", @"/var/root",
        @"/private/var", @"/private/var/db", @"/private/var/lib", @"/private/etc",
        @"/var/jb/Library", @"/var/jb/usr", @"/var/jb/usr/lib", @"/var/jb/Library/dpkg",
        @"/var/jb/Applications", @"/var/jb/Library/MobileSubstrate",
    ];
    if ([exact containsObject:normalized]) return YES;

    NSArray<NSString *> *prefixes = @[
        @"/private/var/db/", @"/var/jb/Library/dpkg/", @"/private/etc/",
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/",
    ];
    for (NSString *prefix in prefixes) {
        if ([normalized hasPrefix:prefix]) return YES;
    }

    // RootHide 没有 /var/jb：真实 jbroot 是
    // /var/containers/Bundle/Application/.jbroot-<hex>。上面那批字面量都匹配不上，
    // 所以再按真实的越狱根目录判一次，否则 RootHide 上这些关键目录可被删除。
    NSString *jbroot = [IAGJailbreakRoot() stringByStandardizingPath];
    if (jbroot.length > 1 && ![jbroot isEqualToString:@"/"]) {
        while (jbroot.length > 1 && [jbroot hasSuffix:@"/"]) {
            jbroot = [jbroot substringToIndex:jbroot.length - 1];
        }
        for (NSString *sub in @[@"Library", @"usr", @"usr/lib", @"Applications",
                                @"Library/dpkg", @"Library/MobileSubstrate"]) {
            if ([normalized isEqualToString:[jbroot stringByAppendingPathComponent:sub]]) return YES;
        }
        for (NSString *sub in @[@"Library/dpkg/", @"Library/MobileSubstrate/DynamicLibraries/"]) {
            // 用格式串拼接以保留结尾的 "/"，避免把 <jbroot>/Library/dpkgfoo 也误判成受保护。
            if ([normalized hasPrefix:[jbroot stringByAppendingFormat:@"/%@", sub]]) return YES;
        }
    }
    return NO;
}

static NSString *IAGDescribeEntry(NSString *name, const struct stat *st)
{
    char kind = '?';
    if (S_ISDIR(st->st_mode)) kind = 'd';
    else if (S_ISLNK(st->st_mode)) kind = 'l';
    else if (S_ISREG(st->st_mode)) kind = '-';
    else if (S_ISCHR(st->st_mode)) kind = 'c';
    else if (S_ISBLK(st->st_mode)) kind = 'b';
    else if (S_ISFIFO(st->st_mode)) kind = 'p';
    else if (S_ISSOCK(st->st_mode)) kind = 's';

    char mode[11];
    mode[0] = kind;
    const char symbols[9] = { 'r','w','x','r','w','x','r','w','x' };
    for (int i = 0; i < 9; i++) {
        mode[i + 1] = (st->st_mode & (1 << (8 - i))) ? symbols[i] : '-';
    }
    mode[10] = '\0';

    char timeBuffer[32];
    struct tm timeInfo;
    localtime_r(&st->st_mtime, &timeInfo);
    strftime(timeBuffer, sizeof(timeBuffer), "%Y-%m-%d %H:%M", &timeInfo);

    NSString *size = S_ISDIR(st->st_mode) ? @"-" : IAGFormatBytes(st->st_size);
    NSString *stamp = [NSString stringWithUTF8String:timeBuffer] ?: @"";
    return [NSString stringWithFormat:@"%s %10s %@ %@", mode, size.UTF8String, stamp, name];
}

static BOOL IAGDataLooksBinary(NSData *data)
{
    NSUInteger check = MIN(data.length, (NSUInteger)8000);
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < check; i++) {
        if (bytes[i] == 0x00) return YES;
    }
    return NO;
}

#pragma mark - fs_read

@interface IAGToolFileRead : NSObject <IAGTool>
@end

@implementation IAGToolFileRead

+ (NSString *)toolName { return @"fs_read"; }

+ (NSString *)toolDescription
{
    return @"读取一个文件的内容（文本）。默认最多读取 256KB，可用 offset_bytes/max_bytes 分段读取大文件。"
            "二进制文件不会被读取，只返回元信息。路径支持 ~ 与 $IAG_JBROOT。";
}

+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"path": @{ @"type": @"string", @"description": @"文件路径（绝对路径，或相对工作目录）" },
            @"offset_bytes": @{ @"type": @"integer", @"description": @"起始字节偏移，默认 0" },
            @"max_bytes": @{ @"type": @"integer", @"description": @"最多读取字节数，默认 262144" },
        },
        @"required": @[ @"path" ],
    };
}

+ (NSString *)category { return @"file"; }
+ (BOOL)isDangerous { return NO; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *path = IAGExpandPath(IAGDictString(arguments, @"path", @""), context.config);
    if (path.length == 0) return IAGToolFailure(@"缺少 path 参数");

    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) {
        return IAGToolFailure([NSString stringWithFormat:@"文件不存在或无法访问: %@ (%s)", path, strerror(errno)]);
    }
    if (S_ISDIR(st.st_mode)) {
        return IAGToolFailure([NSString stringWithFormat:@"%@ 是目录，请使用 fs_list", path]);
    }

    NSInteger offset = IAGDictInteger(arguments, @"offset_bytes", 0);
    if (offset < 0) offset = 0;
    NSInteger maxBytes = IAGDictInteger(arguments, @"max_bytes", 262144);
    if (maxBytes < 1) maxBytes = 262144;
    if (maxBytes > 8 * 1024 * 1024) maxBytes = 8 * 1024 * 1024;

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return IAGToolFailure([NSString stringWithFormat:@"无法打开文件: %@", path]);

    NSData *data = nil;
    @try {
        if (offset > 0) [handle seekToFileOffset:(unsigned long long)offset];
        data = [handle readDataOfLength:(NSUInteger)maxBytes];
    } @catch (NSException *exception) {
        [handle closeFile];
        return IAGToolFailure([NSString stringWithFormat:@"读取失败: %@", exception.reason]);
    }
    [handle closeFile];

    NSMutableString *output = [NSMutableString string];
    [output appendFormat:@"path: %@\n", path];
    [output appendFormat:@"size: %lld bytes\n", (long long)st.st_size];
    [output appendFormat:@"mode: %o  uid: %u  gid: %u\n", st.st_mode & 07777, st.st_uid, st.st_gid];
    [output appendFormat:@"mtime: %@\n", [NSDateFormatter localizedStringFromDate:
                                          [NSDate dateWithTimeIntervalSince1970:st.st_mtime]
                                                                      dateStyle:NSDateFormatterMediumStyle
                                                                      timeStyle:NSDateFormatterMediumStyle]];

    if (IAGDataLooksBinary(data)) {
        [output appendFormat:@"\n(二进制文件，已跳过内容，返回前 %lu 字节的十六进制摘要)\n", (unsigned long)MIN(data.length, (NSUInteger)128)];
        NSMutableString *hex = [NSMutableString string];
        const uint8_t *bytes = data.bytes;
        NSUInteger count = MIN(data.length, (NSUInteger)128);
        for (NSUInteger i = 0; i < count; i++) {
            [hex appendFormat:@"%02x ", bytes[i]];
            if ((i + 1) % 16 == 0) [hex appendString:@"\n"];
        }
        [output appendString:hex];
        return IAGToolSuccess(output);
    }

    NSUInteger consumed = 0;
    NSString *text = IAGStringFromUTF8Lossy(data, &consumed);
    [output appendFormat:@"read: %lu bytes%@\n", (unsigned long)consumed,
                        (offset + (NSInteger)consumed < st.st_size) ? @" (文件未读完)" : @""];
    [output appendFormat:@"\n--- content ---\n%@", text];

    return IAGToolSuccess(IAGTruncateForModel(output, 24000));
}

@end

#pragma mark - fs_write

@interface IAGToolFileWrite : NSObject <IAGTool>
@end

@implementation IAGToolFileWrite

+ (NSString *)toolName { return @"fs_write"; }

+ (NSString *)toolDescription
{
    return @"写入文本到文件（默认覆盖，append=true 则追加）。默认自动创建父目录，写入后会把权限设为 0644。"
            "覆盖不可恢复：修改系统文件前请先用 fs_read 确认现有内容。返回写入字节数、文件大小与路径。";
}

+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"path": @{ @"type": @"string", @"description": @"目标文件路径" },
            @"content": @{ @"type": @"string", @"description": @"要写入的文本内容" },
            @"append": @{ @"type": @"boolean", @"description": @"true 表示追加，默认 false（覆盖）" },
            @"create_dirs": @{ @"type": @"boolean", @"description": @"是否自动创建父目录，默认 true" },
        },
        @"required": @[ @"path", @"content" ],
    };
}

+ (NSString *)category { return @"file"; }
+ (BOOL)isDangerous { return YES; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *path = IAGExpandPath(IAGDictString(arguments, @"path", @""), context.config);
    if (path.length == 0) return IAGToolFailure(@"缺少 path 参数");

    id contentValue = arguments[@"content"];
    if (contentValue == nil) return IAGToolFailure(@"缺少 content 参数");
    NSString *content = IAGStringOrEmpty(contentValue);

    BOOL append = IAGDictBool(arguments, @"append", NO);
    BOOL createDirs = IAGDictBool(arguments, @"create_dirs", YES);

    if (IAGPathIsDirectory(path)) {
        return IAGToolFailure([NSString stringWithFormat:@"%@ 是目录", path]);
    }

    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *parent = [path stringByDeletingLastPathComponent];
    if (createDirs && parent.length && ![manager fileExistsAtPath:parent]) {
        NSError *error = nil;
        if (![manager createDirectoryAtPath:parent withIntermediateDirectories:YES
                                 attributes:nil error:&error]) {
            return IAGToolFailure([NSString stringWithFormat:@"无法创建目录 %@: %@",
                                   parent, error.localizedDescription]);
        }
    }

    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSError *writeError = nil;
    BOOL existed = [manager fileExistsAtPath:path];
    unsigned long long previousSize = 0;
    if (existed) {
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];
        previousSize = [attributes[NSFileSize] unsignedLongLongValue];
    }

    if (append) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) {
            if (![manager createFileAtPath:path contents:data attributes:nil]) {
                return IAGToolFailure([NSString stringWithFormat:@"无法创建文件: %@", path]);
            }
        } else {
            @try {
                [handle seekToEndOfFile];
                [handle writeData:data];
            } @catch (NSException *exception) {
                [handle closeFile];
                return IAGToolFailure([NSString stringWithFormat:@"追加失败: %@", exception.reason]);
            }
            [handle closeFile];
        }
    } else {
        if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
            return IAGToolFailure([NSString stringWithFormat:@"写入失败: %@",
                                   writeError.localizedDescription ?: @"unknown"]);
        }
    }

    // Make sure the mobile user can read files written by a root daemon.
    chmod(path.fileSystemRepresentation, 0644);

    NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];
    unsigned long long finalSize = [attributes[NSFileSize] unsignedLongLongValue];

    return IAGToolSuccess([NSString stringWithFormat:
        @"ok: %@\npath: %@\nbytes_written: %lu\nfile_size: %llu%@",
        append ? @"追加" : @"覆盖", path, (unsigned long)data.length, finalSize,
        existed ? [NSString stringWithFormat:@"\nprevious_size: %llu", previousSize] : @"\ncreated: true"]);
}

@end

#pragma mark - fs_list

@interface IAGToolFileList : NSObject <IAGTool>
@end

@implementation IAGToolFileList

+ (NSString *)toolName { return @"fs_list"; }

+ (NSString *)toolDescription
{
    return @"列出一个目录的内容（不递归），返回类型、权限、大小、修改时间。默认包含隐藏文件。";
}

+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"path": @{ @"type": @"string", @"description": @"目录路径，默认工作目录" },
            @"show_hidden": @{ @"type": @"boolean", @"description": @"是否显示隐藏文件，默认 true" },
            @"max_entries": @{ @"type": @"integer", @"description": @"最多返回条目数，默认 300" },
        },
    };
}

+ (NSString *)category { return @"file"; }
+ (BOOL)isDangerous { return NO; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *path = IAGDictString(arguments, @"path", @"");
    path = path.length ? IAGExpandPath(path, context.config) : [context.config workDir];
    if (!IAGPathIsDirectory(path)) {
        return IAGToolFailure([NSString stringWithFormat:@"目录不存在: %@", path]);
    }

    BOOL showHidden = IAGDictBool(arguments, @"show_hidden", YES);
    NSInteger maxEntries = IAGDictInteger(arguments, @"max_entries", 300);
    if (maxEntries < 1) maxEntries = 300;
    if (maxEntries > 5000) maxEntries = 5000;

    NSFileManager *manager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:path error:&error];
    if (!names) {
        // contentsOfDirectoryAtPath follows the sandbox; fall back to readdir.
        NSMutableArray<NSString *> *fallback = [NSMutableArray array];
        DIR *directory = opendir(path.fileSystemRepresentation);
        if (directory) {
            struct dirent *entry = NULL;
            while ((entry = readdir(directory)) != NULL) {
                NSString *name = [NSString stringWithUTF8String:entry->d_name];
                if (name.length) [fallback addObject:name];
            }
            closedir(directory);
        }
        if (fallback.count == 0) {
            return IAGToolFailure([NSString stringWithFormat:@"无法列出目录 %@: %@",
                                   path, error.localizedDescription ?: @"permission denied"]);
        }
        names = fallback;
    }

    NSMutableArray<NSString *> *directories = [NSMutableArray array];
    NSMutableArray<NSString *> *files = [NSMutableArray array];

    for (NSString *name in names) {
        if (!showHidden && [name hasPrefix:@"."]) continue;
        NSString *full = [path stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(full.fileSystemRepresentation, &st) != 0) continue;
        NSString *line = IAGDescribeEntry(name, &st);
        if (S_ISDIR(st.st_mode)) [directories addObject:line];
        else [files addObject:line];
    }

    [directories sortUsingSelector:@selector(compare:)];
    [files sortUsingSelector:@selector(compare:)];

    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithArray:directories];
    [all addObjectsFromArray:files];

    NSMutableString *output = [NSMutableString string];
    [output appendFormat:@"path: %@\n", path];
    [output appendFormat:@"entries: %lu (目录 %lu, 文件 %lu)%@\n\n",
        (unsigned long)all.count, (unsigned long)directories.count, (unsigned long)files.count,
        all.count > (NSUInteger)maxEntries ? @" [已截断]" : @""];

    NSUInteger limit = MIN(all.count, (NSUInteger)maxEntries);
    for (NSUInteger i = 0; i < limit; i++) {
        [output appendFormat:@"%@\n", all[i]];
    }

    return IAGToolSuccess(output);
}

@end

#pragma mark - fs_search

@interface IAGToolFileSearch : NSObject <IAGTool>
@end

@implementation IAGToolFileSearch

+ (NSString *)toolName { return @"fs_search"; }

+ (NSString *)toolDescription
{
    return @"在目录树中按正则搜索文本内容（类似 grep -rn），或按文件名通配符查找文件。"
            "默认忽略二进制文件与大于 4MB 的文件，跳过符号链接。返回 文件:行号: 内容。";
}

+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"path": @{ @"type": @"string", @"description": @"搜索起始目录，默认工作目录" },
            @"pattern": @{ @"type": @"string", @"description": @"正则表达式；留空则只按文件名匹配" },
            @"file_glob": @{ @"type": @"string", @"description": @"文件名通配符，如 *.plist 或 *.log" },
            @"case_sensitive": @{ @"type": @"boolean", @"description": @"是否区分大小写，默认 false" },
            @"max_results": @{ @"type": @"integer", @"description": @"最多返回匹配行数，默认 80" },
            @"max_files": @{ @"type": @"integer", @"description": @"最多扫描文件数，默认 3000" },
        },
    };
}

+ (NSString *)category { return @"file"; }
+ (BOOL)isDangerous { return NO; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *path = IAGDictString(arguments, @"path", @"");
    path = path.length ? IAGExpandPath(path, context.config) : [context.config workDir];
    NSString *pattern = IAGDictString(arguments, @"pattern", @"");
    NSString *fileGlob = IAGDictString(arguments, @"file_glob", @"");
    BOOL caseSensitive = IAGDictBool(arguments, @"case_sensitive", NO);
    NSInteger maxResults = IAGDictInteger(arguments, @"max_results", 80);
    NSInteger maxFiles = IAGDictInteger(arguments, @"max_files", 3000);
    if (maxResults < 1) maxResults = 80;
    if (maxFiles < 1) maxFiles = 3000;

    if (pattern.length == 0 && fileGlob.length == 0) {
        return IAGToolFailure(@"请至少提供 pattern 或 file_glob 之一");
    }
    if (!IAGPathIsDirectory(path)) {
        return IAGToolFailure([NSString stringWithFormat:@"目录不存在: %@", path]);
    }

    NSRegularExpression *regex = nil;
    if (pattern.length) {
        NSError *regexError = nil;
        regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                          options:caseSensitive ? 0 : NSRegularExpressionCaseInsensitive
                                                            error:&regexError];
        if (!regex) {
            return IAGToolFailure([NSString stringWithFormat:@"正则表达式无效: %@",
                                   regexError.localizedDescription]);
        }
    }

    NSMutableString *output = [NSMutableString string];
    [output appendFormat:@"path: %@\n", path];
    if (pattern.length) [output appendFormat:@"pattern: %@\n", pattern];
    if (fileGlob.length) [output appendFormat:@"file_glob: %@\n", fileGlob];
    [output appendString:@"\n"];

    __block NSInteger matches = 0;
    __block NSInteger scanned = 0;
    __block NSInteger visitedDirs = 0;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSFileManager *manager = [NSFileManager defaultManager];

    // A bounded, iterative (non-recursive) walk so deep trees cannot blow the stack.
    NSMutableArray<NSString *> *pending = [NSMutableArray arrayWithObject:path];
    while (pending.count > 0 && matches < maxResults && scanned < maxFiles) {
        NSString *directory = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visitedDirs++;

        NSError *listError = nil;
        NSArray<NSString *> *entries = [manager contentsOfDirectoryAtPath:directory error:&listError];
        if (!entries) continue;

        for (NSString *name in entries) {
            if (matches >= maxResults || scanned >= maxFiles) break;
            NSString *full = [directory stringByAppendingPathComponent:name];

            struct stat st;
            if (lstat(full.fileSystemRepresentation, &st) != 0) continue;
            if (S_ISLNK(st.st_mode)) continue;

            if (S_ISDIR(st.st_mode)) {
                [pending addObject:full];
                continue;
            }
            if (!S_ISREG(st.st_mode)) continue;
            if (st.st_size > 4 * 1024 * 1024) continue;

            BOOL nameMatches = YES;
            if (fileGlob.length) {
                NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF LIKE %@", fileGlob];
                nameMatches = [predicate evaluateWithObject:name];
                if (!nameMatches) continue;
            }

            scanned++;

            if (!regex) {
                [lines addObject:[NSString stringWithFormat:@"%@", full]];
                matches++;
                continue;
            }

            NSData *data = [NSData dataWithContentsOfFile:full options:NSDataReadingMappedIfSafe error:NULL];
            if (!data || data.length == 0) continue;
            if (IAGDataLooksBinary(data)) continue;

            NSUInteger consumed = 0;
            NSString *text = IAGStringFromUTF8Lossy(data, &consumed);
            if (text.length == 0) continue;

            NSArray<NSString *> *textLines = [text componentsSeparatedByString:@"\n"];
            for (NSUInteger i = 0; i < textLines.count && matches < maxResults; i++) {
                NSString *line = textLines[i];
                if (line.length == 0) continue;
                NSRange searchRange = NSMakeRange(0, line.length);
                if ([regex firstMatchInString:line options:0 range:searchRange]) {
                    NSString *trimmed = line.length > 400 ? [line substringToIndex:400] : line;
                    [lines addObject:[NSString stringWithFormat:@"%@:%lu: %@",
                                      full, (unsigned long)(i + 1),
                                      [trimmed stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceCharacterSet]]]];
                    matches++;
                }
            }
        }
    }

    if (lines.count == 0) {
        [output appendString:@"(没有匹配)"];
    } else {
        for (NSString *line in lines) [output appendFormat:@"%@\n", line];
    }
    [output appendFormat:@"\n已扫描 %ld 个文件 / %ld 个目录，匹配 %ld 处%@",
        (long)scanned, (long)visitedDirs, (long)matches,
        (matches >= maxResults) ? @"（达到上限，可能还有更多）" : @""];

    return IAGToolSuccess(IAGTruncateForModel(output, 24000));
}

@end

#pragma mark - fs_delete

@interface IAGToolFileDelete : NSObject <IAGTool>
@end

@implementation IAGToolFileDelete

+ (NSString *)toolName { return @"fs_delete"; }

+ (NSString *)toolDescription
{
    return @"删除文件或目录。删除目录必须显式设置 recursive=true。系统关键路径（/、/System、/var、"
            "/var/jb/Library 等）被硬性禁止，无法删除。";
}

+ (NSDictionary *)parametersSchema
{
    return @{
        @"type": @"object",
        @"properties": @{
            @"path": @{ @"type": @"string", @"description": @"要删除的路径" },
            @"recursive": @{ @"type": @"boolean", @"description": @"删除目录时需要设置为 true" },
        },
        @"required": @[ @"path" ],
    };
}

+ (NSString *)category { return @"file"; }
+ (BOOL)isDangerous { return YES; }

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments context:(IAGToolContext *)context
{
    NSString *path = IAGExpandPath(IAGDictString(arguments, @"path", @""), context.config);
    if (path.length == 0) return IAGToolFailure(@"缺少 path 参数");

    if (IAGPathIsProtectedFromDelete(path)) {
        return IAGToolFailure([NSString stringWithFormat:
            @"拒绝删除受保护路径 %@（该路径在硬性保护名单中）", path]);
    }
    if (!IAGPathExists(path)) {
        return IAGToolFailure([NSString stringWithFormat:@"路径不存在: %@", path]);
    }

    BOOL recursive = IAGDictBool(arguments, @"recursive", NO);
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode) && !recursive) {
        return IAGToolFailure([NSString stringWithFormat:
            @"%@ 是目录；如确认要整个删除，请设置 recursive=true", path]);
    }

    NSError *error = nil;
    if (![[NSFileManager defaultManager] removeItemAtPath:path error:&error]) {
        return IAGToolFailure([NSString stringWithFormat:@"删除失败: %@", error.localizedDescription]);
    }

    return IAGToolSuccess([NSString stringWithFormat:@"已删除: %@%@", path,
                           recursive ? @" (递归)" : @""]);
}

@end

#pragma mark - registration

void IAGRegisterFileTools(IAGToolRegistry *registry)
{
    [registry registerToolClass:[IAGToolFileRead class]];
    [registry registerToolClass:[IAGToolFileWrite class]];
    [registry registerToolClass:[IAGToolFileList class]];
    [registry registerToolClass:[IAGToolFileSearch class]];
    [registry registerToolClass:[IAGToolFileDelete class]];
}
