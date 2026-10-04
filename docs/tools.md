# iAgent 工具参考

本文档描述 iAgent daemon 中注册的全部 18 个工具。所有事实来自
`daemon/IAGTool.h`、`daemon/IAGTool.m`、`daemon/IAGToolShell.m`、`daemon/IAGToolFile.m`、
`daemon/IAGToolDevice.m`，以及桥接侧的 `daemon/IAGBridge.m`、`tweak/IAGAutomation.*`、
`tweak/IAGTweak.m`。**未编译、未运行验证**；标称"商用实现旁证/未查证"的地方保留原措辞。

---

## 1. 工具是什么

工具是 **OpenAI 风格的 function tool**：注册表把它们导出成模型请求里的 `tools` 数组，元素形如

```json
{
  "type": "function",
  "function": {
    "name": "shell_exec",
    "description": "在这台 iOS 设备上执行一条 shell 命令……",
    "parameters": { "type": "object", "properties": { "command": { "type": "string", "description": "要执行的 shell 命令" } }, "required": ["command"] }
  }
}
```

模型看到的只有三样东西：`name`（snake_case）、`description`（一两句中文，因为模型用中文回答）、
`parameters`（JSON Schema 对象）。定义由 `IAGToolRegistry -openAIToolDefinitionsWithConfig:`
生成，**按 `category` 过滤**：`config.toolEnabled:category` 返回 NO 的类别整类不出现在模型面前
（`toolsEnabled` 的 7 个键默认全为 `@YES`）。

同一批工具也可以从 Web UI 直接调用（同一套注册表、同一个执行入口）：

| 接口 | 方法 | 说明 |
|---|---|---|
| `/api/tools` | GET | 返回 `{"tools": [...]}`，每项含 `name`、`description`、`category`、`dangerous`、`enabled`、`parameters`。**注意：这个列表不做配置过滤**，被禁用的工具仍然出现，只是 `enabled` 为 `false`（与 `IAGTool.h` 里"respects the configuration filter"的注释不符）。 |
| `/api/tools/call` | POST | body `{"name": "...", "arguments": {...}}`，未知工具返回 404 `未知工具 <name>`；命中命令行黑名单返回 403。**这条路径只检查黑名单，不经过审批策略**（审批只在 agent 循环里做）。 |

注册表位于 `IAGToolRegistry`（`+shared` 单例，实现在 `daemon/IAGTool.m`）。`-registerDefaults`
通过 `dispatch_once` 依次调用 `IAGRegisterShellTools` / `IAGRegisterFileTools` /
`IAGRegisterDeviceTools`（这三个 C 函数分别定义在 `IAGToolShell.m`、`IAGToolFile.m`、
`IAGToolDevice.m` 末尾）；`-registerToolClass:` 只接受实现了 `IAGTool` 协议、且 `+toolName`
非空的类，同名工具后注册的覆盖先注册的（幂等）。

每个工具都是无状态类，调用时所需的一切通过 `IAGToolContext`（`config`、`sessionId`、`bridge`）传入。

---

## 2. 工具总表

顺序与 `IAGRegister*` 函数中的注册顺序一致。类别与危险标记取自各工具的 `+category` / `+isDangerous`。

| 工具 | category | 危险 | 一句话 |
|---|---|---|---|
| `shell_exec` | shell | 是 | 通过 `/bin/sh -c` 执行一条命令，返回退出码、stdout、stderr；无交互 TTY |
| `http_fetch` | http | 否 | 发起一次 HTTP 请求，HTML 转成纯文本后返回 |
| `fs_read` | file | 否 | 读文本文件（默认最多 256KB，可分段），二进制只返回元信息与十六进制摘要 |
| `fs_write` | file | 是 | 写文本（默认覆盖，`append=true` 追加），默认自动建父目录并 chmod 0644 |
| `fs_list` | file | 否 | 列目录（不递归），返回类型、权限、大小、修改时间；默认含隐藏文件 |
| `fs_search` | file | 否 | 按正则搜内容（类 grep -rn）或按文件名通配符找文件 |
| `fs_delete` | file | 是 | 删除文件/目录；命中硬性保护名单直接拒绝 |
| `app_list` | app | 否 | 列出已安装应用的 bundle id 与显示名（最多返回 400 条） |
| `app_launch` | app | 否 | 按 bundle id 启动应用，或打开一个 URL/scheme |
| `notify_send` | notify | 否 | 弹一条可见提示；桥接不可用时退回 `CFUserNotification` |
| `cron_add` | cron | 是 | 用 5 字段 cron 表达式创建定时任务 |
| `cron_list` | cron | 否 | 列出所有定时任务及上次结果、下次运行时间 |
| `cron_remove` | cron | 是 | 按任务 id 删除定时任务 |
| `ui_describe` | ui | 否 | 读当前前台界面的可交互元素（无障碍树）与屏幕坐标 |
| `ui_tap` | ui | 是 | 点按：给 `x`/`y` 坐标，或给 `text` 让插件查找并点击 |
| `ui_type` | ui | 是 | 向当前焦点输入框输入文本 |
| `ui_swipe` | ui | 是 | 从 (x1,y1) 滑到 (x2,y2)，默认 0.3 秒 |
| `ui_open_url` | ui | 否 | 打开 URL / URL Scheme（会离开当前 App） |

`category` 的合法值在 `IAGTool.h` 中写着 `"shell" | "file" | "app" | "notify" | "cron" | "ui" | "http"`，
与上面 18 个实现一一对应（注意 `http_fetch` 属于 `http` 而不是 `shell`，尽管它和 `shell_exec`
在同一个文件里注册）。

---

## 3. 文件路径规则（`fs_*` 通用）

### 3.1 `IAGExpandPath`（`IAGToolFile.m`）

`fs_read`、`fs_write`、`fs_delete` 对 `path` 一律先展开；`fs_list`、`fs_search` 只在**显式提供了
`path`** 时才展开，否则直接用 `config.workDir`。展开顺序：

1. `~/xxx` → `NSHomeDirectory()` + `/xxx`；恰好 `~` → `NSHomeDirectory()`。
   仅处理 `~/` 与单独的 `~`，**不处理 `~user`**。
2. 字符串里出现 `$IAG_JBROOT` 或 `${IAG_JBROOT}` → 替换为 `IAGJailbreakRoot()`
   （RootHide/rootless 布局下是 `/var/jb`，rootful 下是 `/`；检测顺序为环境变量
   `IAG_JBROOT` → libroothide → 自身可执行文件路径 → `/var/jb`，都不成立则 `/`）。
3. 展开后仍不以 `/` 开头 → 相对路径，前置 `config.workDir`（默认 `/var/mobile`；
   `workDir` 为空时用 `/var/mobile`）。
4. 最后做 `stringByStandardizingPath`（消掉 `.`、`..`、重复斜杠）。

除上述三种形式外没有别的展开：`$HOME`、其它环境变量、`~user` 都原样保留。

`shell_exec` 的 `cwd` **不**走 `IAGExpandPath`：它直接用参数原值判目录，不是目录时回退到
`config.workDir`，再不行回退 `/var/mobile`。

### 3.2 `IAGPathIsProtectedFromDelete`（`IAGToolFile.m`）

`fs_delete` 在展开并标准化路径、去掉尾部斜杠之后，先比对这张硬性名单，命中即拒绝
（错误文本 `拒绝删除受保护路径 <path>（该路径在硬性保护名单中）`），不看配置、不可绕过。

精确匹配（展开后的完整路径必须等于其中之一）：

```
/                                    /var
/System                              /private
/Applications                        /usr
/bin                                 /sbin
/etc                                 /Library
/var/jb                              /var/mobile
/var/containers                      /var/root
/private/var                         /private/var/db
/private/var/lib                     /private/etc
/var/jb/Library                      /var/jb/usr
/var/jb/usr/lib                      /var/jb/Library/dpkg
/var/jb/Applications                 /var/jb/Library/MobileSubstrate
```

前缀匹配（以其中之一开头即受保护，含子目录）：

```
/private/var/db/
/var/jb/Library/dpkg/
/private/etc/
/var/jb/Library/MobileSubstrate/DynamicLibraries/
```

---

## 4. 工具详情

以下每个工具的参数表逐字取自代码里的 JSON Schema 字面量（"含义"列即 schema 的 `description`）；
"默认/范围"列取自执行函数里的实际取值与钳制逻辑。示例统一写成 `/api/tools/call` 的请求体形状。

### 4.0 `shell_exec`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `command` | string | 是 | — | 要执行的 shell 命令 |
| `cwd` | string | 否 | `config.workDir`（默认 `/var/mobile`）；不是目录时回退 `workDir` → `/var/mobile` | 工作目录，默认使用设置里的工作目录 |
| `timeout` | integer | 否 | `config.shellTimeout`（默认 30）；`<=0` 取配置值，`>1800` 钳到 1800 | 超时秒数，默认取设置值（最长 1800） |

执行：`/bin/sh -c`（支持管道、重定向、变量），`maxOutput` 512KB。超时会被 SIGKILL。

返回（`output` 文本）：

```
exit_code: <退出码>
duration: <.2f>s
cwd: <实际工作目录>
timeout: 是（超过 <N> 秒后已被 SIGKILL）          # 仅超时时
note: 输出超过 512KB，已截断                      # 仅进程输出被截断时
--- stdout ---
<stdout>                                          # 非空时
--- stderr ---
<stderr>                                          # 非空时
(无输出)                                          # stdout/stderr 都为空时
```

整段在返回前经 `IAGTruncateForModel(..., 24000)`。启动失败返回
`命令启动失败: <launchError>`；缺 `command` 返回 `缺少 command 参数`。

```json
{
  "name": "shell_exec",
  "arguments": {
    "command": "ls -la /var/mobile/Documents | head -20",
    "cwd": "/var/mobile",
    "timeout": 30
  }
}
```

---

### 4.1 `http_fetch`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `url` | string | 是 | 无 scheme 时自动补 `https://` | 完整 URL，必须包含 http:// 或 https:// |
| `method` | string | 否 | `GET`；枚举 `GET`/`POST`/`PUT`/`PATCH`/`DELETE`/`HEAD` | HTTP 方法，默认 GET |
| `headers` | object | 否 | — （只有字符串值会被采用） | 额外请求头（键值都是字符串） |
| `body` | string | 否 | 无 body 时不设置 | 请求体（POST/PUT 时使用）；未显式给 `Content-Type` 时自动补 `application/json` |
| `timeout` | integer | 否 | 30；`<=0`→30，`>300`→300；信号量等待 `timeout + 10` 秒 | 超时秒数，默认 30 |
| `max_bytes` | integer | 否 | 262144；`<1024`→1024，`>4*1024*1024`→4MB | 最多读取的字节数，默认 262144 |

固定请求头：`User-Agent: iAgent/1.0 (iOS; +on-device agent)`、
`Accept: text/html,application/json,text/plain,*/*`。

返回（`output` 文本）：

```
status: <HTTP 状态码>
url: <最终 URL>
content_type: <Content-Type>              # 有才输出
bytes: <响应总字节数>[ (已截断)]
--- body ---
<正文>                                     # HTML 经 IAGHTMLToText 转纯文本；空响应显示 (空响应)
(二进制响应，<N> 字节，未作为文本返回)      # 非文本类型时，只有上面几行
```

"文本类型"的判定：`Content-Type` 含 `html` / `text` / `json` / `xml`，或 `Content-Type` 为空。
截断 `max_bytes` 之外的字节不参与正文。整段经 `IAGTruncateForModel(..., 24000)`。
超时返回 `请求超时（<N> 秒）: <url>`；传输错误返回 `请求失败: <localizedDescription>`；
缺 `url` 返回 `缺少 url 参数`；URL 无法解析返回 `URL 无效: <url>`。

```json
{
  "name": "http_fetch",
  "arguments": {
    "url": "https://example.com/api/status",
    "method": "GET",
    "headers": { "Accept-Language": "zh-CN" },
    "timeout": 30,
    "max_bytes": 262144
  }
}
```

---

### 4.2 `fs_read`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `path` | string | 是 | 经 `IAGExpandPath` | 文件路径（绝对路径，或相对工作目录） |
| `offset_bytes` | integer | 否 | 0；`<0`→0 | 起始字节偏移，默认 0 |
| `max_bytes` | integer | 否 | 262144；`<1`→262144，`>8*1024*1024`→8MB | 最多读取字节数，默认 262144 |

返回（`output` 文本）：

```
path: <展开后的绝对路径>
size: <st_size> bytes
mode: <八进制权限>  uid: <uid>  gid: <gid>
mtime: <本地化中等日期时间>

# 二进制（前 8000 字节里出现 0x00 即判定）：
(二进制文件，已跳过内容，返回前 <N> 字节的十六进制摘要)
<每行 16 字节的 hex，最多 128 字节>

# 文本：
read: <实际读取字节数> bytes[ (文件未读完)]
--- content ---
<内容>
```

文本分支整段经 `IAGTruncateForModel(..., 24000)`；二进制分支直接返回，不截断。
错误：`缺少 path 参数`、`文件不存在或无法访问: <path> (<strerror>)`、`<path> 是目录，请使用 fs_list`、
`无法打开文件: <path>`、`读取失败: <exception.reason>`。

```json
{
  "name": "fs_read",
  "arguments": {
    "path": "/var/mobile/Library/Preferences/com.apple.Accessibility.plist",
    "offset_bytes": 0,
    "max_bytes": 262144
  }
}
```

---

### 4.3 `fs_write`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `path` | string | 是 | 经 `IAGExpandPath` | 目标文件路径 |
| `content` | string | 是 | — （键必须存在；空串合法） | 要写入的文本内容 |
| `append` | boolean | 否 | `false` | true 表示追加，默认 false（覆盖） |
| `create_dirs` | boolean | 否 | `true` | 是否自动创建父目录，默认 true |

行为：`create_dirs` 为真且父目录不存在时逐级创建；覆盖走 `NSDataWritingAtomic`；追加走
`NSFileHandle`，文件不存在则直接创建；**无论哪条路径，结束后都会 `chmod 0644`**
（让 root daemon 写的文件 mobile 用户可读）。目标是目录时返回 `<path> 是目录`。

返回（`output` 文本）：

```
ok: 覆盖|追加
path: <展开后的路径>
bytes_written: <本次写入字节数>
file_size: <写入后的文件大小>
previous_size: <写入前大小>     # 覆盖/追加一个已存在的文件时
created: true                   # 原来不存在时
```

此工具不调用 `IAGTruncateForModel`。错误：`缺少 path 参数`、`缺少 content 参数`、
`无法创建目录 <parent>: <原因>`、`无法创建文件: <path>`、`追加失败: <原因>`、`写入失败: <原因>`。

```json
{
  "name": "fs_write",
  "arguments": {
    "path": "/var/mobile/Documents/iagent-note.txt",
    "content": "hello from iAgent\n",
    "append": false,
    "create_dirs": true
  }
}
```

---

### 4.4 `fs_list`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `path` | string | 否 | `config.workDir`（默认 `/var/mobile`）；提供时才经 `IAGExpandPath` | 目录路径，默认工作目录 |
| `show_hidden` | boolean | 否 | `true` | 是否显示隐藏文件，默认 true |
| `max_entries` | integer | 否 | 300；`<1`→300，`>5000`→5000 | 最多返回条目数，默认 300 |

Schema 里**没有** `required`。不递归。先 `contentsOfDirectoryAtPath:`，失败则回退
`opendir`/`readdir`（注释说明：`contentsOfDirectoryAtPath:` 会跟随沙盒，回退到 readdir）。

返回（`output` 文本）：

```
path: <绝对路径>
entries: <总数> (目录 <D>, 文件 <F>)[ [已截断]]

<每行一条，先目录后文件，各自按名称排序>
<类型><权限9位> <右对齐10位大小> <YYYY-MM-DD HH:MM> <名称>
```

类型字符：`d` 目录、`l` 符号链接、`-` 普通文件、`c` 字符设备、`b` 块设备、`p` FIFO、`s` socket；
大小列对目录显示 `-`。条目按 `max_entries` 截断（超限时头部标注 `[已截断]`），
此工具不调用 `IAGTruncateForModel`。错误：`目录不存在: <path>`、
`无法列出目录 <path>: <原因|permission denied>`。

```json
{
  "name": "fs_list",
  "arguments": {
    "path": "/var/mobile/Documents",
    "show_hidden": true,
    "max_entries": 300
  }
}
```

---

### 4.5 `fs_search`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `path` | string | 否 | `config.workDir`；提供时才经 `IAGExpandPath` | 搜索起始目录，默认工作目录 |
| `pattern` | string | 否 | — | 正则表达式；留空则只按文件名匹配 |
| `file_glob` | string | 否 | — | 文件名通配符，如 *.plist 或 *.log |
| `case_sensitive` | boolean | 否 | `false` | 是否区分大小写，默认 false |
| `max_results` | integer | 否 | 80；`<1`→80 | 最多返回匹配行数，默认 80 |
| `max_files` | integer | 否 | 3000；`<1`→3000 | 最多扫描文件数，默认 3000 |

Schema 没有 `required`，但代码要求 `pattern` 与 `file_glob` **至少给一个**，否则
`请至少提供 pattern 或 file_glob 之一`。

遍历规则：迭代式（非递归）广度优先，跳过符号链接、非普通文件、大于 4MB 的文件，
跳过二进制文件（前 8000 字节含 `0x00`）；`file_glob` 用 `SELF LIKE` 谓词匹配文件名。
给定 `pattern` 时逐行匹配，每行截到前 400 字符并去掉首尾空白。正则无效返回
`正则表达式无效: <原因>`；目录不存在返回 `目录不存在: <path>`。

返回（`output` 文本）：

```
path: <起始目录>
pattern: <pattern>            # 给了才输出
file_glob: <glob>             # 给了才输出

<绝对路径>                    # 只按文件名匹配时，每行一个文件
<绝对路径>:<行号>: <行内容>   # 有 pattern 时
(没有匹配)                    # 无命中

已扫描 <N> 个文件 / <M> 个目录，匹配 <K> 处[（达到上限，可能还有更多）]
```

整段经 `IAGTruncateForModel(..., 24000)`。

```json
{
  "name": "fs_search",
  "arguments": {
    "path": "/var/mobile/Library/Preferences",
    "pattern": "WiFi",
    "file_glob": "*.plist",
    "case_sensitive": false,
    "max_results": 80,
    "max_files": 3000
  }
}
```

---

### 4.6 `fs_delete`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `path` | string | 是 | 经 `IAGExpandPath` | 要删除的路径 |
| `recursive` | boolean | 否 | `false` | 删除目录时需要设置为 true |

执行顺序：展开路径 → `IAGPathIsProtectedFromDelete` 检查 → 存在性检查 →
若是目录且 `recursive` 不为真则拒绝 → `removeItemAtPath:`。

返回：`已删除: <path>`，递归时追加 ` (递归)`。

错误：`缺少 path 参数`、`拒绝删除受保护路径 <path>（该路径在硬性保护名单中）`、
`路径不存在: <path>`、`<path> 是目录；如确认要整个删除，请设置 recursive=true`、
`删除失败: <原因>`。此工具不调用 `IAGTruncateForModel`。

```json
{
  "name": "fs_delete",
  "arguments": {
    "path": "/var/mobile/Documents/iagent-note.txt",
    "recursive": false
  }
}
```

---

### 4.7 `app_list`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `filter` | string | 否 | 空（不过滤） | 可选：按 bundle id 或名称做不区分大小写的子串过滤 |

数据来源：优先 `LSApplicationWorkspace.allInstalledApplications`（通过
`dlopen` 四个候选路径后 `NSClassFromString` 取得，`MobileCoreServices` /
`LaunchServices` / `CoreServices`，不硬链接私有框架）；取不到时回退遍历
`/var/containers/Bundle/Application`、`/Applications`、`<jailbreakRoot>/Applications`
下的 `*.app/Info.plist`（`CFBundleIdentifier`，名称取 `CFBundleDisplayName` →
`CFBundleName`）。结果按 bundle id 排序。

返回：`共 <N> 个应用[（已过滤）]：\n<bundleId>\t<显示名>`（每个应用一行），
最多输出 400 条（`shown >= 400` 即停）。无命中返回
`没有找到匹配 <filter|(全部)> 的应用（共扫描到 <N> 个）`。

```json
{
  "name": "app_list",
  "arguments": { "filter": "settings" }
}
```

---

### 4.8 `app_launch`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `bundle_id` | string | 否 | — | 应用的 bundle id（与 url 二选一） |
| `url` | string | 否 | — | 要打开的 URL 或 scheme（与 bundle_id 二选一） |

Schema 没有 `required`，运行时两者都为空则返回 `请提供 bundle_id 或 url 之一`。两个都给时
**优先处理 `url`**。

- `url`：先走 daemon 内的 LaunchServices（`openSensitiveURL:withOptions:` → `openURL:`，
  最后兜底 PATH 里的 `open` 命令）；失败再让 bridge 执行 `open_url`（超时 8 秒）。
- `bundle_id`：先 `openApplicationWithBundleID:`，失败回退 `SpringBoardServices` 的
  `SBSLaunchApplicationWithIdentifier`；再失败让 bridge 执行 `launch_app`（超时 8 秒）。

返回：`已启动 <bundleId>` 或 `已打开 URL: <url>`；经 bridge 成功时直接返回 bridge 的
`output`。失败：`无法打开 URL: <url>（<bridge 错误|LaunchServices 拒绝>）` /
`无法启动 <bundleId>（<bridge 错误|未找到该应用或系统拒绝>）`。

```json
{
  "name": "app_launch",
  "arguments": { "url": "prefs:root=WIFI" }
}
```

---

### 4.9 `notify_send`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `title` | string | 否 | `iAgent` | 标题，默认 iAgent |
| `message` | string | 是 | — | 正文内容 |
| `duration` | integer | 否 | 4；`<1`→1，`>60`→60 | 显示秒数，默认 4 |

执行：先让 bridge 执行 `notify`（超时 5 秒，参数 `title`/`message`/`duration`）；失败则在本进程用
`CFUserNotificationCreate`（`kCFUserNotificationNoteAlertLevel`，按钮标题 `好`，`TopMost`）。

返回：
- bridge 成功：`已通过 SpringBoard 显示提示：<message>`
- 回退成功：`已通过 CFUserNotification 显示提示（<bridge 错误|桥接不可用>）: <message>`
- 全部失败：`无法显示提示（<bridge 错误|桥接不可用>，CFUserNotification 错误码 <N>）`
- 缺参数：`缺少 message 参数`

```json
{
  "name": "notify_send",
  "arguments": { "title": "iAgent", "message": "任务已完成", "duration": 4 }
}
```

---

### 4.10 `cron_add`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `schedule` | string | 是 | — | cron 表达式，5 个字段（分 时 日 月 周，支持 `*` `a` `a-b` `a,b` `*/n` `a-b/n`，设备本地时区） |
| `command` | string | 是 | — | 要执行的 shell 命令 |
| `enabled` | boolean | 否 | `true` | 是否立即启用，默认 true |

交给 `IAGScheduler -addTaskWithSchedule:command:enabled:error:`；失败返回
`<error>`（取不到时 `创建定时任务失败`）。

返回（`output` 文本）：

```
已创建定时任务 <taskId>
表达式: <schedule>
命令: <command>
启用: 是|否
下次运行: <本地化日期时间|未计算>
```

```json
{
  "name": "cron_add",
  "arguments": {
    "schedule": "*/10 * * * *",
    "command": "echo tick >> /var/mobile/Documents/tick.log",
    "enabled": true
  }
}
```

---

### 4.11 `cron_list`

无参数（schema 为 `{"type":"object","properties":{}}`）。

返回：无任务时 `当前没有定时任务。`；否则每个任务一段：

```
<taskId> [启用|暂停] <schedule>
  命令: <command>
  上次: <短日期时间|从未> (exit=<上次退出码>) <上次输出>
  下次: <短日期时间|—>
```

```json
{
  "name": "cron_list",
  "arguments": {}
}
```

---

### 4.12 `cron_remove`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `id` | string | 是 | — | 任务 id，如 cron-1 |

返回：`已删除定时任务 <id>`。错误：`缺少 id 参数`、`没有找到定时任务 <id>`。

```json
{
  "name": "cron_remove",
  "arguments": { "id": "cron-1" }
}
```

---

### 4.13 `ui_describe`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `max_elements` | integer | 否 | 60（Tweak 侧 `<=0` 也回到 60） | 最多返回元素数，默认 60 |

执行：bridge 动作 `ui_describe`（超时 12 秒），参数 `max_elements`。返回的 `output`
按 `IAGTruncateForModel(..., 12000)` 截断后交给模型。失败时返回 bridge 的 `error`
（取不到时 `无法读取界面`）。

Tweak 侧（`IAGTweak.m` / `IAGAutomation.m`）在无障碍后端不可用时用**错误**而不是空列表回答，
三种原文分别是：

```
无障碍接口不可用（<backend>）。请用 ui_tap 的 x/y 坐标方式操作。
AXElement 未能返回前台应用（无障碍服务不可达）。请改用 ui_tap 的 x/y 坐标方式操作界面。
前台界面没有可读元素（可能是全屏画面或无障碍树为空）。请改用 ui_tap 的 x/y 坐标方式操作界面。
```

（`backend` 来自 `IAGAX -backendDescription`；无后端时展开为 `unknown`。）
元素逐条输出 `IAGAXElement -oneLineDescription`，遍历深度上限 8，预算即 `max_elements`。

```json
{
  "name": "ui_describe",
  "arguments": { "max_elements": 60 }
}
```

---

### 4.14 `ui_tap`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `x` | number | 否 | — | 横坐标（点） |
| `y` | number | 否 | — | 纵坐标（点） |
| `text` | string | 否 | — | 要查找并点击的元素文字（与 x/y 二选一） |
| `index` | integer | 否 | 0（Tweak 侧再 `MAX(0, index)`） | 匹配到多个元素时选择第几个，从 0 开始，默认 0 |
| `long_press` | boolean | 否 | `false` | 是否长按，默认 false |

Schema 没有 `required`。daemon 侧前置校验：`text` 非空 **或** `x`、`y` **同时存在**，
否则返回 `请提供 x/y 或 text`；通过后把整个 `arguments` 原样交给 bridge 的 `ui_tap`（超时 12 秒）。

点击链（`IAGTweak.m`，与 `IAGAutomation.h` 的注释一致）：

1. 给了 `text` → `IAGAX -locateText:index:point:label:` 在当前前台界面的元素里找
   label/value/identifier 包含该文本的第 `index` 个元素；
   - 元素支持激活时**直接 `press`（无障碍按压）**，返回 `已通过无障碍动作点击 <label>`；
   - 没有激活成功但拿到了元素中心坐标 → HID 合成点击，返回 `已在 (x,y) 点击 <label>`；
   - HID 不可用 → 失败 `触摸注入不可用（HID 后端缺失）`；
   - 没找到元素 → 失败 `当前界面没有找到包含「<text>」的可点击元素，请用 ui_describe 查看元素或改用 x/y 坐标`。
2. 没给 `text` → 必须有 `x`/`y`，否则 `需要 x/y 坐标，或提供 text 让插件查找元素`；
   只走 HID 合成点击，失败即 `触摸注入不可用（HID 后端缺失）`，成功返回 `已在 (x,y) 点击`。

坐标是 UIKit 点（原点左上）；HID 注入用归一化坐标（0..1）包在父 digitizer 事件里，从主队列投递。
坐标基于当前屏幕方向。

```json
{
  "name": "ui_tap",
  "arguments": { "text": "Wi-Fi", "index": 0, "long_press": false }
}
```

---

### 4.15 `ui_type`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `text` | string | 是 | — | 要输入的文本 |

daemon 侧 `text` 为空返回 `缺少 text 参数`；否则交给 bridge 的 `ui_type`（超时 15 秒）。
成功返回 `已输入 <字符数> 个字符`（字符数按 daemon 侧文本长度计），失败返回 bridge 错误
（取不到时 `输入失败`）；Tweak 侧失败文本为
`输入失败：HID 键盘不可用或当前没有输入焦点`。

Tweak 侧策略：ASCII 走 HID 键盘事件；非 ASCII 先尝试通过无障碍 API 写入第一响应者，
再退回剪贴板 + ⌘V（`IAGAutomation.h` 注明这是"从外部向前台 App 输入 CJK 的唯一可靠方式"）。
需要先点击输入框获得焦点。

> 工具描述现在写明："如果需要发送回车，请在 text 里带上 `\n`；删除字符用 `\u007f`"
> （早期版本误写为"可用 `ui_key`"，而注册表里并不存在 `ui_key`）。
>
> 注意：`ui_type` 的 schema 里没有独立按键参数，回车/退格都靠 `\n` 与 `\u007f` 表达。

```json
{
  "name": "ui_type",
  "arguments": { "text": "hello iAgent" }
}
```

---

### 4.16 `ui_swipe`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `x1` | number | 是 | — | 起点横坐标 |
| `y1` | number | 是 | — | 起点纵坐标 |
| `x2` | number | 是 | — | 终点横坐标 |
| `y2` | number | 是 | — | 终点纵坐标 |
| `duration` | number | 否 | 0.3（秒，Tweak 侧缺省值同为 0.3） | 持续秒数，默认 0.3 |

daemon 侧不做校验，把 `arguments` 原样交给 bridge 的 `ui_swipe`（超时 15 秒）。成功返回
`已从 (x1,y1) 滑动到 (x2,y2)`（坐标按取整格式输出）；失败返回 bridge 错误（取不到时 `滑动失败`），
Tweak 侧失败文本为 `触摸注入不可用（HID 后端缺失）`。

```json
{
  "name": "ui_swipe",
  "arguments": { "x1": 200, "y1": 600, "x2": 200, "y2": 200, "duration": 0.3 }
}
```

---

### 4.17 `ui_open_url`

| 参数 | 类型 | 必填 | 默认 / 范围 | 含义 |
|---|---|---|---|---|
| `url` | string | 是 | — | 要打开的 URL |

执行顺序：先用 daemon 内的 `IAGOpenURL`（LaunchServices，最后兜底 `open` 命令）；
失败再让 bridge 执行 `open_url`（超时 8 秒，Tweak 侧用
`UIApplication openURL:options:completionHandler:`，等待最多 5 秒）。

返回：`已打开 <url>`；经 bridge 成功时返回 bridge 的 `output`（可能为空串）。失败：
`缺少 url 参数` / `无法打开 <url>（<bridge 错误|系统拒绝>）`；Tweak 侧还有
`URL 非法`、`系统拒绝打开该 URL`。

```json
{
  "name": "ui_open_url",
  "arguments": { "url": "prefs:root=WIFI" }
}
```

---

## 5. SpringBoard 桥接要求

`ui_*` 系列（`ui_describe` / `ui_tap` / `ui_type` / `ui_swipe`）的实际执行发生在 SpringBoard
进程内，因为 HID 事件注入需要 SpringBoard 自己的 entitlements（`IAGToolDevice.m` 文件头注释）。
`IAGToolRegistry` 里 `ui_open_url`、`app_launch` 会先自己试 LaunchServices，只在失败后把 bridge
当兜底；`notify_send` 则是先试 bridge、失败后退回本进程的 `CFUserNotification`。
所以**只有 `ui_describe` / `ui_tap` / `ui_type` / `ui_swipe` 是硬依赖桥接**，其余几个在桥接离线
时仍有降级路径。

桥接状态：`IAGBridge -connected` 以"最近一次插件轮询在 20 秒内"（`kIAGConnectedWindow`）为准。
未连接时 `performAction:parameters:timeout:` 立刻失败，错误原文是：

```
SpringBoard 桥接未连接：请确认 iAgent 的 SpringBoard 插件已加载（重新注销或重启后生效）
```

用户/模型看到的形态：

- `ui_*` 四个工具：工具结果 `ok=false`，`error` 就是上面这句话（`IAGToolDevice.m` 只在 bridge
  没给 `error` 时才替换成 `无法读取界面` / `点击失败` / `输入失败` / `滑动失败`）。
- `notify_send`：退化成 CFUserNotification，成功信息里带上这句话，例如
  `已通过 CFUserNotification 显示提示（SpringBoard 桥接未连接：……）: 任务已完成`。
- `app_launch` / `ui_open_url`：daemon 内的 LaunchServices 尝试失败后才轮到 bridge，
  因此报错形如 `无法启动 com.example.app（SpringBoard 桥接未连接：……）`。

桥接已连接但插件没在超时内回结果时，错误是
`SpringBoard 未在 <N> 秒内响应动作 <action>`（各工具的 N：`ui_describe` 12、`ui_tap` 12、
`ui_type` 15、`ui_swipe` 15、`notify` 5、`open_url` 8、`launch_app` 8）；
插件端自身超时另有 `<action> 在 <N> 秒内没有完成（界面可能被占用）`。

`ui_tap` 的三级回退链（`IAGTweak.m` → `IAGAutomation.m`）：

```
text 匹配 → AX 元素 press（无障碍按压，首选，原地激活）
          → 未激活但有元素中心坐标 → 原始 HID 合成点按（tapAtPoint:longPress:）
          → HID 后端缺失 → 失败「触摸注入不可用（HID 后端缺失）」
（没有 text 时：直接走 HID 合成点按）
```

`ui_describe` 在无障碍后端不可用时**不会**返回空列表，而是返回上面 §4.13 列出的三种提示文本之一
（"无障碍接口不可用（<backend>）。请用 ui_tap 的 x/y 坐标方式操作。" 等），并明确建议改用 `x/y` 坐标；
在 `IAGTweak.m` 里这条是以 `ok=false` 的 error 形式返回的。
`IAGAutomation.h` 的相关结论保留了原始措辞：iOS 上没有可用的 C `AXUIElement` API，
实务入口是 AXRuntime.framework 里的 Objective-C `AXElement` 类；
所需 entitlement **未查证**，全部通过 `dlopen` / `NSClassFromString:` 解析，不链接任何私有框架。

---

## 6. 审批与黑名单（工具层视角）

### 6.1 审批模式

审批判定入口是 `IAGToolRegistry -approvalReasonForTool:arguments:config:`，返回非 nil 就弹确认
（agent 循环发 `approval_required` 事件并等待，超时 300 秒；拒绝或超时后工具结果固定为
`用户拒绝执行该操作（或确认超时），请换一种方式或询问用户`）。模式取自 `config.approvalMode`
（配置默认值 `dangerous`）；`auto` 是"既不是 always 也不是 dangerous"的所有取值。

| 工具 | `auto` | `dangerous`（默认） | `always` |
|---|---|---|---|
| 任何工具 | 不弹 | — | 弹，理由 `审批模式为「全部确认」` |
| `shell_exec` | 不弹 | 仅当 `commandLooksDangerous:` 命中，理由 `命令疑似具有破坏性（删除/重启/系统目录写入等）` | 弹 |
| `fs_delete` | 不弹 | 弹，理由 `删除文件` | 弹 |
| `fs_write` | 不弹 | 仅当**原始 path 参数**以 `/System`、`/var/jb/Library`、`/private` 开头，理由 `写入系统路径 <path>` | 弹 |
| `ui_*`（前缀匹配，含 `ui_describe`/`ui_open_url`） | 不弹 | 弹，理由 `将操作设备界面（模拟点击/输入）` | 弹 |
| `cron_add` | 不弹 | 弹，理由 `创建定时任务（将在后台自动执行命令）` | 弹 |
| `notify_send` | 不弹 | 显式返回 nil，不弹 | 弹 |
| `app_launch` | 不弹 | **永不弹**：代码条件为 `app_launch && dangerousTool`，而 `app_launch` 的 `+isDangerous` 是 `NO` | 弹 |
| 其余被标记为危险的工具（当前只有 `cron_remove`） | 不弹 | 弹，理由 `该工具被标记为高风险` | 弹 |
| 其余工具 | 不弹 | 不弹 | 弹 |

两点需要注意：`fs_write` 的判断发生在 `IAGExpandPath` **之前**，所以用 `~`、`$IAG_JBROOT`
或相对路径绕到系统目录的写法不会命中该前缀检查；`ui_` 用 `hasPrefix:` 匹配，
因此只读的 `ui_describe` 在 `dangerous` 模式下同样会弹确认。

`commandLooksDangerous:` 是纯启发式：把命令转小写后做**子串**包含判断，命中任一模式即算危险，
另外"裸的重定向到系统路径"（命令里含 ` >/` 或 ` > /`）也算。模式表按代码顺序（注释说明：故意的，
直接 `curl`/`wget` 不算，只有管道进 shell 才算）：

```
rm -rf / 、rm -fr / 、rm -r / 、rm -rf ~ 、rm -rf /var 、rm -rf /system 、rm -rf /private 、
rm -rf /applications 、rm -rf /library 、mkfs 、dd if= 、dd of=/dev/disk 、> /dev/disk 、
shutdown 、reboot 、halt 、sbreload 、respring 、userspaceReboot 、
launchctl bootout 、launchctl unload 、launchctl disable 、
killall -9 、kill -9 1 、killall springboard 、killall backboardd 、
chmod -r 000 、chown -r 、:(){ 、fork bomb 、
dpkg -r 、dpkg --remove 、apt remove 、apt-get remove 、sileo 、
nvram 、mount -uw 、mount -o rw 、snapshot 、erase all 、
passwd 、/etc/passwd 、sudo rm 、sudo dd 、
mv /system 、mv /var 、mv /library 、
| sh 、|sh 、| bash 、|bash 、| zsh 、
curl -o / 、curl -O / 、wget -O / 、wget -o / 、
ssh  （含尾空格）、scp  （含尾空格）
```

### 6.2 黑名单（blocklist）

`-blockedReasonForTool:arguments:config:` 只对 **`shell_exec`** 生效：把 `command` 转小写后，
逐条与 `config.blockedCommandPatterns`（配置键 `blockedCommands`，同样小写后做子串匹配）比对，
命中返回 `命令命中不可执行黑名单规则「<pattern>」`。命中即**无条件拒绝**，连审批提示都不会出现
（agent 循环先查黑名单再查审批；`/api/tools/call` 命中则直接 403）。

配置默认的 10 条规则（`IAGConfig.m` 的 `defaults`，用户可在设置里改）：

```
rm -rf /          rm -rf /var       rm -rf /System    rm -rf /private
mkfs              dd if=/dev/zero of=/dev/disk        :(){ :|:& };:
mv /System        chmod -R 000 /   nvram
```

`blockedCommandPatterns` 在配置值不是数组时返回空数组 `@[]`（即无规则），见
`IAGConfig -blockedCommandPatterns`。

### 6.3 结果封装与截断

`IAGToolRegistry -executeTool:arguments:context:` 对**每一次**调用（成功、失败、异常都算）
在原结果上追加/修正三个键，这就是 Web UI 与日志里看到的最终对象：

| 键 | 来源 |
|---|---|
| `name` | 请求的工具名 |
| `dangerous` | `[toolClass isDangerous]` |
| `durationMs` | 从进入 `@try` 到返回的墙钟毫秒数 |
| `ok` | 工具没给就补 `@NO` |

原始成功/失败形状（`IAGToolSuccess` / `IAGToolFailure`）：`{ok:YES, output}` /
`{ok:NO, error, output:""}`。未知工具返回 `未知工具: <name>`；工具抛异常被 `@try` 兜住并返回
`工具内部异常: <reason>`；返回值不是字典返回 `工具返回值格式错误`。

回给模型前还有一层截断（`IAGAgent.m`）：

- 成功结果：`IAGTruncateForModel(output, kIAGToolOutputLimit)`，**`kIAGToolOutputLimit = 16000`**；
- 失败结果：不截断，直接包成 `工具执行失败: <error>`；
- 空内容写成 `(无输出)`，随后按 `role: "tool"` + `toolCallId` 追加进会话历史。

`IAGTruncateForModel` 只在 `string.length > maxLength` 且 `maxLength >= 64` 时动手：
保留头部 55%、尾部 `maxLength - head - 64` 个字符，中间插入 `… [中间省略 <N> 字符] …`。
注意工具自己还会先截一次，实际生效的是**先工具后 agent**：`shell_exec`/`http_fetch`/`fs_read`/
`fs_search` 各 24000，`ui_describe` 12000，其余工具不截；所以最终到达模型的成功输出不超过
16000 字符。`/api/tools/call` 返回的是 registry 的原始结果，**不做这层 16000 截断**。

---

## 7. 与代码注释/命名的不一致（自查）

> 本节 1–5 条是文档写作时的静态比对结果。第 2、4、5 条已在同一轮中修掉（标注为 ✅），
> 第 9 条仍然存在，1、3、6、7、8 是设计选择或轻微不一致，保留记录。

1. **`app_launch` 的审批分支是死代码**：`approvalReasonForTool:` 里的
   `if ([name isEqualToString:@"app_launch"] && dangerousTool)` 永远为假，因为 `app_launch` 的
   `+isDangerous` 返回 `NO`；`dangerous` 模式下它实际从不弹确认。
2. ✅ **（已修）`fs_write` 的系统路径判断在路径展开之前**：现在 `approvalReasonForTool:` 直接
   对原始路径判断，`$IAG_JBROOT` / `${IAG_JBROOT}` 前缀、`/System`、`/var/jb/Library`、`/private`
   以及非绝对路径都会触发确认（删除侧本来就在展开之后判断，没有这个问题）。
3. **`ui_describe` / `ui_open_url` 也会弹审批**：审批用 `hasPrefix:@"ui_"`，把只读的
   `ui_describe` 和 `ui_open_url` 一并算进了"将操作设备界面"。
4. ✅ **（已修）`ui_key` 不存在**：`ui_type` 的 `toolDescription` 原先让模型"可用 ui_key"发送
   回车/删除，现在改为"回车请在 text 里带 `\n`，删除字符用 `\u007f`"（18 个工具的名字已逐个核对，
   注册表里确实没有 `ui_key`）。
5. ✅ **（已修）`/api/tools` 的过滤注释**：`IAGTool.h` 的注释已改为说明它返回全部工具并附带
   `enabled`，只有 `-openAIToolDefinitionsWithConfig:` 才按配置过滤。
6. **`/api/tools/call` 不经过审批策略**：只查黑名单就执行（agent 循环两条都查）。这是有意为之：
   这条路径的发起者就是人本人，再向他自己弹确认没有意义。
7. **文件命名 vs 内容**：`IAGToolShell.m` 同时注册 `shell_exec`（category `shell`）和
   `http_fetch`（category `http`）；文件名只体现了前者。`IAGToolFile.m` 只含 5 个 `fs_*`，
   `IAGToolDevice.m` 含 app/notify/cron/ui 共 11 个，与文件名/文件头注释一致。
8. **截断阈值有三档**：工具层 24000（shell/http/fs_read/fs_search）、12000（ui_describe）、
   agent 层 16000；`fs_list`/`fs_write`/`fs_delete`/`app_*`/`notify_send`/`cron_*` 在工具层不截断。
9. **`shell_exec` 的 `cwd` 不走 `IAGExpandPath`**：`~`、`$IAG_JBROOT`、相对路径对它无效
   （相对路径按进程当前目录解释，而非 `workDir`），而 `fs_*` 的 `path` 会展开。请给 `cwd` 传绝对路径。

