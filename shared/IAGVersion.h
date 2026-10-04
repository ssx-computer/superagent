//
//  IAGVersion.h
//  iAgent — native on-device AI Agent for iOS (rootless / Dopamine / RootHide)
//
//  Single source of truth for version + identity strings shared by the daemon
//  and the SpringBoard tweak.
//

#ifndef IAG_VERSION_H
#define IAG_VERSION_H

#define IAG_VERSION_STRING      @"1.0.1"
#define IAG_BUILD_STRING        @"2"
#define IAG_BUNDLE_ID           @"com.dsh.iagent"
#define IAG_DAEMON_LABEL        @"com.dsh.iagent.daemon"
#define IAG_DAEMON_BINARY       @"iagentd"

// Darwin notification posted by the daemon whenever the event queue advances.
// The SpringBoard tweak observes it so it can react without polling.
#define IAG_DARWIN_NOTIFY_EVENT @"com.dsh.iagent.event"

// Default loopback HTTP endpoint used by the web UI and the tweak panel.
#define IAG_DEFAULT_PORT        8080
#define IAG_DEFAULT_HOST        @"127.0.0.1"

// Fallback bearer token header name (also accepted as ?token= query parameter).
#define IAG_TOKEN_HEADER        @"X-IAG-Token"

#endif /* IAG_VERSION_H */
