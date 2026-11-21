// JOOX 签名 / 请求头工具（v2.6.0）。逆向自 bai music 4.7 APK
// （us.yibai.baimusic.api.JooxApi / core.HmacSha256），已实测有效。
//
// 两处签名：
//   1. 取流 sign = HMAC-SHA256-hex("jooxsecret123456jooxsecret123456",
//      "{mid}:{quality}:{timestampMs}") —— 供 joox_express 参考，实际网关
//      已封装，App 侧只需带 X-API-key。
//   2. 歌词 secret = MD5("Jo0x@t3Nc3nTcountry=hk&lang=zh_cn&lyric=1&id={songid}")
//      —— JOOX 官方 track 接口必带。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// molan 取流网关地址与必带 key。
const String jooxExpressBase = 'http://molan.guoyue2010.cn/joox_express.php';
const String jooxApiKey = 'molan';

/// 歌词 track 接口的固定查询串（bai music 4.7 硬编码）。
const String jooxTrackQuery = 'country=hk&lang=zh_cn&lyric=1';

String _md5Hex(String s) => md5.convert(utf8.encode(s)).toString();

/// JOOX 官方 track 接口的 secret。
String jooxTrackSecret(String songId) =>
    _md5Hex('Jo0x@t3Nc3nT$jooxTrackQuery&id=$songId');

/// JOOX 取流签名（保留给需要直连官方 express 的场景；molan 网关已封装）。
String jooxSign(String mid, String quality, int timestampMs) {
  final hmac = Hmac(sha256, utf8.encode('jooxsecret123456jooxsecret123456'));
  return hmac.convert(utf8.encode('$mid:$quality:$timestampMs')).toString();
}

/// JOOX track 接口请求头（对齐 bai music 4.7 okhttp 指纹）。
Map<String, String> jooxTrackHeaders() => const <String, String>{
      'User-Agent': 'okhttp/5.3.2',
      'Connection': 'Keep-Alive',
      'Accept-Encoding': 'gzip',
      'Cookie': '_uniqId=e87oit',
    };

/// JOOX 官方搜索请求头（固定设备指纹，逆向自 bai music 4.7）。
Map<String, String> jooxSearchHeaders() => const <String, String>{
      'Content-Type': 'application/json',
      'User-Agent': 'okhttp/5.3.2',
    };

/// JOOX 官方搜索 header 体里的设备指纹 JSON。
const String jooxDeviceHeader = '{"iUid":"0","iSid":"0","iCv":20201,'
    '"sPhoneType":"Android-V2106A",'
    '"sOpenUdid":"0000000046934d5a00000195c34e12e2",'
    '"iMcc":"65535","iMnc":"65535","sCountry":"CN","sLang":"zh_CN",'
    '"iWmid":"339585933","iChid":"000","sBackendCountry":"hk",'
    '"iUserType":0,"sOsVer":"30",'
    '"sSkey":"9a802401f73705e0d7a6659382eb79de","iNetType":1,'
    '"iMlid":"0","iVip":0,"iVvip":0,"iAppStoreChannel":0,'
    '"iTerminalType":0,"sAppid":"1000716","sDebugInfo":""}';
