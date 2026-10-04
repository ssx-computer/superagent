//
//  IAGLog.h
//  iAgent
//
//  Very small, allocation-light logger. Everything is appended to
//  /var/mobile/Library/iAgent/logs/iagent.log and optionally mirrored to stderr
//  (launchd captures that into the daemon's stdout file).
//

#ifndef IAG_LOG_H
#define IAG_LOG_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, IAGLogLevel) {
    IAGLogLevelDebug = 0,
    IAGLogLevelInfo  = 1,
    IAGLogLevelWarn  = 2,
    IAGLogLevelError = 3,
};

#ifdef __cplusplus
extern "C" {
#endif

void IAGLogSetLevel(IAGLogLevel level);
IAGLogLevel IAGLogGetLevel(void);
void IAGLogSetMirrorToStderr(BOOL mirror);

void IAGLogMessage(IAGLogLevel level, const char *file, int line, NSString *format, ...) NS_FORMAT_FUNCTION(4, 5);

/// Read the tail of the log file (used by GET /api/logs).
NSArray<NSString *> *IAGLogTail(NSUInteger maxLines);
/// Truncate the log file.
void IAGLogClear(void);

#ifdef __cplusplus
}
#endif

#define IAGLogDebug(fmt, ...) IAGLogMessage(IAGLogLevelDebug, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#define IAGLogInfo(fmt, ...)  IAGLogMessage(IAGLogLevelInfo,  __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#define IAGLogWarn(fmt, ...)  IAGLogMessage(IAGLogLevelWarn,  __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#define IAGLogError(fmt, ...) IAGLogMessage(IAGLogLevelError, __FILE__, __LINE__, fmt, ##__VA_ARGS__)

#endif /* IAG_LOG_H */
