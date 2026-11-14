# 白姬音乐 · Baiji Music

跨平台音乐播放客户端，一套 Flutter/Dart 代码同源支持 **iOS / macOS / Windows / Linux / Android / HarmonyOS（鸿蒙）** 六端，
UI 采用暗色玻璃拟态 + 霓虹渐变的现代化未来感设计，构建期自动执行**加壳与混淆**防逆向。

> 本工程由「白姬音乐 Android 原生 v1.1.1」重构而来：C 算法库（hash33 / zzc_sign / tripledes / qrc / qimei / comm）全部移植为纯 Dart，
> 网络层支持 **QQ 音乐 / 网易云音乐 / 酷我音乐 / 酷狗音乐** 四音源，功能模块覆盖搜索、播放、歌单、下载、扫码登录与本地音乐。

---

## v2.5.8-fix2 修复速览（正式修订版）

| 能力 / 修复 | 说明 |
| --- | --- |
| 🐛 **酷狗 360RA 无法解码** | 酷狗下发的是 MPEG-H 3D Audio 容器（stsd fourcc = `mhm1` + `mhaC` 内联配置），media_kit 的 ffmpeg 没有该解码器，直链只会报 `Failed to recognize file format.`。逆向官方 32/64 位 APK 确认该容器与 QQ 音乐 RA0x **同型**（同一套 Sony SAL SDK，mp4 解析器均支持 `mhm1`/`mhaC`），现接入同一条原生解码管线，缓存 key 与 QQ 侧隔离 |
| 🎵 **边转码边播放** | DTS:X / 360RA / NAC 此前是「整曲解码完再播」，NAC 需 1~2 分钟、360RA 需数十秒且全程无声。现原生解码器边解边写、本机 HTTP 服务实时推流给播放器，**首帧到达即出声**；流式失败自动回落到整曲解码缓存 |
| ⚙️ **日志自定义保存位置** | 设置页新增「日志保存位置」，可自选目录（如 SD 卡）方便直接抓日志；切换时写入预检，目录不可用时静默回落默认目录并记 warn；旧日志留在原处不迁移 |
| 🧪 **回归测试** | 新增流式播放、酷狗 360RA 路由、日志自定义目录三组单测，全量 **1211 项通过** |

## v2.5.8-fix1 修复速览（正式修订版）

| 能力 / 修复 | 说明 |
| --- | --- |
| 🐛 **酷狗 360RA 不展示** | 服务端对 `360ra_l1/l2/l3` 一律不下发 `filesize`（为 0）却给了真实 hash，旧解析误判为「档位无效」整批丢弃（如杨丞琳《雨爱》）。改为只看 `quality + hash`，`filesize` 仅作元数据 |
| 🐛 **NAC 转 WAV 后播放不了** | 原生解码边解边写最终 wav，NAC 需 1~2 分钟，期间缓存命中的是 44 字节全 0 占位头的半成品 → `Failed to recognize file format.`。改为写 `.part` + WAV 完整性校验 + 原子落盘，并清理历史残文件；DTS:X / 360RA 同步加固 |
| 🎵 **本地音乐支持特殊音质** | 扫描收录 `.nac` / `.dts*` / `.mha1` / `.mhm1` / `.ac3` / `.eac3` / `.ec3` / `.av3a`；NAC / DTS:X / 360RA 播放前自动转码成 WAV 并缓存，杜比 AC-3 / E-AC-3 由 media_kit 直解 |
| 🧪 **回归测试** | 新增 WAV 缓存与本地特殊格式两组单测，补齐《雨爱》真实接口响应回归 |

## v2.5.8 更新速览（正式版）

> 本版起**不再适配洛雪（LX）音源**，彻底移除相关代码与依赖，回归
> **QQ 音乐 / 网易云音乐 / 酷我音乐 / 酷狗音乐** 四音源的正式版本。

| 能力 / 修复 | 说明 |
| --- | --- |
| 🗑️ **移除洛雪音源全部代码** | 删除整个 `lib/lx/` 运行时（宿主引导 / HTTP 桥 / 加密桥 / 双引擎抽象 / 取流入口 / 音源仓库 / 更新检测）、音源管理与音源测试两个页面、纯洛雪开关与「取链失败自动切换音源」、对应的 7 组单测，以及 `third_party/quickjs_runtime` 第三方引擎源码 |
| 📦 **精简依赖与构建** | 移除 `flutter_js` / `quickjs_runtime` 及其传递依赖；`pubspec.lock` 与 iOS / Android / macOS / Windows / Linux 的插件注册表重新生成；回退仅为洛雪引入的 Android JVM target 兼容配置、CI 中 flutter_js 的 sed 与 Windows build hook 诊断。`crypto` / `pointycastle` / `ffi` 等原生能力依赖完整保留 |
| 🎵 **回归四音源** | 播放取流回归 QQ / 网易云 / 酷我 / 酷狗各自平台内部的音质降级链，功能不受影响；设置页、平台下拉、播放器、数据模型中的洛雪分支全部清理 |
| 🧪 **测试** | `flutter analyze` 零问题；全量 `flutter test` **1165 项全绿**（删除 7 组洛雪单测后精确回落到洛雪前基线） |

## v2.5.6 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 📂 **工具箱升频支持自定义保存位置** | 「本地升频 · 蝰蛇母带」新增「保存位置」目录选择 + 写入预检，`KvStore` 持久化（重启自动恢复），自定义时可「恢复默认」。此前产物只能写死到应用私有 `viper_upscale/` 目录 |
| 🐛 **修复蝰蛇母带「本地升频失败（引擎异常）」** | 真机上「升频完成」后紧接着「引擎异常降级 320k」。两个并发根因：① 解码中间文件 `*.viper48k.wav` / `*.part` 用固定名，同曲并发升频共用，先完成者 `finally` 删掉另一个 isolate 正在读的文件 → 每次调用加唯一 token 隔离；② `enforceCacheQuota` 把 `*.viper48k.wav`（以 `.wav` 结尾）误判为「已完成产物」淘汰、单文件 IO 异常让整轮淘汰中断 → 新增 `isTransientFile` 精确分类，只有最终产物参与淘汰、瞬态文件仅回收陈旧残留、逐文件容错 |
| 🧪 **测试** | 新增 6 项离线单测（瞬态文件分类 / 并发不误删 / 陈旧残留回收 / 保存位置入口）；`flutter analyze` 零问题，全量 **1165 项**通过 |

## v2.5.5 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🐛 **修复酷狗评论误报「未登录」（10000）** | 用户登录有效却返回 `10000 未登录`。根因：评论写接口用了**写死固定 `commentMid`**，与登录 token 绑定的**设备 mid** 不一致 → 网关判 token 无效。项目里我的歌单 / 每日推荐 / 取链 / 歌词等已成功的登录接口全用设备 mid，唯独评论用固定常量，同一批 token 前者通后者 10000，差异只在 mid。修复：写接口改用 `KugouAuth.device().mid`（与登录配套），固定 `commentMid` 仅留给免登录的读评论 / 取 res_id |
| 💬 **酷狗评论 60045 = 服务端风控** | 用户又遇 `60045 发布失败`。逆向倾听 5.6.14 确认：`60045` 是账号 / 设备级反垃圾（风控）的笼统拒绝码，**与正文无关**（正常中文也被拒）；倾听对其无特殊处理、只透传 `message`，官方酷狗也仅在风控时弹滑块验证。客户端无法绕过，本版把提示从含糊「敏感词」改为如实说明「被服务端风控拦截，请稍后重试或换账号」；保留空 / 纯数字 / 空白的轻量预校验（但明确它不是 60045 的解法） |

## v2.5.4 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🎧 **酷狗音质改用服务端权威档位** | v2.5.2 的音质推导全靠猜——酷狗搜索响应里根本没有 `trans_param`，那套「key 名含 360/mha」的启发式**永不命中**，于是 360RA / 蝰蛇 HiFi / 杜比 448k·1500k 一律不展示。改接 `goodsmstore/v1/get_res_privilege` 权威探测，补建三个从未真正建过的枚举（蝰蛇 HiFi / 杜比 448k / 杜比 1500k）；下载弹层从 4 档扩到 **10 档**，未登录时高规格档**置灰**而非隐藏。实测《稻香》服务端下发 8 档，含此前完全缺失的 `viper_hifi` |
| 🎬 **酷狗 MV 播放源** | 按上传的 ikun.js 实现 `m.kugou.com/app/i/mv.php`；画质档 `le/sd/hd/sq/rq` → **480p/720p/1080p/1080p/4K**，同 quality 取 `filesize` 更大的一路。顺带修掉网关个别节点回 `text/html` 导致的解析失败 |
| 💬 **酷狗评论：查看 + 发表** | 协议逆向自倾听 5.6.14 的 APK。**读**免登录（`m.comment.service…/rank/{newest,topliked}`，实测最新 19 条 / 最热 20 条）；**写**需登录，两层签名 `key = md5(appid+salt+clientver+clienttime+mid+body)` + `signature = md5(salt+sorted(k=v)+body+salt)`，标准身份被判未登录时自动切概念版重试。诚实边界：点赞本版未接入（UI 有提示），楼中楼只发不拉 |
| 📂 **酷狗歌单 / 每日推荐 / 我的歌单** | 推荐歌单 + 六大分类 + 歌单歌曲 + 搜索歌单 + 每日推荐（每天 30 首，新增独立页面）+ 我的歌单（需登录）。「我的歌单」接口的**签名盐是歌词盐而不是网关盐**，用错盐服务端一律 `20006 参数验证失败` |
| 🔀 **平台切换改下拉** | 发现页「推荐歌单」「我的歌单」的平台切换由平铺标签改为**点击展开平台列表**的下拉，与搜索页一致 |
| 🐛 **修「切到酷狗还是 QQ 的歌单」** | `hotPlaylistsOf` 的 switch 漏了酷狗分支，酷狗落到 `default` **静默返回 QQ 数据**；热搜入口同样漏了。已补 `KugouHot` + `HotPlaylist.fromKugou` |
| 🧪 **测试** | 新增 `kugou_playlist_test.dart`（23 项，全离线），锁定「我的歌单用歌词盐」等关键协议约定；沙箱端到端实测五套接口全部字段解析正确；`flutter analyze` 零问题，全量 **1154 项**通过 |

## v2.5.3 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🐛 **修复真机「本地升频失败」** | v2.5.2 的升频在 Android 上必失败并降级播放原始 320k。**三个**根因均已修复：① 内置裁剪版 ffmpeg 的 muxer 白名单**没有 `s16le`**（旧代码 `-f s16le` 必报 `Requested output format 's16le' is not known.`），改用 `-f wav` + `-c:a pcm_s16le`；② 整段实现内存峰值约 **2.2 GB** 必 OOM，改为**全链路流式**（分块解码 → 逐帧升频 → 分块写 WAV），实测 4 分钟音频内存峰值仅 **144 MB**；③ 产物是 264 MB/首的大 WAV，缓存没有容量上限会把手机存储吃满，改为**最旧优先的配额淘汰**（默认 2 GB） |
| 🛠 **升频管线重构** | 新增流式 WAV 读写器（内存常数级）；峰值保护改为逐样本软拐点（拐点以下完全透明）；缓存产物先写 `.part` 再原子改名，杜绝半成品被当成有效缓存；缓存命中加 RIFF/WAVE 魔数校验，损坏缓存自动删除重算 |
| 💬 **失败提示可行动** | 播放链路升频失败时区分「未找到解码引擎 / 音频解码失败 / 内存不足 / 缓存写入失败」，不再只有一句笼统的「失败」 |
| 🧪 **测试** | 新增 17 项管线回归（流式与整段数值一致偏差 < 1e-9、分块无关性、流式 WAV 往返、ffmpeg 参数断言、缓存配额淘汰顺序、损坏缓存识别）；端到端实测 320k MP3 → 192kHz/24bit，时长精确、主频无偏、无补零静音；`flutter analyze` 零问题 |

## v2.5.2 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🔬 **找到并加入蝰蛇母带升频算法** | 反编译官方 `libsuperR.so` 还原出 `STFT → 端侧 DNN 超分(NPU) → ISTFT/OLA → 192kHz/24bit`；官方模型权重闭源且绑定天玑 NPU 无法移植，故按相同骨架用纯 Dart 公开算法同构复刻：FFT / Hann STFT、SBR 频域带宽扩展、感知焕新、一次 ISTFT 直出 96k/192k 24bit WAV |
| 🎧 **播放链路接入** | 选「蝰蛇母带」取 320k 源文件 → 本地重建 192kHz/24bit WAV → 缓存播放，失败诚实降级；isolate 后台处理、缓存可清理 |
| 🧰 **工具箱离线升频** | 新增「本地升频」页，把本地音频转成 96k/192k 24bit WAV，含引擎状态、进度、结果规格与分享 |
| 🎵 **酷狗音质补全** | 补蝰蛇超清 / 蝰蛇全景声 / 蝰蛇母带 / 杜比全景声 / 360RA；实测确认 360RA 代号为 `360ra_l1/l2/l3`；列表仍按歌曲实际能力推导，不常驻 |
| 🔧 **修复默认音质** | 设置页补齐「酷狗音乐播放音质」，此前只有 QQ / 网易云 / 酷我 |
| ⚠️ **诚实边界** | 高频为依据低频重建的感知近似，非原始母带信息；下载音质不含升频档，不把 320k 冒充母带 |

## v2.5.1 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🐛 **修复酷狗无法搜索** | 网关签名 salt 一个字符顺序抄错（`...092lski` → `...092lksi`）导致 `err signature` 空列表，已对照 HotDownloader 逐字节校正；取链 `quality` 参数改回服务端认可的 `128 / 320 / flac / high` |
| 🔐 **新增酷狗登录** | 对齐 HotDownloader + 倾听 5.6.14：二维码扫码（服务端下发 PNG + 状态轮询）+ 手动 `userid / token`；设备三件套与会话持久化、启动恢复、登录态监听 |
| 🎧 **登录解锁高音质** | 登录凭据随设备参数注入取链（urlKey 带真实 userid），未登录高音质被判版权/会员限制，登录后可取无损 FLAC / Hi-Res |
| 🧪 **测试** | 新增 27 项酷狗回归 + 登录页冒烟；`flutter analyze` 零问题 |

## v2.5.0 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🎵 **新增酷狗音乐平台** | 完全对齐 HotDownloader：搜索 / 播放 / 下载全覆盖，标准 128K / 高清 320K / 无损 FLAC / Hi-Res 四档音质；KRC 逐字歌词解密（逐字时间轴 + 译文 + 罗马音）；品牌绿 `#1EC17D` 主题，与酷我平级接入 |
| 🖼️ **歌词封面获取插件更新** | 接入 Lyrico-Plugins-3 的酷狗封面分支（`{size}`→480、`http`→`https`），与 QQ / 网易云封面同链路 |
| ✨ **歌词效果复刻 kunyin** | Apple Music 风格：当前行不再放大、靠不透明度区分层次（非当前 0.4 / 当前未唱 0.6 / 已唱纯白），平滑滚动锚点居中、关闭距离模糊、逐字软边擦除、译文排在正文下方、间奏呼吸圆点 |
| 🧪 **测试** | 新增歌词预设回归锁定 kunyin 视觉参数；`flutter analyze` 零问题 |

## v2.4.11 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🎚️ **修复网易云音质严重缺失** | v2.4.10 只按 `l/m/h/sq/hr` 文件对象过滤，把 9 档砍成 3~4 档。基础档改为「文件对象 ∪ `privilege.chargeInfoList` 码率 ∪ `maxbr`」并集，补回被漏掉的无损 / Hi-Res |
| 🎧 **空间 / 母带档常驻** | 臻音全景声 / 杜比全景声 / 超清母带 / 沉浸环绕 / 高清环绕是**播放等级档**（服务端自动降级、接口无歌曲级标记），改为常驻不参与按歌过滤；QQ / 酷我仍严格按歌曲过滤 |
| 🧪 **测试** | 用真实接口响应片段补 5 项回归；全量 994 → **999** 项全绿，`flutter analyze` 零问题 |

## v2.4.10 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🎚️ **音质列表改为按歌曲真实音质** | 修复「每首歌都一样、显示的不是歌曲拥有的音质」：网易云不再误用 `privilege` 里的账号等级，改按歌曲文件对象 `l/m/h/sq/hr` 判定；三首音质不同的歌现在给出不同档位，也不再虚报 Hi-Res / 全景声 |
| 🧩 **旧歌曲按需补全** | 历史 / 收藏 / 歌单里没有音质标记的老数据，打开弹层时按平台查一次详情补全（QQ 详情 `file` / 网易云 `/v3/song/detail` / 酷我 `songInfo`），带进程内缓存；失败仍回退全量 |
| 🔗 **不再丢标记** | 网易云专辑接口补齐专辑名改用 `copyWith`，保留已解析的 `qualityCodes` |
| 🧪 **测试** | 重写网易云用例并新增链路回归，音质可用性测试 16 → 24 项；全量 986 → **994** 项全绿，`flutter analyze` 零问题 |

## v2.4.9 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🤖 **Android 转码引擎改为动态 PIE** | 修复「引擎已找到但转码报错」：v2.4.8 的 static-PIE 无 `PT_INTERP`，真机 `execve` 易被 SELinux / seccomp 拒绝。改为 `ET_DYN` + `/system/bin/linker64` 的动态 PIE，仅依赖系统 `libc` / `libm`；同一份源码与白名单重编三 ABI，托管 `libs-ffmpeg-v2`，编译脚本默认 `dyn` |
| 🔍 **引擎自检 + 错误可见** | 探测到引擎后实跑 `ffmpeg -version` 并显示结果；转码失败保留退出码、完整输出路径与 stderr 末尾数行 |
| 💾 **自定义保存位置** | 「应用目录 / 公共音乐 / 自定义」一键切换，可手动输入路径，选择持久化；切换与开始前做写入预检，公共目录自动申请「所有文件访问权限」；完成后显示并可复制完整路径 |
| 🎚️ **音质列表按歌曲过滤** | 播放页与搜索页的音质弹层只显示这首歌实际有的档位（QQ `file.size_*` / `size_new`、网易云 `privilege`、酷我 `N_MINFO`），零额外请求；无标记时回退全量。设置页全局默认音质保持全量 |
| 🧪 **测试** | 新增 16 项音质解析 / 过滤离线测试；全量 970 → **986** 项全绿，`flutter analyze` 零问题 |

## v2.4.8 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🤖 **Android 内置转码引擎** | 修复 v2.4.7 在安卓端「未找到 ffmpeg」。用 NDK 28.2 交叉编译裁剪版静态 FFmpeg 7.1.3（static-PIE、无动态库依赖、API 24+，三 ABI 共约 7MB），白名单只启用 10 种输出所需编码器 / muxer，未启用任何 GPL 组件；打成 `lib/<abi>/libffmpeg_exec.so` jar 托管在 `libs-ffmpeg-v1` release，构建期下载 + MD5 校验，编译脚本见 `tools/build-android-ffmpeg.sh` |
| 📦 **可执行性打包** | `packaging.jniLibs.useLegacyPackaging = true` + Manifest `extractNativeLibs="true"`，安装时系统把 `.so` 释放到 `nativeLibraryDir` 并授予执行权限（Android 10+ W^X 下唯一可执行随包二进制的位置）；`MainActivity` 新增 `baiji/native` 通道把该目录交给 Dart，探测顺序变为「手动指定 / `BAIJI_FFMPEG` → Android 内置引擎 → 随包 `bin` → 系统 PATH」 |
| 🔓 **特殊格式解绑** | DTS:X / 360RA / NAC 直出 WAV 走自研 FFI，本就不需要 ffmpeg；v2.4.7 的前置硬校验却把这条唯一能在 Android 跑的能力挡住了。现在 `ffmpegPath` 可空，仅在普通格式或自定义声道 / 采样率 / 位深时才校验引擎，并给出精确指引 |
| 🧪 **测试** | 新增 10 项离线测试（内置引擎探测优先级、解绑后无 ffmpeg 直出标准 PCM WAV、缺引擎报错路径）；qemu 跑真 Android 引擎端到端 12/12 通过；全量测试 960 → **970** 项全绿 |

## v2.4.7 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🎵 **音频转码（工具箱新增）** | 「工具箱 → 音乐工具 → 音频转码」：支持 WAV / FLAC / M4A / MP4 / WMA / AAC / AC-3 / E-AC-3 / MP3 / OGG 输出，可自定义声道数、采样率、位深、码率；批量选文件 / 选文件夹、进度显示、随时停止、同名产物自动追加序号不覆盖。引擎走标准 ffmpeg 可执行文件（播放内核内嵌的是纯解码 ffmpeg，无编码器 / muxer），自动按「手动指定 → `BAIJI_FFMPEG` → 随包内置 `bin` → 系统 PATH」探测，桌面端通常开箱即用、移动端可手动选择 |
| 🎧 **特殊音质转码** | DTS:X / 索尼 360RA / NAC 走 App 自研原生解码器直接产出 PCM WAV，AV3A 由 ffmpeg 解码成 WAV；这四种按产品约束**只能输出 WAV**，选择其它格式会自动锁定。mp4 / ac3 / eac3 等 ffmpeg 可解格式既可作输入也可作输出 |
| 🐛 **CI 两个 bug** | ① Android 构建的 3 次重试循环三次全失败时仍可能以 0 退出（最后一条命令是 `sleep`），导致「构建失败却标记成功」——改为显式 `built` 标志 + 失败 `exit 1` + APK 产物兜底校验；② 注释把首次 Android 失败根因误写成 NDK 缺失，按 CI 日志更正为 Kotlin compiler jar 下载 504（大依赖瞬时抖动，与 NDK / 原生代码无关） |
| 🧪 **测试** | 新增 36 项转码核心离线测试，沙箱用真实 ffmpeg 端到端验证 10 种输出格式均可产出、ffprobe 可读、解码 PCM 非静音（可播放）；全量测试 924 → **960** 项全绿 |

## v2.4.6 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🐛 **切换音质后播放进度从头开始（全平台）** | 音质切换 / 自动降级 / baka 重试重开播放时进度丢失：`open()` 内部先 `stop()` 把进度归零、再异步 `loadlist` 加载新轨道，返回时轨道尚未就绪，紧接发出的 `seek` 会被 mpv 丢弃。改为先挂载轨道（`play:false`）→ 等 `duration` 就绪 → 定位续播 → 再正式 `play()`；切音质前的位置作为 `resumeAt` 透传给取流链路，不同音质时长超界时夹到末尾 |
| 🔧 **Android 构建偶发失败** | CI 构建前显式用 `sdkmanager` 安装 NDK 28.2.13676358 并给构建加重试，不再依赖 AGP 静默现下载 |
| 📖 **文档** | README 版本速览补齐 v2.4.3–v2.4.6，测试数量同步为 924 项 |

## v2.4.5 更新速览

| 能力 / 修复 | 说明 |
| --- | --- |
| 🚀 **解码器提速（DTS / 360RA / NAC）** | DTS 去掉整曲解码的 `tmpfile()` 磁盘中转、循环内直写 s16；NAC 推理线程数按设备在线 CPU 核数自适应（封顶 8、保底 2）；360RA 新增 256KB 输出缓冲攒批落盘，减少写 syscall |
| 🐛 **网易云登录歌单只显示 10 首** | 改用 v6 歌单详情接口取全量 `trackIds` + 分批（每批 100）调歌曲详情补齐，按 id 顺序还原，解决大歌单被老接口 10 首预览截断 |
| 🐛 **360RA WAV 头错位** | 解码结尾回填真实 WAV 头前补 `fseek(0)`，避免真头被写到 PCM 数据之后、播放器读到 0 字节数据 |

## v2.4.4 修复速览

| 修复项 | 说明 |
| --- | --- |
| 🐛 **静态代码审查报告中的崩溃与资源泄漏** | `CoverUrl.primary` 空封面返回空串不再抛 `StateError`、`Song.fromTrack` 脏字段容错、播放器 6 个原生流订阅在 `release()` 统一取消（`release()` 只释放底层播放器、不关常驻广播流）、`DownloadTaskRegistry.dispose`、QQ / 网易云 / 酷我解析脏 JSON 类型守卫等 |

## v2.4.3 新增速览

| 能力 | 说明 |
| --- | --- |
| 🎬 **MV 播放（三平台：QQ 音乐 / 网易云 / 酷我）** | 播放页顶栏新增 MV 按钮（打开时自动暂停音乐、本地歌曲不显示、桌面端暂不支持）：QQ `GetMvUrls` 按 vid 取流支持 360p–4k 多档画质 + 多 CDN 备用，网易云 weapi 加密取流，酷我多档 |

## v2.4.2 更新速览（预发布 pre1–pre7）

| 能力 / 修复 | 说明 |
| --- | --- |
| 🎼 **QQ 音乐臻品 DTS:X（DT03）解码** | 集成 DTS 官方 Playback SDK（QQ 音乐同款内核，arm64/v7a 双 ABI，MD5 锚定官方清单）+ 自研 `dts_glue` 原生模块：MP4 `dtsx` 轨 demux + 许可注入 + `DecodeDTS` 循环，Dart FFI 直调后台解码成 WAV 缓存播放，二次播放零等待；双 ABI QEMU 全曲验证 12847 帧 0 失败、输出一致 |
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
│   ├── network/                # QQ 音乐 + 网易云 + 酷我 + 酷狗网络层（含 QMC 解密、f=ar 登录协议、评论、歌词解码、热搜榜、分享歌单解析、酷狗歌单/每日推荐/MV）
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

## 四音源能力

- **QQ 音乐**：登录（扫码 / Cookie / **短信验证码**，Cookie 登录同时支持 QQ 与微信账号）、搜索（综合 + 单曲）、歌曲详情、播放地址（320→192→128 降级链）、歌词解密（QRC）、下载、**评论浏览与发表**（风控触发时内嵌 WebView 完成滑块验证自动重试）、**QMCv2 加密音轨流式解密播放**。
- **网易云**：登录（**手机号验证码** / Cookie）、搜索、播放地址（EAPI 加密）、加密 ID（encryptId）、**我的歌单**、**杜比全景声（E-AC-4 JOC）与臻音全景声（AVS3-P3 / Audio Vivid，v2.4.2 自研解码器直解）**。
- **酷我音乐**（v2.4.0 新增）：搜索、歌曲详情、播放地址、歌词（Base64 → XOR → zlib → GB18030 解码）、下载、**登录（v2.4.1：账号密码 / 短信验证码）**、**评论浏览（v2.4.1，只读）**。
- **酷狗音乐**（v2.5.0 新增）：登录（二维码扫码 / 手动 `userid`+`token`）、搜索、播放地址、歌词（KRC 逐字：逐字时间轴 + 译文 + 罗马音）、下载、**10 档音质（服务端权威档位探测，含 360RA / 蝰蛇 HiFi / 杜比双码率）**、**MV 播放源**、**评论浏览与发表**、**推荐歌单 / 分类 / 歌单歌曲 / 搜索歌单 / 每日推荐 / 我的歌单**。

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

### QQ 音乐臻品 DTS:X 解码（v2.4.2-pre8：dts_glue 独立管线）

DTS UHD（Profile 2 / `dtsx`）无开源解码器、ffmpeg 也不支持，因此**不走 libmpv**，
由独立原生管线承载：选 DT03 档时 App 下载 QQ 的 DT03 mp4（未加密标准封装），
`dts_glue` 原生模块完成「demux → 解码 → WAV」，再交给 media_kit 当普通文件播放：

| 环节 | 实现 |
| --- | --- |
| 解码内核 | DTS 官方 Playback SDK（与 QQ 音乐同款；`jniLibs` 打包 arm64-v8a / armeabi-v7a，MD5 锚定官方 `so_info.json`） |
| 许可 | APK 内置 DSEC 许可（`dts_hpx.lic`，有效期至 2033）+ Playback 配置（`dts_config.yaml`） |
| demux | 自研 MP4 解析（遍历 trak 匹配 `dtsx` fourcc，支持 co64 / 变长 stsz），无第三方依赖 |
| 接入层 | 纯 C API（`dtsglue_init/open/decode_to_wav`）+ Dart FFI 直调，无 JNI 桥；解码跑在后台 Isolate |
| 缓存 | 解码产物 WAV 存应用缓存，二次播放零等待；失败自动沿音质降级链回落 |
| 验证 | 双 ABI 在 QEMU 全曲解码 12847 帧 0 失败（274.07s @48kHz，与元数据吻合），arm64 与 v7a 输出逐帧一致 |
| 兼容性 | x86 系列无官方解码库，运行时探测自动跳过 DT03 档 |

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

## 音频转码（工具箱）

「工具箱 → 音乐工具 → 音频转码」把本地音频文件转成目标格式，支持批量选文件 / 选文件夹、
逐任务进度显示、随时停止，同名产物自动追加 `(2)/(3)` 不覆盖已有文件。

**输出格式**：WAV、FLAC、M4A、MP4（AAC 音轨）、WMA、AAC、AC-3、E-AC-3、MP3、OGG。
**可自定义参数**：声道数（保持源 / 1 / 2 / 4 / 6 / 8）、采样率（保持源 / 32k–384k Hz）、
位深（16 / 24 / 32 bit，仅 WAV / FLAC 生效）、码率（96–1411 kbps，仅有损格式生效）。
`buildFfmpegArgs()` 统一构造 `-vn -map 0:a:0 [-ac N] [-ar RATE] -c:a CODEC [-sample_fmt FMT] [-b:a Nk] -f MUXER`，
显式指定容器避免扩展名与编码器推断不一致；进度解析 `-progress pipe:1` 的 `out_time_us`。

**转码引擎**：App 播放链路（media_kit / libmpv）内嵌的 ffmpeg 是
`--disable-muxers --disable-encoders --disable-programs` 的**纯解码白名单构建**，能解几乎所有
音质（含 `ac3` / `eac3` / `av3a` / `ac4` / `dca`），但**没有音频编码器、没有 muxer、没有 ffmpeg 命令行**，
无法产出文件。因此转码调用标准 ffmpeg 可执行文件：

- **Android（v2.4.9 起）**：随 APK 内置裁剪版**动态 PIE** ffmpeg（FFmpeg 7.1.3 + lame / libogg / libvorbis，
  NDK 交叉编译，带 `PT_INTERP=/system/bin/linker64`，仅依赖系统 `libc` / `libm`），打包为
  `lib/<abi>/libffmpeg_exec.so`，安装时由系统释放到 `nativeLibraryDir` 并授予执行权限，
  `baiji/native` 通道取到目录后自动探测并跑一次 `-version` 自检，**开箱即用**。
  v2.4.8 的 static-PIE 无 INTERP，真机 `execve` 会被系统拒绝，已弃用。
  二进制托管在 `libs-ffmpeg-v2` release，构建期下载 + MD5 校验，编译脚本 `tools/build-android-ffmpeg.sh`。
- **桌面端**：按「页面手动指定 / 环境变量 `BAIJI_FFMPEG` → 随包内置 `bin/ffmpeg[.exe]` → 系统 PATH」
  探测，通常系统已装可直接命中。

找不到引擎时给出明确提示而不是静默失败；DTS:X / 360RA / NAC 直出 WAV 例外见下。

**保存位置**：支持「应用目录 / 公共音乐 / 自定义」切换并持久化，自定义可选文件夹或直接输入绝对路径；
切换与开始转码前都做写入预检（写探针文件），Android 公共目录需要 `MANAGE_EXTERNAL_STORAGE`
（页面会自动申请「所有文件访问权限」）。转码完成后任务项显示完整输出路径，可一键复制。

**特殊音质约束**：DTS:X、索尼 360RA、NAC、AV3A 四种**只能输出 WAV**，选其它格式会自动锁定。
前三者走 App 自研原生解码器（`decodeLocalToWav()`，复用与在线播放同一套 FFI）直接产出 PCM WAV，
**不依赖 ffmpeg**——许可、BRIR 系数、NAC 模型均来自 APK 内置 assets，全程离线；
AV3A 交给 ffmpeg 解码成 WAV（当前 ffmpeg 若无 `av3a` 解码器会明确报错）。
特殊格式识别靠扩展名 + 文件头 / 尾部 fourcc 魔数（`dtsx` / `mha1` / `mhm1` / `av3a` / `ac-3` / `ec-3`）
+ 下载文件名音质标记兜底；mp4、ac3、eac3 等 ffmpeg 可解格式既可作输入也可作输出。
若对特殊格式额外指定了声道 / 采样率 / 位深，才需要在解码出的 WAV 上再跑一次 ffmpeg 做 PCM 变换
（此时若引擎不可用会提前提示清除自定义参数，避免白解码一遍）。

## 音质列表（按歌曲实际音质）

播放页「下载音质」「切换音质」与搜索页下载弹层，列出当前歌曲**实际拥有**的档位，没有的隐藏；
设置页的**全局默认音质**没有歌曲上下文，仍保持全量。`Song.qualityCodes` 由各平台搜索 / 详情接口
解析，随 JSON 持久化。判定口径是「**歌曲存在该音质文件**」：即使当前账号没会员也列出（点了再提示
权限），不按账号等级裁剪列表。

**例外（v2.4.11）**：网易云的臻音全景声 / 杜比全景声 / 超清母带 / 沉浸环绕 / 高清环绕是
**播放等级档**，不是歌曲文件档——搜索 / 详情接口都不给歌曲级标记（`qualities` 恒为 null，
`maxBrLevel` / `playMaxBrLevel` 对所有歌都是同一个账号上限 `vivid`），服务端在歌曲没有对应
内容时会自动向下匹配可用流，官方客户端也是常驻显示、按 VIP 灰置。因此这 5 档通过
`NeteaseQuality.alwaysAvailable` 常驻，不参与按歌过滤；基础档仍严格按歌曲码率过滤。

| 音源 | 判定依据 |
| --- | --- |
| QQ 音乐 | `track_info.file` 的 `size_128mp3` / `size_flac` / `size_hires` / `size_dts` / `size_dolby` / `size_360ra` / `size_*aac` / `size_*ogg` 与 `size_new` 位图（臻品母带 / 臻品音质 2.0 / 全景声 / OGG320 / 黑胶 / OGG640 / NAC / DTS:X），覆盖全部 25 档 |
| 网易云 | **基础档**取 `l/m/h/sq/hr` 文件对象 ∪ `privilege.chargeInfoList` 的 `rate`（128k/192k/320k/999k/1999k）∪ `maxbr` 数值的并集（任一来源缺失都不漏档，兼容老版 `lMusic/hMusic/...` 与开放平台 `qualities`）；空间 / 母带档见上方例外，常驻；**不读** `playMaxBrLevel` / `maxBrLevel` / `plLevel`（账号等级，实测所有歌都返回 `vivid`） |
| 酷我 | 搜索结果 / `songInfo(rid)` 的 `N_MINFO` 解析出的 `KuwoSong.qualities`（接口本来就带音质列表） |

升级前持久化的历史 / 收藏 / 歌单，以及部分歌单 / 分享歌单接口构造的歌曲没有标记：打开音质弹层时
`MusicApi.ensureQualityCodes()` 会按平台查一次详情补全并刷新选项（进程内缓存，同一首歌只查一次），
失败或接口仍未给标记时回退全量档位，保证弹层永远有可选项；过滤结果为空时同样回退。

## 测试与质量

- `flutter test`：**1165 项测试全绿**。新增**音质可用性回归（29 项：QQ / 网易云 / 酷我音质标记解析、码率并集与常驻档位、过滤与全量回退、`Song.qualityCodes` 序列化与 `copyWith`，用真实接口响应片段驱动）**；以及**音频转码核心回归（46 项：格式枚举与扩展名反查、参数校验边界、特殊格式扩展名 / fourcc / 裸流魔数嗅探、wavOnly 锁定 WAV、ffmpeg 参数构造与 10 种 muxer、同名输出去重、ffmpeg 路径探测优先级、Android `nativeLibraryDir` 内置引擎探测、解绑后无 ffmpeg 时 DTS / 360RA / NAC 直出标准 RIFF/WAVE PCM WAV 并断言非静音、缺引擎与解码器不可用的报错路径）**；并在沙箱用真实 ffmpeg 与 `qemu-aarch64-static` 跑真 Android 引擎做端到端验证（10 种输出格式均可产出、ffprobe 可读、解码成 PCM 后非静音可播放、进度回调正常、同名不覆盖）。原有覆盖 QQ 音乐签名算法（hash33 / zzc_sign / tripledes / qrc 解密，与 C 源码参考向量逐字节对照，含 15 字节 zzc_2 修复）、网易云加密、**网易云歌单全量还原（5 项：按 trackIds 顺序合并、分批跨批有序、下架曲目跳过、空列表、修复前只取 10 首预览的丢曲对照）**、**酷我 QMC 解密与歌词解码**、模型解析、二维码登录状态码语义、Cookie 登录的 QQ/微信两种账号形态（15 项）、封面 URL 降级、协议弹窗交互、版本检查、播放页进度条与倍速与音质偏好回归，**酷我 QMC v2 真实向量回归（6 项：用真实 ekey + 真实密文/明文前 6144 字节锁死解密链与 seek 一致性）**，**酷我 18 档音质与播放缓存回归（21 项：音质表逐字段对齐、播放缓存块边界与写读清闭环、中继 Range 逐字节正确、seek 任意偏移、二次请求命中缓存不回源）**，**酷我 `f=ar` 协议编解码（21 项：q 参数与响应体固化向量、协议往返、坏输入拒绝、填充规则）**，**酷我登录核心（28 项：设备身份形制与自愈、会话 JSON 往返、手机号校验、短信 secret 独立参考向量、口令 SM4 加解密、登录态监听）**，**酷我评论解析（18 项：真实抓包样本、时间串解析、分页边界、脏数据降级）**，以及本地音乐的元数据解析（五种容器 38 项）、扫描与增量（30 项）、持久化与页面（13 项）。
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