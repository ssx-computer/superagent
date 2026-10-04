#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
iAgent 静态自检 (preflight)
===========================

这套代码要在 macOS + Theos 上编译，但开发/编辑往往发生在没有 Xcode、没有
iOS SDK、也没有 iOS 设备的机器上。这个脚本把那台机器上**能查的东西**全部查掉：

  1. C/Objective-C: 每个 #import "…" 都能解析；括号/花括号配平；头文件有 guard
  2. Makefile: 两个实例的源文件列表都存在；目录里没有漏登记的 .m；
     引用的框架都在 *_FRAMEWORKS 里
  3. plist: LaunchDaemon / 注入过滤器 / entitlements 都能解析且关键字段齐全
  4. DEBIAN: control 字段、maintainer script 的 shebang 与换行符
  5. Web UI: app.js 语法 (有 node 时)、用到的每个 DOM id 都存在于 index.html、
     每个 HTTP 路径都真的在 IAGDaemon.m 里注册过

用法:
    python scripts/preflight.py            # 在仓库根目录或任意目录下运行
    python scripts/preflight.py --verbose

退出码: 0 = 没有 FAIL（WARN 不阻塞），1 = 至少一个 FAIL。
"""

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys

# Windows 控制台默认是 GBK，中文与符号会直接抛 UnicodeEncodeError。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:                                   # noqa: BLE001 - 老 Python 没有 reconfigure
        pass

ROOT = os.path.dirname(os.path.abspath(os.path.join(__file__, "..")))
PROJECT = os.path.join(ROOT, "iagent") if os.path.isdir(os.path.join(ROOT, "iagent")) else ROOT

FAILURES = []
WARNINGS = []
CHECKS = 0

# 文件作用域的 static 定义（用于「有没有引用点」的粗筛，见 check_objc）。
# 只认 IAG / kIAG 前缀，避免把第三方头文件里的写法误判成本项目的问题。
STATIC_FUNC_RE = re.compile(r'^static\s+[^;{=]*?\b(IAG[A-Za-z0-9_]*)\s*\(', re.M)
STATIC_VAR_RE = re.compile(r'^static\s+[^;{]*?\b(kIAG[A-Za-z0-9_]*)\s*(?:\[[^\]]*\])?\s*=', re.M)

# glibc/Linux 有而 Darwin（iOS SDK）没有：编译到 macOS 上会因"隐式函数声明"报错。
# 只列确定不存在于 iOS SDK 的，宁可少列也不要误报（误报会让 checks job 变红）。
LINUX_ONLY = (
    "fdatasync", "sincos", "sincosf", "memrchr", "strchrnul", "canonicalize_file_name",
    "eaccess", "execvpe", "clearenv", "mallinfo", "mallopt", "malloc_trim",
    "pthread_yield", "get_nprocs", "sched_getaffinity", "secure_getenv",
    "pipe2", "accept4", "signalfd", "eventfd", "epoll_create", "inotify_init", "ppoll",
)
LINUX_ONLY_RE = "|".join(LINUX_ONLY)


def fail(area, message):
    FAILURES.append((area, message))


def warn(area, message):
    WARNINGS.append((area, message))


def ok(area, message, verbose_note=None):
    global CHECKS
    CHECKS += 1
    print("  ok %s: %s" % (area, verbose_note if (verbose_note and VERBOSE) else message))


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


# ---------------------------------------------------------------------------
# 源码扫描工具
# ---------------------------------------------------------------------------

def strip_c_literals(text):
    """去掉注释与字符串/字符字面量，用于括号配平统计。保留换行以便定位行号。"""
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
        elif ch == "/" and nxt == "*":
            i += 2
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                if text[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        elif ch == '"' or ch == "'":
            # 单引号在注释和 #pragma 里也常见（AXRuntime's），只有真正的字符
            # 常量（'x' 或 '\n'）才按字面量处理，否则会吞掉后面的代码。
            if ch == "'" and not (nxt == "\\" or (i + 2 < n and text[i + 2] == "'")):
                out.append(ch)
                i += 1
                continue
            quote = ch
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                if text[i] == "\n":
                    out.append("\n")
                i += 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def unbalanced_at(stripped, open_ch, close_ch):
    """返回 (行号, 余额)。余额不为 0 时行号指向问题最可能出现的位置。"""
    balance = 0
    last_line = 1
    for number, line in enumerate(stripped.split("\n"), 1):
        last_line = number
        for ch in line:
            if ch == open_ch:
                balance += 1
            elif ch == close_ch:
                balance -= 1
        if balance < 0:
            return number, balance
    return (None if balance == 0 else last_line), balance


def source_files():
    """所有参与编译的 .m/.h（daemon / tweak / shared）。"""
    result = []
    for sub in ("daemon", "tweak", "shared"):
        directory = os.path.join(PROJECT, sub)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            if name.endswith(".m") or name.endswith(".h"):
                result.append(os.path.join(directory, name))
    return result


def import_search_paths(path):
    here = os.path.dirname(path)
    return [here,
            os.path.join(PROJECT, "shared"),
            os.path.join(PROJECT, "daemon"),
            os.path.join(PROJECT, "tweak"),
            PROJECT]


# ---------------------------------------------------------------------------
# 1. C / Objective-C
# ---------------------------------------------------------------------------

def check_objc(verbose):
    print("\n[1/6] 源码与头文件")
    files = source_files()
    if not files:
        fail("sources", "在 daemon/ tweak/ shared/ 下没有找到任何 .m/.h")
        return

    for path in files:
        rel = os.path.relpath(path, PROJECT)
        text = read(path)

        # 本地 #import "X.h"
        for match in re.finditer(r'^\s*#\s*(?:import|include)\s+"([^"]+)"', text, re.M):
            header = match.group(1)
            if os.path.isabs(header):
                continue
            if not any(os.path.isfile(os.path.join(base, header)) for base in import_search_paths(path)):
                fail("sources", "%s 引用了不存在的头文件 %s" % (rel, header))

        # 框架 #import <Foo/Bar.h>
        for match in re.finditer(r'^\s*#\s*(?:import|include)\s+<([A-Za-z0-9_]+)/', text, re.M):
            framework = match.group(1)
            if framework in ("Foundation", "CoreFoundation", "UIKit", "WebKit",
                             "CoreGraphics", "IOKit", "objc", "dispatch", "mach",
                             "sys", "unistd", "pthread", "stdlib", "string", "stdio",
                             "signal", "errno", "fcntl", "util", "dlfcn", "stdint",
                             "stdbool", "stddef", "libkern", "netinet", "arpa", "syslog"):
                continue
            warn("sources", "%s 引入了不常见的框架头 <%s/…>，确认链接设置" % (rel, framework))

        # 括号配平（粗筛：能抓住"编辑把文件截断了"这类事故）
        stripped = strip_c_literals(text)
        for open_ch, close_ch in (("{", "}"), ("(", ")"), ("[", "]")):
            line, balance = unbalanced_at(stripped, open_ch, close_ch)
            if balance != 0:
                where = ("第 %d 行附近" % line) if line else "文件末尾"
                fail("sources", "%s 的 %s%s 不配平（差 %+d，%s），文件可能被截断"
                     % (rel, open_ch, close_ch, balance, where))

        # 头文件 guard
        if path.endswith(".h") and "#pragma once" not in text:
            if not re.search(r'^#\s*ifndef\s+\w+', text, re.M):
                warn("sources", "%s 没有 include guard" % rel)

        # 没有引用点的 static 函数/变量：CI 编译带 -Werror，这类警告会让整轮构建失败
        # （曾因 daemon/IAGModelCheck.m 里一个没人调用的 static 函数白跑两轮 CI）。
        # 注释与字符串已经在 stripped 里去掉，所以数字符串里的同名文字不会被算作引用。
        if path.endswith(".m"):
            for kind, flag, pattern in (("函数", "function", STATIC_FUNC_RE),
                                        ("变量", "variable", STATIC_VAR_RE)):
                for match in pattern.finditer(text):
                    name = match.group(1)
                    if name == "main":
                        continue
                    if len(re.findall(r'\b%s\b' % re.escape(name), stripped)) <= 1:
                        fail("sources", "%s 里的 static %s %s 没有任何引用点（-Wunused-%s 会以 -Werror 失败）：删掉它，或补上调用点"
                             % (rel, kind, name, flag))

        # Linux/glibc 有、Darwin 上没有（或没有声明）的函数。CI 是在 macOS 上编译的，
        # clang 从 C99 起把"隐式函数声明"直接当错误，一轮 CI 只会告诉你第一个出问题的
        # 文件，本地先扫一遍能省好几次推送（fdatasync 就是这么发现的）。
        if path.endswith(".m"):
            for symbol in sorted(set(re.findall(r'\b(%s)\s*\(' % LINUX_ONLY_RE, stripped))):
                fail("sources", "%s 调用了 %s()，iOS/macOS 的 SDK 里没有这个函数（Darwin 编译会报 implicit function declaration）"
                     % (rel, symbol))

    ok("sources", "%d 个源文件" % len(files), "检查了 %d 个 .m/.h 的引用、配平、未使用的 static 与 Darwin 缺失函数" % len(files))


# ---------------------------------------------------------------------------
# 2. Makefile
# ---------------------------------------------------------------------------

def parse_makefile_list(text, variable):
    match = re.search(r'^%s\s*=\s*((?:.*\\\n)*.*)$' % re.escape(variable), text, re.M)
    if not match:
        return None
    joined = match.group(1).replace("\\\n", " ")
    return [item for item in joined.split() if item]


def check_makefile(verbose):
    print("\n[2/6] Makefile")
    path = os.path.join(PROJECT, "Makefile")
    if not os.path.isfile(path):
        fail("makefile", "找不到 Makefile")
        return
    text = read(path)

    instances = {"iagentd": "daemon", "iagent": "tweak"}
    listed = {}

    for instance, sub in instances.items():
        entries = parse_makefile_list(text, "%s_FILES" % instance)
        if entries is None:
            fail("makefile", "缺少 %s_FILES" % instance)
            continue
        listed[instance] = entries
        for entry in entries:
            if not os.path.isfile(os.path.join(PROJECT, entry)):
                fail("makefile", "%s_FILES 里的 %s 不存在" % (instance, entry))

        # 反向检查：目录里的 .m 有没有漏登记
        for name in sorted(os.listdir(os.path.join(PROJECT, sub))):
            if not name.endswith(".m") or name == "main.m":
                continue
            rel = "%s/%s" % (sub, name)
            if rel not in entries:
                fail("makefile", "%s 没有被登记进 %s_FILES（不会被编译）" % (rel, instance))

        frameworks = parse_makefile_list(text, "%s_FRAMEWORKS" % instance) or []
        needed = set()
        for entry in entries:
            if not entry.endswith(".m"):
                continue
            source = read(os.path.join(PROJECT, entry))
            for match in re.finditer(r'^\s*#\s*(?:import|include)\s+<([A-Za-z0-9_]+)/', source, re.M):
                header = match.group(1)
                if header in ("Foundation", "CoreFoundation", "UIKit", "WebKit", "CoreGraphics"):
                    needed.add(header)
        missing = needed - set(frameworks)
        if missing:
            warn("makefile", "%s_FRAMEWORKS 里缺少 %s（若通过 dlopen 使用可以忽略）"
                 % (instance, ", ".join(sorted(missing))))

    # 未登记的源文件
    everything = set()
    for entries in listed.values():
        everything.update(entries)
    for path_ in source_files():
        if not path_.endswith(".m"):
            continue
        rel = os.path.relpath(path_, PROJECT).replace("\\", "/")
        if rel not in everything:
            warn("sources", "%s 没有出现在任何实例的 FILES 里" % rel)

    if "include $(THEOS_MAKE_PATH)/tool.mk" not in text:
        fail("makefile", "没有 include tool.mk（守护进程不会被构建）")
    if "include $(THEOS_MAKE_PATH)/tweak.mk" not in text:
        fail("makefile", "没有 include tweak.mk（插件不会被构建）")
    if "include $(THEOS_MAKE_PATH)/aggregate.mk" not in text:
        fail("makefile", "没有 include aggregate.mk（不会产出 .deb）")

    scheme = None
    branch = re.search(r'else\s*\n\s*THEOS_PACKAGE_SCHEME\s*=\s*(\w+)', text)
    if branch:
        scheme = branch.group(1)
    if "IAG_ROOTHIDE" not in text:
        warn("makefile", "没有看到 IAG_ROOTHIDE 开关，RootHide 版本可能打不出来")
    elif verbose and scheme:
        print("  · 默认（非 IAG_ROOTHIDE）打包方案: %s" % scheme)

    entitlements = re.search(r'CODESIGN_FLAGS\s*=\s*-S(\S+)', text)
    if entitlements:
        target = entitlements.group(1).replace("$(THEOS_PROJECT_DIR)/", "").replace("$(THEOS_PROJECT_DIR)", "")
        if not os.path.isfile(os.path.join(PROJECT, target)):
            fail("makefile", "CODESIGN_FLAGS 指向的 %s 不存在" % entitlements.group(1))
    else:
        warn("makefile", "守护进程没有签名参数（RootHide 可能拒绝加载）")

    ok("makefile", "两个构建实例", "iagentd=%d 个源文件, iagent=%d 个源文件"
       % (len(listed.get("iagentd", [])), len(listed.get("iagent", []))))


# ---------------------------------------------------------------------------
# 3. plist
# ---------------------------------------------------------------------------

def check_plists(verbose):
    print("\n[3/6] plist")
    layout = os.path.join(PROJECT, "layout")
    found = []
    for base, _dirs, names in os.walk(layout):
        for name in names:
            if name.endswith(".plist"):
                found.append(os.path.join(base, name))
    ent = os.path.join(PROJECT, "entitlements.plist")
    if os.path.isfile(ent):
        found.append(ent)

    if not found:
        fail("plist", "没有找到任何 plist")
        return

    daemon_plist = None
    tweak_plist = None
    for path in found:
        rel = os.path.relpath(path, PROJECT)
        try:
            with open(path, "rb") as handle:
                data = plistlib.load(handle)
        except Exception as exc:                       # noqa: BLE001 - 报告即可
            fail("plist", "%s 解析失败: %s" % (rel, exc))
            continue

        if not isinstance(data, dict):
            fail("plist", "%s 顶层不是字典" % rel)
            continue

        if "Label" in data:
            daemon_plist = (rel, data)
        if "Filter" in data:
            tweak_plist = (rel, data)
        ok("plist", rel, "%s 可解析" % rel)

    if daemon_plist:
        rel, data = daemon_plist
        for key in ("Label", "ProgramArguments", "RunAtLoad"):
            if key not in data:
                fail("plist", "%s 缺少 %s" % (rel, key))
        label = data.get("Label", "")
        arguments = data.get("ProgramArguments", [])
        if label != "com.dsh.iagent.daemon":
            warn("plist", "LaunchDaemon 的 Label 是 %s" % label)
        if not arguments or not str(arguments[0]).endswith("iagentd"):
            fail("plist", "%s 的 ProgramArguments 没有指向 iagentd: %s" % (rel, arguments))
        elif "/var/jb" in str(arguments[0]) and verbose:
            print("  · LaunchDaemon 使用 rootless 路径 %s（postinst 会在 RootHide 上改写）" % arguments[0])
        if data.get("KeepAlive") is None:
            warn("plist", "%s 没有 KeepAlive，守护进程崩溃后不会自动重启" % rel)
    else:
        fail("plist", "没有找到 LaunchDaemon plist（缺少 Label 字段）")

    if tweak_plist:
        rel, data = tweak_plist
        bundles = (data.get("Filter") or {}).get("Bundles") or []
        if "com.apple.springboard" not in bundles:
            fail("plist", "%s 的 Filter.Bundles 不含 com.apple.springboard" % rel)
        basename = os.path.basename(rel)
        if basename != "iagent.plist":
            warn("plist", "%s 必须与 dylib 同名（iagent.plist ↔ iagent.dylib）" % rel)
    else:
        fail("plist", "没有找到注入过滤器 plist（缺少 Filter 字段）")

    ok("plist", "%d 个 plist" % len(found))


# ---------------------------------------------------------------------------
# 4. DEBIAN
# ---------------------------------------------------------------------------

def check_debian(verbose):
    print("\n[4/6] DEBIAN")
    debian = os.path.join(PROJECT, "layout", "DEBIAN")
    if not os.path.isdir(debian):
        fail("debian", "缺少 layout/DEBIAN")
        return

    control = os.path.join(debian, "control")
    if not os.path.isfile(control):
        warn("debian", "没有 layout/DEBIAN/control（Theos 会用 Makefile 变量生成）")
    else:
        raw = open(control, "rb").read()
        if b"\r\n" in raw:
            fail("debian", "control 含 CRLF 换行，dpkg 会报错")
        text = raw.decode("utf-8", "replace")
        fields = dict(re.findall(r'^([A-Za-z-]+):\s*(.*)$', text, re.M))
        for key in ("Package", "Name", "Version", "Architecture", "Description", "Depends"):
            if key not in fields:
                fail("debian", "control 缺少 %s 字段" % key)
        if "firmware" not in fields.get("Depends", ""):
            warn("debian", "Depends 没有锁 firmware 版本：%s" % fields.get("Depends"))
        if fields.get("Architecture") not in ("iphoneos-arm64", "iphoneos-arm64e"):
            warn("debian", "Architecture 通常是 iphoneos-arm64（rootless）或 iphoneos-arm64e（RootHide）")

    for name in ("postinst", "prerm"):
        path = os.path.join(debian, name)
        if not os.path.isfile(path):
            fail("debian", "缺少 %s" % name)
            continue
        raw = open(path, "rb").read()
        if b"\r\n" in raw:
            fail("debian", "%s 含 CRLF 换行，dpkg 会拒绝执行" % name)
        if not raw.startswith(b"#!/bin/sh"):
            fail("debian", "%s 没有以 #!/bin/sh 开头" % name)
        if not os.access(path, os.X_OK):
            warn("debian", "%s 没有可执行位（Windows 无法保留；CI 与 Makefile 会 chmod +x）" % name)
        text = raw.decode("utf-8", "replace")
        if name == "postinst" and "basebin" not in text:
            warn("debian", "postinst 没有处理 RootHide 的 basebin/LaunchDaemons")

    ok("debian", "control 与维护脚本")


# ---------------------------------------------------------------------------
# 5. Web UI
# ---------------------------------------------------------------------------

def daemon_routes():
    """从 IAGDaemon.m 里抽出所有 /api/... 路径。"""
    path = os.path.join(PROJECT, "daemon", "IAGDaemon.m")
    if not os.path.isfile(path):
        return set()
    text = read(path)
    routes = set()
    for match in re.finditer(r'@?"(/api/[A-Za-z0-9_\-/]*)"', text):
        routes.add(match.group(1))
    # 前缀路由（hasPrefix:）也要算作覆盖
    prefixes = set()
    for match in re.finditer(r'hasPrefix:@?"(/api/[A-Za-z0-9_\-/]*)"', text):
        prefixes.add(match.group(1))
    return routes | prefixes


def check_web(verbose):
    print("\n[5/6] Web 控制面板")
    web = os.path.join(PROJECT, "layout", "usr", "share", "iagent", "web")
    index_path = os.path.join(web, "index.html")
    app_path = os.path.join(web, "app.js")
    style_path = os.path.join(web, "style.css")

    for path in (index_path, app_path, style_path):
        if not os.path.isfile(path):
            fail("web", "缺少 %s" % os.path.relpath(path, PROJECT))
            return

    index = read(index_path)
    app = read(app_path)
    style = read(style_path)

    # app.js 语法
    node = shutil.which("node")
    if node:
        result = subprocess.run([node, "--check", app_path], capture_output=True, text=True)
        if result.returncode != 0:
            fail("web", "app.js 语法错误: %s" % (result.stderr.strip().splitlines()[:3]))
        else:
            ok("web", "app.js 语法", "node --check 通过")
    else:
        warn("web", "本机没有 node，跳过 app.js 语法检查")

    # DOM id 契约
    html_ids = set(re.findall(r'\bid="([^"]+)"', index))
    used_ids = set(re.findall(r"\$\('([^']+)'\)", app))
    used_ids |= set(re.findall(r"getElementById\('([^']+)'\)", app))
    dynamic = {"modal-host"}          # app.js 运行时自己创建
    missing = sorted(used_ids - html_ids - dynamic)
    if missing:
        fail("web", "app.js 使用了 index.html 里不存在的 id: %s" % ", ".join(missing))
    unused = sorted(html_ids - used_ids)
    if unused and verbose:
        print("  · index.html 中未被 app.js 引用的 id: %s" % ", ".join(unused))

    # HTTP 路径契约
    routes = daemon_routes()
    if not routes:
        warn("web", "没能从 IAGDaemon.m 解析出路由")
    called = set()
    for match in re.finditer(r"""(?:api|apiFetch)\(\s*'([^']+)'""", app):
        called.add(match.group(1))
    for path in sorted(called):
        if path.startswith("/api/"):
            if not any(path == route or path.startswith(route.rstrip("/") + "/") or route.startswith(path.rstrip("/") + "/")
                       for route in routes):
                fail("web", "app.js 调用了守护进程没注册的路径: %s" % path)
    if verbose:
        print("  · app.js 调用 %d 个接口，守护进程注册 %d 个路由" % (len(called), len(routes)))

    # SSE 事件名
    events = set(re.findall(r"eventName === '([a-z_]+)'", app))
    daemon_text = read(os.path.join(PROJECT, "daemon", "IAGDaemon.m")) + read(os.path.join(PROJECT, "daemon", "IAGAgent.m"))
    for event in sorted(events):
        if '"%s"' % event not in daemon_text:
            warn("web", "app.js 处理的事件 %s 在守护进程里没找到" % event)

    # CSS 类契约（只查最容易写错的几个状态类）
    for class_name in ("toolcard", "approval", "notice", "term-chip", "tool-chip", "msg", "pill"):
        if ("'" + class_name) not in app and ('"' + class_name) not in app:
            continue
        if "." + class_name not in style:
            warn("web", "app.js 使用 .%s，style.css 里没有定义" % class_name)

    ok("web", "html/js/css 契约", "%d 个 id, %d 个接口调用" % (len(html_ids), len(called)))


# ---------------------------------------------------------------------------
# 6. 其余一致性
# ---------------------------------------------------------------------------

def check_misc(verbose):
    print("\n[6/6] 版本与文档")
    version = os.path.join(PROJECT, "shared", "IAGVersion.h")
    makefile = read(os.path.join(PROJECT, "Makefile"))
    if os.path.isfile(version):
        text = read(version)
        match = re.search(r'IAG_VERSION_STRING\s+@?"([^"]+)"', text)
        if match:
            if ("PACKAGE_VERSION     = %s" % match.group(1)) not in makefile and \
               ("PACKAGE_VERSION = %s" % match.group(1)) not in makefile:
                warn("misc", "IAGVersion.h 的版本 %s 与 Makefile 的 PACKAGE_VERSION 不一致" % match.group(1))
            ok("misc", "版本 %s" % match.group(1))

    control = os.path.join(PROJECT, "layout", "DEBIAN", "control")
    if os.path.isfile(control):
        control_text = read(control)
        match = re.search(r'^Version:\s*(\S+)', control_text, re.M)
        version_match = re.search(r'IAG_VERSION_STRING\s+@?"([^"]+)"', read(version)) if os.path.isfile(version) else None
        if match and version_match and match.group(1) != version_match.group(1):
            warn("misc", "control 的 Version (%s) 与 IAGVersion.h (%s) 不一致"
                 % (match.group(1), version_match.group(1)))

    # 关键文件在不在
    for rel in ("README.md", "docs/architecture.md", "docs/install.md", "docs/tools.md",
                "docs/api.md", "docs/security.md", "docs/build.md",
                ".github/workflows/build.yml"):
        if not os.path.isfile(os.path.join(PROJECT, rel)):
            warn("misc", "缺少 %s" % rel)

    # 数据目录一致性：postinst 与 IAGPaths 必须用同一个路径
    paths = read(os.path.join(PROJECT, "shared", "IAGPaths.m"))
    postinst = read(os.path.join(PROJECT, "layout", "DEBIAN", "postinst"))
    if "/var/mobile/Library/iAgent" not in paths:
        fail("misc", "IAGPaths.m 里的数据目录不是 /var/mobile/Library/iAgent")
    if "/var/mobile/Library/iAgent" not in postinst:
        warn("misc", "postinst 没有创建 /var/mobile/Library/iAgent")


def main():
    global VERBOSE
    parser = argparse.ArgumentParser(description="iAgent 静态自检")
    parser.add_argument("--verbose", "-v", action="store_true", help="打印每一项检查的细节")
    parser.add_argument("--json", action="store_true", help="以 JSON 输出结果")
    args = parser.parse_args()
    VERBOSE = args.verbose

    print("iAgent preflight — 项目目录: %s" % PROJECT)

    check_objc(args.verbose)
    check_makefile(args.verbose)
    check_plists(args.verbose)
    check_debian(args.verbose)
    check_web(args.verbose)
    check_misc(args.verbose)

    print("\n" + "=" * 68)
    if WARNINGS:
        print("WARN (%d)" % len(WARNINGS))
        for area, message in WARNINGS:
            print("  ! [%s] %s" % (area, message))
    if FAILURES:
        print("FAIL (%d)" % len(FAILURES))
        for area, message in FAILURES:
            print("  x [%s] %s" % (area, message))
    print("检查项 %d，警告 %d，错误 %d" % (CHECKS, len(WARNINGS), len(FAILURES)))

    if args.json:
        print(json.dumps({
            "checks": CHECKS,
            "warnings": [{"area": a, "message": m} for a, m in WARNINGS],
            "failures": [{"area": a, "message": m} for a, m in FAILURES],
        }, ensure_ascii=False, indent=2))

    if FAILURES:
        print("\n结论: 有问题需要修复（上面 FAIL 列表）")
        return 1
    print("\n结论: 结构检查通过（仍无法替代真机编译与运行）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
