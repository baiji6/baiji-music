// 酷狗音乐 —— 签名 / 公共参数（搜自 HotDownloader 与 Lyrico kugou 插件）。
//
// 酷狗公开接口需要按 key 字母序拼接后做 MD5 签名：
//   signature = md5(SALT + joined + body + SALT)
// 两套 salt 对应两套业务域名：
//   - gateway.kugou.com（搜索 / 取链 / 元数据）：appid=1005，salt=OIlwieks…
//   - lyrics.kugou.com（歌词）：appid=3116，salt=LnT6xp…（Lyrico 插件）
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// gateway.kugou.com 系列接口盐值（HotDownloader `client.rs` 的 `SALT`）。
///
/// 注意 `...092l**ks**i2UIkp`，不是 `...092l**sk**i2UIkp`。v2.5.0 曾把
/// `ks` 误抄成 `sk`，导致搜索/取链一律返回 `error_code 20006 err signature`
/// （HTTP 200 但 data.lists 为空），表现就是「酷狗无法搜索」。签名算法本身
/// 与上游一致，错的只有这一个字符顺序，已对照上游源码逐字节校正。
const String kugouGatewaySalt = 'OIlwieks28dk2k092lksi2UIkp';

/// lyrics.kugou.com 歌词接口盐值（Lyrico kugou 插件）。
const String kugouLyricSalt = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';

/// v5/url 取链 `key` 盐值（HotDownloader）。
const String kugouUrlKeySalt = '57ae12eb6890223e355ccfcb74edf70d';

/// 设备 mid（小写 32 位 hex），无登录时作为匿名标识。
String kugouDeviceMid() {
  final seed =
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';
  return md5.convert(utf8.encode(seed)).toString();
}

/// 按 key 字母序拼成 `k=v&k=v` 查询串。
String kugouBuildQuery(Map<String, String> params) {
  final keys = params.keys.toList()..sort();
  return keys
      .map((k) =>
          '${Uri.encodeComponent(k)}=${Uri.encodeComponent(params[k] ?? '')}')
      .join('&');
}

/// 酷狗签名：md5(SALT + 排序后 k=v 拼接 + body + SALT)。
String kugouSign(Map<String, String> params, String salt, {String body = ''}) {
  final keys = params.keys.toList()..sort();
  final joined = keys.map((k) => '$k=${params[k] ?? ''}').join('');
  return md5.convert(utf8.encode('$salt$joined$body$salt')).toString();
}

/// gateway.kugou.com 公共参数（appid=1005 那套）。
Map<String, String> kugouGatewayCommon({String? mid}) {
  return <String, String>{
    'dfid': '-',
    'mid': mid ?? kugouDeviceMid(),
    'uuid': '-',
    'appid': '1005',
    'clientver': '20489',
    'clienttime': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
  };
}

/// v5/url 取链 `key`：md5(hash + URL_KEY_SALT + appid + mid + userid)。
String kugouUrlKey(String hash, String mid,
    {String appid = '1005', String userid = '0'}) {
  return md5
      .convert(utf8.encode(hash + kugouUrlKeySalt + appid + mid + userid))
      .toString();
}
