# 架构

## 进程与角色

| 组件 | 身份 | 安装位置 | 职责 |
| --- | --- | --- | --- |
| `iagentd` | root（LaunchDaemon） | `<jbroot>/usr/bin/iagentd` | HTTP/SSE 控制面、agent 循环、工具执行、PTY 终端、cron、会话与日志 |
| `iagent.dylib` | mobile（注入 SpringBoard） | `<jbroot>/Library/MobileSubstrate/DynamicLibraries/` | 悬浮球、控制面板入口、桥接长轮询、HID 触摸/键盘注入、AX 读屏、本地通知 |
| Web UI | —（WKWebView / Safari） | `<jbroot>/usr/share/iagent/web/` | 对话、工具、终端、定时任务、设置、日志 |

拆成两个进程的原因：

1. **权限**：PTY、`posix_spawn`、写系统路径都需要 root；而 HID/AX 必须在 SpringBoard（有窗口服务会话）里执行，守卫进程里做不了。
2. **稳定性**：模型请求、工具执行、终端这类会阻塞的工作放在守护进程里，SpringBoard 里只留一个轻量插件——插件卡住会直接表现为系统 UI 卡住。
3. **可替换**：Web UI 是纯静态文件，改前端不需要重新打包二进制。

## 请求流转

```
浏览器/WKWebView ──HTTP──▶ IAGHTTPServer ──▶ IAGDaemon 路由
                                                 │
                    /api/chat ──▶ IAGAgent.runSession
                                     │  ┌───────────────────────────┐
                                     │  │ 1. 组装消息(会话窗口+     │
                                     │  │    system prompt)         │
                                     │  │ 2. IAGLLM /chat/completions│
                                     │  │    (SSE 流式, 边收边推给  │
                                     │  │     前端 delta/reason)    │
                                     │  │ 3. 有 tool_calls →        │
                                     │  │    IAGToolRegistry 执行   │
                                     │  │    (需要审批则挂起等待    │
                                     │  │     /api/approve)         │
                                     │  │ 4. 结果写回消息, 回到 2   │
                                     │  │    直到没有工具调用或达  │
                                     │  │    到 maxSteps            │
                                     │  └───────────────────────────┘
                                     ▼
                          IAGSessionStore（每会话一个 JSON 文件）

需要设备界面/通知的工具 ──▶ IAGBridge（命令队列）
                                   ▲
                                   │ 插件长轮询 /api/bridge/poll
                                   │ 插件回传 /api/bridge/result
                            iagent.dylib 在 SpringBoard 主线程执行
```

HTTP 服务是手写的（`IAGHTTPServer`）：每连接一个线程，支持 `Content-Length` 请求体、SSE 流（`IAGHTTPStream`，带 10 秒心跳注释行）、静态文件（带路径穿越防护与 `no-cache`）。不依赖任何第三方库。

## Agent 循环（`IAGAgent`）

- 入口 `-runSession:message:eventHandler:`；事件回调推给 SSE：`session`、`delta`、`reason`、`tool_call`、`tool_result`、`approval_required`、`done`、`error`。
- 每次迭代把「会话窗口 + 系统提示」发给模型（`historyLimit` 控制条数上限，窗口不会以 `tool` 消息开头）。
- 工具调用按 `tool_call_id` 回填：先发 `tool_call`（含名字与参数），执行完再发 `tool_result`（含 `ok`/`output`/`error`/`durationMs`），前端用 `[data-call]` 就地替换卡片。
- 工具结果回灌给模型前会截断（`kIAGToolOutputLimit = 16000` 字符），避免一次 `cat` 大文件把上下文顶爆。
- 审批：`approval_required` 事件携带 `id`/`name`/`arguments`/`reason`，`IAGApprovalCenter` 用 `NSCondition` 阻塞该会话线程等待 `/api/approve`，超时后按拒绝处理。
- 中止：`/api/abort` 置位会话的中止标记，同时取消进行中的 LLM 请求（`[llm cancel]`），循环在下一个检查点退出并推送 `done`。
- 未传工具参数时由 `IAGToolRegistry` 统一补齐 `durationMs` / `name` / `dangerous` 三个字段，前端不必自己算。

## 会话与存储

| 路径 | 内容 |
| --- | --- |
| `/var/mobile/Library/iAgent/config.plist` | 全部设置（明文，0644） |
| `/var/mobile/Library/iAgent/sessions/<id>.json` | 一个会话的消息数组（上限 400 条，超出从头裁剪） |
| `/var/mobile/Library/iAgent/cron.json` | 定时任务 |
| `/var/mobile/Library/iAgent/logs/iagentd.log` | 日志（超过阈值自动轮转成 `.1`） |
| `/var/mobile/Library/iAgent/logs/iagentd.{out,err}.log` | LaunchDaemon 的 stdout / stderr |

数据目录固定在 rootfs 上而不是 jbroot 里：RootHide 的随机 jbroot 会随越狱更新变化，用户数据不该跟着消失。这也是插件（mobile）读配置的地方——RootHide 沙箱可能拒绝插件写这里，因此插件侧的写入全部是 best-effort。

## 终端（PTY）

`IAGTerminal` 用 `openpty()` + `fork()` + `login_tty()` 起真 shell（依次尝试 `/bin/sh`、`<jbroot>/bin/sh`、`/var/jb/usr/bin/sh`），每会话一个读线程把输出追加到环形缓冲；前端用 `readSince:` 游标增量拉取（`/api/term/read?since=N`），本地用一个最小 ANSI 模拟器上色。`/api/term/input` 直接写 PTY，`/api/term/resize` 走 `TIOCSWINSZ`，`/api/term/close` 关 fd 并回收子进程。

## 定时任务

5 字段 cron（`分 时 日 月 周`，支持 `*`、`a,b`、`a-b`、`*/n`），`IAGScheduler` 每秒比对一次到期任务，用 `IAGProcess runShell:` 执行并记录 `lastResult` / `lastExitCode` / `nextRun`。任务在守护进程内跑，因此守护进程必须存活。

## 桥接（bridge）

守护进程无法自己点屏幕，所以插件每 20 秒挂一次长轮询：

```
GET /api/bridge/poll?since=<cursor>&wait=20&caps=hid:1,ax:1,notify:cf
→ { "commands": [ {"id":"...","action":"ui_tap","parameters":{...}} ], "cursor": 42 }
POST /api/bridge/result  { "id":"...", "ok":true, "output":"...", "error":"" }
```

- 命令带唯一 `id`，插件执行后回传结果；`caps` 用来告诉守护进程当前可用的后端（HID / AX / 通知），`/api/health` 会把它显示出来。
- 插件把每个动作丢到 SpringBoard 主线程执行，并带超时（普通动作 20 秒，`ui_type` 25 秒），超时返回明确错误而不是一直挂住。
- 桥接离线时，`ui_*` 工具直接返回「桥接未连接」类错误；`notify_send` 会退回守护进程侧的 `CFUserNotification`（在 root 守护进程里不保证可见，因此会同时说明回退原因）。
- `app_launch` / `ui_open_url` 先走桥接（在 SpringBoard 里能拿到完整 LaunchServices 行为），失败再退回守护进程侧的 `LSApplicationWorkspace`。

## 插件内部（`iagent.dylib`）

- **纯构造器**：`__attribute__((constructor))` 里判断 `NSBundle.mainBundle.bundleIdentifier == com.apple.springboard`，延迟 4 秒（等 SpringBoard 的场景就绪）后开始工作。没有任何 `%hook`，因此不依赖 substrate，也不会因为别人 hook 同一方法而互相影响。
- **悬浮球**：一个 `UIWindow`（`windowLevel = 10000001.0`，比键盘还高）。**不调用 `makeKeyAndVisible`**，只设 `hidden = NO`，避免抢走 App 的 key 状态；`windowScene`（iOS 13+）必须显式赋值，否则窗口不显示。自定义 `hitTest:` 让窗口只在悬浮球区域内接收触摸，其余位置直接穿透给下层 App。拖动结束后吸附到左右边缘并把 `bubbleSide` / `bubbleY` 写进配置（失败就只在本次会话内有效）。
- **控制面板**：优先尝试在 SpringBoard 内嵌 `WKWebView`（带标题栏和「浏览器」「关闭」按钮）。iOS 15/16 上 SpringBoard 内嵌 WebKit 有白屏报告，所以设了 6 秒超时：没渲染出来就提示一次、标记本次会话改用 Safari，并自动用系统浏览器打开。页面用 `?token=<token>` 打开，前端会把它存进 `localStorage` 并从地址栏抹掉。
- **触摸注入**：`IOHIDEventCreateDigitizerFingerEvent`（**归一化 0..1 坐标**）作为 child，包进 `IOHIDEventCreateDigitizerEvent` 父事件，`IOHIDEventAppendEvent` 之后在**主线程**用 `IOHIDEventSystemClientDispatchEvent` 投递，并盖上 `IOHIDEventSetSenderID`。字段偏移与顺序来自 XXTouch / ZXTouch 的公开实现，见 `docs/research/ios-private-apis.md`。
- **文本输入**：ASCII 走 HID 键盘事件（USB HID usage 表，含大小写与符号 shift）；CJK 这类没有键位的字符先尝试写无障碍焦点元素的 `value`，失败则写剪贴板 + 模拟 ⌘V，之后还原剪贴板。
- **读屏**：iOS 上没有可用的 C `AXUIElement` API，改用 `AXRuntime.framework` 里的 ObjC 类 `AXElement`（`systemWideElement` → `currentApplication` → `children` 递归，读 `label`/`value`/`identifier`/`frame`）。`ui_tap text=…` 会先尝试直接 `press` 元素，成功就不必点坐标；AX 不可用时明确提示改用坐标。

## 路径解析（rootless 与 RootHide）

`IAGPaths` 不写死任何前缀：

1. 先看自己的可执行文件路径（`_NSGetExecutablePath` / `NSProcessInfo`），往上找到包含 `usr/bin` 的 jbroot；
2. 再尝试 libroothide 的 `JBROOT_PATH` / `jbroot_path()` / `jbroot("/")`（存在才用）；
3. 都没有就按 rootfs（`/`）处理。

由此得到 `IAGJailbreakRoot()`、`IAGRootfs()`、`IAGIsRootless()`，其余路径（数据目录、日志、配置、Web 根目录、candidate 二进制路径）都在此基础上拼出来。`iagentd --print-paths` 可以把这些值直接打出来，排错时非常有用。

依赖库解析靠 rpath：rootless v2 方案同时写入 `/var/jb/*` 与 `@loader_path/.jbroot/*`，所以同一份二进制在 Dopamine 与 RootHide 上都能找到自己的依赖。

## 为什么不用 Logos / substrate

- 插件只需要「被注入 + 起一个窗口 + 起一个线程」，不需要 hook 任何系统方法，因此构造器足够了；
- 少一个 substrate 依赖就少一类版本兼容问题（ElleKit / roothide 注入器 / Substitute 行为各不相同）；
- Makefile 里 `iagent_LOGOSFLAGS = -c generator=internal`，配合源码中零 `%hook`，确保最终 dylib 里不会出现 CydiaSubstrate 的 load command。
