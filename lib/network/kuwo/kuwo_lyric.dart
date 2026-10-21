// 酷我音乐歌词接口（逆向自 bai music_4.0.apk - KuwoApi.getLyricByRid / decodeLyricBytes）
//
// 接口: GET http://newlyric.kuwo.cn/newlyric.lrc?<params>
// params: Base64( XOR("user=12345,web,web,web&requester=localhost&req=1&rid=MUSIC_<rid>&lrcx=1", "yeelion") )
// 解码: tp=content 头校验 -> \r\n\r\n 后数据 -> inflate -> Base64 -> XOR("yeelion") -> GB18030
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';

class KuwoLyric {
  static const String lyricUrl = 'http://newlyric.kuwo.cn/newlyric.lrc';
  static final List<int> xorKey = utf8.encode('yeelion');
  static const String browserUa = 'Mozilla/5.0 (Linux; Android 15; V2453A '
      'Build/AP3A.240905.015.A2_V000L1) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/141.0.7390.5 Mobile Safari/537.36';

  static const Map<String, String> browserHeaders = {
    'User-Agent': browserUa,
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Host': 'newlyric.kuwo.cn',
    'Accept-Encoding': 'identity',
    'Origin': 'http://www.kuwo.cn',
    'X-Requested-With': 'XMLHttpRequest',
  };

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.bytes,
  ));

  /// XorCipher: 循环异或 key='yeelion'
  static Uint8List xorCipher(List<int> data) {
    final out = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      out[i] = data[i] ^ xorKey[i % xorKey.length];
    }
    return out;
  }

  /// 构造查询参数
  static String buildLyricParams(String rid) {
    final s =
        'user=12345,web,web,web&requester=localhost&req=1&rid=MUSIC_$rid&lrcx=1';
    return base64Encode(xorCipher(utf8.encode(s)));
  }

  /// 按 APK 的 decodeLyricBytes 流程解码
  static String? decodeLyricBytes(Uint8List raw) {
    final head = utf8.encode('tp=content');
    if (raw.length < head.length) return null;
    for (var i = 0; i < head.length; i++) {
      if (raw[i] != head[i]) return null;
    }
    // 找 \r\n\r\n
    var sep = -1;
    for (var i = 0; i <= raw.length - 4; i++) {
      if (raw[i] == 13 && raw[i + 1] == 10 && raw[i + 2] == 13 && raw[i + 3] == 10) {
        sep = i;
        break;
      }
    }
    if (sep < 0) return null;

    final tail = raw.sublist(sep + 4);
    List<int>? inflated;
    for (final rawMode in [false, true]) {
      try {
        inflated = rawMode
            ? ZLibCodec(raw: true).decode(tail.toList())
            : zlib.decode(tail.toList());
        break;
      } catch (_) {
        /* 换下一种 */
      }
    }
    if (inflated == null) return null;

    final decoded = base64Decode(String.fromCharCodes(inflated).trim());
    final plain = xorCipher(decoded);
    try {
      return gbk.decode(plain, allowMalformed: true);
    } catch (_) {
      return utf8.decode(plain, allowMalformed: true);
    }
  }

  /// 去掉逐字时间轴 <时长,起始>，转为普通 LRC
  static String krcToLrc(String? krc) {
    if (krc == null) return '';
    return krc.replaceAllMapped(RegExp(r'<\d+,-?\d+>'), (_) => '');
  }

  /// 获取歌词: {rid, krc, lrc}
  static Future<Map<String, dynamic>> getLyric(String rid) async {
    final url = '$lyricUrl?${buildLyricParams(rid)}';
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: browserHeaders,
      ),
    );
    final raw = Uint8List.fromList(resp.data ?? const <int>[]);
    final krc = decodeLyricBytes(raw);
    return {'rid': rid, 'krc': krc, 'lrc': krc == null ? null : krcToLrc(krc)};
  }
}
