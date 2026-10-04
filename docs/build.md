# 构建

## 本地构建（macOS + Theos）

```bash
# 1) Theos 与 iOS SDK
export THEOS=~/theos
git clone --recursive https://github.com/theos/theos.git "$THEOS"
#    SDK 从 https://github.com/theos/sdks 取，解压到 $THEOS/sdks/

# 2) 构建（默认 rootless / Dopamine）
cd iagent
make clean package FINALPACKAGE=1
ls -l packages/
```

产物：`packages/com.dsh.iagent_1.0.0_iphoneos-arm64.deb`。

有用的开关：

| 变量 | 作用 |
| --- | --- |
| `FINALPACKAGE=1` | 正式包（否则包名带 debug 后缀） |
| `DEBUG=0` | 关闭 `-O0 -g`，减小体积 |
| `ARCHS=arm64` | 只构建 arm64（A11 及更早的机器） |
| `IAG_ROOTHIDE=1` | 用 roothide/theos 构建 RootHide 版本（`iphoneos-arm64e`） |
| `make paths` | 打印当前配置解析出的 jbroot / 包架构 / Web 目录 |

`make package` 会经过：

1. `tool.mk` → 编译 `iagentd`（19 个源文件），用 `entitlements.plist` 做 ldid 签名，装到 `/usr/bin`；
2. `tweak.mk` → 编译 `iagent.dylib`（7 个源文件），装到 `/Library/MobileSubstrate/DynamicLibraries`；`iagent_LOGOSFLAGS = -c generator=internal`，且源码里没有任何 `%hook`，因此**不会**产生 CydiaSubstrate 依赖；
3. `aggregate.mk` → 合并成一个 `.deb`；
4. `before-package` 钩子 → 给 `layout/DEBIAN/postinst`、`prerm` 补 `0755` 权限（Windows / ZIP 来源的源码树没有可执行位）。

包内容（rootless 方案会在路径前加 `/var/jb`）：

```
/usr/bin/iagentd
/Library/MobileSubstrate/DynamicLibraries/iagent.dylib
/Library/MobileSubstrate/DynamicLibraries/iagent.plist
/Library/LaunchDaemons/com.dsh.iagent.daemon.plist
/usr/share/iagent/web/{index.html,app.js,style.css}
```

## RootHide 构建

```bash
export THEOS=~/theos-roothide
git clone --recursive https://github.com/roothide/theos.git "$THEOS"
cd iagent
make clean package FINALPACKAGE=1 IAG_ROOTHIDE=1 ARCHS=arm64e
```

区别只在 `THEOS_PACKAGE_SCHEME = roothide` 带来的安装前缀与 `@loader_path/.jbroot` 形式的 install name，以及 `Architecture: iphoneos-arm64e`。`postinst` 是同一份，会自行推导 jbroot 并把 LaunchDaemon 复制到 `basebin/LaunchDaemons`。

## 云端构建（GitHub Actions）

工作流在 `.github/workflows/build.yml`：

| Job | 触发 | 说明 |
| --- | --- | --- |
| `rootless` | push / PR / tag / 手动 | 主产物。`macos-15`（arm64）runner，克隆 Theos + SDK，`make clean package FINALPACKAGE=1` |
| `roothide` | 仅手动且 `roothide=true` | `continue-on-error: true`，用 roothide/theos，失败不阻塞 |

`rootless` job 在打包后会**校验包内容**：`iagentd`、`iagent.dylib`、`web/index.html` 必须存在，且 `DEBIAN/postinst` 必须是 `-rwx`。缺少任何一项直接让 CI 失败——这是在没有真机的情况下能拿到的最强保障。

打 tag（`v1.0.0` 之类）时会用 `softprops/action-gh-release` 自动建 Release 并附上 `.deb`；其他情况从 Actions 页面的 Artifacts 下载。

## 从源码自检（不需要 Mac）

任何平台上都可以跑：

```bash
python3 scripts/preflight.py          # 或 python scripts/preflight.py
python3 scripts/preflight.py --verbose
```

它会检查（有 node 时还会跑 `node --check`）：

1. 所有 `#import "…"` 都能解析到实际文件；每个 `.m/.h` 的 `{}`/`()`/`[]` 配平（能抓住"编辑把文件写坏了"）；头文件有 include guard；
2. Makefile 里两个实例的源文件清单都存在、目录里的 `.m` 没有漏登记、引用的 framework 都在 `*_FRAMEWORKS` 里、`CODESIGN_FLAGS` 指向的 entitlements 存在；
3. LaunchDaemon plist 有 `Label`/`ProgramArguments`/`RunAtLoad` 且指向 `iagentd`，注入过滤器只含 `com.apple.springboard` 且与 dylib 同名；
4. `layout/DEBIAN/control` 字段齐全、维护脚本是 `#!/bin/sh` 且没有 CRLF；
5. Web UI：`app.js` 语法、用到的每个 DOM id 都存在于 `index.html`、每个 HTTP 路径都真的在 `IAGDaemon.m` 里注册过；
6. `IAGVersion.h` / `PACKAGE_VERSION` / `control` 的版本号一致，`postinst` 与 `IAGPaths.m` 用同一个数据目录。

退出码非 0 表示存在 FAIL（WARN 只是提醒）。它不能替代编译，但能把绝大多数低级错误挡在 CI 之前。

## 目前无法验证的部分

这套代码从未在真机或 macOS 上编译过。第一次真正构建时，请重点留意：

| 风险点 | 说明 |
| --- | --- |
| 编译错误 | 全部 26 个源文件都是手写且未经编译器检查；`preflight.py` 只能查结构与括号配平 |
| Theos 变量拼写 | `PACKAGE_ID` / `THEOS_PACKAGE_NAME` 等在不同 Theos 版本里叫法不一（Makefile 里同时写了多种），`layout/DEBIAN/control` 是兜底 |
| RootHide 架构接受度 | `iphoneos-arm64e` 与 roothide Bootstrap 的匹配情况未实测 |
| 第三方 LaunchDaemon 加载 | iOS 15+ 上 `launchctl bootstrap system <plist>` 是否直接生效未实测；`postinst` 同时尝试 `load -w`，最坏情况重启一次设备即可 |
| `UserName: mobile` | LaunchDaemon plist 里没有强制用户，守护进程以 root 运行（需要 root 才能开 PTY、读写系统路径） |
| entitlements | `platform-application` + `com.apple.private.security.no-sandbox` 等组合来自 XXTouch 的公开 plist，但未在 iOS 15/16 上实测 |
| 私有 API 行为 | HID 注入字段偏移、`AXElement` 可用性、SpringBoard 内 WKWebView 渲染，见 `docs/research/ios-private-apis.md` 的「未查证」小节 |
| 插件与守护进程的日志共享 | 插件以 mobile 身份写 `/var/mobile/Library/iAgent/logs/`，RootHide 沙箱下可能失败（仅日志，不影响功能） |
