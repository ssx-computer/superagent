# 安全模型

## 一句话总结

`iagentd` 以 **root、无沙箱**运行，模型能通过它执行任意 shell 命令——所以「安全边界」不在于工具白名单，而在于：**谁能访问这个 HTTP 接口**、**审批模式设成什么**、以及**你自己给模型多大权限**。本文把默认防线、真实的弱点、以及加固建议都写清楚。

## 攻击面

| 面 | 默认状态 | 风险 |
| --- | --- | --- |
| HTTP 接口 | 只绑定 `127.0.0.1:8080`，无 TLS | 设备上任何能发本地 HTTP 的进程都能访问；同网段设备访问不到（除非手动改 `port`/绑定地址） |
| 鉴权 | `authToken` 默认空 = 不校验（`/api/health` 永远免鉴权） | 空令牌时，本机任何进程都能调用 `/api/exec`、`/api/chat` |
| 会话令牌 | `X-IAG-Token` 或 `?token=`，明文 | 令牌存在 `config.plist`（0644），越狱环境下以 mobile 身份运行的任何进程都读得到 |
| 模型服务 | 你填的 `baseUrl`，用 `apiKey` 认证 | 会话内容（含命令输出、文件内容）会发到该服务；用第三方中转等于把设备内容交给对方 |
| 工具执行 | root，无沙箱 | `shell_exec` 等于把 root shell 交给模型 |
| Web UI | 静态文件 + `localStorage['iag_token']` | 面板本身不做额外鉴权，令牌由页面从 URL/表单取得 |

`Depends` 里不含 `mobilesubstrate`；插件不申请任何 entitlement，它复用 SpringBoard 自身的权限。守护进程的 entitlements 在 `entitlements.plist`：

```xml
platform-application
com.apple.private.security.no-sandbox
com.apple.private.security.storage.AppBundles
com.apple.private.security.storage.AppDataContainers
```

这四项来自 XXTouch 的公开 plist（见 `docs/research/ios-private-apis.md`），目的是让守护进程能读写应用容器、起 PTY。它们在 iOS 15/16 上的实际接受度**未在真机验证**。

## 三层防线

### 1. 审批（默认开启）

`approvalMode` 三档：

| 模式 | 行为 |
| --- | --- |
| `auto` | 从不询问，工具直接执行 |
| `dangerous`（默认） | 只对下列情况暂停等待 `/api/approve` |
| `always` | 每个工具调用都要确认 |

`dangerous` 模式下会触发确认的具体条件（`IAGToolRegistry approvalReasonForTool:arguments:config:`）：

| 工具 | 触发条件 |
| --- | --- |
| `shell_exec` | 命令命中内置可疑模式（见下） |
| `fs_delete` | 总是 |
| `fs_write` | 目标路径以 `/System`、`/var/jb/Library`、`/private` 开头 |
| `ui_describe` / `ui_tap` / `ui_type` / `ui_swipe` / `ui_open_url` | 总是（会操作设备界面） |
| `app_launch` | 当该工具被标记为危险时 |
| `cron_add` | 总是（会在后台自动执行命令） |
| `notify_send` | 不触发 |
| 其他被 `isDangerous` 标记的工具 | 总是 |

内置可疑命令模式（`+commandLooksDangerous:`，只触发确认，不是硬拦截）：`rm -rf /`、`rm -rf /var`、`rm -rf /System`、`mkfs`、`dd if=`、`dd of=/dev/disk`、`> /dev/disk`、`shutdown`/`reboot`/`halt`/`sbreload`/`respring`、`launchctl bootout`/`unload`/`disable`、`killall -9`、`killall springboard`、`killall backboardd`、`chmod -r 000`、`chown -r`、fork bomb 形式、`dpkg -r`/`apt remove`/`sileo`、`nvram`、`mount -uw`、`snapshot`、`passwd`、`sudo rm`、`mv /system`、`mv /var`、`| sh`/`| bash`、`curl -o /`、`ssh `、`scp `，以及任何 `> /` 重定向。

审批在界面上的形态：对话流里插入一张确认卡片（工具名、原因、参数），`/api/approve` 回传 `{id, allow}`；超时（默认等待上限见 `IAGApprovalCenter`）按拒绝处理，模型会收到「被拒绝」的工具结果并继续推理。

### 2. 硬拦截

- `blockedCommands`（配置项，默认空）：命中即**直接拒绝执行**，与审批模式无关，且不会给模型第二次机会。适合放你自己绝对不想要的命令（例如 `apt upgrade`）。三个 shell 入口（`/api/chat` 的工具循环、`/api/tools/call`、面板里的 `/api/exec` 快速命令）都会查它。
- `fs_delete` 的不可删除清单（`IAGPathIsProtectedFromDelete`）：

  - 精确匹配：`/`、`/var`、`/System`、`/private`、`/Applications`、`/usr`、`/bin`、`/sbin`、`/etc`、`/Library`、`/var/jb`、`/var/mobile`、`/var/containers`、`/var/root`、`/private/var`、`/private/var/db`、`/private/var/lib`、`/private/etc`、`/var/jb/Library`、`/var/jb/usr`、`/var/jb/usr/lib`、`/var/jb/Library/dpkg`、`/var/jb/Applications`、`/var/jb/Library/MobileSubstrate`
  - 前缀匹配：`/private/var/db/`、`/var/jb/Library/dpkg/`、`/private/etc/`、`/var/jb/Library/MobileSubstrate/DynamicLibraries/`

  命中时 `fs_delete` 返回失败，模型只能换个理由再说一次——**它无法绕过这个检查**，因为检查在工具实现里，不在提示词里。

- 工具开关：`toolsEnabled` 可以逐个关掉工具（默认全开）。关掉的工具不会出现在模型可见的 function 列表里。

### 3. 输出与日志

- 工具输出回灌给模型前截断到 16000 字符，避免一次读取把上下文和费用顶爆；
- `requestLogging` 打开后会把模型请求/响应写进日志（含会话内容），排错用，默认关闭；
- 日志文件 `/var/mobile/Library/iAgent/logs/iagentd.log` 为 0644，超过阈值自动轮转为 `.1`（只保留一代）。

## 静态数据

| 数据 | 位置 | 权限 | 说明 |
| --- | --- | --- | --- |
| 全部设置（含 `apiKey`、`authToken`、`baseUrl`） | `/var/mobile/Library/iAgent/config.plist` | 0644，root 写、mobile 读 | **明文**，没有钥匙串。RootHide 下插件写它可能失败 |
| 会话历史 | `/var/mobile/Library/iAgent/sessions/*.json` | 0644 | 含完整对话与工具输出（可能包含密码、token 等命令里出现过的字符串） |
| 定时任务 | `/var/mobile/Library/iAgent/cron.json` | 0644 | 含要执行的命令 |
| 日志 | `/var/mobile/Library/iAgent/logs/` | 0644 | 视 `logLevel` 可能含命令与输出 |

App Store 应用受沙箱限制读不到 `/var/mobile/Library/`，但这在越狱设备上不是安全边界：**任何越狱进程、任何 tweak 都能读到明文 API Key**。

## 加固建议

1. **设置 `authToken`**：随机 32 位以上字符串，之后用 `?token=` 或 `X-IAG-Token` 访问。面板地址栏会带上它，注意截图/分享别泄露。
2. **保持 `dangerous` 或直接用 `always`**：`auto` 只建议在你完全信任的测试设备上使用，且此时最好把 `toolsEnabled.shell_exec` 关掉。
3. **把决定权留给审批**：审批卡片会显示真实命令与参数，别养成无脑点「允许」的习惯。
4. **关掉用不到的工具**：只用对话就关掉 `shell_exec` / `ui_*` / `fs_delete`。
5. **`blockedCommands` 放硬规则**：例如 `["apt upgrade", "apt-get upgrade", "rm -rf", "> /var"]`。
6. **不要把端口暴露出去**：不要改绑定地址；确实需要远程访问就用 SSH 隧道（`ssh -L 8080:127.0.0.1:8080 root@device`）。
7. **API Key 用最小权限**：给一个专门的 key，设置用量上限；中转服务要当心，它能看到全部会话内容。
8. **定期清理**：`sessions/`、`logs/` 里可能留着敏感内容，卸载时 `prerm` 不会删除数据目录，需要手动 `rm -rf /var/mobile/Library/iAgent`。
9. **降低日志等级**：不需要排错时把 `logLevel` 设为 `warn`，并保持 `requestLogging = false`。

## 已知弱点（诚实清单）

- `shell_exec` 的实现是 `sh -c`，黑名单是**字符串包含**匹配——绕过方式很多（编码、变量拼接、别名、写脚本再执行）。它是给模型的行为护栏，不是安全边界。真正的边界是审批 + 你的判断。
- `authToken` 为空时，本机任何进程都能调用全部接口（包括 `/api/exec`）。
- HTTP 无 TLS：回环上的抓包/中间人理论可行（本机恶意进程），令牌是明文 header。
- 面板的令牌存在 `localStorage`，WKWebView 与 Safari 各自一份。
- 插件的 HID/AX 能力等于「能操作整台设备的界面」，`ui_*` 的审批是唯一的闸门。
- `preflight.py` 只做结构检查；真正的编译期与运行期验证仍未完成（见 `docs/build.md`）。
