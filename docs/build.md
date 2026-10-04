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
| 编译 | ✅ 已在 CI 上验证：26 个源文件 arm64 + arm64e 全部编译、链接、签名通过，`.deb` 产出并逐项断言 |
| RootHide 架构接受度 | `iphoneos-arm64e` 与 roothide Bootstrap 的匹配情况未实测（CI 的 roothide job 需要手动触发） |
| 第三方 LaunchDaemon 加载 | iOS 15+ 上 `launchctl bootstrap system <plist>` 是否直接生效未实测；`postinst` 同时尝试 `load -w`，最坏情况重启一次设备即可 |
| `UserName: mobile` | LaunchDaemon plist 里没有强制用户，守护进程以 root 运行（需要 root 才能开 PTY、读写系统路径） |
| entitlements | `platform-application` + `com.apple.private.security.no-sandbox` 等组合来自 XXTouch 的公开 plist，但未在 iOS 15/16 上实测（签名能过，是否被内核接受要真机看） |
| 私有 API 行为 | HID 注入字段偏移、`AXElement` 可用性、SpringBoard 内 WKWebView 渲染，见 `docs/research/ios-private-apis.md` 的「未查证」小节 |
| 插件与守护进程的日志共享 | 插件以 mobile 身份写 `/var/mobile/Library/iAgent/logs/`，RootHide 沙箱下可能失败（仅日志，不影响功能） |

## CI 首次构建发现并修掉的问题

第一次真正编译暴露了 6 个静态检查抓不到的错误，都已修复（对应 commit 见仓库历史）：

| 文件 | 问题 | 修法 |
| --- | --- | --- |
| `daemon/IAGHTTPServer.m` | `stream.end;` 被 clang 当成"属性访问取副作用"（默认错误） | 改成 `[stream end];` |
| `daemon/IAGLLM.m` | 类扩展里重复声明了头文件已经可读写的属性 | 删掉冗余的扩展声明 |
| `daemon/IAGBridge.m` | `[self readyCommandsSince:cursor locked]` 少了一个参数（语法错误） | 改为 `locked:YES` |
| `shared/IAGPaths.m` | `#import <sys/statfs.h>` 是 Linux 头文件，iOS SDK 里不存在 | 换成 Darwin 的 `<sys/mount.h>` |
| `tweak/IAGTweak.m` | 自己编了 `UIPanGestureRecognizerState*` 之类不存在的枚举 | 全部改用 `UIGestureRecognizerState*` |
| `daemon/IAGToolDevice.m` | `CFUserNotificationCreate` 及其键在公开 iOS SDK 里标记为不可用 | 改为 `dlsym` 解析函数 + 自写字面量键名，既过编译也不产生链接依赖 |

另外两个是打包层面的：

- Theos 的 tweak staging 要求**项目根目录**存在 `iagent.plist`（过滤器），只有 `layout/` 里那份是不够的 —— 现在两处都有。
- `layout/DEBIAN/control` 里手写的 `Installed-Size` 会和 Theos 自动追加的那行重复，dpkg 会以
  `duplicate value for 'Installed-Size' field` 拒绝安装 —— 已删除，并给 CI 加了重复字段断言。

