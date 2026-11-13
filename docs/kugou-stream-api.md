# 酷狗音乐全接口与签名 Salt 完整说明

> 来源：本仓库 `lib/network/kugou/`、`lib/network/mv/kugou_mv.dart`、`lib/network/hot_search_api.dart`、`lib/network/playlist_api.dart` 的实现（逆向自 HotDownloader、Lyrico 插件与「倾听 5.6.14」APK，2026-11 实测）。
> 接口与盐值均可能随服务端变更失效；仅用于学习 / 研究。
>
> 源码索引：
> - [kugou_cipher.dart](../lib/network/kugou/kugou_cipher.dart) —— 盐值、签名、公共参数、取流 `key`
> - [kugou_api.dart](../lib/network/kugou/kugou_api.dart) —— 搜索、`/v5/url` 取流、音质降级
> - [kugou_privilege.dart](../lib/network/kugou/kugou_privilege.dart) —— 权威音质档位探测
> - [kugou_auth.dart](../lib/network/kugou/kugou_auth.dart) —— 二维码登录、设备三件套、取流凭据
> - [kugou_playlist_api.dart](../lib/network/kugou/kugou_playlist_api.dart) —— 歌单、每日推荐、我的歌单
> - [kugou_lyric.dart](../lib/network/kugou/kugou_lyric.dart) —— 歌词搜索 / 下载 / KRC 解密
> - [kugou_comment_api.dart](../lib/network/kugou/kugou_comment_api.dart) —— 评论读 / 写
> - [kugou_mv.dart](../lib/network/mv/kugou_mv.dart) —— MV 取流
> - [models.dart](../lib/models/models.dart) —— `KugouQuality` 音质档位表

---

## 目录

1. [通用约定与示例参数](#1-通用约定与示例参数)
2. [全部 Salt 汇总](#2-全部-salt-汇总)
3. [签名算法](#3-签名算法)
4. [搜索 `GET /v2/search/song`](#4-搜索-get-v2searchsong)
5. [取流 `GET /v5/url`](#5-取流-get-v5url)
6. [权威音质探测 `POST /goodsmstore/v1/get_res_privilege`](#6-权威音质探测-post-goodsmstorev1get_res_privilege)
7. [音质代号与 hash 来源](#7-音质代号与-hash-来源)
8. [二维码登录（login-user.kugou.com）](#8-二维码登录login-userkugoucom)
9. [歌单 / 推荐接口](#9-歌单--推荐接口)
10. [歌词接口](#10-歌词接口)
11. [评论接口](#11-评论接口)
12. [MV 取流](#12-mv-取流)
13. [其它约定](#13-其它约定)
14. [错误码](#14-错误码)
15. [实现检查清单](#15-实现检查清单)

---

## 1. 通用约定与示例参数

### 1.1 域名与路由头

| 域名 | 用途 | `x-router` |
| --- | --- | --- |
| `gateway.kugou.com` | 搜索、取流、元数据、登录后歌单、评论写 | 按接口设置，见各节 |
| `login-user.kugou.com` | 二维码登录 | 无 |
| `lyrics.kugou.com` | 歌词搜索 / 下载 | 无 |
| `m.comment.service.kugou.com` | 评论读（**http**，https 会 502） | 无 |
| `www2.kugou.kugou.com` | 推荐歌单分类 / 列表（老接口，http） | 无 |
| `mobilecdn.kugou.com` | 歌单搜索 / 歌单歌曲（老接口，http） | 无 |
| `m.kugou.com` | MV 取流 | 无 |

### 1.2 本文示例使用的固定值

下文所有示例的签名都按这一组固定值计算，可逐字节复算：

| 变量 | 示例值 |
| --- | --- |
| `mid` | `0123456789abcdef0123456789abcdef` |
| `dev` | `fedcba9876543210fedcba9876543210` |
| `dfid` | `-` |
| `userid`（匿名） | `0` |
| `userid`（登录） | `88888888` |
| `token` | `1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d` |
| `clienttime`（秒） | `1794614400` |
| `clienttime`（毫秒） | `1794614400000` |
| 128k `hash` | `8909E180A7B2F5E5D0E5A4B0D9B0E5A4` |
| 320k `hash` | `1A2B3C4D5E6F708192A3B4C5D6E7F809` |
| `album_id` | `1234567` |
| `album_audio_id` / `res_id` | `987654321` |
| `MvHash` | `4A1B2C3D4E5F60718293A4B5C6D7E8F9` |
| 搜索关键词 | `周杰伦` |
| 歌词关键词 | `周杰伦 - 稻香` |

> 真实请求必须用当前 `clienttime` 重新计算签名；示例 URL 中的签名只对示例值有效。

> 本文 GET 接口没有请求体，示例 URL 已包含**全部** query 参数（含 `signature`）；POST 接口均给出完整 JSON 请求体，无省略。

### 1.3 设备三件套

| 字段 | 规则 |
| --- | --- |
| `mid` | 32 位小写 hex；首次生成后持久化，登录 token 与它绑定 |
| `dev` | 32 位小写 hex；首次生成后持久化 |
| `dfid` | 匿名时为 `-`；也可持久化真实值 |

匿名 `mid` 生成方式：`md5("<微秒时间戳>-<随机数>")`。登录后必须复用同一份 `mid`，否则取链鉴权 / 写评论会判 token 无效。

---

## 2. 全部 Salt 汇总

| 常量 | 值 | 使用位置 |
| --- | --- | --- |
| `kugouGatewaySalt` | `OIlwieks28dk2k092lksi2UIkp` | 搜索、`/v5/url` 取流、每日推荐、评论读、评论写（标准版）、歌词兜底搜索 |
| `kugouLyricSalt` | `LnT6xpN3khm36zse0QzvmgTZ3waWdRSA` | 歌词 `/v1/search`、`/download`；我的歌单 `/v7/get_all_list`；评论写（概念版 lite） |
| `kugouUrlKeySalt` | `57ae12eb6890223e355ccfcb74edf70d` | `/v5/url` 的 `key` 参数 |
| `kugouLoginSalt` | `NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt` | 二维码登录 `/v2/qrcode`、`/v2/get_userinfo_qrcode` |

> **易错点**：gateway 盐是 `...092l` **`ks`** `i2UIkp`，不是 `...092l` `sk` `i2UIkp`。抄错会返回 `error_code 20006`。

---

## 3. 签名算法

### 3.1 公式

```
joined    = 按 key 字典序升序，把每个 "key=value" 直接首尾相接（无 &、无分隔符）
signature = md5( salt + joined + body + salt )       // 小写 32 位 hex
```

规则：

1. **排序**：参数名按 ASCII 字母序升序。
2. **拼接**：`k=v` 之间**没有** `&`。例：`appid=1005clienttime=1794614400hash=...`。
3. **不编码**：参与签名的 value 是原始值；仅最终拼 URL 时才 URL encode。
4. **body**：GET 接口为空串；POST 接口（`v7/get_all_list`、评论发表）放**原始 JSON 请求体**，必须与实际发送的 body 逐字节一致。
5. `signature` 自身不参与签名；其余参数（包括 `key`）全部参与。

### 3.2 参考实现

Dart（仓库实现）：

```dart
String kugouSign(Map<String, String> params, String salt, {String body = ''}) {
  final keys = params.keys.toList()..sort();
  final joined = keys.map((k) => '$k=${params[k] ?? ''}').join();
  return md5.convert(utf8.encode('$salt$joined$body$salt')).toString();
}
```

Python 等价写法：

```python
import hashlib

def md5(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()

def kugou_sign(params: dict, salt: str, body: str = "") -> str:
    joined = "".join(f"{k}={params[k]}" for k in sorted(params))
    return md5(f"{salt}{joined}{body}{salt}")
```

### 3.3 gateway 公共参数（appid=1005）

`kugouGatewayCommon()` 生成：

| 参数 | 值 |
| --- | --- |
| `dfid` | `-` |
| `mid` | 设备 mid（32 位小写 hex） |
| `uuid` | `-` |
| `appid` | `1005` |
| `clientver` | `20489` |
| `clienttime` | 秒级时间戳 |

> 取流 `/v5/url` 的 `clientver` 是 `11430`，不是 `20489`。

---

## 4. 搜索 `GET /v2/search/song`

### 4.1 完整请求

```http
GET https://gateway.kugou.com/v2/search/song?keyword=%E5%91%A8%E6%9D%B0%E4%BC%A6&page=1&pagesize=20&platform=AndroidFilter&iscorrection=1&privilegefilter=0&area_code=1&dopicfull=1&albumhide=0&nocollect=0&dfid=-&mid=0123456789abcdef0123456789abcdef&uuid=-&appid=1005&clientver=20489&clienttime=1794614400&signature=9fd59283f13c2fcca2f53c8a43839307
User-Agent: Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi
x-router: complexsearch.kugou.com
kg-rc: 1
kg-thash: 5d816a0
kg-rec: 1
kg-rf: B9EDA08A64250DEFFBCADDEE00F8F25F
kg-tid: 255
```

### 4.2 参数

| 参数 | 说明 |
| --- | --- |
| `keyword` | 搜索关键词（原始值参与签名，UTF-8） |
| `page` / `pagesize` | 页码 / 每页数量 |
| `platform` | `AndroidFilter` |
| `iscorrection` | `1` |
| `privilegefilter` | `0` |
| `area_code` | `1` |
| `dopicfull` | `1` |
| `albumhide` | `0` |
| `nocollect` | `0` |
| `dfid` / `mid` / `uuid` | 公共参数 |
| `appid` / `clientver` / `clienttime` | `1005` / `20489` / 秒级时间戳 |
| `signature` | gateway 盐签名 |

### 4.3 响应关键字段

`data.lists[]` 每项：

| 字段 | 说明 |
| --- | --- |
| `MixSongID` / `album_audio_id` | 歌曲主键 |
| `AlbumID` | 专辑 id |
| `FileHash` | 128k hash |
| `HQFileHash` | 320k hash |
| `SQFileHash` | FLAC hash |
| `ResFileHash` | Hi-Res hash |
| `SuperFileHash` / `SuperExtName` | 超品 hash / 扩展名 |
| `trans_param.hash_multitrack` | 多轨 hash（全景声 / 杜比） |
| `MvHash` | MV hash（32 位 hex） |
| `SongName` / `SingerName` / `AlbumName` | 元信息 |
| `Image` / `sizable_cover` | 封面模板（含 `{size}`） |
| `Duration` | 秒 |

### 4.4 歌词模块内的简化搜索

[kugou_lyric.dart](../lib/network/kugou/kugou_lyric.dart) 为了拿 `FileHash` 会内联一次搜索，参数略有差异（无 `platform` / `iscorrection` / `privilegefilter` 等），签名仍用 gateway 盐：

```http
GET https://gateway.kugou.com/v2/search/song?keyword=%E5%91%A8%E6%9D%B0%E4%BC%A6%20%E7%A8%BB%E9%A6%99&page=1&pagesize=1&platform=AndroidFilter&iscorrection=1&area_code=1&dopicfull=1&albumhide=0&nocollect=0&dfid=-&mid=0123456789abcdef0123456789abcdef&uuid=-&appid=1005&clientver=20489&clienttime=1794614400&signature=ea8b824125cc9b4768b1060158e06fd6
User-Agent: Android14-1070-11070-201-0-SearchSong-wifi
x-router: complexsearch.kugou.com
kg-rc: 1
kg-thash: 5d816a0
kg-rec: 1
kg-rf: B9EDA08A64250DEFFBCADDEE00F8F25F
kg-tid: 255
```

---

## 5. 取流 `GET /v5/url`

### 5.1 基本信息

| 项 | 值 |
| --- | --- |
| URL | `https://gateway.kugou.com/v5/url` |
| Method | `GET` |
| `x-router` | `trackercdn.kugou.com` |
| `User-Agent` | `Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi` |
| 其它头 | `kg-tid: 255` |
| 签名盐 | gateway 盐 |
| `key` 盐 | `kugouUrlKeySalt` |

### 5.2 完整请求（匿名，128k）

```http
GET https://gateway.kugou.com/v5/url?hash=8909E180A7B2F5E5D0E5A4B0D9B0E5A4&album_id=1234567&album_audio_id=987654321&quality=128&area_code=1&ssa_flag=is_fromtrack&version=11430&page_id=151369488&behavior=play&pid=2&cmd=26&pidversion=3001&IsFreePart=0&ppage_id=463467626%2C350369493%2C788954147&cdnBackup=1&module=&clientver=11430&uuid=-&appid=1005&clienttime=1794614400&mid=0123456789abcdef0123456789abcdef&dfid=-&dev=fedcba9876543210fedcba9876543210&userid=0&key=da7918b375608ce8ac13951a6a01eff7&signature=5c3ec76fc9bbd564b25f21b33c425b67
User-Agent: Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi
x-router: trackercdn.kugou.com
kg-tid: 255
```

其中：

```
key       = md5("8909E180A7B2F5E5D0E5A4B0D9B0E5A4"
                "57ae12eb6890223e355ccfcb74edf70d"
                "1005"
                "0123456789abcdef0123456789abcdef"
                "0")
          = da7918b375608ce8ac13951a6a01eff7

signature = md5(gatewaySalt + 排序拼接 + gatewaySalt)
          = 5c3ec76fc9bbd564b25f21b33c425b67
```

### 5.3 完整请求（已登录，带 userid/token）

```http
GET https://gateway.kugou.com/v5/url?hash=8909E180A7B2F5E5D0E5A4B0D9B0E5A4&album_id=1234567&album_audio_id=987654321&quality=128&area_code=1&ssa_flag=is_fromtrack&version=11430&page_id=151369488&behavior=play&pid=2&cmd=26&pidversion=3001&IsFreePart=0&ppage_id=463467626%2C350369493%2C788954147&cdnBackup=1&module=&clientver=11430&uuid=-&appid=1005&clienttime=1794614400&mid=0123456789abcdef0123456789abcdef&dfid=-&dev=fedcba9876543210fedcba9876543210&userid=88888888&token=1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d&key=e054f72093c324d2c6ebf90abdab3f3d&signature=c1a7b373ab6d84c814189be746c7b326
User-Agent: Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi
x-router: trackercdn.kugou.com
kg-tid: 255
```

登录态差异：

```
key = md5(hash + URL_KEY_SALT + "1005" + mid + "88888888")
token 参数只在已登录时携带（未登录不要放空 token）
```

### 5.4 完整参数表

| 参数 | 示例值 / 来源 | 说明 |
| --- | --- | --- |
| `hash` | 目标档位文件 hash | 128k/320k/flac/hires 各自不同 |
| `album_id` | `1234567`（搜索 `AlbumID`） | 可为空串 |
| `album_audio_id` | `987654321`（搜索 `MixSongID`） | 歌曲主键 |
| `quality` | `128` | 见第 7 节 |
| `area_code` | `1` | 固定 |
| `ssa_flag` | `is_fromtrack` | 固定 |
| `version` | `11430` | 固定 |
| `page_id` | `151369488` | 固定 |
| `behavior` | `play` | 固定 |
| `pid` | `2` | 固定 |
| `cmd` | `26` | 取流命令 |
| `pidversion` | `3001` | 固定 |
| `IsFreePart` | `0` | 不要试听片段 |
| `ppage_id` | `463467626,350369493,788954147` | 固定 |
| `cdnBackup` | `1` | 允许备用 CDN |
| `module` | 空串 | 必带，空值也参与签名 |
| `clientver` | `11430` | 与搜索的 `20489` 不同 |
| `uuid` | `-` | 匿名占位 |
| `appid` | `1005` | 标准版 |
| `clienttime` | 秒级时间戳 | 实时生成 |
| `mid` | 持久化设备 mid | `KugouAuth.device()` |
| `dfid` | `-` 或持久化值 | `KugouAuth.device()` |
| `dev` | 持久化 32 位 hex | `KugouAuth.device()` |
| `userid` | `0` 或真实 userid | 登录后填真实值 |
| `token` | 登录 token | **仅登录后携带** |
| `key` | 见 5.5 | 先算 key，再参与 `signature` |
| `signature` | 见 5.5 | 最后计算 |

### 5.5 组装顺序

1. 组装除 `signature` 外的全部参数（含 `mid/dfid/dev/userid/token`）。
2. 计算 `key = md5(hash + URL_KEY_SALT + appid + mid + userid)`，放入 params。
3. 计算 `signature = md5(gatewaySalt + sorted(k=v) + gatewaySalt)`，放入 params。
4. 所有 key/value URL encode，按 key 排序拼 query，发起 GET。

### 5.6 响应处理

| 字段 | 含义 | 处理 |
| --- | --- | --- |
| `url` | 播放地址 | 可能是 `string`，也可能是 `list`，取第一个非空项 |
| `is_free_part` / `free_part` | `1` 表示试听片段 | 视为无链接，继续降级 |
| `status` | `2` 常见于未登录取高音质 | 版权 / 会员限制，降级 |

判定顺序：先看 `is_free_part` / `free_part`，再取 `url`；`url` 为空即失败。

### 5.7 播放降级链

`KugouQuality.playbackOptions`（高 → 低）：

```
viper_tape → super → viper_hifi → viper_atmos → viper_clear → dolby
→ 360ra → hires → dolby2_1500k → flac → dolby2_448k → 320k → 128k
```

从用户选择的档位开始沿链下探；`hash` 为空跳过；取到空 `url` / 试听片段继续下一档。

---

## 6. 权威音质探测 `POST /goodsmstore/v1/get_res_privilege`

用于获取搜索响应里没有的 hash（360RA、蝰蛇 HiFi、杜比 448k/1500k）。

### 6.1 完整请求

```http
POST https://gateway.kugou.com/goodsmstore/v1/get_res_privilege?appid=1005&clientver=20049&clienttime=1794614400000&mid=0123456789abcdef0123456789abcdef
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36
Content-Type: application/json

{
  "behavior": "play",
  "clientver": "20049",
  "resource": [
    {"id": 0, "type": "audio", "hash": "8909E180A7B2F5E5D0E5A4B0D9B0E5A4"}
  ],
  "area_code": "1",
  "quality": "128",
  "qualities": [
    "128",
    "320",
    "flac",
    "high",
    "dolby",
    "viper_atmos",
    "viper_tape",
    "viper_clear",
    "viper_hifi",
    "360ra_l1",
    "360ra_l2",
    "360ra_l3",
    "dolby2_448k",
    "dolby2_1500k",
    "super"
  ]
}
```

说明：

- **不校验 gateway 签名**，只认 `appid` / `clientver`；`mid` 仅用于保持登录态一致，可用占位值。
- `clienttime` 在这里是**毫秒**时间戳。
- `qualities` 里混入任一非法代号（`360ra` / `master` / `mha1` / `sony360ra` / `viper_tape_master`），整批直接 `error_code 20010`。
- 一次最多约 30 首。

### 6.2 响应

`data[].relate_goods[]`：

| 字段 | 说明 |
| --- | --- |
| `quality` | 档位代号（`128` / `320` / `flac` / `360ra_l3` …） |
| `hash` | 该档文件 hash（取流直接用） |
| `info.filesize` | 文件字节数（`0` 的条目应跳过） |
| `info.extname` | 容器扩展名（`mp3` / `flac` / `mp4`） |
| `level` | 服务端等级（2=128k、4=320k、5=flac、6=Hi-Res，高级档为 0） |

---

## 7. 音质代号与 hash 来源

| 档位 | 取流 `quality` | hash 来源字段 | 需登录 |
| --- | --- | --- | --- |
| 标准 128K | `128` | `FileHash` / `hash` | 否 |
| 高清 320K | `320` | `HQFileHash` | 否（登录更稳） |
| 无损 FLAC | `flac` | `SQFileHash` | 否（高概率需登录） |
| Hi-Res | `high` | `ResFileHash` | 是 |
| 酷狗超品 | `super` | `SuperFileHash` | 是 |
| 蝰蛇全景声 | `viper_atmos` | `HashMultiTrack`（`trans_param.hash_multitrack`） | 是 |
| 蝰蛇超清 | `viper_clear` | `SQFileHash` | 是 |
| 杜比全景声 | `dolby` | `HashMultiTrack` | 是 |
| 360RA 空间音频 | `360ra_l3` | 探测接口下发 | 是 |
| 蝰蛇 HiFi | `viper_hifi` | 探测接口下发 | 是 |
| 杜比 448k | `dolby2_448k` | 探测接口下发 | 是 |
| 杜比 1500k | `dolby2_1500k` | 探测接口下发 | 是 |
| 蝰蛇母带（本地升频） | `320` | `HQFileHash` | 否 |

- **蝰蛇母带**是本地升频档：服务端没有该文件，实际取 `quality=320` + `HQFileHash` 的 320k 源文件，再由客户端重建 192kHz/24bit。
- **360RA** 合法代号是 `360ra_l1/l2/l3`，通常取最高 `360ra_l3`；`360ra` / `mha1` / `sony360ra` 均 `20010`。
- 取流 `quality` 与本地音质 id（`128kmp3` / `320kmp3` / `flac` / `hires`）**不是一回事**，传 `128kmp3` 会 `20010`。

---

## 8. 二维码登录（login-user.kugou.com）

登录的意义：未登录取高音质返回空 URL / `status: 2`；登录后把 `userid` + `token` 与 `mid/dfid/dev` 一起注入 `/v5/url` 才能解锁 flac / Hi-Res。

**盐是 `kugouLoginSalt`，不是 gateway 盐。**

### 8.1 创建二维码

```http
GET https://login-user.kugou.com/v2/qrcode?dfid=-&mid=0123456789abcdef0123456789abcdef&uuid=-&appid=1001&clientver=20489&clienttime=1794614400&dev=fedcba9876543210fedcba9876543210&type=1&plat=4&srcappid=2919&qrcode_txt=https%3A%2F%2Fh5.kugou.com%2Fapps%2FloginQRCode%2Fhtml%2Findex.html%3Fappid%3D1005%26&signature=5d181eb1951eb1b2b537e617108de8af
User-Agent: Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi
kg-rc: 1
kg-thash: 5d816a0
kg-rec: 1
kg-rf: B9EDA08A64250DEFFBCADDEE00F8F25F
kg-tid: 255
```

参数组装：

```text
params = 公共参数(dfid=-, mid, uuid=-, appid=1005, clientver=20489, clienttime)
       + 设备参数(mid, dfid, dev)            // 覆盖同名键
       + 业务参数(appid=1001, type=1, plat=4, srcappid=2919, qrcode_txt)
params["clienttime"] = 当前秒级时间戳
params["signature"]  = md5(loginSalt + sorted(k=v) + loginSalt)
```

业务参数：

| 参数 | 值 |
| --- | --- |
| `appid` | `1001`（覆盖公共的 1005） |
| `type` | `1` |
| `plat` | `4` |
| `srcappid` | `2919` |
| `qrcode_txt` | `https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=1005&` |

响应：

| 字段 | 说明 |
| --- | --- |
| `data.qrcode` | 轮询 key |
| `data.qrcode_img` | `data:image/png;base64,...` 二维码图片 |

### 8.2 轮询扫码状态

```http
GET https://login-user.kugou.com/v2/get_userinfo_qrcode?dfid=-&mid=0123456789abcdef0123456789abcdef&uuid=-&appid=1005&clientver=20489&clienttime=1794614400&dev=fedcba9876543210fedcba9876543210&srcappid=2919&plat=4&qrcode=9f8e7d6c5b4a39281706f5e4d3c2b1a0&signature=f0d18efe1af3b445c67f9b916ed6859d
User-Agent: Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi
kg-rc: 1
kg-thash: 5d816a0
kg-rec: 1
kg-rf: B9EDA08A64250DEFFBCADDEE00F8F25F
kg-tid: 255
```

业务参数：`appid=1005`、`srcappid=2919`、`plat=4`、`qrcode=<key>`。

响应 `data.status`：

| 值 | 含义 |
| --- | --- |
| `1` | 等待扫码 |
| `2` | 已扫码，待确认 |
| `4` | 已确认（`data.userid` / `data.token` 有效） |
| 其它 | 过期 / 失败 |

### 8.3 取流用的登录凭据

`KugouAuth.requestParams()` 返回：

```json
{
  "mid": "0123456789abcdef0123456789abcdef",
  "dfid": "-",
  "dev": "fedcba9876543210fedcba9876543210",
  "userid": "88888888",
  "token": "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"
}
```

未登录时 `userid=0` 且不含 `token`。

---

## 9. 歌单 / 推荐接口

### 9.1 歌单分类标签

```http
GET http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_smarty=1
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36
Accept: */*
```

响应：`data.tagids = { "主题": {id:1, data:[{id,name},…]}, "语种": …, "风格": …, "年代": …, "心情": …, "场景": … }`。

### 9.2 推荐歌单列表

```http
GET http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_ajax=1&cdn=cdn&t=5&c=&p=1&pagesize=20
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36
Accept: */*
```

| 参数 | 说明 |
| --- | --- |
| `t` | 排序：`3` 热藏 / `5` 推荐 / `6` 最热 / `7` 最新 / `8` 飙升 |
| `c` | 分类 id（空 = 全部） |
| `p` / `pagesize` | 页码 / 每页数量 |

响应：`special_db[]`（`specialid` / `specialname` / `nickname` / `img` / `song_count` / `total_play_count` …）。

### 9.3 搜索歌单

```http
GET http://mobilecdn.kugou.com/api/v3/search/special?format=json&keyword=%E5%91%A8%E6%9D%B0%E4%BC%A6&page=1&pagesize=20&showtype=1
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36
Accept: */*
```

响应：`data.info[]`（`specialid` / `specialname` / `imgurl` / `nickname` / `playcount` / `songcount`）。

### 9.4 歌单歌曲

```http
GET http://mobilecdn.kugou.com/api/v3/special/song?version=9108&specialid=123456789&page=1&pagesize=100&plat=0&area_code=1&with_res_tag=0
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36
Accept: */*
```

响应：`data.info[]`：

| 字段 | 说明 |
| --- | --- |
| `album_audio_id` | MixSongID |
| `hash` | 128k hash |
| `320hash` / `hash_320` | 320k hash |
| `sqhash` / `hash_flac` | FLAC hash |
| `res_hash` / `hash_res` | Hi-Res hash |
| `filename` | `歌手 - 歌名.mp3` |
| `album_name` / `sizable_cover` / `duration` / `mvhash` | 元信息 |

> 老接口返回 `Content-Type: text/html`，需按纯文本接收后自行 JSON 解析。

### 9.5 每日推荐

```http
GET https://gateway.kugou.com/everyday_song_recommend?dfid=-&mid=0123456789abcdef0123456789abcdef&uuid=-&appid=1005&clientver=20489&clienttime=1794614400&platform=ios&signature=8837e0b1a09d43b264e92e48284e73cb
User-Agent: Android810-AndroidPhone-20489-14-0-COMMENT-wifi
Accept: application/json
kg-rc: 1
kg-thash: 5d816a0
kg-rec: 1
kg-rf: B9EDA08A64250DEFFBCADDEE00F8F25F
x-router: everydayrec.service.kugou.com
```

- 签名盐：gateway 盐。
- 响应：`data.song_list[]`（`mixsongid` / `songname` / `author_name` / `hash` / `hash_320` / `hash_flac` / `hash_res` / `sizable_cover` / `time_length` / `mv_hash`）。

### 9.6 我的歌单（需登录）

```http
POST https://gateway.kugou.com/v7/get_all_list?appid=3116&clientver=11440&clienttime=1794614400&dfid=-&mid=0123456789abcdef0123456789abcdef&plat=1&uuid=-&signature=30b71ae3b4ec65bdd325230704461ae5
User-Agent: Android15-1070-11440-46-0-DiscoveryDRADProtocol-wifi
Accept: application/json
Content-Type: application/json
kg-rc: 1
kg-thash: 5d816a0
kg-rec: 1
kg-rf: B9EDA08A64250DEFFBCADDEE00F8F25F
x-router: cloudlist.service.kugou.com
Cookie: 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d

{"userid":88888888,"token":"1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d","total_ver":979,"type":2,"page":1,"pagesize":30}
```

关键点：

- 签名盐是 **lyric 盐**（不是 gateway 盐），错盐返回 `20006`。
- `signature = md5(lyricSalt + sorted(k=v) + body + lyricSalt)`，`body` 必须与请求体逐字节一致。
- 查询参数只有 `appid/clientver/clienttime/dfid/mid/plat/uuid`，`userid/token` 在 body 里。

响应：`data.info` / `data.list` / `data.lists` 三种数组名都可能出现，单条字段兼容 `listid|list_id|id|list_create_listid|specialid`、`name|list_name|specialname|title`、`pic|sizable_cover|flexible_cover|imgurl|cover|img` 等。

### 9.7 热搜

酷狗没有稳定的公开热搜接口，仓库用「推荐歌单名」当热搜词（同 9.2 的请求）。

---

## 10. 歌词接口

### 10.1 搜索候选

```http
GET https://lyrics.kugou.com/v1/search?album_audio_id=0&duration=0&hash=8909E180A7B2F5E5D0E5A4B0D9B0E5A4&keyword=%E5%91%A8%E6%9D%B0%E4%BC%A6%20-%20%E7%A8%BB%E9%A6%99&lrctxt=1&man=no&appid=3116&clientver=11070&signature=2135ae334f9f09bfc2cf2bb98ac14532
User-Agent: Android14-1070-11070-201-0-SearchSong-wifi
```

- 签名盐：lyric 盐。
- 参数：`hash`、`keyword`（`歌手 - 歌名`）、`album_audio_id=0`、`duration=0`、`lrctxt=1`、`man=no`、`appid=3116`、`clientver=11070`。
- 响应：`candidates[]`，取 `candidates[0].id` 与 `candidates[0].accesskey`。

### 10.2 下载 KRC

```http
GET https://lyrics.kugou.com/download?accesskey=ABCDEF1234567890ABCDEF1234567890&charset=utf8&client=mobi&fmt=krc&id=123456789&ver=1&appid=3116&clientver=11070&signature=e3b1acef1b25120fdc8b4e53626b97c3
User-Agent: Android14-1070-11070-201-0-SearchSong-wifi
```

- 签名盐：lyric 盐。
- 响应：`content`（base64 内容）、`contenttype`（`2` 表示纯文本 base64，其它表示 KRC 密文）。

### 10.3 KRC 解密

```text
1) base64 解码 content
2) 去掉前 4 字节
3) 与 16 字节密钥循环 XOR
4) zlib 解压
5) 按 UTF-8 解码得到 KRC 文本
```

密钥（`_krcKey`）：

```text
[64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]
```

KRC 解析：行格式 `[开始ms,时长ms]`，逐字标记 `<偏移ms,时长ms,0>文本`；`[language:<base64 JSON>]` 里 `type=1` 是译文、`type=0` 是罗马音。

---

## 11. 评论接口

### 11.1 取歌曲评论标识 `POST /v3/album_audio/audio`

```http
POST https://gateway.kugou.com/v3/album_audio/audio
KG-THash: 13a3164
KG-RC: 1
KG-Fake: 0
KG-RF: 00869891
User-Agent: Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi
x-router: kmr.service.kugou.com
Content-Type: application/json

{
  "area_code": "1",
  "show_privilege": 1,
  "show_album_info": "1",
  "is_publish": "",
  "appid": 1005,
  "clientver": 11451,
  "mid": "1",
  "dfid": "-",
  "clienttime": 1794614400000,
  "key": "OIlwieks28dk2k092lksi2UIkp",
  "fields": "album_info,author_name,audio_info,ori_audio_name,base,songname,classification",
  "data": [
    {"hash": "8909E180A7B2F5E5D0E5A4B0D9B0E5A4"}
  ]
}
```

- **无签名**：body 里的 `key` 字段直接填 gateway 盐值。
- `clienttime` 是毫秒。
- 响应取值：
  - `data[0][0].classification[0].res_id` → 评论读的 `mixsongid`、评论写的 `album_audio_id`
  - `data[0][0].audio_info.audio_id` → 评论写的 `childrenid`（错填会 `10013 歌曲不存在`）

### 11.2 读评论（免登录）

```http
GET http://m.comment.service.kugou.com/r/v1/rank/newest?appid=1005&clienttime=1794614400&clienttoken=0&clientver=11409&code=fc4be23b4e972707f36b8a828a93ba8a&dfid=0&extdata=8909E180A7B2F5E5D0E5A4B0D9B0E5A4&kugouid=0&mid=16249512204336365674023395779019&mixsongid=987654321&p=1&pagesize=20&uuid=0&ver=10&signature=6cd99683c479bc31a77d22bf0fc6ac2e
accept: application/json
User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 Edg/107.0.1418.24
```

- 排序：`newest`（最新）/ `topliked`（最热）。
- 域名必须用 **http**（https 会 502）。
- 固定值：`code=fc4be23b4e972707f36b8a828a93ba8a`、`mid=16249512204336365674023395779019`、`clientver=11409`。
- 签名盐：gateway 盐；`signature` 追加在查询串末尾。
- 响应：`list[]` 评论数组、`count` 总数；服务端偶发返回 `err_code 20006` 但仍有数据，按空结果兼容。

### 11.3 发表评论（需登录，标准版）

两层签名：

```
key       = md5(appid + salt + clientver + clienttime + mid + body)
signature = md5(salt + sorted(k=v) + body + salt)
```

`key` 算完后放进 params，再参与 `signature`。

```http
POST https://gateway.kugou.com/m.comment.service/p/v1/commentsv3/add?album_audio_id=987654321&appid=1005&childrenid=0&clienttime=1794614400&clienttoken=0&clientver=11440&code=fc4be23b4e972707f36b8a828a93ba8a&dfid=0&gid=0&is_t=0&key=c4a7e0113c67dd833c1d246fe1e822c3&kugouid=88888888&mid=0123456789abcdef0123456789abcdef&pid=0&token=1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d&userid=88888888&uuid=0&ver=10&signature=2c7f7a67e97d9e01d3f373acabc8e213
accept: application/json
User-Agent: Android810-AndroidPhone-11440-14-0-COMMENT-wifi
Content-Type: application/json;charset=utf-8
Cookie: kg_userid=88888888; kg_token=1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d

{"data":{"content":"好听","contentFormatted":"好听","album_audio_id":"987654321","hash":"8909E180A7B2F5E5D0E5A4B0D9B0E5A4"}}
```

其中：

```
key = md5("1005" + gatewaySalt + "11440" + "1794614400"
          + "0123456789abcdef0123456789abcdef" + body)
    = c4a7e0113c67dd833c1d246fe1e822c3
```

- 路径：普通评论 `add`，回复 `reply`（额外带 `tid=<父评论 id>`）。
- `mid` 必须是登录 token 绑定的设备 mid；用固定值会 `err_code 10000 未登录`。
- 标准版被判未登录时，切概念版重试。

### 11.4 回复评论（概念版 lite 身份）

概念版：`appid=3116`、`clientver=10659`、**lyric 盐**。

```http
POST https://gateway.kugou.com/m.comment.service/p/v1/commentsv3/reply?album_audio_id=987654321&appid=3116&childrenid=0&clienttime=1794614400&clienttoken=0&clientver=10659&code=fc4be23b4e972707f36b8a828a93ba8a&dfid=0&gid=0&is_t=0&key=8a878075197377615766fb098b8d6a17&kugouid=88888888&mid=0123456789abcdef0123456789abcdef&pid=0&tid=1122334455&token=1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d&userid=88888888&uuid=0&ver=10&signature=e1b7c7789be6ea3ab806b304060244e2
accept: application/json
User-Agent: Android810-AndroidPhone-10659-14-0-COMMENT-wifi
Content-Type: application/json;charset=utf-8
Cookie: kg_userid=88888888; kg_token=1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d

{"data":{"content":"好听","contentFormatted":"好听","album_audio_id":"987654321","hash":"8909E180A7B2F5E5D0E5A4B0D9B0E5A4"}}
```

响应判据：`err_code == 0` 成功；`10000` 未登录；`10003` 字数不够；`20006` 签名错；`60045` 风控拦截（客户端无法绕过）。

---

## 12. MV 取流

```http
GET https://m.kugou.com/app/i/mv.php?cmd=100&ext=mp4&hash=4A1B2C3D4E5F60718293A4B5C6D7E8F9
Referer: https://www.kugou.com/
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 Edg/107.0.1418.24
```

- 无签名。
- `hash` 是搜索响应的 `MvHash`（32 位 hex）；`cmd=100` 才是取流，其它值返回 `errcode:2 Bad cmd`。
- 响应 `status` 必须为 `1`；`mvdata` 含五档：

| key | 画质 |
| --- | --- |
| `le` | 480p |
| `sd` | 720p |
| `hd` | 1080p |
| `sq` | 1080p |
| `rq` | 4k |

每档字段：`downurl`、`backupdownurl`、`filesize`、`width`、`height`、`bitrate`、`timelength`、`codec`。

- 同 quality 多档取 `filesize` 更大的。
- CDN 地址保留 **http**（HTTPS 证书主机不匹配，Chromium 会拒绝）。

---

## 13. 其它约定

### 13.1 封面归一化

```dart
raw.replaceAll('{size}', '480').replaceFirst('http:', 'https:')
```

### 13.2 clientver / appid 速查

| 场景 | appid | clientver | 盐 |
| --- | --- | --- | --- |
| 搜索 / 元数据 | 1005 | 20489 | gateway |
| 取流 `/v5/url` | 1005 | 11430 | gateway |
| 音质探测 | 1005 | 20049 | 无签名 |
| 登录创建二维码 | 1001 | 20489 | login |
| 登录轮询 | 1005 | 20489 | login |
| 每日推荐 | 1005 | 20489 | gateway |
| 我的歌单 | 3116 | 11440 | lyric |
| 歌词 | 3116 | 11070 | lyric |
| 评论读 | 1005 | 11409 | gateway |
| 评论写标准版 | 1005 | 11440 | gateway |
| 评论写概念版 | 3116 | 10659 | lyric |
| 歌曲评论信息 | 1005 | 11451 | body 里 `key` 填 gateway 盐 |

---

## 14. 错误码

| 错误码 | 含义 | 常见原因 |
| --- | --- | --- |
| `20006` | `err signature` / 参数验证失败 | 盐值错、排序错、value 被 URL encode、body 不一致 |
| `20010` | 参数非法 | `quality` 传了不存在的代号、`qualities` 混入非法代号 |
| `20017` | token 无效 | 未登录 / token 过期 / mid 与 token 不匹配 |
| `status: 2` | 版权或会员限制 | 未登录取高音质 |
| `10000` | 请登录后发送 | 评论写接口未登录 / mid 与 token 不绑定 |
| `10003` | 发送字数不够 | 评论内容过短 |
| `10013` | 歌曲不存在 | 评论写 `childrenid` 填错 |
| `60045` | 风控拦截 | 账号 / 设备触发反垃圾策略，客户端无法绕过 |

---

## 15. 实现检查清单

- [ ] 盐值与第 2 节逐字符一致（尤其 `...092l**ks**i2UIkp`）。
- [ ] 签名用原始值拼接，URL 编码只发生在最终拼 query 时。
- [ ] 排序后 `k=v` 直接相接，无 `&`。
- [ ] `clienttime` 搜索 / 取流用秒，音质探测 / 评论歌曲信息用毫秒。
- [ ] 取流 `clientver=11430`，搜索 `20489`。
- [ ] 取流 `key` 在 `signature` 之前算好，并参与 `signature`。
- [ ] `quality` 用服务端代号（`128` / `320` / `flac` / `high` …），不是本地音质 id。
- [ ] 登录后 `userid` / `token` 与持久化 `mid` / `dfid` / `dev` 一起携带。
- [ ] 我的歌单用 **lyric 盐**且 body 参与签名。
- [ ] 评论写是两层签名，`key` 也要进 params 参与 `signature`。
- [ ] `url` 兼容字符串和数组；`is_free_part` / `free_part == 1` 视为失败。
- [ ] 图片 `{size}` 替换为 `480`，`http:` 改 `https:`。
