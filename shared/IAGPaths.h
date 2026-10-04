//
//  IAGPaths.h
//  iAgent
//
//  Runtime path resolution that works on every modern jailbreak flavour:
//
//    * rootless (Dopamine, palera1n rootless, unc0ver rootless) -> /var/jb
//    * RootHide / roothide Bootstrap -> a randomised, hidden jailbreak root
//      that must be resolved through libroothide at runtime
//    * rootful -> "/" (no separate jailbreak root)
//
//  Design rule: never trust the compiled-in prefix. The daemon derives its own
//  jailbreak root from the path of its executable, the tweak asks libroothide
//  (and falls back to /var/jb). User data always lives on the *rootfs*
//  (/var/mobile/Library/iAgent) so it is shared between root and mobile
//  processes and survives a jailbreak-root change.
//

#ifndef IAG_PATHS_H
#define IAG_PATHS_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Jailbreak root, e.g. "/var/jb" or the hidden roothide root. "/" if rootful.
NSString *IAGJailbreakRoot(void);

/// Real rootfs prefix ("/" for almost everybody, roothide may differ).
NSString *IAGRootfs(void);

/// true when the jailbreak root is not the rootfs itself.
BOOL IAGIsRootless(void);

/// /var/mobile/Library/iAgent — shared, always on the rootfs.
NSString *IAGDataDir(void);
NSString *IAGConfigPath(void);
NSString *IAGStatePath(void);
NSString *IAGSessionsDir(void);
NSString *IAGSessionPath(NSString *sessionId);
NSString *IAGLogDir(void);
NSString *IAGLogPath(void);
NSString *IAGCronPath(void);
NSString *IAGApprovalsDir(void);
NSString *IAGEventsPath(void);

/// Directory holding the static web UI (index.html / app.js / style.css).
NSString *IAGWebRoot(void);

/// Translate a rootless absolute path ("/usr/bin/sh") into the real, on-disk
/// path for this device. Tries the detected jailbreak root first, then /var/jb,
/// then the rootfs, and returns the first candidate that exists. When nothing
/// exists the preferred candidate is returned so callers can still report it.
NSString *IAGResolveRootlessPath(NSString *rootlessAbsolutePath);

/// All candidates for a rootless path, best first (used for diagnostics).
NSArray<NSString *> *IAGCandidatePaths(NSString *rootlessAbsolutePath);

/// mkdir -p with sane permissions; returns YES when the directory exists after
/// the call.
BOOL IAGEnsureDirectory(NSString *path);

BOOL IAGPathExists(NSString *path);
BOOL IAGPathIsDirectory(NSString *path);

/// Device identity, works from a daemon (no UIKit required).
NSString *IAGDeviceModelIdentifier(void);   // e.g. "iPhone14,2"
NSString *IAGDeviceModelName(void);         // e.g. "iPhone 13 Pro"
NSString *IAGSystemVersion(void);           // e.g. "15.4.1"
NSString *IAGDeviceName(void);              // user visible name, may be nil
NSString *IAGBootUUID(void);

/// geteuid() == 0
BOOL IAGIsRoot(void);
/// "mobile", "root", ...
NSString *IAGUserName(void);

/// Free space in bytes on the data volume (-1 when unknown).
long long IAGFreeDiskSpace(void);

/// Human readable uptime of the *process*, e.g. "01:23:45".
NSString *IAGProcessUptime(void);

#ifdef __cplusplus
}
#endif

#endif /* IAG_PATHS_H */
