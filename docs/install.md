# 安装与排错

## 前置条件

| 项目 | 要求 |
| --- | --- |
| 设备 | arm64 / arm64e 的 iPhone / iPad |
| 系统 | iOS 15.0 及以上（`Depends: firmware (>= 15.0)`） |
| 越狱 | Dopamine 一类 **rootless**（jailbreak root = `/var/jb`）或 **RootHide / roothide Bootstrap**（随机 jbroot） |
| 包管理器 | Sileo / Zebra / `dpkg` |
| 需要联网 | 仅用于调用你配置的模型接口（回环 HTTP 不需要网络） |

不需要安装 CydiaSubstrate / ElleKit 之外的额外依赖：插件是纯构造器 dylib，由越狱自带的注入器（ElleKit / roothide 注入器）加载。

## 安装

### 方式 A：用 Sileo / Zebra 安装（推荐）

把 `com.dsh.iagent_1.0.0_iphoneos-arm64.deb` 传到设备（AirDrop、`scp`、Filza 均可），点击后用 Sileo 打开并安装。安装结束会自动 respring。

### 方式 B：命令行

```bash
# 在设备上（root）
dpkg -i /var/mobile/com.dsh.iagent_1.0.0_iphoneos-arm64.deb
# 依赖或权限有问题时
apt-get -f install
```

也可以从 Mac / PC 直接推：

```bash
scp packages/*.deb root@<设备IP>:/var/mobile/
ssh root@<设备IP> 'dpkg -i /var/mobile/*.deb'
```

### 安装完成后会发生什么

`layout/DEBIAN/postinst` 依次做这几件事（脚本可以在 `/var/lib/dpkg/info/com.dsh.iagent.postinst` 查看）：

1. **推导 jailbreak root**：从 `$0`（`<jbroot>/var/lib/dpkg/info/com.dsh.iagent.postinst`）里截出前缀；Dopamine 得到 `/var/jb`，RootHide 得到 `<随机 jbroot>`。推导失败时退回 `/var/jb`，再退回系统根。
2. **创建数据目录** `/var/mobile/Library/iAgent/{logs,sessions,approvals}` 并 `chown mobile:mobile`（守护进程是 root，插件是 mobile 用户，两边都要读写）。
3. **改写 LaunchDaemon**：`layout/Library/LaunchDaemons/com.dsh.iagent.daemon.plist` 里写的是 rootless 路径 `/var/jb/usr/bin/iagentd`，如果实际 jbroot 不是 `/var/jb` 就用 `sed` 换成真实路径。
4. **RootHide 额外步骤**：当 `<jbroot>/basebin` 存在时，把 plist 复制到 `<jbroot>/basebin/LaunchDaemons/`，因为 RootHide 从那里加载系统守护进程。
5. **启动守护进程**：`launchctl bootout system <plist>` 再 `launchctl bootstrap system <plist>`；老版本 launchctl 退回 `launchctl load -w`。这一步失败不会中断安装。
6. **respring**：优先 `sbreload`，否则 `killall -9 SpringBoard`，让插件被注入。

## 验证安装

```bash
# 1) 守护进程是否在跑
launchctl print system/com.dsh.iagent.daemon | head -n 20
ps -A | grep iagentd

# 2) 二进制是否可执行、路径是否解析正确
iagentd --print-paths      # 打印 jbroot / 数据目录 / 配置 / 日志 / Web 根目录
iagentd --version

# 3) HTTP 是否可用（守护进程默认只监听回环）
curl -s http://127.0.0.1:8080/api/health | head -c 400

# 4) 插件是否加载
ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/iagent.dylib   # RootHide 换成 <jbroot>/...
tail -n 50 /var/mobile/Library/iAgent/logs/iagent.log
```

`/api/health` 返回的 JSON 里包含设备型号、系统版本、注入桥接是否连接、工具数量、HTTP 统计，是判断「装好没有」最快的方式。

日志文件：

| 文件 | 内容 |
| --- | --- |
| `/var/mobile/Library/iAgent/logs/iagent.log` | daemon 与插件共用的日志（超过 4MB 轮转为 `.1`，只保留一代）；插件里 `IAGAutomation` 的 HID/AX 后端信息走 `NSLog`，要看设备控制台 |
| `/var/mobile/Library/iAgent/logs/iagentd.out.log` | stdout（LaunchDaemon 重定向） |
| `/var/mobile/Library/iAgent/logs/iagentd.err.log` | stderr，启动崩溃看这里 |

## 首次配置

打开控制面板（悬浮球 / `http://127.0.0.1:8080`）→「设置」，填写：

| 键 | 说明 |
| --- | --- |
| `baseUrl` | OpenAI 兼容接口前缀，例如 `https://api.openai.com/v1`；客户端会补 `/chat/completions` |
| `apiKey` | 明文保存在 `config.plist`（0644） |
| `model` | 例如 `gpt-4o-mini` |
| `approvalMode` | `auto`（不确认）/ `dangerous`（默认）/ `always`（每次工具都确认） |
| `port` | 默认 8080，改完需要重启守护进程：`launchctl kickstart -k system/com.dsh.iagent.daemon` |

## 排错

| 现象 | 原因 / 处理 |
| --- | --- |
| 看不到悬浮球 | 插件没被注入：确认 `/Library/MobileSubstrate/DynamicLibraries/iagent.dylib` 与 `iagent.plist` 都在 jbroot 下、`iagent.plist` 的 Filter 只含 `com.apple.springboard`；然后 respring。仍未出现就看设备控制台里插件的 `[iAgent] HID backend:` / `[iAgent] AX backend:`（这两行走 `NSLog`，不写日志文件），以及 `/var/mobile/Library/iAgent/logs/iagent.log` 里的 `iAgent tweak 1.0.0 已载入 SpringBoard`——构造器里任何异常都会被吞掉，只留日志 |
| 悬浮球点了没反应 | 守护进程没起来（面板会提示「守护进程 iagentd 未在运行」）。`iagentd --print-paths` 手动跑一次，看是不是路径/权限问题 |
| 控制面板白屏 | SpringBoard 内嵌 WKWebView 渲染失败（iOS 15/16 已知问题）。插件在 6 秒超时后自动改用 Safari；也可以用长按菜单 →「在浏览器中打开」 |
| 面板打不开、提示连接失败 | 端口被占用或改了端口没重启守护进程；`curl http://127.0.0.1:8080/api/health` 先确认守护进程活着 |
| `401 Unauthorized` | 设置里填了 `authToken`，访问时必须带 `X-IAG-Token` 头或 `?token=`。浏览器直接访问时用 `http://127.0.0.1:8080/?token=<token>` |
| 设置保存失败 | 守护进程写 `config.plist` 失败（目录权限）；`chmod 755 /var/mobile/Library/iAgent` 后重试。开启 `requestLogging` 看具体错误 |
| 悬浮球拖动后位置不记住 | 插件（mobile 用户）在 RootHide 沙箱下可能写不了 `config.plist`，位置是尽力而为 |
| `ui_*` 工具报「桥接未连接」 | 插件没加载或刚 respring 完还在连接。`/api/health` 的 `bridge.connected` 字段可以直接看到状态 |
| `ui_describe` 说无障碍不可用 | `AXRuntime` 的 `AXElement` 在当前系统上不可用（未在真机验证过）。改用 `ui_tap` 的 `x`/`y` 坐标 |
| 终端没有输出 / 卡住 | 只支持真 PTY；`/api/term/open` 创建失败通常是找不到可用 shell（依次尝试 `/bin/zsh`、`/var/jb/bin/zsh`、`/bin/bash`、`/var/jb/bin/bash`、`/bin/sh`，最后兜底 `/bin/sh`）。单个 daemon 最多 8 个终端会话，超出会报「终端数量已达上限（8）」 |
| 定时任务不执行 | 守护进程必须在跑（cron 在守护进程内）。`cron_list` 看 `lastResult` / `lastExitCode`；时间按设备本地时区 |

## 卸载

```bash
dpkg -r com.dsh.iagent        # 或 Sileo 里卸载
```

`prerm` 会 `launchctl bootout` 掉守护进程、删掉 RootHide basebin 里的那份 plist、杀掉 `iagentd`，并 respring 让 dylib 从 SpringBoard 里卸载。

**用户数据不会被删除**：`/var/mobile/Library/iAgent`（配置、会话、日志、定时任务）会保留，需要彻底清理时手动删除：

```bash
rm -rf /var/mobile/Library/iAgent
```

## RootHide 注意事项

- RootHide 没有 `/var/jb`：真实前缀是 `/var/containers/Bundle/Application/.jbroot-<16位十六进制>`，用 `IAGJailbreakRoot()` 解析（源码里不写死路径）。
- jbroot 里的 `/var` 与 `/tmp` 下的 Mach-O **不能**被加载，因此应用数据仍然放在 rootfs 的 `/var/mobile/Library/iAgent`。
- 插件运行在 mobile 用户下，RootHide 的沙箱可能拒绝它写 rootfs 的这个目录；守护进程侧的读写不受影响，插件侧全部是 best-effort（日志写不进去就只打 stderr）。
- RootHide 版本需要 roothide/theos 编译（`IAG_ROOTHIDE=1`，Architecture 变成 `iphoneos-arm64e`）。同一份 rootless 包通常也能装上（rpath 同时包含 `/var/jb/*` 和 `@loader_path/.jbroot/*`），但要真正验证请构建对应架构。
