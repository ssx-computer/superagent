# iOS 15+ 越狱（Dopamine rootless / RootHide）AI Agent 插件 —— 私有 API 技术备忘

> 目标读者：要写「常驻 LaunchDaemon + 注入 SpringBoard 的 Theos tweak」的开发者。
> 本文只写**可落地的事实**，并严格区分「已查证」与「未查证/不确定」。

---

## 0. 调研方法与可信度说明（务必先读）

本文的调研条件有一个重要限制，必须交代清楚，否则你会误判某些结论的强度：

- `web_search` 工具在本会话**不可用**（缺 API key）。
- 通用搜索引擎经当前网络出口后**被代理/审查层污染**：`cn.bing.com`、`ecosia.org` 等对技术查询返回的是完全无关的中文内容（例如查询 `xuan32546 IOS13-SimulateTouch github IOHIDEvent` 返回「威尼斯」条目），`duckduckgo`、`google`、`mojeek`、`brave`、`startpage`、`baresearch` 全部连接超时，`yandex` 直接弹 captcha，`grep.app` / `sourcegraph` / `searchcode` 的代码搜索 API 分别返回 429 / 403 / 404。GitHub 代码搜索 API 需要登录（401）。
- 因此本文的**事实来源**是：GitHub 公开仓库的**真实源码文件**（通过 GitHub contents API 与 jsDelivr 原始文件通道逐字读取）、**Apple 开源发行版源码**（`apple-oss-distributions/*`）、**Apple 官方文档 JSON**（`developer.apple.com/tutorials/data/...`）、以及 **iPhoneOS SDK 头文件镜像**（`xybp888/iOS-SDKs`）。
- 这反而让结论更硬：**凡是标注「已查证」的，都是我在上述一手文件里逐字读到并在此抄录的**（含函数原型、entitlement 键名、substrate filter、plist 内容）。

标注约定：

| 标注 | 含义 |
|---|---|
| ✅ 已查证 | 我读到了一手文件（源码 / 官方文档 / SDK 头文件），并给出链接与抄录 |
| 🟡 部分查证 | 名称或部分来源已确认，但完整签名/行为未逐条核对 |
| ❌ 未查证 | 只有传闻/常识，或我抓取失败；**上线前必须自己验证** |

参考链接里的 `github.com/.../blob/...` 是**人类可读的规范地址**；我实际是通过 GitHub contents API / jsDelivr 原始通道读取同一路径的文件内容的（因为 `raw.githubusercontent.com` 在本网络下 TLS 握手失败）。

---

## 1. 结论速查表

| # | 需求 | 推荐做法 | 进程 | 硬性前提 | 信心 |
|---|---|---|---|---|---|
| 1 | 全局模拟触摸（点击/长按/滑动/输入） | `IOHIDEventSystemClientCreate` + `IOHIDEventCreateDigitizerFingerEvent` + `IOHIDEventAppendEvent` + `IOHIDEventSystemClientDispatchEvent` | **root LaunchDaemon 或注入 SpringBoard 的 dylib 都可**（不必须在 SpringBoard） | `com.apple.private.hid.client.event-dispatch` 等 HID entitlements（见 §1.4） | ✅ |
| 2 | 读前台 App 的 UI 树 | iOS 私有 `AXRuntime.framework` 的 **ObjC 类** `AXElement` / `AXUIElement`（`+systemWideElement`、`+elementAtCoordinate:withVisualPadding:`、`-children`、`-frame`、`-press`） | 需能访问 AX 服务的进程 | entitlement **未查证**（见 §2.4） | 🟡 |
| 3 | 从 daemon 启动 App | `LSApplicationWorkspace`（**CoreServices.framework**，不是 MobileCoreServices）`-openApplicationWithBundleID:` | 任意有权限进程 | — | ✅ |
| 4 | daemon 弹可见通知 | **daemon → (rocketbootstrap CFMessagePort) → 注入 UIKit 进程的 tweak → UIAlertController / CFUserNotification** | daemon + 被注入进程 | tweak filter 覆盖 `com.apple.UIKit` 或 SpringBoard | ✅（模式）/ 🟡（单方案） |
| 5 | 交互式 PTY shell | `openpty()`（`<util.h>`，**iOS SDK 里有**）+ `posix_spawn` 到 helper，helper 里 `setsid()` + `ioctl(0, TIOCSCTTY, NULL)` + `execvp()` | daemon | 无 entitlements 依赖 | ✅ |
| 6 | SpringBoard 里放 WKWebView 加载 `http://127.0.0.1:PORT` | 历史可行（Xen HTML），但 **iOS 15/16 上权威维护者明确报告会「空白/渲染不出」**；建议放弃，改走外部浏览器或原生渲染 | SpringBoard | ATS 需允许明文 localhost | ✅（问题存在）/ ❌（"绝对不可行"未查证） |
| 7 | 悬浮球 | SpringBoard tweak 里 `UIWindow(windowLevel = 1e7 级)` + 自定义 `hitTest:` 穿透 + `UIPanGestureRecognizer` | SpringBoard（或每个 App 进程） | 无 | ✅ |

---

## 2. 六条必须先纠正的常见误解

1. ❌ **`/var/jb` 在 RootHide 上不成立。** RootHide 每次越狱把 jailbreak 装到**随机名字的 `jbroot` 目录**，依赖库用 `@loader_path/.jbroot/<绝对路径>` 作为 install_name，每个含 Mach-O 的目录会自动生成一个指向 jbroot 的 `.jbroot` 符号链接；bootstrap 里 `jbroot` 是默认根，`jbroot/rootfs` 才是真正的 iOS 根文件系统。→ 写"rootless 路径"代码时必须用 RootHide 的接口拿路径，不能硬编码 `/var/jb`。✅ 已查证：[roothide/Developer/roothide.md](https://github.com/roothide/Developer/blob/main/roothide.md)、[vroot.md](https://github.com/roothide/Developer/blob/main/vroot.md)
2. ❌ **`IOHIDEventSystemClientCreateWithType` 在我查到的所有 iOS 真实实现里都没有被使用。** XXTouch 与 ZXTouch 用的都是 `IOHIDEventSystemClientCreate(kCFAllocatorDefault)`。`...CreateWithType` 是 macOS/AppleInternal SDK 的形态（`kIOHIDEventSystemClientTypeMonitor` 之类）。→ 见 §1.6。
3. ❌ **`<pty.h>` / `<libutil.h>` 在 iOS SDK 里不存在，但 `<util.h>` 存在**，且 `openpty` / `forkpty` / `login_tty` 就声明在它里面。`posix_openpt` / `grantpt` / `unlockpt` / `ptsname` / `ptsname_r` 声明在 `<stdlib.h>`。✅ 已查证（iPhoneOS 15.5 / 15.6 / 16.5 三个 SDK）。
4. ❌ **`posix_spawn` 可以做 PTY 会话** —— NewTerm 就是这么做的（配合一个 helper 二进制）。代价是你得自己写那个小 helper。`POSIX_SPAWN_SETSID` 常量在 **public iOS SDK 的 `spawn.h` 里不存在**（只在 xnu 内部头里是 `0x0400`）。✅ 已查证。
5. ❌ **`LSApplicationWorkspace` 在 `CoreServices.framework`，不在 `MobileCoreServices`。** 且 `SBSLaunchApplicationWithIdentifier`（单参数老符号）**不在 `theos/headers` 的 SpringBoardServices 头文件里**；该头文件实际导出的是 `...AndLaunchOptions` 系列。✅ 已查证。
6. ❌ **`notifyutil` / Darwin 通知不是"通知"。** Procursus 的 `notifyutil` 来自 Apple 的 **Libnotify**（notifyd 的 CLI），是纯 IPC，**不产生任何可见 UI**。✅ 已查证：[Procursus build_info/notifyutil.control](https://github.com/ProcursusTeam/Procursus/blob/main/build_info/notifyutil.control)（Homepage 指向 `opensource.apple.com/source/Libnotify/`）。

---

## 3. 主题 1：模拟触摸（全局注入 HID 事件）

### 3.1 结论

在 iOS 15/16 上从**进程内**注入全局触摸事件是完全可行的，业界有两个成熟实现：

| 实现 | 架构 | 注入位置 | 备注 |
|---|---|---|---|
| **XXTouch (XXTouchNG)** | root **LaunchDaemon** `ch.xxtou.simulatetouchd`（`UserName=root`）持有 HID entitlements，自己 dispatch | 独立 daemon | 最接近你想要的架构，**推荐参考** |
| **ZXTouch (IOS13-SimulateTouch)** | Theos dylib，substrate filter `Bundles = (com.apple.UIKit)`，在**所有链接 UIKit 的进程（含 SpringBoard 与各 App）**里 dispatch | SpringBoard + App 进程 | 不需要 daemon，但需要 daemon 时才需要另设 |
| **iolate/SimulateTouch** | dylib + `rocketbootstrap` CFMessagePort 转发 | 目标 App 进程 | 用"屏幕坐标↔窗口坐标"转换处理旋转 |
| **PTFakeTouch / KIF 系** | 纯 ObjC：伪造 `UITouch` 并 `[[UIApplication sharedApplication] sendEvent:event]` | **必须注入目标 App**，且**不跨进程、不跨 App** | 见 §3.7 |

**关键结论：不必须在 SpringBoard 里执行。** 只要进程拿到了 HID 相关 entitlement，就能 dispatch 全局事件；XXTouch 用的是 root daemon，ZXTouch 用的是注入进程。SpringBoard 只是"顺便"也被注入了而已。

### 3.2 确切函数签名（✅ 已查证，逐字抄录）

来源：XXTouch 自带的 SPI 头文件 [touch/hid/IOKitSPI.h](https://github.com/XXTouchNG/XXTouchNG/blob/master/touch/hid/IOKitSPI.h)（该文件头部注明源自 Apple `IOHIDFamily` 的 `IOHIDEventTypes.h`）：

```c
typedef double   IOHIDFloat;
typedef UInt32   IOOptionBits;
typedef uint32_t IOHIDEventOptionBits;
typedef uint32_t IOHIDEventField;
typedef kern_return_t IOReturn;
typedef uint32_t IOHIDDigitizerEventMask;   /* 定义在 IOHIDEventTypes.h，本头文件里是 enum */
typedef uint32_t IOHIDEventType;

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDEvent             *IOHIDEventRef;

#define IOHIDEventFieldBase(type) (type << 16)

/* ---- 事件构造 ---- */
IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t, IOHIDDigitizerTransducerType,
        uint32_t, uint32_t, IOHIDDigitizerEventMask, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat,
        IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits);

IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(
        CFAllocatorRef allocator,
        uint64_t       timeStamp,
        uint32_t       index,
        uint32_t       identity,
        IOHIDDigitizerEventMask eventMask,
        IOHIDFloat     x,
        IOHIDFloat     y,
        IOHIDFloat     z,
        IOHIDFloat     tipPressure,
        IOHIDFloat     twist,
        boolean_t      range,
        boolean_t      touch,
        IOOptionBits   options);

IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef, uint64_t, uint32_t /*usagePage*/,
        uint32_t /*usage*/, boolean_t /*isDown*/, IOOptionBits);

IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
        uint32_t, uint8_t *, CFIndex, IOHIDEventOptionBits);

IOHIDEventRef IOHIDEventCreateForceEvent(CFAllocatorRef, uint64_t, uint32_t, IOHIDFloat,
        uint32_t, IOHIDFloat, IOHIDEventOptionBits);

IOHIDEventRef IOHIDEventCreateAccelerometerEvent(CFAllocatorRef, uint64_t, IOHIDFloat, IOHIDFloat,
        IOHIDFloat, IOOptionBits);

IOHIDEventRef IOHIDEventCreateDigitizerStylusEventWithPolarOrientation(CFAllocatorRef, uint64_t,
        uint32_t, uint32_t, IOHIDDigitizerEventMask, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat,
        IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t,
        IOHIDEventOptionBits);

/* ---- 事件读写 / 组合 ---- */
IOHIDEventType IOHIDEventGetType(IOHIDEventRef);
uint64_t       IOHIDEventGetTimeStamp(IOHIDEventRef event);
void           IOHIDEventSetTimeStamp(IOHIDEventRef event, uint64_t timeStamp);
CFArrayRef     IOHIDEventGetChildren(IOHIDEventRef event);
CFIndex        IOHIDEventGetIntegerValue(IOHIDEventRef, IOHIDEventField);
void           IOHIDEventSetIntegerValue(IOHIDEventRef, IOHIDEventField, CFIndex);
IOHIDFloat     IOHIDEventGetFloatValue(IOHIDEventRef event, IOHIDEventField field);
void           IOHIDEventSetFloatValue(IOHIDEventRef event, IOHIDEventField field, IOHIDFloat value);
void           IOHIDEventSetSenderID(IOHIDEventRef, uint64_t);
void           IOHIDEventAppendEvent(IOHIDEventRef, IOHIDEventRef, IOOptionBits);

/* ---- 系统客户端 ---- */
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef client,
        IOHIDEventSystemClientEventCallback callback, void *target, void *refcon);
void IOHIDEventSystemClientUnregisterEventCallback(IOHIDEventSystemClientRef client);
void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef client,
        CFRunLoopRef runloop, CFStringRef mode);
void IOHIDEventSystemClientUnscheduleWithRunLoop(IOHIDEventSystemClientRef client,
        CFRunLoopRef runloop, CFStringRef mode);
```

**枚举与字段偏移**（同一头文件，✅ 已查证）：

```c
/* IOHIDEventType */
kIOHIDEventTypeNULL = 0, kIOHIDEventTypeVendorDefined, kIOHIDEventTypeKeyboard = 3,
kIOHIDEventTypeRotation = 5, kIOHIDEventTypeScroll = 6, kIOHIDEventTypeZoom = 8,
kIOHIDEventTypeDigitizer = 11, kIOHIDEventTypeNavigationSwipe = 16, kIOHIDEventTypeForce = 32

/* digitizer 事件掩码 */
kIOHIDDigitizerEventRange   = 1 << 0,
kIOHIDDigitizerEventTouch   = 1 << 1,
kIOHIDDigitizerEventPosition= 1 << 2,
kIOHIDDigitizerEventIdentity= 1 << 5,
kIOHIDDigitizerEventAttribute = 1 << 6,
kIOHIDDigitizerEventCancel  = 1 << 7,
kIOHIDDigitizerEventStart   = 1 << 8

/* digitizer 字段（IOHIDEventFieldBase(type) == type << 16） */
kIOHIDEventFieldDigitizerX              = 0xB0000   /* 11 << 16 */
kIOHIDEventFieldDigitizerY              = 0xB0001
kIOHIDEventFieldDigitizerType           = 0xB0004   /* X + 4 */
kIOHIDEventFieldDigitizerIndex          = 0xB0005
kIOHIDEventFieldDigitizerIdentity       = 0xB0006
kIOHIDEventFieldDigitizerEventMask      = 0xB0007
kIOHIDEventFieldDigitizerRange          = 0xB0008
kIOHIDEventFieldDigitizerTouch          = 0xB0009
kIOHIDEventFieldDigitizerPressure       = 0xB000A
kIOHIDEventFieldDigitizerMajorRadius    = 0xB0014   /* X + 20 */
kIOHIDEventFieldDigitizerMinorRadius    = 0xB0015
kIOHIDEventFieldDigitizerIsDisplayIntegrated = 0xB0019  /* MajorRadius + 5 */
kIOHIDEventFieldIsBuiltIn               = 0x4       /* IOHIDEventFieldBase(kIOHIDEventTypeNULL) + 4 */

/* digitizer transducer 类型（IOHIDDigitizerTransducerType） */
kIOHIDDigitizerTransducerTypeHand / kIOHIDDigitizerTransducerTypeFinger / kIOHIDDigitizerTransducerTypeStylus
```

> **交叉验证**：ZXTouch 的源码里直接写了裸常数 `0xb0014`（major radius）、`0xb0015`（minor radius）、`0xb0019`（isDisplayIntegrated）、`0x4`（isBuiltIn），与上面的偏移算术**完全吻合** —— 这是这两份独立实现互相印证的好信号。✅

### 3.3 实测调用序列

**(A) ZXTouch 的做法（一次触摸 = 1 个 parent + N 个 child）** ✅ 已查证：
[IOS13-SimulateTouch/pccontrol/Touch.xm](https://github.com/xuan32546/IOS13-SimulateTouch/blob/master/pccontrol/Touch.xm)

```objc
/* 手指子事件：down / move / up 只差 eventMask 与 range/touch 标志 */
IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, mach_absolute_time(),
        index,          /* 手指编号 */
        3,              /* identity */
        3,              /* eventMask: down = (Range|Touch) = 3 */
        x / device_screen_width,   /* 归一化 0..1 的 X */
        y / device_screen_height,  /* 归一化 0..1 的 Y */
        0.0f, 0.0f, 0.0f,
        1,              /* range  */
        1,              /* touch  */
        0);             /* options */
IOHIDEventSetFloatValue(child, 0xb0014, 0.04f);   /* major radius */
IOHIDEventSetFloatValue(child, 0xb0015, 0.04f);   /* minor radius */
/* move 版： eventMask = 4，range/touch 仍为 1 */
/* up  版： eventMask = 2，range/touch 改为 0 */

/* 父事件（集合） */
IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, mach_absolute_time(),
        3,    /* transducerType */
        99,   /* index */
        1,    /* eventMask */
        0, 0, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
        0,    /* range  */
        0,    /* touch  */
        0);   /* options */
IOHIDEventSetIntegerValue(parent, 0xb0019, 1);   /* IsDisplayIntegrated = 1 */
IOHIDEventSetIntegerValue(parent, 0x4,     1);   /* IsBuiltIn = 1 */
IOHIDEventSetIntegerValue(parent, 0xb0007, 0x23);/* EventMask */
IOHIDEventSetIntegerValue(parent, 0xb0008, 0x1); /* Range */
IOHIDEventSetIntegerValue(parent, 0xb0009, 0x1); /* Touch */

IOHIDEventAppendEvent(parent, child);
IOHIDEventSetSenderID(parent, senderID);                     /* 见下 */
IOHIDEventSystemClientDispatchEvent(ioSystemClient, parent); /* 全局投递 */
```

**(B) XXTouch 的做法** ✅ 已查证：
[touch/hid/STHIDEventGenerator.m](https://github.com/XXTouchNG/XXTouchNG/blob/master/touch/hid/STHIDEventGenerator.m)

```objc
static void _sendHIDEvent(IOHIDEventRef eventRef) {
    static IOHIDEventSystemClientRef _ioSystemClient = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _ioSystemClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    });
    if (eventRef) {
        IOHIDEventRef strongEvent = (IOHIDEventRef)CFRetain(eventRef);
        dispatch_async(dispatch_get_main_queue(), ^{
            IOHIDEventSetSenderID(strongEvent, 0x8000000817319372);
            IOHIDEventSystemClientDispatchEvent(_ioSystemClient, strongEvent);
            CFRelease(strongEvent);
        });
    }
}
/* 每个 child 上再设置： */
IOHIDEventSetIntegerValue(eventRef, kIOHIDEventFieldIsBuiltIn, 1);
IOHIDEventSetIntegerValue(eventRef, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
```

要点：
- **在 main queue 上 dispatch**（XXTouch 明确这么做）；`mach_absolute_time()` 做时间戳。
- 坐标是**归一化到 0..1 的屏幕比例**，不是像素。
- `IOHIDEventSetSenderID` 用来伪造事件来源 ID。ZXTouch 更讲究：它先用一个 **monitor 客户端**（`IOHIDEventSystemClientRegisterEventCallback` + `IOHIDEventSystemClientScheduleWithRunLoop`）截获一次真实硬件 digitizer 事件的 senderID，缓存到 `senderid.plist`（重启后失效需重学），再把这个 senderID 打到伪造事件上。✅ 已查证（Touch.xm）。

**键盘/文字输入**：`IOHIDEventCreateKeyboardEvent(alloc, mach_absolute_time(), usagePage, usage, isKeyDown, options)`，`usagePage` 用 `kHIDPage_KeyboardOrKeypad (0x07)`。✅ 已查证（XXTouch `_sendIOHIDKeyboardEvent:`）。要注意这走的是 **HID 层**，能否上屏取决于当前是否有输入焦点；输入中文/非 ASCII 基本走不通，实务上更常用"往有焦点的输入框粘贴"（`UIPasteboard` + `paste:`，或直接改 `UITextField` 文本）。

### 3.4 需要的 entitlements（✅ 已查证，这是本节最有价值的产出）

XXTouch 的 touch daemon 的**完整** entitlements 文件：
[touch/cli/ent.plist](https://github.com/XXTouchNG/XXTouchNG/blob/master/touch/cli/ent.plist)

```xml
<key>platform-application</key><true/>
<key>get-task-allow</key><true/>
<key>task_for_pid-allow</key><true/>
<key>proc_info-allow</key><true/>
<key>run-unsigned-code</key><true/>
<key>vm-pressure-level</key><true/>
<key>application-identifier</key><string>ch.xxtou.simulatetouchd</string>
<key>com.apple.private.security.no-container</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
<key>com.apple.private.security.container-required</key><false/>
<key>com.apple.private.skip-library-validation</key><true/>
<!-- Jetsam -->
<key>com.apple.private.kernel.jetsam</key><true/>
<key>com.apple.private.memorystatus</key><true/>
<!-- IOHID  ← 关键 -->
<key>com.apple.private.hid.manager.client</key><true/>
<key>com.apple.private.hid.client.event-dispatch</key><true/>
<key>com.apple.private.hid.client.event-filter</key><true/>
<key>com.apple.private.hid.client.event-monitor</key><true/>
<key>com.apple.private.hid.client.service-protected</key><true/>
<key>com.apple.private.applesepmanager.allow</key><true/>
<key>com.apple.gasgauge.user-access-device</key><true/>
<key>com.apple.security.iokit-user-client-class</key>
<array>
  <string>IOSurfaceAcceleratorClient</string>
  <string>IOMobileFramebufferUserClient</string>
  <string>IOSurfaceRootUserClient</string>
</array>
<key>com.apple.CommCenter.fine-grained</key><array><string>spi</string></array>
```

- **`com.apple.private.hid.client.event-dispatch`** 是 dispatch 的钥匙；`event-monitor` 是抓真实事件学 senderID 用的。
- `com.apple.private.skip-library-validation` 对 rootless/roothide 下加载非标准路径的 dylib 很关键。
- 签名方式（✅ 已查证 [touch/Makefile](https://github.com/XXTouchNG/XXTouchNG/blob/master/touch/Makefile)）：
  ```make
  ifeq ($(TARGET_CODESIGN),ldid)
  simulatetouchd_CODESIGN_FLAGS = -Scli/ent.plist
  else
  simulatetouchd_CODESIGN_FLAGS = --entitlements cli/ent.plist $(TARGET_CODESIGN_FLAGS)
  endif
  ```
  即 `ldid -S<plist>`；daemon 的 launchd plist 用 `UserName=root`、`RunAtLoad`、`KeepAlive`、`HighPriorityIO`、`ProcessType=Interactive`（✅ 已查证 `touch/layout/Library/LaunchDaemons/ch.xxtou.simulatetouchd.plist`）。

对比 ZXTouch 的 dylib entitlements（少得多，✅ 已查证 [layout/entitlements.plist](https://github.com/xuan32546/IOS13-SimulateTouch/blob/master/layout/entitlements.plist)）：
```xml
<key>platform-application</key><true/>
<key>com.apple.private.skip-library-validation</key><true/>
<key>com.apple.private.security.no-container</key><true/>
```
—— **注意它没有 HID entitlement 却能 dispatch**。合理解释：它运行在已由系统背书的宿主进程（SpringBoard / App）里，用的是宿主进程已获得的 HID 访问权。🟡 这是我从两份 entitlements 差异做的推断，**未查证**；如你在自己的 daemon 里遇到 dispatch 失败，先补 §3.4 的 HID 键。

### 3.5 RootHide / Dopamine 下的限制

- ✅ 已查证（[roothide/Developer/entitlements.md](https://github.com/roothide/Developer/blob/main/entitlements.md)）：
  - jailbreak 的二进制**默认是被沙盒化的**，需要 `platform-application` + `com.apple.private.security.no-sandbox` + `storage.AppBundles` + `storage.AppDataContainers`。
  - **`jbroot:/var/` 或 `jbroot:/tmp/` 里的 Mach-O（可执行/dylib/framework）无法被加载**（iOS 安全机制），必须放在 jbroot 其它目录。→ 你的 daemon 二进制和 tweak dylib **不要**放 `/var/`。
  - tweak 默认只能写 jbroot 下的 `/var/`；要写别处得靠 daemon 代劳。
- AutoTouch（原始版）是**应用内/AutoTouch 自身进程**的方案（旧版 iOS、rootful 时代的产物），在 Dopamine/RootHide 下不能直接照搬：它依赖 rootfs 的固定路径与旧的注入点。🟡 我**没有**找到 AutoTouch 在 Dopamine rootless 下可用性的一手证据（其源码仓 `Aethereux/AutoTouch` 仅 3 星、无文档），**标为未查证**。
- `libhooker`/`ElleKit`：Dopamine 用 ElleKit 做 hooking；substrate 兼容层可用（上述所有 tweak 都 `Depends: mobilesubstrate`）。🟡 部分查证（来自各 tweak 的 `control` 文件）。

### 3.6 关于 `IOHIDEventSystemClientCreateWithType`（你点名问的符号）

- ❌ **未查证**：我没有找到任何 iOS 15/16 的一手实现使用 `IOHIDEventSystemClientCreateWithType`。XXTouch 与 ZXTouch 都用 `IOHIDEventSystemClientCreate`。
- 🟡 该符号及其配套 `kIOHIDEventSystemClientTypeMonitor` / `kIOHIDEventSystemClientTypeAdministrator` 属于 Apple 内部 SDK 头 `IOHIDEventSystemClient.h`（不在 iOS SDK，也不在 [apple-oss-distributions/IOHIDFamily](https://github.com/apple-oss-distributions/IOHIDFamily) 的公开头文件里 —— 我枚举过该仓库，只有 `IOHIDFamily/IOHIDEvent.h` 与 `IOHIDFamily/IOHIDEventData.h`，`SystemClient` 只在 `HID/Headers/HIDEventSystemClient.h` 里出现，且那是另一套 API 形态）。
- **建议**：直接用 `IOHIDEventSystemClientCreate`，它已被两份生产实现验证。若你确实需要 `...CreateWithType`，用 `dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateWithType")` 探查，别静态链接。

### 3.7 纯 ObjC 方案（PTFakeTouch / KIF）的边界

✅ 已查证 [xuanxt/PTFakeTouch/PTFakeMetaTouch.m](https://github.com/xuanxt/PTFakeTouch/blob/master/PTFakeTouch/PTFakeMetaTouch.m)：它构造伪 `UITouch`，通过私有 `[[UIApplication sharedApplication] _touchesEvent]` + `_clearTouches` + `_addTouch:forDelayedDelivery:` 组装 `UIEvent`，再 `[[UIApplication sharedApplication] sendEvent:event]`。

- 优点：不需要任何 entitlement。
- 致命限制：**必须注入到目标 App 进程**；事件不跨进程，"全局点击"做不到；对系统 UI（SpringBoard）和自己进程外的窗口无效。→ 对你的 AI Agent 需求**不适用**，只适合"注入单个 App 后操控该 App"。

---

## 4. 主题 2：读取前台 App 的 UI / 无障碍树

### 4.1 结论（重要）

**你点名的 C 函数 `AXUIElementCreateSystemWide` / `AXUIElementCopyAttributeValue` / `AXUIElementCreateApplication` 在 iOS 上属于私有/不可用范畴**：

- ✅ 已查证：Apple 官方文档把 `AXUIElement` 与 `AXUIElementCopyAttributeValue(_:_:_:)` 归到 **Application Services / macOS 10.2+**：
  - <https://developer.apple.com/documentation/applicationservices/axuielement>
  - <https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue>
- ✅ 已查证：**iPhoneOS 16.5 SDK 里不存在** `ApplicationServices.framework/Headers/AXUIElement.h`、`ApplicationServices.framework/Frameworks/HIServices.framework/Headers/AXUIElement.h`，也不存在公开的 `PrivateFrameworks/AXRuntime.framework/Headers/`（我逐个路径探测 `xybp888/iOS-SDKs` 得到 MISSING）。
- 对应签名（🟡 **部分查证**：名字与所属框架已确认；完整原型我未能从 Apple 文档逐字取到 Create* 两函数的条目，下列为通用声明，请在 macOS SDK 头文件上二次核对）：
  ```c
  AXUIElementRef AXUIElementCreateSystemWide(void);
  AXUIElementRef AXUIElementCreateApplication(pid_t pid);
  AXError AXUIElementCopyAttributeValue(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value);
  AXError AXUIElementCopyElementAtPosition(AXUIElementRef application, float x, float y, AXUIElementRef *element);
  ```

### 4.2 iOS 上实际可用的私有路径：`AXRuntime.framework` 的 ObjC 类

✅ 已查证（iOS 私有头文件转储 [nst/iOS-Runtime-Headers](https://github.com/nst/iOS-Runtime-Headers)）：

**`/System/Library/PrivateFrameworks/AXRuntime.framework` → `AXElement`**（这是 iOS 侧最实用的"读 UI 树 + 点元素"入口）
[PrivateFrameworks/AXRuntime.framework/AXElement.h](https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/AXRuntime.framework/AXElement.h)

```objc
@interface AXElement : NSObject <AXGroupable>
/* 类方法 */
+ (id)systemWideElement;
+ (id)primaryApp;
+ (id)elementAtCoordinate:(CGPoint)p withVisualPadding:(BOOL)pad;
+ (id)elementWithAXUIElement:(struct __AXUIElement *)e;
+ (id)elementWithUIElement:(id)uiElement;
+ (id)elementsWithUIElements:(id)uiElements;
+ (void)registerNotifications:(id)a withIdentifier:(id)b withHandler:(void (^)(void))c;
+ (void)unregisterNotifications:(id)a;

/* 只读属性（节选，全量见头文件） */
@property (nonatomic, readonly) NSArray    *children;
@property (nonatomic, readonly) CGRect      frame;
@property (nonatomic, readonly) CGRect      cachedFrame;
@property (nonatomic, readonly) CGPoint     centerPoint;
@property (nonatomic, readonly) NSString   *label;
@property (nonatomic, readonly) NSString   *identifier;
@property (nonatomic, readonly) NSString   *hint;
@property (nonatomic)           NSString   *value;
@property (nonatomic, readonly) NSString   *bundleId;
@property (nonatomic, readonly) int         pid;
@property (nonatomic, readonly) NSString   *processName;
@property (nonatomic, readonly) NSArray    *currentApplications;
@property (nonatomic, readonly) AXElement  *currentApplication;
@property (nonatomic, readonly) AXElement  *application;
@property (nonatomic, readonly) AXElement  *springBoardApplication;
@property (nonatomic, readonly) AXElement  *firstResponder;
@property (nonatomic, readonly) bool        isSystemWideElement;
@property (nonatomic, readonly) bool        isSpringBoard;
@property (nonatomic, readonly) bool        isVisible;
@property (nonatomic, readonly) unsigned long long traits;
@property (nonatomic, readonly) struct __AXUIElement *elementRef;

/* 动作 */
- (BOOL)press;
- (BOOL)longPress;
- (BOOL)performAction:(int)action;
- (BOOL)performAction:(int)action withValue:(id)value;
- (BOOL)canScrollInAtLeastOneDirection;
- (void)autoscrollInDirection:(unsigned long long)direction;
@property (nonatomic, readonly) NSArray *supportedGestures;
@property (nonatomic, readonly) NSArray *customActions;
@property (nonatomic, readonly) NSArray *textOperations;
- (BOOL)isAccessibleElement;
- (BOOL)isValid;
@end
```

**`AXUIElement`（ObjC 类，同名于 C 类型但完全不同）**
[PrivateFrameworks/AXRuntime.framework/AXUIElement.h](https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/AXRuntime.framework/AXUIElement.h)

```objc
@interface AXUIElement : NSObject <UIElementProtocol>
+ (struct __AXUIElement *)systemWideAXUIElement;
+ (id)uiApplicationAtCoordinate:(CGPoint)p;
+ (id)uiApplicationForContext:(unsigned int)contextId;
+ (id)uiElementAtCoordinate:(CGPoint)p;
+ (id)uiElementAtCoordinate:(CGPoint)p forApplication:(struct __AXUIElement *)app contextId:(unsigned int)ctx;
+ (id)uiElementAtCoordinate:(CGPoint)p startWithElement:(id)element;
+ (id)uiElementWithAXElement:(struct __AXUIElement *)e;
+ (id)uiSystemWideApplication;

- (BOOL)performAXAction:(int)action;
- (BOOL)performAXAction:(int)action withValue:(id)value;
- (BOOL)canPerformAXAction:(int)action;
- (id)uiElementsWithAttribute:(long long)attr;
- (id)uiElementsWithAttribute:(long long)attr parameter:(void *)param;
- (id)objectWithAXAttribute:(long long)attr;
- (id)stringWithAXAttribute:(long long)attr;
- (id)numberWithAXAttribute:(long long)attr;
- (CGRect)rectWithAXAttribute:(long long)attr;
- (CGPoint)pointWithAXAttribute:(long long)attr;
- (int)pid;
- (struct __AXUIElement *)axElement;
@end
```

> 典型调用方式（🟡 基于上述头文件的组合，**我未在真机验证**）：
> ```objc
> Class AXE = objc_getClass("AXElement");
> id sysWide  = [AXE systemWideElement];
> id app      = [sysWide currentApplication];       // 前台 App
> NSArray *kids = [app children];                   // 递归遍历
> CGRect f     = [[kids firstObject] frame];
> BOOL ok      = [[kids firstObject] press];        // 直接触发元素动作（优于坐标点击）
> ```
> 也可以"坐标 → 元素"：`[AXE elementAtCoordinate:CGPointMake(x,y) withVisualPadding:NO]`。

**更可靠的替代方案**：先用 `AXElement` 遍历树拿到元素的 **`frame` / `centerPoint`**，再用 §3 的 IOHID 合成点击去打那个坐标。这样组合的鲁棒性最好（AX 树负责"知道点哪"，HID 负责"真的点下去"）。我看到的真实产品也是这么分工的。

### 4.3 CLI 便利工具：`axaudit` / `Accessibility Inspector`

❌ **未查证**：我没有验证 iOS 上是否随系统提供可用于脚本化的 AX inspector（macOS 上是 `Accessibility Inspector.app`）。别依赖它。

### 4.4 权限 / entitlement（**这一项我明确没查证**）

- ❌ **未查证**：我没有找到 iOS 15/16 上使用 `AXElement`/`AXUIElement` 所需要的 **确切 entitlement 名称或授权方式**。我尝试的多条代码搜索通道全部不可用（见 §0），因此**不给你猜测性的键名**。
- ✅ 唯一相关的一手旁证：XXTouch 的 daemon entitlements 里有一批 `com.apple.private.hid.client.*`，但**没有任何 `accessibility` 相关键**——说明该 HID 方案不需要 AX 权限，而不能反推 AX 需要什么。
- **验证方法（请自己做，5 分钟）**：
  ```bash
  # 在越狱设备上 dump 系统 AX 相关进程的 entitlements
  ldid -e /usr/libexec/assistivetouchd
  ldid -e /System/Library/CoreServices/SpringBoard.app/SpringBoard
  # 或 rootless 前置：/var/jb/usr/bin/ldid -e ...
  # 观察是否有 com.apple.private.accessibility* / com.apple.accessibility.* / axserver 之类
  ```
  然后用 `dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime")` + `NSClassFromString(@"AXElement")` 在一个**注入 SpringBoard 的 tweak**里做最小实验：先试 `+systemWideElement` 能否返回非 nil 且 `children` 非空；不行就把该 tweak 的 entitlements 对齐 `assistivetouchd` 再试。

---

## 5. 主题 3：从 daemon 启动 App / 列出所有 App

### 5.1 `LSApplicationWorkspace`（推荐）✅ 已查证

**归属框架纠正**：`LSApplicationWorkspace` 在 **`/System/Library/Frameworks/CoreServices.framework`**（我枚举 `nst/iOS-Runtime-Headers` 时，`LSApplicationWorkspace.h` / `LSApplicationProxy.h` 都在 `Frameworks/CoreServices.framework/` 下，而 `MobileCoreServices` 下没有）。🟡 历史上 iOS 早期它在 MobileCoreServices 里，你的记忆来自那个时代。

精确方法列表（节选，来自转储头文件）：
[Frameworks/CoreServices.framework/LSApplicationWorkspace.h](https://github.com/nst/iOS-Runtime-Headers/blob/master/Frameworks/CoreServices.framework/LSApplicationWorkspace.h)

```objc
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;

- (id)allApplications;                 // NSArray<LSApplicationProxy *> *
- (id)allInstalledApplications;
- (id)installedPlugins;
- (id)placeholderApplications;
- (void)enumerateApplicationsOfType:(unsigned long long)type block:(void (^)(id))block;
- (void)enumerateApplicationsOfType:(unsigned long long)type legacySPI:(bool)legacy block:(void (^)(id))block;
- (bool)applicationIsInstalled:(id)bundleIdentifier;
- (id)applicationsAvailableForHandlingURLScheme:(id)scheme;
- (id)applicationsAvailableForOpeningURL:(id)url;
- (bool)openApplicationWithBundleID:(id)bundleIdentifier;      // ← 启动 App
- (bool)openURL:(id)url;
- (bool)openURL:(id)url withOptions:(id)options;
- (bool)openSensitiveURL:(id)url withOptions:(id)options;
- (bool)openSensitiveURL:(id)url withOptions:(id)options error:(id *)error;
- (bool)installApplication:(id)ipa withOptions:(id)options error:(id *)error;
- (bool)uninstallApplication:(id)bundleID withOptions:(id)options;
- (bool)invalidateIconCache:(id)arg1;
@end
```

一份更精简、面向 Theos 的声明（✅ 已查证，来自 XXTouch 实际使用的头）
[shared/include/LSApplicationWorkspace.h](https://github.com/XXTouchNG/XXTouchNG/blob/master/shared/include/LSApplicationWorkspace.h)：

```objc
@interface LSApplicationWorkspace : NSObject
+ (LSApplicationWorkspace *)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
- (BOOL)installApplication:(NSURL *)ipaPath withOptions:(id)arg2 error:(NSError **)error;
- (BOOL)uninstallApplication:(NSString *)bundleIdentifier withOptions:(id)arg2;
- (BOOL)invalidateIconCache:(id)arg1;
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(id)arg2 error:(NSError **)error;
@end
```

**列出所有已安装 App 的 bundle id**（🟡 组合示例，基于上述已验证签名）：
```objc
for (LSApplicationProxy *p in [[LSApplicationWorkspace defaultWorkspace] allApplications]) {
    NSLog(@"%@ | %@ | %@ | %@", [p applicationIdentifier], [p localizedName],
          [p applicationType], [p bundleContainerURL]);
}
```
`LSApplicationProxy` 关键成员（✅ 已查证 [LSApplicationProxy.h](https://github.com/nst/iOS-Runtime-Headers/blob/master/Frameworks/CoreServices.framework/LSApplicationProxy.h)）：
```objc
+ (id)applicationProxyForIdentifier:(id)bundleID;
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *applicationType;      // 如 "User" / "System"
@property (nonatomic, readonly) NSString *shortVersionString;
@property (getter=isDeletable, nonatomic, readonly) bool deletable;
@property (getter=isPlaceholder, nonatomic, readonly) bool placeholder;
@property (getter=isRestricted, nonatomic, readonly) bool restricted;
- (id)localizedNameForContext:(id)ctx;
- (id)dataContainerURL;   // 注：XXTouch 的精简头里有，转储头文件里是 container 系列方法
- (NSArray<LSPlugInKitProxy *> *)plugInKitPlugins;
```

### 5.2 `SBSLaunchApplicationWithIdentifier`（你点名的符号）✅ 已查证的事实

**`theos/headers` 里的 SpringBoardServices 头文件并不导出这个单参数符号**，它导出的是：
[theos/headers/SpringBoardServices/SpringBoardServices.h](https://github.com/theos/headers/blob/master/SpringBoardServices/SpringBoardServices.h)

```objc
FOUNDATION_EXPORT mach_port_t SBSSpringBoardServerPort();
FOUNDATION_EXPORT void SBFrontmostApplicationDisplayIdentifier(mach_port_t port, char *result);
FOUNDATION_EXPORT NSString *SBSCopyFrontmostApplicationDisplayIdentifier();
FOUNDATION_EXPORT void SBGetScreenLockStatus(mach_port_t port, BOOL *lockStatus, BOOL *passcodeEnabled);
FOUNDATION_EXPORT void SBSUndimScreen();

FOUNDATION_EXPORT int SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions(
        NSString *bundleIdentifier, NSURL *url, NSDictionary *appOptions,
        NSDictionary *launchOptions, BOOL suspended);
FOUNDATION_EXPORT int SBSLaunchApplicationWithIdentifierAndLaunchOptions(
        NSString *bundleIdentifier, NSDictionary *appOptions,
        NSDictionary *launchOptions, BOOL suspended);
FOUNDATION_EXPORT bool SBSOpenSensitiveURLAndUnlock(CFURLRef url, char flags);
FOUNDATION_EXPORT NSString *const SBSApplicationLaunchOptionUnlockDeviceKey;
```

- 🟡 很多老 tweak 里写着 `extern int SBSLaunchApplicationWithIdentifier(CFStringRef, Boolean);` 也能编过并能跑（动态符号查找），但它**不在当前 theos 头文件里**，属于老符号；iOS 15/16 上是否仍导出 ❌ **未查证**。
- **建议**：优先 `LSApplicationWorkspace -openApplicationWithBundleID:`（纯 ObjC，跨版本稳定，且 XXTouch 在 iOS 13–16 上就是这么用的）；需要"不解锁就前台打开/带 URL 和 launch options"时再用 `SBSLaunchApplicationWithIdentifierAndLaunchOptions`。
- **注意**：`openApplicationWithBundleID:` 等从**非 GUI 会话的 root daemon** 里调用能否真正把 App 拉到前台，取决于你进程是否有前台启动的授权（`SBSLaunchApplicationWithIdentifierAndLaunchOptions` 的最后那个 `suspended` 参数、以及 SpringBoard 的授权校验）。❌ **未查证**：我没有找到"daemon 直接 open 能否成功"的一手结论。**稳妥做法**：把"启动 App"这一步也交给注入 SpringBoard 的 tweak（daemon 通过 CFMessagePort 请求它，见 §7.3）。
- **前台 App 查询**（✅ 已查证符号）：`SBSCopyFrontmostApplicationDisplayIdentifier()` / `SBFrontmostApplicationDisplayIdentifier(port, buf)`；另有 `SBGetScreenLockStatus(port, &locked, &passcodeEnabled)` 可判断锁屏。

### 5.3 Rootless / RootHide 注意事项

- ✅ 已查证：RootHide 的 bootstrap 里 CLI 只接受 jbroot 相对路径，真正 rootfs 在 `jbroot/rootfs`；jailbreak 二进制默认沙盒化，需要 `platform-application` 等 entitlements。
- ✅ 已查证：XXTouch 用 `uicache`（Procursus 提供）来刷新 App 列表/图标缓存（roothide.md 里点名 `uicache` 是 bootstrap 自带工具之一）。
- 若你的 daemon 要写 App 容器（例如往目标 App 的 Documents 放文件），RootHide 下 tweak 写不了，得 **daemon 代写**（roothide 官方文档明说）。✅

---

## 6. 主题 4：从 daemon 发"用户可见"通知

### 6.1 结论

**能在 iOS 15/16 的 rootless daemon 里直接弹出可见 UI 的方案，我一条都没有查到可靠证据；所有成熟产品都是"daemon → IPC → 注入到 UIKit 进程的 tweak → 由 tweak 弹 UI"。**

### 6.2 逐方案对比

| 方案 | 可见 UI？ | 从 daemon 可用？ | 证据 |
|---|---|---|---|
| `CFUserNotificationCreate` / `DisplayAlert` / `DisplayNotice` | **是**（有 UI），但**要求调用进程有 GUI/WindowServer 会话** | 🟡 在**注入进程**里可行（XXTouch AlertHelper 就这么用）；**从纯 daemon 未查证，且大概率不显示** | ✅ 签名已查证；🟡 daemon 侧未查证 |
| `UNUserNotificationCenter` | 是（横幅） | ❌ 对非安装 App 的二进制通常会失败（`UNErrorCodeNotificationsNotAllowed`），需要 bundle + 授权 | ❌ **未查证**（我未找到 iOS 15/16 的一手测试报告，**不要依赖**） |
| `SBSNotification` 系列 | — | — | ❌ **未查证**：我没能在 `theos/headers` 或私有头转储里确认存在名为 `SBSNotification`/`SBSNotificationRequest` 的可用符号。**不要按这个假设写代码**。 |
| `libnotify` / `notifyutil` / `notify_post` | **否，纯 IPC** | 可 | ✅ 已查证（见下） |
| `CFMessagePort` + rocketbootstrap | 否，纯 IPC（但是**正确方案的管道**） | 可 | ✅ 已查证 |
| 注入 SpringBoard/UIKit 的 tweak 里用 `UIAlertController` / `CFUserNotification` | **是** | 需 daemon 先 IPC 请求它 | ✅ 已查证（两种产品都这么做） |

### 6.3 `CFUserNotification` 确切签名（✅ 已查证，Apple 开源）

来源：Apple 开源 CoreFoundation 头文件 [apple-oss-distributions/CF/CFUserNotification.h](https://github.com/apple-oss-distributions/CF/blob/main/CFUserNotification.h)

```c
typedef struct __CFUserNotification *CFUserNotificationRef;
typedef void (*CFUserNotificationCallBack)(CFUserNotificationRef userNotification,
                                           CFOptionFlags responseFlags);

CFUserNotificationRef CFUserNotificationCreate(CFAllocatorRef allocator,
                                               CFTimeInterval timeout,
                                               CFOptionFlags flags,
                                               SInt32 *error,
                                               CFDictionaryRef dictionary);

SInt32 CFUserNotificationReceiveResponse(CFUserNotificationRef userNotification,
                                         CFTimeInterval timeout,
                                         CFOptionFlags *responseFlags);

CFStringRef     CFUserNotificationGetResponseValue(CFUserNotificationRef n, CFStringRef key, CFIndex idx);
CFDictionaryRef CFUserNotificationGetResponseDictionary(CFUserNotificationRef n);
SInt32          CFUserNotificationUpdate(CFUserNotificationRef n, CFTimeInterval timeout,
                                         CFOptionFlags flags, CFDictionaryRef dictionary);
SInt32          CFUserNotificationCancel(CFUserNotificationRef userNotification);
CFRunLoopSourceRef CFUserNotificationCreateRunLoopSource(CFAllocatorRef allocator,
                                        CFUserNotificationRef n,
                                        CFUserNotificationCallBack callout, CFIndex order);
SInt32 CFUserNotificationDisplayNotice(CFTimeInterval timeout, CFOptionFlags flags,
        CFURLRef iconURL, CFURLRef soundURL, CFURLRef localizationURL,
        CFStringRef alertHeader, CFStringRef alertMessage, CFStringRef defaultButtonTitle);
SInt32 CFUserNotificationDisplayAlert(CFTimeInterval timeout, CFOptionFlags flags,
        CFURLRef iconURL, CFURLRef soundURL, CFURLRef localizationURL,
        CFStringRef alertHeader, CFStringRef alertMessage,
        CFStringRef defaultButtonTitle, CFStringRef alternateButtonTitle,
        CFStringRef otherButtonTitle, CFOptionFlags *responseFlags);
```

**一手使用证据**：XXTouch 的 `AlertHelper`（一个被注入到**所有链接 UIKit 的进程**的 tweak，filter 是 `Bundles = ("com.apple.UIKit")`）里：
[alert/AlertHelper.mm](https://github.com/XXTouchNG/XXTouchNG/blob/master/alert/AlertHelper.mm)

```objc
__global_AlertHelperDialogNotification =
    CFUserNotificationCreate(kCFAllocatorSystemDefault,
                             timeout < 0.1 ? 0 : timeout,
                             flags, &error, dialogDict);
/* 需要关闭时： */
CFUserNotificationCancel(__global_AlertHelperDialogNotification);
```
✅ 这说明：**在 iOS 15/16 上，`CFUserNotificationCreate` 在注入进程里是可用的**（该 tweak 的 target 是 iOS 13–16），并且用 `Create` + 一个 dialog dictionary 才能拿到可编程控制（而不是用 `DisplayAlert` 一把梭）。

### 6.4 推荐的落地模式（✅ 架构已由两个产品验证）

```
┌────────────────────┐   rocketbootstrap CFMessagePort / XPC    ┌──────────────────────┐
│ LaunchDaemon(root) │ ───────────────────────────────────────► │ tweak in UIKit procs │
│  "要弹个提示"       │                                          │  (或只注入 SpringBoard) │
└────────────────────┘ ◄─────────────────────────────────────── └──────────────────────┘
                                                                  UIAlertController /
                                                                  CFUserNotification
```

一手证据：
- **iolate/SimulateTouch** 用 `rocketbootstrap_cfmessageportcreateremote(NULL, CFSTR("kr.iolate.simulatetouch"))` + `CFMessagePortSendRequest(...)` 从客户端把事件送给持有 HID 权限的一方。✅ 已查证 [STLibrary.mm](https://github.com/iolate/SimulateTouch/blob/master/STLibrary.mm)
  ```c
  messagePort = rocketbootstrap_cfmessageportcreateremote(NULL, CFSTR(MACH_PORT_NAME));
  CFMessagePortSendRequest(messagePort, 1, cfData, 1, 1, kCFRunLoopDefaultMode, &rData);
  ```
- **XXTouch** 的 daemon 侧通过 `TFLuaBridge` 与注入端做 RPC，方法名如 `ClientGetTopMostDialog` / `ClientDismissTopMostDialog` / `ClientInputText` / `ClientSetOrientation` / `ClientShake`。✅ 已查证 [webserv/AlertHelperHandlers.m](https://github.com/XXTouchNG/XXTouchNG/blob/master/webserv/AlertHelperHandlers.m)
- Makefile 依赖里明确有 `rocketbootstrap`。✅ 已查证（`touch/Makefile`、`monkey/Makefile`）

**给你的建议**：daemon 只做"重活"（HID dispatch、PTY、本地 HTTP 服务、启动 App），任何**需要 UI 的事**（通知、弹窗、WebView、悬浮球）一律通过 rocketbootstrap CFMessagePort 交给注入 SpringBoard 的 tweak。这也是 XXTouch/ZXTouch 的分工。

### 6.5 `libnotify` / `notifyutil` 的准确事实（✅ 已查证）

- `notifyutil` 是 Apple **Libnotify** 项目的 CLI（Darwin 通知 / notifyd），Procursus 打包，Homepage 为 `opensource.apple.com/source/Libnotify/`。✅ [build_info/notifyutil.control](https://github.com/ProcursusTeam/Procursus/blob/main/build_info/notifyutil.control)
- Procursus 给它的 entitlements：`platform-application`、`com.apple.private.security.no-container`、`com.apple.private.skip-library-validation`、`com.apple.private.libnotify.statecapture`。✅ [build_misc/entitlements/notifyutil.xml](https://github.com/ProcursusTeam/Procursus/blob/main/build_misc/entitlements/notifyutil.xml)
- Procursus 的补丁把 `--dump` 从"仅 internal diagnostics 可用"改成始终可用（`os_variant_has_internal_diagnostics` 判断被删掉）。✅ [build_patch/notifyutil/fixes.diff](https://github.com/ProcursusTeam/Procursus/blob/main/build_patch/notifyutil/fixes.diff)
- **`notify_post` / `notify_register_dispatch` / `notifyutil -p` 只传递通知名与整数状态，不产生任何 UI。** 用它做"daemon 通知 tweak 去干活"的**信号**是可以的（虽然 rocketbootstrap 更可靠、能带负载）。
- 🟡 关于"越狱 libnotify 与 Darwin libnotify 是两个东西"：我**未能**取到 `rpetrich/libnotify` 的 README（jsDelivr 上该仓库文件不存在/已迁移），所以这条**部分查证**。但结论不变：**Darwin 通知 ≠ 可见通知**。另有一个易混点：`libnotify` 也是 Linux 桌面通知库的名字，与本主题无关。

### 6.6 其他候选（明确"不要指望"）

- `uiopen`（Procursus 的 `uicache`/`uiopen` 工具）：❌ 未查证能否在 daemon 里打开 URL 并显示；本质是 `LSApplicationWorkspace openURL` 的 CLI 包装。
- `sbutil`（SpringBoard 工具集，Procursus 有 `sbutil`）：🟡 未查证；历史上用过 `sbutil -9`（kill SpringBoard）等。
- **Activator (`libactivator`)**：只是"手势→事件"总线，**不是**通知 UI 方案。❌ 未查证其 API 在 iOS 15/16 rootless 下的可用性。
- `banner` 命令：❌ 未查证在 iOS 15/16 存在；不作为方案。

---

## 7. 主题 5：PTY 终端（交互式 shell）

这一节的结论**非常明确且都是硬证据**，可以放心落地。

### 7.1 iOS SDK 头文件的确切情况（✅ 已查证，逐 SDK 探测）

我逐个路径探测了 `xybp888/iOS-SDKs`（iPhoneOS 15.5 / 15.6 / 16.5）：

| 头文件 | iPhoneOS 15.5 | 15.6 | 16.5 |
|---|---|---|---|
| `usr/include/util.h` | **存在** | **存在** | **存在** |
| `usr/include/pty.h` | **不存在** | 不存在 | 不存在 |
| `usr/include/libutil.h` | **不存在** | 不存在 | 不存在 |
| `usr/include/stdlib.h` | 存在 | 存在 | 存在 |
| `usr/include/spawn.h` | 存在 | 存在 | 存在 |

**iPhoneOS 15.5 SDK `usr/include/util.h` 里的原型（逐字抄录）**：
```c
#include <pwd.h>
#include <termios.h>

int   login_tty(int);
int   openpty(int *, int *, char *,
              struct termios *, struct winsize *);
pid_t forkpty(int *, char *, struct termios *, struct winsize *);
```

**iPhoneOS 15.5 SDK `usr/include/stdlib.h` 里的原型（逐字抄录）**：
```c
int      grantpt(int);
int      posix_openpt(int);
char    *ptsname(int);
int      ptsname_r(int fildes, char *buffer, size_t buflen)
             __API_AVAILABLE(macos(10.13.4), ios(11.3), tvos(11.3), watchos(4.3));
int      unlockpt(int);
```

→ **结论：`<pty.h>` / `<libutil.h>` 不存在，别 include 它们；用 `<util.h>` + `<stdlib.h>`。`openpty`/`forkpty`/`login_tty`/`posix_openpt`/`grantpt`/`unlockpt`/`ptsname`/`ptsname_r` 在 iOS 15+ 全部可用。**

### 7.2 Darwin 的实现细节（✅ 已查证，Apple 开源）

`posix_openpt` / `grantpt` / `unlockpt` / `ptsname` / `ptsname_r` 的真实实现（说明它们就是 ioctl 包装）：
[apple-oss-distributions/Libc/stdlib/grantpt.c](https://github.com/apple-oss-distributions/Libc/blob/main/stdlib/grantpt.c)

```c
int posix_openpt(int flags) {                 /* 就是开 /dev/ptmx */
    int fd = open("/dev/ptmx", flags);
    if (fd >= 0) return fd;
    return -1;
}
int grantpt(int fd)  { return ioctl(fd, TIOCPTYGRANT); }
int unlockpt(int fd) { return ioctl(fd, TIOCPTYUNLK); }
int ptsname_r(int fd, char *buffer, size_t buflen) { /* ioctl(fd, TIOCPTYGNAME, buf) + stat 校验 */ }
```

`openpty` / `forkpty` 的实现：
[apple-oss-distributions/Libc/util/pty.c](https://github.com/apple-oss-distributions/Libc/blob/main/util/pty.c)

```c
int openpty(int *aprimary, int *areplica, char *name,
            struct termios *termp, struct winsize *winp) {
    if ((primary = posix_openpt(O_RDWR|O_NOCTTY)) < 0) return -1;
    if (grantpt(primary) < 0 || unlockpt(primary) < 0
        || ptsname_r(primary, rname, sizeof(rname)) == -1
        || (replica = open(rname, O_RDWR|O_NOCTTY, 0)) < 0) { ... return -1; }
    *aprimary = primary; *areplica = replica;
    if (termp) (void)tcsetattr(replica, TCSAFLUSH, termp);
    if (winp)  (void)ioctl(replica, TIOCSWINSZ, (char *)winp);   /* 注意这里设了 winsize */
    return 0;
}

int forkpty(int *aprimary, char *name, struct termios *termp, struct winsize *winp) {
    if (openpty(&primary, &replica, name, termp, winp) == -1) return -1;
    switch (pid = fork()) {
    case 0:  /* 子进程 */
        (void)close(primary);
        if (login_tty(replica) < 0) {          /* 失败则退化为 dup2 */
            (void)dup2(replica, 0); (void)dup2(replica, 1); (void)dup2(replica, 2);
        }
        return 0;
    }
    *aprimary = primary; (void)close(replica);
    return pid;
}
```

> ⚠️ 注意：**`forkpty` 内部用的是 `fork()`**。在 daemon（多线程 + 强沙盒）里 `fork()` 后只做 `exec` 是可以的，但 `fork()` 之后**不 exec** 就调用非 async-signal-safe 的代码会死锁。`login_tty` 本身是 safe 的（`setsid` + `ioctl TIOCSCTTY` + `dup2`）。见 §7.4。

### 7.3 生产实现：NewTerm 怎么做（✅ 已查证，强烈建议照抄）

NewTerm 是 iOS 上事实标准的终端。它的做法**不是 `forkpty`**，而是**`openpty` + `posix_spawn`(经 libiosexec) + 一个 helper 二进制**：

**(a) 应用侧**（`openpty` 直接在 iOS App 里调用 → 证明可用）：
[hbang/NewTerm/Common/Controllers/SubProcess.swift](https://github.com/hbang/NewTerm/blob/main/Common/Controllers/SubProcess.swift)

```swift
private static let loginHelper: String = Bundle.main.path(forAuxiliaryExecutable: "NewTermLoginHelper")!

private static let login: String = {
    #if targetEnvironment(simulator)
    return "/bin/zsh"
    #elseif targetEnvironment(macCatalyst)
    return "/usr/bin/login"
    #else
    if loginIsShell { return "/var/jb/bin/zsh" }          // ← rootless 前缀
    return ["/var/jb/usr/bin/login", "/usr/bin/login"]    // ← rootless 优先，rootfs 兜底
        .first { (try? URL(fileURLWithPath: $0).checkResourceIsReachable()) == true } ?? "/usr/bin/login"
    #endif
}()

private static var loginArgv: [String] {
    ...
    return ["login", "-fp\(hushLogin ? "q" : "")", NSUserName(), loginHelper]
}

private func updateWindowSize() {
    guard let fileDescriptor = fileDescriptor else { return }
    var windowSize = screenSize.windowSize
    if ioctl(fileDescriptor, TIOCSWINSZ, &windowSize) == -1 {   // ← 改窗口大小
        logger.error("Setting screen size failed: \(errno, format: .darwinErrno)")
    }
}
```
（同一文件里：`openpty(...)` 建 pty；`posix_spawn` 经 `ie_posix_spawn` 启动 `/usr/bin/login`；用 `DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)` 收子进程退出，`stop()` 里 `kill(pid, SIGKILL)` + `waitpid`。）

**(b) helper 侧**（这是"成为控制终端"的正确姿势，⚠️ 只在子进程里做）：
[hbang/NewTerm/NewTermLoginHelper/main.c](https://github.com/hbang/NewTerm/blob/main/NewTermLoginHelper/main.c)

```c
int main(int argc, char *argv[]) {
    if (argc < 3 || strcmp(argv[0], "-NewTermLoginHelper") != 0) { ... return 1; }

    // Become a controlling tty. Equivalent to what login_tty() does.
    if (setsid() != getpid()) { perror("setsid()"); }
    if (ioctl(0, TIOCSCTTY, NULL) != 0) { perror("ioctl()"); }

    chdir(argv[1]);

    // argv[2] 前加 "-"，告诉 shell 这是 login shell
    char *program = malloc(strlen(argv[2]));
    strcpy(program, argv[2]);
    asprintf(&argv[2], "-%s", basename(program));

    execvp(program, (char **)&argv[2]);
    perror(program);
    return 1;
}
```

**(c) 用 libiosexec 解决 iOS 的 `exec` 缺陷**：
[ProcursusTeam/libiosexec](https://github.com/ProcursusTeam/libiosexec) README：
> "A shim library that both works to allow **shell scripts to execute correctly on iOS**, and provides a framework for **true rootless support**."
> "this implementation follows FreeBSD/Linux behavior of not splitting the argument passed to the shebang, unlike macOS which does."

接口（✅ 已查证 [NewTermCommon.h](https://github.com/hbang/NewTerm/blob/main/Common/Supporting%20Files/NewTermCommon.h)）：
```c
extern int ie_posix_spawn(pid_t *pid, const char *path,
        const posix_spawn_file_actions_t *file_actions,
        const posix_spawnattr_t *attrp,
        char *const argv[], char *const envp[]);
extern int ie_getpwuid_r(uid_t uid, struct passwd *pw, char *buf, size_t buflen, struct passwd **pwretp);
```
→ **如果你要 `posix_spawn` 一个 shell 脚本或通过 shebang 的路径，必须用 `ie_posix_spawn`（或自己实现 shebang 解析），否则 iOS 上会失败。**

NewTerm 的 entitlements（供参考，它是 App 不是 daemon）：✅ 已查证 [App/entitlements.plist](https://github.com/hbang/NewTerm/blob/main/App/entitlements.plist)
```xml
<key>platform-application</key><true/>
<key>com.apple.private.skip-library-validation</key><true/>
<key>com.apple.private.security.no-container</key><true/>
<key>com.apple.security.iokit-user-client-class</key><array><string>IOUserClient</string></array>
```

### 7.4 `fork` vs `posix_spawn`，与 `POSIX_SPAWN_SETSID`

- ✅ 已查证：`POSIX_SPAWN_SETSID` 在 **public iOS SDK 的 `spawn.h` 里没有定义**（我 grep 了 iPhoneOS 15.5 与 16.5 的 `#define POSIX_SPAWN_*`，只有 `POSIX_SPAWN_NP_CSM_*`）。它的真值在 **xnu 内部头** `bsd/sys/spawn.h` 里是：
  [apple-oss-distributions/xnu/bsd/sys/spawn.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/spawn.h)
  ```c
  #define POSIX_SPAWN_RESETIDS        0x0001
  #define POSIX_SPAWN_SETPGROUP       0x0002
  #define POSIX_SPAWN_SETSIGDEF       0x0004
  #define POSIX_SPAWN_SETSIGMASK      0x0008
  #define POSIX_SPAWN_START_SUSPENDED 0x0080
  #define POSIX_SPAWN_SETSID          0x0400
  #define POSIX_SPAWN_CLOEXEC_DEFAULT 0x4000
  ```
  ❌ **未查证**：iOS 15/16 内核是否接受字面量 `0x0400`（内核支持该位，但你得绕过 SDK 定义，且不确定是否有额外的沙盒/平台限制）。**建议不要用**，直接照抄 NewTerm 的 helper 方案（在 helper 里 `setsid()` + `TIOCSCTTY`），100% 可控、零猜测。
- ✅ 已查证：SDK 里 `posix_spawn_file_actions_addchdir_np` / `addfchdir_np` 标着 `__API_AVAILABLE(macos(10.15)) __API_UNAVAILABLE(ios, tvos, watchos)` → **iOS 上不能用它设子进程 cwd**，所以 NewTerm 的 helper 里自己 `chdir(argv[1])`。
- 关于 `fork()` 在 iOS 上的限制：❌ **未查证**是否有"越狱 daemon 里 fork 被沙盒禁止"的硬性证据（我未取得一手材料）。已知的一手事实是：**Darwin 的 `forkpty` 自身就用 `fork()`**（§7.2），说明 fork 在 kernel 层可用；风险主要来自**多线程进程 fork 后不 exec**（`posix_spawn` 的设计初衷就是规避这个）。**推荐：daemon 里用 `posix_spawn` + helper，不要 `forkpty`。**

### 7.5 推荐的 daemon 侧落地蓝图

```
LaunchDaemon (root 或 mobile)
 ├─ openpty(&master, &slave, NULL, &termios, &winsize)   // 或 posix_openpt+grantpt+unlockpt+open(ptsname)
 ├─ 保存 master fd  → 用于 read/write 终端数据（可挂 DispatchSourceRead / kqueue）
 ├─ posix_spawn(pid, helper_path, fileActions{d adddup2(slave,0/1/2); addclose(master) },
 │              attrs{ 可选 SETPGROUP },
 │              argv = {"-helper", cwd, shell_path, ...}, envp = {"TERM=xterm-256color", ...})
 ├─ 窗口尺寸变化： ioctl(master, TIOCSWINSZ, &ws); 然后 kill(pid, SIGWINCH)
 ├─ 子进程回收： DispatchSource.makeProcessSource(pid, .exit) （等价 C: kqueue EVFILT_PROC）
 │              或统一 SIGCHLD + while ((p = waitpid(-1, &st, WNOHANG)) > 0) {}
 │              ⚠️ 不要用 signal(SIGCHLD, SIG_IGN)：会丢掉退出状态且与 SA_NOCLDWAIT 语义混杂，
 │                 自己要拿到每个会话的退出码就难了
 └─ 终止会话： kill(-pgid, SIGHUP) → 略等 → SIGKILL → waitpid
```

坑清单（部分已查证）：
1. **shell 路径**：Dopamine/rootless 下 `/bin/sh` 可能不存在或不是你想的那个；NewTerm 走 `/var/jb/bin/zsh` 优先、`/usr/bin/login` 兜底（✅）。RootHide 下**不能**硬编码 `/var/jb`（✅，见 §2 第 1 条），要用 roothide 的路径接口。
2. **`login` 比直接起 shell 好**（拿到 login shell、正确的 HOME/PATH），NewTerm 就是 `login -fp <user> <helper>`（✅）。
3. **`TIOCSCTTY` 必须在子进程里、`setsid()` 之后**（✅ NewTerm）。
4. **`TIOCSWINSZ` 要在 master（或 slave）上设**；`openpty` 的最后一个参数也会设一次（✅ Apple 源码）。
5. **僵尸回收**：用 `waitpid` 循环或 kqueue/`DispatchSource` 进程源；`SIGCHLD` handler 里只做 `waitpid`。
6. **信号**：转发 `SIGWINCH`；daemon 退出时对会话进程组发 `SIGHUP` 再 `SIGKILL`。
7. **`<util.h>` 里的 `login_tty(int)` 也可用**，但它 `dup2` 后不 exec，务必只在刚 fork/spawn 出来的子进程里调用。
8. ❌ **未查证**：iOS 上同时开多个 PTY 会话的数量上限、以及 daemon 以 `mobile` vs `root` 运行时 `/dev/ptmx` 的权限差异。→ 用 `openpty` 返回值 + `errno` 做健壮性判断，两种身份都测。

---

## 8. 主题 6：SpringBoard tweak 里的 WKWebView（加载 `http://127.0.0.1:PORT`）

### 8.1 结论（这是本文最"有料"的一个反直觉发现）

- ✅ **历史上确实可行**：**Xen HTML** 是 iOS 上最著名的"在 SpringBoard 里渲染 HTML"的 tweak，它的加载器只注入 SpringBoard：
  [Deploy/.../XenHTML_Loader.plist](https://github.com/Matchstic/Xen-HTML/blob/master/Deploy/Package/Library/MobileSubstrate/DynamicLibraries/XenHTML_Loader.plist)
  ```xml
  { Filter = { Bundles = ( "com.apple.springboard", "com.apple.Preferences" ); }; }
  ```
  而它的数据桥 `libwidgetinfo` 直接**在 SpringBoard 里 swizzle `WKWebView`**：
  [lib/Hooks/WKWebView_WidgetData.m](https://github.com/Matchstic/libwidgetinfo/blob/master/lib/Hooks/WKWebView_WidgetData.m)
  ```objc
  @implementation WKWebView (WidgetData)
  - (instancetype)initWithFrame:(CGRect)frame
                  configuration:(WKWebViewConfiguration *)configuration
               injectWidgetData:(BOOL)injectWidgetData {
      if (injectWidgetData) {
          [[XENDWidgetManager sharedInstance] injectRuntime:configuration.userContentController];
      }
      return [self initWithFrame:frame configuration:configuration];
  }
  + (void)load {   /* swizzle loadFileURL:allowingReadAccessToURL: 与 stopLoading */ }
  - (WKNavigation *)xenhtml_loadFileURL:(NSURL *)URL allowingReadAccessToURL:(NSURL *)readAccessURL { ... }
  ```
  → 说明「SpringBoard 进程里创建并使用 WKWebView」在 iOS ≤13 时代是**现实可行的**（不需要额外 entitlements 的证据也没找到；tweak 本身只有基础 entitlements）。

- ✅ **但 iOS 15/16 上有明确的一手失败报告**：Xen HTML 的 iOS 15/16 续作维护者在其 README 里写：
  [miron302/xen-html-reborn/README.md](https://github.com/miron302/xen-html-reborn/blob/main/README.md)
  > "#### WebKit Rendering
  > The original Xen HTML implementation relies on **WebKit/WKWebView instances being embedded into SpringBoard interfaces**.
  > On newer versions of iOS, WebKit rendering and interaction within SpringBoard layers are handled differently, particularly on the Lock Screen. This currently **prevents some HTML-based effects from rendering correctly and can result in blank widgets or backgrounds**."
  > 并且它的开发重点之一是 "Improving stability and **preventing SpringBoard crashes/SpringBoard crash loops**"。
  该续作本身只注入 SpringBoard（`{ Filter = { Bundles = ( "com.apple.springboard" ); }; }`，✅ [XenHTMLRebornNative.plist](https://github.com/miron302/xen-html-reborn/blob/main/XenHTMLRebornNative.plist)），且**改成了原生渲染**（`JSONWidgetEngine.m` / `NativeBackgroundView.m`，读它们的方案本质是"绕开 WebView"）。

- ❌ **未查证**：我**没有**找到"完全无法在 SpringBoard 里创建 WKWebView"的确定性结论；也没有找到 iOS 15/16 上某 tweak 成功在 SpringBoard 里**渲染显示** WKWebView 的一手报告。**结论应当表述为：高风险、有空白渲染的实证报告、不应作为主方案。**

### 8.2 为什么风险高（技术解释，其中带结论的部分我没查到一手证据，标注如下）

- ✅ 已查证（Apple 文档）：WKWebView 是"in-app browser"组件，且 iOS 8+ 起取代 UIWebView：<https://developer.apple.com/documentation/webkit/wkwebview>。其 web 内容由**独立进程**承载（WebKit 的 WebContent/Networking 进程模型），宿主进程需要与这些 XPC 服务建连 —— 这正是"非 App 宿主（SpringBoard）可能建连失败/渲染空白"的机理假设。
- ❌ **未查证**：SpringBoard 具体缺哪些 entitlement / sandbox extension，以及确切的 `com.apple.private.webkit.*` 键名。**我拒绝给出猜测的键名。** 验证方法见 §8.5。
- ✅ 已查证（一手线索）：XXTouch 的 TamperMonkey tweak 的 filter 是
  ```xml
  { Filter = { Bundles = ( "com.apple.springboard", "com.apple.WebKit" ); }; }
  ```
  [monkey/.../TamperMonkey.plist](https://github.com/XXTouchNG/XXTouchNG/blob/master/monkey/layout/Library/MobileSubstrate/DynamicLibraries/TamperMonkey.plist)
  且它声明了私有 WebKit 头（`monkey/include/WKWebViewIOS.h`、`WKWebViewPrivateForTestingIOS.h`）、hook 了 `WKFormSelectControl`/`WKDateTimePicker`/`WKSelectSinglePicker`/`UIWebView`/`SFSafariView`/`_UILayerHostView`/`SFBrowserServiceViewController`（✅ [LogosTamperMonkey.xm](https://github.com/XXTouchNG/XXTouchNG/blob/master/monkey/LogosTamperMonkey.xm)）。
  → 说明：**"注入 SpringBoard 并操作 WKWebView 体系"这件事本身有人在做**（它 hook 已存在的 webview、注入 JS），但这**不等于**"能在 SpringBoard 里新建并显示一个 WKWebView"。
- ✅ 已查证（有用的一手事实）：该 tweak 里 `%hook UIWebView` 存在 → **`UIWebView` 类在 iOS 13–16 上仍然存在**（WebKitLegacy）。这给 §8.4 的备选方案提供了依据。
- ❌ **未查证**：RootHide 是否额外干扰 SpringBoard 内 WebKit（我未找到 RootHide issues 中的相关报告）。

### 8.3 本地 loopback HTTP 与 ATS

- ✅ 已查证（Apple 官方文档）：`NSAllowsLocalNetworking` —— "A Boolean value that indicates whether to allow local resources to load."；讨论原文：
  > "`NSAllowsLocalNetworking` key controls whether App Transport Security (ATS) allows your app to connect to **unqualified domains, `.local` domains, and IP addresses** using IPv4 or IPv6. In iOS 9 and macOS 10.11, ATS disallows connections to all three domain types. You can add exceptions for unqualified domains and ..."
  <https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking>
  → `127.0.0.1` 属于"IP address"，因此**在 ATS 下默认是被禁止的**；需要 `NSAllowsLocalNetworking = YES`（或对该域加例外）。
- ⚠️ **关键落地难题**：tweak 没有自己的 Info.plist；ATS 由**宿主进程的 Info.plist** 决定 —— 在 SpringBoard 场景下就是 **SpringBoard 的 Info.plist**。🟡 我**未查证** iOS 15/16 的 SpringBoard Info.plist 是否已包含 `NSAllowsLocalNetworking` 或 `NSAllowsArbitraryLoads`。**验证方法**：
  ```bash
  plutil -p /System/Library/CoreServices/SpringBoard.app/Info.plist | grep -A6 NSAppTransportSecurity
  ```
  如果没有，你可以在 tweak 里**运行时 hook 读 Info.plist 的方法**（XXTouch 的 voiceball 就是这么给宿主 App 补 `NSMicrophoneUsageDescription` 的：`%hook NSBundle - (id)objectForInfoDictionaryKey:` 返回补充值，✅ 已查证 [voiceball/Tweak.xm](https://github.com/281609331/voiceball/blob/main/Tweak.xm)）——这是绕过该问题的现实手段。
- ✅ 替代做法：**直接用 `file://` + `loadFileURL:allowingReadAccessToURL:`**（Xen HTML/libwidgetinfo 就是这么加载本地 widget 的，✅）可以完全绕开 ATS 与 HTTP 端口；但那样你就不能"daemon 提供 HTTP API"了。折中：本地 HTML 里用 `WKScriptMessageHandler` 与 tweak 通信，让 tweak 去问 daemon（rocketbootstrap），避免 HTTP。

### 8.4 备选方案与各自限制

| 方案 | 能否在 SpringBoard tweak 用 | 限制 |
|---|---|---|
| **`WKWebView` + `http://127.0.0.1`** | 🟡 可创建，**显示/渲染有 iOS 15/16 空白报告** | 需 ATS 放行；多进程依赖；锁屏层问题更严重 |
| **`WKWebView` + `loadFileURL:`（本地 HTML）** | 🟡 同上，但**绕过 ATS 和本地服务器** | 仍需 WebKit 进程；Xen HTML 用它但 iOS 15/16 仍空白 |
| **`UIWebView`（WebKitLegacy）** | 🟡 类在 iOS 13–16 仍存在（✅ 一手证据：TamperMonkey `%hook UIWebView`）；**同进程渲染**，理论上更适合 SpringBoard | 已弃用多年、性能差、部分现代 JS/CSS 支持缺失；❌ 未在 iOS 15/16 的 SpringBoard 里验证过能否正常显示 |
| **`SFSafariViewController`** | ❌ 不适合：它要求一个 `UIViewController` 且内容在**独立服务进程**里，把它的 view 塞进 SpringBoard 的 window 属于未验证用法 | 需要 present 语义；同样有跨进程 UI 的层级问题 |
| **`UIApplication openURL:` / `LSApplicationWorkspace openURL:`** | ✅ 简单可靠 | **会离开 SpringBoard/当前界面跳到 Safari**；用户流程被打断；对"AI Agent 内嵌面板"不合适 |
| **把 UI 放进一个真正的 App**（daemon/`LSApplicationWorkspace` 启动它） | ✅ 最稳 | 需要切前台，牺牲"随处呼出" |
| **原生渲染（UIView/SwiftUI）而不是 WebView** | ✅ 最稳（Xen HTML Reborn 的选择） | 你要自己写 UI；不能复用 HTML 前端 |

### 8.5 上线前的验证清单（30 分钟，真机）

1. 在 SpringBoard tweak 里（`%hook SpringBoard - (void)applicationDidFinishLaunching:` 之后）：
   ```objc
   WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
   WKWebView *wv = [[WKWebView alloc] initWithFrame:CGRectMake(0,0,300,400) configuration:cfg];
   [wv loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:8080"]]];
   [someSpringBoardView addSubview:wv];   // 先加到一个简单容器里，不要先搞 window
   ```
   - 看控制台是否有 WebContent 进程启动失败、`didFailNavigation`、沙盒拒绝日志。
2. 同时用 `os_log`/`NSLog` 打 `wv.title`、`wv.URL`、`wv.loading`；用 `-webView:didFinishNavigation:` 判断是真加载成功还是只是白屏。
3. 检查 ATS：`plutil -p /System/Library/CoreServices/SpringBoard.app/Info.plist | grep -A6 NSAppTransportSecurity`；若缺，先在 tweak 里补 `NSBundle` hook 再测。
4. 在**锁屏**与**主屏**分别测（README 明确指出锁屏层更糟）。
5. 若失败：换成 `file://` + `loadFileURL:` 重测；再失败就换 `UIWebView`；仍失败 → 接受"不做 WebView"，走 `openURL` 或原生渲染。

---

## 9. 主题 7：悬浮球 / 悬浮窗

### 9.1 结论

✅ 完全可行，且有一个**面向 rootless + RootHide 的现成开源实现**可以直接抄：
**`281609331/voiceball` —— "VoiceBall floating voice-input ball tweak for jailbroken iOS (Theos, rootless+roothide)"**（✅ 已查证仓库描述与源码）

### 9.2 一手实现细节（✅ 已查证，逐条来自 [voiceball/Tweak.xm](https://github.com/281609331/voiceball/blob/main/Tweak.xm)）

```objc
#define VB_BALL_SIZE          58.0
#define VB_WINDOW_LEVEL       10000001.0  // 高于系统键盘窗口(约1e7), 键盘弹出时球仍在最上层

/* ---- 命中穿透容器：只有命中子控件(球/提示)才响应，其余触摸透传给下层 App ---- */
@interface VBHitView : UIView
@end
@implementation VBHitView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *h = [super hitTest:point withEvent:event];
    return (h == self) ? nil : h;      // 返回 nil → 触摸落到下面的 App
}
@end

- (void)installIfNeeded {
    if (self.window) return;
    if (!NSClassFromString(@"UIWindow")) return;
    if (![UIApplication sharedApplication]) return;
    if ([self shouldSkipProcess]) return;

    CGRect sb = [UIScreen mainScreen].bounds;
    self.window = [[UIWindow alloc] initWithFrame:sb];
    self.window.windowLevel = VB_WINDOW_LEVEL;
    self.window.backgroundColor = [UIColor clearColor];
    self.window.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) {
        // iOS 13+ 场景化窗口: 尽量挂到当前场景
        if (!self.window.windowScene) {
            UIWindowScene *scene = (UIWindowScene *)[[[UIApplication sharedApplication] connectedScenes] anyObject];
            self.window.windowScene = scene;
        }
    }
    self.window.hidden = NO;
    VBRootViewController *rootVC = [[VBRootViewController alloc] init];
    self.window.rootViewController = rootVC;
    // ... 球体、手势 ...
}

/* ---- 生命周期：每个 App 进程第一次有触摸事件时创建（延迟等 UI 就绪） ---- */
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[VBOverlay sharedOverlay] installIfNeeded];
        });
    });
}
%end
```

从这份代码可以直接提炼出**推荐做法**：
1. **不要用 `makeKeyAndVisible`**（该实现只设 `hidden = NO`），否则会抢 key window 破坏键盘/状态栏行为。
2. **必须处理场景**：iOS 13+ 上 `UIWindow` 需要 `windowScene` 才可靠显示 —— 它的做法是 `[[UIApplication sharedApplication] connectedScenes].anyObject`，并**显式赋值 `self.window.windowScene = scene`**。🟡 更严谨的做法是选 `activationState == UISceneActivationStateForegroundActive` 的 scene（该实现没做这一步，属可改进点）。
3. **触摸穿透靠 `hitTest:` 返回 `nil`**（`VBHitView`），这是关键技巧；不要靠 `userInteractionEnabled = NO`（那会连球一起失效）。
4. **拖拽**：`UIPanGestureRecognizer` + `translationInView:` + `setTranslation:CGPointZero`，并 clamp 到屏幕内，落点存 `NSUserDefaults`（该实现如此）。
5. **不调 `makeKeyAndVisible`、`backgroundColor = clearColor`、`rootViewController` 用自定义 VC**。
6. **进程过滤**：该 tweak 的 substrate filter 是**空 filter**（✅ 已查证 [VoiceBall.plist](https://github.com/281609331/voiceball/blob/main/VoiceBall.plist) 内容是 `{ Filter = { }; }` → 注入所有进程），然后在代码里排除 SpringBoard/BackBoard：
   ```objc
   - (BOOL)shouldSkipProcess {
       NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
       if ([bid isEqualToString:@"com.apple.springboard"]) return YES;
       if ([bid isEqualToString:@"com.apple.BackBoard"]) return YES;
       return NO;
   }
   ```
   → 两种架构二选一：**(a) 只注入 SpringBoard**（window 天然全局，但注意 SpringBoard 桌面/锁屏层级差异）；**(b) 注入每个 App 各自起球**（voiceball 的选择，能精确控制"某个 App 不显示"）。**若你要"悬浮球 + 全局面板"，(a) 更合适。**
7. **时序**：voiceball 用 `%hook UIApplication -sendEvent:` + `dispatch_once` + 延迟 0.5s 来等 UI 就绪（App 进程场景）。在 **SpringBoard** 场景，✅ 已查证的成熟做法是 hook **`SpringBoard -applicationDidFinishLaunching:`**：
   [Xen-HTML/Loader/XenHTML.mm](https://github.com/Matchstic/Xen-HTML/blob/master/Loader/XenHTML.mm)
   ```objc
   %hook SpringBoard
   - (void)applicationDidFinishLaunching:(id)arg1 {
       %orig;
       // ... 初始化；示例里还用下面这种方式从 SpringBoard 弹 UI：
       [[UIApplication sharedApplication].keyWindow.rootViewController
            presentViewController:alert animated:YES completion:nil];
   }
   %end
   ```
8. **windowLevel 数值**：✅ 已查证 iOS 16.5 SDK 的声明（注意**头文件只有 extern 声明，没有数值**）：
   ```objc
   typedef CGFloat UIWindowLevel NS_TYPED_EXTENSIBLE_ENUM;
   @property(nonatomic) UIWindowLevel windowLevel;   // default = 0.0
   UIKIT_EXTERN const UIWindowLevel UIWindowLevelNormal;
   UIKIT_EXTERN const UIWindowLevel UIWindowLevelAlert;
   UIKIT_EXTERN const UIWindowLevel UIWindowLevelStatusBar API_UNAVAILABLE(tvos);
   ```
   Apple 文档给出的**语义**（✅）：`UIWindowLevelAlert` — "Windows at this level appear on top of the status bar."；`UIWindowLevelStatusBar` — "Windows at this level appear on top of your app's main window, but below alerts."
   （<https://developer.apple.com/documentation/uikit/uiwindow/level/alert>、<https://developer.apple.com/documentation/uikit/uiwindow/level/statusbar>）
   🟡 **数值 0.0 / 1000.0 / 2000.0 我没有从 SDK 头文件里读到**（它们是 extern 常量），属于公开已知值但**未经我直接在 SDK 里查证**。
   **实务建议**：`UIWindowLevelAlert + 1`（≈2001）足够压过系统弹窗；但 voiceball 用了 **`10000001.0`** 来压过**系统键盘窗口（约 1e7）**——如果你要"键盘弹出时悬浮球仍在最上层"，就必须用这个量级。**这是本节最实用的一个数字。**

### 9.3 坑清单

1. **不要 `makeKeyAndVisible`**（✅ voiceball 的做法）。
2. **必须设 `windowScene`**（iOS 13+），否则窗口可能不显示或显示在错误的场景（✅）。
3. **锁屏/主屏层级不同**：在锁屏上要让窗口出现，通常需要用锁屏自己的场景/窗口层级（Xen HTML Reborn 明确说锁屏层要单独适配，✅）。🟡 具体类名（`CSCoverSheetViewController` / `CSPosterViewController`）在 README 里被点到，但我**未验证**用法。
4. **窗口必须强引用**（`@property (nonatomic, strong) UIWindow *window;`，✅），否则会被释放导致球消失。
5. **respring/重启后消失**：窗口属于进程生命周期，SpringBoard 重启后需靠 daemon/`RunAtLoad` 或 tweak 的 `%ctor` 重建。✅ 已查证 XXTouch 的 daemon plist 有 `RunAtLoad`+`KeepAlive`。
6. **触摸穿透**：`hitTest:` 返回 `nil` 只对"未命中子视图"生效；如果你的 root VC 的 view 铺满屏幕且 `userInteractionEnabled = YES`，务必确保只有球是 subview（✅ voiceball 的结构就是 `VBHitView`(铺满) + `ball`/`toastLabel`(子视图)）。
7. **性能/耗电**：常驻窗口 + 定时器会持续占用；避免在窗口里跑高频刷新。
8. **arm64e**：voiceball 的 Makefile 用 `export ARCHS = arm64 arm64e`，rootless 分支用 `make package THEOS_PACKAGE_SCHEME=rootless`；✅ 已查证 [Makefile](https://github.com/281609331/voiceball/blob/main/Makefile)。XXTouch 的 touch 库则只用 `ARCHS = arm64`（稳）. 🟡 是否必须 arm64e：不必，`arm64` 单架构在 iOS 15/16 上可用（多个项目如此）。
9. **entitlements**：注入 SpringBoard 的 tweak 通常需要 `platform-application` + `com.apple.private.skip-library-validation`（+ RootHide 的 no-sandbox 系列）；✅ 已查证 ZXTouch 的 dylib entitlements 与 roothide 官方文档。

---

## 10. 目标架构建议（一句话版）

```
LaunchDaemon (root, 带 HID/IOKit entitlements)      ← 重活：HID 事件、PTY shell、本地 HTTP、启动 App
   ↕ rocketbootstrap CFMessagePort / XPC
SpringBoard tweak (filter: com.apple.springboard)   ← 所有 UI：悬浮球、面板、通知、AX 读取
   ↕ (可选) 每个 App 的 tweak (空 filter 或 com.apple.UIKit)
```
- **不要**在 daemon 里试图弹 UI 或建 WebView（§6、§8）。
- **不要**在 RootHide 下硬编码 `/var/jb`（§2.1）。
- **不要**用 `IOHIDEventSystemClientCreateWithType`、`SBSNotification`、`SBSLaunchApplicationWithIdentifier`（单参数）、`POSIX_SPAWN_SETSID`、`<pty.h>` 这些名字/常量作为方案基础（§2、§6、§7.4）。

---

## 11. 待验证清单（按优先级）

| # | 待验证项 | 建议方法 |
|---|---|---|
| 1 | root daemon 里 dispatch HID 事件是否只需 §3.4 那套 entitlements | 用 XXTouch 的 `ent.plist` 原样签名你的 daemon，最小化测一次合成点击 |
| 2 | daemon 能否直接 `LSApplicationWorkspace -openApplicationWithBundleID:` 把 App 拉到前台 | 真机测；失败则改由 SpringBoard tweak 执行 |
| 3 | `AXElement` / `AXUIElement` 需要什么 entitlement | `ldid -e /usr/libexec/assistivetouchd`、`ldid -e .../SpringBoard`，对齐后最小实验 |
| 4 | SpringBoard 的 Info.plist 是否已允许本地明文 HTTP | `plutil -p /System/Library/CoreServices/SpringBoard.app/Info.plist \| grep -A6 NSAppTransportSecurity` |
| 5 | SpringBoard 里 `WKWebView` 能否显示（空白问题） | 按 §8.5 的 5 步实验；准备 `loadFileURL:` 与 `UIWebView` 两个退路 |
| 6 | SpringBoard 里 `CFUserNotificationCreate` 是否直接可用 | 最小 tweak：`applicationDidFinishLaunching:` 后建一个 dialog dict 调 `CFUserNotificationCreate` |
| 7 | 悬浮球在锁屏上的表现 | 按 §9.3 第 3 条，锁屏场景单独测 |
| 8 | RootHide vs rootless（Dopamine）路径 | 用 `roothide` 的路径接口取 jbroot；把 shell/helper 路径做成可配置，别硬编码 |

---

## 12. 主要参考链接

**模拟触摸 / HID**
- XXTouch SPI 头（确切函数原型）: <https://github.com/XXTouchNG/XXTouchNG/blob/master/touch/hid/IOKitSPI.h>
- XXTouch 事件发生器: <https://github.com/XXTouchNG/XXTouchNG/blob/master/touch/hid/STHIDEventGenerator.m>
- XXTouch daemon entitlements: <https://github.com/XXTouchNG/XXTouchNG/blob/master/touch/cli/ent.plist>
- XXTouch daemon launchd plist: <https://github.com/XXTouchNG/XXTouchNG/blob/master/touch/layout/Library/LaunchDaemons/ch.xxtou.simulatetouchd.plist>
- XXTouch touch Makefile: <https://github.com/XXTouchNG/XXTouchNG/blob/master/touch/Makefile>
- ZXTouch 触摸实现: <https://github.com/xuan32546/IOS13-SimulateTouch/blob/master/pccontrol/Touch.xm>
- ZXTouch entitlements / filter / Makefile: <https://github.com/xuan32546/IOS13-SimulateTouch/blob/master/layout/entitlements.plist>
- iolate/SimulateTouch（rocketbootstrap CFMessagePort 架构）: <https://github.com/iolate/SimulateTouch/blob/master/STLibrary.mm>
- PTFakeTouch（纯 ObjC 伪造 UITouch）: <https://github.com/xuanxt/PTFakeTouch/blob/master/PTFakeTouch/PTFakeMetaTouch.m>
- Apple IOHIDFamily 公开源: <https://github.com/apple-oss-distributions/IOHIDFamily>

**无障碍 / AX**
- iOS AXRuntime `AXElement`: <https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/AXRuntime.framework/AXElement.h>
- iOS AXRuntime `AXUIElement`: <https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/AXRuntime.framework/AXUIElement.h>
- Apple 文档（macOS-only）: <https://developer.apple.com/documentation/applicationservices/axuielement>、<https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue>

**启动 App / 前台查询**
- `LSApplicationWorkspace`: <https://github.com/nst/iOS-Runtime-Headers/blob/master/Frameworks/CoreServices.framework/LSApplicationWorkspace.h>
- `LSApplicationProxy`: <https://github.com/nst/iOS-Runtime-Headers/blob/master/Frameworks/CoreServices.framework/LSApplicationProxy.h>
- XXTouch 精简头: <https://github.com/XXTouchNG/XXTouchNG/blob/master/shared/include/LSApplicationWorkspace.h>
- theos SpringBoardServices 头: <https://github.com/theos/headers/blob/master/SpringBoardServices/SpringBoardServices.h>

**通知**
- Apple 开源 `CFUserNotification.h`: <https://github.com/apple-oss-distributions/CF/blob/main/CFUserNotification.h>
- XXTouch AlertHelper（CFUserNotification 一手用法）: <https://github.com/XXTouchNG/XXTouchNG/blob/master/alert/AlertHelper.mm>
- XXTouch AlertHelper filter（注入 UIKit 进程）: <https://github.com/XXTouchNG/XXTouchNG/blob/master/alert/layout/Library/MobileSubstrate/DynamicLibraries/AlertHelper.plist>
- XXTouch daemon 侧 RPC 处理: <https://github.com/XXTouchNG/XXTouchNG/blob/master/webserv/AlertHelperHandlers.m>
- Procursus notifyutil 打包/entitlements/patch: <https://github.com/ProcursusTeam/Procursus/blob/main/build_info/notifyutil.control>、<https://github.com/ProcursusTeam/Procursus/blob/main/build_misc/entitlements/notifyutil.xml>

**PTY**
- Apple 开源 `Libc/include/util.h`: <https://github.com/apple-oss-distributions/Libc/blob/main/include/util.h>
- Apple 开源 `Libc/util/pty.c`（openpty/forkpty 实现）: <https://github.com/apple-oss-distributions/Libc/blob/main/util/pty.c>
- Apple 开源 `Libc/stdlib/grantpt.c`（posix_openpt/grantpt/unlockpt/ptsname_r）: <https://github.com/apple-oss-distributions/Libc/blob/main/stdlib/grantpt.c>
- xnu `bsd/sys/spawn.h`（POSIX_SPAWN_SETSID）: <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/spawn.h>
- NewTerm SubProcess.swift: <https://github.com/hbang/NewTerm/blob/main/Common/Controllers/SubProcess.swift>
- NewTerm login helper: <https://github.com/hbang/NewTerm/blob/main/NewTermLoginHelper/main.c>
- libiosexec: <https://github.com/ProcursusTeam/libiosexec>
- iPhoneOS SDK 头文件镜像（15.5/15.6/16.5）: <https://github.com/xybp888/iOS-SDKs>

**WebView / 悬浮窗 / RootHide**
- Xen HTML 加载器 filter: <https://github.com/Matchstic/Xen-HTML/blob/master/Deploy/Package/Library/MobileSubstrate/DynamicLibraries/XenHTML_Loader.plist>
- Xen HTML loader（hook `SpringBoard applicationDidFinishLaunching:`）: <https://github.com/Matchstic/Xen-HTML/blob/master/Loader/XenHTML.mm>
- libwidgetinfo 在 SpringBoard 里 swizzle WKWebView: <https://github.com/Matchstic/libwidgetinfo/blob/master/lib/Hooks/WKWebView_WidgetData.m>
- Xen HTML Reborn（iOS 15/16 WKWebView 空白的一手报告）: <https://github.com/miron302/xen-html-reborn/blob/main/README.md>
- Apple ATS `NSAllowsLocalNetworking`: <https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking>
- voiceball（rootless+roothide 悬浮球）: <https://github.com/281609331/voiceball/blob/main/Tweak.xm>
- UIWindowLevel 语义: <https://developer.apple.com/documentation/uikit/uiwindow/level/alert>
- RootHide 开发者文档: <https://github.com/roothide/Developer/blob/main/roothide.md>、<https://github.com/roothide/Developer/blob/main/entitlements.md>

---

## 13. 本文的诚实边界

以下是**我明确没查证**、不要当结论用的点（已在正文逐条标注）：

1. iOS 15/16 上使用 `AXElement` / `AXUIElement` 所需的确切 entitlement / 授权机制。
2. `UNUserNotificationCenter` 在越狱 daemon 中的实际行为；以及 `SBSNotification` / `SBSNotificationRequest` 是否是真实存在的可用符号（**我倾向认为你记忆里的名字不可靠**）。
3. `CFUserNotificationCreate` 从**纯 root daemon**（无 GUI 会话）调用能否显示。
4. daemon 直接 `openApplicationWithBundleID:` 能否拉前台。
5. `SBSLaunchApplicationWithIdentifier`（单参数）在 iOS 15/16 是否仍导出。
6. WKWebView 在 SpringBoard 里的**具体**失败机理与所需 entitlement 键名（只知道现象报告：空白）。
7. RootHide 是否额外影响 SpringBoard 内 WebKit。
8. `ioctl(master, TIOCSWINSZ)` 与多会话上限、以 `mobile` 身份开 PTY 的权限差异。
9. `POSIX_SPAWN_SETSID` 字面量 `0x0400` 在 iOS 15/16 内核上是否被接受。
10. AutoTouch / Activator / sbutil / uiopen 在 Dopamine rootless + RootHide 下的可用性（原始仓库无相关文档，我的搜索通道又被阻断）。
11. `UIWindowLevelNormal/StatusBar/Alert` 的**数值**（SDK 头只有 extern 声明；0.0/1000.0/2000.0 是公开已知值但我未在 SDK 内直接读到）。

> 若你需要其中任一项的确定答案，最快路径是**在真机上做 5 分钟最小实验**（本文 §8.5 / §11 给了具体命令与代码骨架），而不是继续找资料 —— 因为当前网络环境下，公开资料的可检索性已经被严重削弱。
