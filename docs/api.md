# HTTP API 参考

iAgent 守护进程（`iagentd`）在设备本机回环地址上暴露的 HTTP 控制平面：REST + SSE + 静态 Web UI。

本文档的内容**只来自源码阅读**，覆盖：

| 文件 | 提供的信息 |
| --- | --- |
| `daemon/IAGDaemon.m` | 全部路由处理器、状态码、响应字段 |
| `daemon/IAGHTTPServer.h/.m` | 请求/响应/流式 API、报文解析、连接上限 |
| `daemon/IAGConfig.h/.m` | 配置键、`publicSnapshot`、`applyPatch` 语义 |
| `daemon/IAGBridge.h/.m` | 桥接长轮询 / 结果回传语义 |
| `daemon/IAGAgent.h/.m` | SSE 事件、工具循环、审批中心 |
| `shared/IAGVersion.h` | 版本、默认端口/主机、token 头名称 |
| `shared/IAGJSON.h/.m` | `IAGErrorObject` / `IAGOkObject` 形状 |

> 未在设备上编译或运行验证；文中的示例值都是合理构造的，字段名严格照实现。行为上属于「尽力而为」的地方在 [实现细节与已知偏差](#实现细节与已知偏差) 中单独列出。

---

## 1. 基础

### 1.1 监听地址与协议

| 项目 | 值 | 来源 |
| --- | --- | --- |
| 默认主机 | `127.0.0.1`（`IAG_DEFAULT_HOST`） | `shared/IAGVersion.h` |
| 默认端口 | `8080`（`IAG_DEFAULT_PORT`） | `shared/IAGVersion.h` |
| 绑定地址 | `htonl(INADDR_LOOPBACK)` —— **仅回环，不可从局域网访问** | `IAGHTTPServer.m:440` |
| 协议 | 明文 HTTP/1.1，**没有 TLS** | `IAGHTTPServer.m` |
| 实际端口 | 取配置 `port`；命令行 `--port <n>` 可临时覆盖（不写入配置） | `main.m`、`IAGDaemon.m:82` |

传输层能力（都来自 `IAGHTTPServer.m`）：

- keep-alive（HTTP/1.0 需要显式 `Connection: keep-alive`）、`Content-Length` 与 `chunked` 请求体、`Expect: 100-continue`（curl 大 body 会发）。
- 请求头上限 64 KB，请求体上限 32 MB，超出直接断连（不是 JSON 错误）。
- 同时连接上限 **32**，超出时在 accept 阶段直接回裸响应 `HTTP/1.1 503 Service Unavailable` + `Content-Length: 0` + `Connection: close`（**没有 JSON body**）。SSE 会一直占用一个连接。
- 未显式设置 `Content-Type` 的缓冲响应默认是 `application/json; charset=utf-8`；所有响应都带 `Server: iAgent` 和 `Content-Length`。
- `HEAD` 由传输层处理（只发头、不发 body），路由看到的 `method` 仍是 `HEAD`，因此对只支持 `GET` 的接口会得到 405。

Web UI 地址：`http://127.0.0.1:<port>/`（启动日志里也会打印）。

### 1.2 鉴权

- 令牌来自配置键 `authToken`。**`authToken` 为空时所有接口都不校验**。
- 令牌以两种等价方式提交（`IAGHTTPRequest.accessToken`：先看请求头，再看 query 参数）：
  - 请求头 `X-IAG-Token: <token>`（常量名 `IAG_TOKEN_HEADER`）
  - 查询参数 `?token=<token>`
- **免鉴权端点**：
  - `GET /api/health`（唯一始终免鉴权的 `/api/*` 路由，供 UI 探活）
  - 所有非 `/api/` 路径的静态文件（Web UI 的 `index.html` / `app.js` / `style.css` 不需要令牌）
- 鉴权检查发生在路由之前：未带令牌访问**任何** `/api/*`（包括不存在的路径）都会得到 401，而不是 404。
- 401 响应体是唯一带额外键的错误：

```json
{ "error": "需要有效的访问 token（X-IAG-Token）", "needToken": true }
```

### 1.3 错误响应形状

绝大多数错误用 `IAGErrorObject`，即**只有一个 `error` 键**：

```json
{ "error": "会话不存在" }
```

成功且无数据要返回时用 `IAGOkObject`：

```json
{ "ok": true }
```

用到的状态码（`IAGStatusText` 里已登记的文案）：

| 状态码 | 含义 | 典型场景 |
| --- | --- | --- |
| 200 | OK | 所有成功响应（创建会话/任务也是 200，不是 201） |
| 204 | No Content | `favicon.ico` |
| 400 | Bad Request | 请求体不是 JSON 对象、`message`/`command`/`schedule` 缺失或非法、路径缺 id |
| 401 | Unauthorized | 令牌缺失/错误（带 `needToken`） |
| 403 | Forbidden | 静态路径越出 Web 根；工具命中 `blockedCommands` 黑名单 |
| 404 | Not Found | 会话/任务/终端/工具不存在、未知接口、审批请求已超时 |
| 405 | Method Not Allowed | 方法不对（错误文案各路由自定，如 `仅支持 GET`、`不支持的方法`） |
| 500 | Internal Server Error | 路由抛异常（`内部错误`）、终端创建失败、响应序列化失败 |
| 502 | Bad Gateway | 非流式 `/api/chat` 里模型侧失败（`error` 事件的 message） |
| 503 | Service Unavailable | 连接数超限（裸响应）；handler 未就绪（`服务未就绪`） |

未知接口的 404 文案随前缀路由不同：

- 通用：`{"error":"未知接口 POST /api/nope"}`
- `/api/tools/*`：`{"error":"未知接口"}`
- `/api/term/*`：`{"error":"未知终端接口"}`
- `/api/bridge/*`：`{"error":"未知桥接接口"}`

### 1.4 约定

- 时间戳都是 **Unix 秒**（`createdAt` / `updatedAt` / `lastRun` / `nextRun` / `time` / `lastSeen` / `startedAt`）。
- JSON 键大小写敏感、与本文一致；`IAGDict*` 读取器对类型宽容（字符串 `"1"` / `"true"` 也能当布尔用），但请求端不要依赖这一点。
- 路径会先做百分号解码，`?` 之后是 query；query 里的 `+` 会先还原成空格。

---

## 2. 端点总览

「需要 token」列指 `authToken` 非空时是否要求令牌。

| 方法 | 路径 | 用途 | 需要 token |
| --- | --- | --- | --- |
| GET | `/api/health` | 存活探针 + 环境/统计快照 | 否 |
| GET | `/api/config` | 读取配置（`apiKey` 掩码） | 是 |
| POST | `/api/config` | 局部更新配置，返回改动键名 | 是 |
| GET | `/api/sessions` | 会话列表（按 `updatedAt` 倒序） | 是 |
| POST | `/api/sessions` | 新建会话 | 是 |
| GET | `/api/sessions/<id>` | 会话详情，含全部消息 | 是 |
| PATCH / POST | `/api/sessions/<id>` | 重命名会话 | 是 |
| DELETE | `/api/sessions/<id>` | 删除会话（含磁盘文件） | 是 |
| POST | `/api/chat` | 对话：SSE 流式（默认）或整段 JSON | 是 |
| POST | `/api/approve` | 回答一次审批请求 | 是 |
| POST | `/api/abort` | 中止运行中的会话 | 是 |
| GET | `/api/tools` | 工具清单（含 JSON Schema） | 是 |
| POST | `/api/tools/call` | 直接执行一个工具（不经模型） | 是 |
| POST | `/api/exec` | 一次性非交互 shell 命令 | 是 |
| GET | `/api/term/list` | 终端（PTY）会话列表 | 是 |
| POST | `/api/term/open` | 打开一个交互式 PTY | 是 |
| GET | `/api/term/read` | 按字节游标读取终端增量输出 | 是 |
| POST | `/api/term/input` | 向终端写入按键/文本 | 是 |
| POST | `/api/term/resize` | 调整终端窗口尺寸 | 是 |
| POST | `/api/term/close` | 关闭终端 | 是 |
| GET | `/api/cron` | 定时任务列表 | 是 |
| POST | `/api/cron` | 新建定时任务 | 是 |
| DELETE | `/api/cron/<id>` | 删除定时任务 | 是 |
| POST / PATCH | `/api/cron/<id>` | 启停任务 / 立即运行一次 | 是 |
| GET | `/api/logs` | 读取日志尾部 | 是 |
| POST | `/api/logs/clear` | 清空日志文件 | 是 |
| GET | `/api/bridge/poll` | 插件长轮询取待执行命令 | 是 |
| POST | `/api/bridge/result` | 插件回传命令执行结果 | 是 |
| GET | `/api/bridge/status` | 桥接连接状态与计数 | 是 |
| GET | 任何不以 `/api/` 开头的路径 | Web UI 静态文件 | 否 |

---

## 3. 端点详情

### 3.1 `GET /api/health`

- 方法：仅 `GET`，其它方法 → 405 `{"error":"仅支持 GET"}`。
- 鉴权：**始终免鉴权**。
- 请求：无参数。

响应 200（示例值全部为构造值）：

```json
{
  "ok": true,
  "version": "1.0.0",
  "build": "1",
  "uptimeSec": 18342,
  "processUptime": "05:05:42",
  "jbRoot": "/var/jb",
  "rootfs": "/",
  "rootless": true,
  "runningAsRoot": true,
  "user": "root",
  "device": {
    "model": "iPhone14,2",
    "name": "iPhone 13 Pro",
    "deviceName": "我的 iPhone",
    "systemName": "iOS",
    "systemVersion": "15.4.1",
    "freeDisk": 24567890176,
    "bootUUID": "3F2A9C41-5B7E-4D18-9C0A-1E6D7B8A9F23"
  },
  "model": {
    "baseUrl": "https://api.deepseek.com/v1",
    "model": "deepseek-chat",
    "hasKey": true,
    "apiKeyMasked": "sk-abc…7f21",
    "approvalMode": "dangerous"
  },
  "authRequired": true,
  "tools": [
    {
      "name": "shell_exec",
      "description": "在这台 iOS 设备上执行一条 shell 命令（通过 /bin/sh -c，支持管道、重定向、变量）。",
      "dangerous": true,
      "enabled": true
    }
  ],
  "sessions": 7,
  "terminalSessions": 1,
  "runningSessions": ["s-7-1717043000"],
  "pendingApprovals": 0,
  "bridge": {
    "connected": true,
    "lastSeen": 1717043580.123456,
    "pending": 0,
    "completed": 12,
    "failed": 1,
    "capabilities": {}
  },
  "http": { "port": 8080, "totalRequests": 412, "activeConnections": 3 },
  "webRoot": "/var/jb/usr/share/iagent/web",
  "dataDir": "/var/mobile/Library/iAgent",
  "time": 1717043592
}
```

注意：`tools` 里的每一项只有 `name` / `description` / `dangerous` / `enabled` 四个键（没有 `category` 和 `parameters`，那是 `/api/tools` 才有的）。`freeDisk` 为 `-1` 表示未知。`bridge` 内容见 [3.14](#314-桥接-apibridge)。

### 3.2 `GET /api/config`

- 方法：仅 `GET`/`POST`，其它 → 405 `{"error":"仅支持 GET/POST"}`。
- 响应：`IAGConfig.publicSnapshot`，即完整配置快照，其中 `apiKey` 被替换成 `""`，并额外加两个键：`apiKeyMasked`（脱敏展示用）和 `hasApiKey`（布尔）。

```json
{
  "baseUrl": "https://api.deepseek.com/v1",
  "apiKey": "",
  "model": "deepseek-chat",
  "temperature": 0.3,
  "maxTokens": 2048,
  "systemPrompt": "你是 iAgent，一个运行在 iOS 设备上的原生 AI Agent。…",
  "port": 8080,
  "authToken": "9f2c1b7d4e6a8c0f",
  "approvalMode": "dangerous",
  "maxSteps": 12,
  "shellTimeout": 30,
  "workDir": "/var/mobile",
  "toolsEnabled": {
    "shell": true, "file": true, "app": true, "notify": true,
    "cron": true, "ui": true, "http": true
  },
  "requestLogging": false,
  "logLevel": 1,
  "openInSafari": false,
  "historyLimit": 24,
  "blockedCommands": ["rm -rf /", "mkfs", "dd if=/dev/zero of=/dev/disk"],
  "bubbleSide": "right",
  "apiKeyMasked": "sk-abc…7f21",
  "hasApiKey": true
}
```

> 只有 `apiKey` 会被掩码：`authToken`、`systemPrompt` 等都是**明文**返回的。

### 3.3 `POST /api/config`

- 请求体：JSON 对象（局部 patch）。不是对象（含空/nil body）→ 400 `{"error":"请求体必须是 JSON 对象"}`。
- 允许写任意键（实现里没有键白名单）；`apiKeyMasked` 和 `hasApiKey` 会被忽略，防止 UI 把计算字段写回来。
- `apiKey` 的三种约定：

| 传入值 | 效果 |
| --- | --- |
| `""`（或缺失/非字符串的空值） | **保持不变**（不会清空） |
| `"__CLEAR__"` | 清空 `apiKey` |
| 其它任意非空字符串 | 设为新的 API Key |

- `toolsEnabled` 是**按键合并**：只覆盖传入的子键，未提及的保持原值，值统一转成布尔。
- 部分键会被钳制：

| 键 | 取值范围 / 回退 |
| --- | --- |
| `port` | 1–65535，越界回退 `8080` |
| `maxSteps` | 1–50（默认 12） |
| `shellTimeout` | 1–1800（默认 30） |
| `temperature` | 0.0–2.0（默认 0.3） |
| `maxTokens` | 64–32000（默认 2048） |
| `logLevel` | 0–3（默认 1） |
| `historyLimit` | 2–200（默认 24） |

- `logLevel` 变化会立即生效（重置日志级别）；`port` 只在守护进程启动时读取，**改完要重启 daemon 才生效**。
- 有实际改动时会把配置写回 `/var/mobile/Library/iAgent/config.plist`。

响应 200：`publicSnapshot` + `changed` 数组（本次真正发生变化的键名；没有变化时为空数组）。

请求示例：

```bash
curl -s -X POST http://127.0.0.1:8080/api/config \
  -H 'Content-Type: application/json' \
  -H 'X-IAG-Token: 9f2c1b7d4e6a8c0f' \
  -d '{"model":"deepseek-chat","temperature":0.2,"toolsEnabled":{"ui":false}}'
```

响应示例：

```json
{
  "baseUrl": "https://api.deepseek.com/v1",
  "apiKey": "",
  "model": "deepseek-chat",
  "temperature": 0.2,
  "maxTokens": 2048,
  "systemPrompt": "你是 iAgent，一个运行在 iOS 设备上的原生 AI Agent。…",
  "port": 8080,
  "authToken": "9f2c1b7d4e6a8c0f",
  "approvalMode": "dangerous",
  "maxSteps": 12,
  "shellTimeout": 30,
  "workDir": "/var/mobile",
  "toolsEnabled": { "shell": true, "file": true, "app": true, "notify": true, "cron": true, "ui": false, "http": true },
  "requestLogging": false,
  "logLevel": 1,
  "openInSafari": false,
  "historyLimit": 24,
  "blockedCommands": ["rm -rf /", "mkfs"],
  "bubbleSide": "right",
  "apiKeyMasked": "sk-abc…7f21",
  "hasApiKey": true,
  "changed": ["temperature", "toolsEnabled"]
}
```

### 3.4 `GET /api/sessions`

- 响应 200：**裸数组**（不是对象包装），按 `updatedAt` 倒序，每项是会话摘要。

```json
[
  { "id": "s-7-1717043000", "title": "列出 /var/mobile 下的文件", "createdAt": 1717043000.51, "updatedAt": 1717043591.02, "messageCount": 6 },
  { "id": "s-6-1717039000", "title": "新会话", "createdAt": 1717039000.11, "updatedAt": 1717039010.87, "messageCount": 2 }
]
```

### 3.5 `POST /api/sessions`

- 请求体（可选）：`{ "title": "…" }`。省略、nil 或空串时标题为 `新会话`。
- 响应 200：新建会话的摘要（同上一节的单个对象）。会话 id 形如 `s-<自增序号>-<Unix 秒>`。
- 其它方法 → 405 `{"error":"仅支持 GET/POST"}`。

### 3.6 `GET|PATCH|POST|DELETE /api/sessions/<id>`

路径 id 会被百分号解码；`/api/sessions/`（缺 id）→ 400 `{"error":"缺少会话 id"}`。

| 方法 | 请求 | 成功响应 |
| --- | --- | --- |
| GET | 无 | 200，`summaryJSON` + `messages` |
| PATCH / POST | `{"title":"新标题"}` | 200，会话摘要（`title` 为空则保留原标题但仍返回 200） |
| DELETE | 无 | 200 `{"ok":true}`（同时删除磁盘上的会话文件） |

- 会话不存在 → 404 `{"error":"会话不存在"}`（DELETE / PATCH 同样）。
- 其它方法 → 405 `{"error":"不支持的方法"}`。
- `messages` 是本地存储形状（比 OpenAI 线格式多几个本地键）：普通消息 `role` / `content` / `createdAt`；助手工具轮次还带 `toolCalls`（数组）和可选 `reasoning`；工具结果消息带 `toolCallId` / `name` / `content`。

`GET /api/sessions/s-7-1717043000` 响应示例：

```json
{
  "id": "s-7-1717043000",
  "title": "列出 /var/mobile 下的文件",
  "createdAt": 1717043000.51,
  "updatedAt": 1717043591.02,
  "messageCount": 4,
  "messages": [
    { "role": "user", "content": "列出 /var/mobile 下的文件", "createdAt": 1717043000.52 },
    { "role": "assistant", "content": "", "toolCalls": [ { "id": "call_7f3a1c92", "type": "function", "function": { "name": "shell_exec", "arguments": "{\"command\":\"ls -lh /var/mobile\"}" } } ], "createdAt": 1717043001.10 },
    { "role": "tool", "toolCallId": "call_7f3a1c92", "name": "shell_exec", "content": "exit_code: 0\nduration: 0.12s\ncwd: /var/mobile\n\n--- stdout ---\n…", "createdAt": 1717043001.23 },
    { "role": "assistant", "content": "/var/mobile 下共 17 个条目，占用最大的是 Documents（1.2 GB）。", "createdAt": 1717043002.40 }
  ]
}
```

### 3.7 `POST /api/chat`

- 仅 `POST`（其它方法 → 405 `{"error":"仅支持 POST"}`）；请求体必须是 JSON 对象，否则 400 `{"error":"请求体必须是 JSON 对象"}`。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `message` | string | 是 | 为空 → 400 `{"error":"message 不能为空"}` |
| `sessionId` | string | 否 | 缺省或找不到时**自动新建会话**，并把真实 id 放在响应/`session` 事件里 |
| `stream` | bool | 否 | 默认 `true`（SSE）；显式 `false` 时走整段 JSON |

#### 3.7.1 非流式（`"stream": false`）

响应 200：

```json
{
  "sessionId": "s-3-1717043521",
  "text": "/var/mobile 下有 5 个目录和 12 个文件，占用最大的是 Documents（约 1.2 GB）。",
  "toolCalls": [
    {
      "id": "call_7f3a1c92",
      "name": "shell_exec",
      "arguments": { "command": "ls -lh /var/mobile | head -n 20", "cwd": "/var/mobile" }
    }
  ],
  "usage": { "prompt_tokens": 1024, "completion_tokens": 210, "total_tokens": 1234 },
  "steps": 2
}
```

- `text` 只累积 `delta` 事件（`reason` 推理增量被丢弃）。
- `toolCalls` 是每个 `tool_call` 事件的原样负载数组（`id` / `name` / `arguments`）。
- `usage` 直接取自 `done` 事件：正常一轮一定带 `prompt_tokens` / `completion_tokens` / `total_tokens`（模型没汇报时是 0），被中止的一轮只带 `total_tokens`，完全没收到 `done` 时才是 `{}`。
- 只要出现 `error` 事件（例如未配置 API Key、模型请求失败），响应就是 502 + `{"error":"<error 事件的 message>"}`。

#### 3.7.2 流式（默认）

响应 `200` + `Content-Type: text/event-stream; charset=utf-8`，chunked 编码，事件格式见 [第 4 节](#4-sse-事件参考)。

```bash
curl -N -s -X POST http://127.0.0.1:8080/api/chat \
  -H 'Content-Type: application/json' \
  -H 'X-IAG-Token: 9f2c1b7d4e6a8c0f' \
  -d '{"sessionId":"s-3-1717043521","message":"列出 /var/mobile 下的文件","stream":true}'
```

### 3.8 `POST /api/approve`

用于回答 `approval_required` 事件（详见 [第 5 节](#5-审批流程与中止)）。

- 仅 `POST`（其它 → 405 `{"error":"仅支持 POST"}`）。
- 请求体：`{ "id": "<工具调用 id>", "allow": true }`。`id` 就是 `approval_required` 事件里的 `id`；`allow` 缺失时按 `false`（拒绝）处理。
- 200 `{"ok":true}`；`id` 为空、或不处于等待状态（含已超时）→ 404 `{"error":"没有等待中的审批请求（可能已超时）"}`。

### 3.9 `POST /api/abort`

- 仅 `POST`（其它 → 405 `{"error":"仅支持 POST"}`）。
- 请求体：`{ "sessionId": "s-3-1717043521" }`。
- 语义：给该会话打上中止标记，并取消正在进行的模型 HTTP 请求。运行中的那一轮会在下一个检查点结束，并以带 `aborted: true` 的 `done` 事件收尾。
- `sessionId` 为空或该会话并未运行：**仍然返回 200 `{"ok":true}`**（幂等，无副作用）。

### 3.10 `GET /api/tools`

- 仅 `GET`（其它 → 405 `{"error":"仅支持 GET"}`）。
- 响应 200：`{ "tools": [ … ] }`，按工具名排序。每个工具比 `/api/health` 多 `category` 和 `parameters`（原始 JSON Schema）。

```json
{
  "tools": [
    {
      "name": "shell_exec",
      "description": "在这台 iOS 设备上执行一条 shell 命令（通过 /bin/sh -c，支持管道、重定向、变量）。返回退出码、标准输出与标准错误。没有交互式 TTY…",
      "category": "shell",
      "dangerous": true,
      "enabled": true,
      "parameters": {
        "type": "object",
        "properties": {
          "command": { "type": "string", "description": "要执行的 shell 命令" },
          "cwd": { "type": "string", "description": "工作目录，默认使用设置里的工作目录" },
          "timeout": { "type": "integer", "description": "超时秒数，默认取设置值（最长 1800）" }
        },
        "required": ["command"]
      }
    }
  ]
}
```

`enabled` 来自 `toolsEnabled` 的类别开关；**被禁用的类别仍会列出来**，只是 `enabled: false`（禁用的工具不会出现在发给模型的 `tools` 里）。

### 3.11 `POST /api/tools/call`

直接执行一个工具，不经模型、**不走审批**，只需要工具名和参数对象。

- 仅 `POST`（其它 → 405 `{"error":"仅支持 POST"}`）。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `name` | string | 是 | 工具名；不存在 → 404 `{"error":"未知工具 <name>"}` |
| `arguments` | object | 否 | 缺省为 `{}` |

- 命中 `blockedCommands` 黑名单（仅 `shell_exec` 会检查）→ 403，错误文案形如 `命令命中不可执行黑名单规则「rm -rf /」`。
- 执行上下文里的 `sessionId` 固定为 `"manual"`。
- 响应 200：工具原始结果（`ok` 为真时是 `output`，为假时是 `error`）再加注册表补充的 `name` / `dangerous` / `durationMs`。

请求示例：

```bash
curl -s -X POST http://127.0.0.1:8080/api/tools/call \
  -H 'Content-Type: application/json' \
  -H 'X-IAG-Token: 9f2c1b7d4e6a8c0f' \
  -d '{"name":"shell_exec","arguments":{"command":"uname -a","cwd":"/var/mobile"}}'
```

响应示例：

```json
{
  "ok": true,
  "output": "exit_code: 0\nduration: 0.12s\ncwd: /var/mobile\n\n--- stdout ---\nDarwin iPhone 15.4.1 Darwin Kernel Version 21.4.0 arm64\n",
  "name": "shell_exec",
  "dangerous": true,
  "durationMs": 128
}
```

### 3.12 `POST /api/exec`

一次性非交互 shell 命令（`/bin/sh -c` 之类，由 `IAGProcess runShell` 实现），没有 PTY——需要交互的程序请用终端接口。

- 仅 `POST`（其它 → 405 `{"error":"仅支持 POST"}`）。

| 字段 | 类型 | 必填 | 默认 |
| --- | --- | --- | --- |
| `command` | string | 是 | 为空 → 400 `{"error":"command 不能为空"}` |
| `cwd` | string | 否 | 配置里的 `workDir`；**这里不做目录校验**（与 `shell_exec` 工具不同） |
| `timeout` | integer | 否 | 配置里的 `shellTimeout`；`<= 0` 时同样回退到配置值 |

响应 200：

```json
{
  "exitCode": 0,
  "stdout": "total 24\ndrwx------  8 mobile mobile  256 May 30 10:15 Documents\n",
  "stderr": "",
  "durationMs": 41,
  "timedOut": false,
  "launchError": "",
  "cwd": "/var/mobile"
}
```

- `stdout` / `stderr` 各自最多 200000 字符，超出会用 `… [N 字符已截断] …` 标记掐掉中段；进程层还有一个 1 MB 的输出上限。
- 超时被 SIGKILL 时 `timedOut: true`；进程启动失败时 `exitCode: -1` 且 `launchError` 非空。
- **不检查黑名单、不做审批**（见 [第 8 节](#8-实现细节与已知偏差)）。

### 3.13 终端 `/api/term/*`

真实 PTY 会话（优先 `forkpty`，否则 `posix_openpt`+`fork`）。输出放在 512 KB 环形缓冲里，用单调递增的字节游标寻址，客户端只要轮询 `read` 即可。

> 这一组路由**没有做 HTTP 方法校验**：任何方法都会执行对应动作（例如 `GET /api/term/open` 也会开一个 PTY）。

#### `GET /api/term/list`

响应 200：裸数组，按 `sessionId` 数字序排列。

```json
[
  {
    "sessionId": "t1",
    "pid": 4213,
    "columns": 80,
    "rows": 24,
    "shell": "/var/jb/bin/zsh",
    "alive": true,
    "exitCode": null,
    "cursor": 128,
    "startedAt": 1717043500.44
  }
]
```

`exitCode` 在进程仍在运行时是 `null`；已结束的会话（`alive: false`）会保留一小段时间供查看输出，最多同时保留 2 个已结束会话。

#### `POST /api/term/open`

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `cols` | integer | 80 | 小于 2 时按 80 处理 |
| `rows` | integer | 24 | 小于 2 时按 24 处理 |
| `shell` | string | 自动探测 | 依次尝试 `/bin/zsh`、`/var/jb/bin/zsh`、`/bin/bash`、`/var/jb/bin/bash`、`/bin/sh`，兜底 `/bin/sh` |

响应 200：

```json
{ "sessionId": "t1", "pid": 4213, "shell": "/var/jb/bin/zsh" }
```

失败时 500 + `{"error":"…"}`，可能的文案：`终端数量已达上限（8）`、`创建 PTY 失败: <errno 描述>`、`内存不足`。活的终端会话最多 8 个。

#### `GET /api/term/read`

查询参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `sessionId` | — | 必填；找不到 → 404 `{"error":"终端会话不存在"}` |
| `since` | 0 | 上次响应的 `cursor`，负数按 0 处理 |

响应 200：

```json
{ "data": "iPhone:~ mobile$ ", "cursor": 16, "alive": true, "exitCode": null, "truncatedHead": false }
```

- `cursor` 是「已消费字节数」，下次原样回传即可续读。
- `truncatedHead: true` 表示请求的 `since` 已经落在 512 KB 环形缓冲之外，头部输出已丢失，游标被推进到缓冲起点。
- 末尾若是被截断的多字节 UTF-8 字符，会等下一个字节再接（`cursor` 只推进到已成功解码的位置）。

#### `POST /api/term/input`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `sessionId` | string | 必填；找不到 → 404 |
| `data` | string | 按 UTF-8 写入 |
| `data_base64` | string | 非空时**优先于** `data`，用于发送任意字节（如 `\u0003`、方向键序列） |

响应 200 `{"ok":true}`（PTY 已消失时写入被静默丢弃，仍返回 `ok`）。

#### `POST /api/term/resize`

`{ "sessionId": "...", "cols": 120, "rows": 40 }` → 200 `{"ok":true}`。`cols`/`rows` 默认 80/24，钳制到 1–1000，并给子进程发 `SIGWINCH`。

#### `POST /api/term/close`

`{ "sessionId": "t1" }` → 200 `{"ok":true}`。先 `SIGHUP`，约 300 ms 内没退出再 `SIGKILL` 整个进程组。

### 3.14 定时任务 `/api/cron`

#### `GET /api/cron`

响应 200：裸数组。

```json
[
  {
    "id": "cron-1",
    "schedule": "*/5 * * * *",
    "command": "echo hello >> /var/mobile/iagent-cron.log",
    "enabled": true,
    "lastRun": 1717043400,
    "nextRun": 1717043700,
    "lastResult": "exit=0 0.0s hello",
    "lastExitCode": 0,
    "createdAt": 1717040000.12
  }
]
```

`nextRun` 为 0 表示按该表达式在约两年内找不到下一次运行时间。表达式是经典五字段（分 时 日 月 周），支持 `*`、`a`、`a-b`、`a,b,c`、`*/n`、`a-b/n`，按设备本地时区计算；日/周字段同时给定时是**或**关系（与 cron 一致）。

#### `POST /api/cron`

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `schedule` | string | — | 非法 → 400 `{"error":"cron 表达式无效（需要 5 个字段：分 时 日 月 周）"}` |
| `command` | string | — | 为空 → 400 `{"error":"命令不能为空"}` |
| `enabled` | bool | true | |

响应 200：新任务的完整 JSON（同上面列表里的单项），id 形如 `cron-<自增序号>`。

#### `DELETE /api/cron/<id>`

200 `{"ok":true}`；不存在 → 404 `{"error":"任务不存在"}`；缺 id → 400 `{"error":"缺少任务 id"}`。

#### `POST|PATCH /api/cron/<id>`（启停 / 立即运行）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `enabled` | bool | 出现即设置启停；重新启用时会重算 `nextRun` |
| `runNow` | bool | `true` 时把任务排进调度队列立即跑一次 |

- 响应 200：更新后的任务 JSON；id 不存在时回退成 `{"ok":true}`（**不返回 404**）。
- `runNow` 是异步的：命令在调度队列里执行（超时 600 秒、输出上限 128 KB），响应会在命令结束前返回；结果之后写进 `lastRun` / `lastResult` / `lastExitCode` 并重算 `nextRun`。
- 其它方法 → 405 `{"error":"不支持的方法"}`。

### 3.15 日志 `/api/logs`

#### `GET /api/logs?lines=N`

`lines` 缺省或 `<= 0` 时为 200。

```json
{
  "lines": [
    "[2026-05-30 10:15:02] [INFO] 第 1 步：发送 3 条消息 / 12 个工具",
    "[2026-05-30 10:15:02] [INFO] 会话 s-7-1717043000 完成: 2 步, 1 次工具调用, 1234 tokens"
  ],
  "path": "/var/mobile/Library/iAgent/logs/iagent.log"
}
```

#### `POST /api/logs/clear`

清空日志文件，响应 200 `{"ok":true}`。

`/api/logs` 前缀下其它方法（含 `GET /api/logs/clear`）→ 405 `{"error":"不支持的方法"}`。

### 3.16 桥接 API `/api/bridge`

守护进程自己不做触摸注入：UI 自动化必须由持有相应 entitlement 的 SpringBoard 插件执行。因此动作在守护进程侧排队，插件用长轮询取走、执行、再把结果回传。全部数据在内存里，不落盘。

> 这一组路由同样**没有做 HTTP 方法校验**。

#### `GET /api/bridge/poll`

插件侧长轮询。

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `since` | 0 | 上次拿到的 `cursor`；只返回序号大于它的命令 |
| `wait` | 20 | 最多阻塞秒数；`<= 0` 时用 20，实现内部再钳制到 0–25 |
| `caps` | 无 | 插件能力声明，**百分号编码**后传。两种形式都接受：JSON 对象 `caps={"hid":true,"ax":true}`，或紧凑列表 `caps=hid:1,ax:1,notify:cf`（随包插件用后者）。解析出的键值对记入 `/api/bridge/status.capabilities` |

响应 200：

```json
{
  "commands": [
    {
      "id": "3f9c1d2e-5b7a-4c81-9f0e-2d6a7b8c9d10",
      "action": "ui_tap",
      "parameters": { "x": 187.5, "y": 402.0, "long_press": false }
    }
  ],
  "cursor": 12
}
```

- `cursor` 恒为「当前最大命令序号」，客户端保存后下次作为 `since` 传回。
- 一条命令只会被投递一次（投递后置 `delivered`）；已拿到结果或序号 `<= since` 的不会再返回。
- 已经有结果的命令在创建 300 秒后会被清理；还没被取走的命令会一直留着。有插件轮询（20 秒窗口内）时 `/api/bridge/status` 的 `connected` 为 `true`。
- 没有任何待执行命令时，请求会一直挂到 `wait` 到期再回一个空的 `commands`。

#### `POST /api/bridge/result`

请求体：`{ "id": "<命令 id>", "ok": true, "output": "已在 (187,402) 点击", "error": "" }`。

响应 200 `{"ok": <是否被接受>}`：

- 接受（`true`）：守护进程唤醒正在等待该命令的调用方。`ok` 为假时，`error` 为空会用默认文案 `SpringBoard 执行失败`。
- `false`：`id` 缺失、未知或重复回传（迟到/重复结果），HTTP 状态仍是 200。

#### `GET /api/bridge/status`

```json
{ "connected": true, "lastSeen": 1717043580.12, "pending": 0, "completed": 12, "failed": 1, "capabilities": {} }
```

| 字段 | 含义 |
| --- | --- |
| `connected` | 最近 20 秒内有插件轮询过 |
| `lastSeen` | 最近一次轮询的 Unix 秒（0 = 从未） |
| `pending` | 已排队但还没回结果的动作数 |
| `completed` / `failed` | 成功/失败结果累计计数 |
| `capabilities` | 最近一次 `caps` 解析结果；没传或解析不出键值对时是 `{}` |

> `caps` 支持 JSON 对象与 `k:v,k:v` 紧凑列表两种写法；随包插件发的是
> `hid:1,ax:1,notify:cf`，会被解析成 `{"hid":"1","ax":"1","notify":"cf"}` 写进 `capabilities`。
> `connected` / `lastSeen` 由轮询本身刷新，与 `caps` 无关。

插件的 `action` 由实现侧定义（当前支持 `ping`、`caps`、`notify`、`ui_describe`、`ui_tap`、`ui_type`、`ui_swipe`、`open_url`、`launch_app`）；`parameters` 是对应动作的参数对象。这些名字不在 HTTP 层校验，插件不认识的动作用结果里的 `error` 报告。

### 3.17 静态文件（Web UI）

任何**不以 `/api/` 开头**的路径都走静态文件服务：

- `/` → `index.html`。
- 根目录是 `IAGWebRoot()`（安装后的 `usr/share/iagent/web`，`/api/health` 的 `webRoot` 字段会给出实际路径）；`index.html`、`app.js`、`style.css` 是全部资源。
- `Content-Type` 按扩展名：`html`/`htm`、`js`、`css`、`json`、`svg`、`png`、`jpg`/`jpeg`、`webp`、`ico`、`woff2`、`txt`/`md`，其余 `application/octet-stream`。
- 所有静态响应带 `Cache-Control: no-cache, no-store, must-revalidate`。
- `/favicon.ico` → 204，空 body。
- 解析后越出 Web 根 → 403 `{"error":"路径非法"}`；文件不存在 → 404 `{"error":"未找到 /xxx"}`。
- **静态文件不需要令牌**；只有 `/api/*` 受 `authToken` 保护。

Web UI 会把令牌存在 `localStorage` 的 `iag_token`，并可通过 `?token=<token>` 打开页面时自动采纳（SpringBoard 面板就是这样把令牌带进去的）。

---

## 4. SSE 事件参考

`POST /api/chat`（默认 `stream: true`）的响应：

```
HTTP/1.1 200 OK
Content-Type: text/event-stream; charset=utf-8
Cache-Control: no-cache, no-store, must-revalidate
Pragma: no-cache
X-Accel-Buffering: no
Connection: keep-alive
Transfer-Encoding: chunked
Server: iAgent
```

帧格式固定为：

```
event: <事件名>\n
data: <JSON>\n
\n
```

- JSON 里的 `\r` 会被删除、`\n` 会被转义成字面量 `\n`（SSE 不允许 data 字段跨行），所以每个事件恰好一行 `data:`。
- 第一个事件总是 `session`，随后是模型/工具循环产生的事件；结束时会发送 chunked 终止块并关闭连接（`Connection: keep-alive` 但流本身到此为止）。
- **心跳**：一个 10 秒周期（首次 10 秒后触发，1 秒 leeway）的定时器在私有队列上发送 SSE 注释帧 `: keepalive\n\n`，只在这一轮运行期间存在。它可能出现在任意两帧之间；客户端按规范忽略以 `:` 开头的行即可。

| 事件 | 触发时机 | `data` 字段 |
| --- | --- | --- |
| `session` | 流建立后、进入 agent 循环之前 | `sessionId` |
| `delta` | 模型正文增量（每个 chunk 一次） | `text` |
| `reason` | 模型推理增量（`reasoning_content`，若服务端提供） | `text` |
| `tool_call` | 模型请求调用一个工具（`phase = start`，不含增量阶段） | `id`、`name`、`arguments`（已解析的对象；解析失败时为 `{}`） |
| `tool_result` | 每个工具执行完成（含被拒绝、被拦截、未知工具） | `id`、`name`、`ok`、`output`、`error`（非空时）、`durationMs`、`exitCode`（仅当工具结果里带该键；内置工具把退出码写在 `output` 文本里） |
| `approval_required` | 工具命中审批策略、在阻塞等待用户决定之前 | `id`、`name`、`arguments`、`reason` |
| `done` | 一轮运行结束 | 正常：`messageId`、`steps`、`toolCalls`、`contentLength`、`usage`；被中止时：`messageId`、`steps`、`aborted: true`、`usage` |
| `error` | 会话不存在、未配置 API Key、模型请求失败 | `message` |

细节与边界：

- `session` 的 `sessionId` 是最终使用的会话（请求里给了不存在的 id 时会新建一个）。
- `usage` 的三个键是 `prompt_tokens` / `completion_tokens` / `total_tokens`；中途中止时只带 `total_tokens`。
- **`done.messageId` 实际就是会话 id**（不是单条消息的 id）。
- 达到 `maxSteps` 时会先补一个 `delta`（附加说明文本）再发 `done`。
- 模型请求失败会先发 `error`，随后**仍会发一个 `done`**（该轮 `steps: 0`、`toolCalls: 0`、`contentLength: 0`、`usage` 全 0）。只有「会话不存在」和「未配置 API Key」这两种情况是 `error` 之后直接结束、没有 `done`。
- 被中止的那一轮：`done` 带 `aborted: true`，`steps` 是中止时所处的步号。中止不会回滚已经写入的历史消息。

### 完整示例流

```text
event: session
data: {"sessionId":"s-3-1717043521"}

event: reason
data: {"text":"用户要列目录，先用 shell_exec 看真实结果，不要凭猜测回答。"}

event: tool_call
data: {"id":"call_7f3a1c92","name":"shell_exec","arguments":{"command":"ls -lh /var/mobile | head -n 20","cwd":"/var/mobile"}}

: keepalive

event: approval_required
data: {"id":"call_7f3a1c92","name":"shell_exec","arguments":{"command":"rm -rf /var/mobile/tmp-cache"},"reason":"命令疑似具有破坏性（删除/重启/系统目录写入等）"}

event: tool_result
data: {"id":"call_7f3a1c92","name":"shell_exec","ok":false,"output":"","error":"用户拒绝执行该操作（或确认超时），请换一种方式或询问用户"}

event: delta
data: {"text":"好的，我不删除任何东西。"}

event: delta
data: {"text":"/var/mobile 下有 5 个目录、12 个文件，占用最大的是 Documents（约 1.2 GB）。"}

event: done
data: {"messageId":"s-3-1717043521","steps":2,"toolCalls":1,"contentLength":46,"usage":{"prompt_tokens":1024,"completion_tokens":210,"total_tokens":1234}}
```

（`done` 之后服务端写入 chunked 终止块并关闭连接；上面的 `: keepalive` 只是示意心跳出现的位置。）

---

## 5. 审批流程与中止

审批只在 **`/api/chat` 的工具循环**里发生（`/api/tools/call` 不审批，`/api/exec` 既不审批也不查黑名单）。

### 5.1 `approval_required` 携带什么

工具被判定需要确认时，守护进程先发事件、再阻塞等待：

```json
{
  "id": "call_7f3a1c92",
  "name": "shell_exec",
  "arguments": { "command": "rm -rf /var/mobile/tmp-cache" },
  "reason": "命令疑似具有破坏性（删除/重启/系统目录写入等）"
}
```

| 字段 | 说明 |
| --- | --- |
| `id` | **工具调用 id**，也是审批请求的标识（回传时必须原样带回） |
| `name` | 工具名 |
| `arguments` | 已解析的参数对象 |
| `reason` | 为什么要确认；由审批策略生成，例如 `审批模式为「全部确认」`、`删除文件`、`写入系统路径 /private/etc/hosts`、`将操作设备界面（模拟点击/输入）`、`创建定时任务（将在后台自动执行命令）`、`该工具被标记为高风险` |

是否要求审批由配置 `approvalMode` 决定：`auto` 从不确认；`dangerous`（默认）只对「危险工具」和命中破坏性模式的 `shell_exec` 确认；`always` 对每次工具调用都确认。命中 `blockedCommands` 黑名单的工具不会进入审批，直接以失败结果返回。

### 5.2 客户端如何回答

```bash
curl -s -X POST http://127.0.0.1:8080/api/approve \
  -H 'Content-Type: application/json' \
  -H 'X-IAG-Token: 9f2c1b7d4e6a8c0f' \
  -d '{"id":"call_7f3a1c92","allow":true}'
```

- 允许 → `{"ok":true}`，工具随即执行，流里出现对应的 `tool_result`。
- 拒绝 → `{"ok":true}`，工具不执行，流里出现 `ok: false` 的 `tool_result`，`error` 文案是 `用户拒绝执行该操作（或确认超时），请换一种方式或询问用户`。
- 已经超时或 id 不存在 → 404 `{"error":"没有等待中的审批请求（可能已超时）"}`。

### 5.3 超时行为

- 工具循环等待审批的固定超时是 **300 秒**（`requestApprovalForIdentifier:timeout:300`）。
- 超时按**拒绝**处理：工具不执行，发 `ok: false` + 上面那句 `error` 的 `tool_result`，然后**这一轮继续跑**——模型会看到工具失败的结果，自行换方案或询问用户。
- 超时不会自动中止会话，也不会把 HTTP 状态改成错误；审批卡片的决定状态只体现在工具结果里。

### 5.4 与 `/api/abort` 的关系

- `POST /api/abort {"sessionId": "..."}` 做两件事：给会话打中止标记、取消正在进行的模型 HTTP 请求（`IAGLLM cancel`）。
- 工具循环在**每个模型步开始前、每个工具调用开始前**检查中止标记；发现后跳出循环，并以 `done`（`aborted: true`）收尾。因此中止不是立即生效的：当前正在执行的工具/命令会先跑完。
- **中止不会唤醒正在等待的审批**：如果此刻正阻塞在 `approval_required` 上，得等 `/api/approve` 到达或那 300 秒超时结束，循环才能走到下一个检查点看到中止标记。
- 中止标记在该会话下一次 `runSession` 开始时会清除，所以 `abort` 对「尚未开始」的运行没有影响。
- 对不存在/未运行的会话调用 `abort` 仍是 200 `{"ok":true}`。
- SSE 客户端断连不会中止运行：模型请求和工具继续执行到该轮结束，只是写事件失败（`SIGPIPE` 已被忽略，守护进程不受影响）。

---

## 6. curl 示例

下面假设：

```bash
BASE=http://127.0.0.1:8080
TOKEN=9f2c1b7d4e6a8c0f     # 配置里的 authToken；为空时所有 -H 'X-IAG-Token: …' 都可省略
```

`X-IAG-Token` 也可以换成查询串 `?token=$TOKEN`。

### 6.1 健康检查

```bash
curl -s "$BASE/api/health"
```

带令牌（health 免鉴权，带上也无妨）：

```bash
curl -s "$BASE/api/health" -H "X-IAG-Token: $TOKEN"
```

### 6.2 非流式对话

```bash
curl -s -X POST "$BASE/api/chat" \
  -H "X-IAG-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sessionId":"s-3-1717043521","message":"列出 /var/mobile 下的文件并告诉我哪个目录最大","stream":false}'
```

省掉 `sessionId` 会自动新建会话，响应里的 `sessionId` 就是新 id：

```bash
curl -s -X POST "$BASE/api/chat" \
  -H "X-IAG-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"message":"现在几点了？","stream":false}'
```

### 6.3 流式对话（SSE，必须 `-N`）

```bash
curl -N -s -X POST "$BASE/api/chat" \
  -H "X-IAG-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: text/event-stream' \
  -d '{"sessionId":"s-3-1717043521","message":"看看电池健康度","stream":true}'
```

`-N` 关掉 curl 的输出缓冲，否则看不到逐块到达的 `delta`。

### 6.4 直接调用工具

```bash
curl -s -X POST "$BASE/api/tools/call" \
  -H "X-IAG-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"shell_exec","arguments":{"command":"uname -a","cwd":"/var/mobile"}}'
```

查看全部工具名与参数 schema：

```bash
curl -s "$BASE/api/tools" -H "X-IAG-Token: $TOKEN"
```

### 6.5 直接执行 shell 命令

```bash
curl -s -X POST "$BASE/api/exec" \
  -H "X-IAG-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"command":"ls -lh /var/mobile | head -n 20","cwd":"/var/mobile","timeout":30}'
```

### 6.6 打开并读取终端

```bash
# 1) 打开一个 100x30 的 PTY
curl -s -X POST "$BASE/api/term/open" \
  -H "X-IAG-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"cols":100,"rows":30}'
# → {"sessionId":"t1","pid":4213,"shell":"/var/jb/bin/zsh"}

# 2) 从游标 0 开始读（第一次通常只有 shell 提示符）
curl -s "$BASE/api/term/read?sessionId=t1&since=0" -H "X-IAG-Token: $TOKEN"
# → {"data":"iPhone:~ mobile$ ","cursor":16,"alive":true,"exitCode":null,"truncatedHead":false}

# 3) 输入命令（\n 会当成回车）
curl -s -X POST "$BASE/api/term/input" \
  -H "X-IAG-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sessionId":"t1","data":"id -un && uname -a\n"}'

# 4) 用上一步返回的 cursor 续读
curl -s "$BASE/api/term/read?sessionId=t1&since=16" -H "X-IAG-Token: $TOKEN"

# 5) 发送 Ctrl-C（base64 的 0x03）
curl -s -X POST "$BASE/api/term/input" \
  -H "X-IAG-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sessionId":"t1","data_base64":"Aw=="}'

# 6) 关闭
curl -s -X POST "$BASE/api/term/close" \
  -H "X-IAG-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sessionId":"t1"}'
```

### 6.7 桥接长轮询

插件侧的轮询（`since` 用上一次响应里的 `cursor`，`wait` 是阻塞秒数，`caps` 用紧凑列表或 JSON 对象）：

```bash
curl -s -N -G "$BASE/api/bridge/poll" \
  -H "X-IAG-Token: $TOKEN" \
  --data-urlencode 'since=0' \
  --data-urlencode 'wait=20' \
  --data-urlencode 'caps={"hid":true,"ax":true,"notify":"cf"}'
```

响应形状（没有命令时 `commands` 为空数组，请求会挂到 `wait` 到期）：

```json
{
  "commands": [
    {
      "id": "3f9c1d2e-5b7a-4c81-9f0e-2d6a7b8c9d10",
      "action": "ui_tap",
      "parameters": { "x": 187.5, "y": 402.0, "long_press": false }
    }
  ],
  "cursor": 12
}
```

回传执行结果：

```bash
curl -s -X POST "$BASE/api/bridge/result" \
  -H "X-IAG-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"id":"3f9c1d2e-5b7a-4c81-9f0e-2d6a7b8c9d10","ok":true,"output":"已在 (187,402) 点击","error":""}'
```

查看桥接状态：

```bash
curl -s "$BASE/api/bridge/status" -H "X-IAG-Token: $TOKEN"
```

### 6.8 审批与中止（补充）

```bash
# 允许一次审批（id 取自 approval_required 事件）
curl -s -X POST "$BASE/api/approve" \
  -H "X-IAG-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"id":"call_7f3a1c92","allow":true}'

# 中止某个会话的运行
curl -s -X POST "$BASE/api/abort" \
  -H "X-IAG-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sessionId":"s-3-1717043521"}'
```

### 6.9 会话、定时任务、日志（补充）

```bash
curl -s "$BASE/api/sessions" -H "X-IAG-Token: $TOKEN"
curl -s -X POST "$BASE/api/sessions" -H "X-IAG-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"title":"排错"}'
curl -s "$BASE/api/sessions/s-3-1717043521" -H "X-IAG-Token: $TOKEN"
curl -s -X PATCH "$BASE/api/sessions/s-3-1717043521" -H "X-IAG-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"title":"重新命名"}'
curl -s -X DELETE "$BASE/api/sessions/s-3-1717043521" -H "X-IAG-Token: $TOKEN"

curl -s "$BASE/api/cron" -H "X-IAG-Token: $TOKEN"
curl -s -X POST "$BASE/api/cron" -H "X-IAG-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"schedule":"*/5 * * * *","command":"echo hello >> /var/mobile/iagent-cron.log","enabled":true}'
curl -s -X POST "$BASE/api/cron/cron-1" -H "X-IAG-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"runNow":true}'
curl -s -X DELETE "$BASE/api/cron/cron-1" -H "X-IAG-Token: $TOKEN"

curl -s "$BASE/api/logs?lines=250" -H "X-IAG-Token: $TOKEN"
curl -s -X POST "$BASE/api/logs/clear" -H "X-IAG-Token: $TOKEN"
```

---

## 7. 静态 Web UI

浏览器直接打开 `http://127.0.0.1:8080/` 即可；页面加载 `index.html` → `app.js` → `style.css`，随后用 `GET /api/health` 探活。设置里填写的访问令牌会存进 `localStorage`（键 `iag_token`）并加到后续请求的 `X-IAG-Token` 头。SpringBoard 面板用 `?token=<token>` 打开同一页面，页面读取后会把它记下来并从地址栏抹掉。除 `GET /api/health` 外，`/api/*` 都需要令牌（若配置了 `authToken`）。

---

## 8. 实现细节与已知偏差

以下都是源码里能直接读出来的行为，写客户端时值得注意：

1. **401 响应不是纯 `IAGErrorObject`**：它多带一个 `"needToken": true`，其余错误都只有 `error` 一个键。
2. **鉴权先于路由**：未带令牌访问不存在的 `/api/*` 得到 401 而不是 404。
3. **`/api/term/*` 和 `/api/bridge/*` 不校验 HTTP 方法**：例如 `GET /api/term/open` 也会创建 PTY，`POST /api/bridge/status` 也能读到状态。
4. **缺少 404 的情况**：`POST|PATCH /api/cron/<不存在的 id>` 返回 200 `{"ok":true}`（`runNow` 静默无效），而不是 404。
5. ✅ **（已修）桥接 `caps` 解析**：JSON 对象与 `hid:1,ax:1,notify:cf` 这类紧凑列表现在都能解析并写入 `capabilities`；`poll` 也不再每次都把上一次的能力声明清空。
6. **审批覆盖范围不一致**：`/api/chat`（工具循环）查黑名单 + 走审批；`/api/tools/call` 只查黑名单（403，发起者是人本人，不再弹确认）；`/api/exec` 现在也查配置里的 `blockedCommands`（403），同样不走审批。
7. **非流式对话的损失**：`reason` 增量被丢弃；被中止的一轮与非中止一轮在响应里无法区分（只用 `done` 的 `usage`/`steps` 组装）；模型失败时虽然先发 `error` 再发 `done`，非流式路径只取 `error` 并返回 502。
8. **`done.messageId` 是会话 id**，不要当成消息 id 使用。
9. **`tool_result.exitCode` 基本不会出现**：只有工具结果字典自带 `exitCode` 键时才会带上；内置工具（含 `shell_exec`）把退出码写在 `output` 文本的 `exit_code:` 行里。`durationMs` 则每次都有。
10. **心跳与事件来自不同线程**：心跳可能插入任意两帧之间（不会破坏帧结构），客户端按 SSE 规范忽略 `:` 注释行即可。
11. **`port` 改动需重启**：配置写入后不会重新绑定监听；`--port` 只是启动时的临时覆盖。
12. **`bubbleSide` 是插件气泡位置在协议上的键名**（配置头里叫 `kIAGKeyTopButtonSide`，取值为 `left` / `right`）。
13. **`/api/config` 只掩码 `apiKey`**：`authToken` 等其余键都是明文，这正是 `authRequired: false` 时任何本机进程都能控制守护进程的原因——所以监听地址被硬编码为回环。
14. **耗时上限属于尽力而为**：终端是 8 个会话 / 512 KB 环形缓冲（旧输出会丢，靠 `truncatedHead` 提示）；shell 输出会被截断（`/api/exec` 200000 字符、`shell_exec` 工具 24000 字符左右、`http_fetch` 同理）；`runNow` 与定时任务执行是异步的（600 秒超时、128 KB 输出上限）；桥接命令 300 秒后清理，插件不轮询时动作直接以「桥接未连接」失败返回。
15. **Web UI 的接口覆盖**：`app.js` 调用的路径（`/api/health`、`/api/config`、`/api/sessions`、`/api/sessions/<id>`、`/api/chat`、`/api/approve`、`/api/abort`、`/api/tools`、`/api/tools/call`、`/api/exec`、`/api/term/*`、`/api/cron`、`/api/cron/<id>`、`/api/logs`）**全部已实现**，没有调用缺失端点。反向地，`/api/logs/clear`、`/api/cron/<id>` 的 `runNow` 以及全部 `/api/bridge/*` 目前只有 API 没有 UI 入口；UI 也忽略 `session` SSE 事件（会话 id 由 `POST /api/sessions` 或非流式响应获得）。
