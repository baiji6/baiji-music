// 酷我 MV 播放源 —— legacy playUrl（主）+ anymatch get_url_by_vid（辅）。
//
// 逆向自聆澜酷我脚本的 getMvSource（v2.4.3），两条路径：
//
// 1) legacy（主路径，实测 2026-11 可用，无需 vid）：
//    GET https://kuwo.cn/api/v1/www/music/playUrl?mid=<rid>&type=mv&httpsStatus=1
//    headers: Secret + Cookie（web 站硬编码，脚本 KUWO_MV_HEADERS 同款）
//    响应: {"code":200,"data":{"url":"https://kw-bj.kuwo.cn/....mp4"}}
//    实测 Range 请求 206、Content-Type video/mp4。
//
// 2) anymatch（有 vid 时优先，可指定画质档）：
//    GET https://anymatch.kuwo.cn/mobi.s?f=web&...&type=get_url_by_vid
//        &vid=<vid>&quality=MP4BD&...
//    headers: iPhone UA（脚本 KUWO_MV_USER_AGENT）
//    响应是 key=value 行文本（parseKuwoMvResponse 同款解析）：
//      url=... format=mp4 quality=MP4BD bitrate=3553 ...
//    quality 请求映射: 240p=MP4L 360p=MP4 480p=MP4HV 720p=MP4UL 1080p=MP4BD
//
// 搜索接口（searchMusicBykeyWord）的 abslist 不带 MVID，酷我歌曲的 MV
// 播放统一在点击时用 rid 现查（legacy 路径），不预取。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/app_logger.dart';
import 'mv_source.dart';

class KuwoMvApi {
  KuwoMvApi._();

  static const String _legacyUrl =
      'https://kuwo.cn/api/v1/www/music/playUrl';
  static const String _anymatchUrl = 'https://anymatch.kuwo.cn/mobi.s';

  /// web 站硬编码头（脚本 KUWO_MV_HEADERS 同款；实测长期有效）。
  static const Map<String, String> _legacyHeaders = {
    'Secret': '5470ccb31c2e253cf173fea957bd5e544d0b4f6e54f88190868a0817094e92'
        '0000224d1a',
    'Cookie': 'Hm_Iuvt_cdb524f42f23cer9b268564v7y735ewrq2324='
        'w6nWhWQm4y2cTbFFcXi5Xxa3KtXKnjzS',
    'Referer': 'https://kuwo.cn/',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36',
  };

  static const String _mobileUa = 'Mozilla/5.0 (iPhone; CPU iPhone OS 19_4 '
      'like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) '
      'Version/18.4 Mobile/15E148 Safari/604.1';

  /// MV CDN 防盗链头（脚本同款）。
  static const Map<String, String> cdnHeaders = {
    'Referer': 'https://kuwo.cn/',
    'User-Agent': _mobileUa,
  };

  /// 画质 → anymatch quality 参数（脚本 KUWO_MV_REQUEST_QUALITY）。
  static const Map<MvQuality, String> _requestQuality = {
    MvQuality.q240p: 'MP4L',
    MvQuality.q360p: 'MP4',
    MvQuality.q480p: 'MP4HV',
    MvQuality.q720p: 'MP4UL',
    MvQuality.q1080p: 'MP4BD',
  };

  /// anymatch quality 响应 → 画质（脚本 KUWO_MV_RESPONSE_QUALITY）。
  static const Map<String, MvQuality> _responseQuality = {
    'MP4L': MvQuality.q240p,
    'MP4': MvQuality.q360p,
    'MP4HV': MvQuality.q480p,
    'MP4UL': MvQuality.q720p,
    'MP4BD': MvQuality.q1080p,
  };

  /// 测试钩子：画质映射表（与聆澜脚本一致性回归）。
  static Map<MvQuality, String> get requestQualityMapForTest =>
      _requestQuality;
  static Map<String, MvQuality> get responseQualityMapForTest =>
      _responseQuality;

  /// 拉 MV 源：有 vid 走 anymatch（可指定画质），失败或无 vid 走 legacy。
  static Future<MvSource?> getSource(
    String rid,
    MvQuality quality, {
    String? vid,
  }) async {
    if (vid != null && vid.trim().isNotEmpty) {
      try {
        final s = await getSourceByVid(vid.trim(), quality);
        if (s != null) return s;
      } catch (e) {
        AppLog.w('KuwoMvApi', 'anymatch 路径失败，回退 legacy: $e');
      }
    }
    return getLegacySource(rid);
  }

  /// legacy：按歌曲 rid 取关联 MV（画质不可选，通常 720p 左右）。
  static Future<MvSource?> getLegacySource(String rid) async {
    final r = rid.trim().replaceFirst(RegExp(r'^MUSIC_'), '');
    if (r.isEmpty) return null;
    final uri = Uri.parse(_legacyUrl).replace(queryParameters: {
      'mid': r,
      'type': 'mv',
      'httpsStatus': '1',
    });
    final resp = await http
        .get(uri, headers: _legacyHeaders)
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw MvUnavailable('酷我 MV 接口 HTTP ${resp.statusCode}');
    }
    final Map<String, dynamic> root =
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (root['code'] != 200) {
      throw MvUnavailable('酷我 MV 接口 code=${root['code']}');
    }
    final data = root['data'];
    final url = data is Map<String, dynamic> ? data['url']?.toString() : null;
    if (url == null || url.isEmpty) return null;
    return MvSource(
      url: url,
      headers: cdnHeaders,
      videoQuality: MvQuality.q720p.key,
    );
  }

  /// anymatch：按 vid 取指定画质的源。响应是 key=value 行文本。
  static Future<MvSource?> getSourceByVid(String vid, MvQuality quality) async {
    final v = vid.trim();
    if (v.isEmpty) return null;
    final params = <String, String>{
      'f': 'web',
      'prod': 'kwplayer_ar_12.1.6.0',
      'corp': 'kuwo',
      'newver': '3',
      'vipver': '12.1.6.0',
      'source': 'kwplayer_ar_12.1.6.0_40.apk',
      'p2p': '1',
      'approval': 'false',
      'allpay': '1',
      'notrace': '0',
      'vipMode': '0',
      'type': 'get_url_by_vid',
      'vid': v,
      'quality': _requestQuality[quality] ?? 'MP4BD',
      'secureScreen': '1',
      'short_mv': '1',
      'p2pid': '1',
      'h265': '1',
    };
    final uri = Uri.parse(_anymatchUrl).replace(queryParameters: params);
    final resp = await http
        .get(uri, headers: {'User-Agent': _mobileUa, 'Accept-Encoding': 'gzip'})
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw MvUnavailable('酷我 anymatch HTTP ${resp.statusCode}');
    }
    final kv = parseKvResponse(utf8.decode(resp.bodyBytes, allowMalformed: true));
    final url = kv['url'];
    if (url == null || url.isEmpty) return null;

    // quality=MP4BD → '1080p'（脚本同款归一化）
    final rawQ = (kv['quality'] ?? '').toString().trim().toUpperCase();
    final actual = _responseQuality[rawQ] ?? quality;
    final bitrateKbps = int.tryParse(kv['bitrate'] ?? '') ?? 0;
    return MvSource(
      url: url,
      headers: cdnHeaders,
      videoQuality: actual.key,
      bitrate: bitrateKbps > 0 ? bitrateKbps * 1000 : 0,
    );
  }

  /// anymatch 响应解析：`key=value` 行文本 → map（脚本 parseKuwoMvResponse）。
  static Map<String, String> parseKvResponse(String body) {
    final out = <String, String>{};
    for (final line in body.split(RegExp(r'\r?\n'))) {
      final i = line.indexOf('=');
      if (i <= 0) continue;
      final key = line.substring(0, i).trim();
      final value = line.substring(i + 1).trim();
      if (key.isNotEmpty) out[key] = value;
    }
    return out;
  }
}
