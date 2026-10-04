# iAgent 工程事实备查：RootHide / Dopamine / Theos 云编译

> 调研目标：为「Windows 上写源码 + GitHub Actions(macOS runner) 用 Theos 云编译」的原生 iOS 越狱插件项目（rootless .deb，iOS 15+，同时面向 Dopamine 与 RootHide/roothide Bootstrap，含常驻 LaunchDaemon + SpringBoard 注入 dylib）提供**准确的工程事实**。
>
> 采集方式：不依赖记忆。全部结论来自 ①本机 git clone 的**源码行级证据**（clone 目录 `C:\Users\ssx\AppData\Local\Temp\jbstudy\`，各仓库 HEAD 见下表），②可公开访问的官方文档/仓库原文。`raw.githubusercontent.com` 在本机被网络重置，改用镜像 `https://gh-proxy.com/https://raw.githubusercontent.com/...` 与 `https://testingcf.jsdelivr.net/gh/...` 读取原文。
>
> 证据等级约定：
> - ✅ **已查证** = 有源码行级或官方文档原文证据（文末给出处）。
> - 🟡 **高置信推断** = 由已查证事实 + 明确的工具行为推出，但没有一行"就是这样写的"原文；交付前建议按第 10 节命令在真机/CI 复核。
> - ❓ **未查证** = 本次无法确认，禁止当成事实使用。

---

## 0. 结论速览（决策用）

| # | 结论 | 等级 |
|---|---|---|
| 1 | RootHide 的越狱根**不是 `/var/jb`**，而是 `/var/containers/Bundle/Application/.jbroot-<16位十六进制>`，每次越狱随机；同一越狱周期内由 `jbrand()` 提供系统级随机值 | ✅ |
| 2 | RootHide 下**没有任何名为 `/var/jb` 的路径**；依赖库一律用 `@loader_path/.jbroot/<绝对路径>` 形式链接（官方原话 + 示例 `@loader_path/.jbroot/usr/lib/libsubstrate.dylib`） | ✅ |
| 3 | 每个"含 Mach-O 的目录"会被自动创建 `.jbroot` 符号链接指向 jbroot（dpkg 装包时或越狱加载二进制时生成，卸包时清理）→ 这正是 `@loader_path/.jbroot/...` 能解析的原因 | ✅ |
| 4 | 现代 Theos 的 `THEOS_PACKAGE_SCHEME = rootless` 会**同时**加两组 rpath：`/var/jb/Library/Frameworks`、`/var/jb/usr/lib`（v1）**和** `@loader_path/.jbroot/Library/Frameworks`、`@loader_path/.jbroot/usr/lib`（v2）→ 同一个 rootless 包在 Dopamine 走 v1、在 RootHide 走 v2 | ✅（rpath 行级证据）+ 🟡（解析优先级推论） |
| 5 | `THEOS_PACKAGE_SCHEME = rootless` ⇒ `THEOS_PACKAGE_INSTALL_PREFIX = /var/jb`、`Architecture: iphoneos-arm64`；`THEOS_PACKAGE_SCHEME = roothide`（需 roothide/theos）⇒ `Architecture: iphoneos-arm64e` 且**不再**加 `-lroot` | ✅ |
| 6 | `Architecture: iphoneos-arm64`(rootless) 与 `iphoneos-arm64e`(roothide) 是两个不同包架构；跨架构安装是否被 RootHide 的 dpkg/Sileo 接受 **未查证** | ✅ / ❓ |
| 7 | RootHide 的 LaunchDaemon：basebin 自带 daemon 的 plist 放 `$JBROOT/basebin/LaunchDaemons/*.plist`，Bootstrap App 安装时把 plist 文本里的 `@JBROOT@` / `@JBRAND@` 占位符替换成真实 jbroot / 随机值 | ✅ |
| 8 | RootHide **不用 `launchctl load`** 管自己：它跑 `$JBROOT/basebin/bootstrapd daemon -f`，用 `$JBROOT/basebin/bsctl {check,stop,usreboot,openssh,resign}` 管理 | ✅ |
| 9 | Dopamine 侧：`launchd` 被 hook，daemon plist 从 `JBROOT/basebin/LaunchDaemons` 和 `JBROOT/Library/LaunchDaemons` 两处注入；Dopamine 自己用 `launchctl bootstrap system /var/jb/Library/LaunchDaemons` 载入 | ✅ |
| 10 | Dopamine 的 `/var/jb/usr/lib/libsubstrate.dylib` **存在**（ElleKit 安装的软链 → `libellekit.dylib`），`/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate` 同样存在 | ✅ |
| 11 | RootHide 对应路径是 `$JBROOT/usr/lib/libsubstrate.dylib`（即 `@loader_path/.jbroot/usr/lib/libsubstrate.dylib`）；`/var/jb/...` 绝对路径的 dylib 在 RootHide 上必然加载失败 | ✅ |
| 12 | `Depends: mobilesubstrate` 在 ElleKit 生态里**是可满足的**：`ellekit` 提供 `Provides: mobilesubstrate (= 99)` 并 `Conflicts: mobilesubstrate` | ✅ |
| 13 | Theos 的 Makefile **从不**给 tweak 加 `-lsubstrate`；Logos 默认生成器是 `MobileSubstrate`，会 `#include <substrate.h>` 并调用 `MSHookMessageEx` | ✅ |
| 14 | 不用任何 Logos/`%hook`（只有 `__attribute__((constructor))` + `dlopen/dlsym`）时，可以做到 dylib 里**完全没有 substrate 依赖**；Logos 只想要 `%ctor` 时可切 `internal` 生成器 | ✅（生成器存在）+ 🟡（"没有依赖"的实际链上验证） |
| 15 | `layout/` 语义：`layout/**` 原样进 staging，非 `DEBIAN` 顶层项在 rootless 方案下整体搬到 `/var/jb` 前缀下；`layout/DEBIAN/*` → 包内 `DEBIAN/*`（**不加前缀**） | ✅ |
| 16 | 常驻工具（`TOOL_NAME`）默认装到 `/usr/bin`，rootless 下即 `/var/jb/usr/bin/iagentd`；staging 用的是 `cp`（保留二进制 0755 权限） | ✅ |
| 17 | RootHide 下 tweak **只能写 `$JBROOT/var/`（和 `$JBROOT/tmp/`）**；且 `$JBROOT/var/`、`$JBROOT/tmp/` 里的 Mach-O **无法被加载**（iOS 安全机制） | ✅ |
| 18 | GH Actions：macOS runner 现役标签 `macos-15` / `macos-26` = **arm64**，`macos-15-intel` / `macos-26-intel` = x64（`macos-13` 已下架） | ✅ |

---

## 1. 证据来源与复现

### 1.1 本次读取的仓库（HEAD 均已固定，可复现）

| 仓库 | HEAD commit | 用途 |
|---|---|---|
| https://github.com/theos/theos | `dd5c14bb9d91311e221d51b5bfb8c9e5948156db` | Theos 本体（scheme、layout、package 规则） |
| https://github.com/roothide/theos | `88506b2c22e9e07dd4ed055f23c9e398a117a2c7` | roothide 分支 Theos（roothide scheme / vendor mod） |
| https://github.com/roothide/libroothide | `7764c54759009272b4f2f23c18c62b21794fe6dd` | roothide 运行时库、API、`.jbroot` 机制 |
| https://github.com/roothide/Bootstrap | `428a8c26044ac39f3741b176c5c08f1122d1b9f7` | RootHide Bootstrap App（jbroot 发现、daemon 处理） |
| https://github.com/opa334/Dopamine | `1a54e76d515ff5916b64e44d6afbb57d2bc89ee9` | Dopamine（launchd hook、rootless 布局） |
| https://github.com/evelyneee/ellekit | `1017a0d09606ea49ba8bc4d6cccc530d372e640e` | ElleKit（注入器与 substrate 兼容软链） |
| https://github.com/theos/lib | `6f2af307568e6b8c52181d26314b0cd69ffaf188` | Theos 自带 `.tbd`（substrate 的 install_name！） |
| https://github.com/theos/logos | `777925d1add4ee3485a2432a6f6d5e3ded59de7b` | Logos 生成器（生成什么代码） |

### 1.2 官方文档（本次逐字读取原文）

- Theos：https://theos.dev/docs/rootless ，https://theos.dev/docs/packaging ，https://theos.dev/docs/modules ，https://theos.dev/docs/installation-macos ，https://theos.dev/docs/installation-linux ，https://theos.dev/docs/arm64e-deployment
- roothide（官方 developer 文档，**这份最重要**）：https://github.com/roothide/Developer/blob/main/roothide.md ，`interface.md` ，`vroot.md` ，`filemirror.md` ，`entitlements.md`
- ElleKit：https://github.com/evelyneee/ellekit
- GitHub runner 规格：https://github.com/actions/runner-images/blob/main/README.md

### 1.3 复现方式（本机命令）

```powershell
$base = "$env:TEMP\jbstudy"
git clone --depth 1 https://github.com/theos/theos.git $base\theos
git clone --depth 1 https://github.com/roothide/theos.git $base\roothide_theos
git clone --depth 1 https://github.com/roothide/libroothide.git $base\libroothide
git clone --depth 1 https://github.com/roothide/Bootstrap.git $base\Bootstrap
git clone --depth 1 https://github.com/opa334/Dopamine.git $base\Dopamine
git clone --depth 1 https://github.com/evelyneee/ellekit.git $base\ellekit
```

被墙文件的读取方式（谁能用就用谁）：`https://gh-proxy.com/https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>`（`raw.githubusercontent.com` 在本机直接超时/重置；`gh-proxy.com` 可用）；jsdelivr 适合 `.md`，对 `.mk` 会报 `unsupported content type "application/octet-stream"`。

---

## 2. RootHide（roothide）机制事实

### 2.1 jbroot 是随机路径 ✅

`Bootstrap/Bootstrap/utils.m`（Bootstrap 仓库）与 `libroothide/common.h`、`common.c` 一致：

```c
#define JB_ROOT_PREFIX ".jbroot-"
#define JB_RAND_LENGTH  (sizeof(uint64_t)*sizeof(char)*2)   // 16
int is_jbroot_name(const char* name);                       // 校验 ".jbroot-" + 16 hex
uint64_t resolve_jbrand_value(const char* name);             // 从目录名解出 jbrand
```

- jbroot 的父目录（`JB_ROOT_PARENT`）= `/var/containers/Bundle/Application`，即越狱根伪装成一个 App 容器目录名 `.jbroot-XXXXXXXXXXXXXXXX`。
- 目录名里那 16 位十六进制**不是纯随机**：`jbrand_new()` 生成 `value`，再把低 8 位替换成其余 7 字节的 XOR 校验，`is_jbrand_value()` 校验 —— 所以是"可校验的随机值"，任何进程都能凭目录名判断这是不是 jbroot。
- 实测代码（Bootstrap App 自己的发现逻辑，`Bootstrap/Bootstrap/utils.m`）：

```objc
NSArray *subItems = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application/" error:nil];
for (NSString *subItem in subItems) {
    if (is_jbroot_name(subItem.UTF8String)) { jbroot = [@"/var/containers/Bundle/Application/" stringByAppendingPathComponent:subItem]; break; }
}
```

### 2.2 API 与头文件（roothide.h 从哪来）✅

**头文件来源**：`roothide/theos` 的 `vendor/include` 子模块指向 `https://github.com/roothide/headers.git`（见 `roothide_theos/.gitmodules`）。在该仓库里：

```c
/* roothide/headers/roothide.h —— 就是本文件内容 */
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#include <roothide/roothide.h>
#else
#include <roothide/stub.h>          // rootful/rootless 编译时全部变成空 stub
#endif
```

官方 `interface.md` 原话："`#include <roothide.h>` … **it has been included in theos, you can use it directly** in c/c++/objc/swift-bridging-header. when you compile for rootful/rootless, all APIs in it will become empty stub functions for compatibility."

**API 清单**（`libroothide/roothide.h` 全文，1231 字节）：

```c
const char* rootfs_alloc(const char* path);   /* free after use */
const char* jbroot_alloc(const char* path);   /* free after use */
const char* jbrootat_alloc(int fd, const char* path); /* free after use */
unsigned long long jbrand();                  /* 当前越狱状态的系统级随机值 */
const char* jbroot(const char* path);
const char* rootfs(const char* path);
/* 另有 NSString* / std::string 重载 */
```

**方向语义（重要，官方文档自相矛盾，以官方示例与真实调用为准）**：

- `jbroot("/相对路径")` → 返回**真实绝对路径**（`$JBROOT/<相对路径>`）。证据：Bootstrap 里 `spawn_root(jbroot(@"/basebin/bootstrapd"), …)`、`copyItemAtPath:… toPath:jbroot(@"/basebin")`，被 spawn/拷贝的目标确实在 jbroot 里；`jbroot("/")` = jbroot 自身。
- `rootfs(真实绝对路径)` → 返回**jbroot 视角的逻辑路径**，用来交给 bootstrap 里的工具：官方示例 `char* args = {"/usr/bin/rm", "-f", rootfs(filepath), NULL};`，而 `/usr/bin/rm` 是通过 `posix_spawn(jbroot("/usr/bin/rm"))` 起的、运行在 vroot 下（它的 `/` 就是 jbroot），所以必须拿到 `/etc/x` 这种逻辑路径。
- ⚠️ `interface.md` 末尾的 Mnemonic 表把方向写成 "jbroot: jbroot-based → rootfs-based"，与它自己上面的示例相反；`roothide.h` 的行内注释也这么说。**按示例走**，不要按表格走。🟡（对照证据充分，但上游文档确实写乱了）
- `jbrand()` 值"直到下次越狱都不变"，可用于给 XPC 服务名加后缀。

**命令行工具** ✅：`jbroot` / `rootfs` / `jbrand` 也提供 CLI，用于 shell/脚本转换路径（`interface.md` 末尾 "Command Line Tool"）。

**模块自动链接** ✅：`libroothide/module.modulemap` 声明 `module roothide { header "roothide.h"; link "roothide"; export * }`，所以开启 clang modules 时会自动带上 `-lroothide`；反之 `roothide_theos/vendor/mod/roothide/instance/rules.mk` 会在关闭 modules 时告警：

```make
$(warning "*** You have disabled clang modules. To use the roothide api, please add `-lroothide` to LDFLAGS ***")
```

### 2.3 链接与 `.jbroot` 符号链接（RootHide 的核心机制）✅

`roothide/Developer/roothide.md` 原文（逐字要点）：

1. roothide 不使用固定 `/var/jb`，每次越狱 (re)install 到随机名目录 jbroot。
2. **"roothide uses the dyld variable `@loader_path` to link dependent libraries. all dependent libraries should set install_name to `@loader_path/.jbroot/absolute_path_to_lib`"**，示例：
   ```
   @loader_path/.jbroot/usr/lib/libsubstrate.dylib
   @loader_path/.jbroot/Library/Frameworks/Cephei.framework/Cephei
   ```
3. **"each directory containing a mach-o file will automatically generate a `.jbroot` symbolic link that pointing to the jailbreak root directory, it's usually generated by dpkg when installing packages, or generated by the jailbreak itself when loading a binary/library, and roothide will automatically remove the related `.jbroot` symbolic link to keep system clean when dpkg removes a package."**
4. Bootstrap 与 rootfs 的关系：**"roothide's bootstrap uses jbroot as the default root, and roothide creates a symbolic link named `rootfs` in jbroot to provide bootstrap access to the iOS original root file system"**；"**all command line tools in bootstrap will only accept jbroot-based paths, and will only output jbroot-based paths. (and you should also use this path rule in jailbreak plist/config/shell-script files)**"，示例：
   ```
   cp /var/config.plist /etc/config.plist              # 全程在 jbroot 内
   cp /rootfs/var/config.plist /etc/config.plist       # rootfs → jbroot
   cp /etc/config.plist /rootfs/var/config.plist       # jbroot → rootfs
   ```

`.jbroot` 链接的批量修复工具（`libroothide/updatelink.c` + `updatelinks.sh`）：一条 shell 脚本枚举 `/` 与 `/private/var/` 下的符号链接，喂给 `/usr/libexec/updatelink`，由它把相对/绝对符号链接重写成 jbroot 语义（`libroothide/updatelink.c` 里 `jbfirmlinks[] = { "/var" }` 是例外表）。RootHide 侧运行它的位置（Bootstrap 源代码）：

```objc
// Bootstrap/Bootstrap/bootstrap.m
ASSERT(spawn_bootstrap_binary((char*[]){"/bin/sh", "/usr/libexec/updatelinks.sh", NULL}, nil, nil) == 0);
```

另外 `libroothide/symredirect.cpp` 会把 Mach-O 里的 **vroot API 符号**改指到 shim：`const char* g_shim_install_name = "@loader_path/.jbroot/usr/lib/libvrootapi.dylib";`（即 C/C++ 程序的文件 API 被 `libvroot` 换成"以 jbroot 为根"的实现，见 `vroot.md`："changes the default root of file system for programs/modules by replacing all system APIs related to file paths at compile/build time"）。

`filemirror.md` 列出了 jbroot 里被固定成指向 rootfs 的目录：jbroot 自身（`rootfs`）、`/dev`、`/private/preboot`、`/var/containers`、`/var/mobile/Containers`、`/usr/share/misc/trace.codes`、`/usr/share/zoneinfo`、`/etc/hosts.equiv`、`/etc/hosts`、`/var/run/utmpx`、`/var/db/timezone`、`/System/Library/CoreServices/SystemVersion.plist` ✅

### 2.4 RootHide 下权限与写文件（真机踩坑点）✅

`roothide/Developer/entitlements.md` 原文要点：

- 越狱二进制默认被沙盒化，需要基础 entitlements：
  ```xml
  <key>platform-application</key><true/>
  <key>com.apple.private.security.no-sandbox</key><true/>
  <key>com.apple.private.security.storage.AppBundles</key><true/>
  <key>com.apple.private.security.storage.AppDataContainers</key><true/>
  ```
- **"except for `/var/` in jbroot, your tweak may not be able to modify(write) files in other jailbreak directories (even through libSandy)"**，建议所有数据放 `$JBROOT/var/`。
- **"macho files(executable/framework/dylib) in `jbroot:/var/` or `jbroot:/tmp/` can not be loaded due to the security mechanism of iOS, you should put them in other directories in jbroot."**
- `$JBROOT/System` 目录是保留目录（镜像 rootfs 的关键文件），不要往里存东西。

> 对本项目的直接影响：iAgent 的数据目录若放在 rootfs（`/var/mobile/Library/iAgent`）则 tweak 侧能否写、daemon 侧怎么共享，需要按上表复核；RootHide 官方建议是 `$JBROOT/var/`，但那与 rootfs 共享/跨越狱重启保留的诉求冲突（见 §9 建议）。

---

## 3. 标准 rootless deb 在 RootHide 上能不能装/跑

这题必须拆成"**装（dpkg/apt）**"和"**跑（dyld/路径）**"两半。

### 3.1 已验证的机制事实

1. ✅ **两种包架构不同**：rootless 方案强制 `THEOS_PACKAGE_ARCH := iphoneos-arm64`（`theos/vendor/mod/rootless/package/deb.mk`），roothide 方案强制 `iphoneos-arm64e`（`roothide_theos/vendor/mod/roothide/package/deb.mk`）。RootHide 自己的包也是 arm64e：

   ```
   # roothide/Bootstrap/control
   Package: com.roothide.bootstrap.bootstrap-app
   Architecture: iphoneos-arm64e
   Depends: firmware (>= 15.0)
   ```

2. ✅ **rootless v2 产物天然兼容 RootHide 的 dyld 解析**：`theos/vendor/mod/rootless/instance/rules.mk` 只有两行，就是两组 rpath：
   ```make
   _THEOS_INTERNAL_LDFLAGS += -rpath $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/Frameworks -rpath $(THEOS_PACKAGE_INSTALL_PREFIX)/usr/lib # v1
   _THEOS_INTERNAL_LDFLAGS += -rpath '@loader_path/.jbroot/Library/Frameworks' -rpath '@loader_path/.jbroot/usr/lib' # v2
   ```
   Dopamine（有真实 `/var/jb`）由 v1 命中；RootHide 由 v2 命中（因为工具/库所在目录都有 `.jbroot` 链接）。所以**依赖写在 `@rpath` 上的 rootless 包，两边都能解析依赖** 🟡（rpath 只是搜索路径，最终命中的前提确实是 `.jbroot` 链接存在，官方已声明每个含 Mach-O 的目录都会自动生成）。
3. ✅ **硬编码 `/var/jb` 的东西在 RootHide 上必挂**：RootHide 上不存在 `/var/jb`（官方 roothide.md 第 1 条 + 随机目录实测逻辑）。这会命中三类东西：
   - dylib 的 `LC_LOAD_DYLIB` 是绝对 `/var/jb/usr/lib/xxx.dylib`（老 rootless v1 产物、手工 `-l` 链接的库）；
   - plist / 脚本 / 配置文件里写死 `/var/jb/...`；
   - postinst 里 `launchctl ... /var/jb/Library/LaunchDaemons/...`。
4. ✅ **依赖声明在两边都成立**：`Depends: mobilesubstrate` 可以由 ElleKit 满足（`ellekit/packaging/control`）：
   ```
   Package: ellekit
   Conflicts: com.ex.substitute, org.coolstar.libhooker, science.xnu.substitute, mobilesubstrate, com.saurik.substrate.safemode
   Replaces:  com.ex.libsubstitute, org.coolstar.libhooker, mobilesubstrate
   Provides:  mobilesubstrate (= 99), org.coolstar.libhooker (= 1.6.9)
   ```
   同一份 ElleKit 也把 substrate 兼容软链铺满（`ellekit/Makefile`，`INSTALL_PREFIX` 在 rootless 目标下 = `/var/jb`）：
   ```
   ln -s $(INSTALL_PREFIX)/usr/lib/libellekit.dylib $(INSTALL_ROOT)/usr/lib/libsubstrate.dylib
   mkdir -p $(INSTALL_ROOT)/Library/Frameworks/CydiaSubstrate.framework
   ln -s ${INSTALL_PREFIX}/usr/lib/libellekit.dylib $(INSTALL_ROOT)/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
   ln -s $(INSTALL_PREFIX)/usr/lib/libhooker.dylib  -> libellekit.dylib   (同 Makefile)
   ln -s $(INSTALL_PREFIX)/usr/lib/libblackjack.dylib -> libellekit.dylib
   ln -s .../ellekit/libinjector.dylib -> usr/lib/TweakLoader.dylib / TweakInject.dylib
   ln -s $(INSTALL_PREFIX)/usr/lib/TweakInject -> $(INSTALL_ROOT)/Library/MobileSubstrate/DynamicLibraries
   ```

### 3.2 未查证的部分 ❓

- ❓ RootHide 的 **dpkg/Sileo 是否接受 `Architecture: iphoneos-arm64`** 的包（dpkg 对 non-native arch 有强制检查，是否开了 `--force-architecture` / arch 白名单不确定）。→ 需要在真机 `dpkg -i --dry-run` 实测，或**干脆让 RootHide 目标出 `iphoneos-arm64e` 包**（用 roothide/theos + `THEOS_PACKAGE_SCHEME = roothide`）。
- ❓ 第三方 deb 的 `$JBROOT/Library/LaunchDaemons/*.plist` 在 RootHide 上由谁、何时载入（Bootstrap 源码里只看到它改写 `basebin/LaunchDaemons`，没看到扫描第三方目录；见 §4）。
- ❓ RootHide 的注入器到底是 ElleKit 的哪个 fork（Bootstrap 仓库源码里**没有** "ellekit" 字样；但存在 `usr/lib/DynamicPatches` + `.roothidepatch` 机制和 `Provides: mobilesubstrate` 生态一致性 → 🟡 推测为 roothide 版 ElleKit）。RootHide 的 Verifier/mobilesubstrate 提供者在 `strapfiles/bootstrap-1900.tar.zst` 里，本次环境**没有可用的 zstd/tar 工具**（`tar.exe`、`pwsh tar` 均不可用）故未展开该 tar。

### 3.3 结论（可执行的取舍）

> ✅ 想让**同一个源码树**同时喂饱 Dopamine 与 RootHide，最稳的是两条构建线：
> - **rootless 线**（Dopamine 及多数 rootless 越狱）：`THEOS_PACKAGE_SCHEME = rootless`，`Architecture: iphoneos-arm64`，依赖只写 `@rpath`/`@loader_path` 相对形式，绝不硬编码 `/var/jb` 到 Mach-O 里（plist 与 postinst 例外，见 §4/§9）。
> - **roothide 线**（RootHide）：用 roothide/theos + `THEOS_PACKAGE_SCHEME = roothide`，得到 `@loader_path/.jbroot/...` install_name + `iphoneos-arm64e` 包。
>
> 如果只出一个包，选 rootless v2（双 rpath）——它在 RootHide 上靠 `.jbroot` 也能解析；但**架构字段**与 **plist/脚本里的 `/var/jb`** 两层风险仍在（§3.2 的两条 ❓）。

---

## 4. LaunchDaemon（本项目常驻 `iagentd` 的关键）

### 4.1 Dopamine ✅

`Dopamine/BaseBin/launchdhook/src/daemon_hook.m`：hook 了 launchd 读取 daemon plist 的 XPC 路径，**额外**把两个目录里的 plist 注入：

- `JBROOT_PATH(@"/basebin/LaunchDaemons")`
- `JBROOT_PATH(@"/Library/LaunchDaemons")`

即 rootless 实际的 plist 目录是 **`/var/jb/Library/LaunchDaemons/`**（`/var/jb/basebin/LaunchDaemons` 是越狱自用）。plist 里的 `Program`/`ProgramArguments` 会被当作普通路径处理，所以**必须写 jbroot 真实路径**（`/var/jb/usr/bin/iagentd`，不能写 `/usr/bin/iagentd`）。

载入命令（Dopamine 自己就这么干，`Dopamine/BaseBin/dopamine/src/main.m`）：

```objc
exec_cmd_trusted("/var/jb/usr/bin/launchctl", "bootstrap", "system", "/var/jb/Library/LaunchDaemons", NULL);
```

源码注释还说明：从 stage2 dropbear 环境里 `launchctl load` 不可靠，所以用 `bootstrap`。

### 4.2 RootHide ✅（已查证部分）

`Bootstrap/Bootstrap/bootstrap.m` → `rebuildBasebin()`：

```objc
// 把 App 包里的 basebin 拷进 jbroot
ASSERT([fm copyItemAtPath:basebinPath toPath:jbroot(@"/basebin") error:nil]);
unlink(jbroot(@"/basebin/.jbroot").fileSystemRepresentation);
ASSERT([fm createSymbolicLinkAtPath:jbroot(@"/basebin/.jbroot") withDestinationPath:@"../.jbroot" error:nil]);

// 把 basebin 的 plist 里的占位符替换成真实值
NSURL *basebinDaemonsURL = [NSURL fileURLWithPath:jbroot(@"/basebin/LaunchDaemons")];
for (NSURL *fileURL in [fm contentsOfDirectoryAtURL:basebinDaemonsURL …]) {
    NSString* plistContent = [NSString stringWithContentsOfFile:fileURL.path …];
    plistContent = [plistContent stringByReplacingOccurrencesOfString:@"@JBROOT@" withString:jbroot(@"/")];
    plistContent = [plistContent stringByReplacingOccurrencesOfString:@"@JBRAND@" withString:[NSString stringWithFormat:@"%016llX",jbrand()]];
    ASSERT([plistContent writeToFile:fileURL.path atomically:YES …]);
}
```

启动/管理方式（同文件）：

```objc
int status = spawn_root(jbroot(@"/basebin/bootstrapd"), @[@"daemon",@"-f"], &log, &err);
status = spawn_root(jbroot(@"/basebin/bsctl"), @[@"check"], &log, &err);
// 其它子命令（Bootstrap/ViewController.m + bootstrap.m）：stop / usreboot / openssh start|stop|check / resign
```

要点：

- **`@JBROOT@` / `@JBRAND@` 占位符是 RootHide 官方支持的写法**，但**只看到 Bootstrap App 对 `$JBROOT/basebin/LaunchDaemons/` 做替换** ✅（第三方目录的自动替换 ❓）。
- RootHide 没有固定 `/var/jb`，所以第三方 plist 不能写死路径；二选一：① 安装期（postinst）用 roothide 的 `jbroot` CLI 或 `%JBROOT%` 占位替换后写入；② 交给 RootHide 的 vroot/patched launchd 解释（后者行为 ❓）。
- RootHide 官方明确要求：plist/config/shell 脚本里"**也要用 jbroot-based 路径规则**"（`roothide.md` 第 5 条）✅ —— 所以 plist 里写 `ProgramArguments = ("/usr/bin/iagentd")`（jbroot 逻辑路径）才是 RootHide 风格，而 Dopamine 要求写 `/var/jb/usr/bin/iagentd`。**两边 plist 内容不同，必须按目标出两份 plist，或 postinst 生成**。

### 4.3 `UserName: mobile` ❓

- 没有在 Dopamine/RootHide 源码或文档里找到关于 LaunchDaemon `UserName` 键的专门说明。Apple 的 launchd 支持 `UserName`（iOS 上 `mobile` 用户存在），所以理论上可用 🟡；但本项目 daemon 若需要读写 `$JBROOT/var` 或 rootfs 的 `/var/mobile/...`，请以 §2.4 的沙盒/权限事实为准 —— **是否降权到 mobile 取决于你要不要 root 权限去 spawn/bootstrap 工具**。建议：daemon 以 root 运行（默认），把用户态语义（文件属主）自己 `chown mobile`，或拆两个进程。交付前用 `launchctl print system/com.dsh.iagent.daemon` 看实际 uid。
- ❓ `launchctl bootstrap/kickstart/bootout` 在 RootHide 上是否与 Dopamine 行为一致（RootHide 的 `launchctl` 是 Procursus 的，且 launchd 由 roothide 注入的运行时处理 jbroot 路径）——真机验证命令见 §10。

---

## 5. Dopamine 侧其它事实

- ✅ 固定 rootless 前缀 `/var/jb`；`Dopamine/Packages/libroot/Makefile` 里就是 `LDFLAGS = -dynamiclib -rpath /var/jb`。
- ✅ 自带 ElleKit（`Dopamine/BaseBin/_external/lib/libellekit.tbd`，`install-name: '@rpath/CydiaSubstrate.framework/CydiaSubstrate'`）→ Dopamine 环境下 substrate 兼容层由 ElleKit 提供，`libsubstrate.dylib` 可用（§3.1 第 4 点）。
- ✅ `Packages/` 目录只有 `additional`、`basebin-link`、`libkrw-provider`、`libroot` 四个包（`basebin-link` 提供 `Provides: opainject`）。**Sileo/PreferenceLoader 不在 Dopamine 仓库中**，属于 bootstrap/用户安装范畴 ❓（不要写成"Dopamine 自带 Sileo"）。
- 注入目录：ElleKit 把 `Library/MobileSubstrate/DynamicLibraries` 做成 → `usr/lib/TweakInject` 的软链 ✅，所以 tweak 的默认安装路径 `/Library/MobileSubstrate/DynamicLibraries`（Theos `tweak.mk` 默认 `LOCAL_INSTALL_PATH`）在 rootless 下就是 `/var/jb/Library/MobileSubstrate/DynamicLibraries`，与 ElleKit 兼容 ✅。
- arm64 / arm64e：`Architecture:` 字段由 `THEOS_PACKAGE_ARCH` 决定（rootless 恒为 `iphoneos-arm64`），Mach-O 可以同时 `ARCHS = arm64 arm64e`；arm64e **新 ABI** 需要新 clang/ld64（Theos 文档：iOS 12.0–13.7 才需要 Xcode 11.7 的老 ABI；现代 iOS 14+ 用新 ABI，`export TARGET = iphone:latest:14.0` 之类的写法）✅（https://theos.dev/docs/arm64e-deployment）。

---

## 6. Theos：scheme、layout、打包，以及 substrate 链接四问

### 6.1 `THEOS_PACKAGE_SCHEME = rootless` 的确切效果 ✅

来源：`theos/vendor/mod/rootless/`（upstream theos 直接把这两个 mod 目录放在 `vendor/mod` 下，非 submodule；本机 `theos/vendor/mod/rootless/*` 5 个文件）与 `theos/makefiles/**`。

| 效果 | 证据 |
|---|---|
| `THEOS_PACKAGE_INSTALL_PREFIX = /var/jb` | `vendor/mod/rootless/package.mk` 全文件就一行 |
| `THEOS_PACKAGE_ARCH := iphoneos-arm64`（覆盖用户设置） | `vendor/mod/rootless/package/deb.mk`：`ifneq ($(THEOS_PACKAGE_ARCH),iphoneos-arm64) THEOS_PACKAGE_ARCH := iphoneos-arm64 endif` |
| 加 rpath `/var/jb/Library/Frameworks`、`/var/jb/usr/lib` **和** `@loader_path/.jbroot/Library/Frameworks`、`@loader_path/.jbroot/usr/lib` | `vendor/mod/rootless/instance/rules.mk` 两行（注释自带 `# v1` / `# v2`） |
| 库/框架 install_name 用 `@rpath/<name>` | `vendor/mod/rootless/instance/{library,framework}.mk` |
| 仍然加 `-lroot`（只在 roothide scheme 下跳过） | `roothide_theos/makefiles/instance/rules.mk:141` `ifneq ($(THEOS_PACKAGE_SCHEME),roothide) … -lroot …` |

`roothide` scheme 的差异（`roothide_theos/vendor/mod/roothide/`）✅：

- `THEOS_PACKAGE_ARCH := iphoneos-arm64e`；
- `install_name = @loader_path/.jbroot$(LOCAL_INSTALL_PATH)/...`；
- 定义 `THEOS_PACKAGE_SCHEME_ROOTHIDE=1`（`roothide.h` 的 shim 全靠它切换 stub / 真实现）；
- `-D THEOS_PACKAGE_INSTALL_PREFIX="/var/jb"`（给编译期用的宏，不代表磁盘上有 /var/jb）；
- `package.mk` 为空 → **不**覆盖 install prefix；
- 关闭 clang modules 时告警要手加 `-lroothide`。

### 6.2 `layout/` 打包语义 ✅

`theos/makefiles/stage.mk`：

```make
internal-stage:: [ -d layout ] && rsync -a "layout/" "$(THEOS_STAGING_DIR)" --exclude "DEBIAN"
```

`theos/makefiles/package/deb.mk`：`layout/DEBIAN/` → `$(THEOS_STAGING_DIR)/DEBIAN`；打包时 rootless 方案把 staging 里**非 DEBIAN 的顶层项整体搬进 `$(_THEOS_SCHEME_STAGE)`（= `$(THEOS_STAGING_TMP)/var/jb`）再合并**，`Architecture:` 取自 `THEOS_PACKAGE_ARCH`（scheme 覆盖优先）。

由此得到本项目（iAgent）的实际映射表：

| 仓库里的路径 | 包内路径 | 真机路径（Dopamine/rootless） | RootHide |
|---|---|---|---|
| `layout/usr/bin/iagentd` | `/var/jb/usr/bin/iagentd` | `/var/jb/usr/bin/iagentd` | `$JBROOT/usr/bin/iagentd` |
| `layout/usr/share/iagent/web/index.html` | `/var/jb/usr/share/iagent/web/index.html` | `/var/jb/usr/share/iagent/web/...` | `$JBROOT/usr/share/iagent/web/...` |
| `layout/Library/LaunchDaemons/com.dsh.iagent.daemon.plist` | `/var/jb/Library/LaunchDaemons/...plist` | 同左 | 需另做 roothide 版 plist |
| `layout/Library/MobileSubstrate/DynamicLibraries/iagent.dylib` | `/var/jb/Library/MobileSubstrate/DynamicLibraries/...` | 同左（ElleKit 的 TweakInject 软链） | ❓（RootHide 用 `usr/lib/DynamicPatches`） |
| `layout/DEBIAN/control`、`postinst` | `DEBIAN/control`、`DEBIAN/postinst` | 安装器脚本，**不加前缀** | 同 |

⚠️ 常见坑：**不要在 `layout/` 里自己写 `var/jb/...`**，否则会变成 `/var/jb/var/jb/...`（因为 scheme 会再加一次前缀）。

### 6.3 control / postinst / ldid ✅❓

- ✅ `Architecture:` 不要手写死（会被 scheme 覆盖），`Depends:` 建议 `mobilesubstrate`（ElleKit Provides，§3.1）或更精确的 `ellekit`；`Pre-Depends: firmware (>= 15.0)` 是 rootless 生态惯例（RootHide 自己的 control 就是这么写的：`Depends: firmware (>= 15.0)`）。
- ✅ **Theos 不会改写你的 `postinst`/`prerm`**：`layout/DEBIAN/*` 是 `rsync` 原样拷进 `DEBIAN/`。所以 rootless 包里的脚本必须**自己**处理前缀（写 `/var/jb/...`，或用变量探测）。可用的探测片段（建议，非上游原文）：
  ```sh
  #!/bin/sh
  if [ -d /var/jb ]; then JB=/var/jb; else JB="$(jbroot / 2>/dev/null)"; fi
  [ -n "$JB" ] || exit 0
  launchctl bootstrap system "$JB/Library/LaunchDaemons" 2>/dev/null || true
  ```
  （RootHide 上 `jbroot` CLI 由 roothide 提供 ✅；Dopamine 上走 `/var/jb` 分支 ✅。）
- ✅ **签名**：Theos 在 macOS 上默认用 `ldid`（`TARGET_CODESIGN = ldid`、`TARGET_CODESIGN_FLAGS ?= -S`，见 `makefiles/targets/_common/darwin_head.mk`）。daemon 若要 `platform-application` / no-sandbox 等 entitlements，用 `<instance>_CODESIGN_FLAGS = -S<entitlements.plist>`；RootHide 需要的基础 entitlements 清单见 §2.4。tweak dylib 一般 ad-hoc 即可。❓ 具体哪些 entitlement 在 iOS 15+ 上仍被允许（无 TFP0 场景）需真机实测。
- ✅ `TOOL_NAME` 的安装：`makefiles/instance/tool.mk` → `LOCAL_INSTALL_PATH` 默认 `/usr/bin`（可用 `<name>_INSTALL_PATH` 覆盖，如 `/usr/libexec`），staging 用 `cp`（不 chmod；链接器产物本身 0755，所以 deb 里是可执行的）。

### 6.4 父代理的四问：Theos 会不会自动链 substrate？

**(1) `TWEAK_NAME` 项目会自动加 `-lsubstrate` 吗？dylib 里会有 substrate 的 `LC_LOAD_DYLIB` 吗？**

- ✅ **Makefile 层面不会**：全量检索 `theos/makefiles/**` 与 `theos/vendor/mod/**`，**没有任何 `-lsubstrate`**；`rules.mk` 只做两件事：把 `<TYPE>_LIBRARIES` 展开成 `-l<name>`（L107），以及给 iphone 目标加 `-lroot`（L141，roothide scheme 除外）。`darwin_tail.mk` 也**没有** `-undefined dynamic_lookup`。
- ✅ **依赖是从编译期进来的**：Logos 默认生成器是 `MobileSubstrate`（`theos/makefiles/instance/tweak.mk` 的 `_LOCAL_LOGOS_DEFAULT_GENERATOR` 默认值），生成代码里 `#include <substrate.h>` + `MSHookMessageEx/MSHookFunction`（`logos/bin/lib/Logos/Generator/MobileSubstrate/*.pm`）；而 `theos/headers`（= `$THEOS/vendor/include`）里 `substrate.h` → `CydiaSubstrate.h` → `#include <CydiaSubstrate/CydiaSubstrate.h>`，最终落到 `$THEOS/vendor/lib/.../CydiaSubstrate.framework/Headers/CydiaSubstrate.h`（声明是**普通 extern，没有 weak_import**）。
- 🟡 **因此（高置信推断）**：开着 clang modules（Theos 默认 `-fmodules`，`rules.mk` 里 `_LOCAL_USE_MODULES` 默认真）时，clang 会用 framework 的 `module.modulemap` 把 `CydiaSubstrate` 作为模块导入并**自动链接该 framework**，于是链接线上出现 `-framework CydiaSubstrate`；ld 读 `$THEOS/vendor/lib/iphone/rootless/CydiaSubstrate.framework/CydiaSubstrate.tbd`，把 install_name 原样写进 Mach-O。**这个 install_name 是关键**（见下）：
  - rootless：`install-name: '@rpath/CydiaSubstrate.framework/CydiaSubstrate'`（`theos/lib/iphone/rootless/CydiaSubstrate.framework/CydiaSubstrate.tbd`）
  - rootful：`install-name: '/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate'`（`theos/lib/CydiaSubstrate.framework/CydiaSubstrate.tbd`）
  - 旁证：Dopamine 自带 ElleKit 的 tbd 也是 `@rpath/CydiaSubstrate.framework/CydiaSubstrate`，ElleKit 则在 `/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate` 建软链 —— 两边 install_name 精确对上，说明这就是生态里实际出现的加载命令形态。
- ⚠️ **本次无法在本机证伪/证实到底层**（环境无 clang/otool/macOS）。**请按 §10 第 1 条真机或 CI 跑一次 `otool -L` 一锤定音**；若结果里**没有** substrate，则说明自动链接没发生（那意味着必须显式 `TWEAK_LIBRARIES = substrate`），此时按下面 (2) 的方式显式声明即可。

**(2) 完全不用 Logos/`%hook`（只 `__attribute__((constructor))` + `dlopen/dlsym`）能不能彻底去掉 substrate？**

- ✅ **能**。没有任何 `#include <substrate.h>`、没有 Logos 生成代码，就没有对 `MSHookMessageEx` 的引用，也没有模块被导入 → 不会有 substrate 相关的加载命令（Theos 自己不添加）。`TWEAK_NAME`/`TOOL_NAME` 只是"产物类型"，不隐含库依赖。
- 想要**双保险**（例如你的文件里可能间接 include 了别人带 substrate 的头）：
  - 保持 source 只 include 系统头 + 你自己的头；
  - 如果确实要用 Logos 语法但不想引 substrate，把生成器换掉：`logos.pl` 支持 `-c generator=[internal|libhooker|MobileSubstrate]`（`logos/bin/logos.pl:33,43`；生成器目录 `logos/bin/lib/Logos/Generator/{Base,internal,libhooker,MobileSubstrate}`）→ 在 Makefile 里：
    ```make
    iagent_LOGOSFLAGS = -c generator=internal
    ```
    `internal` 用 Objective-C runtime 自己实现 hook，**不包含 substrate.h** ✅（生成器存在且有独立实现；具体产出代码请以首次构建产物核对 🟡）。
  - 若要**禁止**任何模块自动链接：`<instance>_USE_MODULES = 0`（`theos/makefiles/instance/rules.mk:192` 的 `_LOCAL_USE_MODULES`）。注意：一旦关掉 modules，roothide API 就必须手加 `-lroothide`（见 §2.2 官方告警），substrate 若需要也同理手加。
  - 显式"零依赖"的写法（不是必须，但语义清晰）：`iagent_LIBRARIES =`（留空）——不要写 `substrate`。

**(3) `/var/jb/usr/lib/libsubstrate.dylib` 在 RootHide / Dopamine 上存在吗？带了 substrate 依赖的 dylib 会加载失败吗？**

- ✅ **Dopamine：存在**。ElleKit 的 rootless 安装（`INSTALL_PREFIX=/var/jb`）创建 `/var/jb/usr/lib/libsubstrate.dylib`（→ `libellekit.dylib`）以及 `/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate`。因此 `@rpath/CydiaSubstrate.framework/CydiaSubstrate` 经 rpath `/var/jb/Library/Frameworks` 命中 ✅。
- ✅ **RootHide：不是 `/var/jb`，而是 `$JBROOT/usr/lib/libsubstrate.dylib`**，官方给出的链接写法就是 `@loader_path/.jbroot/usr/lib/libsubstrate.dylib`（roothide.md 原文示例）。RootHide 上**没有 `/var/jb`**。
- ✅ **会失败的情形**：dylib 的加载命令是绝对 `/var/jb/...`（rootless v1 风格）→ 在 RootHide 上 dyld 找不到文件 → 该 tweak/dylib 加载失败（`dyld: Library not loaded`）。反之，`@rpath/...`（rootless v2）或 `@loader_path/.jbroot/...`（roothide）两边都能活。
- 🟡 推论（对 iAgent 直接有用）：**不要**用 `-lsubstrate` 之外的绝对路径 `/var/jb/...` 手工 `dlopen` 任何库；如果确实要 `dlopen` substrate，请按平台拼路径：
  ```
  Dopamine  : /var/jb/usr/lib/libsubstrate.dylib
  RootHide  : jbroot("/usr/lib/libsubstrate.dylib")
  ```
  更稳的做法：只用 `dlopen("libsubstrate.dylib")` 之类的**语义名**（走 dyld 搜索路径 + 已加载镜像），或者干脆不依赖 substrate（(2) 的方案）。

**(4) `layout/` 在 rootless 下的确切语义？** → 见 §6.2 表（`layout/usr/share/foo` → `/var/jb/usr/share/foo`；`layout/Library/LaunchDaemons/x.plist` → `/var/jb/Library/LaunchDaemons/x.plist`；`layout/DEBIAN/*` → 包内 `DEBIAN/*`）。

---

## 7. GitHub Actions 云编译（Theos）

### 7.1 runner 选择 ✅

`actions/runner-images` README 现役标签（本次读取的原文）：

| 标签 | 架构 |
|---|---|
| `macos-latest` / `macos-26` / `macos-26-xlarge` | **arm64** |
| `macos-latest-large` / `macos-26-intel` / `macos-26-large` | x64 |
| `macos-15` | **arm64** |
| `macos-15-intel`(及 `macos-15-large`) | x64 |
| `macos-13` | 已下架（不要再用） |

结论：用 `runs-on: macos-15`（arm64，Xcode 完整安装，含 ld64 → arm64e 新 ABI 没问题）。❓ xlarge 需付费计划；开源仓库可用标准 runner。

### 7.2 在 runner 上装 Theos ✅

Theos 官方安装（macOS 与 Linux/WSL 同一条命令，无需 root；macOS 上必须装**完整 Xcode**，只装 Command Line Tools 不够 —— 见 https://theos.dev/docs/installation-macos ）：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
```

装完的路径是 `~/theos`；CI 里建议 `echo "THEOS=$HOME/theos" >> "$GITHUB_ENV"` 并 `echo "$HOME/theos/bin" >> "$GITHUB_PATH"`。

❓ Linux runner 是否可用于本项目的 arm64e：Theos 文档说 Linux 支持 iOS target ✅，但 arm64e 新 ABI 依赖新 ld64 工具链；本项目按 parent 的要求以 macOS runner 为准（更稳），Linux 只作为"可选备选"。

### 7.3 推荐的 workflow（**建议模板**，非官方原文）

```yaml
name: build
on:
  push:
    tags: ["v*"]
  workflow_dispatch:
jobs:
  deb:
    runs-on: macos-15                 # arm64，见 §7.1
    env:
      THEOS: ${{ github.workspace }}/theos
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }   # 若使用 roothide/theos 或自带 theos 子模块
      - name: Cache Theos
        uses: actions/cache@v4
        with:
          path: theos
          key: theos-${{ runner.os }}-${{ hashFiles('theos-version.txt') }}
      - name: Install Theos
        run: |
          [ -d "$THEOS" ] || bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
          echo "$THEOS/bin" >> "$GITHUB_PATH"
      - name: Build package
        run: make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
      - name: Collect
        run: |
          mkdir -p out
          cp packages/*.deb out/
      - uses: actions/upload-artifact@v4
        with: { name: iagent-deb, path: out/*.deb }
      - name: Release
        if: startsWith(github.ref, 'refs/tags/')
        env: { GH_TOKEN: ${{ secrets.GITHUB_TOKEN }} }
        run: gh release create "$GITHUB_REF_NAME" out/*.deb --generate-notes
```

说明：用 `gh release create`（runner 预装 `gh`，`GITHUB_TOKEN` 自带）而不是第三方 release action，可以避免额外依赖 🟡（`gh` 存在于官方 runner 镜像是常识，本次未逐条验证镜像清单）。

若要走 roothide 线，把 Theos 换成 roothide/theos（`git clone --recursive https://github.com/roothide/theos.git "$THEOS"`，注意 `--recursive` 才会拉 `vendor/include`（roothide/headers）与 `vendor/lib`（roothide/lib），否则 `#include <roothide.h>` 会找不到）并 `THEOS_PACKAGE_SCHEME=roothide` ✅（`.gitmodules` 证据）。

---

## 8. 一个 Theos 项目同时产出 tweak + 常驻工具

- ✅ 顶层 Makefile 形状（同一个 `common.mk`，两个 target 段）：
  ```make
  TARGET = iphone:clang:latest:15.0
  ARCHS  = arm64 arm64e
  THEOS_PACKAGE_SCHEME = rootless
  INSTALL_TARGET_PROCESSES = SpringBoard
  include $(THEOS)/makefiles/common.mk

  TWEAK_NAME = iagent
  iagent_FILES = $(wildcard daemon/*.m shared/*.m)     # 或单独的 tweak/ 目录
  iagent_FRAMEWORKS = UIKit Foundation
  # iagent_LIBRARIES =                                  # 不要写 substrate（见 §6.4(2)）

  include $(THEOS_MAKE_PATH)/tweak.mk

  TOOL_NAME = iagentd
  iagentd_FILES = $(wildcard daemon/*.m shared/*.m)
  iagentd_FRAMEWORKS = Foundation UIKit
  iagentd_INSTALL_PATH = /usr/bin                       # 默认值，rootless 下即 /var/jb/usr/bin

  include $(THEOS_MAKE_PATH)/tool.mk
  ```
- ✅ 落点：tweak → `/var/jb/Library/MobileSubstrate/DynamicLibraries/iagent.dylib`；工具 → `/var/jb/usr/bin/iagentd`；web 资源 → `/var/jb/usr/share/iagent/web/`（与现有 `layout/usr/share/iagent/web/` 完全对应）。
- ✅ `INSTALL_TARGET_PROCESSES = SpringBoard` 让 Theos 在安装后自动重启目标进程（`tweak.mk` 相关规则）；daemon 不需要这条，daemon 由 plist + `launchctl bootstrap` 生效。
- 坑（按已查证事实归纳）：
  1. ❌ 工具名与 tweak 名重名会撞 staging 路径（都用 `$(THEOS_OBJ_DIR)/<name>`）。
  2. ❌ daemon 里别去 `dlopen` 一个装在 `/var/jb/...` 的绝对路径 —— RootHide 上不存在（§3.1 第 3 点）。
  3. ❌ 别把 daemon 或 dylib 放进 `$JBROOT/var/` 或 `$JBROOT/tmp/`（RootHide 上不可加载，§2.4）。
  4. ⚠️ RootHide 下 tweak 想写文件只能在 `$JBROOT/var/`（其它目录可能被拒），而当前项目设计把数据放 rootfs `/var/mobile/Library/iAgent` —— **这条必须在真机复核**（§2.4/§9）。
  5. ⚠️ plist 内容两边不同（Dopamine 绝对 `/var/jb`，RootHide jbroot 逻辑路径或 `@JBROOT@`），见 §4.2。
  6. ⚠️ `postinst` 里 `uicache`/`launchctl` 要用带前缀的绝对路径或 `PATH` 里的 bootstrap 工具（§6.3）。

---

## 9. 对 iAgent 的落地建议（明确标注为"建议"）

1. **源码路径抽象已就绪**：项目里 `shared/IAGPaths.{h,m}` 的 `IAGJailbreakRoot()` / `IAGResolveRootlessPath()` 设计思路与本次查证一致（不信任编译期前缀、运行期探测）。RootHide 侧建议优先用 `jbroot()`（编译期 `#include <roothide.h>`，rootless/rootful 自动变 stub），失败再退化到 `/var/jb`。
2. **构建矩阵**：rootless（`iphoneos-arm64`，Dopamine/大多数 rootless）+ roothide（`iphoneos-arm64e`，RootHide）。两者共用同一份 `daemon/`、`shared/`、`layout/`，只在 scheme 与 plist/control 上分叉。
3. **数据目录**：RootHide 官方建议 `$JBROOT/var/`，rootfs 共享放在 `/var/mobile/Library/iAgent` 更符合"跨越狱重启保留 + root/mobile 共享"。两者取舍需真机验证写入权限（§2.4 的两条限制是硬事实，务必先测）。
4. **不依赖 substrate**：本项目 tweak 只做 SpringBoard 侧通知/面板，若不需要 hook ObjC 方法，就按 §6.4(2) 保持零 substrate 依赖，可同时降低 Dopamine/RootHide 的兼容风险。
5. **daemon 启动**：优先用 plist + 平台对应的载入命令（Dopamine：`/var/jb/usr/bin/launchctl bootstrap system /var/jb/Library/LaunchDaemons`；RootHide：遵循 §4.2，先在真机确认第三方 plist 的载入路径与是否可用 `@JBROOT@`）。

---

## 10. 交付前必须做的真机/CI 验证清单

| # | 命令 | 要确认什么 |
|---|---|---|
| 1 | `otool -L packages/.../iagent.dylib`（或 `.build/iagent.dylib`） | 是否出现 substrate 依赖；install_name 是 `@rpath/...` 还是 `/var/jb/...`；有无硬编码 `/var/jb` 绝对加载命令 |
| 2 | `otool -l iagentd \| grep -A2 LC_RPATH` | 是否有 `@loader_path/.jbroot/usr/lib`（rootless v2 双 rpath 是否生效） |
| 3 | `dpkg-deb -c packages/*.deb` | 包内路径是否为 `/var/jb/...`；`DEBIAN/` 是否未被加前缀 |
| 4 | Dopamine：`launchctl print system/com.dsh.iagent.daemon` | plist 是否被载入、uid、是否 root |
| 5 | RootHide：`$JBROOT/basebin/bsctl check`、`ls $JBROOT/Library/LaunchDaemons`、`launchctl print system/com.dsh.iagent.daemon` | 第三方 daemon plist 是否被载入（❓ 项） |
| 6 | RootHide：`jbroot /`、`rootfs <真实路径>`、`jbrand` | API/CLI 方向语义（§2.2） |
| 7 | RootHide：`dpkg -i --dry-run` 装 rootless（`iphoneos-arm64`）包 | 架构是否被接受（❓ 项） |
| 8 | RootHide：tweak 写 `/var/mobile/Library/iAgent` | 沙盒是否拦截（§2.4 限制对本项目的影响） |

---

## 11. 明确的"未查证"清单（不要当成事实）

1. ❓ clang 自动链接 substrate 的**机制层**证据（本环境无 clang/otool）；结论以 §10-1 的 `otool -L` 为准。
2. ❓ RootHide 的 dpkg/Sileo 是否接受 `Architecture: iphoneos-arm64`。
3. ❓ RootHide 上第三方 deb 的 `$JBROOT/Library/LaunchDaemons/*.plist` 由谁载入、是否支持 `@JBROOT@` 占位符自动替换。
4. ❓ LaunchDaemon `UserName: mobile` 在 RootHide/Dopamine 的实际行为。
5. ❓ RootHide 的注入器身份（ElleKit fork vs 其它）——`strapfiles/bootstrap-1900.tar.zst` 未展开。
6. ❓ `firmware` 虚拟包在 Dopamine 上的提供者（Dopamine 仓库 `Packages/` 内没有相关 control）。
7. ❓ Dopamine 是否自带 Sileo/PreferenceLoader（不在 Dopamine 仓库内）。
8. ❓ Linux runner 构建 arm64e 新 ABI 的可行性（仅 macOS runner 已确认为稳）。

---

## 12. 出处索引

- Theos 本体（HEAD `dd5c14b`）：`makefiles/instance/tweak.mk`、`makefiles/instance/tool.mk`、`makefiles/instance/rules.mk`（L107 `-l$(library)`、L141 `-lroot`、L144 `-D THEOS_PACKAGE_INSTALL_PREFIX`、L192 `_LOCAL_USE_MODULES`、L212 `ALL_LDFLAGS`、L469/L522 链接规则）、`makefiles/stage.mk`、`makefiles/package/deb.mk`、`makefiles/targets/_common/darwin_head.mk`（`TARGET_CODESIGN = ldid`）、`makefiles/targets/_common/darwin_tail.mk`（无 `-undefined dynamic_lookup`）、`vendor/mod/rootless/*`（5 个文件）
- Theos lib（HEAD `6f2af30`）：`CydiaSubstrate.framework/CydiaSubstrate.tbd`、`CydiaSubstrate.framework/Headers/CydiaSubstrate.h`、`CydiaSubstrate.framework/Modules/module.modulemap`、`iphone/rootless/CydiaSubstrate.framework/CydiaSubstrate.tbd`、`iphone/rootless/libhooker.tbd`、`README.md`
- Logos（HEAD `777925d`）：`bin/logos.pl:33,43`、`bin/lib/Logos/Generator/{Base,internal,libhooker,MobileSubstrate}/`
- roothide/theos（HEAD `88506b2`）：`.gitmodules`、`vendor/mod/roothide/{package.mk,instance/rules.mk,instance/library.mk,instance/framework.mk,package/deb.mk}`、`makefiles/instance/rules.mk:141`
- roothide/libroothide（HEAD `7764c54`）：`roothide.h`、`module.modulemap`、`common.h`、`init.c`、`updatelink.c`、`updatelinks.sh`、`symredirect.cpp`
- roothide/Bootstrap（HEAD `428a8c2`）：`Bootstrap/utils.m`（`find_jbroot`、`is_jbroot_name`、`jbrand_new`）、`Bootstrap/bootstrap.m`（`rebuildBasebin`、`@JBROOT@`/`@JBRAND@`、`bootstrapd`、`bsctl`、`updatelinks.sh`、`fixBadPatchFiles`）、`Bootstrap/ViewController.m`（`launchctl_support`、`bsctl` 用法）、`Makefile`、`control`
- roothide/Developer 文档：https://github.com/roothide/Developer/blob/main/roothide.md | `interface.md` | `vroot.md` | `filemirror.md` | `entitlements.md`
- roothide/headers：`roothide.h`（shim，原文见 §2.2）
- Dopamine（HEAD `1a54e76`）：`BaseBin/launchdhook/src/daemon_hook.m`、`BaseBin/dopamine/src/main.m`（`launchctl bootstrap system /var/jb/Library/LaunchDaemons`）、`BaseBin/_external/lib/libellekit.tbd`、`Packages/{basebin-link,libkrw-provider,libroot}/`、`Packages/libroot/Makefile`
- ElleKit（HEAD `1017a0d`）：`Makefile`（软链与 `INSTALL_PREFIX`）、`packaging/control`（`Provides: mobilesubstrate (= 99)`）
- GitHub runner 规格：https://github.com/actions/runner-images/blob/main/README.md
- Theos 文档：https://theos.dev/docs/rootless | https://theos.dev/docs/packaging | https://theos.dev/docs/modules | https://theos.dev/docs/installation-macos | https://theos.dev/docs/installation-linux | https://theos.dev/docs/arm64e-deployment
