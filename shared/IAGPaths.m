//
//  IAGPaths.m
//  iAgent
//

#import "IAGPaths.h"
#import "IAGVersion.h"

#import <sys/stat.h>
#import <sys/mount.h>    // struct statfs / statfs() 在 Darwin 上由 sys/mount.h 提供
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <dlfcn.h>
#import <pwd.h>
#import <unistd.h>
#import <time.h>

#pragma mark - tiny helpers

BOOL IAGPathExists(NSString *path)
{
    if (path.length == 0) return NO;
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0;
}

BOOL IAGPathIsDirectory(NSString *path)
{
    if (path.length == 0) return NO;
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) return NO;
    return S_ISDIR(st.st_mode);
}

BOOL IAGEnsureDirectory(NSString *path)
{
    if (path.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (IAGPathIsDirectory(path)) return YES;
    NSError *err = nil;
    if ([fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&err]) {
        return YES;
    }
    // A concurrent creator may have won the race.
    if (IAGPathIsDirectory(path)) return YES;
    return NO;
}

#pragma mark - jailbreak root detection

static NSString *gJailbreakRoot = nil;
static NSString *gRootfs = nil;
static dispatch_once_t gOnce;

// libroothide (RootHide / roothide Bootstrap) exports:
//     const char *jbroot(const char *path);
//     const char *rootfs(const char *path);
// Both take an absolute path and return a newly malloc'ed(ish) translated path.
// We only ever pass "/" and read the resulting prefix, and we copy the string
// immediately so a per-call allocation cannot leak into our object graph.
typedef const char *(*IAGPathTranslateFn)(const char *);
typedef const char *(*IAGRootPathFn)(void);

static NSString *IAGStringFromTranslator(IAGPathTranslateFn fn, const char *input)
{
    if (!fn) return nil;
    const char *out = fn(input);
    if (!out || !*out) return nil;
    NSString *s = [NSString stringWithUTF8String:out];
    return s.length ? s : nil;
}

/// Ask libroothide for the hidden jailbreak root. Returns nil when not present.
static NSString *IAGRootHideRoot(void)
{
    void *h = dlopen("libroothide.dylib", RTLD_NOW | RTLD_NOLOAD);
    if (!h) h = dlopen("/usr/lib/libroothide.dylib", RTLD_NOW);
    if (!h) h = dlopen("libroothide.dylib", RTLD_NOW);
    if (!h) return nil;

    // Preferred: JBROOT_PATH global (a C string), which is the documented way to
    // read the hidden root without calling into the translator.
    const char **rootPathSym = (const char **)dlsym(h, "JBROOT_PATH");
    if (rootPathSym && *rootPathSym && **rootPathSym) {
        NSString *s = [NSString stringWithUTF8String:*rootPathSym];
        if (s.length) return s;
    }

    IAGRootPathFn rootPathFn = (IAGRootPathFn)dlsym(h, "jbroot_path");
    if (rootPathFn) {
        const char *p = rootPathFn();
        if (p && *p) {
            NSString *s = [NSString stringWithUTF8String:p];
            if (s.length) return s;
        }
    }

    IAGPathTranslateFn jbrootFn = (IAGPathTranslateFn)dlsym(h, "jbroot");
    NSString *translated = IAGStringFromTranslator(jbrootFn, "/");
    if (translated.length && ![translated isEqualToString:@"/"]) {
        // A trailing slash is not useful for path joining.
        if (translated.length > 1 && [translated hasSuffix:@"/"]) {
            translated = [translated substringToIndex:translated.length - 1];
        }
        return translated;
    }
    return nil;
}

static NSString *IAGRootfsRoot(void)
{
    void *h = dlopen("libroothide.dylib", RTLD_NOW | RTLD_NOLOAD);
    if (!h) h = dlopen("/usr/lib/libroothide.dylib", RTLD_NOW);
    if (h) {
        IAGPathTranslateFn rootfsFn = (IAGPathTranslateFn)dlsym(h, "rootfs");
        NSString *translated = IAGStringFromTranslator(rootfsFn, "/");
        if (translated.length) return translated;
    }
    return @"/";
}

/// Derive "<root>" from "<root>/usr/bin/iagentd" style paths.
static NSString *IAGJailbreakRootFromExecutable(NSString *executablePath)
{
    if (executablePath.length == 0) return nil;
    NSArray<NSString *> *comps = [executablePath pathComponents];
    NSUInteger idx = [comps indexOfObject:@"usr"];
    if (idx == NSNotFound || idx == 0) return nil;
    NSArray<NSString *> *prefix = [comps subarrayWithRange:NSMakeRange(0, idx)];
    NSString *root = [NSString pathWithComponents:prefix];
    if ([root isEqualToString:@"/"] || root.length == 0) return nil;
    // Sanity check: a real jailbreak root has a usr/lib directory.
    if (!IAGPathIsDirectory([root stringByAppendingPathComponent:@"usr/lib"])) return nil;
    return root;
}

static void IAGDetectPathsOnce(void)
{
    gRootfs = IAGRootfsRoot() ?: @"/";
    if (![gRootfs isEqualToString:@"/"] && [gRootfs hasSuffix:@"/"]) {
        gRootfs = [gRootfs substringToIndex:gRootfs.length - 1];
    }

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    // 1. Environment override (handy for debugging and for the tweak, which is
    //    loaded by a process we do not control).
    NSString *envRoot = NSProcessInfo.processInfo.environment[@"IAG_JBROOT"];
    if (envRoot.length) [candidates addObject:envRoot];

    // 2. libroothide — the only reliable answer on RootHide.
    NSString *roothideRoot = IAGRootHideRoot();
    if (roothideRoot.length) [candidates addObject:roothideRoot];

    // 3. Our own executable path (exact for the daemon).
    NSString *fromExe = IAGJailbreakRootFromExecutable(NSBundle.mainBundle.executablePath);
    if (fromExe.length) [candidates addObject:fromExe];

    // 4. The conventional rootless prefix.
    [candidates addObject:@"/var/jb"];

    for (NSString *cand in candidates) {
        if (IAGPathIsDirectory([cand stringByAppendingPathComponent:@"usr/lib"]) ||
            IAGPathIsDirectory([cand stringByAppendingPathComponent:@"Library"])) {
            gJailbreakRoot = cand;
            return;
        }
    }

    // Rootful, or nothing we recognise.
    gJailbreakRoot = @"/";
}

NSString *IAGJailbreakRoot(void)
{
    dispatch_once(&gOnce, ^{ IAGDetectPathsOnce(); });
    return gJailbreakRoot;
}

NSString *IAGRootfs(void)
{
    dispatch_once(&gOnce, ^{ IAGDetectPathsOnce(); });
    return gRootfs;
}

BOOL IAGIsRootless(void)
{
    return ![IAGJailbreakRoot() isEqualToString:@"/"];
}

NSArray<NSString *> *IAGCandidatePaths(NSString *rootlessAbsolutePath)
{
    if (rootlessAbsolutePath.length == 0) return @[];
    if (![rootlessAbsolutePath hasPrefix:@"/"]) {
        rootlessAbsolutePath = [@"/" stringByAppendingString:rootlessAbsolutePath];
    }
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    void (^add)(NSString *) = ^(NSString *root) {
        if (root.length == 0) return;
        NSString *full;
        if ([root isEqualToString:@"/"]) {
            full = rootlessAbsolutePath;
        } else {
            full = [root stringByAppendingString:rootlessAbsolutePath];
        }
        if (![out containsObject:full]) [out addObject:full];
    };

    NSString *jb = IAGJailbreakRoot();
    if (jb.length && ![jb isEqualToString:@"/"]) add(jb);
    add(@"/var/jb");
    add(@"/");

    return out;
}

NSString *IAGResolveRootlessPath(NSString *rootlessAbsolutePath)
{
    NSArray<NSString *> *candidates = IAGCandidatePaths(rootlessAbsolutePath);
    for (NSString *cand in candidates) {
        if (IAGPathExists(cand)) return cand;
    }
    return candidates.firstObject ?: rootlessAbsolutePath;
}

#pragma mark - user data (always on the rootfs)

static NSString *gDataDir = nil;

NSString *IAGDataDir(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *preferred = @"/var/mobile/Library/iAgent";
        // Root daemons may want their own home; keep the shared location as long
        // as it is reachable, otherwise fall back to this process' home.
        if (IAGEnsureDirectory(preferred)) {
            gDataDir = preferred;
            return;
        }
        NSString *alt = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/iAgent"];
        IAGEnsureDirectory(alt);
        gDataDir = alt;
    });
    return gDataDir;
}

NSString *IAGConfigPath(void)   { return [IAGDataDir() stringByAppendingPathComponent:@"config.plist"]; }
NSString *IAGStatePath(void)    { return [IAGDataDir() stringByAppendingPathComponent:@"state.plist"]; }
NSString *IAGSessionsDir(void)  { return [IAGDataDir() stringByAppendingPathComponent:@"sessions"]; }
NSString *IAGCronPath(void)     { return [IAGDataDir() stringByAppendingPathComponent:@"cron.plist"]; }
NSString *IAGApprovalsDir(void) { return [IAGDataDir() stringByAppendingPathComponent:@"approvals"]; }
NSString *IAGEventsPath(void)   { return [IAGDataDir() stringByAppendingPathComponent:@"events.jsonl"]; }

NSString *IAGSessionPath(NSString *sessionId)
{
    NSString *safe = [[sessionId ?: @"" componentsSeparatedByCharactersInSet:
                       [[NSCharacterSet alphanumericCharacterSet] invertedSet]]
                      componentsJoinedByString:@"_"];
    if (safe.length == 0) safe = @"default";
    return [IAGSessionsDir() stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"json"]];
}

NSString *IAGLogDir(void)
{
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [IAGDataDir() stringByAppendingPathComponent:@"logs"];
        IAGEnsureDirectory(dir);
    });
    return dir;
}

NSString *IAGLogPath(void) { return [IAGLogDir() stringByAppendingPathComponent:@"iagent.log"]; }

#pragma mark - web resources (inside the jailbreak root)

NSString *IAGWebRoot(void)
{
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];

        // Relative to the running executable: <jb>/usr/bin/iagentd -> <jb>/usr/share/iagent/web
        NSString *exe = NSBundle.mainBundle.executablePath;
        if (exe.length) {
            NSString *prefix = IAGJailbreakRootFromExecutable(exe);
            if (prefix.length) {
                [candidates addObject:[prefix stringByAppendingPathComponent:@"usr/share/iagent/web"]];
            }
            // Also accept a development layout: <dir>/../share/iagent/web
            NSString *binDir = [exe stringByDeletingLastPathComponent];
            [candidates addObject:[[binDir stringByDeletingLastPathComponent]
                                   stringByAppendingPathComponent:@"share/iagent/web"]];
        }

        NSString *jb = IAGJailbreakRoot();
        if (jb.length && ![jb isEqualToString:@"/"]) {
            [candidates addObject:[jb stringByAppendingPathComponent:@"usr/share/iagent/web"]];
        }
        [candidates addObject:@"/var/jb/usr/share/iagent/web"];
        [candidates addObject:@"/usr/share/iagent/web"];

        for (NSString *cand in candidates) {
            if (IAGPathExists([cand stringByAppendingPathComponent:@"index.html"])) {
                root = cand;
                return;
            }
        }
        root = candidates.firstObject ?: @"/usr/share/iagent/web";
    });
    return root;
}

#pragma mark - device identity

NSString *IAGDeviceModelIdentifier(void)
{
    static NSString *model = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct utsname u;
        if (uname(&u) == 0) {
            model = [NSString stringWithUTF8String:u.machine];
        }
        if (model.length == 0) model = @"unknown";
    });
    return model;
}

NSString *IAGDeviceModelName(void)
{
    static NSDictionary<NSString *, NSString *> *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            @"iPhone12,1": @"iPhone 11",        @"iPhone12,3": @"iPhone 11 Pro",
            @"iPhone12,5": @"iPhone 11 Pro Max",@"iPhone12,8": @"iPhone SE (2nd)",
            @"iPhone13,1": @"iPhone 12 mini",   @"iPhone13,2": @"iPhone 12",
            @"iPhone13,3": @"iPhone 12 Pro",    @"iPhone13,4": @"iPhone 12 Pro Max",
            @"iPhone14,2": @"iPhone 13 Pro",    @"iPhone14,3": @"iPhone 13 Pro Max",
            @"iPhone14,4": @"iPhone 13 mini",   @"iPhone14,5": @"iPhone 13",
            @"iPhone14,6": @"iPhone SE (3rd)",  @"iPhone14,7": @"iPhone 14",
            @"iPhone14,8": @"iPhone 14 Plus",   @"iPhone15,2": @"iPhone 14 Pro",
            @"iPhone15,3": @"iPhone 14 Pro Max",@"iPhone15,4": @"iPhone 15",
            @"iPhone15,5": @"iPhone 15 Plus",   @"iPhone16,1": @"iPhone 15 Pro",
            @"iPhone16,2": @"iPhone 15 Pro Max",
            @"iPad13,1": @"iPad Air (4th)",     @"iPad13,2": @"iPad Air (4th)",
            @"iPad13,4": @"iPad Pro 11 (3rd)",  @"iPad13,8": @"iPad Pro 12.9 (5th)",
            @"iPad14,1": @"iPad mini (6th)",    @"iPad14,3": @"iPad Pro 11 (4th)",
        };
    });
    NSString *identifier = IAGDeviceModelIdentifier();
    return names[identifier] ?: identifier;
}

NSString *IAGSystemVersion(void)
{
    static NSString *version = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
        version = [NSString stringWithFormat:@"%ld.%ld.%ld",
                   (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
    });
    return version;
}

NSString *IAGDeviceName(void)
{
    static NSString *name = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
                               @"/var/mobile/Library/Preferences/.GlobalPreferences.plist"];
        id value = prefs[@"DeviceName"];
        if ([value isKindOfClass:[NSString class]] && [value length]) {
            name = value;
        }
    });
    return name;
}

NSString *IAGBootUUID(void)
{
    static NSString *uuid = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char buf[128] = {0};
        size_t len = sizeof(buf) - 1;
        if (sysctlbyname("kern.bootsessionuuid", buf, &len, NULL, 0) == 0) {
            uuid = [NSString stringWithUTF8String:buf];
        }
        if (uuid.length == 0) uuid = @"unknown";
    });
    return uuid;
}

#pragma mark - process facts

static NSTimeInterval gProcessStart = 0;

__attribute__((constructor)) static void IAGPathsInit(void)
{
    gProcessStart = [NSDate date].timeIntervalSince1970;
}

BOOL IAGIsRoot(void) { return geteuid() == 0; }

NSString *IAGUserName(void)
{
    struct passwd *pw = getpwuid(geteuid());
    if (pw && pw->pw_name) return [NSString stringWithUTF8String:pw->pw_name];
    return IAGIsRoot() ? @"root" : @"mobile";
}

long long IAGFreeDiskSpace(void)
{
    struct statfs fs;
    if (statfs("/var/mobile", &fs) != 0) {
        if (statfs("/", &fs) != 0) return -1;
    }
    return (long long)fs.f_bavail * (long long)fs.f_bsize;
}

NSString *IAGProcessUptime(void)
{
    long long secs = (long long)([NSDate date].timeIntervalSince1970 - gProcessStart);
    if (secs < 0) secs = 0;
    return [NSString stringWithFormat:@"%02lld:%02lld:%02lld",
            secs / 3600, (secs % 3600) / 60, secs % 60];
}
