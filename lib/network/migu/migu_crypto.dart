// 咪咕音乐 —— 签名与公共请求头（v2.6.0）。
//
// 两个来源：
//   - 搜索（jadeite v3）：洛雪 LX-X `musicSdk/mg/musicSearch.js` 的
//     `createSignature`，sign = MD5(keyword + 固定盐 + deviceId + 时间戳)，
//     且 header 里的 timestamp 必须与 sign 内的时间戳**同源**。
//   - 取流 / 探针（listen-url v2.4）：附件「小熙」插件的 UA / Referer /
//     channel / By / 随机 Cookie。
//
// 这些常量是从洛雪插件与官方客户端逆向得到的中继参数，非用户凭据，
// 与账号登录无关（咪咕在本版走匿名取流）。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 洛雪 mg 模块使用的固定设备 id（签名与 header 共用）。
const String miguDeviceId = '963B7AA0D21511ED807EE5846EC87D20';

/// 签名拼接中的固定盐片段（洛雪 createSignature）。
const String _signSalt =
    '6cdc72a439cef99a3418d2a78aa28c73yyapp2d16148780a1dcc7408e06336b98cfd50';

/// jadeite v3 搜索签名。
///
/// `sign = MD5(keyword + salt + deviceId + timeMs)`，与洛雪 JS 的
/// `toMD5(`${str}${signatureMd5}yyapp2d...${deviceId}${time}`)` 完全一致。
String miguSign(String keyword, int timeMs, {String deviceId = miguDeviceId}) {
  final raw = '$keyword$_signSalt$deviceId$timeMs';
  return md5.convert(utf8.encode(raw)).toString();
}

/// 搜索接口请求头（timestamp 须与 [miguSign] 的 timeMs 同源）。
Map<String, String> miguSearchHeaders(int timeMs, String sign) => {
      'uiVersion': 'A_music_3.6.1',
      'deviceId': miguDeviceId,
      'timestamp': '$timeMs',
      'sign': sign,
      'channel': '0146921',
      'User-Agent':
          'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) '
          'AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30',
    };

const String _desktopUa =
    'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/102.0.0.0 Safari/537.36';

const String _chars =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/// 插件格式的随机 Cookie：`SESSION=LOVELOVEYX` + 22 位字母数字。
String miguSessionCookie([Random? random]) {
  final rnd = random ?? Random();
  final sb = StringBuffer('SESSION=LOVELOVEYX');
  for (var i = 0; i < 22; i++) {
    sb.write(_chars[rnd.nextInt(_chars.length)]);
  }
  return sb.toString();
}

/// 取流 / 探针请求头（listen-url v2.4，附件插件的同款参数）。
Map<String, String> miguListenHeaders() => {
      'User-Agent': _desktopUa,
      'Connection': 'Keep-Alive',
      'Referer': 'https://m.music.migu.cn/v4/',
      'channel': '014000D',
      'By': '3c0effb5be907dd7fc209a9001a18713',
      'Cookie': miguSessionCookie(),
    };

/// 探针 Range 请求头（探测各档派生 URL 是否可用）。
Map<String, String> miguProbeHeaders() => {
      'User-Agent': _desktopUa,
      'Referer': 'https://m.music.migu.cn/v4/',
      'Range': 'bytes=0-0',
    };

/// 歌词请求头（lrcUrl 直链）。
Map<String, String> miguLyricHeaders() => {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Mobile Safari/537.36',
      'Referer': 'https://app.c.nf.migu.cn/',
      'channel': '0146921',
    };

/// 歌单接口请求头（洛雪 mg/songList.js 的 defaultHeaders）。
Map<String, String> miguPlaylistHeaders() => {
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
      'Referer': 'https://m.music.migu.cn/',
    };
