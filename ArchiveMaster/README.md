# 解压大师（ArchiveMaster）

一个 iOS 压缩 / 解压工具，界面按照 Apple《人机界面指南》（HIG）设计：标签栏导航、大标题、系统字体与颜色（支持深色模式和动态字体）、SF Symbols 图标、上下文菜单、滑动操作和表单式选项页。

**安装包：[`dist/ArchiveMaster.ipa`](dist/ArchiveMaster.ipa)**（arm64，iOS 15.0 及以上，iPhone / iPad 通用）

## 功能

**iPhone Duo 与 iOS 26 设计**：App 以 iOS 27.1 SDK 版本链接，在 iPhone Duo 展开的内屏上全屏显示（不再是居中的小窗口和黑边）；展开时“文件”页变为左右两栏（左侧文件列表，右侧预览或压缩包内容），合上后自动回到单栏。在 iOS 26 及以上使用 Liquid Glass 设计：玻璃质感的标签栏（滚动时自动收起）、导航栏、进度卡片、提示条和按钮；表单页在宽屏上保持合适的阅读宽度。iOS 15–25 上自动使用对应的旧样式。

**界面语言**：简体中文（默认），另附英文。系统弹出的选择器、分享面板等也会跟随显示中文；可以在系统“设置 › 解压大师 › 语言”中切换。

| 页面 | 功能 |
| --- | --- |
| 文件 | 浏览 App 内的文件；从“文件”App 导入文件或整个文件夹，从相册导入原图/视频；新建文件夹、重命名、复制、**移动到…**、删除、分享、存储到“文件”、**简介**（大小、尺寸、拍摄信息、压缩包内容等）；多选后批量压缩、**批量解压**、移动；轻点压缩包可解压到此处、**解压到其他文件夹**或查看内容；其他文件用“快速查看”预览；缩略图、搜索、排序 |
| 压缩包内容 | 不解压就能看到里面的文件；**轻点单个文件直接预览**（只解出这一个文件）；**多选后只解压所选项** |
| 相册 | 选择一张或多张照片/视频后：<br>**压缩图片**：按比例（压缩到原来的 5%–90%，滑块）或按单张大小（每张不超过 30 KB–10 MB，滑块），可限制最长边、选 JPEG/HEIC、移除位置信息；**直接存回相册**（保留原拍摄时间，可选“删除原图”，原图进入“最近删除”可恢复），也可存到“文件”页面或打成 ZIP；可先**预览压缩效果**并与原图左右滑动对比；视频可压缩为 1080p / 720p / 540p。<br>**打包成压缩包**：可开启“限制压缩包大小”，用**滑块设置目标大小**（另有 25 MB 邮件附件等常用值），照片会按比例压缩以满足目标 |
| 设置 | 默认格式与压缩级别、智能解压、解压后删除压缩包、文件名编码（自动识别 / GBK / Big5 / Shift_JIS / EUC-KR）、**密码本**、语言、存储占用与缓存清理、支持格式列表、开源许可 |

其他细节：
- **密码本**：保存常用解压密码（存于本机钥匙串），遇到加密压缩包自动逐个尝试；输入新密码时可选“确定并存入密码本”。
- 在微信、Safari、“文件”等 App 中把压缩包“用其他应用打开 / 分享”到“解压大师”，会自动导入并询问是否解压。
- 文件保存在本机，可在“文件”App 的“我的 iPhone › 解压大师”中直接访问。
- 解压时自动识别 Windows 中文系统打包的 GBK 文件名，避免乱码；自动跳过 `__MACOSX`、`.DS_Store`。
- 解压、压缩、照片处理都有进度条，可随时取消；切到后台时会申请额外运行时间，处理期间不会自动锁屏；中途取消或失败不会留下半成品。

## 支持的格式

| | 格式 |
| --- | --- |
| 压缩 + 解压 | ZIP（含 AES-256 / ZipCrypto 密码）、7Z、TAR、TAR.GZ/TGZ、TAR.BZ2、TAR.XZ、TAR.ZST、TAR.LZ4、ISO、CPIO；单文件 GZ、BZ2、XZ、ZST、LZ4 |
| 仅解压 | RAR（RAR4 / RAR5、固实）、分卷（`.part1.rar`、`.r00`、`.7z.001`、`.zip.001`）、CAB、LZH/LHA、XAR/PKG、DEB、RPM、AR、APK/IPA/JAR、LZMA、LZIP、Z、UU、WARC、MTREE |

限制：**加密的 RAR、7Z 暂不能解压**（libarchive 不支持这两种加密）；7Z 不能设置密码（压缩时只有 ZIP 能加密）。

## 安装

IPA 没有用开发者证书签名（只有链接器生成的 ad-hoc 签名），需要用以下任一方式签名安装：

- **TrollStore**（系统版本支持时）：直接用 TrollStore 打开 IPA 安装。
- **AltStore / SideStore / Sideloadly**：用自己的 Apple ID 签名安装（免费账号 7 天需续签）。
- **爱思助手、轻松签、全能签**等工具：用你自己的证书签名后安装。

## 从源码构建（Linux）

不需要 Mac 或 Xcode：用 clang + lld 和 Theos 项目发布的 iOS 16.5 SDK 头文件交叉编译，链接时把 SDK 版本记录为 27.1（`LINK_SDK`，见 `scripts/build_app.sh`），这样 iPhone Duo 会全屏运行、iOS 26 会启用 Liquid Glass。iOS 26/27 的新接口（如 `UIGlassEffect`）在运行时按需调用，旧系统上自动退回原样式。

```bash
cd ArchiveMaster
./scripts/build_deps.sh   # 下载 SDK，交叉编译 libarchive 3.8.1、zstd、lz4、xz（liblzma）静态库
./scripts/build_app.sh    # 编译 App 并输出 dist/ArchiveMaster.ipa
```

需要：clang/lld（≥ 15）、make、curl、python3 + Pillow（生成图标）、zip。

### 测试

压缩/解压引擎（`Sources/AMArchiveCore.c`）是纯 C，可以在构建机上直接测试：

```bash
LIBARCHIVE_PREFIX=<本机构建的 libarchive 安装目录> LIBARCHIVE_SRC=<libarchive 源码目录> ./tests/run_host_tests.sh
```

测试覆盖：10 种打包格式和 5 种单文件格式的压缩→解压往返校验、ZIP AES-256 / ZipCrypto 的“需要密码 / 密码错误 / 密码正确”、密码本（多个候选密码）、只解压选中项、ZipCrypto 错误密码 1000 次压力测试、取消、非压缩包识别、GBK 文件名自动识别、RAR4/RAR5/7z/CAB/LZH 样本解压、RAR 分卷与 7z 拆分卷解压、加密 RAR/7z 的提示。

## 代码结构

```
Sources/
  AMArchiveCore.[ch]      libarchive 封装（纯 C）：解压/列目录/压缩、分卷、多密码、按条目过滤、编码识别、路径安全
  AMArchiver.[hm]         Objective-C 封装：后台执行、进度、智能解压、单条目预览、错误信息
  AMMediaCompressor.[hm]  图片按字节预算压缩（先降画质再降分辨率）、视频转码
  AMActions.[hm]          通用流程：进度卡片、密码本与密码输入、批量解压、相册导入
  AMPasswordBook.[hm]     密码本（钥匙串）
  AMFilesSplitViewController      “文件”页容器：宽屏两栏（列表 + 预览），窄屏单栏
  AMFileBrowserViewController     “文件”页
  AMArchiveContentsViewController 压缩包内容（预览单个文件、只解压所选）
  AMPhotosViewController          “相册”页（压缩图片 / 打包）
  AMSettingsViewController        “设置”页、密码本、支持格式、开源许可
  AMCompressViewController        压缩选项表单
  AMFolderPickerViewController    选择文件夹（移动到 / 解压到）、简介
  AMProgressController / AMQuickLook / AMUI  进度卡片、快速查看、工具方法与表单行
Resources/
  Info.plist
  en.lproj/Localizable.strings    英文文案（键为简体中文原文）
  */InfoPlist.strings             各语言的 App 名称与权限说明
scripts/                  构建脚本、图标生成、本地化检查（l10n_check.py）
tests/                    引擎测试
```

开源组件：libarchive（BSD-2）、Zstandard（BSD-3）、LZ4（BSD-2）、XZ Utils（0BSD），许可全文见 App 内“设置 › 开源组件许可”。
