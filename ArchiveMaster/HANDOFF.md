# 交接说明：解压大师（ArchiveMaster）

这份文档写给接手的开发者（例如 Mac 上的 Claude Code）。项目此前一直在 **Linux** 上开发：用 clang/lld 和 iOS 16.5 SDK 头文件交叉编译，**从未在真机或模拟器上运行过**。在 Mac 上用 Xcode 构建并调试，是定位问题最快的办法。

## 1. 当前状态

- 版本 1.3.1（build 5），Objective-C + UIKit，最低 iOS 15.0，iPhone/iPad 通用。
- 用户设备：**iPhone Duo（折叠屏），iOS 27.2**。
- **未解决：App 在用户设备上闪退**，没有任何崩溃日志或报告。
  - v1.1（`git 2922a8a`）能在设备上运行（用户有截图），但在 iPhone Duo 内屏上以兼容模式小窗口显示。
  - v1.2（`2b43183`）起，链接的 SDK 版本被标记为 27.1，用来全屏显示。用户没有单独反馈过 v1.2。
  - v1.3.0（`afb9634`）和 v1.3.1（`68eee13`）：用户反馈闪退。1.3.1 已修复两处确定的问题（见第 4 节），但用户反馈仍然闪退。

## 2. 在 Mac 上构建（推荐）

```bash
cd ArchiveMaster
brew install xcodegen
scripts/vendor_thirdparty.sh   # 生成 ThirdParty/（打包给你的 zip 里已经带好，可跳过）
xcodegen                       # 根据 project.yml 生成 ArchiveMaster.xcodeproj
open ArchiveMaster.xcodeproj
```

- **Scheme**：选 `ArchiveMaster`；设备选 iPhone Duo 模拟器（Xcode 27.1+ 的 Device Hub）或真机。
- **签名**：在 Signing & Capabilities 里选自己的 Team。
- **第三方库**：libarchive 3.8.1、zstd 1.5.7、lz4 1.10.0、xz/liblzma 5.8.1，以源码形式编成 4 个静态库 target（`archive`、`zstd`、`lz4`、`lzma`）。
  - 文件清单就是 Linux 上成功编译的那些文件。
  - `config.h` 在 `Xcode/ThirdPartyConfig/`，是为 iOS arm64 生成的，所以模拟器只编 arm64（Apple 芯片 Mac）。
- **Info.plist**：Xcode 用 `Xcode/Info.plist`，DT* 键由 Xcode 自动写入；`Resources/Info.plist` 只给 Linux 构建用。
- **不参与编译的文件**：`Sources/AMCompat.m` 只在 Linux 工具链下需要，已在 project.yml 里排除。
- **已验证的部分**：在 Linux 上按 project.yml 里各 target 的参数编译了全部 240 个第三方 .c 文件，并和 App 链接成功，没有未定义符号。xcodegen 和 xcodebuild 本身**没有**运行过。

## 3. 首要任务：定位闪退

1. **先看崩溃栈**。用 Xcode 在 iPhone Duo 模拟器或真机上运行（Debug），直接看崩溃位置；同时测展开和折叠两种状态。
2. **取设备日志**：
   - Xcode › Window › Devices and Simulators › 设备 › View Device Logs；
   - 或者让用户在 设置 › 隐私与安全性 › 分析与改进 › 分析数据 里找 `ArchiveMaster-*.ips`。
3. **App 内置崩溃报告**（`AMCrashReporter`）：会把 Objective-C 异常和致命信号写到 `Library/LastCrash-*.txt`，下次启动时弹窗提供分享。
   - 用户没有收到过这个弹窗，有两种可能：崩溃发生在报告器安装之前（dyld 阶段或 UIApplicationMain 早期）；或者每次都在 0.4 秒内崩溃，弹窗还没来得及出现。
4. **对比包**：`dist/ArchiveMaster-diag-sdk16.ipa` 和 1.3.1 代码完全相同，只是没有把 SDK 版本标成 27.1。
   - 如果它不闪退，问题就在下面第 ① 条。

### 可疑点（按可能性排序）

1. **SDK 版本是"标记"上去的。**
   - **做法**：`scripts/build_app.sh` 用 `-Wl,-platform_version,ios,15.0,27.1` 把 LC_BUILD_VERSION 写成 27.1，Info.plist 的 `DTSDKName` 也写成 `iphoneos27.1`；但头文件和 .tbd 实际是 iOS 16.5。
   - **后果**：UIKit 会按"链接于 27.1"的行为运行。
   - **处理**：用 Xcode 的真实 SDK 构建就能排除这一项。
2. **Files 标签用了 UISplitViewController。**
   - **位置**：`AMFilesSplitViewController`，作为 `UITabBarController` 的子控制器；`AMAppDelegate.m` 里它和 `filesNav` **共用同一个 `tabBarItem` 对象**。
   - **担心**：iOS 18+ 的标签栏可能不接受这种用法。
3. **iOS 26 新接口是在运行时动态调用的**（`AMUI.m`）。
   - **涉及**：`UIGlassEffect effectWithStyle:`、`prominentGlassButtonConfiguration`、`glassButtonConfiguration`、`tabBarMinimizeBehavior`（KVC 赋值 2）、`navigationItem.subtitle`（KVC）。
   - **现状**：调用前用 `respondsToSelector` 判断并加了 `@try`，但信号级崩溃挡不住，而且选择器名和枚举值都是推测的。
   - **处理**：有了真实 SDK 后，应改为直接调用正式 API。
4. **保存位置的安全书签**（`AMStorage`）。
   - 首次启动时还没有保存位置；1.3.1 已修复因此产生的 nil URL 崩溃（`AMAppDelegate -removeLeftovers`）。
   - 仍需检查：书签解析失败或文件夹被删除时的路径。
5. **启动阶段的其他代码**：`AMCrashReporter install`（sigaction）、`am_init`（setlocale）、后台清理 `tmp/`，以及 `AMSceneDelegate` 里创建 4 个标签页和分栏控制器的过程。

## 4. 已修复的问题（1.3.1）

- **首次启动崩溃**：还没选保存位置时，启动清理把 nil URL 传给了 `NSFileManager`，而且是在后台线程。
- **打开"相册""设置"标签后卡死，被看门狗杀掉**：`+[AMUI applyReadableMarginsToTableView:]` 拿 getter 返回的"实际边距"做比较，而它包含安全区（iPhone Duo 两侧不对称），导致每次布局都重新设置，无限循环。现在改为和上次设置的值比较。
- **ZipCrypto 密码误报**：错误密码约有 1/256 的概率会被当成"压缩包损坏"，已修复，并加了 1000 次的回归测试。

## 5. 用户提出的全部需求（务必保留）

1. 支持绝大多数压缩格式的解压与压缩，并做成 IPA。
2. 遵循 iPhone Duo / iOS 最新设计规范（Liquid Glass）；在 iPhone Duo 内屏**全屏**显示，展开时多栏、折叠时单栏。
3. 界面简体中文（另附英文）。
4. **App 内不保存任何解压或压缩产生的文件**：结果存到用户选择的"保存位置"（App 外的文件夹），或存回相册、直接分享。
5. 压缩格式至少包括 ZIP、7Z、**RAR** 等常用格式。
   - RAR 目前生成标准 RAR5 容器，用"存储"方式（不压缩），因为 RAR 压缩算法是 RARLAB 专有的。
6. 相册图片压缩，可以牺牲分辨率和细节：
   - 按比例压缩，或按单张不超过多大压缩（滑块）；
   - 单张或多张都能处理，处理完直接存回相册。
7. 把多张图片打包时可以设置**目标压缩包大小**（滑块）。
8. **可以生成多个压缩包，并选择个数**：分卷（.001…），或多个独立压缩包。
9. 解压分卷压缩包：`.7z.1`/`.7z.001`、`.part1.rar`、`.rar`+`.r00`、`.z01`+`.zip`。
10. 修复导入 30 张以上照片后变慢的问题（已改为并发加载，并直接移动临时文件）。
11. 其他已做的功能：
    - 密码本；
    - 不解压整包、只预览其中一个文件；只解压选中的条目；
    - 移动到…、解压到…、简介；
    - 批量解压；
    - 切到后台后继续运行一段时间，处理期间屏幕不自动锁定；
    - 视频压缩。

## 6. 代码结构

| 文件 | 作用 |
| --- | --- |
| `Sources/AMArchiveCore.[ch]` | 纯 C 的压缩/解压引擎：基于 libarchive 解压、列目录、压缩；分卷；多密码；按条目过滤；GBK 文件名识别；路径安全；RAR5 写入；文件切分 |
| `Sources/AMArchiver.[hm]` | Objective-C 封装：后台队列、进度、智能解压、生成多个压缩包、分卷识别 |
| `Sources/AMActions.[hm]` | 界面流程：进度卡片、密码输入、批量解压、相册导入 |
| `Sources/AMStorage.[hm]` | 保存位置（安全书签）、系统文件和文件夹选择器 |
| `Sources/AMMediaCompressor.[hm]` | 图片按字节预算压缩（ImageIO，先降画质再降分辨率）、视频转码（AVFoundation） |
| `Sources/AMFileBrowserViewController` | "文件"标签 |
| `Sources/AMFilesSplitViewController` | "文件"标签的分栏容器 |
| `Sources/AMPhotosViewController` | "相册"标签 |
| `Sources/AMSettingsViewController` | "设置"、密码本、支持格式、开源许可 |
| `Sources/AMCompressViewController` | 压缩选项表单 |
| `Sources/AMArchiveContentsViewController` | 压缩包内容 |
| `Sources/AMFolderPickerViewController` | 文件夹选择器、简介 |
| `Sources/AMProgressController`、`AMQuickLook`、`AMUI` | 进度卡片、快速查看、表单行组件和 Liquid Glass 辅助函数 |
| `Sources/AMCrashReporter` | 崩溃报告 |
| `Sources/AMCompat.m` | Linux 专用的 `__isPlatformVersionAtLeast` 实现 |
| `Resources/` | Info.plist（Linux 用）、`en.lproj/Localizable.strings`（键是中文原文）、`*/InfoPlist.strings`、`Assets.xcassets` |
| `tests/` | C 引擎的测试，在电脑上运行：`LIBARCHIVE_PREFIX=… LIBARCHIVE_SRC=… tests/run_host_tests.sh`；在 macOS 上需要按 Homebrew 的 libarchive 调整链接参数 |
| `scripts/` | Linux 构建（`build_deps.sh`、`build_app.sh`）、`vendor_thirdparty.sh`、本地化检查 `l10n_check.py`、图标生成 |

**本地化**：界面字符串一律写成 `L(@"中文原文")`。新增字符串后运行 `python3 scripts/l10n_check.py check Resources/en.lproj/Localizable.strings Sources/*.m`，把缺少的英文补上。

## 7. 建议的后续工作

1. 用 Xcode 和真实 iOS 27.x SDK 构建，找到闪退原因并修复。
2. 把 `AMUI.m` 里的 iOS 26 运行时调用改成正式 API；考虑用 `UITab` API 和 sidebar 适配大屏；按 iPhone Duo 的新接口（如 `UIViewReservedRegion`）检查折叠区域。
3. 在 iPhone Duo 的各种形态下测试：展开、折叠、分屏、横竖屏。
4. 真机走一遍所有流程：
   - 选择保存位置；
   - 打开压缩包、解压（包括带密码的和分卷的）；
   - 压缩（每种格式、分卷、多个独立压缩包、RAR）；
   - 相册：压缩后存回相册、删除原图、目标大小打包、视频压缩；
   - 从其他 App 分享文件进来。
