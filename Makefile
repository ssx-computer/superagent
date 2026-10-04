# ============================================================================
#  iAgent — native on-device AI agent for iOS 15+ (Dopamine / RootHide / rootless)
#
#  Two instances are built from this single Makefile:
#
#    * iagentd      — the root daemon: HTTP control plane, agent loop, PTY
#                     terminals, cron, tools  (built as a `tool` -> /usr/bin)
#    * iagent.dylib — the SpringBoard tweak: floating bubble, web panel,
#                     bridge long-poll, HID injection  (a plain constructor
#                     dylib; no Logos, no substrate, no hooking)
#
#  Build:
#      make clean package FINALPACKAGE=1                 # Dopamine / rootless
#      make clean package FINALPACKAGE=1 IAG_ROOTHIDE=1  # RootHide (needs roothide/theos)
#
#  See docs/build.md for the cloud-build (GitHub Actions) instructions.
# ============================================================================

export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0

# Keep the built binaries' deployment target at iOS 15 so they load on Dopamine
# (iOS 15/16) as well as newer releases.
export ADDITIONAL_CFLAGS += -Wno-unused-parameter -Wno-deprecated-declarations

# ---------------------------------------------------------------------------
#  Package scheme
#
#  rootless  -> THEOS_PACKAGE_INSTALL_PREFIX=/var/jb, Architecture iphoneos-arm64
#               and the dual rpath (/var/jb + @loader_path/.jbroot) that makes
#               the same binaries resolve on both Dopamine and RootHide.
#  roothide  -> for roothide/theos: Architecture iphoneos-arm64e and
#               @loader_path/.jbroot install names. Requires the roothide fork
#               of Theos; with upstream Theos this variable does nothing.
# ---------------------------------------------------------------------------
ifeq ($(IAG_ROOTHIDE),1)
THEOS_PACKAGE_SCHEME = roothide
else
THEOS_PACKAGE_SCHEME = rootless
endif

# ---------------------------------------------------------------------------
#  Package metadata (used to generate the Debian control file).
#  The identifier is spelled several ways on purpose: Theos has used more than
#  one variable name for the Package: field across releases, and an unknown
#  variable is harmless here. layout/DEBIAN/control carries the same values as
#  a fallback, so the package is correct either way.
# ---------------------------------------------------------------------------
PACKAGE_ID          = com.dsh.iagent
PACKAGE_NAME        = iAgent
THEOS_PACKAGE_NAME  = com.dsh.iagent
PACKAGE_VERSION     = 1.1.0
PACKAGE_DESCRIPTION = 原生 iOS AI Agent：常驻守护进程 + SpringBoard 悬浮球与 Web 控制面板，支持终端、文件、应用、通知、定时任务与界面自动化。
PACKAGE_MAINTAINER  = dsh <dsh@localhost>
PACKAGE_SECTION     = Tweaks
PACKAGE_PRIORITY    = optional
PACKAGE_DEPENDS     = firmware (>= 15.0)
PACKAGE_URL         = https://github.com/dsh/iagent

# Restart SpringBoard so the tweak is picked up right after installation.
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# ===========================================================================
#  iagentd — daemon
# ===========================================================================

TOOL_NAME = iagentd

iagentd_FILES = \
    daemon/main.m \
    daemon/IAGDaemon.m \
    daemon/IAGHTTPServer.m \
    daemon/IAGConfig.m \
    daemon/IAGAgent.m \
    daemon/IAGSessionStore.m \
    daemon/IAGLLM.m \
    daemon/IAGModelCheck.m \
    daemon/IAGTool.m \
    daemon/IAGToolShell.m \
    daemon/IAGToolFile.m \
    daemon/IAGToolDevice.m \
    daemon/IAGBridge.m \
    daemon/IAGScheduler.m \
    daemon/IAGTerminal.m \
    daemon/IAGProcess.m \
    shared/IAGPaths.m \
    shared/IAGLog.m \
    shared/IAGDiagnostics.m \
    shared/IAGJSON.m \
    shared/IAGUtil.m

iagentd_FRAMEWORKS = Foundation CoreFoundation
iagentd_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/shared -I$(THEOS_PROJECT_DIR)/daemon
iagentd_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/entitlements.plist
# TOOL_NAME installs to /usr/bin by default -> $JBROOT/usr/bin/iagentd.
iagentd_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk

# ===========================================================================
#  iagent.dylib — SpringBoard tweak
#
#  Contains no Logos directives at all (the entry point is a plain
#  __attribute__((constructor))), so generator=internal is only a guarantee
#  that nothing drags in <substrate.h> and therefore no CydiaSubstrate load
#  command ever appears in the dylib.
# ===========================================================================

TWEAK_NAME = iagent

iagent_FILES = \
    tweak/IAGTweak.m \
    tweak/IAGAutomation.m \
    daemon/IAGConfig.m \
    shared/IAGPaths.m \
    shared/IAGLog.m \
    shared/IAGJSON.m \
    shared/IAGUtil.m

iagent_FRAMEWORKS = Foundation UIKit WebKit CoreFoundation CoreGraphics
iagent_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/shared -I$(THEOS_PROJECT_DIR)/daemon -I$(THEOS_PROJECT_DIR)/tweak
iagent_LOGOSFLAGS = -c generator=internal
# Default LOCAL_INSTALL_PATH for tweaks is /Library/MobileSubstrate/DynamicLibraries,
# which is exactly where ElleKit (Dopamine) and roothide inject from.
iagent_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

# ===========================================================================
#  Aggregate + small helpers
# ===========================================================================

include $(THEOS_MAKE_PATH)/aggregate.mk

# ===========================================================================
#  Packaging hooks
#
#  Maintainer scripts must be executable inside the .deb. A checkout made on
#  Windows cannot carry the mode bit, so force it after staging (CI does the
#  same thing on the source tree).
# ===========================================================================
before-package::
	@for script in postinst prerm; do \
		if [ -f "$(THEOS_STAGING_DIR)/DEBIAN/$$script" ]; then \
			chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/$$script"; \
			echo "  staged DEBIAN/$$script (mode 0755)"; \
		fi; \
	done
	@# Theos generates DEBIAN/control from the variables above; the copy in
	@# layout/DEBIAN/control documents the same fields for manual packaging.

# `make paths` prints what the daemon will resolve at runtime (handy on device).
paths::
	@echo "jailbreak root : $(THEOS_PACKAGE_INSTALL_PREFIX)"
	@echo "package arch   : $(THEOS_PACKAGE_ARCH)"
	@echo "web files      : $(THEOS_PROJECT_DIR)/layout/usr/share/iagent/web"
