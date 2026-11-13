# 酷狗音乐取流接口与签名 Salt 完整说明

> 来源：本仓库 `lib/network/kugou/` 的实现（逆向自 HotDownloader、Lyrico 插件与「倾听 5.6.14」APK，并在 2026-11 实测验证）。
> 结论可能随酷狗服务端变更而失效；仅用于学习 / 研究。
>
> 相关源码：
> - [kugou_cipher.dart](../lib/network/kugou/kugou_cipher.dart) —— 盐值、签名、公共参数、`key` 计算
> - [kugou_api.dart](../lib/network/kugou/kugou_api.dart) —— 搜索、`/v5/url` 取流、音质降级
> - [kugou_auth.dart](../lib/network/kugou/kugou_auth.dart) —— 二维码登录、设备三件套、取流凭据注入
> - [kugou_privilege.dart](../lib/network/kugou/kugou_privilege.dart) —— 权威音质档位探测
> - [kugou_lyric.dart](../lib/network/kugou/kugou_lyric.dart) / [kugou_playlist_api.dart](../lib/network/kugou/kugou_playlist_api.dart) / [kugou_comment_api.dart](../lib/network/kugou/kugou_comment_api.dart)
> - [kugou_mv.dart](../lib/network/kugou/kugou_mv.dart) —— MV 取流（无签名）
> - [models.dart](../lib/models/models.dart) —— `KugouQuality` 音质档位表

---

## 1. 全部 Salt 汇总

| 常量 | 值 | 适用域名 / 接口 |
| --- | --- | --- |
| `kugouGatewaySalt` | `OIlwieks28dk2k092lksi2UIkp` | `gateway.kugou.com` 系列：搜索 `/v2/search/song`、**取流 `/v5/url`**、每日推荐、评论读、评论写（标准版）、歌词兜底搜索 |
| `kugouLyricSalt` | `LnT6xpN3khm36zse0QzvmgTZ3waWdRSA` | `lyrics.kugou.com` 歌词 `/v1/search`、`/download`；`gateway.kugou.com/v7/get_all_list`（我的歌单）；评论写（概念版 lite） |
| `kugouUrlKeySalt` | `57ae12eb6890223e355ccfcb74edf70d` | `/v5/url` 取流的 `key` 参数（不是 `signature`） |
| `kugouLoginSalt` | `NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt` | `login-user.kugou.com` 二维码登录 `/v2/qrcode`、`/v2/get_userinfo_qrcode` |

> **易错点**：gateway 盐是 `...092l` **`ks`** `i2UIkp`，不是 `...092l` `sk` `i2UIkp`。抄错一个字符顺序，签名算法完全正确也会返回 `error_code 20006`（`err signature`，HTTP 200 但数据为空）。

---

## 2. 签名算法

### 2.1 公式

```
joined    = 按 key 字典序升序，把每个 "key=value" 直接首尾相接（无 &、无分隔符）
signature = md5( salt + joined + body + salt )        // 小写 32 位 hex
```

要点：

1. **排序**：按参数名字母序（ASCII）升序。
2. **拼接**：`k=v` 之间**没有** `&`，例如 `appid=1005clienttime=...hash=...`。
3. **值不编码**：参与签名的 value 是原始值，**不做 URL encode**。等真正拼到 URL 上时才做百分号编码（`Uri.encodeComponent`）。
4. **body**：GET 接口为空串；POST 接口（如 `v7/get_all_list`、评论发表）放原始 JSON 字符串，且必须与实际请求体**逐字节一致**。
5. **signature 自身不参与签名**，其余全部 query 参数（含 `key`）都参与。

### 2.2 参考实现

Dart（与仓库实现一致）：

```dart
String kugouSign(Map<String, String> params, String salt, {String body = ''}) {
  final keys = params.keys.toList()..sort();
  final joined = keys.map((k) => '$k=${params[k] ?? ''}').join(); // 无分隔符
  return md5.convert(utf8.encode('$salt$joined$body$salt')).toString();
}

String kugouBuildQuery(Map<String, String> params) {
  final keys = params.keys.toList()..sort();
  return keys
      .map((k) => '${Uri.encodeComponent(k)}=${Uri.encodeComponent(params[k] ?? '')}')
      .join('&');
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

---

## 3. gateway 公共参数（appid=1005）

`kugouGatewayCommon()` 生成，参与**每一次** gateway 签名：

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `dfid` | `-` | 匿名设备指纹；登录后可用持久化值 |
| `mid` | 32 位小写 hex | 设备 ID；匿名时随机生成，登录后必须与 token 绑定的一致 |
| `uuid` | `-` | 匿名占位 |
| `appid` | `1005` | 标准版客户端 |
| `clientver` | `20489` | 搜索 / 元数据接口用；取流接口单独用 `11430` |
| `clienttime` | 秒级时间戳 | 每次请求实时生成 |

---

## 4. 取流主接口：`GET /v5/url`

### 4.1 基本信息

| 项 | 值 |
| --- | --- |
| URL | `https://gateway.kugou.com/v5/url` |
| Method | `GET` |
| 路由头 | `x-router: trackercdn.kugou.com` |
| `User-Agent` | `Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi` |
| 其它头 | `kg-tid: 255` |
| 签名盐 | `kugouGatewaySalt`（`OIlwieks28dk2k092lksi2UIkp`） |
| `key` 盐 | `kugouUrlKeySalt`（`57ae12eb6890223e355ccfcb74edf70d`） |

### 4.2 完整参数表

| 参数 | 值 / 来源 | 说明 |
| --- | --- | --- |
| `hash` | 目标档位的文件 hash | 128k/320k/flac/hires 等各自不同，按档位取 |
| `album_id` | 搜索响应 `AlbumID` | 可空串 |
| `album_audio_id` | 搜索响应 `MixSongID` | 歌曲唯一 ID |
| `quality` | 档位代号，见第 5 节 | 只认 `128`/`320`/`flac`/`high` 及 `viper_*`、`dolby*`、`360ra_l*`、`super` |
| `area_code` | `1` | 区域 |
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
| `module` | 空串 | 必带（空值也参与签名） |
| `clientver` | `11430` | 注意与搜索的 `20489` 不同 |
| `uuid` | `-` | 匿名占位 |
| `appid` | `1005` | 标准版 |
| `clienttime` | 秒级时间戳 | 实时生成 |
| `mid` | 设备 mid（32 位小写 hex） | 来自 `KugouAuth.device()` |
| `dfid` | `-` 或持久化设备值 | 来自 `KugouAuth.device()` |
| `dev` | 32 位小写 hex | 来自 `KugouAuth.device()` |
| `userid` | `0`（未登录）或真实 userid | 登录后填真实值 |
| `token` | 登录 token | **仅登录后携带**；未登录不要带空 token 参数 |
| `key` | 见 4.3 | 必须先算好并加入 params，再参与 `signature` |
| `signature` | 见 4.4 | 最后计算 |

### 4.3 `key` 计算

```
key = md5( hash + kugouUrlKeySalt + appid + mid + userid )
```

- `appid`：`1005`
- `mid`：与签名同一份设备 mid
- `userid`：未登录 `0`，登录后为真实 userid
- 结果：32 位小写 hex

### 4.4 组装与签名顺序

1. 组装除 `signature` 外的**全部**参数（含 `mid/dfid/dev/userid/token`）。
2. 计算 `key`，放进 params。
3. 对当前整个 params 计算 `signature = md5(gatewaySalt + sorted(k=v) + gatewaySalt)`。
4. 把 `signature` 加入 params。
5. 按 key 排序，URL encode 后拼成 query，发起 GET。

伪代码：

```text
params = {hash, album_id, album_audio_id, quality, area_code, ssa_flag,
          version, page_id, behavior, pid, cmd, pidversion, IsFreePart,
          ppage_id, cdnBackup, module, clientver, uuid, appid, clienttime,
          mid, dfid, dev, userid[, token]}
params["key"] = md5(hash + URL_KEY_SALT + "1005" + mid + userid)
params["signature"] = md5(SALT + join_sorted(params) + SALT)
GET https://gateway.kugou.com/v5/url?<urlencode(sorted(params))>
```

### 4.5 请求示例（Python）

```python
import hashlib, time, urllib.parse, requests

SALT     = "OIlwieks28dk2k092lksi2UIkp"
KEY_SALT = "57ae12eb6890223e355ccfcb74edf70d"
UA       = "Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi"

def md5(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()

def sign(params: dict, salt: str = SALT) -> str:
    joined = "".join(f"{k}={params[k]}" for k in sorted(params))
    return md5(f"{salt}{joined}{salt}")

hash_       = "目标档位文件hash"
album_id    = "123456"
album_audio = "987654321"
quality     = "128"
mid         = "0123456789abcdef0123456789abcdef"
dev         = "fedcba9876543210fedcba9876543210"
userid      = "0"

params = {
    "hash": hash_, "album_id": album_id, "album_audio_id": album_audio,
    "quality": quality, "area_code": "1", "ssa_flag": "is_fromtrack",
    "version": "11430", "page_id": "151369488", "behavior": "play",
    "pid": "2", "cmd": "26", "pidversion": "3001", "IsFreePart": "0",
    "ppage_id": "463467626,350369493,788954147", "cdnBackup": "1",
    "module": "", "clientver": "11430", "uuid": "-", "appid": "1005",
    "clienttime": str(int(time.time())),
    "mid": mid, "dfid": "-", "dev": dev, "userid": userid,
}
params["key"] = md5(hash_ + KEY_SALT + "1005" + mid + userid)
params["signature"] = sign(params)

query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
resp = requests.get(
    "https://gateway.kugou.com/v5/url?" + query,
    headers={
        "User-Agent": UA,
        "x-router": "trackercdn.kugou.com",
        "kg-tid": "255",
    },
    timeout=20,
)
data = resp.json()
print(data)
```

### 4.6 响应处理

| 字段 | 含义 | 处理 |
| --- | --- | --- |
| `url` | 播放地址 | 可能是 `string`，也可能是 `list`，取第一个非空项 |
| `is_free_part` / `free_part` | `1` 表示试听片段 | 视为无链接，继续降级下一档 |
| `status` | `2` 常见于未登录取高音质 | 版权 / 会员限制，取不到则降级 |

注意判定顺序：先看 `is_free_part`/`free_part`，再取 `url`；`url` 为空即失败。

### 4.7 音质降级链（播放）

`KugouQuality.playbackOptions`（高 → 低）：

```
viper_tape → super → viper_hifi → viper_atmos → viper_clear → dolby
→ 360ra → hires → dolby2_1500k → flac → dolby2_448k → 320k → 128k
```

从用户选择的档位开始沿链下探；某档 `hash` 为空则跳过；取到的 `url` 为空 / 试听则继续下一档。

---

## 5. 音质代号与 hash 来源

同一首歌的不同音质是**不同文件**，用不同 hash 定位。

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
| 360RA 空间音频 | `360ra_l3` | 探测接口下发（搜索响应里没有） | 是 |
| 蝰蛇 HiFi | `viper_hifi` | 探测接口下发 | 是 |
| 杜比 448k | `dolby2_448k` | 探测接口下发 | 是 |
| 杜比 1500k | `dolby2_1500k` | 探测接口下发 | 是 |
| 蝰蛇母带（本地升频） | `320`（不是 `viper_tape`） | `HQFileHash` | 否 |

**蝰蛇母带**是本地升频档：服务端没有对应文件，实际取 320k 源文件（`quality=320` + `HQFileHash`），再由客户端重建 192kHz/24bit。

**360RA** 的服务端合法代号是 `360ra_l1/l2/l3`（取 `360ra_l3`）；传入 `360ra`、`mha1`、`sony360ra` 等会返回 `error_code 20010`。

---

## 6. 取流前置链路

### 6.1 搜索拿 hash：`GET /v2/search/song`

```
GET https://gateway.kugou.com/v2/search/song
```

| 参数 | 值 |
| --- | --- |
| `keyword` | 关键词 |
| `page` / `pagesize` | 页码 / 每页数量 |
| `platform` | `AndroidFilter` |
| `iscorrection` | `1` |
| `privilegefilter` | `0` |
| `area_code` | `1` |
| `dopicfull` | `1` |
| `albumhide` | `0` |
| `nocollect` | `0` |
| 公共参数 | `dfid/mid/uuid/appid=1005/clientver=20489/clienttime` |
| `signature` | gateway 盐签名 |

Headers：

```
User-Agent: Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi
x-router: complexsearch.kugou.com
kg-rc: 1
kg-thash: 5d816a0
kg-rec: 1
kg-rf: B9EDA08A64250DEFFBCADDEE00F8F25F
kg-tid: 255
```

响应：`data.lists[]`，单条包含 `MixSongID`、`AlbumID`、`FileHash`、`HQFileHash`、`SQFileHash`、`ResFileHash`、`SuperFileHash`、`MvHash`、`Duration`、`Image` 等。

### 6.2 权威档位探测：`POST /goodsmstore/v1/get_res_privilege`

用于拿到搜索响应里没有的 hash（360RA、蝰蛇 HiFi、杜比 448k/1500k）。

```
POST https://gateway.kugou.com/goodsmstore/v1/get_res_privilege
?appid=1005&clientver=20049&clienttime=<毫秒时间戳>&mid=<mid>
```

请求体：

```json
{
  "behavior": "play",
  "clientver": "20049",
  "resource": [
    {"id": 0, "type": "audio", "hash": "<FileHash>"}
  ],
  "area_code": "1",
  "quality": "128",
  "qualities": [
    "128", "320", "flac", "high", "dolby",
    "viper_atmos", "viper_tape", "viper_clear", "viper_hifi",
    "360ra_l1", "360ra_l2", "360ra_l3",
    "dolby2_448k", "dolby2_1500k", "super"
  ]
}
```

- **该接口不校验 gateway 签名**，只认 `appid` / `clientver`。
- `qualities` 全集里只要混入一个非法代号，整批返回 `error_code 20010`。
- 响应：`data[].relate_goods[]`，每条含 `quality`、`hash`、`info.filesize`、`info.extname`、`level`。
- 一次最多约 30 首；某首失败不影响其它首。

### 6.3 登录解锁高音质

未登录时 `userid=0`、不传 `token`，通常只能取 128k；高音质返回空 URL / `status: 2`。登录后把 `userid` + `token` 随 `mid/dfid/dev` 一起注入 `/v5/url` 才能解锁 flac / Hi-Res 等。

二维码登录（**使用 `kugouLoginSalt`**）：

```
GET https://login-user.kugou.com/v2/qrcode
GET https://login-user.kugou.com/v2/get_userinfo_qrcode
```

| 步骤 | 参数 |
| --- | --- |
| 创建二维码 | `appid=1001&type=1&plat=4&srcappid=2919&qrcode_txt=...` + 公共参数 + 设备三件套 + `signature` |
| 轮询状态 | `appid=1005&srcappid=2919&plat=4&qrcode=<key>` + 公共参数 + 设备三件套 + `signature` |

- 签名：`md5(loginSalt + sorted(k=v) + loginSalt)`，**不是 gateway 盐**。
- 轮询 `data.status`：`1` 等待扫码、`2` 已扫码待确认、`4` 已确认（返回 `userid` / `token`）。
- 设备三件套 `mid` / `dev` 为 32 位小写 hex，`dfid` 匿名时为 `-`；生成后**持久化复用**，token 与 mid 绑定。
- 手动凭据：`userid` 必须为正整数，`token` 非空。

---

## 7. 其它用盐接口速查

| 接口 | Method / 路径 | 签名盐 | body 参与签名 |
| --- | --- | --- | --- |
| 搜索 | `GET gateway.kugou.com/v2/search/song` | gateway | 否 |
| **取流** | `GET gateway.kugou.com/v5/url` | gateway + URL key 盐 | 否 |
| 每日推荐 | `GET gateway.kugou.com/everyday_song_recommend` | gateway | 否 |
| 我的歌单 | `POST gateway.kugou.com/v7/get_all_list` | **lyric** | 是（JSON） |
| 歌词搜索 | `GET lyrics.kugou.com/v1/search` | lyric | 否 |
| 歌词下载 | `GET lyrics.kugou.com/download` | lyric | 否 |
| 评论读 | `GET m.comment.service.kugou.com/r/v1/rank/{newest,topliked}` | gateway | 否 |
| 评论写（标准版） | `POST gateway.kugou.com/m.comment.service/p/v1/commentsv3/{add,reply}` | gateway | 是 |
| 评论写（概念版） | 同上 | **lyric** | 是 |
| 二维码登录 | `GET login-user.kugou.com/v2/{qrcode,get_userinfo_qrcode}` | login | 否 |
| 音质探测 | `POST gateway.kugou.com/goodsmstore/v1/get_res_privilege` | 无签名校验 | — |
| MV 取流 | `GET m.kugou.com/app/i/mv.php?cmd=100&ext=mp4&hash=<MvHash>` | 无签名 | — |

补充说明：

- **每日推荐**：`x-router: everydayrec.service.kugou.com`，`platform=ios`，`clientver=20489`。
- **我的歌单**：`appid=3116`、`clientver=11440`、`plat=1`，body `{"userid":…,"token":…,"total_ver":979,"type":2,"page":1,"pagesize":30}`，签名盐用 **lyric 盐**（错用 gateway 盐返回 `20006`）。
- **评论读**：域名是 **http**（https 会 502），`clientver=11409`；`count` 为评论总数。
- **评论写**是**两层签名**：
  - `key = md5(appid + salt + clientver + clienttime + mid + body)`
  - `signature = md5(salt + sorted(k=v) + body + salt)`
  - `key` 也要放进 params 后一起参与 `signature`。
  - `mid` 必须与登录 token 绑定的一致（写接口用 `KugouAuth.device().mid`，不能固定值）。
- **MV 取流**：无签名，但必须带 `Referer: https://www.kugou.com/` 与桌面 UA；响应 `mvdata` 含 `le(480p)` / `sd(720p)` / `hd(1080p)` / `sq(1080p)` / `rq(4k)` 五档，每档有 `downurl` / `backupdownurl` / `filesize` / `width` / `height` / `bitrate` / `timelength` / `codec`。CDN 地址保留 **http**（HTTPS 证书主机不匹配）。

---

## 8. 常见错误码

| 错误码 | 含义 | 常见原因 |
| --- | --- | --- |
| `20006` | `err signature` / 参数验证失败 | 盐值错（如 `ks` 抄成 `sk`）、排序错、value 被 URL encode、body 不一致 |
| `20010` | 参数非法 | `quality` 传了不存在的代号（如 `128kmp3`、`360ra`）、`qualities` 混入非法代号 |
| `20017` | token 无效 | 未登录 / token 过期 / mid 与 token 不匹配 |
| `status: 2` | 版权或会员限制 | 未登录取高音质 |
| `10000` | 请登录后发送 | 评论写接口未登录 / mid 与 token 不绑定 |
| `10003` | 发送字数不够 | 评论内容过短 |
| `60045` | 风控拦截 | 账号 / 设备触发反垃圾策略，客户端无法绕过 |

---

## 9. 实现检查清单

- [ ] 盐值与上表逐字符一致（尤其 `...092lksi2UIkp`）。
- [ ] 签名用**原始值**拼接，URL 编码只发生在最后拼 query 时。
- [ ] 排序后 `k=v` 直接相接，无 `&`。
- [ ] `clienttime` 为**秒**级时间戳；`clientver` 取流用 `11430`，搜索用 `20489`。
- [ ] 取流 `key` 在 `signature` 之前计算，并参与 `signature`。
- [ ] `quality` 用 `128` / `320` / `flac` / `high` 等服务端代号，不是本地音质 id。
- [ ] 登录后 `userid` / `token` 与持久化 `mid` / `dfid` / `dev` 一起携带。
- [ ] `url` 兼容字符串和数组两种形态；`is_free_part` / `free_part == 1` 视为失败。
