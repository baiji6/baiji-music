# 白姬音乐 · Baiji Music

跨平台音乐播放客户端，一套 Flutter/Dart 代码同源支持 **iOS / macOS / Windows / Linux / Android / HarmonyOS（鸿蒙）** 六端，
UI 采用暗色玻璃拟态 + 霓虹渐变的现代化未来感设计，构建期自动执行**加壳与混淆**防逆向。

> 本工程由「白姬音乐 Android 原生 v1.1.1」重构而来：C 算法库（hash33 / zzc_sign / tripledes / qrc / qimei / comm）全部移植为纯 Dart，
> 网络层支持 **QQ 音乐 / 网易云音乐 / 酷我音乐** 三音源，功能模块覆盖搜索、播放、歌单、下载、扫码登录与本地音乐。

---

## v2.4.2 更新速览（预发布 pre1–pre7）

| 能力 / 修复 | 说明 |
| --- | --- |
| 🎧 **网易云臻音全景声（Audio Vivid / AVS3-P3）解码** | 自研解码器直接编入 libmpv：UWA 参考软件（C 语言）封装为 FFmpeg `av3a` 解码器，MP4 `'av3a'` 封装识别，NN 模型内嵌零外部依赖；宿主实测解码真实网易云文件 12289 帧 0 错误，输出与参考解码器逐样本等价（RMS 差异 0.000%）；新增网易云「臻音全景声」音质档（`level=vivid` 可直连取流，请求杜比无内容时服务端也自动返回该格式） |
| 🔊 **AC-4 双解码器共存** | ffmpeg 同时编入两个 AC-4 解码器：Jellyfin 移植版（`ac4`）+ [baka-ac4](https://github.com/Zencok/baka-ac4) Rust 版（`ac4_baka`），播放侧 `ad=ac4_baka,ac4` 自动切换；运行时探测解码器能力，探测通过即短路音质降级防护，酷我杜比 AC-4 正常直放 |
| 💬 **QQ 评论风控 10009 修复** | 发评论被风控时（错误 10009）App 内弹出**内嵌 WebView 滑块/验证页**，验证完成自动重试，不跳浏览器 |
| 📱 **QQ / 网易云验证码登录** | 仿倾听交互：手机号 + 短信验证码登录（QQ 走 `SendPhoneAuthCode/Login`，网易云走 weapi `captcha/sent` + `login/cellphone`），App 内完成 |
| 🎵 **QQ 音乐 QMCv2 流式解密** | QQ 部分音轨与酷我同为 qmcv2 加密，同一本地中继链路复用，边下载边解密直接播放 |
| 📋 **网易云「我的歌单」修复** | 三平台用户歌单统一修复（QQ 带-cookie `fcg_user_created_diss` / 网易云带-cookie / 酷我 `getuserlist`） |
| 📡 **数据上报带 IP** | 客户端上报自动附带公网 IP（ipify 主 + icanhazip 备），服务端入库并在面板三张表展示；旧库自动 `ALTER TABLE` 迁移 |
| 📊 **服务端面板交互优化** | `upload.php` 三张明细表横向滑动时**最左列一起滑动**（移除首列吸附）；旧数据库无需删库自动补列 |
| 🔍 **完整播放链路日志** | 播放时输出所用解码器（`codec=... 解码器=...`）、采样率、声道与实际音频输出设备，一屏看清「文件→解码器→输出」全链路 |

## v2.4.1 新增速览

| 能力 | 说明 |
| --- | --- |
| 🔑 **酷我音乐登录** | 设置 → 账号 → 酷我音乐：账号密码 / 短信验证码两种方式，会话本地持久化 + 过期自动重登，口令 SM4 加密落盘 |
| 💬 **酷我歌曲评论** | 播放页评论按钮对酷我歌曲生效：最热 / 最新评论浏览 + 分页；酷我不开放发表与楼中楼，故为**只读**并明确告知，不放假按钮 |
| 🔐 **酷我 `f=ar` 协议** | `q = base64(DES-ECB(query, "kwks&@69"))`、响应体 `sx` 密钥密封；复用 QMC 同一套 DES 表（只补 `encrypt`，无第二份密码学实现），与倾听 5.5.0.2 / TuneWeave 交叉验证并实测打通 |

## v2.4.0-fix2 修复速览

| 修复项 | 说明 |
| --- | --- |
| 🖼️ **酷我封面太模糊** | 封面档位 120 → **1500**（接口最高档），完整 URL 换尺寸段、短路径剥尺寸前缀，两种入参都拿到 1500px |
| 🏷️ **酷我显示成 QQ 音乐** | 播放页音源胶囊改三分支：酷我音乐（品牌蓝）/ 网易云音乐 / QQ 音乐；顺带修掉搜索页下载弹层缺酷我分支会抛错的真实 bug |
| 🎚️ **酷我音质不全** | `KuwoQuality` 由 7 档补齐到接口实际的 **18 档**（黑胶 / BCMS / 母带 / 全景声 7.1.4·5.1·2.0 / 杜比 E-AC-3·640·448·AC-4 / Hi-Res / 无损 / 320k / OGG 300k·192k / 128k / OGG 100k / AAC），旧 id 全保留无需迁移 |
| 🧹 **清理缓存不含播放缓存** | 新增 `PlaybackCache`（256 KiB 块、原子写、512 MB LRU），接入酷我 QMC 中继；清理缓存现已一并清空，明细页可单独查看 |

## v2.4.0-fix1 修复速览

| 修复项 | 说明 |
| --- | --- |
| 🔍 **酷我搜不到歌** | 酷我搜索接口响应头是 `text/plain` 而非 JSON，dio 原样返回字符串导致类型转换崩溃；已改为按字节收取 + 手动解码 |
| 📋 **歌单只解析出一部分** | QQ 去掉 1000 首硬上限（接口本就返回全量）；网易云改用 v6 `trackIds` + `v3/song/detail` 分批补全；酷我按 1000 条/页循环拉取 |
| 🔑 **设备 GUID 点不开** | 改为 Miuix 对话框完整展示 GUID + 平台名，等宽字体可横向滚动，支持一键复制 |
| ⚡ **QMC v2 流式解密** | 算法逐表对照开源实现验证一致；中继重写为**真流式**（首字节 0ms）、ekey 改短 token、端口自适应、越界 Range 修复 |
| 📱 **服务端表格不能滑动** | `upload.php` 三张表外包横向滚动容器，首列吸附固定，手机端加滑动提示 |
| 🎯 **酷我 ID 直达播放** | 新增「工具箱 → 酷我 ID 直达播放」：输入 rid 或单曲链接即可查询并播放 |

## v2.4.0 新增速览

| 能力 | 说明 |
| --- | --- |
| 🎵 **酷我音乐音源** | 搜索 / 歌曲详情 / 播放地址 / 歌词全链路；含 **QMC 加密音轨解密**与**本地中继播放**、**18 档音质**与**自动降级链** |
| 🎨 **内嵌平台切换 + 热搜榜** | 搜索框左侧内嵌「酷我 ▾」下拉平台选择器；搜索框下方为带序号的「{平台}热搜榜」，点击即搜 |
| 🆔 **设备 GUID** | 每台设备一个永久唯一 UUID：Android `ANDROID_ID` / iOS `identifierForVendor` / 桌面 machine-id，落盘永不变 |
| 📡 **数据上报 + 服务端面板** | 客户端轻量埋点上报 GUID / 平台 / 搜索 / 歌曲 / 音质 / 播放链接；服务端 `upload.php` 带图形界面，**每 10 秒自动刷新** |
| 🎵 **分享歌单一键导入** | 粘贴 QQ / 网易云 / 酷我歌单链接即可解析、全部播放或存进本地歌单 |

---

## 技术栈

| 层 | 技术 |
| --- | --- |
| UI / 业务 | Flutter 3.47.x + Dart 3.13.x |
| 算法层 | 纯 Dart（QQ 音乐签名 / 设备指纹 / QRC 歌词解密，与原 C 实现逐字节对照） |
| 网络层 | dio（Cookie 管理、流式下载、超时）+ QQ 音乐 / 网易云 / 酷我三协议 |
| 音频 | media_kit（libmpv + ffmpeg 软解，MP3 / FLAC / M4A / OGG / WAV 通吃）；**自研解码器编入链路**：AC-4 双解码器（Jellyfin 移植版 + baka-ac4 Rust 版）与 AVS3-P3 参考解码器（网易云臻音全景声），四 ABI 全覆盖 |
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
│   ├── network/                # QQ 音乐 + 网易云 + 酷我网络层（含 QMC 解密、f=ar 登录协议、评论、歌词解码、热搜榜、分享歌单解析）
│   ├── data/                   # 设备指纹 / 历史 / 歌单 / 本地音乐库存储
│   ├── player/                 # 播放控制
│   ├── download/               # 音质降级下载链
│   ├── local/                  # 本地音乐扫描（Isolate + 增量指纹）
│   ├── metadata/               # 音频元数据读写（写入 / 读取）
│   └── core/                   # 日志 / KV / 封面 URL / 版本号 / 工具 / 设备 GUID / 数据上报
├── android/                    # Android（R8 全量混淆 + 资源混淆）
├── ios/                        # iOS（Xcode Release 自动 strip 符号）
├── macos/                      # macOS（构建后 strip 符号）
├── windows/                    # Windows（构建后 UPX 加壳）
├── linux/                      # Linux（构建后 UPX 加壳）
├── ohos/                       # HarmonyOS 鸿蒙（方舟混淆自动生效）
├── scripts/protect/build_all.sh# 统一构建·加壳·混淆流水线
├── tools/upx/                  # 固化 UPX 可执行文件（无需系统安装）
├── upload.php                  # 服务端数据接收与可视化面板（PHP 7.4+，每 10 秒自动刷新）
└── test/                       # 算法向量对照测试与全量回归测试
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

## 三音源能力

- **QQ 音乐**：登录（扫码 / Cookie / **短信验证码**，Cookie 登录同时支持 QQ 与微信账号）、搜索（综合 + 单曲）、歌曲详情、播放地址（320→192→128 降级链）、歌词解密（QRC）、下载、**评论浏览与发表**（风控触发时内嵌 WebView 完成滑块验证自动重试）、**QMCv2 加密音轨流式解密播放**。
- **网易云**：登录（**手机号验证码** / Cookie）、搜索、播放地址（EAPI 加密）、加密 ID（encryptId）、**我的歌单**、**杜比全景声（E-AC-4 JOC）与臻音全景声（AVS3-P3 / Audio Vivid，v2.4.2 自研解码器直解）**。
- **酷我音乐**（v2.4.0 新增）：搜索、歌曲详情、播放地址、歌词（Base64 → XOR → zlib → GB18030 解码）、下载、**登录（v2.4.1：账号密码 / 短信验证码）**、**评论浏览（v2.4.1，只读）**。

### QMC 加密音轨解密（酷我 & QQ 音乐）

酷我与 QQ 音乐的部分音轨均为 QMC 加密流（qmcv2），本工程纯 Dart 实现了完整解密链路，
两个音源共用同一本地中继通道：

| 环节 | 实现 |
| --- | --- |
| 密钥解包 | `EkeyCipher`（DES 变体）解出 ekey |
| 密钥派生 | TEA 派生八字节密钥 |
| 主体解密 | `MapCipher` / `Rc4Cipher`（QMC v2） |
| 播放通道 | 内置本地 HTTP 中继（支持 Range 随机访问），边下载边解密喂给 media_kit |

同时提供 **18 档音质规则**（母带 / HiRes / FLAC / OGG / 320K / 128K / AAC 等），
播放与下载各自独立记忆偏好；高档音质不可用（未登录等）时按
**降级链**逐档回落，不直接报错。

**QMC v2 可靠性验证（v2.4.0-fix1）**：解密链路与开源实现
`kuwo-music-relay-main/decrypt.php` 逐表逐式对照完全一致，并用真实线上
mflac 母带音轨（rid=7149583）端到端跑通（ekey 952 字符 → rawKey 704 →
最终 key 512 → `Rc4Cipher` → 解出合法 `fLaC` 头）。本地中继已重写为
**真流式**（`StreamedResponse` 逐块解密逐块下发，实测首字节延迟 0ms），
ekey 只存内存（URL 用短 token），端口由系统分配，越界 Range 自动夹回合法范围。

**歌曲播放缓存（v2.4.0-fix2）**：中继在直连流式之外增加**块缓存路径**——
按 256 KiB 块取流，命中即回块、未命中回源后落盘，seek 到任意偏移都能精确命中。
实测在沙箱内验证了 libmpv 自带的 `--cache-on-disk` 在本项目的用法下
**并不会真正落盘**（目录建了但始终为空，数据全在内存），因此改为自建缓存：
`tmp + rename` 原子写、512 MB 上限 mtime-LRU 淘汰、全程不抛异常，
**首块失败会干净退回直连流式**，对播放零影响。「设置 → 清理缓存」现已把
播放缓存一并清空，缓存明细页可单独查看占用。

### 音频解码器扩展（v2.4.2：AC-4 双解码器 + 臻音全景声）

libmpv 原生库在通用 ffmpeg 基础上额外编入三个音频解码器。`third_party/media_kit_libs_android_audio`
指向 GitHub Releases 托管的四 ABI jar（`libs-ac4-v6`），构建时逐包 MD5 校验自动拉取：

| 解码器 | 来源 | 用途 |
| --- | --- | --- |
| `ac4` | Jellyfin ffmpeg 6.0 分支解码器移植（含 7.1 兼容层） | 酷我 / 网易云杜比全景声（E-AC-4 JOC） |
| `ac4_baka` | [baka-ac4](https://github.com/Zencok/baka-ac4)（Rust FFI） | 同上的第二实现，`ad=ac4_baka,ac4` 自动切换 |
| `av3a` | AVS3-P3 参考软件（UWA，C 语言，NN 模型内嵌零外部依赖） | 网易云臻音全景声（Audio Vivid） |

- **运行时探测**：启动后查询 mpv `decoder-list`，确认解码器真实编入才放行对应音质，
  探测通过自动短路「不可解码」降级防护，避免接口给了但设备解不了的假故障；
- **完整链路日志**：tracks 事件输出 codec、解码器名、采样率、声道数与实际音频输出设备（`current-ao`）；
- **宿主验证**：av3a 对真实网易云文件 12289 帧解码 0 错误，输出与参考解码器逐样本等价
  （RMS 差异 0.000%，Pearson 相关 0.99996）。

### 搜索页：内嵌平台切换 + 真实热搜榜

- 搜索框**左侧内嵌平台下拉选择器**（「酷我 ▾」样式），在 QQ 音乐 / 网易云音乐 / 酷我 之间直接切换；
- 搜索框下方为**「{平台}热搜榜」**：真实抓取三平台热搜词，带**序号**排布，点击任一热词直接发起搜索；
- 平台切换后热词自动刷新，并上报平台切换埋点。

### 分享歌单一键导入

「我的 → 更多 → 导入分享歌单」：粘贴 QQ 音乐 / 网易云 / 酷我 的歌单分享链接或整段分享文本，
自动识别平台并解析出曲目列表，可**全部播放**或**保存到本地歌单**。

v2.4.0-fix1 修复了「只解析出一部分曲目」的问题，三平台现在都能拿到**全量**：

| 平台 | 之前的坑 | 现在的做法 |
| --- | --- | --- |
| QQ 音乐 | 本地 `.take(1000)` 把接口已返回的全量截断 | 直接用接口返回的全量 `songlist`，不限量 |
| 网易云 | `api/playlist/detail` 的 `tracks` 只有 **10 条** | 先取 v6 接口的 `trackIds`（全量），再分批调 `api/v3/song/detail`（单批 ≤100）补全 |
| 酷我 | `rn` 参数单次上限 1000 条 | 按 1000 条/页循环拉取，直到取满 `total` |

### 酷我 ID / 单曲链接直达播放

「工具箱 → 音乐工具 → 酷我 ID 直达播放」（「我的 → 更多」也有入口）：
输入**纯数字歌曲 ID（rid）**、酷我网页版单曲链接或移动端单曲链接，
即可查询歌曲元信息与可用音质并一键播放；QMC 加密音轨自动走本地流式解密。

### 酷我登录与评论（v2.4.1）

**登录**（设置 → 账号 → 酷我音乐）：

- 支持**账号密码**（用户名 / 手机号 / 邮箱）与**短信验证码**（中国大陆手机号，5 位验证码，60 秒冷却）；
- 会话本地持久化，启动自动恢复；过期自动用留存口令重登；
- 口令以 SM4-CBC 加密落盘，不明文存储。

**评论**（播放页评论按钮，酷我歌曲生效）：

- 可浏览**最热**与**最新**评论，支持分页与点赞数，未登录同样可看；
- 酷我**不开放发表评论与楼中楼回复**（沙箱内穷举验证 `post_comment` /
  `get_child_comment` 全部不可用），因此评论页对酷我歌曲为**只读**，
  输入框位置明确提示，不放假按钮。

**协议层**（酷我 `f=ar`）：`q = base64(DES-ECB(query, "kwks&@69"))`，
响应体 `base64(DES-ECB(body, sx))`，`sx` 取毫秒时间戳前 8 位；
元数据走 `Cookies` 头（复数，官方原生传输形制）。
DES 复用 QMC 的同一套表（只补 `encrypt` 方向，无第二份密码学实现），
与倾听 5.5.0.2、TuneWeave 的 Rust 实现逐式交叉验证，沙箱内对真实
服务端实测打通。

## 设备 GUID 与数据上报

### 唯一设备标识

每台设备生成一个**永久唯一 GUID**（UUID 形态，由 sha256 派生）：

| 平台 | 设备 ID 来源 |
| --- | --- |
| Android | 原生 `Settings.Secure.ANDROID_ID`（MethodChannel `baiji/device`） |
| iOS | `identifierForVendor`（MethodChannel `baiji/device`） |
| 桌面端 | 系统 machine-id / IOPlatformUUID / MachineGuid |
| 兜底 | 本地随机种子派生（保证同一设备恒定） |

GUID 首次生成后落盘保存，**永不重新生成**，避免服务端重复计数。

### 上报通道

`lib/core/telemetry.dart` 实现了轻量上报：内存队列（上限 200）+ 批量 10 条 +
30 秒定时发送 + 失败保留重试，POST JSON 到
`http://molan.guoyue2010.cn/upload.php`，内容包含 GUID、平台、搜索词、
歌曲、音质、播放链接与**公网 IP**（启动时 ipify 主 + icanhazip 备双通道获取，
失败时服务端从请求头兜底）。**fire-and-forget，不阻塞**播放与搜索主流程；
设置 → 通用里可一键关闭「数据上报」并查看本机 GUID。

### 服务端面板 `upload.php`

仓库根目录提供 `upload.php`（PHP 7.4+，无第三方依赖）：

- 接收 `POST` JSON 事件，落库存储：优先 **SQLite**（`data/baiji.db`），
  宿主无 `pdo_sqlite` 时**自动降级为 JSON 文件**（`data/baiji.json`），功能一致；
  事件/播放/搜索三张表均记录**用户 IP**（客户端上报优先，服务端
  `X-Forwarded-For` → `X-Real-IP` → CF 头 → `REMOTE_ADDR` 兜底），
  **旧库自动 `ALTER TABLE` 补列迁移**，无需删库重建；
- `?action=api` 输出聚合统计（stats / platforms / keywords / users / plays / searches）；
- 自带**暗色图形界面面板**：统计卡片、平台分布条、热词云、用户表、播放明细、搜索明细，
  页面**每 10 秒自动刷新**（`setInterval(load, 10000)`，局部刷新不整页闪烁）；
- 三张明细表在**手机上可左右滑动**（外层 `.tw` 横向滚动容器，最左列跟随一起滑动），
  并带「← 左右滑动查看更多列 →」提示。

部署：把 `upload.php` 放到网站根目录，确保 `data/` 目录可写（脚本会自动创建），
访问 `http://<你的域名>/upload.php` 即可。

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

- `flutter test`：899 项测试全绿。覆盖 QQ 音乐签名算法（hash33 / zzc_sign / tripledes / qrc 解密，与 C 源码参考向量逐字节对照，含 15 字节 zzc_2 修复）、网易云加密、**酷我 QMC 解密与歌词解码**、模型解析、二维码登录状态码语义、Cookie 登录的 QQ/微信两种账号形态（15 项）、封面 URL 降级、协议弹窗交互、版本检查，**酷我 QMC v2 真实向量回归（6 项：用真实 ekey + 真实密文/明文前 6144 字节锁死解密链与 seek 一致性）**，**酷我 18 档音质与播放缓存回归（21 项：音质表逐字段对齐、播放缓存块边界与写读清闭环、中继 Range 逐字节正确、seek 任意偏移、二次请求命中缓存不回源）**，**酷我 `f=ar` 协议编解码（21 项：q 参数与响应体固化向量、协议往返、坏输入拒绝、填充规则）**，**酷我登录核心（28 项：设备身份形制与自愈、会话 JSON 往返、手机号校验、短信 secret 独立参考向量、口令 SM4 加解密、登录态监听）**，**酷我评论解析（18 项：真实抓包样本、时间串解析、分页边界、脏数据降级）**，以及本地音乐的元数据解析（五种容器 38 项）、扫描与增量（30 项）、持久化与页面（13 项）。
- `flutter analyze`：No issues found。
- 版本号的唯一真相来源是 `pubspec.yaml`：`test/app_version_test.dart` 会校验 UI 常量与之一致，CI 的 `read-version` 复合动作也从这里读取，避免「关于页显示旧版本」「Release 标题错位」。
- 自 **v2.2.1** 起，Release 正文里的更新日志统一写在仓库根目录的 `CHANGELOG.md`：CI 的 `Extract changelog` 步骤会抽出与 tag 同版本的那一节填进 Release 正文，**抽不到就直接让流水线失败**；同时 `app_version_test.dart` 也会校验 `CHANGELOG.md` 里有对应条目，避免改了 tag 却忘了写日志。

## 鸿蒙适配说明

`ohos/` 是完整可构建的原生鸿蒙壳工程（stage 模型、API 12），启动页视觉与 Flutter 侧主题一致；
业务层共用在 `lib/`，通过 flutter-ohos 引擎（OpenHarmony Flutter 发行版）接入，
详见 [`ohos/README.md`](ohos/README.md)。

## 许可与声明

本工程仅作学习与技术演示使用。QQ 音乐、网易云音乐、酷我音乐相关接口与算法仅用于个人研究，
请遵守目标平台服务条款与著作权法规。数据上报功能默认开启，可在「设置 → 通用 → 数据上报」中随时关闭，
服务端仅收集设备 GUID、平台、搜索词、歌曲与音质等统计信息，不含个人身份信息。