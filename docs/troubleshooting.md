# 真机排障

面向"装上了但就是不动"的情况。每条都先给**判断依据**，再给**处理办法**。
本文里的命令在设备上以 root 运行（SSH / NewTerm / Filza 的终端都行）。

> 说明：iAgent 只在 GitHub Actions 的 macOS runner 上编译过，**没有在真机上完整验证过**。
> 下面这些判断依据来自代码本身，如果你实测与文档不符，以实测为准并告诉我。

---

## 0. 一分钟收集信息（贴给我看这个就够）

```sh
echo "--- 包与架构"; dpkg -l com.dsh.iagent; dpkg --print-architecture
echo "--- 越狱根";    ls -d /var/jb 2>/dev/null; ls -d /var/containers/Bundle/Application/.jbroot-* 2>/dev/null
echo "--- 守护进程";  launchctl print system/com.dsh.iagent.daemon 2>&1 | head -25
echo "--- 健康检查";  curl -s http://127.0.0.1:8080/api/health | head -c 900; echo
echo "--- 主日志";    tail -n 40 /var/mobile/Library/iAgent/logs/iagent.log
echo "--- 守护进程 stderr"; tail -n 40 /var/mobile/Library/iAgent/logs/iagentd.err.log
echo "--- 崩溃日志";  tail -n 60 /var/mobile/Library/iAgent/logs/iagentd-crash.log 2>/dev/null || echo "(没有崩溃日志)"
echo "--- 安装日志";  tail -n 40 /var/mobile/Library/iAgent/logs/postinst.log 2>/dev/null
```

日志目录固定是 `/var/mobile/Library/iAgent/logs/`（在 rootfs 上，**不会**随越狱更新消失）：

| 文件 | 内容 |
| --- | --- |
| `iagent.log` | 守护进程主日志（含模型请求失败原因） |
| `iagentd.out.log` / `iagentd.err.log` | launchd 捕获的标准输出/错误（崩溃前的最后遗言常在这里） |
| `iagentd-crash.log` | 崩溃/异常/信号报告 |
| `postinst.log` | 安装脚本每一步做了什么 |

---

## 1. Sileo 报「dpkg 已中断」

**原因**：上一次 dpkg 事务没跑完（早期版本的 `postinst` 在事务里重启 SpringBoard，会把 Sileo 和它子进程 dpkg 一起杀掉）。
**处理**：

```sh
dpkg --configure -a
# 还不行就先摘掉这个包再修
dpkg -r --force-remove-reinstreq com.dsh.iagent
rm -f /var/lib/dpkg/updates/*
dpkg --configure -a
```

1.0.1 起安装脚本**不再 respring**（这是故意的），装完守护进程立刻可用，悬浮球要你自己重启一次 SpringBoard 才出现。

---

## 2. 发消息没有任何反应 / 转圈不出字

先看模型这一条链路，不要猜：

```sh
# 守护进程实际拿到的配置（baseUrl / model / 有没有 Key）
curl -s http://127.0.0.1:8080/api/health | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps(d["model"],ensure_ascii=False))'

# 分步体检：配置 → 网络 → 鉴权 → 模型列表 → 流式对话
curl -s -X POST http://127.0.0.1:8080/api/model/check -H 'Content-Type: application/json' -d '{}' | python3 -m json.tool

# 绕开 iAgent，直接用 curl 打这个端点
KEY=sk-xxx; BASE=https://your-host/v1; MODEL=your-model
curl -sS -m 20 -w '\nHTTP %{http_code}\n' "$BASE/chat/completions" \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true}" | head -c 400
```

- 面板/体检里出现 `鉴权失败 (HTTP 401)` → Key 不对或没有该模型权限。
- `接口不存在 (HTTP 404)` → `baseUrl` 写错了：它应当以 `/v1` 结尾（守护进程自己拼 `/chat/completions`）。
- `无法连接 … [NSURLErrorDomain -1004]` → 网络不可达；明文 `http://` 在 iOS 上还可能被 ATS 拦掉，换 https 或本地代理。
- `模型返回 HTTP 404` 且 body 里有 "model not found" → 模型名不对（用 `GET /api/models` 拉列表对照）。
- **端点返回 200 但没有 SSE 数据（可能不支持流式）** → 你用的中转端点忽略了 `stream:true`。守护进程会兜底把整段非流式 JSON 解析出来，但如果连内容都没有，就是端点的问题。
- 一切正常但界面空白 → 看 `iagent.log` 里那行 `模型请求失败: …`。

模型请求的超时是 **空闲 60 秒 / 单次最长 300 秒**，超时会明确报错而不是无限转圈。

---

## 3. 界面提示「连接被提前关闭」

这句话的意思是："SSE 流结束了，但我没收到结束标记 `done`"。可能是：

1. **误报（1.0.3 及以前）**：守护进程在预检阶段直接返回了错误（例如"尚未配置 API Key"），只发了 `error` 没发 `done`，界面就多叠加了这条吓人的提示。1.1.0 起：收到过 `error` 就不再报"提前关闭"，同时守护进程保证每次流都以 `done` 收尾。**看到这条时先往上翻，看有没有真正的错误卡片。**
2. **守护进程真的重启过**：卡片里会带 `pid`/重启次数/信号。对照下面第 4 节。
3. **模型连接中断**：`iagent.log` 里会有对应的 `模型请求失败` 行。

---

## 4. 守护进程没在跑 / 反复重启

```sh
launchctl print system/com.dsh.iagent.daemon | head -30   # state / pid / last exit status
launchctl kickstart -k system/com.dsh.iagent.daemon        # 手动重启一次
```

判断：

- `state = waiting` 且反复出现 → 它在崩溃循环，看 `iagentd-crash.log` 和 `iagentd.err.log`。
- 完全没有这个服务 → LaunchDaemon 没被加载：确认 plist 在
  `<jbroot>/Library/LaunchDaemons/com.dsh.iagent.daemon.plist`，RootHide 还要在
  `<jbroot>/basebin/LaunchDaemons/` 有一份（1.0.1 起的 `postinst` 会自动复制）。
  `<jbroot>` 在 RootHide 上是 `/var/containers/Bundle/Application/.jbroot-<hex>`，Dopamine 上是 `/var/jb`。
- 隔一阵就重启一次、`lastCrash` 显示被信号杀掉但崩溃日志是空的 → 多半是**系统内存压力（jetsam）**杀掉的：这是 iOS 的正常行为，`KeepAlive`（1.1.0 起是无条件保活）会把它拉起来。可以观察 `/api/health` 里的 `restarts` 增长速度和当时是否有大模型回答/长终端输出。

`/api/health` 里的 `pid`、`startedAt`、`restarts`、`lastCrash`、`lastExitClean` 就是给这件事用的：界面每 5 秒轮询一次，`pid` 变了就会告诉你"守护进程已重启"。

---

## 5. 悬浮球不出现

守护进程能用（`curl` 通）但悬浮球没有 → 是 SpringBoard 插件没注入：

1. 确认这两个文件在 `<jbroot>/Library/MobileSubstrate/DynamicLibraries/`：`iagent.dylib` 和 `iagent.plist`；
2. `iagent.plist` 的 `Filter.Bundles` 必须只含 `com.apple.springboard`；
3. **重启一次 SpringBoard**（`sbreload`，没有就用 `killall -9 SpringBoard`）—— 插件只在 SpringBoard 启动时注入；
4. 还不行就看设备控制台里插件的 `[iAgent] HID backend:` / `[iAgent] AX backend:` 两行（走 `NSLog`），以及 `iagent.log` 里的 `iAgent tweak … 已载入 SpringBoard`。

不改悬浮球也能用：Safari 打开 `http://127.0.0.1:8080`。

---

## 6. 装错架构

`dpkg --print-architecture` 的输出必须和包名一致：

| 设备 | 架构 | 该装的包 |
| --- | --- | --- |
| iPhone 6s / 6sp / 7 / 8 / X（A9–A11） | `iphoneos-arm64` | `..._iphoneos-arm64.deb` |
| iPhone XS 及以后（A12+） | 视越狱而定，多为 `iphoneos-arm64e` | `..._iphoneos-arm64e.deb` |

注意：**RootHide 不等于 arm64e**。RootHide 只是把 rootless 包透明安装到随机 jbroot；架构仍然取决于芯片（A9 就是 arm64）。
