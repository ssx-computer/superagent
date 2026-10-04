# iAgent

[![build](https://github.com/ssx-computer/superagent/actions/workflows/build.yml/badge.svg)](https://github.com/ssx-computer/superagent/actions/workflows/build.yml)
[![platform](https://img.shields.io/badge/platform-iOS%2015%2B%20%C2%B7%20arm64%2Farm64e-blue)](#支持的系统)

原生 iOS AI Agent：一个常驻的 root 守护进程（`iagentd`）+ 一个注入 SpringBoard 的 tweak
（`iagent.dylib`）。模型直接调用设备上的工具来操作这台已越狱的 iPhone：跑 shell、读写文件、
启动 App、发提示、管理定时任务、驱动界面（HID/AX）。

**没有 WebDAV，没有云端中间层，没有服务器中转。** 设备上的守护进程直接在回环地址上提供
HTTP + SSE 控制面，并由它自己通过 HTTPS 调用 OpenAI 兼容的模型接口；API Key 只存在本机。

> **状态：已在 GitHub Actions 上编译成功并产出 `.deb`；真机安装正在进行中。**
> 在 macOS runner（Xcode 16.4 / iPhoneOS 16.5 SDK）上 `iagentd` 与 `iagent.dylib` 都已
> arm64 + arm64e 编译、链接、签名通过，包内容与元数据断言全部通过。两个架构的产物都在
> [Releases](https://github.com/ssx-computer/superagent/releases)（以及 Actions 的 Artifacts）：
> `..._iphoneos-arm64.deb`（Dopamine / rootless）与 `..._iphoneos-arm64e.deb`（RootHide）。
> **先确认架构**：`dpkg --print-architecture` 的输出必须和包后缀一致。
> **仍未验证的**：守护进程真机启动、HID/AX 注入、SpringBoard 内嵌 WebView —— 见
> [已查证 / 未查证](#已查证--未查证)。

---

## 架构

```
┌──────────────────────────── iOS 设备 ────────────────────────────┐
│                                                                  │
│  SpringBoard（mobile）                 iagentd（root, launchd）  │
│  ┌───────────────────────┐            ┌───────────────────────┐  │
│  │ iagent.dylib (tweak)  │            │ HTTP 控制面 127.0.0.1 │  │
│  │  · 悬浮球 window      │  HTTP/SSE  │  · /api/* + 静态 Web  │  │
│  │    level 10000001     │◄──────────►│  · SSE 事件流         │  │
│  │  · WKWebView 控制面板 │  回环      │  · Agent 循环         │  │
│  │  · 桥接长轮询客户端   │  仅本机    │  · 工具注册表         │  │
│  │  · HID / AX 自动化    │            │  · PTY 终端 / cron    │  │
│  └───────────┬───────────┘            └───────────┬───────────┘  │
│              │                                    │              │
│              │ 触摸/键盘注入、AX 读树              │ HTTPS        │
└──────────────┼────────────────────────────────────┼──────────────┘
               ▼                                    ▼
        当前前台 App / 系统 UI              LLM API（base_url，OpenAI 兼容）
```

数据流：浏览器或面板 → `POST /api/chat`（SSE）→ `IAGAgent` 循环 → 模型返回工具调用 →
`IAGToolRegistry` 执行（必要时经 `IAGBridge` 长轮询交给 SpringBoard 里的 tweak）→
工具结果写回会话 → 再喂给模型，直到模型不再要求工具或步数用尽。

---

## 3 分钟安装

1. **拿 `.deb`**
   - [Releases](https://github.com/ssx-computer/superagent/releases) 或 Actions 的 artifact 直接下载
     （`..._iphoneos-arm64.deb` = Dopamine/rootless，`..._iphoneos-arm64e.deb` = RootHide）；
   - 或自己编译：见 [docs/build.md](docs/build.md)。
2. **安装**（已越狱的 iOS 15+ 设备）
   - 先用 `dpkg --print-architecture` 确认架构，装错架构 dpkg 会拒绝并可能留下「dpkg 已中断」；
   - Sileo / Zebra 里打开对应架构的 `.deb` → 安装；或
   - `dpkg -i com.dsh.iagent_1.1.0_iphoneos-arm64.deb`。
3. **不要期待安装完自动 respring**：脚本故意不重启 SpringBoard（在 dpkg 事务里 respring 会把
   Sileo 和 dpkg 一起杀掉，弄坏 dpkg 状态）。守护进程装完就能用 —— Safari 打开
   `http://127.0.0.1:8080` 即可；悬浮球要你自己重启一次 SpringBoard 才出现。
4. 点悬浮球打开控制面板 → **设置** 页填写模型信息 → 保存。

## 首次运行配置

设置页保存的是 `/var/mobile/Library/iAgent/config.plist`（daemon 与 tweak 读同一份文件）。
最少只需要三项，键名与 `POST /api/config` 完全一致：

| 键 | 默认值 | 说明 |
|---|---|---|
| `baseUrl` | `https://api.openai.com/v1` | OpenAI 兼容的接口前缀；客户端会补 `/chat/completions`，也接受直接写到 `/chat/completions` |
| `apiKey` | `""`（空） | 明文存进 `config.plist`；提交 `""` 表示"保持不变"，`"__CLEAR__"` 表示清空 |
| `model` | `gpt-4o-mini` | 模型名 |

其他常用项：`port`（默认 `8080`）、`authToken`（默认空 = 关闭鉴权）、`approvalMode`
（默认 `dangerous`）、`maxSteps`（12）、`shellTimeout`（30 秒）、`workDir`（`/var/mobile`）、
`historyLimit`（24）、`temperature`（0.3）、`maxTokens`（2048）。完整列表见
[docs/api.md](docs/api.md#post-apiconfig)。

没有填 `apiKey` 时，`POST /api/chat` 会直接返回错误事件 `尚未配置 API Key，请打开设置页填写模型接口信息`。

---

## 工具列表

按 `IAGToolRegistry registerDefaults` 实际注册的 18 个工具（编号即 `category`，
对应 `toolsEnabled` 里的开关）。

| 工具 | 类别 | 危险 | 一句话 |
|---|---|---|---|
| `shell_exec` | shell | 是 | 用 `/bin/sh -c` 执行一条命令，返回退出码、stdout、stderr；无交互 TTY |
| `http_fetch` | http | 否 | 发起一次 HTTP 请求，HTML 会转成纯文本后返回 |
| `fs_read` | file | 否 | 读文本文件（默认最多 256KB，可分段），二进制只返回元信息与十六进制摘要 |
| `fs_write` | file | 是 | 写文本（默认覆盖，`append=true` 追加），自动建父目录并 chmod 0644 |
| `fs_list` | file | 否 | 列目录（不递归），返回类型、权限、大小、修改时间 |
| `fs_search` | file | 否 | 按正则搜内容或按文件名通配符找文件（类 grep -rn） |
| `fs_delete` | file | 是 | 删除文件/目录；命中硬性保护名单直接拒绝 |
| `app_list` | app | 否 | 列出已安装应用的 bundle id 与显示名 |
| `app_launch` | app | 否 | 按 bundle id 启动应用，或打开一个 URL/scheme |
| `notify_send` | notify | 否 | 弹一条可见提示；桥接不可用时退回 `CFUserNotification` |
| `cron_add` | cron | 是 | 用 5 字段 cron 表达式创建定时任务 |
| `cron_list` | cron | 否 | 列出所有定时任务及上次结果、下次运行时间 |
| `cron_remove` | cron | 是 | 按 id 删除定时任务 |
| `ui_describe` | ui | 否 | 读当前前台界面的可交互元素（AX 树）与屏幕坐标 |
| `ui_tap` | ui | 是 | 点按；给 `x`/`y` 坐标，或给 `text` 让插件查找并点击 |
| `ui_type` | ui | 是 | 向当前焦点输入框输入文本（CJK 走 AX/pasteboard 回退） |
| `ui_swipe` | ui | 是 | 从 (x1,y1) 滑到 (x2,y2)，默认 0.3 秒 |
| `ui_open_url` | ui | 否 | 打开 URL / URL Scheme（会离开当前 App） |

参数表、示例与行为细节见 [docs/tools.md](docs/tools.md)。`ui_*` / `notify_send` 的实际执行发生在
SpringBoard 进程内（HID 注入需要 SpringBoard 自己的 entitlements）；桥接未连接时它们会明确报
`SpringBoard 桥接未连接：请确认 iAgent 的 SpringBoard 插件已加载（重新注销或重启后生效）`。

---

## 打开 UI

三种方式，都指向同一个 `http://127.0.0.1:8080/`（端口按 `port` 配置）：

1. **单击悬浮球** —— 后台用 3 秒超时探一次 `/api/health`（JSON 接口、免鉴权）；活着就在 SpringBoard
   内用 WKWebView 打开面板，否则弹一条"守护进程 iagentd 未在运行"的提示。面板加载 6 秒未完成会自动
   改用浏览器打开（SpringBoard 内 WKWebView 在 iOS 15/16 上有空白渲染的公开报告，见
   [docs/research/ios-private-apis.md](docs/research/ios-private-apis.md) §8）。
2. **长按悬浮球** —— 弹出菜单：打开控制面板 / 在浏览器中打开 / 隐藏悬浮球（本次会话内隐藏，
   重启后恢复）/ 取消。悬浮球可拖动，位置与左右侧会写回配置。
3. **Safari 直接访问** `http://127.0.0.1:8080/`（设置里开了 `openInSafari` 后，单击悬浮球直接走
   这条）。配置了 `authToken` 时 URL 带 `?token=<token>`。

面板有五个标签页：聊天、终端、工具、会话、设置（外加 daemon 日志弹窗），全部走同一条
回环 API。

---

## 守护进程存活与模型体检

**存活检测**：面板每 5 秒探一次 `/api/health`（页面切到后台时降到 15 秒），顶栏右侧的状态
徽标显示「在线 / 检测中 / 掉线」，点一下立刻重测。连续 2 次探测失败才判定掉线——掉线时聊天页
顶部出现常驻横幅（写明已经掉线多少秒）、发送按钮与输入框禁用、正在输出的回复会被中止；
守护进程回来后提示「已恢复响应」。如果这期间它换过 `pid`（说明重启过），还会插一张卡片说明
是第几次重启、上次退出是否干净、以及崩溃日志的最后几行。

**为什么现在能常驻**：LaunchDaemon 的 `KeepAlive` 改成了**无条件** `<true/>`。早先是
`{SuccessfulExit: false}`，语义是「只在退出码非 0 时重启」——被系统内存压力（jetsam）杀掉时
退出码是 0，于是再也不起来。守护进程启动时写一个运行标记，下一次启动据此判断上次是否正常退出，
并把累计重启次数与最后一次崩溃信号放进 `/api/health`（`pid` / `startedAt` / `restarts` /
`lastCrash` / `lastExitClean`）。未捕获异常与致命信号（SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/
SIGTRAP）会在 `logs/iagentd-crash.log` 留下信号名与调用栈。

**模型体检**（设置页「测试模型」）：不用先保存，按你正在填的 Base URL / API Key / 模型名真实发
一次请求，分五步给结论 —— 配置检查 → 网络连通 → 接口鉴权（`GET <baseUrl>/models`）→ 模型列表
里有没有你填的模型 → 流式对话是否真的收到 SSE 数据。自建中转最常见的问题是「HTTP 200 但没有
SSE 数据」（反向代理缓冲吃掉了 `text/event-stream`），这一步会单独指出来。「拉取模型列表」可以
把端点报告的模型 id 直接点进模型名输入框。

排查真机问题时先看 [docs/troubleshooting.md](docs/troubleshooting.md)：第 0 节是一条把所有
相关日志一次性收集完的命令。

---

## 安全默认值

- **只监听回环**：HTTP 服务器 `bind` 到 `INADDR_LOOPBACK`，代码里写死"loopback only, by design"，
  没有对外监听选项。
- **鉴权可选**：`authToken` 为空时所有 `/api/*` 都不校验（仅 `/api/health` 始终免鉴权，供 UI 探活）；
  一旦设置，除 `/api/health` 外的接口都要求 `X-IAG-Token` 头或 `?token=`。静态 Web 文件（`/`、
  `index.html`、`app.js`、`style.css`）**不走鉴权**。**没有 TLS**，明文 HTTP 只跑在回环上。
- **审批模式**：`approvalMode` = `auto` | `dangerous` | `always`，默认 `dangerous`。`dangerous`
  下命中所见即所得的破坏性规则（删除、重启、系统目录写入、界面自动化等）会在执行前要求确认。
- **命令黑名单**：`blockedCommands`（默认 10 条，如 `rm -rf /`、`mkfs`、`nvram`）按"命令小写后的
  子串包含"匹配，对三个 shell 入口（agent 工具循环、`/api/tools/call`、`/api/exec`）都生效，
  命中直接拒绝（HTTP 入口返回 403），与审批模式无关。
- **删除保护名单**：`fs_delete` 对 `/`、`/System`、`/var`、`/var/jb`、`/var/mobile`、
  `/private/var/db` 等路径硬性拒绝。
- **API Key 明文**：`/var/mobile/Library/iAgent/config.plist` 里是明文，文件权限 0644（tweak 以
  mobile 身份也要能读）。见 [docs/security.md](docs/security.md)。

细节与威胁模型见 [docs/security.md](docs/security.md)。

---

## 支持的系统

| 项目 | 值 |
|---|---|
| 最低系统 | iOS 15.0（`TARGET = iphone:clang:latest:15.0`，`Depends: firmware (>= 15.0)`） |
| 越狱形态 | rootless（Dopamine 等，jailbreak root = `/var/jb`）与 RootHide / roothide Bootstrap（随机 jbroot） |
| 包架构 | rootless 线 `iphoneos-arm64`；RootHide 线（`IAG_ROOTHIDE=1` + roothide/theos）`iphoneos-arm64e` |
| 二进制 | `ARCHS = arm64 arm64e` |
| 注入 | 仅 `com.apple.springboard`（`iagent.plist` 的 Filter） |
| 不依赖 | 不使用 Logos / `%hook`，不链接 substrate，不需要 CydiaSubstrate |

路径解析不信任编译期前缀：daemon 从自身可执行文件路径推导 jbroot，tweak 优先问 libroothide，
再退回 `/var/jb`（`shared/IAGPaths.m`）。Dopamine 与 RootHide 的差异说明见
[docs/research/roothide-dopamine-theos.md](docs/research/roothide-dopamine-theos.md)。

---

## 项目结构

```
iagent/
├── Makefile                     # 一个 Makefile 构建两个产物（iagentd + iagent.dylib）
├── entitlements.plist           # daemon 的 4 个 entitlements（tweak 不带）
├── .github/workflows/build.yml  # macOS 云编译（rootless + 可选 RootHide）
├── daemon/                      # iagentd：入口、HTTP、Agent 循环、工具、PTY、cron、桥接
│   ├── main.m  IAGDaemon.{h,m}  IAGHTTPServer.{h,m}
│   ├── IAGAgent.{h,m}  IAGLLM.{h,m}  IAGSessionStore.{h,m}  IAGConfig.{h,m}
│   ├── IAGTool.{h,m}  IAGToolShell.m  IAGToolFile.m  IAGToolDevice.m
│   ├── IAGBridge.{h,m}  IAGScheduler.{h,m}  IAGTerminal.{h,m}  IAGProcess.{h,m}
├── shared/                      # daemon 与 tweak 共用
│   ├── IAGPaths.{h,m}  IAGLog.{h,m}  IAGJSON.{h,m}  IAGUtil.{h,m}  IAGVersion.h
├── tweak/                       # SpringBoard 侧
│   ├── IAGTweak.m               # constructor 入口、悬浮球、面板、桥接客户端
│   └── IAGAutomation.{h,m}      # HID 注入 + AX 树
├── layout/                      # 打进 .deb 的静态内容（Theos 会加 /var/jb 前缀）
│   ├── DEBIAN/{control,postinst,prerm}
│   ├── Library/LaunchDaemons/com.dsh.iagent.daemon.plist
│   ├── Library/MobileSubstrate/DynamicLibraries/iagent.plist
│   └── usr/share/iagent/web/{index.html,app.js,style.css}
└── docs/
    ├── architecture.md  install.md  tools.md  api.md  security.md  build.md
    └── research/{roothide-dopamine-theos.md, ios-private-apis.md}
```

---

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 进程模型、HTTP/SSE、Agent 循环与审批、会话存储、PTY、cron、桥接、tweak 内部、路径解析 |
| [docs/install.md](docs/install.md) | 前置条件、安装/卸载、postinst 做了什么、验证命令、故障排查 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | **真机排障**：dpkg 已中断、发消息没反应、连接被提前关闭、守护进程被杀/重启、悬浮球不出现、架构选择、一键收集全部日志 |
| [docs/tools.md](docs/tools.md) | 18 个工具的参数表、危险级别、示例与行为说明 |
| [docs/api.md](docs/api.md) | 全部 HTTP 接口、SSE 事件、curl 示例 |
| [docs/security.md](docs/security.md) | 威胁模型、黑名单、审批模式、entitlements、静态数据、加固建议 |
| [docs/build.md](docs/build.md) | 本地 Theos 构建、RootHide 变体、GitHub Actions、产物处理、未验证清单 |
| [docs/research/roothide-dopamine-theos.md](docs/research/roothide-dopamine-theos.md) | RootHide / Dopamine / Theos 工程事实（引用，不复述） |
| [docs/research/ios-private-apis.md](docs/research/ios-private-apis.md) | iOS 私有 API 备忘：HID、AX、PTY、WKWebView、悬浮窗（引用，不复述） |

---

## 已知的代码问题

写文档时逐行比对源码，发现下列问题**在代码里**（不是文档笔误）。前四条已在本轮修掉，其余是设计
取舍或轻微不一致，保留记录以便后续维护：

| 位置 | 问题 | 状态 |
|---|---|---|
| `tweak/IAGTweak.m` `openPanel` | 存活探测用 `IAGHTTPJSON` GET 面板地址 `/`，但该函数要求响应能解析成 JSON 字典，而 `/` 返回的是 `index.html`（HTML）。默认配置下（`openInSafari=false`）单击悬浮球会**永远**走到"守护进程 iagentd 未在运行"分支。 | ✅ 已修：改探 `/api/health`（JSON 且免鉴权） |
| `daemon/IAGToolFile.m` `IAGPathIsProtectedFromDelete` | 删除保护名单里的 `/var/jb/...` 条目是硬编码的：RootHide 的真实 jbroot（`/var/containers/Bundle/Application/.jbroot-xxxx/Library/...`）不在保护范围内。 | ✅ 已修：按 `IAGJailbreakRoot()` 再判一次 `Library` / `usr` / `Applications` / `Library/dpkg` / `Library/MobileSubstrate` |
| `daemon/IAGTool.m` `fs_write` 审批判据 | 敏感路径只硬编码了 `/System`、`/var/jb/Library`、`/private`，RootHide 的真实 jbroot 绝对路径会静默放行。 | ✅ 已修：额外按真实 jbroot 前缀判一次，并补上 `$IAG_JBROOT` 前缀与相对路径两类判据 |
| `tweak/` 桥接能力声明 | 插件用 `caps=hid:1,ax:1,notify:cf` 而非 JSON，且 daemon 在解析后又把它清空，导致 `/api/bridge/status.capabilities` 永远是 `{}`。 | ✅ 已修：daemon 两种格式都收且不再清空 |
| `daemon/IAGTool.m` `approvalReasonForTool` | `dangerous` 模式下 `[name hasPrefix:@"ui_"]` 让**所有** `ui_*` 都需审批——包括只读的 `ui_describe` 和 `isDangerous=NO` 的 `ui_open_url`；反过来 `app_launch` 的分支是 `&& dangerousTool`，而它 `isDangerous` 为 `NO`，所以**从不**触发审批。 | 设计取舍：界面类工具一律确认更安全；`ui_open_url`/`ui_describe` 若嫌吵可把 `approvalMode` 设为 `auto` |
| `daemon/IAGConfig.h` | 拖悬浮球时会写 `bubbleY` 键，但头文件只声明了 `bubbleSide`（`kIAGKeyTopButtonSide`），`bubbleY` 走通用字典存取。 | 轻微：不影响功能 |
| `layout/DEBIAN/control` | `Architecture` 写死 `iphoneos-arm64`；Theos 实际按 Makefile 的 scheme 决定架构，这个文件是人工打包时的参照。 | 已知：RootHide（arm64e）线需相应调整 |
| `tweak/IAGAutomation.m` | HID/AX 后端信息用 `NSLog` 输出，不写 `/var/mobile/Library/iAgent/logs/iagent.log`。 | 已知：排错需看设备控制台 |

---

## 已查证 / 未查证

**编写这些文档时对代码可查证的**（逐行读过源码）：接口路径与字段、配置键与默认值、工具参数
schema、危险标记、黑名单与删除保护名单、审批判定分支、HTTP 服务器的连接上限与 SSE 帧格式、
桥接的 command id / cursor / 20 秒连接窗口 / 5 分钟保留期、会话 400 条上限与历史窗口、
PTY 的 512KB 环形缓冲与 8 会话上限、cron 的"启动 5 秒后首次、之后每 15 秒"tick 与 600 秒执行超时、
路径探测顺序、entitlements 与 plist 内容。

**未查证的**（没有编译、没有真机）：

- 本项目从未编译：`otool -L` 是否有 substrate 依赖、双 rpath 是否生效、`dpkg-deb -c` 的包内路径，
  均未验证（memo 1 §10 给了命令）。
- RootHide 的 dpkg/Sileo 是否接受 `Architecture: iphoneos-arm64`（rootless 线）；第三方 plist 在
  RootHide 上由谁载入；`@JBROOT@` 占位符是否对第三方目录生效 —— memo 1 §3.2 / §4.2 / §11。
- RootHide 下 tweak 能否写 rootfs 的 `/var/mobile/Library/iAgent`（官方建议写 `$JBROOT/var/`）——
  memo 1 §2.4 / §11，本项目的数据目录设计正落在这条风险上。
- AX（`AXElement`）所需的确切 entitlement、SpringBoard 内 WKWebView 空白渲染的具体机理与
  ATS/entitlement 键名 —— memo 2 §13。
- daemon 直接 `openApplicationWithBundleID:` 能否把 App 拉到前台、`CFUserNotificationCreate` 从纯
  root daemon 调用能否显示 —— memo 2 §5.2 / §6.2 / §13。因此 `app_launch` / `ui_open_url` 实现为
  "先 daemon 侧 `LSApplicationWorkspace`、失败再交给桥接"，`notify_send` 则是"先桥接、失败退回
  `CFUserNotification`"，三条链都未在设备上验证。
- HID 键位映射、`IOHIDEventSystemClientCreate` 在 iOS 15/16 上的实际可用性 —— memo 2 §3 有已查证的
  调用序列，但本项目没有跑过一次注入。
- PTY：以 `mobile` 身份开 PTY 的权限差异、多会话上限 —— memo 2 §13 第 8 条。

上述每一条都应该按 memo 里的真机验证清单复核后再当作事实。

---

## 构建状态与许可

- 仓库：[`ssx-computer/superagent`](https://github.com/ssx-computer/superagent)
- CI：[`.github/workflows/build.yml`](.github/workflows/build.yml) —— 先跑不依赖 Mac 的
  `scripts/preflight.py` 结构自检，再用 Theos + iOS SDK 编译并由 `dpkg-deb` 断言包内容
  （`iagentd`、`iagent.dylib`、Web UI、LaunchDaemon 是否都在，`postinst` 是否有执行位）。
  产物在 Actions 的 Artifacts 里；打 `v*` tag 会自动建 Release 并附上 `.deb`。
  每次 push 都会同时编 **rootless（`iphoneos-arm64`）与 RootHide（`iphoneos-arm64e`）两个包**
  ——RootHide 不再需要手动触发，两个 job 会把各自的 `.deb` 附到同一个 Release 上。
- 许可：仓库根目录的 [Apache License 2.0](https://github.com/ssx-computer/superagent/blob/main/LICENSE)
  覆盖本仓库代码。**注意**：修改系统私有 API、以 root 权限运行命令带来的一切后果由使用者自行承担；
  本项目仅供在自有设备上研究与自动化使用。
