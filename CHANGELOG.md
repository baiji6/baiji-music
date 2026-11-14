# 更新日志

本文件是「白姬音乐」每个版本的更新说明。Release 正文会**自动取这里对应版本的内容**，
所以写在这里就够了，不要在 GitHub Release 里另写一份。

格式约定：每个版本一个 `## 版本号` 二级标题，标题必须与 `pubspec.yaml` 的
`version` 完全一致（CI 会校验），否则 Release 会构建失败。

## 2.5.8-fix2

> 正式修订版（tag `v2.5.8-fix2`）。修复酷狗 360RA 无法解码，新增日志自定义
> 保存位置，并让 DTS:X / 360RA / NAC 三个自研解码格式支持**边转码边播放**。

### 🐛 酷狗：360RA 音质无法解码

- 根因：酷狗服务端下发的 360RA 是 **MPEG-H 3D Audio** 容器——mp4 的 stsd 里
  fourcc 为 `mhm1`，`mhaC` 配置盒内联 `mpegh3daConfig`。media_kit 的 ffmpeg
  白名单没有这个解码器，旧版把直链原样丢给播放器，只会得到
  `Failed to recognize file format.`（日志里能看到
  `播放: ...qu360ra_l3...mp4` 之后没有解码记录）。而 QQ 音乐的 RA01-04
  走的是原生解码管线，酷狗这一档**完全没接进去**。
- 逆向确认（酷狗音乐 20.8.8 官方 64 位 / 32 位 APK）：
  - 酷狗 `libkugouplayer.so` 内置 `KugouPlayer::Sony360RADecoder` +
    `KugouPlayer::MpeghDecoder`，调用的是 `sia_mhdr_*` / `sia_virtualizer_*`
    ——与官方 QQ 解码器 `qm_native_decoder_360ra.so` 内置的是**同一套
    Sony SAL SDK**；
  - 两者的 mp4 解析器都支持 `mhm1` / `mhaC`：反汇编
    `CMP4Parser::find_stsd_in_stbl` 确认它依次 `strncmp` 比较
    `mha1`(0x1bd1d) / `mhm1`(0x1bd27) / `mhaC`(0x1bd22)。
  - 实测《雨爱》360RA 样本（52MB）：stsd fourcc = `mhm1`，`mhaC` 内
    `profileLevelIndication=0x0e`（MPEG-H 3D Audio），config 内联，
    与 QQ 音乐 RA0x **完全同型**。
- 修复：酷狗 `360ra` 档位接入与 QQ 音乐 RA0x 相同的原生解码管线，产出
  48kHz/32bit binaural WAV 后播放；解码失败时诚实降级到其它音质。缓存 key
  带 `kg360ra_` 前缀，与 QQ 侧隔离（避免同 mid 的两平台歌互相命中对方的
  解码产物）。
- 补齐路由回归测试，锁定「酷狗 360RA → 原生解码」的映射与缓存隔离。

### 🎵 边转码边播放（DTS:X / 360RA / NAC）

- 此前三个自研解码格式都是「整曲解码完 → 写 WAV 缓存 → 再播放」。NAC 一次
  解码要 1~2 分钟（MNN 神经推理 + ISTFT），360RA 要数秒到数十秒，这段时间
  **完全没声**；用户中途切歌，已解的部分全部白费。
- 修复：新增 `lib/core/transcode_stream.dart`——本机 HttpServer（127.0.0.1
  随机端口）tail 原生解码器**边解边写**的临时文件，把增量 PCM 实时推给
  播放器；libmpv 收到多少算多少，**首帧到达即出声**。
  - 原生侧新增 `ra360glue_decode_stream` / `dtsglue_decode_stream` /
    `nacglue_decode_stream`：边解码边追加写 PCM，每段 `fflush`。
  - 流式 WAV 头的 RIFF / data 长度写 `0xFFFFFFFF`（未知总长，流式场景的
    常规做法）——已实测 ffmpeg 能正常解码这类 WAV（`duration=N/A` 是流式的
    正常表现），端到端验证「解码未完成即开始出数据、字节数精确匹配」。
  - DTS:X 的声道数在解码首帧前未知，因此**先解一帧探测真实声道数**再写头，
    避免头里声道数写错导致音频变成噪声。
  - 流式失败自动回落到「整曲解码 + WAV 缓存」旧路径，两条路互为兜底。
- 说明：流式产物写在系统临时目录，**不污染正式缓存**；正式缓存仍由
  v2.5.8-fix1 的「`.part` + 校验 + 原子落盘」流程负责。

### ⚙️ 日志支持自定义保存位置

- 日志此前固定写在应用支持目录下的 `logs/`，用户想抓日志排查问题只能连
  adb 拉文件。现在设置页新增「日志保存位置」，可自选目录（如 SD 卡上的某
  个文件夹），方便直接用文件管理器取。
- 切换时做**写入预检**（建目录 + 写探针文件 + 删除），选到不可写的目录会
  明确提示「Android 11+ 写公共目录需要「所有文件访问权限」」，而不是让
  日志静默地继续写在旧目录里、用户却以为已经切好。
- 自定义目录不可用（卡被拔、目录被删、权限被收回）时**静默回落到默认目录**
  并记一条 warn——日志功能不能因为一个目录设置而整体停摆。
- 切换只影响之后的写入，旧日志留在原处（不迁移）；清理过期日志仍只删
  匹配 `baiji_YYYYMMDD.log` 的文件，不会误伤用户目录里的其它内容。

### 🧪 回归测试

- 新增 `test/transcode_stream_test.dart`：验证「文件增长过程中即可读到已
  写入的部分」（首帧不必等写完）、多次追加的数据按顺序完整读出无重复遗漏、
  流式 WAV 头的未知长度标记。
- 新增 `test/kugou_360ra_route_test.dart`：锁定酷狗 360RA 的档位属性与
  解码管线路由、缓存 key 的平台隔离。
- 新增 `test/log_custom_dir_test.dart`：覆盖自定义目录读写、不可写不落盘、
  回落默认目录、旧日志不迁移、键名不冲突。
- 全量 **1211 项测试通过**（v2.5.8-fix1 为 1187 项）。

## 2.5.8-fix1

> 正式修订版（tag `v2.5.8-fix1`）。修复三个线上问题：酷狗有 360RA 却不展示、
> NAC 转码 WAV 后播放不了、本地音乐扫描不收录特殊音质格式。

### 🐛 酷狗：有 360RA 音质的歌曲却看不到该档位

- 根因：权威档位接口 `goodsmstore/v1/get_res_privilege` 对 360RA 三档
  （`360ra_l1` / `360ra_l2` / `360ra_l3`）**一律不下发 `info.filesize`**
  （值为 0，`extname` 也为空），但每档都带真实且互不相同的 32 位 hash。
  v2.5.4 的解析把 `filesize<=0` 当成「服务端占位、档位无效」整批丢弃，
  于是所有带 360RA 的歌曲都不显示该档位。实测杨丞琳《雨爱》三档 hash
  均有效，用 `360ra_l3` 的 hash 取链返回 `status=2`（需会员/登录），
  证明档位真实存在，只是 App 自己把它藏了。
- 修复：档位有效性只看 `(quality, hash)`，`filesize` 退化为纯元数据
  （0 = 服务端未给大小）；只有空 hash 的占位条目才跳过。抽样 10 个关键词
  共 1207 个档位条目，`filesize=0` 的仅《雨爱》这 3 条 360RA，确认放宽
  判据不会引入「实际没有」的假档位。
- 补齐真实接口响应片段驱动的回归测试，覆盖解析 → 档位推导 → UI 过滤 →
  取流 hash 全链路。

### 🐛 NAC / DTS:X / 360RA：转码成 WAV 后播放不了

- 根因：三个原生解码器边解码边把 PCM 直接写进**最终 wav 路径**（先写 44
  字节全 0 占位头，结束时才 `fseek(0)` 回填 RIFF 头）。NAC 全曲解码需
  1~2 分钟，期间缓存判断只看 `existsSync()` 就命中这个半成品，media_kit
  报 `Failed to recognize file format.`；解码若被中断，残文件会永久留在
  缓存目录，之后每次点播都失败。
- 修复：新增 `lib/core/wav_cache.dart`——解码改写 `<final>.part`，校验
  RIFF / WAVE / data 与文件长度一致性后**原子落盘**；`hasCachedWav` 拒绝
  并自动清理半成品/残文件；重复点播优先等待进行中的解码任务，不再因
  取流被频控打空而降级到低音质。
- NAC / DTS:X / 360RA 三个解码器与工具箱「音频转码」共用同一套落盘逻辑，
  避免同类问题在别处复现。

### 🎵 本地音乐：收录特殊音质格式并自动转码播放

- 扫描扩展名补齐 `.nac` / `.dts` / `.dtshd` / `.dtsx` / `.mha1` / `.mhm1`
  / `.ac3` / `.eac3` / `.ec3` / `.av3a`，这些文件现在能进入本地曲库。
- NAC / DTS:X / 360RA 在播放前由自研解码器转成标准 PCM WAV 再播，按
  「路径 + 大小 + 修改时间」生成缓存键，同一文件只解一次；AC-3 / E-AC-3
  （杜比全景声）由 media_kit 内置 ffmpeg 直接解码，不做无谓转码。MP4
  容器里的 `dtsx` / `mha1` / `ec-3` 靠文件头 fourcc 识别。
- 自研解码器仅 Android arm64 可用，其它平台会明确提示「可先用工具箱
  『音频转码』转成 WAV」，而不是把不可解码的文件直接丢给播放器。

### 🧪 测试

- 新增 `wav_cache_test.dart`（占位头 / 未写完文件 / 原子落盘 / 残文件清理）
  与 `local_special_test.dart`（扩展名 / 格式识别 / 缓存键 / 平台降级）；
  `kugou_privilege_test.dart` 补《雨爱》真实响应回归。`flutter analyze`
  零问题，全量 `flutter test` 全绿。

## 2.5.8

> 正式版（tag `v2.5.8`）。本版起**不再适配洛雪（LX）音源**，彻底移除
> v2.5.7-pre1 ~ pre3 期间引入的全部洛雪相关代码与依赖，回归
> **QQ 音乐 / 网易云音乐 / 酷我音乐 / 酷狗音乐** 四音源。

### 🗑️ 移除洛雪音源适配

- 删除整个 `lib/lx/` 运行时目录（宿主引导脚本、HTTP 请求桥、同步加密桥、
  JS 引擎抽象层与两套引擎适配、取流入口 `LxMusicApi`、音源仓库、版本比较与
  检测更新），以及 `lib/core/pure_lx_mode.dart`、`lib/network/source_fallback.dart`。
- 删除洛雪音源管理页与音源测试页，移除设置页「内置音源（需登录）」总开关、
  平台下拉的「洛雪」项、播放器与数据模型（`Source.lx` / `Song.hash` / `isLx` /
  `lxSource`）中的全部分支，以及启动时预热音源的逻辑。
- 「取链失败自动切换音源」（原生→洛雪补链 / 洛雪→回退 QQ）随洛雪一并移除；
  播放取流回归四大原生平台各自内部的音质降级链，功能不受影响。
- 删除 `third_party/quickjs_runtime` 第三方引擎源码（约 9.5 万行 QuickJS C 代码）
  与 7 组洛雪单测、本地测试音源夹具；移除 `flutter_js` / `quickjs_runtime`
  依赖并重新生成 `pubspec.lock` 与六端插件注册表。`crypto` / `pointycastle` /
  `ffi` 等原生能力依赖完整保留。

### 🛠️ 构建与工程

- 回退仅为洛雪引入的 Android `kotlin.jvmTarget.validation.mode` 兼容配置、
  CI 中 flutter_js 的 JVM target sed 与 Windows `--verbose` build hook 诊断；
  `build.yml` 保留通用的 `concurrency` 串行排队（避免 tag run 缺 Release job）。
- `flutter analyze --no-pub` 零问题；全量 `flutter test --no-pub` 全绿；
  本地 `flutter build linux --release` 实跑通过。版本号 `2.5.8+33`。

## 2.5.7-pre3

> 预发布版（tag `v2.5.7-pre3`，GitHub Pre-release）。洛雪音源仍由**用户自行导入**，
> App 本体不内置、不分发任何音源脚本。

### ⚙️ JS 引擎升级：QuickJS 2024-01-13 + 双引擎

- **根因**：`flutter_js 0.8.7` 内置的是 QuickJS 2020-11-08 / 2021-03-27，
  `molan.js`（墨澜聚合音源）等使用现代语法的音源会直接
  `SyntaxError: expecting ';'`，而 LX-X 用较新 QuickJS 且不做转译，能正常运行。
- **Android / Linux / Windows** 改用 `quickjs_runtime 0.4.9` 自带的
  **QuickJS 2024-01-13**（pure-Dart FFI + Native Assets 六端自编译；Windows 有
  MSVC 兼容 shim、Android 有 16KB 页对齐、Apple 有 `@rpath`）。实测 `molan.js`
  已能完整加载并声明 kw / kg / tx / wy / mg 五个子源与 128k ~ master 全部音质档位。
- **iOS / macOS 保留系统 JavaScriptCore**（`flutter_js`），满足 App Store 3.3.2
  「第三方脚本须由 WebKit / JavaScriptCore 解释执行」的要求。
- 新增 `LxJsEngine` 抽象层与两个 adapter，`LxRuntime` 改为引擎无关。通过注册
  同名全局 `sendMessage` host function，宿主引导脚本**零改动**即可在两套引擎上
  运行；13 个通道、同步返回值、Promise / `lx_result` 闭环行为完全一致。

### 🧩 按 LX-X 环境完整支持所有洛雪音源（修复纯洛雪取流）

- 以 LX-X 的 `user-api-preload.js` 为金标准重写宿主契约：
  `env=mobile` / `version=2.0.0` / `currentScriptInfo`（含 `rawScript`）/
  `EVENT_NAMES` / `on` `send` 返回 Promise / `send(inited)` 规范化 `sources` /
  `lx.request` 三参回调 `(err, resp, body)` 并返回 abort 函数 /
  `setTimeout` `clearTimeout` `setInterval` / `form` `formData` `binary` /
  `utils.crypto.md5(encodeURIComponent)` / `aesEncrypt` 双签名 /
  `rsaEncrypt`（`RSA/ECB/NoPadding`）/ `global` `process` `require` `atob`
  `btoa` `crypto` `performance` `fetch` 等全局 polyfill。
- **标准 `musicInfo` 字段按平台区分**：网易云 / 酷我用 `id`，QQ 音乐用
  `songmid` / `mid`，酷狗用 `hash`。此前酷狗 `Song.mid` 存的是 `albumAudioId`
  而非 `FileHash`，导致 `ikun` / `baimusic` 等音源取错主键；现给 `Song` 增加
  `hash` 字段，并在酷狗搜索映射时持久化真 `FileHash`。
- 修复 `lx.currentScriptInfo.rawScript` 同步 getter：此前传给通道的空字符串会被
  `jsonDecode('')` 打断脚本，改为合法 JSON。
- HTTP 桥支持 `form` / `formData` / `binary` 响应、`statusMessage`、headers、
  `timeout` clamp、`follow_max`，并显式编码 `Map` / `List` body。
- **加载失败不再静默吞**：新增 `LxMusicApi.loadErrors`，音源测试页如实展示
  「脚本加载失败 / 未声明 inited」。

### 🔬 音源测试页重做

- 只按插件 `inited.sources` 声明生成探针，且**子源与样本平台强制匹配**
  （tx↔QQ、wy↔网易云、kw↔酷我、kg↔酷狗）；去掉「所有子源 × 所有平台」
  笛卡尔积与固定假 mid 打真实网关的做法。
- 样本搜索失败如实返回失败，不再用假 mid 冒充结果；结果改用
  `LxMusicApi.musicInfoOf(song, sub)` 构造标准 `musicInfo`。

### 🧪 测试与发布合规

- 新增双引擎契约测试（17 项）：13 通道、同步返回值、`rawScript` 大字符串、
  `lx_result` 闭环、定时器、错误判定、`molan.js` 端到端加载。
- `flutter analyze` 零问题，全量 **1256 项**（其中 8 项 Apple 引擎在本机
  无 flutter_js 原生库时按环境自动跳过）。
- 用户提供的测试音源不入库、不进 App 资源包、不随 Release 分发；
  夹具缺失时相关测试自动跳过。

## 2.5.7-pre2

> 预发布版（tag `v2.5.7-pre2`，GitHub Pre-release）。洛雪音源仍由**用户自行导入**，
> App 本体不内置、不分发任何音源脚本。

### 🐛 修复「用洛雪音源取流播放失败」

- **响应体对象化**：宿主回写 `lx.request` 的 `resp.body` 时按内容判定——JSON 文本
  解析为对象，非 JSON 文本保持字符串。`ikun` 等音源直接读 `body.code` / `body.url`，
  pre1 恒回传字符串导致 `unknow error`、取链 100% 失败；`baimusic` 自带
  `parseBody` 的字符串分支不受影响（不回归）。刻意不用 `new String` 包装，
  那会让 `typeof` 变成 `'object'` 反而破坏字符串分支。
- **宿主契约补齐**：注入 `console.group / groupEnd / table / time / timeEnd` 等常用
  方法并把 `log / warn / error` 转发到 App 日志；`EVENT_NAMES` 补齐
  `updateAlert / updateLog / log / error`。这两处缺失会直接抛错打断音源脚本。
- **请求桥加固**：响应头透传（pre1 恒为空对象）、`timeout` → connect/send/receive
  超时、`follow_max` → `maxRedirects`、非 2xx 响应体保留（否则读不到 403 / 429 /
  500 的错误信息）、`Map` / `List` body 显式按 JSON 编码。
- **超时与日志**：`dispatch` 统一超时并从待决表自清理；音源脚本日志进入 App 日志，
  排查「取流失败」时可看到脚本内部报错。
- **失败原因诊断**：`LxPlayResult` 新增 `LxFailReason` 与中文 `reasonText`
  （未加载音源 / 子源不支持 / 音质不支持 / 脚本取链失败 / 超时 / 空链接），
  音源测试页与日志如实展示，不再只有「无法获取播放链接」。
- **按平台路由**：洛雪取流按 `song.source` 选择用户实际选中的音质档位
  （QQ / 网易云 / 酷我 / 酷狗），子源由 `LxSubSource.fromApp` 推断，
  绕开 `search(Source.lx)` 固定 `tx` 子源的旧路径。

### 🎚️ 内置音源（需登录）总开关 · 纯洛雪模式

- 设置页「音源」新增总开关，默认开启（保持现状）。关闭后进入**纯洛雪模式**：
  所有网络歌曲（含从 QQ / 网易云 / 酷我 / 酷狗搜索到的）只由洛雪 JS 音源取流，
  跳过原生平台取链，且**取链失败不回退原生**。
- 播放器对所有网络歌曲单次取流，不再走原生 6 档降级链重复打洛雪网关
  （部分音源有 429 限流）；失败时播放页提示「纯洛雪模式：已跳过内置音源回退」。
- 纯洛雪模式下平台下拉隐藏「洛雪」项，避免回到旧路径；关闭开关但尚未导入音源时
  明确提示「将无法播放网络歌曲」。

### 🔬 音源测试页重构（只测洛雪）

- **只测洛雪音源**：删除 4 个原生平台的「搜索 + 取流」探针；按平台搜索仅用于
  准备一条样本 mid，不算测试原生取链。
- **四维筛选**：单个音源（全部 / 指定插件）、洛雪音质（从插件 `qualitys` 声明
  动态取并集，不硬编码）、洛雪子源（自动 / 全部 / `kw·kg·tx·wy·mg·git`）、
  曲目来源平台（QQ / 网易云 / 酷我 / 酷狗 / 全部）。
- **单项测试**：每张卡片可单独「测试」，顶部保留「运行全部」；指定音源时只命中
  该插件，避免被别的插件静默补链误判可用。结果展示耗时、命中插件 / 子源 /
  档位 / 直链，或失败原因；组合过多时按 60 条探针上限截断并提示。

### 🧪 测试与发布

- 新增 21 项回归：`ikun` 真实音源端到端取链、`resp.body` 对象 / 字符串 / 响应头、
  `console` 与 `EVENT_NAMES` polyfill、请求体编码与非 2xx 响应体保留、
  结构化失败原因 / `pluginInfos` / `pluginId` 单插件取流、纯洛雪开关与回退短路。
- `flutter analyze --no-pub` 零问题，全量 **1222 项**测试通过。
- CI 新增顶层 `concurrency`（按 workflow + SHA 串行排队），避免同一 commit 的
  main run 与 tag run 被跨 run 去重导致 Release job 因 `needs` 不满足而跳过。

## 2.5.7-pre1

> 预发布版（tag `v2.5.7-pre1`，GitHub Pre-release）。洛雪音源是**用户自行导入**的 JS 插件，
> App 本体不内置、不分发任何音源脚本。

### 🎵 完整支持洛雪音乐（LX Music）音源

- **JS 运行时宿主**：新增 `flutter_js`（Android / Windows / Linux 走 QuickJS，Apple 走 JavaScriptCore），
  以 Dart 忠实复刻洛雪插件契约 `globalThis.lx`：`on` / `send` / `request` / `EVENT_NAMES` /
  `env` / `version`，并补齐 QuickJS 缺失的 `TextEncoder` / `TextDecoder` / `Buffer` polyfill
  （含 UTF-8 多字节正确解码，避免中文歌名乱码）。
- **异步请求桥**：`lx.request` 经消息通道交给 Dio 发请求，HTTP 完成后回写 JS 回调并冲刷
  QuickJS 事件循环；全程不在 `evaluate` 内等待 JS Promise，规避运行时重入。
- **同步加密桥**：`utils.crypto` 的 md5 / sha1 / sha256 / HMAC / AES(ECB/CBC + PKCS7) /
  randomBytes 同步委托给 Dart `crypto` / `pointycastle`，用已知向量锁定正确性，
  避免手写 JS 哈希出错或 QuickJS 不支持 BigInt 字面量。
- **未登录也能取流播放**：搜索仍走原生平台，歌曲切到「洛雪」后由已导入插件取直链；
  洛雪音质档位（`128k / 320k / flac / flac24bit / hires / atmos / atmos_plus / master`）
  按插件 `inited.sources[].qualitys` 声明自动裁剪 / 降级。
- **mflac / mgg + ekey 流式解密**：插件返回 ekey 时复用现有 `QmcRelayServer` 本地中继，
  与 QQ / 酷我加密档同一条边下边播通道。

### 🔁 取链失败自动切换音源

- 原生平台整条降级链都取不到链（未登录 / 无会员 / 无版权）时，自动改用洛雪音源补链；
  洛雪模式下插件全部失效时回退原生 QQ。播放页提示「已从 X 源补充」。
- 洛雪插件内部某个取链失败会自动切到下一个声明支持该子源的插件。
- 设置页可关闭「取链失败自动切换音源」。

### 🧩 音源管理：检测更新 + 自动更新

- **导入**：从本地 `.js` 文件（多选）或在线链接导入；URL 导入时该链接同时作为更新地址，
  文件导入可读取脚本头 `@updateURL` 或手动填写。脚本存应用私有目录，元数据存 `sources.json`。
- **检测更新**：抓取更新地址、解析新脚本 `@version`，用与 App 更新检查同规则的
  `SourceVersion.compare` 比较（兼容 `v27` / `261107` / `2.3.6` / `-fixN` 等版本号）。
- **自动更新**：全局开关 + 单源开关；检测到新版本即下载替换脚本、刷新版本号并重载 JS 运行时，
  UI 角标显示「vX → vY」/「已自动更新到 vY」。App 启动后按 30 分钟节流静默检测一次。
- 每个源可单独启用 / 停用、编辑更新地址、删除；导入时给出脚本安全提示。

### 🔬 音源测试页

对每个原生平台跑「搜索 + 取流」探针、对每个已启用插件声明的子源跑「取流」探针，
展示耗时 / 成功失败 / 示例直链，失败原因如实显示，便于判断该换哪个音源。

### 📦 发布合规

- 用户提供的 4 个测试音源**不随工程 / App 分发**：夹具目录加入 `.gitignore`，
  缺失时相关单测自动跳过，CI / 发布 checkout 的全量测试仍全绿。
- Apple 端使用系统 JavaScriptCore 执行用户自行导入的脚本；App 不内置任何音源。
- Android `minSdk` 沿用 `flutter.minSdkVersion`（≥ 21，满足 `flutter_js` 要求）。

### 🛠 构建兼容

- 修复 `flutter_js` 0.8.7 旧 KGP 插件在 AGP 9 下的 Android 构建失败：
  插件声明 `kotlinOptions.jvmTarget=1.8`，而 AGP 把插件模块 Java target 抬到 11，
  Kotlin 的 JVM-target 一致性校验直接判 `:flutter_js:compileReleaseKotlin` 失败。
  现由 `android/gradle.properties` 把该校验降为 warning（本地 / CI 一致），
  CI 打包时同时把插件目标对齐到 11，彻底消除不一致。

### 🧪 测试与质量

- 新增 `lx_runtime_test` / `lx_music_api_test` / `lx_update_test` / `source_fallback_test`：
  真实音源加载与 `inited` 声明、异步请求桥取链、加密已知向量、Buffer / UTF-8 polyfill、
  版本比较、仓库 CRUD、检测 / 自动更新、插件间自动切换、双向兜底、ekey 中继。
- `flutter analyze --no-pub`：No issues found；全量 `flutter test --no-pub`：**1201 项通过**。

## 2.5.6

### 📂 工具箱「本地升频 · 蝰蛇母带」支持自定义保存位置

之前升频产物只能写到应用私有目录 `…/Documents/viper_upscale/`，用户无法
选择输出位置。本版按转码页已有的成熟模式补齐：

- 「输入与参数」里新增 **「保存位置」** 行，点击用系统目录选择器指定输出目录，
  选择后做**写入预检**（建目录 + 写探针文件再删），避免升频到一半才发现不可写
  （Android 11+ 写公共目录需「所有文件访问权限」）。
- 选择结果用 `KvStore` **持久化**，重启 App 后自动恢复；自定义时显示
  **「恢复默认保存位置」**，一键回落到应用私有目录。
- 输出文件命名、去重（同名自动加序号）等逻辑不变。

### 🐛 修复蝰蛇母带播放链路「本地升频失败（引擎异常）」

用户真机反馈：播放页选「蝰蛇母带」时，先弹出「升频完成 · 192 kHz / 24 bit」，
紧接着又弹「本地升频失败（引擎异常），已降级播放原始 320k」。日志里同一首歌
（同一 hash）反复「完成 → 失败」交替，伴随：

```
蝰蛇母带升频完成: 192000Hz/24bit ... 280166444 字节
缓存配额淘汰未执行: PathNotFoundException: Cannot retrieve length of file,
  ... 5edd0fd94ef7e58bcf6f63b8cc0eabb1.wav.src
蝰蛇母带本地升频失败: Bad state: 升频失败: PathNotFoundException:
  Cannot open file, ... 5edd0fd94ef7e58bcf6f63b8cc0eabb1.wav.src.viper48k.wav
```

**两个根因**（均为并发触发同一首歌升频时暴露）：

1. **中间文件路径写死**：解码产物 `inputPath.viper48k.wav` 与写盘半成品
   `outputPath.part` 用固定名。同一首歌被并发触发两次升频时共用这些文件，
   先完成的任务在 `finally` 里删掉，后启动的 isolate 就报
   `Cannot open file ...viper48k.wav`。→ 每次 `upscaleFile` 用
   `时间戳_自增序号` 生成唯一 token，各任务独占中间文件；后缀仍保留
   `.viper48k.wav` / `.part` 以便被正确识别为瞬态文件。
2. **缓存配额淘汰误删中间文件**：`enforceCacheQuota` 把 `*.viper48k.wav`
   （以 `.wav` 结尾）当成「已完成产物」纳入淘汰，且不享受 30 分钟宽限期保护；
   单文件 `length/stat` 撞上并发删除抛异常，还会让整轮淘汰抛
   `PathNotFoundException` 中断（日志里的「淘汰未执行」）。→ 新增
   `isTransientFile` 精确分类：**只有最终产物 `.wav` 参与配额淘汰**，瞬态文件
   仅回收超过宽限期的残留；每个文件的 IO 各自容错，不再互相打断。

### 🧪 测试与验证

- 新增 `isTransientFile` 分类、并发中间文件不被淘汰、陈旧残留仍回收等
  5 项 upscaler 单测；升频页新增「保存位置入口可见 / 默认不显示恢复项」1 项。
- `flutter analyze --no-pub` → **No issues found**；全量测试 **1165 项通过**
  （上一版 1159）。全部离线，用真实临时目录 + 注入缓存根驱动 `enforceCacheQuota`。

## 2.5.5

### 🐛 修复酷狗评论误报「未登录」（错误码 10000）

用户登录态明明有效，发评论却返回「`10000 未登录或登录已失效`」。这不是风控，是**参数 bug**：

- 评论写接口之前用了**写死的固定 `commentMid`**（`1624…019`），但登录 token 是与
  **设备 mid**（`KugouAuth.device().mid`，扫码 / 手动登录都走它）绑定的。两者不一致，
  网关校验 token 时直接判为无效 → `10000`。
- 关键线索：项目里**所有已成功**的登录接口（我的歌单 / 每日推荐 / 取链 / 歌词）用的都是
  设备 mid，唯独评论写接口用了固定常量——同一批 token，前者通、后者 10000，差异只在 mid。
- **修复**：写接口（签名 `key` 与 query 的 `mid`）改用与登录配套的设备 mid；固定
  `commentMid` 常量仅保留给免登录的读评论 / 取 res_id 接口（它们不校验 token↔mid 绑定，
  实测正常）。

### 💬 酷狗评论 60045 = 服务端风控（如实提示，客户端无解）

用户又遇到「`60045 发布失败`」。逆向倾听 5.6.14 确认：

- `60045` 是酷狗对**账号 / 设备级反垃圾（风控）**的笼统拒绝码，**与评论正文无关**——
  正常中文（如「好听」「版权一会有，一会没」）也会被拒。
- 倾听对 60045 **没有任何特殊处理**（不弹验证、不重试），只把服务端 `message`
  透传为「操作失败」。官方酷狗 App 也仅在账号触发风控时弹滑块验证，验证通过后该码即消失。
- 客户端无法绕过，本版把提示从含糊的「敏感词」改为如实说明「被服务端风控拦截，请稍后重试或换账号」。
- 保留客户端轻量预校验（空 / 纯数字 / 含空白），但明确它**不是** 60045 的解法。

### 已知诚实边界

- 酷狗**点赞**协议已逆向但未接入（UI 提示「酷狗暂不支持点赞」）。
- **楼中楼回复列表**只支持发送、不拉取。

## 2.5.4

### 🎧 酷狗音质改用「服务端权威档位」，补齐 360RA / 蝰蛇 HiFi / 杜比双码率

用户反馈「酷狗下载界面的音质不全」+「支持 360RA 的歌曲里看不到 360RA 选项」。根因是 v2.5.2 的音质推导**全靠猜**：酷狗搜索响应里根本没有 `trans_param` 字段，v2.5.2 那套「key 名含 360/mha」的 360RA 启发式**永不命中**，于是 360RA / 蝰蛇 HiFi / 杜比 448k·1500k 这些只在服务端存在的档位一律不展示。

- 服务端真正决定档位的是 `POST goodsmstore/v1/get_res_privilege`（`x-router: media.store.kugou.com`）。新增 `lib/network/kugou/kugou_privilege.dart` 接入该接口，探测请求里的 `quality` 只用服务端认得的代号（**混入 `360ra` / `master_tape` 会整批返回 `error_code 20010` 非法参数**，这类"看起来更全"的写法必须避免）。
- 补建三个此前只在注释里列过、代码里从没建过的枚举：**蝰蛇 HiFi**、**杜比 448k**、**杜比 1500k**；360RA 的 `360ra_l1/l2/l3` 三档统一映射到最高档 `360ra_l3`。
- 下载弹层从 4 档扩到 **10 档**，并新增 `disabled` 能力：高规格档在**未登录**时**置灰**而不是隐藏（此前直接消失，用户完全看不到自己缺什么）。
- 实测（周杰伦《稻香》）：服务端下发 `128 / 320 / flac / high / viper_atmos / viper_tape / viper_clear / viper_hifi` 共 8 档，其中 **`viper_hifi` 是此前完全缺失的一档**。

### 🎬 酷狗 MV 播放源（按上传的 ikun.js 接口实现）

- 新增 `lib/network/mv/kugou_mv.dart`，完整实现 `m.kugou.com/app/i/mv.php`。
- 画质档 `le / sd / hd / sq / rq` 对应 **480p / 720p / 1080p / 1080p / 4K**；同一 `quality` 有多个 `filesize` 时取**文件更大**的那一路。
- `mv_api.dart` 接入 `Source.kugou` 分支；`resolveMvId` 走酷狗缓存——酷狗的 `mid` 是 **29 位 MixSongID**，`int.tryParse` 会溢出，不能复用 QQ 详情查询那套。
- 顺带修掉档位探测的响应解析：酷狗网关个别节点回 `Content-Type: text/html`，Dio 不会自动当 JSON 解析，改为 `ResponseType.plain` + 手动 `jsonDecode`。

### 💬 酷狗评论：查看 + 发表

评论协议逆向自**倾听 5.6.14** 的 APK。

- **读**：`GET m.comment.service.kugou.com/r/v1/rank/{newest,topliked}`，**免登录**。实测最新 19 条 / 最热 20 条（该歌评论总数 471166）。取 `res_id` 要先打 `POST gateway.kugou.com/v3/album_audio/audio`（**必须走 http 而非 https**，https 会 502）。
- **写**：`POST gateway.kugou.com/m.comment.service/p/v1/commentsv3/{add,reply}`，**需登录**。核心突破是逆向出 APK 里 `LGr1.iiii` 的加解密算法（Base64 + 自定义流密码），解出 `iooIi` 的 4 个 lazy salt，并确认写接口是**两层签名**：
  ```
  key       = md5(appid + salt + clientver + clienttime + mid + body)
  signature = md5(salt + sorted('k=v') + body + salt)
  ```
  两套客户端身份：`std` = appid 1005 / clientver 11440 / 网关盐，`lite` = appid 3116 / clientver 10659 / 歌词盐；标准身份被判未登录时自动切概念版重试。
- 实测：读评论通；发评论签名通过，服务端返回 `10000 请登录后发送`——**只剩登录态这一件事**，未登录时 UI 明确提示「请先登录酷狗音乐账号后再发表评论」。
- 已知的诚实边界：酷狗**点赞**协议已逆向但本版**未接入**（UI 上提示「酷狗暂不支持点赞」），**楼中楼回复列表**只支持发送、不拉取。

### 📂 酷狗歌单 / 每日推荐 / 我的歌单

- **推荐歌单**：`www2.kugou.kugou.com/yueku/v9/special/getSpecial`（`is_ajax=1`），排序 `3 热藏 / 5 推荐 / 6 最热 / 7 最新 / 8 飙升`。
- **歌单分类**：同接口 `is_smarty=1`，结构是 `{组名: {id, data:[{id,name}]}}`（组名有主题 / 语种 / 风格 / 年代 / 心情 / 场景六类）。
- **歌单歌曲**：`mobilecdn.kugou.com/api/v3/special/song`，每条带 `hash / 320hash / sqhash / album_audio_id`，正好是取链要的三件套。
- **搜索歌单**：`mobilecdn.kugou.com/api/v3/search/special`。
- **每日推荐**：`gateway.kugou.com/everyday_song_recommend`，每天一批 30 首（含 `hash_320 / hash_flac / mv_hash`），新增「酷狗每日推荐」页，支持播放全部与点播。
- **我的歌单**：`gateway.kugou.com/v7/get_all_list`，需登录。**这个接口的签名盐是「歌词盐」而不是网关盐**（逆自倾听 APK 的 `LeN.iliO`），用错盐服务端一律返回 `error_code 20006 参数验证失败`；body 需带 `userid / token / total_ver / type / page / pagesize`，`x-router: cloudlist.service.kugou.com`。

### 🔀 平台切换改成下拉列表 + 修一个「切了平台没变化」

- 发现页「推荐歌单」与「我的歌单」右侧的平台切换，由平铺标签改为**点击展开平台列表的下拉**（与搜索页的切换器一致）。
- 🐛 **修「切到酷狗还是 QQ 的歌单」**：`hotPlaylistsOf` 的 switch 里漏了酷狗分支，酷狗落到 `default` **静默返回 QQ 数据**。已补 `KugouHot` 与 `HotPlaylist.fromKugou`，同时给 `hotKeywordsOf` 也补上酷狗分支（此前同样回落成 QQ 热搜）。

### 🧪 测试与验证

- 新增 `test/kugou_playlist_test.dart`（**23 项**，全离线）：用真实响应片段驱动推荐 / 搜索 / 每日推荐 / 歌单歌曲 / 我的歌单五套解析，并锁定「我的歌单用歌词盐」这一关键协议约定（含与网关盐结果必须不同的断言）。
- 沙箱端到端实测：推荐歌单 5 条、分类 6 组、歌单歌曲 5/89 首、每日推荐 30 首、搜索歌单 3 条，全部字段（id / 封面 / 歌手 / 曲目数 / 320k·FLAC hash）解析正确。
- `flutter analyze` 零问题；全量测试 **1154 项通过**（上一版 1057 项）。

## 2.5.3

### 🐛 修复真机「本地升频失败，已降级播放原始 320k 音质」

v2.5.2 上线后，Android 真机播放酷狗歌曲时选「蝰蛇母带」必现弹层「本地升频失败，已降级播放原始 320k 音质」。经定位有**两个各自独立、且都足以致命**的根因，均已修复：

- **根因一：ffmpeg 输出格式不被支持（100% 失败）**
  Android 随包内置的是**裁剪版 ffmpeg CLI**（`libffmpeg_exec.so`），构建时以白名单裁剪了能力：
  `MUXERS=wav,flac,ipod,mp4,asf,adts,ac3,eac3,mp3,ogg`、`ENCODERS=pcm_s16le,pcm_s24le,pcm_s32le,flac,aac,wmav2,libmp3lame,libvorbis,ac3,eac3`。
  其中**没有 `s16le` muxer**，而 v2.5.2 的解码步骤用的是 `-f s16le` 导出裸 PCM，真机上必然报
  `Requested output format 's16le' is not known.`，于是每次都走「升频失败 → 降级播放原始 320k」。
  改为 `-f wav` + `-c:a pcm_s16le`（这套白名单下唯一可行的 PCM 输出组合）落临时文件，再从 WAV 里流式取 PCM。
- **根因二：内存峰值约 2.2 GB（即使修好格式也必 OOM）**
  v2.5.2 是整段实现：4 分钟的歌在 192 kHz 档下输出缓冲 703 MB + 归一化缓冲 351 MB，叠加 isolate 消息的深拷贝与 WAV 字节缓冲，峰值接近 **2.2 GB**，而 Android 单进程 heap 只有 256~512 MB。
  改为**全链路流式**：解码产物落磁盘 → 分块读 → 逐帧升频 → 分块写 24bit WAV；isolate 只传路径与参数（几十字节），不再传整段 PCM。
  **实测 4 分钟音频 RSS 峰值 144 MB（基线 124 MB），耗时 16.8 秒**，内存占用与歌曲长度彻底解耦。

- **根因三：升频缓存会把手机存储吃满（升频几首后必然失败）**
  升频产物是 192 kHz / 24 bit / 立体声 WAV，**一首 4 分钟的歌约 264 MB**。升频缓存目录虽已纳入「清理缓存」受管清单，却没有任何容量上限：用户连续升频几首后存储被占满，之后新产物写不落盘（`FileSystemException`）、改名也失败，用户看到的仍是「本地升频失败，已降级播放原始 320k」。
  新增**最旧优先的配额淘汰**（默认 2 GB），每次产出后把缓存目录压回上限内；只删已完成的产物与残留的 `.part`/`.src` 临时文件，正在写入的文件不会被碰。

### 🔧 配套改动

- 新增 `ViperPcmStreamReader` / `ViperWav24Writer`：按块读写 WAV，内存常数级；`finish()` 会把文件裁剪到精确帧数，消掉尾部补零幻听。
- 峰值保护由「整首歌统一乘 headroom/peak」改为**逐样本软拐点**（knee 0.70 → ceiling 0.94）：低于拐点完全透明，只削真正的峰值，且不必为求全局峰值把整首歌在内存里跑两遍。
- 缓存产物改为**先写 `.part` 再原子改名**，避免中途取消/崩溃留下的半成品被当成有效缓存命中。
- 缓存命中不再只看「文件存在」：新增 RIFF/WAVE 魔数与最小长度校验，**损坏的缓存会被删除重算**，避免播放出无声/畸形音频却毫无提示。
- 播放链路失败提示**区分具体原因**（未找到解码引擎 / 音频解码失败 / 内存不足 / 缓存写入失败…），不再是一句笼统的「失败」。

### 🧪 测试与验证

- 新增 `viper_upscaler_test.dart`（17 项）：**流式与整段实现数值一致（最大偏差 < 1e-9）**、分块大小无关性、流式 WAV 读写往返、尾部裁剪、ffmpeg 参数断言（防止再被改回 `s16le`）、WAV 直读路径（48 kHz 立体声 / 44.1 kHz 单声道重采样）、**缓存配额淘汰顺序与 keepPath 保护**、**残留临时文件计入配额**、**损坏缓存识别**。
- 沙箱端到端实测：320k MP3 → 192000 Hz / 24 bit / 2ch WAV，时长精确 5.000 s，主频 440.9 Hz（源 440 Hz），无非有限样本，尾部 RMS 与中段一致（无补零静音）；4 分钟音频内存峰值 144 MB。
- 边界核查：1 / 100 / 2047 / 2048 / 2049 / 4096 帧的极短输入，输出帧数严格等于输入 ×4，无 NaN、无削波，与 v2.5.2 行为逐项一致（非本次回归）。
- `flutter analyze` 零问题；全量测试 1057 项通过，另有 6 项 UI 冒烟/点击测试在 headless 沙箱 1080×2400 视口下因历史遗留 `RenderFlex` 溢出 25px 失败（已用干净树复现，非本次回归，CI 构建流水线不跑 `flutter test`）。

## 2.5.2

### 🔬 找到酷狗「蝰蛇母带」的升频算法，并加入软件

- **反编译实证**：从官方 64 位 APK 解出 `lib/arm64-v8a/libsuperR.so`，导出符号还原出真实链路——`ISuperResolution::Create(samplerate, ModelType)` → `CSuperResolutionMTK` → `SuperResolutionEigen::createHannWindow / stft / istft / getBlockSize / getOverlapSize / specToAudioOverlap / process_audio_to_tensor` → `NeuronModel_* / NeuronExecution_compute`（`com.mediatek.compiled_network`，联发科 NPU）→ `nsSuperResolution::processS16(short* PCM)`。即 **16-bit PCM → Hann 窗 STFT → 频谱张量 → 端侧 DNN 超分 → ISTFT + overlap-add → 96k/192k 24bit**。与官方公开资料一致（2025 MDDC 酷狗 × 联发科「蝰蛇音质 AI 超分音频引擎」，128kbps 重建 16kHz 以上高频至 192kHz/24bit，NPU 推理）。官方弹层里「Hi-Res」「蝰蛇超清 · 至臻母带」都带「**AI升频**」标记，也印证 320k 源文件在本地重建。
- **为什么不能直接搬**：模型权重不在 APK 内（`setModelPath` 运行时下发）、是绑定天玑 NPU 的编译网、SDK 为联发科私有，而本 App 是 Flutter 六端应用。因此按**相同骨架用公开算法同构复刻**，并在代码、UI 与文档中如实标注，绝不冒充官方模型。
- **纯 Dart 升频引擎**（`lib/viper/`）：基 2 迭代 FFT；Hann 窗 STFT（N=2048，hop=1024）；因 `targetRate/48000 == nHigh/nLow`，两个域 bin 频率分辨率相同，低频 bins 原样搬移，24 kHz 以上 bins 用 **SBR / eSBR 频域带宽扩展**重建（子带倍频转置保持谐波结构、谱包络按 4.5 dB/oct 外推整形、确定性相位去相关、谱平坦度驱动的音调/噪声混合、瞬态抑制、32 kHz 起 taper）；叠加「声音焕新」式频响 tilt；一次 ISTFT（N=nLow×ratio）直接出 96k/192k PCM，输出 24-bit WAV（峰值归一 + TPDF 抖动）。**修正了一个真实 DSP 缺陷**：Hann² 在 50% overlap 下不满足常数叠加，改用「Hann 分析窗 + 矩形合成窗 + Σw 归一化」，避免约 33% 的周期性幅度调制。
- **播放链路**：选「蝰蛇母带」时服务端只取 `quality=320` + `HQFileHash` 的 320k 源文件，App 本地重建为 192kHz/24bit WAV 后缓存播放（复用 DTS:X / 360RA / NAC 的 WAV 缓存管线，含切歌世代检查、失败诚实降级回 320k、进度提示）。转换在独立 isolate 中执行，不卡 UI；升频缓存纳入「清理缓存」范围。
- **工具箱**：新增「本地升频 · 蝰蛇母带」页，可把本地任意音频离线升成 96k/192k 24bit WAV（选文件、目标规格、声音焕新开关、引擎状态、进度、输出规格/体积/耗时、复制路径与分享）。页面明确提示 192k WAV 约 1.15 MB/秒（4 分钟约 276 MB）。
- **边界声明**：生成的 24 kHz 以上高频是依据低频信号重建的**感知近似**，不是原始录音中真实存在的信息；下载音质刻意**不含**本地升频档，避免把 320k 文件冒充母带。

### 🎧 酷狗音质档位补全（列表仍只展示歌曲实际有的档位）

- 官方 APK 反编译 + `/v5/url` 实测确认服务端合法 `quality` 代号：`viper_clear` / `viper_atmos` / `viper_tape` / `viper_hifi` / `super` / `dolby` / `dolby2_448k` / `dolby2_1500k` / **`360ra_l1` / `360ra_l2` / `360ra_l3`**（360RA 代号此前未知；`360ra` / `mha1` / `master_tape` 等均返回 `error_code 20010` 非法参数）。
- 新增 5 档：**蝰蛇母带**（本地 AI 升频 192kHz/24bit）、**蝰蛇超清**、**蝰蛇全景声**、**杜比全景声**、**360RA 空间音频**。
- 「只展示歌曲实际有的」按明确信号推导：基础四档看各自 hash；本地升频 / 蝰蛇超清看 320k / FLAC 源文件；蝰蛇全景声与杜比看 `trans_param.hash_multitrack`（真有多轨内容）；360RA 看服务端 MHA1 / 360 显式标记，**未可靠破译 `qualitymap.bits` 完整位语义前宁缺勿滥、绝不常驻**。播放与设置弹层给升频档标注「AI升频」。

### 🔧 修复酷狗无法设置默认音质

- 设置页「播放与音质」区此前只有 QQ / 网易云 / 酷我，补齐**酷狗音乐播放音质**项（含弹层、持久化、`currentKugouQuality` 联动），选择本地升频档时提示首次需转换。

### 🧪 测试与验证

- 新增 `viper_super_resolution_test.dart`（8 项：FFT 往返、Hann COLA、24bit WAV 往返、192k/96k 采样率与时长、低频主频保持、逐周期峰值稳定性回归、宽带信号高频重建能量、取消）、`kugou_quality_v252_test.dart`（8 项：新档位反查、本地升频取链参数、按歌实际能力推导、`trans_param` 双形态、hashFor）、`viper_upscale_page_test.dart`（2 项 build 冒烟）。
- 沙箱端到端实测：2 秒 44.1k 音频 → 192000 Hz / 24 bit / 2ch WAV，ffprobe 校验通过，耗时 0.37 秒。
- `flutter analyze` 零问题；全量测试 1038 项通过，另有 6 项 UI 冒烟/点击测试在 headless 沙箱 1080×2400 视口下因历史遗留 `RenderFlex` 溢出 25px 失败（已用干净树复现，非本次回归，CI 构建流水线不跑 `flutter test`）。

## 2.5.1

### 🐛 修复酷狗无法搜索（签名 salt 抄错）

- **根因**：`gateway.kugou.com` 签名盐值的一个字符顺序抄错（`...092lski2UIkp` → 应为 `...092lksi2UIkp`）。接口 HTTP 200 但返回 `error_code 20006 err signature`、`data.lists` 为空，表现就是「酷狗无法搜索」。已对照 HotDownloader `client.rs` 的 `SALT` 逐字节校正；实测修正后搜索「周杰伦」返回 `total=480` / 20 首，四档 hash 齐全。
- **取链音质参数**：`/v5/url` 的 `quality` 只认 `128 / 320 / flac / high`，此前误用了 filename 后缀 `128kmp3 / 320kmp3`，被判 `error_code 20010`。`KugouQuality.qualityTag` 已改回，并与持久化用的 `id` 明确分离。

### 🔐 新增酷狗登录（对齐 HotDownloader + 倾听 5.6.14，解锁高音质）

- **二维码登录**：`login-user.kugou.com/v2/qrcode` 创建（服务端直接下发二维码 PNG）+ `/v2/get_userinfo_qrcode` 轮询，状态 `1=等待 / 2=已扫 / 4=确认`；登录接口用独立签名盐 `NVPh5oo…`。另有手动填写 `userid / token`（可附设备 `MID / DFID`）通道。
- **设备与会话**：`mid / dfid / dev` 三件套首次生成后持久化并与 token 绑定，`userid / token` 会话支持启动恢复、登录态监听与退出。
- **音质解锁（关键）**：登录凭据随设备参数一起注入 `/v5/url`（`urlKey` 也带真实 userid）。未登录时高音质取链会被服务端判为版权/会员限制（`status:2`），登录后才能拿到无损 FLAC / Hi-Res。签名仍用 gateway 盐，注入后匿名取链实测仍可用。
- **界面**：新增酷狗登录页（扫码 + 手动凭据 + 已登录卡片 + 退出）；设置页账号区新增「酷狗音乐」入口，`isLoggedIn` / 评论页登录分发补齐酷狗来源。

### 🧪 测试

- 新增 `kugou_cipher_test.dart`（9 项：三套 salt 逐字节、签名/urlKey 向量、四档 qualityTag）与 `kugou_auth_test.dart`（18 项：设备持久化、会话、二维码状态映射、PNG 解码、凭据注入），并加酷狗登录页 build 冒烟。
- 沙箱联网实测：二维码创建/轮询打通；注入凭据后匿名取链仍拿到真实直链（义勇军进行曲 `status:1`）。
- `flutter analyze` 零问题；全量测试 1022 项通过，另有 6 项 UI 冒烟/点击测试在 headless 沙箱的 1080×2400 视口下因历史遗留 `RenderFlex` 溢出失败（已验证非本次回归，CI 构建流水线不跑 `flutter test`）。

## 2.5.0

### 🎵 新增酷狗音乐平台（完全对齐 HotDownloader）

- **新音源**：网络层接入酷狗，`player_controller` / `download_manager` / 搜索页 / 播放页与酷我平级镜像，新增 `KugouQuality`（标准 128K / 高清 320K / 无损 FLAC / Hi-Res 四档，含 `FileHash` / `HQFileHash` / `SQFileHash` / `ResFileHash` 多文件音质路由）。
- **接口与签名**：`gateway.kugou.com`（appid=1005）与 `lyrics.kugou.com`（appid=3116）两套公共参数 + 按 key 字母序的 `md5` 签名；取链 `v5/url` 用 `key = md5(hash + URL_KEY_SALT + appid + mid + userid)` 校验，拒绝 `is_free_part==1` 试听片段。
- **KRC 逐字歌词**：去 4 字节头 → base64 → 与 16 字节密钥 XOR → `zlib` 解压，逐字时间轴 + 译文（type=1）+ 罗马音（type=0）全部解析为结构化 `Lyrics`；搜索降级链自动按音质保真度回退取链。
- **品牌绿主题**：平台选择器 / 芯片 / 品牌色统一为酷狗绿 `#1EC17D`，下载与音质弹层复用通用组件。

### 🖼️ 歌词封面获取插件更新（Lyrico-Plugins-3）

- 接入上传压缩包里酷狗封面分支，对齐 `normalizeImage`：`{size}` → `480`、`http:` → `https:`；`cover_url.dart` 的 `candidates()` 新增 `if (song.isKugou)` 分支，与 QQ / 网易云封面同链路。

### ✨ 歌词效果复刻 kunyin（Apple Music 风格）

- **当前行不放大**：`defaultActiveScale` 1.12 → 1.0，当前行字号与相邻行一致，层次只靠文字色建立（非当前 0.4 白 / 当前行未唱 0.6 白 / 逐字已唱纯白 1.0），消除「当前行大一号」撑开行距。
- **平滑滚动锚点居中**：`LyricAnchor.fraction(0.5)`，当前播放行停在视口正中。
- **距离模糊关闭**：`LyricDistanceBlur` maxSigma / sigmaPerLine 降至 0，彻底去掉逐帧高斯模糊（省中端机开销，也避免远处行被糊）。
- **逐字软边擦除**：高亮尾迹柔边加宽（tailFadeWidth 10 → 14），已唱纯白不透明、未唱半透明白做平滑扫光。
- **译文在主词下方**：译文与主词之间留白（translationSpacing=10），保证副文本清晰排在正文之下；间奏呼吸圆点主题化到已唱色。

### 🧪 测试

- 新增 / 改写歌词预设回归：锁定距离模糊关闭、当前行不放大（行过渡恒等）、锚点居中；`AppVersion` 与 `pubspec.yaml` 同步校验。
- `flutter analyze` 零问题；歌词预设单元测试全部通过（另有 6 项依赖真机渲染的 UI 冒烟测试在 headless 沙箱下因 1080×2400 视口 RenderFlex 溢出失败，属环境 / 历史布局问题，非本次回归，CI 构建流水线不跑 `flutter test`）。

## 2.4.11

### 🐛 修复网易云「实际音质严重缺失」

- **根因：v2.4.10 把「按歌曲过滤」做得过头**。网易云搜索与 `/v3/song/detail` 接口都**不返回** `qualities`（歌曲级空间音质标记），`privilege.maxBrLevel` / `playMaxBrLevel` 实测对所有歌曲都是同一个账号上限 `vivid`，无法用于判定歌曲是否拥有某档位。于是 `availableLevelsFrom()` 只能靠 `l/m/h/sq/hr` 文件对象，把 9 档砍成 3~4 档：臻音全景声 / 杜比全景声 / 超清母带 / 沉浸环绕 / 高清环绕 **5 档全部消失**，`hr` 对象缺失时连 Hi-Res 也不见。
- **基础档改为「歌曲真实码率」并集**：`l/m/h/sq/hr` 文件对象 ∪ `privilege.chargeInfoList` 的 `rate`（服务端列出的歌曲可用码率 128k/192k/320k/999k/1999k）∪ `maxbr` 数值兜底，三者取并集；任一来源缺失都不会再漏掉无损 / Hi-Res。账号等级字段仍一概不读，三首音质不同的歌依然给出不同档位。
- **空间 / 母带档改为常驻**：`jyeffect` / `sky` / `jymaster` / `dolby` / `vivid` 本质是**播放等级档**——网易云服务端在歌曲没有对应内容时会自动向下匹配可用流，官方客户端也是常驻显示、按 VIP 权限灰置，并不按歌曲隐藏。新增 `NeteaseQuality.alwaysAvailable` 与 `filterQualityOptions` 的 `alwaysShow` 参数，播放页下载 / 播放音质、搜索页下载三处弹层只对网易云启用常驻；QQ / 酷我保持严格按歌曲过滤，行为不变。
- **口径**：基础档仍按歌曲实际拥有的码率文件过滤（没有 Hi-Res 就不显示 Hi-Res），空间 / 母带档常驻；无标记或旧数据回退全量，保证弹层永远有可选项。

### 🧪 测试

- 用本次抓取的真实 `cloudsearch/pc` / `/v3/song/detail` 响应片段补回归：晴天 4 档、渡口 3 档、`chargeInfoList` 补出 Hi-Res、`maxbr` 补出无损、账号等级字段不干扰、`alwaysShow` 只影响网易云且保持原顺序。
- `flutter analyze` 零问题；全量测试 994 → **999 项全绿**（音质可用性 24 → 29 项）。

## 2.4.10

### 🐛 修复音质列表「每首歌都一样、显示的不是歌曲真实拥有的音质」

- **根因一：网易云取错了字段**。v2.4.9 用 `privilege.playMaxBrLevel` / `maxBrLevel` 判定音质，但这两个是**用户可播等级**（搜索接口里 `maxBrLevel` 也常被填成账号等级）。实测三首音质完全不同的歌都返回 `vivid`，于是每首歌都解析出同一套 `{标准, 极高, 无损, Hi-Res, 臻音全景声}`，还虚报歌曲根本没有的 Hi-Res / 全景声。改为按歌曲自身的**文件对象** `l/m/h/sq/hr` 判定（有该对象即服务端存在对应码率的文件，与账号身份无关），兼容开放平台 `qualities` 对象与老版 `lMusic/hMusic/...` 字段；仅在文件对象全缺失时用 `privilege.maxbr` 数值兜底，且不再虚报空间 / 母带档。
- **根因二：很多入口的 `Song` 没带音质标记**。网易云专辑接口补齐专辑名时重新 `Song(...)` 构造，把已解析的 `qualityCodes` 丢了；歌单、分享歌单等接口构造的 `Song` 本来就没有；升级前持久化的历史 / 收藏 / 歌单也没有该字段。空集合触发 `filterQualityOptions` 回退全量，三平台看起来都「每首歌都一样」。
- **按需补全**：新增 `MusicApi.ensureQualityCodes()`，在打开音质弹层时对缺标记的歌曲按平台查一次详情（QQ `get_song_detail_yqq` 的 `file`、网易云 `/api/v3/song/detail` 的 `l/m/h/sq/hr`、酷我 `songInfo(rid)` 的 `N_MINFO`），成功后刷新弹层选项，结果带进程内缓存；失败静默保留全量回退，不会比现在更差。网易云专辑补齐改用 `copyWith`，不再丢标记。
- **口径**：按用户选择，展示「歌曲实际存在该音质文件」的档位，即使当前账号没会员也列出（点了再提示权限），不再用账号等级裁剪列表。

### 🧪 测试

- 用真实接口响应片段重写网易云音质用例：三首同名「晴天」按 `l/m/h/sq/hr` 解析出**不同**档位、账号等级字段不干扰结果、`/v3/song/detail` 无 `privilege` 也能解析、`qualities` 明确标记才显示空间档、老字段兼容、`maxbr` 数值兜底、专辑 `copyWith` 保留标记。
- `flutter analyze` 零问题；全量测试 986 → **994 项全绿**。

## 2.4.9

### 🐛 修复安卓端「引擎已找到但转码报错」

- **根因**：v2.4.8 随 APK 打包的是 **static-PIE**（`ET_DYN` 但没有 `PT_INTERP`）的 ffmpeg。Android 10+ 对 `untrusted_app` 的 `execve` 有 W^X / SELinux / seccomp 限制，无 INTERP 的静态 PIE 在真机上很容易被拒绝执行——表现为「文件探测到了，开始转码却失败」。官方支持的形态是**动态 PIE**（`ET_DYN` + `/system/bin/linker64`）。
- **引擎换成动态 PIE**：同一份 FFmpeg 7.1.3 源码与组件白名单，链接方式由 `-static-pie` 改为 `-pie`，产物带 `PT_INTERP`；第三方库（lame / libogg / libvorbis）仍静态链接进二进制，只依赖系统 `libc.so` / `libm.so`，**无需 `LD_LIBRARY_PATH`**。三 ABI 重新交叉编译并托管到 `libs-ffmpeg-v2` release，`tools/build-android-ffmpeg.sh` 默认改为 `dyn` 模式，Gradle 下载项与 MD5 同步更新。
- **引擎自检与完整错误**：页面探测到引擎后实际跑一次 `ffmpeg -version`，「转码引擎」卡片直接显示自检结果；`_runFfmpeg` 失败时保留退出码、完整输出路径与 stderr 末尾数行，不再只给一句模糊提示。
- **保存位置导致的写入失败**：`file_picker.getDirectoryPath()` 在 Android 11+ 返回公共目录路径，写公共目录需要 `MANAGE_EXTERNAL_STORAGE`（「所有文件访问权限」）；旧版既不做权限检查也不做写入预检，且默认输出落在应用私有目录里、用户找不到产物。

### ✨ 自定义转码保存位置

- 「保存位置」支持 **应用目录 / 公共音乐 / 自定义** 三种模式一键切换；自定义可选文件夹或直接输入绝对路径（目录选择器在部分 Android 文件管理器上不可用时兜底）。
- 选择会**持久化**（`KvStore`），下次打开页面自动沿用，不再每次重置。
- 切换与开始转码前都做**写入预检**（创建目录 + 写探针文件），不可写时给出可操作指引；公共目录会自动申请「所有文件访问权限」。
- 转码完成后任务项显示**完整输出路径**并可一键复制；「保存位置」卡片也可复制当前目录。

### ✨ 音质列表按歌曲实际有的音质展示

- 播放页「下载音质」「切换音质」、搜索页「下载」弹层，现在只列出这首歌**实际拥有**的档位，没有的档位隐藏；设置页的**全局默认音质**仍保持全量（没有歌曲上下文）。
- `Song` 新增 `qualityCodes`（随 JSON 持久化，兼容旧数据）。三个音源各自从搜索 / 详情接口解析，**零额外网络请求**：
  - **QQ 音乐**：`track_info.file` 的 `size_128mp3` / `size_320mp3` / `size_flac` / `size_hires` / `size_dts` / `size_dolby` / `size_360ra` / `size_*aac` / `size_*ogg` 与 `size_new` 位图（臻品母带 / 臻品音质 2.0 / 全景声 5.1 / OGG320 / 黑胶 / OGG640 / 全景声 7.1 / NAC / DTS:X），覆盖全部 25 档。
  - **网易云**：`privilege.playMaxBrLevel`（回退 `maxBrLevel` / `flLevel` / `plLevel`）+ `sq` / `hr` 标记按 level 等级过滤；特殊空间 / 母带档位只在服务端明确标为该 level 时显示，避免虚报。
  - **酷我**：复用搜索结果 `N_MINFO` 已解析出的 `KuwoSong.qualities`。
- 接口未给音质标记或旧持久化数据 → 回退全量档位，保证弹层永远有可选项；过滤结果为空时同样回退。

### 🧪 测试

- 新增 16 项离线测试（QQ / 网易云 / 酷我音质标记解析、`filterQualityOptions` 过滤与回退、`Song.qualityCodes` 序列化与 `copyWith`），用真实接口响应片段驱动，不联网。
- `flutter analyze` 零问题；全量测试 970 → **986 项全绿**。`libs-ffmpeg-v2` 三个 jar 匿名下载 MD5 校验通过。

## 2.4.8

### ✨ Android 端音频转码内置引擎（修复「安卓端没有探测到」）

- **根因**：v2.4.7 的转码页在 Android 上显示「未找到 ffmpeg」并非探测逻辑写错——APK 内只有 media_kit / libmpv 的**纯解码白名单 ffmpeg**（`--disable-muxers --disable-encoders --disable-programs`），没有编码器 / muxer / 命令行，产不出文件；而 Android 10+ 的 W^X 限制又禁止从应用数据目录 `execve`，页面里「手动选择 ffmpeg」在真机上基本无效。
- **内置裁剪版静态 ffmpeg**：用 NDK 28.2.13676358 交叉编译 FFmpeg 7.1.3 + lame 3.100（LGPL-2.1）+ libogg 1.3.5 + libvorbis 1.3.7（BSD），`--disable-everything` 白名单只启用转码所需的 demuxer / decoder / encoder / muxer / filter（10 种输出：WAV / FLAC / M4A / MP4 / WMA / AAC / AC-3 / E-AC-3 / MP3 / OGG），**未启用任何 GPL 组件**。产物为 static-PIE、无动态库依赖、API 24+，三 ABI（arm64-v8a / armeabi-v7a / x86_64）各 4.5–5.6MB。编译脚本固化为 `tools/build-android-ffmpeg.sh`，可复现。
- **随包与下载**：二进制按现有 media-kit 约定打成 `lib/<abi>/libffmpeg_exec.so` jar，托管在 `libs-ffmpeg-v1` release；构建期由 `third_party/media_kit_libs_android_audio/android/build.gradle` 的 `downloadDependencies` 下载并做 MD5 校验，不往仓库塞二进制。
- **可执行性**：`build.gradle.kts` 打开 `packaging.jniLibs.useLegacyPackaging = true`，Manifest 同步 `android:extractNativeLibs="true"`，安装时系统把 `.so` 释放到 `nativeLibraryDir` 并授予执行权限——这是 Android 10+ 允许执行随包二进制的位置。
- **探测链**：`MainActivity` 新增 `baiji/native` 通道返回 `applicationInfo.nativeLibraryDir`，`FfmpegLocator` 增加可注入 `extraCandidates`，顺序为「手动指定 / `BAIJI_FFMPEG` → **Android 内置引擎** → 随包 `bin` → 系统 PATH」。

### 🐛 解绑特殊格式对 ffmpeg 的硬依赖

- v2.4.7 里 DTS:X / 360RA / NAC 转 WAV 走自研 FFI 解码器 `decodeLocalToWav()`，**本来就不需要 ffmpeg**，但 `_start()` 的前置硬校验和 `AudioTranscoder` 必填的 `ffmpegPath` 把这条唯一能在 Android 上跑的能力也挡住了。现在 `ffmpegPath` 可空，只在真正需要 ffmpeg（普通格式、或自定义声道 / 采样率 / 位深需二次 PCM 变换）时才校验；页面去掉前置拦截，UI 区分「内置引擎可用 / 需手动指定」。
- 附带确认：DTS 许可、360RA BRIR 系数、NAC 模型全部来自 APK 内置 assets（`rootBundle`），本地文件转码全程离线、不联网。

### 🧪 测试与验证

- 新增 10 项离线测试：`Android nativeLibraryDir` 探测优先级、内置引擎缺失时的回退、手动路径仍优先、**解绑后 `ffmpegPath=null` 时 DTS / 360RA / NAC 直出标准 RIFF/WAVE s16 PCM WAV（断言 fmt chunk 与 PCM 非静音）**、解码器不可用时精确报错、缺引擎时自定义参数提前拒绝、普通格式缺引擎的可操作提示。`flutter analyze` 零问题，全量 `flutter test` **970 项**通过。
- 沙箱用 `qemu-aarch64-static` 跑真编译出的 Android 引擎：ffmpeg 7.1.3、10 个编码器与 10 个 muxer 齐全，用生产代码 `buildFfmpegArgs()` 生成的命令真实转出 10 种格式，`ffprobe` 可读、PCM 非静音（可播放）、自定义参数与 `-progress` 回调正常，**12/12 通过**（不进 CI，避免 runner 环境差异导致 flaky）。
- 需真机确认的部分：DTS:X / 360RA / NAC 三个自研解码器仅在 Android、对应 ABI、官方 glue 库与许可齐备时可用（`isSupported`），沙箱是 Linux x86_64 无法跑真实 FFI 解码；这一层需在 arm64 真机上验证。

## 2.4.7

### ✨ 新功能

- **音频转码（工具箱）**：新增「工具箱 → 音乐工具 → 音频转码」页面，支持 WAV / FLAC / M4A / MP4 / WMA / AAC / AC-3 / E-AC-3 / MP3 / OGG 十种输出格式，可自定义声道数（1–8）、采样率（8k–384k Hz）、位深（16 / 24 / 32 bit）、码率（32–1411 kbps）。支持批量选文件 / 选文件夹、逐任务进度条、随时停止；同名产物自动追加 `(2)/(3)`，不覆盖已有文件。核心服务层 `lib/core/audio_transcoder.dart` 负责参数校验、ffmpeg 命令构造（显式 `-f` 容器 + `-progress pipe:1` 进度解析）、可执行文件探测（页面手动指定 / 环境变量 `BAIJI_FFMPEG` → 随包内置 `bin` → 系统 PATH）、失败与半成品清理。
- **关于「内置 ffmpeg」**：播放链路（media_kit / libmpv）内嵌的 ffmpeg 是 `--disable-muxers --disable-encoders --disable-programs` 的纯解码白名单构建，能解几乎所有音质（含 `ac3` / `eac3` / `av3a` / `ac4` / `dca`），但**没有音频编码器、没有 muxer、没有命令行**，无法产出文件。因此转码调用标准 ffmpeg 可执行文件，桌面端通常直接命中系统 PATH，移动端可在页面手动选择或用 `BAIJI_FFMPEG` 指定；找不到时明确报错，不再静默失败。
- **特殊音质转码**：DTS:X、索尼 360RA、NAC、AV3A 按产品约束**只能输出 WAV**（选其它格式自动锁定）。前三者通过新增的 `decodeLocalToWav()` 复用与在线播放同一套 FFI，走 App 自研原生解码器直接产出 PCM WAV；AV3A 由 ffmpeg 解码成 WAV（当前 ffmpeg 无 `av3a` 解码器时给出可操作提示）。特殊格式靠扩展名 + 文件头 / 尾部 fourcc 魔数（`dtsx` / `mha1` / `mhm1` / `av3a` / `ac-3` / `ec-3`）+ 下载文件名音质标记识别；mp4、ac3、eac3 等 ffmpeg 可解格式既可作输入也可作输出。若对特殊格式额外指定声道 / 采样率，会在解码出的 WAV 上再跑一次 ffmpeg 做 PCM 变换。

### 🐛 修复（CI 两个 bug）

- **重试循环吞掉失败**：Android 构建的 3 次重试写法在三次全失败时，循环最后一条命令是 `sleep`，步骤仍可能以 0 退出，导致「构建失败却标记成功」，后续签名 / 重命名步骤拿到不存在的 APK 才炸。改为 `set -e` + 显式 `built` 标志，循环结束检查 `built != 1` 就 `exit 1`，并用 `find build/app/outputs -name "*.apk"` 兜底校验产物真实存在。
- **注释里的失败根因写错**：把首次 Android 失败的注释从「NDK 28.2 不在 runner 预装列表」更正为 CI 日志实测根因——`:gradle:compileKotlin` 解析 `kotlinBuildToolsApiClasspath` 时下载 `kotlin-compiler-embeddable-2.2.21.jar` 被 GitHub Releases 返回 504 Gateway Time-out，属于大依赖下载瞬时抖动，与原生代码 / NDK 无关。显式安装 NDK 保留为减少不确定性的措施，重试用于抵御这类抖动。

### 🧪 测试

- 新增 `test/audio_transcoder_test.dart`（36 项离线）；沙箱用真实 ffmpeg 端到端验证 10 种输出格式均能产出、ffprobe 可读、解码成 PCM 后非静音（可播放）、进度回调正常、同名不覆盖；`flutter analyze` 零问题，全量 `flutter test` **960 项**通过（原 924 + 36）。

## 2.4.6

### 🐛 修复

- **切换音质后播放进度从头开始（全平台）**：音质切换、自动降级、baka 解码器重试等重开播放的场景下，续播位置会丢失、从头播放。根因是 media_kit 的 `open()` 内部先 `stop()`（把 `position` 归零）再异步 `loadlist` 加载新轨道，`open()` 返回时轨道尚未 demux 完成，此时紧接发出的 `seek` 命令会被 libmpv 丢弃。修复：改用 `open(play:false)` 先挂载轨道，等 `duration` 就绪（轨道已可读，最长等 5 秒）后再 `seek` 续播位置，最后才 `play()` 正式发声；切换前的位置作为 `resumeAt` 透传给取流链路，不同音质时长超界时夹到末尾，避免直接跳到 EOF。

### 🔧 构建

- **Android CI 构建偶发失败**：构建前显式用 `sdkmanager` 安装 `ndk;28.2.13676358`（`flutter.ndkVersion` 默认值，GitHub `ubuntu-latest` runner 预装不含），并给 `flutter build apk` 加最多 3 次重试，避免依赖 AGP 静默自动下载大依赖时的瞬时抖动。

### 📖 文档

- README 版本速览补齐 v2.4.3–v2.4.6，测试数量同步为 924 项。

## 2.4.5

### 🚀 解码器提速（DTS / 360RA / NAC）

- **DTS**：去掉整曲解码时的 `tmpfile()` 磁盘中转，循环内直接把 float 平面数据转 s16 交错写入 WAV，省去一整趟约 60~70MB 的磁盘读写，并把每样本一次 `fwrite` 降为每帧一次。
- **NAC（TL01 神经音频）**：MNN 推理线程数从写死 4 改为按设备在线 CPU 核数自适应（封顶 8、保底 2），多核设备显著加速推理吞吐。
- **360RA（索尼）**：新增 256KB 输出缓冲，把 SDK 每帧约 8KB 的回写攒批落盘，大幅减少写 syscall。

### 🐛 修复

- **网易云登录歌单只显示 10 首**：改用 v6 歌单详情接口取完整 `trackIds` 与 `trackCount`，再分批（每批 100）调歌曲详情接口补齐，按 id 顺序还原，解决大歌单被老接口 10 首预览截断的问题。
- **360RA WAV 头错位**：解码结尾回填真实 WAV 头前补 `fseek(0)`，避免真头被写到 PCM 数据之后、播放器读到 0 字节数据。

## 2.4.4

### 🐛 修复静态代码审查报告中的崩溃与资源泄漏

- **封面地址空值崩溃**：`CoverUrl.primary()` 在歌曲无可用封面时改为返回空串，不再因 `.first` 抛 `StateError`
- **脏数据解析崩溃**：`Song.fromTrack()` 对 `mid / name / singer` 等非字符串字段做容错；`singer` 为非数组类型时不再因 `as List` 抛 `TypeError`
- **播放器订阅泄漏**：`PlayerController._ensurePlayer()` 的 6 个 media_kit 原生流订阅统一登记并在 `release()` 时取消；`release()` 改为只释放底层播放器、不关闭常驻广播流（保证播放器可重建复用），新增 `dispose()` 负责终态清理
- **下载任务注册表**：`DownloadTaskRegistry` 新增幂等 `dispose()`，关闭任务变更广播流
- **网络解析加固**：QQ / 网易云 / 酷我热搜与歌单解析对脏 JSON（非 `Map` 元素）做类型守卫，单条脏数据不再导致整个列表失败
- **其它**：设置页文件选择由 `.single` 改为 `.first`（防多选抛 `StateError`）；移除 `device_manager` 中未调用的调试死代码

## 2.4.3

### 🎬 新增 MV 播放（三平台：QQ 音乐 / 网易云 / 酷我）

播放页顶栏新增 MV 按钮（本地歌曲不显示，桌面端暂不支持），打开时自动暂停音乐：
- **QQ 音乐**：`GetMvUrls` 接口按 vid 取流，支持 360p–4k 多档画质（实测同一 MV 各档
  可用性不同，自动落在 ≤ 请求档的最高可用档），多 CDN 备用地址
- **网易云**：`/weapi/song/enhance/play/mv/url`（weapi 加密，登录后可看部分 VIP MV），
  r 参数指定分辨率；MV id 由歌曲详情现查
- **酷我**：`playUrl?type=mv` 关联 MV 直链（实测可播）；有 vid 时走 anymatch 接口
  指定画质档（MP4L→MP4BD）

技术要点：
- **本地防盗链中继**：三平台 MV CDN 都校验 Referer/UA，WebView 拿不到自定义请求头，
  故 `<video>` 指向 `127.0.0.1` 中继注入头；Range 透传（206）保证进度条拖动可用
- **播放实现选 WebView**（HTML5 `<video>`）而非 media_kit：换 `media_kit_libs_video`
  会顶掉自编译的 AC-4 补丁库（杜比全景声音质依赖），MV 不能牺牲音乐功能；
  webview_flutter 本就是现有依赖，覆盖 Android / iOS / macOS，桌面端隐藏入口
- mvId 持久化进 Song 模型；旧数据（历史/歌单）无 mvId 时点按钮现查详情兜底
  （QQ song detail / 网易 v3 song detail / 酷我按 rid 播放本就不需要）

端到端实测（发布前）：QQ 晴天 MV（720p 源 59.6MB）、网易云光年之外 MV（1080p
82.8MB）、酷我晴天关联 MV（25.4MB）三平台全部取源成功，Range 拉流均 206。

### 其他

- `webview_flutter_android` 升为直接依赖（MV 页自动播放手势开关需要其平台 API）

## 2.4.2-pre13

### 🐛 修复 NAC 音质档在真机上从不生效（pre12 回归）

pre12 里 NAC 虽然随包了模型与推理库，但实际选播 TL01 档时会**静默降级**到下一个音质，
用户拿到手的不是 NAC。根因在能力探测：

`nacglue_abi_available()` 原先通过环境变量 `NAC_MODEL_PATH` 找模型。这个变量只在
QEMU 测试时才有，**App 进程里从来没被设置**，于是探测恒为 0 → `isSupported = false`
→ `decodeToWav` 直接返回 null → 走降级链。不崩溃、不报错，但功能完全失效。

修复：

- `nacglue_abi_available()` 只验证「引擎可用」——`libMNN_dl.so` 能加载、所需符号齐全，
  **不碰模型、不读环境变量**（与 DTS:X / 360RA 的探测语义一致）
- 模型加载回归正轨：`nacglue_init(modelPath)` 在真正解码时由 Dart 传入解包后的真实路径
- 新增 `nacglue_probe(modelPath)`：给工具/测试用的完整自检（模型 + 零输入推理烟测）

符号绑定抽出为 `mnnBind()`，`init` 与探测共用，避免两处逻辑漂移。

### 实测

| 场景 | 结果 |
|---|---|
| 无环境变量 + 模型在位（真机真实情况） | `abi_available` = **1**，全曲解码 260.63s 正常 |
| 模型文件不存在 / 被截断 / 是随机垃圾 / 路径是目录 | 一律返回 `-3`，**不崩溃**，走降级链 |
| `nacglue_init(NULL)` | 返回 `-1` |
| 修复前后解码输出 | MD5 完全一致（`0f911f26…`），相关性 1.0 |

### 📝 注意

NAC 依赖的 `libMNN_dl.so` 与模型 `7187332.mnn` **缺一不可**，二者都随包分发。
任一不可用时 App 会沿音质降级链自动绕开，不会崩溃或报错。

---

## 2.4.2-pre12

> 预发布版：新增 NAC（TL01）神经音频编解码音质档。

### 🧠 NAC 神经音频解码（TL01，全新档位）

QQ 音乐自研 Neural Audio Codec：码流里存的不是 PCM 也不是频域数据，而是
**矢量量化码字（codes）**，必须经神经网络模型前向推理重建复数频谱，
再由 ISTFT 还原波形。新增自研原生管线（`nac_glue`）：

- **容器解析**：108B 头（含 JSON 元数据）+ N 段 × stride
- **codes 解包**：LSB-first 连续位流，每码 10 bit，
  读取序 `[ch][frame][cb]` → 存储序 `[ch][cb][frame]`（需转置）
- **MNN 推理**：运行时 dlopen 官方 `libMNN_dl.so`（arm64，Apache-2.0），
  输入 `codes(2,22,32)` int32 + 6 个流式 buffer（逐段回灌状态）
- **ISTFT**：Hann(512) / hop 256 / 重叠相加归一化，输出
  44.1kHz / 16-bit / 立体声 WAV
- **模型内置**：`quantizer_decoder_cb22_hardswish_1113_N3_fp16_2_2_34_257.mnn`
  （1.2MB，随包分发，无需服务端下发）

实测全曲 260.63s 解码零错误，输出与官方解码器逐比特一致。

## 2.4.2-pre11

> 预发布版：新增索尼 360RA 与黑胶 VIP 两个高端音质档。

### 🎵 索尼 360RA（RA01-04，全新档位）

与索尼合作的空间音频档位：服务端下发 MHA1 容器的 MPEG-H 3D Audio 流，
本机无通用解码器，新增原生解码管线（`ra360_glue` + 官方
`qm_native_decoder_360ra.so`）：

- **官方解码内核**：QQ 音乐 CDN 同源 decoder（arm64-v8a，MD5 锚定于
  QQ 音乐内置 `so_info.json`），依赖库随包内置
- **标准 BRIR 系数自动部署**：内置 Sony SAL SDK 官方资产 riff，按
  RIFF→BRIR→`h13 ` 语义提取 `hrtf13.hki` 并生成 config（首次播放
  解包一次，全程离线）
- **Binaural 输出**：48kHz / 32-bit int / 双声道 WAV 缓存，与官方
  播放内核渲染结果一致
- 仿 DT03 管线的完整体验：取流频控等待、缓存直通、解码失败自动
  沿降级链切换；非 arm64 设备自动绕开该档
- 全链路已在 arm64 QEMU 完成全曲验证（259s 曲目、零错误、时长与
  源精确吻合）

### 🎵 黑胶 VIP（V0M0，全新档位）

24bit 高解析 mflac 档，与母带/无损同走 ekey + 本地流式解密中继，
播放、下载两侧直接可用，无额外等待。

### 📦 下载侧

360RA 档位的原始 MHA1 mp4 本地不可播，下载侧自动替换为最近的
杜比全景声档（与 DTS:X 同策略）；黑胶 VIP 经解密中继正常下载。

## 2.4.2-pre10

> 预发布版：修复 DTS:X「转码成功但播出来是降级档」的并发竞态。

### 🐛 DTS:X 并发竞态修复

真机复现：首次点播 DT03 后「下载 + 全曲解码」需约 10 秒，期间 UI 无
进度反馈，用户再次点播会触发第二条取流 —— 第二条的 DT03 取流被腾讯
频控返回空 URL，全链降级先播了臻品全景声（Q003）；首次解码完成后其
播放回调又与降级播放交叉 open，最终用户听到的是降级档而非 DTS。
三处修复：

- **同曲解码任务复用**：同 key 的并发解码请求复用同一 Future，
  重复点播安静等待首次解码完成，不再各自下载/解码/回调播放
- **取流世代号**：长等待（解码 10 秒）返回后校验世代号，过期请求
  静默作废（返回哨兵 URL，调用方识别后不跳歌不报错），保证最新
  请求唯一生效，消除双 open 互踩
- **DT03 缓存直通 + 频控等待**：取流之前先查本地解码缓存（复播/
  重试零取流、零等待）；取流被频控打空且同曲解码已在进行时，等待
  解码结果而不是急着降级
- 解码发起时向 UI 提示「转码中，首次约需 10 秒…」，减少重复点击

## 2.4.2-pre9

> 预发布版：修复 pre8 的 DTS:X 真机探测失败（自动降级）问题。

### 🐛 DTS:X 真机降级修复

真机（arm64-v8a）上 DT03 档位被运行时探测直接跳过，降级到下一档。
根因是**打包问题**（解码链路本身在 QEMU 已全曲验证通过），共三处：

- **jniLibs 文件名缺 `lib` 前缀**：官方 so 以 CDN 原名 `DTSPlaybackSDK.so`
  放入 jniLibs，AGP 原样打包，运行时 `dlopen("libDTSPlaybackSDK.so")`
  找不到文件 → 改名 `libDTSPlaybackSDK.so`
- **许可文件放错 assets 体系**：`dts_hpx.lic` / `dts_config.yaml` 放在
  Android 原生 assets 且 pubspec 未声明，`rootBundle` 无法读取 →
  移至项目根 `assets/dts/` 并在 pubspec 声明
- **探测失败无细节**：新增 `dtsglue_probe_detail()` 把 native 侧
  `dlerror` 文本透传到 Dart 日志，后续排障不再盲猜

## 2.4.2-pre8

> 预发布版：**QQ 音乐「臻品 DTS:X」（DT03）解码支持**。

### 🎧 臻品 DTS:X 解码（原生 dts_glue 模块）

- 集成 **DTS 官方 Playback SDK**（QQ 音乐同款解码内核，CDN 下发库，
  arm64-v8a / armeabi-v7a 双 ABI，MD5 与官方 so_info.json 锚定）
- 新增原生模块 `dts_glue`（单 C 文件）：dlopen SDK → 注入 DSEC 许可
  （有效期至 2033）→ 自实现 MP4 demux 提取 `dtsx` 轨（支持 co64 /
  变长 stsz / 多轨 fourcc 匹配）→ `DTSPlayback_DecodeDTS` 循环 → WAV
- **双 ABI QEMU 逆向验证**：arm64 与 v7a 均完成全曲解码（12847 帧
  0 失败，输出 274.07s @48kHz，与容器元数据吻合；两 ABI 输出逐帧一致）
- C API 签名从 SDK 官方 JNI 封装反汇编还原（InitialiseDTS 的
  ctx 槽语义 / InstallLicense 三参 / LoadConfiguration 带 len）
- Dart FFI 直调（无 JNI 桥），解码在后台 Isolate 秒级完成，
  WAV 缓存到应用缓存目录，**二次播放零等待**
- 播放链路：选 DT03 档自动走「下载 mp4 → 原生解码 → 播放 WAV」，
  失败或不可用沿音质降级链自动回落（SQ 无损 → …）
- x86 系列无官方解码库，运行时探测自动跳过 DT03 档

## 2.4.2-pre7

> 预发布版：**网易云「臻音全景声」（Audio Vivid / AVS3-P3）解码支持**。

### 🎧 臻音全景声解码（原生库 v6）

- 集成 **AVS3-P3 参考解码器**（UWA 参考软件 RMv3.3.1，C 语言）为
  `libavs3a.a`，经 ffmpeg wrapper 注册为 `av3a` 解码器（四 ABI 全编入）
- NN 声码模型已内嵌进库（无外部 model.bin 依赖），无文件 IO
- 宿主实测：解码真实网易云臻音全景声文件（MP4 封装 av3a、44.1kHz
  12 声道 7.1.4）12289 帧 0 错误，x86 约 9.5x 实时；输出与参考
  命令行解码器逐样本等价（RMS 差异 0.000%，相关 0.99996）
- ffmpeg 补丁：`AV_CODEC_ID_AV3A` codec id、MP4 `'av3a'` fourcc
  识别、`ff_av3a_decoder` 注册（与 ac4/ac4_baka 共存互不影响）

### 🎵 网易云「臻音全景声」音质档

- 新增 `vivid` 音质档（臻音全景声）：接口实测直接请求 `level=vivid`
  即可取流（请求杜比全景声时歌曲无杜比内容也会自动返回该格式）
- 音质列表、下载、实际生效展示自动跟随（`type=av3a` / 832kbps）
- 播放器运行时探测新增 av3a 解码器上报（链路日志显示
  `codec=av3a 解码器=av3a ...`）


## 2.4.2-pre6

> 预发布版：**AC-4 双解码器共存** + 播放链路日志 + 上报带 IP。

### 🔊 AC-4 双解码器（原生库 v5）

- 编入 **baka-ac4**（纯 Rust 的 AC-4 解码器）作为第二解码器，与 Jellyfin
  移植版共存（`ac4` 默认 / `ac4_baka` 备用，同 codec id 类似 aac/aac_fixed）
- 宿主实测 Baka 版完整解码真实酷我 AC-4 文件（3701 帧 0 错误）
- 播放侧：jellyfin 版解码报错时**自动切 baka 重放**，都失败才降音质

### 📝 播放链路日志

- 每次开播在日志里记录**实际解码器**（mpv decoder-desc）、codec、
  采样率 / 声道数与音频输出后端（audiotrack / opensles）——排查音质
  与解码问题不再靠猜

### 📊 上报带 IP

- 行为上报（upload.php）的批量 payload 新增 `ip` 字段（客户端公网 IP，
  ipify 查询失败时留空，PHP 端仍可用 REMOTE_ADDR 兜底）

## 2.4.2-pre5

> 预发布版：**AC-4 最后一环修复**（播放内核防误伤）。

### 🔊 杜比全景声不再被自动切走

- pre4 的日志实锤了最后一环问题：运行时探测已确认本机有 AC-4 解码器
  （日志「运行时探测 AC-4 解码器: true」），但当初为官方库设计的
  「发现 AC-4 音轨就自动降级」的保险**还在拦截正常播放**——表现即
  「选杜比全景声每次都被自动切换到别的音质」
- 现已让该保险在探测成功后自动短路；仅当解码器真正报错时才降级兜底

## 2.4.2-pre4

> 预发布版：**AC-4 修复**（原生库 v4 + 运行时探测）。

### 🔊 原生库 v4：AC-4 解码器真正可用

- 根因一：v3 用的 Jellyfin 6.0 分支 AC-4 补丁是**早期实现**，实测解不了
  真实流媒体的 AC-4 文件——v4 把 7.1 补丁的解码器实现移植到官方 6.0
  基线（带 6.0 API 兼容层），宿主实测真实酷我 AC-4 文件完整解码 0 错误
- 根因二：App 里「AC-4 不可解码 → 自动降级」是硬编码的，换了自编译库后
  仍在生效——杜比全景声永远放不出来。现在改为**启动时运行时探测**
  （查播放内核的 decoder-list），探测到 AC-4 解码器就恢复杜比全景声可选

## 2.4.2-pre3

> 预发布版：**播放修复第二弹（原生库 v3，对拍版）**。

### 🚑 原生库 v3：回到官方基线 + 仅 AC-4

- pre2 仍无法播放的设备请装这个版本验证：库完全回到 media-kit 官方
  构建组合（ffmpeg **6.0** + mpv 0.35.1 + 官方原版参数），只加 Jellyfin
  6.0 分支的 AC-4 解码补丁——与官方库唯一差异就是 AC-4 解码器
- 若 v3 能播：确认问题出在 ffmpeg 7.1 组合，后续按 v3 路线走；
  若 v3 仍不能播：请到「设置 → 运行日志」导出日志发我（应用层排查）

## 2.4.2-pre2

> 预发布版：**修复 pre1 全平台无法播放**（原生库 v2）+ QQ 风控验证 App 内完成
> + 三平台手机验证码登录 + 网易云「我的歌单」修复。

### 🚑 修复：pre1 全平台无法播放（重要，请务必升级）

- pre1 更换的自编译 libmpv 意外引入了 `libmediandk.so` 动态依赖（ffmpeg 7.x
  的构建探测误伤，官方构建没有），部分设备上库加载直接失败，
  播放器初始化不了——表现为**所有平台都无法播放**
- 原生库 v2 重链：与官方完全一致的依赖清单（0 个 mediandk），AC-4 解码器保留

### 🔐 QQ 风控验证改为 App 内完成（不跳浏览器）

- 发表评论触发安全验证（10009）时，**App 内直接弹出验证页**完成滑块，
  完成后自动重发，不再跳转浏览器
- 短信登录需要滑块验证时同样 App 内完成，完成后自动重发验证码

### 📱 新增：QQ / 网易云手机验证码登录

- QQ 音乐登录页、网易云登录页各新增「手机验证码登录」：
  输入手机号 → 收短信 → 输入验证码直接登录，无需再折腾 Cookie

### 🐛 修复：网易云「我的歌单」空白

- 之前拉取时没带登录 Cookie、账号 uid 也没解析，「我的歌单」永远空白；
  现已修复（登录后进「我的」页即可看到）

## 2.4.2-pre1

> 预发布版：AC-4 杜比全景声根治（自编译 libmpv）+ 三平台歌单体系 + 一批体验修复。
> 标记为 **Pre-release**，正式版 2.4.2 待真机验证后发布。

### 🔊 修复：AC-4 无法解码（酷我 dolby_ac4 / QQ 音乐 D004-D008 杜比全景声）

- 播放侧：选到 AC-4 档自动沿降级链换到可解码档位，QQ D001-D008 档位图谱补齐
  （D004 为 AC-4，D005-D008 是 D001-D004 的别名），命中不可解码档自动续探，
  提示「已自动切换到可播放音质」
- 根治：自编译 libmpv——**ffmpeg 7.1.3 + Jellyfin AC-4 解码补丁 + mpv 0.35.1**，
  四 ABI（arm64-v8a / armeabi-v7a / x86 / x86_64）全量重打，替换官方
  media_kit_libs_android_audio 1.3.8（其 ffmpeg 白名单不含 ac4）
- 真实酷我 AC-4 文件完整解码验证通过（2:37.90、0 错误）

### 💬 修复：QQ 音乐发表评论失败（10009）

- 沙箱真机 cookie 实测定性：**10009 不是发送失败**——评论已被服务端记录，
  但账号触发风控，需完成一次安全验证后才会展示
- 现在触发后会**自动跳转浏览器**打开验证页，完成后回到 App 重新点发送即可

### 🎵 新增：推荐歌单 / 我的歌单（仿倾听）

- 发现页「推荐歌单」：真实热门歌单数据 + **QQ / 网易 / 酷我 三平台切换**，
  点卡片进入歌单详情
- 我的页「我的歌单」：登录后按账号拉取本人歌单（QQ / 网易云 / 酷我），
  三列封面网格 + 平台切换，未登录显示登录引导
- 新增**歌单详情页**：封面 / 简介 / 曲目列表，支持播放全部与单曲点播

### 🎚️ 音质偏好修正

- 设置页新增「酷我音乐播放音质」（此前酷我没有默认音质入口）
- **播放页切音质只作用于当前一首**，不再写进默认偏好（试听不污染设置）

### 🔍 修复：QQ / 网易云热搜榜空白

- 三平台热搜字段名不同（QQ 为 k/n，网易云为 first/second），此前统一按
  word/count 解析导致全部被过滤成空列表
- 顺带修复热门歌单字段错配（封面 / 创建者全空）与 http 封面在
  Android 9+ 无法加载的问题（统一转 https）

### 📝 日志持久化补齐

- 日志页新增**近 7 天历史日期**切换，隔天也能翻到出问题当天的日志
- 导出改为合并近 7 天落盘 + 实时缓冲，保存到**下载目录**（原缓存目录
  会被「清理缓存」连带删除）

## 2.4.1

> 参考倾听 5.5.0.2：新增酷我登录（账号密码 / 短信验证码）与酷我评论浏览。

### 🔑 新增：酷我音乐登录

- 酷我音源此前**只能匿名播放**，现在支持登录自己的账号
- 支持两种方式：
  - **账号密码登录**（用户名 / 手机号 / 邮箱均可），可勾选「记住密码」；
  - **短信验证码登录**（仅中国大陆手机号，验证码 5 位，60 秒发送冷却）
- 登录入口：**设置 → 账号 → 酷我音乐**
- 会话（uid / sid / 昵称 / 头像）本地持久化，启动时自动恢复；
  过期会自动用留存口令重登，全程无需用户干预
- 口令以 **SM4-CBC** 加密后落盘，不明文躺在 SharedPreferences 里

### 💬 新增：酷我歌曲评论浏览

- 播放页评论按钮对酷我歌曲生效，可浏览**最热评论**与**最新评论**，
  支持分页加载、相对时间展示、点赞数显示
- 未登录同样可看（酷我评论接口免登录）
- 酷我**不开放发表评论与楼中楼回复**（沙箱内穷举验证：`post_comment`
  在 `f=web` 恒 600、`f=ar` 恒 604；`get_child_comment` 15 种父评论参数名
  × 3 主机 × 两种模式全部失败），因此输入框位置明确提示
  「酷我评论仅支持浏览」，**不放假按钮**

### 🔧 协议层（酷我 `f=ar`）

- 新增 `KuwoCipher`：`q = base64(DES-ECB(query, "kwks&@69"))`、
  响应体 `base64(DES-ECB(body, sx))`，`sx` 为毫秒时间戳前 8 位
- 复用 `EkeyCipher` 的同一套 DES 表，只补 `encrypt` 方向，
  **没有第二份密码学实现**；协议与倾听 / TuneWeave 逐式交叉验证，
  沙箱内对真实服务端实测打通（账密返回中文错误、短信真实送达）
- 新增设备身份三件套（`device_user` / `android_id` 32 位 hex +
  纯数字 `app_uid`），首次安装生成后持久化，所有请求带同一份

### 🧪 新增回归测试

- `test/kuwo_cipher_test.dart`（21 个用例）：q 参数与响应体的固化向量、
  协议往返、坏输入拒绝（坏 Base64 / 长度非 8 倍数 / sx 形制 / 超预算）、
  填充规则（长度恰为 8 的倍数仍补满整块）
- `test/kuwo_auth_test.dart`（28 个用例）：设备身份形制与持久化自愈、
  会话 JSON 往返与坏数据兜底、手机号校验边界、短信 secret 独立参考向量
  （Python hashlib 口径）、口令 SM4 加解密往返、登录态监听
- `test/kuwo_comment_test.dart`（18 个用例）：真实抓包样本解析、
  时间串解析、分页 `hasMore` 边界、空页与脏数据优雅降级
- 全量测试 **831 项通过**

### 🐛 修复

- 口令加密密钥短一字节（14 → 16），此前勾选「记住密码」的账密登录会抛
  `ArgumentError`（由新增单测在发版前抓出）

## 2.4.0-fix2

> 酷我音源体验收口：封面、平台标识、音质、播放缓存四项修复。

### 🖼️ 修复：酷我封面清晰度太低

- 酷我封面地址形如 `img1.kuwo.cn/star/albumcover/{尺寸}/{路径}.jpg`，
  此前统一取 **120** 档（约 120px，在播放页大图上明显模糊）
- 改为默认取接口支持的**最高档 1500**（1500px），并做归一化：
  完整 URL 直接替换尺寸段、短路径（形如 `120/s3s94/93/211513640.jpg`）
  先剥掉多余的尺寸前缀再拼接，两种入参都拿到 1500 档
- 搜索、歌曲详情两条链路均已生效

### 🏷️ 修复：酷我歌曲在播放页显示「QQ 音乐」

- 播放页的音源胶囊（`_SourceChip`）此前只判断「是不是网易云」，
  其余一律显示 QQ 音乐；酷我歌曲因此被错标成 QQ
- 改为三分支：**酷我音乐**（酷我品牌蓝 `#3B82F6`）/ 网易云音乐 / QQ 音乐
- 顺带把散在各处的平台角标收口到统一的 `SourceBadge`：
  搜索页、发现页、收藏页、历史页原先硬编码 `isNetease ? '网易云' : 'QQ'`，
  本地歌曲则根本没有角标；现在本地 / QQ / 网易云 / 酷我四态一致
- 同时修掉一个真实 bug：搜索页的下载弹层**完全没有酷我分支**，
  酷我歌曲会显示 QQ 的音质选项，选择时还会因 `picked as Quality`
  类型转换直接抛错；现已补上 `DownloadOptionsSheet<KuwoQuality>` 分支

### 🎚️ 修复：酷我音质不全

- 酷我的音质接口实际支持 **18 档**，但 `KuwoQuality` 常量表只有 7 档，
  选音质菜单被 `KuwoQuality.fromId` 过滤后只剩 7 项
- 现已按接口截图补齐全部 18 档，与 `KuwoLink.qualityRules` 逐字段对齐、同序：

| 档位 | 格式 | 码率 |
| --- | --- | --- |
| 黑胶音质 | flac | 23000k |
| 臻品音质 BCMS | mgg | 22000k |
| 臻品母带 | mflac | 20900k |
| 全景声 7.1.4 | mgg | 24000k |
| 全景声 5.1 | mflac | 20501k |
| 全景声 2.0 | mflac | 20201k |
| 杜比全景声 E-AC-3 | mp4 | 11700k |
| 杜比全景声 640 | mp4 | 11600k |
| 杜比全景声 448 | mp4 | 11500k |
| 杜比全景声 AC-4 | mp4 | 11000k |
| Hi-Res 无损 | flac | 4000k |
| 无损 FLAC | flac | 2000k |
| 极高 320k | mp3 | 320k |
| 极高 OGG 300k | ogg | 300k |
| 高品质 OGG 192k | ogg | 192k |
| 标准 128k | mp3 | 128k |
| 高清 OGG 100k | ogg | 100k |
| 省流 AAC | aac | 48k |

- 旧的 7 个 id（`master` / `hires` / `flac` / `300k` / `320k` / `128k` / `48k`）
  **全部保留**，下载与播放设置无需迁移
- 下载音质选项与播放音质选项统一为同一张表（18 档），
  播放默认仍为省流的 `128k`

### 🧹 新增：清理缓存支持清理歌曲播放缓存

- 此前「清理缓存」只能清封面、歌词、搜索历史等元数据缓存，
  **歌曲播放产生的缓存不在管辖范围**，长期占用空间
- 新增 `PlaybackCache`（256 KiB 块对齐、tmp + rename 原子写、
  512 MB 上限 mtime-LRU 淘汰、永不抛异常），
  接入酷我 QMC 加密音轨的本地中继：
  中继按 256 KiB 块取流，命中缓存直接回块、未命中回源后落盘，
  seek 到任意偏移都能精确命中
- 中继的**首块失败会干净退回原有直连流式路径**，对播放零影响
- 缓存明细页「歌曲播放缓存」条目同时统计应用自管目录与
  libmpv 默认缓存目录；播放中会跳过 libmpv 目录并给出提示
- 「设置 → 清理缓存」现已把播放缓存一并清空

### 🧪 新增回归测试

- `test/kuwo_quality_playback_test.dart`（21 个用例）：
  18 档音质与 `KuwoLink.qualityRules` 逐字段对齐 / 严格降序 / 旧 id 兼容；
  `sourceShort` / `sourceFull` 四音源；播放缓存块边界、key 稳定性、写读清闭环；
  中继 Range 逐字节正确、跨块 Range、末块不满、seek 任意偏移
  （0 / 1 / 127 / 128 / 5119 / 5120 / 5121 / 12345 / 65536）、
  **二次请求命中缓存不再回源**、缓存内容与明文一致、清缓存后回源
- 全量测试 **765 项通过**

## 2.4.0-fix1

### 🐛 修复：酷我无法搜索

- 根因：酷我搜索接口 `www.kuwo.cn/search/searchMusicBykeyWord` 的响应头是
  `Content-Type: text/plain`（不是 `application/json`），dio 的 `ResponseType.json`
  因此把响应体**原样当字符串**返回，后续 `as Map<String, dynamic>` 直接抛
  `type 'String' is not a subtype of type 'Map<String, dynamic>' in type cast`
- 修复：改为按 bytes 收取 + 手动解码（UTF-8 优先，失败回退 GBK）+ `jsonDecode`，
  并显式校验 `decoded is! Map` 时抛出可读错误，不再抛类型转换异常

### 🐛 修复：三平台歌单只解析出部分曲目

- **QQ 音乐**：`fcg_v8_playlist_cp.fcg` 的 `songlist` 字段本身就是**全量**
  （实测 2710 首的歌单返回 2163~2710 条全量），此前被本地 `.take(limit)` 截断成
  1000 条；现改为默认不限量，并补上歌单创建者昵称
- **网易云音乐**：`api/playlist/detail` 的 `tracks` 字段**只返回 10 首**，
  改为先取 `api/v6/playlist/detail` 的 `trackIds`（实测全量 1996 条），
  再分批调 `api/v3/song/detail`（单批上限 100）补全曲目信息
- **酷我音乐**：`pl.svc` 的 `rn` 参数单次最多返回 1000 条，超过会被截断；
  改为按 1000 条/页循环拉取，直到取满 `total`
- 分享歌单导入的 `limit` 默认值由 1000 改为 0（不限制）

### 🐛 修复：设置里的「设备 GUID」点不开

- 此前只弹一条瞬时 snackbar，GUID 太长在手机上根本看不全、也复制不了
- 改为弹出 Miuix 信息对话框：完整展示 GUID + 平台名，等宽字体 + 可横向滚动，
  并提供**一键复制**按钮；取值改为 `await DeviceGuid.ensure()`，
  首次启动读平台设备 ID 未完成时也不会再显示「生成中…」

### 🆕 酷我 ID / 单曲链接直达播放

- 新增「工具箱 → 音乐工具 → **酷我 ID 直达播放**」，同时在「我的 → 更多」增加同名入口
- 支持三种输入：纯数字歌曲 ID（rid）、酷我网页版单曲链接
  （`kuwo.cn/play_detail/{id}`）、移动端单曲链接（`m.kuwo.cn/newh5app/song_detail/{id}`）
- 查询后展示歌曲名 / 歌手 / 专辑 / 时长 / 可用音质，一键播放；
  QMC 加密音轨自动走本地流式中继解密

### ⚡ QMC v2 本地流式解密：重写中继 + 验证算法

- **算法验证**：与开源实现 `kuwo-music-relay-main/decrypt.php` 逐表逐式对照
  （DES 置换表、TEA 变体、密钥派生常量、`rawKeyLengths=[704,364]`、V2 前缀、
  Rc4Cipher 的 KSA / hash / segmentSkip / firstSegment）**完全一致**；
  用真实线上 mflac 母带音轨（rid=7149583）端到端跑通：
  ekey 952 字符 → rawKey 704 → 最终 key 512 → 走 `Rc4Cipher` → 解出合法 `fLaC` 头
- **中继重写**，修掉四个实际缺陷：
  - 之前无 Range 时会把整个文件读进内存（实测 145MB / 8.3 秒，手机上直接 OOM）；
    改用 `http.Client.send()` + `StreamedResponse` **逐块解密逐块下发**，
    实测 2863 块、**首字节延迟 0ms**、总耗时 6.2 秒
  - ekey 原本明文塞在 URL query（952 字符，密钥暴露在日志里）；
    改为**短 token 会话表**，URL 形如 `http://127.0.0.1:43425/stream.flac?t=s0`，
    ekey 只存内存
  - 固定端口 8899 可能冲突；改为由系统分配空闲端口（`port = 0`）
  - 越界 Range 直接 502；改为先探测总大小再把 start/end 夹回合法范围重试
- 补齐 `.aac` → `audio/aac`、`.mp4` → `audio/mp4` 的 Content-Type

### 🐛 修复：服务端面板表格在手机上无法左右滑动

- `upload.php` 的「用户（按 GUID 聚合）」「最近播放」「最近搜索」三张表在窄屏下
  被裁切且无法横向滚动
- 改为外层 `.tw` 滚动容器（`overflow-x:auto` + `-webkit-overflow-scrolling:touch`），
  表格 `width:max-content; min-width:100%`，**首列（GUID / 时间）左侧吸附固定**，
  滑动时仍可见；手机端另加「← 左右滑动查看更多列 →」提示
- 手机端同步收紧外边距与字号

### 🧪 新增回归测试

- `test/kuwo_qmc_test.dart`：用**真实 ekey + 真实密文/明文前 6144 字节**锁死
  QMC v2 行为 —— 密钥派生链、工厂选择 `Rc4Cipher`、解密得合法 FLAC 头、
  **按偏移解密与整文件解密逐字节一致**（seek 前提）、分段边界 128 / 5120 前后一致

## 2.4.0

### 🎵 新增：酷我音乐音源（第三平台）

- 搜索 / 歌曲详情 / 播放地址 / 歌词全链路打通：`www.kuwo.cn` 搜索接口、
  `musicpay.kuwo.cn` 歌曲信息、`nmobi.kuwo.cn` 播放地址、`newlyric.kuwo.cn` 歌词
- **QMC 加密音轨解密**：移植 `EkeyCipher`（DES 变体）+ TEA 密钥派生 +
  `MapCipher`/`Rc4Cipher`（QMC v2），并内置本地 HTTP 中继（支持 Range 随机访问）
  边下载边解密，兼容 media_kit 播放
- **歌词解码**：`Base64 → XOR("yeelion") → zlib → GB18030` 全链路还原，
  自动剥离 KRC 逐字标记转普通 LRC
- **18 档音质规则**（母带 / HiRes / FLAC / OGG / 320K / 128K / AAC 等），
  播放与下载各自独立记忆偏好
- **自动降级链**：高档音质不可用（未登录等）时逐档回落到可播放档位，
  不再直接报错

### 🎨 搜索页：内嵌平台切换 + 真实热搜榜

- 搜索框**左侧内嵌平台下拉选择器**（「酷我 ▾」样式），可在 QQ 音乐 /
  网易云音乐 / 酷我 之间直接切换，取代原先右上角的独立分段按钮
- 搜索框下方新增**「{平台}热搜榜」**：真实抓取三平台热搜词，带**序号**排布，
  点击任一热词直接发起搜索
- 平台切换后热词自动跟随刷新，并上报平台切换埋点

### 🆔 设备 GUID 唯一标识

- 每台设备生成一个**永久唯一 GUID**（UUID 形态，sha256 派生）
- Android 走原生 `Settings.Secure.ANDROID_ID`、iOS 走 `identifierForVendor`、
  桌面端读取系统 machine-id；拿不到时用本地随机种子兜底
- 首次生成后落盘保存，**永不重新生成**（避免服务端重复计数）

### 📡 数据上报 + 服务端可视化面板

- 客户端新增轻量上报通道（内存队列 + 批量 10 条 + 30 秒定时 + 失败重试），
  上报 GUID、平台、搜索内容、歌曲、音质、播放链接等
- fire-and-forget，**不阻塞**播放与搜索主流程
- 设置 → 通用新增「数据上报」开关（可一键关闭）与「设备 GUID」查看项
- 服务端 `upload.php` 提供**图形界面面板**：统计卡片、平台分布、搜索热词、
  用户列表、播放明细、搜索明细，**每 10 秒自动刷新**；存储优先 SQLite，
  无 `pdo_sqlite` 时自动降级为 JSON 文件

### 🎵 分享歌单一键导入

- 「我的 → 更多 → 导入分享歌单」：粘贴 QQ 音乐 / 网易云 / 酷我 的歌单分享链接
  即可解析成曲目列表，支持**全部播放**或**保存到本地歌单**

## 2.3.1-fix1

### 📊 「播放统计」入口移到「我的」页面

- v2.3.1 把入口放在了设置 → 通用；按反馈移到「我的」页「更多」分区
  首位（设置页不再重复展示），其余功能不变

## 2.3.1

### ⚡️ 修复：逐字歌词页太卡

- 主因一：歌词视图逐帧重绘（逐字跟手）时，静态的模糊封面底被连带
  重滤波——每帧一次全屏高斯模糊。加 `RepaintBoundary` 隔离后模糊只在
  换歌时重算一次
- 主因二：远处行虚化档位太重（预设 maxSigma 4 / 每行 +1），一屏
  8~10 行全在逐帧 saveLayer + 高斯模糊。降到 2.5 / 0.4——层次感
  保留，逐帧开销降一个量级（新增 1 例回归锁档位）
- 模糊底纹理面积减半：放大倍数 1.8→1.25、解码宽度钳到 480px
  （sigma 40 下肉眼无差，进播放页的首帧卡顿明显减轻）

### 🎨 播放页 UI 统一（消除割裂感）

- 之前只有歌词页是「模糊封面 + 暗幕」，封面页还是主题亮色——浅色
  模式下左右一滑白↔黑反差强烈（用户录屏反馈）
- 整页统一为**恒暗沉浸面**：顶栏 / 封面页 / 歌词页 / 控制区共用同一
  张模糊封面底 + 深色幕布，文案与按钮取深色板配色（与 QQ 音乐 /
  网易云 / Apple Music 的播放页一致）；弹层维持各自样式

### 📊 新增：本地播放统计（完全本地，无任何上报）

- 新入口：设置 → 通用 → 播放统计
- 今日听歌时长 / 播放次数 / 单曲循环次数；近 7 日合计与柱状图；
  7 日最爱歌曲；按时长 / 按次数的歌曲排行榜（Top 20，行内展示
  单曲循环次数）
- 采集口径：播放次数按开播事件计（单曲循环重播同曲也计），听歌
  时长按播放器**真实推进量**累加（暂停不计、seek 跳变不计、后台
  播放照常计）
- 存储：按「天 × 歌曲」聚合的 JSON 日 blob，只保留 15 天，无数据库、
  无膨胀；6 例单测（聚合 / 合并 / 排序 / 损坏兜底 / 过期清理）

### 📲 关于页新增社区与支持

- GitHub 项目主页（点击跳转浏览器）
- QQ 交流群 1070571636（点击唤起 QQ 加群）
- 「请作者喝一杯」捐赠入口：支付宝收款码 + 微信赞赏码（图片内置）

### 🐛 常规排查

- 播放页全部订阅与控制器 dispose 复核：无泄漏
- 歌词日 blob 解析失败自动回退空数据，不再可能因坏数据炸统计页

## 2.3.0-fix6

### 🎨 修复：歌词页「不是参考视频里的样子」（浅色主题下整页发白）

- 根因：fix5 的歌词页幕布/三色跟随主题——手机系统是**浅色模式**时，
  歌词页变成「白色幕布 + 绿色高亮 + 墨色未唱」，与参考视频1 的
  「暗底模糊封面 + 白色逐字填充」完全不同
- 歌词区改为**恒暗画布**（与 AMLL / Apple Music 一致，歌词永远压在
  封面模糊 + 深色幕布上，不随主题明暗切换）：深色幕 50%→72% 黑恒定，
  三色默认值与可读性解析都按暗底走（未自定义时恒为 白/60%白/40%白）
- 修复左对齐默认值从未生效的隐藏 bug：`load()` 把「键不存在」等同旧
  默认的居中，导致所有用户（包括全新安装）的左对齐默认都是 false
- 新增**旧默认值迁移**：老用户碰过样式面板后本地持久化的旧默认值
  （17px / 圆角 24 / 居中 / 荧光黄绿三色）会压住新默认——迁移把与旧
  默认完全相等的项恢复为新 AMLL 默认，真自定义保留；版本号落盘只跑
  一次。新增 3 例迁移回归

### 🐛 网易云发评论被风控（250）——请求指纹对齐真浏览器

- 定位：无 Cookie / 伪造 Cookie 的 weapi 请求返回 **301（未登录）**，
  用户拿到的是 **250**——说明登录态与加密都正确，是服务端风控评分
  拒绝（频率 + 设备指纹 + 账号信用三层评分）
- 指纹问题：weapi 是**网页端**通道，但请求带桌面客户端 UA（
  `NeteaseMusicDesktop/2.10.2`）、Cookie 被追加 `os=pc; appver=…;
  deviceId=pyncm!`（桌面客户端 + 第三方库标记）、缺浏览器必带的
  `Origin` 头——三者都在抬高风控分
- 修复：weapi 请求改用纯浏览器 UA + `Origin` 头，Cookie 原样直传
  （eapi / 明文 api 通道维持原头，那些通道吃桌面客户端指纹）
- 会话补齐：粘贴 Cookie 登录不会跑会话补齐（只有扫码登录会跑），
  只粘了 MUSIC_U 的 Cookie 缺 NMTID 等浏览器会话字段，写操作风控
  概率大增——发评 / 点赞前自动补齐（限时 3 秒，失败不阻塞），粘贴
  登录成功后也异步补齐一次
- csrf 兜底：扫码登录 Set-Cookie 的字段名是 `__csrf_token`（浏览器
  粘贴的是 `__csrf`），两者都认，扫码用户不再空 csrf
- 错误透传服务端 message：250 等失败码现在会带出服务端原文，便于
  远程定位；250 文案给出可操作指引（稍后再试 / 重新粘贴完整浏览器
  Cookie）

## 2.3.0-fix5

### 🎨 歌词视觉对齐参考视频（AMLL / Apple Music 风格）

- 歌词区从「玻璃卡片」改为**全幅暗底**：当前歌封面放大 1.8 倍重度模糊
  （sigma 40）铺满 + 主题化暗幕（深色 50%→72% 黑 / 浅色 72%→88% 白），
  歌词直接压在暗底上；卡片圆角设置仍作用于裁剪
- 三色改回**明度层次**（对齐参考视频1）：已唱 = 纯白填充、当前行未唱 =
  60% 白、非当前行 = 40% 白；逃逸色（对比度不足时）改用品类强调色
- 修复**远处行几乎不可见**：`flutter_lyric` 的 `appleMusic` 预设对非当前行
  施加 `fade(.45)`，叠加 40% 白文字后远处行有效亮度不到背景 1.15 倍。
  自建行过渡（scale .92 + fade .88）——灰度由文字色本身承担，虚化仍由
  预设自带的 distanceBlur 负责。新增 1 例回归锁死不透明度
- 默认字号 17→26、默认左对齐、默认圆角 24→0；译文字号比例 0.78→0.6
  （主文字号变大后保持层次）
- 视觉验证：临时探针截图 + 像素扫描——当前行已唱 / 未唱按字分界与逐字
  时间轴精确一致（「不需」纯白、「要借口」60% 白），远处行灰色可读并
  向底边渐虚淡出

### 🎚️ 进度条改为参考视频2 样式（QQ 音乐式）

- 3px 细轨道（圆角）：已播纯白 / 未播 28% 白；3×16 竖条游标，已播 / 游标
  位置精确（实测 42.7% 处）
- 两端时间与轨道**同一行**（各 11px），点击 / 拖动实时 seek；删除原
  `MiuixSlider` 方案（其在宽松横向约束下会塌缩，fix4 已埋雷）

### 🐛 修复：网易云发不出评论——不是风控，是接口迁移

- **纠正误判**：fix4 归因为「250 账号级写风控」不准确。实测明文
  `/api/resource/comments/add` 恒定返回 **400（参数错误）**——写接口已
  废弃迁移到 `/weapi/`，与账号、频率、Cookie 完整性均无关
- 全部写接口切 weapi：发评 / 回复（`/weapi/resource/comments/add|reply`）、
  点赞 / 取消点赞（`/weapi/v1/comment/like|unlike`），均带 `csrf_token`
- 新增 Dart 端 weapi 加密器（AES-128-CBC 双层 + RSA 无填充），与线上
  参考实现逐位一致；5 例单测（已知向量 / 双层往返 / RSA 正向验算 /
  随机 secret 形制 / csrf 形制）
- 端到端实测：Dart 加密发评 → 200，删评 → 200，点赞 / 取消点赞 → 200

## 2.3.0-fix4

### 🐛 修复：播放页进度条「不见了」

- 根因：`MiuixSlider` 内部是 `LayoutBuilder + SizedBox(height) + CustomPaint`，
  CustomPaint 无子节点时按内容尺寸（0 宽）测量；在 `Column` 的宽松横向
  约束下会塌缩成轨道高度的一小截，视频里只剩一个居中小胶囊
- 修复：播放页进度条显式撑满可用宽度；新增 2 例回归（生产组件满宽断言 +
  不撑满就塌缩的对照用例）

### 🐛 修复：网易云评论输入框

- **占位符与输入文字重叠**：`flutter_miuix` 1.3.0 的
  `useLabelAsPlaceholder` 只在标签/边框动画时重建，文本变化不触发重建，
  输入后「写评论」仍压在文字上。`AppTextField` 改为监听文本变化补重建
- **输入栏不随输入法上抬**：`MiuixScaffold` 的 bottomBar 只吃系统栏
  `padding`、不处理 `viewInsets`，键盘弹出后输入栏与发送按钮被盖住
  （「能看评论、不能发送」的直接原因之一）。评论页按 `viewInsets.bottom`
  垫高输入栏，并用 `AnimatedPadding` 跟随键盘动画
- 网易云 250 仍为账号级写风控：文案保留「稍后再试」，可在登录页粘贴
  完整浏览器 Cookie 走逃生门

### ♻️ 重构：歌词渲染改用 AMLL 风格引擎

- 官方 AMLL（applemusic-like-lyrics）只有 DOM / React / Vue 绑定，没有
  Flutter 版；改用语义最接近的 `flutter_lyric` 4.1.0——Canvas 渲染、
  逐字高亮、词级上弹 / 悬浮、前后奏倒计时、点击跳转、滚动跟随
- 新增适配层：内部 `Lyrics` → `LyricDocument`（逐字时间轴、译文 / 罗马音、
  无效行止时间、乱序归一），歌词样式（字号 / 对齐 / 三色 / 字重）映射为
  AMLL 预设（Apple Music 预设：当前行放大、逐字点亮、远行虚化）
- 播放器位置接成 `LyricProgressSource`：行进中逐帧采样（逐字跟手），
  暂停 / seek / 切歌由事件驱动；不再自绘卡拉 OK 遮罩
- 纯 Dart、无新增原生依赖，六端一致；旧 `KaraokeLine` / `KaraokeFill`
  保留为参考实现与像素级测试

## 2.3.0-fix3

### 🐛 修复：逐字歌词「渲染成逐行」（已唱行恢复已唱色）

- 根因：非当前行被统一置为暗灰，导致满屏只有当前行在动，观感即
  「逐字变成了逐行」
- 对齐 AMLL / 倾听三态语义：当前行 → 未唱色；**已唱行保留已唱色**
  （时间轨迹，唱过的部分不褪色）；未唱行 → 暗灰
- 新增 `lyricLineColor()` 纯函数 + 7 例单测锁死三态边界

### 🐛 修复：QQ 音乐评论加载失败（业务错误 10000）

- 根因一：评论接口 BizId 误传了歌曲 mid，必须传**数字 songid**
  （传 mid 必返 10000，登录与否都一样）
- 根因二：musicu 响应漏剥 `data` 层，评论数静默解析为 0
  （接口其实返回成功）
- 修复后实测：周杰伦《晴天》读到 33 万+ 条评论（热评 16 + 最新 15）

### 🐛 修复：网易云评论发送失败（250 风控提示）

- 扫码登录后自动补齐浏览器会话 Cookie（NMTID 等），请求更接近
  真实浏览器；250 提示改为「过于频繁或被风控，请稍后再试」
- 仍被风控时，可在登录页手动粘贴完整浏览器 Cookie 登录

### ✨ 新增：备份加密升级为国密 SM4 + SM2

- 备份文件改用 SM4-CBC（随机密钥 + IV）加密内容，SM4 密钥用
  SM2 公钥信封加密，整体 Base64 封装（`BAIJI2.` 前缀）
- 纯 Dart 实现：SM4（GB/T 32907-2016）、SM2（GM/T 0003）、
  SM3（复用 pointycastle），通过标准测试向量与 gmssl 交叉验证
- 旧的 `BAIJI1.`（RC4+RSA）备份仍可正常导入

## 2.3.0-fix2

### ✨ 新增：QQ / 网易云歌曲评论

- 播放页顶栏评论图标进入评论页；**未登录可浏览**，登录后可发评 / 回复 / 点赞
- QQ：读热评 / 最新评 / 评论数全部免登录（musicu globalComment 模块族），
  发评与点赞走 `AddComment` / `PraiseComment`（未登录返回业务错误码）
- 网易云：读评论免登录（`/api/v1/resource/comments/R_SO_4_{id}`），
  发评 / 回复走模块接口（表单编码），点赞 / 取消走 `/api/v1/comment/like`
- 评论页：头像 + 昵称 + 时间 + 内容 + 子评论缩略展示，点赞乐观更新
  （失败自动回滚），下拉刷新 + 滚动到底自动加载更多

### ✨ 新增：QQ 手机 App 扫码 + 网易云扫码登录（复刻「倾听」）

- QQ 手机扫码：`CreateQRCode` 取码 → MQTT 5.0 over WebSocket 订阅
  `management.qrcode_login/{id}` → 事件推送（scanned/canceled/timeout/
  cookies）实时推进，不轮询；扫码成功后 cookies 载荷直接换票登录
- 自实现 MQTT 最小客户端（CONNECT/SUBSCRIBE/PUBLISH/PINGREQ/DISCONNECT），
  支持 CONNACK 0x9D 重定向跟随，不引入 mqtt_client 依赖
- 网易云扫码：unikey 取码 + 二维码渲染 + 轮询（等待/已扫/过期/成功），
  成功后从 Set-Cookie 提取登录态
- 新增登录入口位于各自登录页，与原有 Cookie 登录并列

### 🐛 修复：逐字歌词渲染语义（对齐 AMLL / 倾听）

- 每词独立滑动羽化遮罩重写：过渡带宽恒为半个行高，取代旧的按字宽
  比例窄过渡；`feather<=0` 时以亚像素 epsilon 带实现硬切
- 每视觉行独立 `saveLayer + dstIn` 遮罩，换行不再导致染色失效
- 修复当前行「居中 / 右对齐」设置被丢弃、一律顶左的问题
  （根因：CustomPaint 未处理 textAlign 偏移，文本与染色层同步偏移）

## 2.3.0-fix1

### 🐛 修复：逐字歌词当前行「跳到左对齐 + 无染色」

- 2.3.0 重写的逐字渲染 **CustomPaint 没有处理对齐**：TextPainter 单行
  短文本时宽度收缩、绘制从 (0,0) 开始——用户设置的「居中」被丢掉，
  当前行一律顶到左边（普通行靠 Column 居中所以看不出）
- 渲染器补齐对齐偏移：center = 剩余宽度一半 / right = 全部，
  文本与染色层同步偏移
- 新增渲染层诊断日志（各打一次）：
  `歌词视图: lines=N 词级行=M hasWordTiming=…`（数据到达 UI 的状态）、
  `卡拉OK量字: 词数=N 有效盒=M 视觉行=K`（量字成败）、
  词级歌词中出现无 words 行时打 WARN——若染色仍异常，日志可直接
  区分「数据被替换」与「量字失败」

### 🔐 新增：备份文件加密（Base64 + RC4 + RSA）

- 备份含登录态与解密密钥库，明文落盘等于把账号送出去——
  改为**信封加密**：每次导出生成随机 16 字节 RC4 会话密钥加密内容，
  会话密钥用内置 RSA-1024 公钥（PKCS#1 v1.5）加密随文件携带，
  整体 Base64（`BAIJI1.` 前缀），文件离开设备后不可读
- 导入端用内置 RSA 私钥还原会话密钥解密；旧的明文 JSON 备份
  仍可导入（自动识别）
- 备份弹层说明同步更新；新增加密往返 / 明文泄露检查等 6 项测试

### ✨ 美化：Cookie 登录输入框（QQ / 网易云）

- 新的共用 CookieField 组件：5~8 行大输入区（长 Cookie 框内滚动）、
  一键「粘贴」（空剪贴板有明确提示）、一键「清空」、
  实时字符计数（贴没贴上、贴了多少一目了然）

## 2.3.0

### 🐛 修复：逐字歌词染色渲染（借鉴 AMLL / 倾听 同款方案重写）

- fix5 的诊断日志证实数据与解析全部正常（QQ/网易云逐字都能解析出词级
  时间轴），断点在**渲染层**：旧实现是整行单一横向渐变，歌词换行后
  第二行从 x=0 重新开始，渐变 stops 乱序被单调保护全部丢弃——
  **换行的行后半段永远染不上色**（大字号下几乎每行都换行，
  看起来就是「没有逐字效果」），且 widget 测试全是短行无法复现
- 借鉴倾听使用的 AMLL（Apple Music-like Lyrics）渲染库的方案重写：
  量取每个字的盒子并**按视觉行分组**，每个显示行独立做
  分段渐变遮罩（saveLayer + dstIn），换行、字间时间重叠全部安全；
  整行唱完/未唱时跳过离屏合成，性能与旧实现相当
- 界面圆角 / 字重 / 颜色变化时排版缓存自动失效重建

### ✨ 新增：备份与恢复

- 「设置 → 通用 → 备份与恢复」：一键导出 / 导入 JSON 备份
- 备份范围：**歌单**、播放/搜索历史、收藏、本地音乐库索引、
  **网易云与 QQ 登录态**、解密密钥库、全部个性化设置（歌词样式 /
  界面 / 下载 / 音质 / 播放偏好）
- 刻意排除设备指纹（device_json / session_*）——跨设备恢复会与
  服务端风控冲突，反而导致登录/取流异常
- 导入为合并写回：只覆盖备份里存在的键，本机其他数据保留；
  文件格式校验（app 标识 / 备份版本），不可撤销操作前有确认弹层
- 恢复后重启应用完全生效

### 📋 其他

- 网易云接口保持 `/song/lyric/v1`（实测老接口无论是否登录都不返回
  yrc）；逐字歌词需要 app 内登录网易云账号

## 2.2.9-fix5

### 🐛 修复

**QQ 逐字歌词（fix4 修复点未命中真实形态）**

- 用用户 cookie 实测 `GetPlayLyricInfo`：`crypt:1` 时**逐字 QRC 密文放在
  `lyric` 字段**（9136 字节 hex），`qrc` 字段反而为空，且不同登录态/
  客户端版本下服务端可能改变放置位置——fix4 的「qrc 优先」选择器没踩中
- 改为**双候选都解析**：qrc 与 lyric 各自走解析器（含自动解密），
  **优先返回带词级时间轴的结果**，都没有词级才用逐行兜底——
  无论服务端把逐字数据放哪个字段都能命中

**诊断日志（定位真机问题）**

- QQ：响应字段存在性/长度（qrc/lyric/trans/roma）+ 每条候选的解析结果
  （词级与否、行数）
- 网易云：登录态 + yrc/lrc/klyric 长度 + 解析结果行数与词级标志；
  「yrc 有数据但解析无词级」时打 WARN 立即暴露解析端异常

### 📋 说明

- 网易云接口保持 `/song/lyric/v1`：实测老接口无论是否登录都不返回
  `yrc`（v1 带登录返回，已验证），换回老接口拿不到逐字数据
- 网易云逐字必须登录（服务端限制）：未登录时 v1 只有混合格式 lrc

## 2.2.9-fix4

### 🐛 修复

**Lyrico 本地逐字歌词被拆成单字行（视频里本地音乐逐字失效 + 播放崩溃）**

- 根因：Lyrico 写入音频标签的 VERBATIM 逐字格式是「一行内每个词各带一个
  `[mm:ss.xx]` 时间戳，标签即词分隔符」（如 `[00:01.00]Moon[00:01.50]Halo`），
  解析器把它当经典 LRC 拆成了每词一行，词级时间轴全部丢失——
  播放已写入逐字歌词的本地音乐时既不染色、又可能出现异常行结构
- 解析器新增 VERBATIM 分支：相邻时间标签之间存在正文时改写为增强 LRC
  的尖括号标签，整行一句交给词级解析；经典 LRC（行首多时间戳紧挨着）
  完全不受影响

**本地音乐播放页 FATAL 空指针崩溃（日志两次堆栈逐帧一致）**

- 崩溃栈 12 层嵌套构建循环 + 两次堆栈完全相同，定位到歌词自动滚动
  `Scrollable.ensureVisible` 链路：`GlobalKey.currentContext` 拿到已失效
  Element（ListView 回收滑出屏幕的行）时，框架内部空断言直接崩
- 三重防御：滚动前检查 `ctx.mounted`；`ensureVisible` 整体 try-catch
  （滚动是纯辅助行为，任何异常只记日志不拖垮播放页）；换歌时重算
  当前行 `_active`，行数恰好相同的两首歌不再指向错误行

**QQ 音乐有逐字歌词却按逐行渲染**

- 根因：QQ 歌词接口同时返回 `lyric`（逐行 LRC）和 `qrc`（逐字 QRC），
  代码优先取了逐行的 `lyric`，逐字数据被丢弃；改为 `qrc` 优先

**下载中显示封面、下载完成后封面消失**

- 根因：四种格式（FLAC/MP3/M4A/OGG）重写标签时，本次没传封面就把文件里
  已有的封面块直接丢弃——「先写封面、再补歌词/标签」或「封面拉取失败
  后补写」都会把旧封面擦掉；改为没提供新封面时保留原有封面，
  OGG 反向问题（重复封面块）一并修复

**导入密钥后解密失败 / 手动填写只能填一条**

- 根因：「导入文本」只改内存从不落盘，从密钥页返回或重启后
  `load()` 读到旧数据，导入的密钥全部消失；补上持久化
- 判重键忽略匹配键：两首歌共用同一把 ekey 时（同批下载很常见），
  后加入的匹配条目被悄悄吞掉，按文件名查表落空；改为
  「平台+密钥+匹配键」三元组判重，删除同理只删指定条目
- 手动填写弹层修复：保存成功后清空表单并关闭弹层（可连续填写多条），
  补上弹层缺失的 `key` 参数（编译错误）

**网易云歌词偶发拉取失败（connection timeout）**

- 日志实测两首歌歌词请求超时后用户彻底拿不到歌词；网页接口加轻量重试：
  连接类失败（超时/连接错误）600ms 后重试一次，4xx/5xx 不重试

### 🔧 优化

- FLAC/OGG 空标签值不再写入（`TITLE=` 之类的空条目），与 MP3/M4A 行为统一
- 音频标签往返新增 8 项回归测试（嵌入读回 / 旧封面保留 / 失败不损坏原文件），
  密钥仓库新增 4 项 fix4 回归测试；全量 610 项测试通过

## 2.2.9-fix3

### 🐛 修复

**有逐字歌词的歌曲被渲染成逐行歌词（网易云侧根因）**

- 根因：网易云 v1 接口**未登录**时 `lrc` 返回的是**混合格式**——开头若干行
  JSON 制作信息（`{"t":ms,"c":[{"tx":".."}]}`）+ 经典 LRC 尾，且 `yrc`
  （逐字）未登录一律不返回。旧解析器只认识纯 LRC，JSON 头被整体丢弃、
  只剩 LRC 尾，于是所有未登录状态下的网易云歌曲都变成逐行
- 解析器新增混合格式分支：JSON 行按 `t` 时间戳成行、LRC 尾正常解析，
  合并后按「下一行起点 - 10ms」补全每行结束时间
- 播放页增加提示条：网易云未登录且当前歌没有逐字数据时，提示
  「登录后显示逐字染色」并提供跳转登录入口（yrc 需登录是服务端限制）

**下载歌曲时元数据写入不完整**

- 根因：`AudioTagger.embed` 在「无歌词且无封面」时直接早退，连
  title / artist / album 都不写——用户关掉歌词/封面选项后下载的
  QQ/网易云文件本身没有任何元数据，在播放器里显示成无名曲目
- 改为：只要基础标签非空就仍然写入（四种容器 MP3/FLAC/M4A/OGG
  均验证过「只写基础标签」路径）

**同名歌曲重复下载会覆盖旧文件**

- 根因：下载目录直接按「歌手 - 歌名」落盘，第二次下载同一首歌会把
  上次的文件（连同内嵌歌词/封面/元数据）整体冲掉
- 改为：目标已存在时自动追加 ` (1)` / ` (2)` 去重，新旧文件都在

### ✨ 新增

**「下载歌词」成为独立动作**

- 下载选项弹层的歌词区（逐行 / 逐字）点击后**只下载歌词文件**
  （外挂 `.lrc` 落盘到下载目录，带 ` (1)` 去重），不再顺带下载音乐
- 下载音乐（点音质行）时**自动附带**当前选中的歌词与封面，
  行为与之前一致
- 搜索页歌曲操作弹层新增「仅下载歌词」入口

**下载管理支持暂停 / 继续下载**

- 进行中任务右侧显示暂停按钮；暂停后保留 `.part` 残片，
- 已暂停任务显示断点进度，点「继续」通过 HTTP Range 从断点续传
  （服务端不支持 Range 时自动截断重下；残片已满时直接收尾）
- 暂停态持久化：重启 App 后仍可继续；失败任务重试时也会优先续传
- 暂停与取消分流：取消会删除残片，暂停保留

**下载管理界面显示歌曲封面**

- 任务图标改为真实封面：已完成任务读文件内嵌封面（不依赖网络），
  进行中 / 暂停中显示网络封面，读不到时回落渐变占位

### 🔧 改进

- 下载改用 `.part` 临时文件中转：失败 / 取消不会在下载目录留下
  打不开的残品；流中断（连接被掐断）时残片保留供续传
- 下载完成后做长度校验：服务端声明 content-length 与实际不符时
  判失败并保留残片
- 修复日志页在无界高度容器中渲染报
  `BoxConstraints forces an infinite height` 的问题
  （Row stretch 改 Stack + Positioned 色条）
- 测试：新增下载管理器单测（本地 Range 服务器跑完整
  下载 / 暂停 / 续传 / 断流链路）、下载任务 paused 态序列化、
  弹层歌词独立下载契约；探针测试整理为正式回归

## 2.2.9-fix2

### 🐛 修复

**有逐字歌词的歌曲获取到逐行歌词**

- 根因：网易云歌词用的是老接口 `/api/song/lyric`——它**无论什么参数都
  不返回 `yrc`（逐字）**（实测晴天 id=186016，响应里连 `yrc` 键都没有），
  于是所有网易云歌曲都只能拿到逐行歌词
- 改用 **`/api/song/lyric/v1`** 接口：登录网易云账号后返回 `yrc` 逐字歌词
  （未登录时无 `yrc`，自动回退逐行）；QQ 音乐侧走 QRC 不受影响
- 该修复同时作用于**播放页逐字显示**与**下载歌词选项**（选逐字才能
  真正拿到逐字数据）

**倍速弹层没有调节滑杆**

- 根因：MiuixSlider 内部是「无子节点的 CustomPaint」，在弹层 Column 的
  松约束下首选尺寸为 **0 宽**——滑杆渲染了但完全不可见，只剩固定预设
  （组件测试实测：裸放宽 0.0，包一层撑满后 344.7px）
- 倍速弹层滑杆用 `SizedBox(width: double.infinity)` 强制撑满，
  顺带修复歌词样式表 4 个滑杆（字号 / 放大 / 字重 / 圆角）的同款问题

**选择倍速播放后没有声音**

- 根因：libmpv 0.38+ 变速走 scaletempo2 音频滤镜，其默认
  **max-speed=4**——超过 4 倍速音频直接静音（点 5.0x 预设必现）
- 播放器创建时显式配置 `af=scaletempo2=min-speed=0.01:max-speed=50`，
  0.01~50 倍全区间都有声音；旧版 mpv 无此滤镜时配置自动跳过，
  回落默认 scaletempo（本身不限速）

## 2.2.9-fix1

修复 v2.2.9 对比度保障引入的逐字歌词染色回归：浅色主题下自定义的
已唱色与未唱色**双双不可读时会被兜成同一个墨色**，卡拉 OK 填充渐变
两端同色，逐字染色整个隐形（表现为「逐行好了，逐字又没了」）。

### 🐛 修复

- 可读色解析改为**分层回退**：自定义色不可读时优先回退当前主题的
  默认色（已唱=绿 / 未唱=墨或纸，彼此天生不同色），主题默认也不可读
  才用墨/纸兜底
- 新增**同色保护**：已唱色与未唱色解析后若相同（例如两把自定义色
  都可读但取了同一个值），强制已唱色换主题绿，保证填充始终可见
- 逐行歌词的高亮行为不变（未唱色回退墨色的语义与 v2.2.9 一致）

## 2.2.9

本版本包含五块内容：**修复弹窗输入框被撑满**（RenderErrorBox 根因）、
**QQ/网易云下载歌词选项**（默认逐字、无逐字回退逐行）、**修复逐行歌词
当前行浅色主题下隐身**（三色对比度保障）、**新增倍速播放**
（0.01x ~ 50x 无级调节）、**全平台签名校验**（防二次打包 / 篡改）。

### ✨ 新增

**下载选项弹层（歌词 + 音质二合一）**

- 播放页与搜索页的下载入口共用同一个弹层：顶部选歌词粒度，下面点音质即下载
- 歌词三档：不下载 / 逐行歌词（标准 LRC，兼容性最好）/ 逐字歌词（增强 LRC，
  保留每个字的演唱时间，支持卡拉 OK 染色）
- **默认逐字，无逐字自动回退逐行**：老歌、纯音乐只有逐行歌词时落盘逐行 LRC，
  并在日志里记录回退原因
- 下载结果文案带上实际写入的物件（如「逐字歌词 + 封面已内嵌 + 同名外挂文件」），
  下载管理页一眼可见

**倍速播放（0.01x ~ 50x 无级调节）**

- 播放页操作行新增倍速入口（速度图标，非 1.0x 时高亮），
  弹层内对数刻度滑杆无级拖动 + 0.5x~5.0x 常用预设 + 一键恢复 1.0x
- 对数刻度让 1.0x 落在滑杆约 46% 处，低速/高速两端都有足够可调行程
  （线性刻度下 1.0x 挤在最左端 2% 没法用）
- 拖动即时生效（libmpv speed 属性无损调速）；倍速跨歌曲、跨重启记忆，
  切歌后自动重放，不会被 open() 重置
- 歌词播放头的墙钟插值同步按倍率外推，倍速下逐字染色不再滞后于歌声

**全平台签名校验（防二次打包 / 篡改）**

- **Android**：构建期把实际签名证书的 SHA-256 锚进原生代码（BuildConfig
  随 R8 编进 dex），启动时原生层读取当前 APK 签名证书比对——
  重打包 / 换签的安装包必然对不上，直接拦截
- **Windows / macOS / Linux**：CI 打包前对产物全部文件做 SHA-256 清单
  并用 ed25519 私钥签名（私钥走 CI secret，公钥锚进应用），
  启动时验签清单 + 逐文件比对，改任何文件 / 换清单 / 删清单都会被抓住
- 校验失败显示**防篡改拦截页**（展示指纹差异），不执行任何业务代码，
  用户只能从官方渠道重下
- 本地 / debug 构建自动跳过校验（无锚定指纹或无清单时放行），
  不影响开发；iOS 因侧载自签证书各设备不同，明确不校验（避免误伤）

### 🐛 修复

**弹窗输入框被撑满成巨型灰块**

- 根因：弹窗内容祖先链缺少 MaterialLocalizations，TextField 在 build 期
  抛异常被 RenderErrorBox 替换，而无高度约束下按 100000px 撑爆整个弹窗
  （用户截图：密钥管理各平台填写弹窗、抓包代理弹窗全是巨型灰块）
- AppTextField 现在会在缺失时自动包一层自包含中文 MaterialLocalizations
  （AppZhMaterialLocalizations），页面内已正确设置的系统语言不受影响
- 密钥管理各平台填写弹窗 / 蜻蜓设备信息 / 抓包代理 / 关于页密码弹窗
  的输入框全部恢复 18~36px 正常高度，附回归测试

**逐行歌词当前行浅色主题下隐身**

- 用户视频实测：浅色背景下当前行文字 #D1D0D3 vs 背景 #FCFBFE，
  对比度仅约 1.5:1，几乎不可见——深色主题下调的浅色三色不跟随主题切换
- 新增 `LyricSettings.ensureReadable` 对比度保障：当前行 / 非当前行 /
  已唱填充色在歌词背景上对比度不足 3:1（WCAG 大字号下限）时，
  自动回退为与背景明暗相对的内置墨色 / 纸色；可读的自定义色原样保留
- 逐行歌词当前行、逐字歌词未唱部分、卡拉 OK 填充统一走可读色，
  浅色主题下当前行恢复清晰高亮

## 2.2.8

本版本聚焦**全 App 界面彻底统一与底层健壮性**：所有子页面改用与主界面
一致的白色玻璃骨架（跟随系统明暗 + 莫奈取色），修复顶部标题遮挡内容，
输入框视觉统一收口；日志模块结构化重构，崩溃转储噪声可折叠；
同步修复多个「切页面后 setState」隐藏崩溃与订阅泄漏，并加固打包。

### ✨ 新增

**统一页面骨架 PageScaffold**

- 设置 / 关于 / 工具箱 / 日志 / 历史 / 下载 / 收藏 / 歌单 / 搜索 /
  两个登录页 / 解密 / 密钥管理 / 播放页全部迁移到统一骨架：
  白色星云背景 + 天蓝顶栏 + 系统状态栏安全区，深浅色都跟随系统
- 播放页改为全出血模式（自绘渐变背景 + SafeArea），去掉了突兀的黑窗

**统一输入框组件 AppTextField**

- 玻璃底 + 细描边 + 强调色光标，替换各页面手写输入框，
  搜索 / 歌单重命名 / 密钥录入等 12 处全部换新

**日志模块结构化重构**

- 每条日志解析为级别 / 时间 / 标签 / 消息，级别 chip 筛选 +
  关键词搜索 + 一键复制单条
- 崩溃转储（tombstone、backtrace、Build fingerprint 等）自动识别
  折叠为「已折叠 N 行系统转储」，可一键展开/隐藏，不再刷屏
- 修复 FATAL 日志中 Flutter isolate dump 覆盖关键错误的问题

### 🐛 修复

**隐藏崩溃（await 后 setState）**

- 本地音乐扫描授权、解密选文件/建目录、播放页上一首/下一首：
  异步返回后页面已销毁时继续 setState 导致崩溃，全部补 mounted 检查

**订阅泄漏**

- 修复迷你播放条 onDurationChanged 订阅未取消，切歌/退出时
  回调打到已销毁 State 的问题

**顶部标题遮挡内容**

- 统一骨架正确应用顶栏回传的 padding，设置等页面首项不再被标题挡住

### ⚡ 优化

**流畅度**

- 迷你播放条进度订阅移入叶子组件，每秒多次的位置刷新不再触发
  封面图重建
- 本地音乐列表过滤/排序结果记忆化，搜索与排序切换不再重复计算

**打包加固**

- Android R8 开启 fullMode + 补充 keep 规则（注解/JNI/签名），
  桌面端符号表剥离 + tree-shake-icons，包体更小更难逆向

## 2.2.7

本版本聚焦**弹窗体验与全 App 界面统一**：更新弹窗支持 Markdown 渲染、
密码弹窗重做、日志页重新设计、设置/关于/工具箱视觉语言统一；
歌词字重与界面圆角改为点击弹出调节界面，实时预览。

### ✨ 新增

**歌词字重 / 界面圆角弹出调节**

- 设置页「歌词字重」「界面圆角」从行内滑块改为点击整行弹出调节界面
- 字重弹窗：示例歌词按当前字重实时渲染，所见即所得
- 圆角弹窗：玻璃卡片实时预览，圆角变化肉眼可见，支持一键恢复默认

**更新日志 Markdown 渲染**

- 「发现新版本」弹窗正文改为 Markdown 渲染（与设置页更新日志卡同款排版），
  标题 / 列表 / 行内代码 / 引用块不再显示原始符号

### 🎨 优化

**界面统一（不止日志页）**

- 日志页重新设计：每条日志一张卡片，左侧级别色条 + 时间 + 级别徽章，
  超长消息默认折叠，ERROR / FATAL 描边高亮
- 工具箱页、关于页改用与设置页一致的分区标题 + 玻璃卡语言，消除割裂感
- 关于页开发者密码弹窗重做为 Miuix 风格，并修复手机端输入框把弹窗
  撑爆的布局缺陷

**修复布局溢出**

- 修复关于页信息卡、工具箱页标题行、密码弹窗在多机型下的 RenderFlex 溢出
- 新增 9 组全页面 build 冒烟测试（手机视口），回归防再犯

### 🐞 修复

- 播放器 stream 回调统一 try-catch 兜底：native 边界异常降级为 ERROR 日志，
  不再冒泡成 FATAL 闪退
- 播放链接为空时跳过 open 并提示，避免空串送入 media_kit

## 2.2.6

本版本聚焦**歌词体验、可诊断性与界面整理**：修复长歌词跨行被当成一句、
暂停时点击歌词可跳转、歌词视图支持手动浏览并自动回定位；
新增日志持久化与闪退兜底捕获、开发者模式；设置页重新分组，
全局圆角与歌词字重开放调节。

### ✨ 新增

**日志持久化 + 闪退兜底捕获**

- 日志按天写入本地文件（保留 7 天），重启后自动回读当天历史，
  不再「每次打开软件就清空」
- 三层捕获框架错误 / 平台错误 / 异步未捕获异常，闪退前强制刷盘留痕，
  下次启动可在「工具箱 → 运行日志」查看

**开发者模式**

- 关于页连点版本号 10 次，输入密码 `molan` 开启
- 原设置页的抓包功能（允许抓包调试 / 抓包代理）移入设置页「开发者模式」分区，
  默认隐藏，关闭开关后立即隐藏

**全局圆角与歌词字重调节**

- 设置 → 通用新增「界面圆角」滑条（8~28，默认 16），全 App 卡片统一跟随
- 设置 → 歌词与显示新增「歌词字重」滑条，播放页逐字歌词实时生效

**工具箱扩充**

- 工具箱从单一「本地音乐解密」扩为三个工具：本地音乐解密 / 解密密钥管理 / 运行日志
- 按「音乐工具」「诊断工具」分组，卡片视觉与设置页统一

### 🔧 优化

**长歌词跨行拆分**

- 部分源（如 QQ 音乐 QRC）把两个分句放在同一行同一时间片，导致整行同步染色
- 解析时按行内字间显著停顿（≥800ms 或 ≥5 倍行内中位间隔）自动拆分为多行，
  每行独立高亮；译文 / 罗马音跟随第一段

**暂停时点击歌词跳转**

- 暂停状态下点击歌词行也能跳转到对应时间，跳转后逐字染色播放头同步归位

**歌词视图手动浏览**

- 查看歌词时可上下滑动浏览；停止滑动 5 秒后自动定位回当前播放行

**设置页重新分组**

- 设置页重组为六个分区：账号 / 播放与音质 / 歌词与显示 / 下载与存储 / 通用 / 开发者模式，
  每个分区带图标锚点；「缓存管理」并入「下载与存储」，「检查更新」并入「通用」，
  免责声明与使用协议移至关于页「法律信息」

## 2.2.5

本版本是一次**主题系统改造**：整体 UI 支持浅色（跟随系统自动切换深色 / 浅色），
标题文字改为天蓝色，并新增「莫奈取色」开关（主题色跟随系统壁纸，可在设置里关闭）。

### ✨ 新增

**浅色主题（跟随系统）**

- 整体 UI 在系统浅色模式下呈现白色底 + 深墨文字的浅色配色，深色模式保持原值不变
- 切换实时生效，无需重启；App 内所有页面、弹窗、控件统一走同一套明暗令牌
- 浅色下的前景色全部换深档（天蓝 `#0277BD`、青 `#027DA6`、品红 `#C2185B`），
  正文三级色对比度均 ≥ 4.5:1，不会「糊」在白底里

**天蓝标题**

- 各级标题（大标题 / 页面标题 / 顶栏）统一为天蓝色：深色模式 `#7AD1FF`，
  浅色模式压深为 `#0277BD`，两种底色下对比度均 ≥ 4.5:1

**莫奈取色开关（设置 → 外观）**

- 开启后主题色从系统壁纸取色（Android 支持；其他平台自动回退品牌紫）
- 只接管主色一族，背景 / 表面 / 描边等结构令牌仍是白姬玻璃风，不会整页变色
- 开关状态持久化，重启后恢复

### 🔧 修复

**歌词三色现在跟随明暗主题**

- 未自定义时，已唱 / 当前行未唱 / 非当前行三色随浅色 / 深色主题自动切换；
  自定义过的颜色仍然优先，重置 = 回到主题默认

## 2.2.4

本版本一共五项改动：歌词渲染更顺滑、歌词三色可调、更新检测修复误判、
歌词字重与圆角可调，以及一次**全 App 的 UI 框架切换**。

### ✨ 新增

**歌词颜色自定义（RGB 取色，默认白）**

播放页新增歌词配色面板，已唱色 / 当前行未唱色 / 非当前行色三色均可独立调节：

- 默认保持视频实测值：已唱荧光黄绿 `#A8F685`、当前行白 `#FFFFFF`、非当前行暗灰
- 支持 RGB 三个通道滑条微调 + 十六进制输入 + 预设色板，改完即时生效
- 设置持久化到本地，重启后恢复；一键重置回默认

**歌词字重与圆角可调**

- 字重：300~900 十档可调（默认 800），非当前行自动比当前行轻一档
- 歌词行圆角：0~40 可调（默认 24），作用于歌词面板背景
- 两项均实时预览、越界自动钳制、可重置

### 🔧 修复

**歌词过渡平滑化**

逐字填充的边界不再是硬切换：每个字的填充前沿增加一段渐变过渡带，
上一字唱完与下一字唱起之间不再"跳色"，视觉上连续跟进。

**版本号带 fix 字样时检测更新误判最新**

`2.2.3-fix1` 这类带 `-fixN` 后缀的本地版本，此前与 tag `v2.2.3` 比较时
被判定为"已是最新"，实际 GitHub 上已有新版本。语义化版本比较现在会先
剥离预发布/构建后缀再按主次修订号比较，并正确识别 `fixN` 迭代高于同号发行版。

### 🎨 UI

**全 App 界面切换为 Miuix 设计语言**

所有页面的控件由 Material 系统一换成 Miuix 组件，视觉与交互一致：

| 场景 | 之前（Material） | 现在（Miuix） |
|---|---|---|
| 页面骨架 | `Scaffold` + `AppBar` | `MiuixScaffold` + `MiuixTopAppBar` |
| 对话框 / 底部弹层 | 命令式 `showDialog` / `showModalBottomSheet` | 声明式 `MiuixOverlayDialog` / `MiuixOverlayBottomSheet` |
| 列表行 | `ListTile` | `MiuixPressable` 自定义行 |
| 输入框 | `TextField` + `InputDecoration` | `MiuixTextField` |
| 按钮 | `TextButton` / `IconButton` / `FloatingActionButton` | `MiuixTextButton` / `MiuixIconButton` / `MiuixFloatingActionButton` |
| 分割线 | `Divider` | `MiuixHorizontalDivider` |
| 进度 | `CircularProgressIndicator` / `LinearProgressIndicator` | `MiuixCircularProgressIndicator` / `MiuixLinearProgressIndicator` |
| 下拉刷新 | `RefreshIndicator` | `MiuixPullToRefresh` |
| 提示条 | `SnackBar` + `ScaffoldMessenger` | 全局 `showAppSnack` + `MiuixSnackbarHost` |

霓虹品牌组件（GlassCard / NeonButton / NeonText / TagBadge / CoverImage）保留原视觉，
仅把按压反馈升级为 Miuix 的按压曲线。全局圆角由 Miuix squircle 主题统一承担，
歌词卡片圆角仍可按上一节单独调节。

## 2.2.3-fix1

逐字歌词的填充方式按视频逐帧核对后重做。上一版（2.2.3）的效果是**整字渐变跳色**，
而视频里是**字符内从左到右逐渐填满**——帧分析确认：18.0s 目标字全白 →
18.1s 左 1/3 变绿 → 18.3s 绿到 2/3 → 18.6s 整字填满，填充边界是一条竖线，
随播放推进扫过整个字。

### 🔧 修复

**逐字歌词改为字符级渐进填满（严格对照视频）**

| 对比项 | 之前 | 现在 |
|---|---|---|
| 填充方式 | 整字一起从灰渐变到青 | 每个字在自己的起止时间内**从左往右扫过填充**，左绿右白、竖直边界推进 |
| 已唱色 | 青色 | **荧光黄绿 #A8F685**（从参考视频逐帧取色的实测值） |
| 未唱色（当前行） | 次级灰蓝 | **亮白**（视频里当前行没唱到的部分就是白字） |
| 非当前行 | 暗灰 | 暗灰（不变） |

实现方式：`ShaderMask` + 分段 `LinearGradient`——

- 用 `TextPainter` 量出每个字在行内的水平区间，文本不变时缓存，
  播放期间每帧只重算填充进度，不重新排版
- 每个字按演唱进度算出填充前沿，在渐变上放「前沿之前 = 已唱色、
  之后 = 未唱色」的硬停靠点，即得到竖直填充边界
- 分段构造抽成纯函数模块 `KaraokeFill`，新增 10 项单测覆盖
  全未唱 / 全唱完 / 进行中 / 组合状态 / 空文本占位字 / 越界钳制等场景
- 非当前行逐字 span 合并成整行文本（颜色统一后无需逐字拼接，渲染更省）

## 2.2.3

本版本解决 6 个用户反馈的问题，核心是**缓存统计口径**、**下载任务可见性**
和**本地歌词识别**三块。

### 🔧 修复

**1. 点击清理缓存后实际缓存没清掉**

根因是「统计口径」和「清理口径」不一致：`breakdown()` 里多统计了一个
「系统临时目录」，而 `clear()` 从来不删它。移动端上 `getTemporaryDirectory()`
通常就是 `getApplicationCacheDirectory()`，两者是父子重叠目录——
于是同一份文件被统计两次却只删得掉一份，用户点完看数字几乎没降，只会觉得「没生效」。

- 抽出 `CacheManager.managedDirNames` 作为**唯一受管目录清单**，
  `breakdown()` 与 `clear()` 都只认它
- 新增 `tmp` 受管目录，把**解密页的临时副本**从系统临时目录挪进来
  （之前落在清理范围外，解密残留永远清不掉）
- 删除失败不再静默吞异常，通过 `onIssue` 回调如实上报，
  设置页把「权限不足 / 文件占用」显示成红色错误提示而不是「点了没反应」
- 清理确认框会动态列出实际会清空的目录名

**5. 本地歌曲的内嵌歌词识别有问题**

有两个独立原因，都修了：

- `LyricApi.of` **缺 `isLocal` 分支**——本地歌曲落进 `qq()` 分支，
  拿 `hashCode` 当 mid 去请求QQ 接口，必然失败。现在新增 `LyricApi.local()`
  接 `LocalScanner.readLyricFor`
- 元数据读取侧的覆盖面不够，补齐后：
  | 场景 | 之前 | 现在 |
  |---|---|---|
  | ID3 `SYLT` 同步逐字歌词 | 完全不认 | 转成增强 LRC 片段，走现成卡拉 OK 渲染 |
  | ID3v2.2（3 字符帧 ID、6 字节帧头、无 flags） | 整张标签被丢弃 | 三套帧头格式分别解析 |
  | FLAC `UNSYNCEDLYRICS`（官方推荐键名） | 只认老的 `LYRICS` | 两个键名都认 |
  | FLAC 元数据块超过 64KB 预读窗口 | 直接 `break`，歌词读不到 | 按需回文件补读 |
  | QQ 的 `QRC64://` 前缀歌词 | 不剥前缀，解析失败 | 连同 `QRC://` / `LRCLIB://` / `bLyric/` 一起剥，并加 base64 兜底 |
  | 外挂歌词 `.lrc/.qrc/.txt` 与多层后缀命名 | 只认 `.lrc` | 扩展支持并加时间标签校验 |

### 🎨 改进

**2. 逐字歌词渲染改为视频所示的效果**

之前当前行字号放大到 **1.45 倍**，视觉上「一跳一跳」的，而且已唱/未唱用两种灰度
反而让人看不出当前行在哪。现在：

- 放大倍率降到 **1.12 倍**（轻微），保留视频里那种「当前行稍稍突出」的感觉但不刺眼
- 非当前行统一用一种暗灰，不再区分已唱/未唱（卡拉OK 的逐字染色已经承担了「唱到哪」的信息）
- 当前行的**未唱部分**从最暗灰提到次级灰，这样当前行位置一眼可辨

**3. 下载管理要显示下载进度，点击下载后的能直接播放**

之前 `DownloadManager.download()` 只是个阻塞 Future，调用方拿一个局部变量渲染进度条：
切页就没了、搜索页完全没反馈、下载完也点不到。现在引入**全局任务注册表**：

- 新增 `DownloadTaskRegistry`：任务列表是**不可变快照** + 广播流，
  任意页面订阅都能拿到最新状态，进度不再随页面生命周期丢失
- 7 态状态机：等待 / 准备中 / 下载中 / 补齐附属文件 / 已完成 / 失败 / 已取消
- 下载管理页按「进行中 / 已完成」分组，显示进度条、百分比、已下载/总量、实时速度
- **点已完成项直接播放**：`downloadedSongOf()` 把任务转成带 `localPath` 的
  `Source.local` 歌曲（之前页面只有裸 `File`，构造不出能播的 `Song`）
- 下载目录里存在但任务表没记录的文件，启动时用 `AudioReader` 读元数据补齐成条目
- 失败任务显示原因并支持重试；删除文件会顺带删掉同名的歌词/封面外挂文件
- 已完成任务持久化，重启 App 后历史还在（文件已不存在的会被剔除）

**4. 本地歌曲支持搜索，修改排列方式**

- AppBar 加搜索框，按**歌名 / 歌手 / 专辑 / 文件名**过滤，多关键词空格分隔是「与」关系
- 排序菜单支持标题 / 歌手 / 专辑 / 时长 / 修改时间 / 文件大小 / 格式，
  同一项再点一次翻转升降序，偏好持久化到本地
- 时长/大小/时间为 0（读不到）的条目统一沉底，**降序时也一样**——
  这点专门写了测试，因为简单 `reverse()` 会把它们甩到最前面
- 播放队列改用筛选排序后的列表，`startIndex` 与屏幕行号一致（之前排序后点第 3 首
  会播成原序第 3 首）
- 空搜索结果显示独立的「没有匹配…」态并提供一键清空，而不是复用空列表的「还没有本地音乐」

**6. 播放页新增音频规格信息**

播放页操作行新增一个按钮，点开可以看到当前这首歌的：

- 采样率（kHz）、比特率（kbps）、声道数、容器格式、编码格式
- 本地歌曲走 `AudioReader` 直读文件头（带 64 条 LRU 缓存，切换歌不重复读盘）
- 在线歌曲走 `player.state.track.audio` + `audioBitrate`
- 音质档位显示的是 `actualQqQuality` / `actualNeteaseQuality`，即**实际生效**的档位
  而不是请求时选的档位（降级后两者可能不同）

顺手修掉一个显示错乱的 bug：**MP4/M4A 的采样率之前取的是 `mvhd.timescale`**，
那是影片时长时间基（真实文件里几乎总是 1000），跟音频采样率毫无关系，
所以以前 M4A 一律显示「1 kHz」。现在改从 `stsd` 的 `mp4a` 条目正确读取
（16.16 定点，高 16 字节是整数部分），同时补齐声道数与编码名。
WAV / Ogg Vorbis / Opus 也一并补上声道数与编码。

### 🧹 其它

- 本地歌曲页的提示行常驻显示「共 N 首 · 按标题↑排列」，搜索时变成「匹配 M / N 首」，
  一眼能看出筛选效果
- 错误提示改用显式的 warn 标记，不再靠字符串匹配判断有没有出错

## 2.2.2-fix3

### 🔧 修复

把四个平台的**真实查表键**在界面上显式化，并按压缩包的严格查表语义重写密钥查找。

用户指出"QQ 音乐需要文件名和 ekey、酷狗需要 audioHash 和 ekey、酷我需要资源 id+音质+ekey、
蜻蜓只要设备密钥，这些你都没有体现出来"——核对 `um-react` 后确认完全正确，
并且发现旧实现还有一个更实质的问题：**取密钥用的是「该平台随便取第一条」**，
而上游前三个平台是严格查表（酷狗 `hasOwn(keys, audioHash)` 不命中就是 `undefined`，
绝不会退化成任意一把）。拿错一把必然解出噪声。

- **各平台匹配键显式化**
  | 平台 | 查表键 | 来源依据 |
  |---|---|---|
  | QQ 音乐 | 原始文件名（`mediaName`）或 mid | `selectQMCv2KeyByFileName` |
  | 酷狗 | `audioHash` | `selectKugouKey` |
  | 酷我 | `资源ID-音质` | `selectKWMv2Key` |
  | 蜻蜓 FM | 无（一把设备密钥通吃） | `QignTingFMDecipher` |
  | 网易云 / 咪咕 | 无（密钥在文件头里） | — |

- **手动填写对话框按平台显示对应字段**：QQ 填「原始文件名 + ekey」，
  酷狗填「audioHash + fileKey」，酷我填「资源 ID + 音质 + fileKey」并实时预览拼出的
  `rid-quality`，蜻蜓只填设备密钥 hex。匹配键留空会直接拦下——
  没填的密钥永远匹配不上文件，存进去只会让人误以为是自己密钥错了
- **导入文本的格式说明按平台改写**：逗号左边是那个平台的匹配键，不再是通用的 mid
- **去掉「随便取一把」的兜底**：QQ / 酷狗 / 酷我改成严格查表，查不到就报明确的
  缺密钥错误（并直接告诉你本文件的 audioHash 或 rid-quality 是什么），不再拿别的
  条目去试；蜻蜓保留单把通吃
- **QQ 支持文件名模糊匹配**（编辑距离 ≤ 3），对齐上游 `closestByLevenshtein`，
  但只在同平台内进行
- **导入数据库时补齐匹配键**：扫描 SQLite 时一并提取 `audioHash` 与资源 id，
  扫出来的条目才真的能对上文件
- **密钥列表显示匹配键**，缺匹配键的条目会标黄提示「无法匹配」

## 2.2.2-fix2

### 🐛 修复

- **逐字歌词回来了**——2.2.2 改「整行放大」时，把逐字卡拉 OK 染色整条链路
  一起删掉了，只剩放大。用户反馈"只是换一个渲染方式，为什么逐字歌词直接没了"，
  确实是实现错误：放大管字号、染色管颜色，是两条独立的链路，现在两者同时生效
- **咪咕解密起点从 0x1000 改回 0x0000**——按 um-react 的 `Migu3D.fromHeader`
  契约，文件头只是借来反推密钥用的，解密 offset 从 0 递增。之前跳过 4 KiB
  等于把开头 4 KiB 密文原样留在输出里，音频头部被噪声毁掉
- **解密产物新增音频校验**（对齐 um-react 的 `detectAudioExtension`）：
  密钥填错、版本判断错、偏移猜错时解密本身不会报错，只是产出随机字节。
  现在产物会按ID3 / fLaC / ftyp / OggS / RIFF / ASF / FRM8 判定，
  认不出来就**删掉产物并报错**，不再让用户拿到"能播放但全是噪声"的文件
- 错误提示按平台区分，直接告诉用户该填哪个版本的密钥

### 🔧 优化

- 密钥填写说明按各平台**解密条件**重写：QMC v1 用内置密钥不要填、
  仅 kgm v5 / kwm v2 需要 fileKey、网易云与咪咕无需密钥
- 网易云 / 咪咕填写密钥时先提示"该平台通常不需要密钥"，避免白忙
- 解密结果带上实际音频格式（如 `完成 · 酷狗音乐 · flac`），一眼可确认
- CI 放宽版本号正则，接受 `2.2.2-fix2` 这类修订版号

## 2.2.2-fix1

### 🐛 修复

- **密钥不再跨平台混用**——之前所有平台的密钥堆在同一个列表里，取密钥时
  可能拿到别的平台的 key。六个平台的加密规则完全不同（一把钥匙开不了
  别的平台的锁），现在密钥按平台隔离存储与查找，解密时按文件实际格式
  精确取对应平台的那一把
- 旧版本已保存的密钥自动迁移（归入 QQ 音乐），不会丢
- 删除 / 清空密钥只作用于当前选中的平台，不再一颗老鼠屎坏一锅汤

### ✨ 新增

- **新增蜻蜓 FM（.qta）解密支持**
  - 算法：AES-128-CTR，64 位大端计数器；IV 从文件名 `.p!<base64>.qta` 派生
  - 蜻蜓的文件没有文件头，唯一识别依据是文件名，已放在嗅探链最前面判定
  - 内置「由设备信息生成密钥」：填手机product / device / manufacturer /
    brand / board / model 六段机型信息，自动派生 16 字节设备密钥
- 密钥管理页改为**分平台 Tab**：每个平台一格，显示该平台已录的密钥条数，
  手动填写 / 导入文本 / 导入数据库都只作用于当前 Tab
- 每条密钥按平台的形态不同给出对应填写说明（蜻蜓要hex、QQ 要 base64 …）
- 解密页展示六个平台的密钥配置状态，一眼看出哪个平台还缺钥匙

### 🔧 优化

- 蜻蜓 FM 的「导入数据库」会明确提示密钥扫不出来、改用设备信息生成，
  不再让用户白忙一场

## 2.2.2

### ✨ 新增

- **逐字歌词改为整行放大**：当前播放行不再只有几个字被放大，而是整行统一放大、加粗并居中，过渡动画重新做了缓动，读起来更顺。放大倍率可在歌词样式里自行调节（1.00× ~ 2.00×，默认 1.45×）。
- **「我的」页新增工具箱**：进入后可用工具集中管理，目前收录**本地音乐解密**。
- **本地音乐解密**：支持 QQ 音乐（QMC / MFLAC）、酷狗（KGM / VPR）、酷我（KWM）、网易云（NCM）、咪咕（3D / 3DA）五个平台的已加密音频，批量导入、自动识别格式、边解边写不占内存。
- **密钥三种录入方式**：
  - 手动填写 ekey / fileKey，可顺带填 mid 做精确匹配；
  - 导入文本，支持 `ekey`、`mid,ekey`、`mid,文件名,ekey` 三种写法；
  - 导入客户端数据库：内置 MMKV 解析器（读 QQ 音乐的 protobuf 键值对，并从键名里认出mid）与 SQLite 解析器（走 b-tree + record，只收 `ekey` / `xxx_key` 这类列），导入后会给出逐文件的命中报告。
- **自定义保存位置**：默认落在「文档/解密音乐」，也可随时用文件选择器改到别处；同名文件会自动加序号，不会互相覆盖。
- **并发解密与中断**：按设备核数自动开 1 ~ 4 个并发 worker，解密中可随时点「停止」，已解出的文件会保留。

### 🐛 修复

- **修复解密结果偶尔无法播放**：QMC 密钥压缩的移位方向、KGM v3 的密钥派生顺序、酷我 DES 的 S 盒常量表此前都有偏差，已逐字节对齐，五个平台的解密结果均与原库一致。
- **修复部分文件解不出来却没有任何提示**：现在每个文件都会显示识别到的平台与失败原因，不再静默跳过。
- **修复批量导入时的同名覆盖**：同一文件夹里存在同名不同格式文件时不再互相覆盖。
- **修复「我的」页新增入口后的滚动错位**：工具箱入口不再引起列表跳动。

## 2.2.1

### ✨ 新增

- **搜索结果支持翻回上一页**：底栏改为「上一页 / 第 N 页 / 下一页」三态布局，往回翻时列表会相应截断，已加载过的页走本地缓存不发请求。
- **缓存管理**：设置页新增「清理缓存」按钮，清理前会列出各类缓存的占用明细与释放量；同时支持用文件选择器自定义缓存目录，并可调节内存图片缓存上限（16~1024 MB）。
- **播放页长按封面保存到相册**：长按播放页封面即可把当前歌曲的封面存进系统相册（Android / iOS / macOS / Windows 支持，会自动申请相册权限）。
- **下载时同时产出外挂歌词与封面**：除了写入音频文件内嵌标签，还会按音频文件名在同目录生成同名的 `.lrc` 与图片文件，很多播放器与文件管理器只认外挂文件。
- **更新日志支持 Markdown**：检查更新的弹窗现在会渲染更新日志的标题、列表、代码块、引用、表格与链接，并可上下滚动，点击链接用系统浏览器打开。

### 🐛 修复

- **修复「清理缓存」可能误删其它文件**：桌面端系统临时目录是全机共享的（如 Linux 的 `/tmp`），现在只统计不再递归删除；清理范围收敛到 App 自建的 `images/` 与 `misc/` 子目录。
- **自定义缓存目录新增安全校验**：目录里若已有其它文件会直接拒绝设为缓存目录，避免一次清理把整个目录删空。
- **修复搜索分页串页**：在分页请求返回前换一个关键词重新搜索，旧关键词的结果不再混进新列表。
- **修复封面保存的文件名**：相册里不再出现 `歌手 - 歌名.jpg.jpeg` 这种双扩展名。
- **修复 GIF / WebP 封面**：按真实图片格式写文件扩展名，不再一律存成 `.jpg` 导致部分播放器不显示。
- **修复设置页多处 `setState` 越界**：打开设置页后立即返回、或在选择目录对话框中返回时不再抛异常。
- **修复更新日志里的图片撑破弹窗**：窄屏下图片按可用宽度自适应，不再溢出。

## 2.2.0

### ✨ 新增

- **本地音乐**：支持扫描本地目录、读取元数据、加入曲库并播放，可自定义扫描目录、多目录管理、增量刷新。
- **QQ 音乐 Cookie 登录**：支持粘贴浏览器 Cookie 登录，兼容网页版**微信登录**（`wxuin` 填在 `uin` 处），并按票据前缀自动判定账号类型。
- **QQ 音乐二维码登录修复**：修正了状态码 65 / 66 的语义颠倒问题。

### 🐛 修复

- **修复本地音乐扫描卡死**：扫描 Isolate 增加 10 分钟超时兜底，超时后强制回收，不会一直转圈。
- **修复登录票据前缀丢失**：微信登录票据不再被截断。