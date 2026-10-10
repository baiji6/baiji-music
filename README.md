# 白姬音乐 · Baiji Music

跨平台音乐播放客户端，一套 Flutter/Dart 代码同源支持 **iOS / macOS / Windows / Linux / Android / HarmonyOS（鸿蒙）** 六端，
UI 采用暗色玻璃拟态 + 霓虹渐变的现代化未来感设计，构建期自动执行**加壳与混淆**防逆向。

> 本工程由「白姬音乐 Android 原生 v1.1.1」重构而来：C 算法库（hash33 / zzc_sign / tripledes / qrc / qimei / comm）全部移植为纯 Dart，
> 网络层支持 QQ 音乐与网易云双音源，功能模块覆盖搜索、播放、歌单、下载、扫码登录与本地音乐。

---

## 技术栈

| 层 | 技术 |
| --- | --- |
| UI / 业务 | Flutter 3.47.x + Dart 3.13.x |
| 算法层 | 纯 Dart（QQ 音乐签名 / 设备指纹 / QRC 歌词解密，与原 C 实现逐字节对照） |
| 网络层 | dio（Cookie 管理、流式下载、超时）+ QQ 音乐 / 网易云双协议 |
| 音频 | media_kit（libmpv + ffmpeg 软解，一套解码器通吃 MP3 / FLAC / M4A / OGG / WAV） |
| 存储 | shared_preferences + path_provider |
| 权限 | permission_handler（仅 Android 需要；桌面端无运行时存储权限） |
| 鸿蒙壳 | ArkTS stage 模型（API 12），方舟混淆自动生效 |

## 目录结构

```
baiji_music/
├── lib/                        # 跨平台源码（六端共享）
│   ├── main.dart               # 入口
│   ├── theme/                  # 主题：暗色玻璃拟态 + 霓虹渐变
│   ├── ui/                     # 页面：发现 / 搜索 / 我的 / 播放条 / 小组件
│   ├── crypto/                 # QQ 音乐签名算法（纯 Dart，含向量测试）
│   ├── network/                # QQ 音乐 + 网易云网络层
│   ├── data/                   # 设备指纹 / 历史 / 歌单 / 本地音乐库存储
│   ├── player/                 # 播放控制
│   ├── download/               # 音质降级下载链
│   ├── local/                  # 本地音乐扫描（Isolate + 增量指纹）
│   ├── metadata/               # 音频元数据读写（写入 / 读取）
│   └── core/                   # 日志 / KV / 封面 URL / 版本号 / 工具
├── android/                    # Android（R8 全量混淆 + 资源混淆）
├── ios/                        # iOS（Xcode Release 自动 strip 符号）
├── macos/                      # macOS（构建后 strip 符号）
├── windows/                    # Windows（构建后 UPX 加壳）
├── linux/                      # Linux（构建后 UPX 加壳）
├── ohos/                       # HarmonyOS 鸿蒙（方舟混淆自动生效）
├── scripts/protect/build_all.sh# 统一构建·加壳·混淆流水线
├── tools/upx/                  # 固化 UPX 可执行文件（无需系统安装）
└── test/                       # 算法向量对照测试（22 项全绿）
```

## 快速开始

```bash
# 安装依赖
flutter pub get

# 静态检查 / 单测
flutter analyze
flutter test

# 构建六端产物（自动加壳混淆，见下一节）
./scripts/protect/build_all.sh all
```

## 构建期自动加壳与混淆

统一入口 `scripts/protect/build_all.sh`，每个平台构建完成后**自动**执行加固，无需手工干预：

| 平台 | 混淆 / 加壳手段 | 生效时机 |
| --- | --- | --- |
| 全部平台 | Dart 层混淆 `--obfuscate --split-debug-info`（符号表与产物分离） | 每次 release 构建 |
| Android | R8 全量代码混淆 + 资源压缩 + 资源名混淆（`isShrinkResources` / `androidResources.isShrink`）+ 自定义 ProGuard 规则 | `flutter build apk --release` |
| iOS | Xcode Release 构建默认 STRIP 符号 + 脚本兜底 `xcrun strip -x` | Archive 构建 |
| macOS | 构建后对 `.app/Contents/MacOS/*` 执行 `strip -x`（等价 STRIP_INSTALLED_PRODUCT） | `build macos --release` |
| Windows | 构建后 UPX `--best` 压缩可执行文件（加固体积双重收益） | `build windows --release` |
| Linux | 构建后 UPX `--best` 压缩可执行文件 | `build linux --release` |
| HarmonyOS | 方舟编译器 Obfuscation（`obfuscation-rules.txt`：属性/顶层作用域/文件名混淆） | hvigor `release` 模式自动生效 |

```bash
# 单平台
./scripts/protect/build_all.sh android
./scripts/protect/build_all.sh ohos

# 全平台（依次构建并加固，产物输出到 build/out/，日志 build/logs/）
./scripts/protect/build_all.sh all
```

> 说明：鸿蒙需在 DevEco Studio 5.0+（API 12）环境构建；iOS/macOS 需 macOS + Xcode；Windows/Linux 需对应平台工具链。
> Android 的 `build.gradle.kts` 已内置 R8 与资源混淆配置，release 会签名自动生效（默认 debug 签名便于一键出包，正式发布时替换 keystore）。

## 双音源能力

- **QQ 音乐**：登录（扫码 / Cookie，Cookie 登录同时支持 QQ 与微信账号）、搜索（综合 + 单曲）、歌曲详情、播放地址（320→192→128 降级链）、歌词解密（QRC）、下载。
- **网易云**：搜索、播放地址（EAPI 加密）、加密 ID（encryptId）。

## 本地音乐

不走任何网络接口，直接用本机磁盘上的音频文件，依靠 `lib/metadata/audio_reader.dart`
自研的纯 Dart 元数据读取器识别信息：

| 容器 | 标签来源 | 时长来源 |
| --- | --- | --- |
| MP3 | ID3v2.3/2.4（TIT2 / TPE1 / TALB / USLT / APIC），回退 ID3v1 | Xing / Info / VBRI 精确值，否则 CBR 估算 |
| FLAC | Vorbis Comment + PICTURE | STREAMINFO 的 totalSamples / sampleRate |
| M4A | `moov/udta/meta/ilst` 的 ©nam / ©ART / ©alb / ©lyr / covr | `mvhd` 的 duration / timescale |
| OGG | Vorbis Comment + base64 METADATA_BLOCK_PICTURE | 末页 granulePosition / sampleRate |
| WAV | `LIST/INFO` 的 INAM / IART / IPRD | `fmt ` 的 byteRate |

- **增量扫描**：以「文件大小 + 修改时间」为指纹，未变动的文件不重新读盘，第二次扫描几乎瞬时；扫描在后台 Isolate 执行，不卡 UI。
- **歌词**：优先同目录同名 `.lrc`，其次文件内嵌（USLT / Vorbis Comment）。
- **性能取舍**：扫描阶段不读封面与歌词——几千张封面会吃掉几百 MB 内存，二者改为播放时按需读取，并带 200 条上限的封面内存缓存。

移动端需要授权存储权限才能扫公共目录；桌面端无需额外授权。

## 测试与质量

- `flutter test`：170 项测试全绿。覆盖 QQ 音乐签名算法（hash33 / zzc_sign / tripledes / qrc 解密，与 C 源码参考向量逐字节对照，含 15 字节 zzc_2 修复）、网易云加密、模型解析、二维码登录状态码语义、Cookie 登录的 QQ/微信两种账号形态（15 项）、封面 URL 降级、协议弹窗交互、版本检查，以及本地音乐的元数据解析（五种容器 38 项）、扫描与增量（30 项）、持久化与页面（13 项）。
- `flutter analyze`：No issues found。
- 版本号的唯一真相来源是 `pubspec.yaml`：`test/app_version_test.dart` 会校验 UI 常量与之一致，CI 的 `read-version` 复合动作也从这里读取，避免「关于页显示旧版本」「Release 标题错位」。

## 鸿蒙适配说明

`ohos/` 是完整可构建的原生鸿蒙壳工程（stage 模型、API 12），启动页视觉与 Flutter 侧主题一致；
业务层共用在 `lib/`，通过 flutter-ohos 引擎（OpenHarmony Flutter 发行版）接入，
详见 [`ohos/README.md`](ohos/README.md)。

## 许可与声明

本工程仅作学习与技术演示使用。QQ 音乐、网易云相关接口与算法仅用于个人研究，请遵守目标平台服务条款与著作权法规。