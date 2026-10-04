# iAgent

原生 iOS AI Agent：一个常驻的 root 守护进程（`iagentd`）+ 一个注入 SpringBoard 的 tweak
（`iagent.dylib`）。模型直接调用设备上的工具来操作这台已越狱的 iPhone：跑 shell、读写文件、
启动 App、发提示、管理定时任务、驱动界面（HID/AX）。

**没有 WebDAV，没有云端中间层，没有服务器中转。** 设备上的守护进程直接在回环地址上提供
HTTP + SSE 控制面，并由它自己通过 HTTPS 调用 OpenAI 兼容的模型接口；API Key 只存在本机。

> **状态：源码完成，尚未编译、尚未在真机上运行。** 仓库里的任何"能跑"描述都只是设计意图；
> 截止本文件写入时，本项目**没有经过一次 `make`、没有产出过 `.deb`、没有在任何 iOS 设备上安装或测试**。
> 见 [已查证 / 未查证](#已查证--未查证)。

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
   - 自己编译：见 [docs/build.md](docs/build.md)。
   - 或用 GitHub Actions 云编译：push 到 `main`/`master`（或手动 `workflow_dispatch`），
     在 Actions 的 artifact 里下载 `iagent-rootless-deb`；打 `v*` tag 会自动发布到 Release。
2. **安装**（已越狱的 iOS 15+ 设备）
   - Sileo / Zebra 里打开这个 `.deb` → 安装；或
   - `dpkg -i com.dsh.iagent_1.0.0_iphoneos-arm64.deb`。
3. 安装脚本会创建数据目录、引导 LaunchDaemon、并在最后自动 respring（`sbreload`，
   没有则 `killall -9 SpringBoard`）。respring 后悬浮球出现即安装成功。
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

1. **单击悬浮球** —— 先探测 `/api/health`；daemon 活着就在 SpringBoard 内用 WKWebView 打开面板，
   否则弹一条"守护进程 iagentd 未在运行"的提示。面板加载 6 秒未完成会自动改用浏览器打开
   （SpringBoard 内 WKWebView 在 iOS 15/16 上有空白渲染的公开报告，见
   [docs/research/ios-private-apis.md](docs/research/ios-private-apis.md) §8）。
2. **长按悬浮球** —— 弹出菜单：打开控制面板 / 在浏览器中打开 / 隐藏悬浮球（本次会话内隐藏，
   重启后恢复）/ 取消。悬浮球可拖动，位置与左右侧会写回配置。
3. **Safari 直接访问** `http://127.0.0.1:8080/`（设置里开了 `openInSafari` 后，单击悬浮球直接走
   这条）。配置了 `authToken` 时 URL 带 `?token=<token>`。

面板有五个标签页：聊天、终端、工具、会话、设置（外加 daemon 日志弹窗），全部走同一条
回环 API。

---

## 安全默认值

- **只监听回环**：HTTP 服务器 `bind` 到 `INADDR_LOOPBACK`，代码里写死"loopback only, by design"，
  没有对外监听选项。
- **鉴权可选**：`authToken` 为空时所有 `/api/*` 都不校验（仅 `/api/health` 始终免鉴权，供 UI 探活）；
  一旦设置，除 `/api/health` 外的接口都要求 `X-IAG-Token` 头或 `?token=`。**没有 TLS**，明文 HTTP
  只跑在回环上。
- **审批模式**：`approvalMode` = `auto` | `dangerous` | `always`，默认 `dangerous`。`dangerous`
  下命中所见即所得的破坏性规则（删除、重启、系统目录写入、界面自动化等）会在执行前要求确认。
- **命令黑名单**：`blockedCommands`（默认 10 条，如 `rm -rf /`、`mkfs`、`nvram`）对 `shell_exec`
  无条件生效，返回 403 / 工具失败，与审批模式无关。
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
| [docs/tools.md](docs/tools.md) | 18 个工具的参数表、危险级别、示例与行为说明 |
| [docs/api.md](docs/api.md) | 全部 HTTP 接口、SSE 事件、curl 示例 |
| [docs/security.md](docs/security.md) | 威胁模型、黑名单、审批模式、entitlements、静态数据、加固建议 |
| [docs/build.md](docs/build.md) | 本地 Theos 构建、RootHide 变体、GitHub Actions、产物处理、未验证清单 |
| [docs/research/roothide-dopamine-theos.md](docs/research/roothide-dopamine-theos.md) | RootHide / Dopamine / Theos 工程事实（引用，不复述） |
| [docs/research/ios-private-apis.md](docs/research/ios-private-apis.md) | iOS 私有 API 备忘：HID、AX、PTY、WKWebView、悬浮窗（引用，不复述） |

---

## 已查证 / 未查证

**编写这些文档时对代码可查证的**（逐行读过源码）：接口路径与字段、配置键与默认值、工具参数
schema、危险标记、黑名单与删除保护名单、审批判定分支、HTTP 服务器的连接上限与 SSE 帧格式、
桥接的 command id / cursor / 20 秒连接窗口 / 5 分钟保留期、会话 400 条上限与历史窗口、
PTY 的 512KB 环形缓冲与 8 会话上限、cron 的 5 秒 tick、路径探测顺序、entitlements 与 plist 内容。

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
  root daemon 调用能否显示 —— memo 2 §5.2 / §6.2 / §13。因此 `app_launch` 与 `notify_send` 都实现了
  "先 daemon 自己试、失败再交给桥接"的回退链，但两条链都未在设备上验证。
- HID 键位映射、`IOHIDEventSystemClientCreate` 在 iOS 15/16 上的实际可用性 —— memo 2 §3 有已查证的
  调用序列，但本项目没有跑过一次注入。
- PTY：以 `mobile` 身份开 PTY 的权限差异、多会话上限 —— memo 2 §13 第 8 条。

上述每一条都应该按 memo 里的真机验证清单复核后再当作事实。
