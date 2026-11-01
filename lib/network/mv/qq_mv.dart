// QQ 音乐 MV 播放源 —— gosrf.Stream.MvUrlProxy / GetMvUrls。
//
// 逆向自聆澜 QQ 脚本的 getMvSource（v2.4.3），接口无需登录：
//
//   GET https://u.y.qq.com/cgi-bin/musicu.fcg
//       ?format=json&data={"comm":{"ct":24,"cv":4747474},
//         "getMVUrl":{"module":"gosrf.Stream.MvUrlProxy",
//                     "method":"GetMvUrls",
//                     "param":{"vids":["<vid>"],"request_typet":10001}}}
//
// 响应（实测 2026-11，vid=w0026q7f01a 晴天 MV）：
//   data[vid].mp4 = [ {filetype, code, fileSize, expire, freeflow_url[], ...} ]
//   filetype: 10=360p 20=480p 30=720p 40=1080p 50=4k
//   code: 0=可用 1000/2000=无权限/无流
//   freeflow_url: http:// 直链（多 CDN），取 https 优先，http 升 https。
//
// 注意：vid 是 "w0026q7f01a" 这类字符串；纯数字是旧 mvId，
// GetMvUrls 不认（脚本里 /^\d+$/ 直接判 null），传入前必须过滤。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/app_logger.dart';
import 'mv_source.dart';

class QQMvApi {
  QQMvApi._();

  static const String _fcgUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';

  /// MV CDN 的 Referer 防盗链（脚本同款）。
  static const Map<String, String> cdnHeaders = {
    'Referer': 'https://y.qq.com/',
    'User-Agent': _ua,
  };

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// filetype → 画质档（脚本 videoQualityLevels 同序）。
  static const List<({int filetype, MvQuality quality})> _levels = [
    (filetype: 10, quality: MvQuality.q360p),
    (filetype: 20, quality: MvQuality.q480p),
    (filetype: 30, quality: MvQuality.q720p),
    (filetype: 40, quality: MvQuality.q1080p),
    (filetype: 50, quality: MvQuality.q4k),
  ];

  /// vid 有效性：非空且非纯数字（纯数字是旧 mvId，接口不认）。
  static bool isVidValid(String? vid) {
    final v = (vid ?? '').trim();
    return v.isNotEmpty && !RegExp(r'^\d+$').hasMatch(v);
  }

  /// 拉取 MV 播放源。[vid] 必须是字符串型 vid。
  static Future<MvSource?> getSource(String vid, MvQuality quality) async {
    final v = vid.trim();
    if (!isVidValid(v)) return null;

    final data = <String, dynamic>{
      'comm': {'ct': 24, 'cv': 4747474},
      'getMVUrl': {
        'module': 'gosrf.Stream.MvUrlProxy',
        'method': 'GetMvUrls',
        'param': {'vids': [v], 'request_typet': 10001},
      },
    };
    final uri = Uri.parse(_fcgUrl).replace(queryParameters: {
      'format': 'json',
      'data': jsonEncode(data),
    });

    final resp = await http
        .get(uri, headers: {'User-Agent': _ua, 'Referer': 'https://y.qq.com/'})
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw MvUnavailable('QQ MV 接口 HTTP ${resp.statusCode}');
    }
    final Map<String, dynamic> root =
        (jsonDecode(utf8.decode(resp.bodyBytes)) as Map)['getMVUrl']
            as Map<String, dynamic>? ?? const {};
    final code = root['code'];
    if (code != 0) {
      throw MvUnavailable('QQ MV 接口 code=$code');
    }
    final data2 = root['data'];
    if (data2 is! Map<String, dynamic>) return null;
    final entry = data2[v];
    if (entry is! Map<String, dynamic>) return null;

    final streams = _normalizeStreams(entry['mp4']);
    final usable = _usableStreams(streams);
    if (usable.isEmpty) {
      throw MvUnavailable('该 MV 暂无可用播放流（可能仅 VIP 可看）');
    }
    final picked = pickStream(usable, quality);
    if (picked == null) return null;

    final urls = (picked['freeflow_url'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
    var url = urls.firstWhere((u) => u.startsWith('https://'),
        orElse: () => urls.isNotEmpty ? urls.first : '');
    if (url.startsWith('http://')) url = url.replaceFirst('http:', 'https:');
    if (url.isEmpty) return null;

    final expire = _num(picked['expire']);
    return MvSource(
      url: url,
      headers: cdnHeaders,
      videoQuality: qualityOf(picked).key,
      size: _num(picked['fileSize'] ?? picked['filesize'] ?? picked['size']),
      bitrate: _num(picked['bitrate']),
      backupUrls: urls.where((u) => u != url).toList(),
      expiresInSeconds: expire > 0 ? expire : 0,
    );
  }

  /// 该 MV 的可用画质列表（按档位从低到高）。
  static Future<List<MvQuality>> availableQualities(String vid) async {
    final v = vid.trim();
    if (!isVidValid(v)) return const [];
    final data = <String, dynamic>{
      'comm': {'ct': 24, 'cv': 4747474},
      'getMVUrl': {
        'module': 'gosrf.Stream.MvUrlProxy',
        'method': 'GetMvUrls',
        'param': {'vids': [v], 'request_typet': 10001},
      },
    };
    final uri = Uri.parse(_fcgUrl).replace(queryParameters: {
      'format': 'json',
      'data': jsonEncode(data),
    });
    final resp = await http
        .get(uri, headers: {'User-Agent': _ua, 'Referer': 'https://y.qq.com/'})
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) return const [];
    try {
      final root = (jsonDecode(utf8.decode(resp.bodyBytes))
          as Map)['getMVUrl'] as Map<String, dynamic>? ?? const {};
      final data2 = root['data'];
      if (data2 is! Map<String, dynamic>) return const [];
      final entry = data2[v];
      if (entry is! Map<String, dynamic>) return const [];
      final usable = _usableStreams(_normalizeStreams(entry['mp4']));
      // 同一画质可能命中多档 filetype，去重后按档位排序
      final set = <MvQuality>{};
      for (final s in usable) {
        set.add(qualityOf(s));
      }
      final list = set.toList()
        ..sort((a, b) => a.height.compareTo(b.height));
      return list;
    } catch (e) {
      AppLog.w('QQMvApi', 'availableQualities 解析失败: $e');
      return const [];
    }
  }

  /// mp4 字段可能是数组或 map（不同接口形态），统一成 list。
  static List<Map<String, dynamic>> _normalizeStreams(dynamic mp4) {
    final List<dynamic> list;
    if (mp4 is List) {
      list = mp4;
    } else if (mp4 is Map) {
      list = mp4.values.toList();
    } else {
      return const [];
    }
    return list
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  /// 过滤出可用流：code==0 且 freeflow_url 非空。
  static List<Map<String, dynamic>> _usableStreams(
      List<Map<String, dynamic>> streams) {
    return streams.where((s) {
      if (_num(s['code']) != 0) return false;
      final urls = s['freeflow_url'];
      return urls is List && urls.isNotEmpty;
    }).toList();
  }

  /// 挑流：目标高度精确命中 → 不超过目标的最大档 → 最低档（脚本同策略）。
  static Map<String, dynamic>? pickStream(
      List<Map<String, dynamic>> usable, MvQuality target) {
    if (usable.isEmpty) return null;
    final byQuality = <MvQuality, Map<String, dynamic>>{};
    for (final s in usable) {
      byQuality[qualityOfForTest(s)] = s;
    }
    // 精确命中
    final exact = byQuality[target];
    if (exact != null) return exact;
    // 不超过目标的最大档
    final lower = byQuality.entries
        .where((e) => e.key.height <= target.height)
        .toList()
      ..sort((a, b) => a.key.height.compareTo(b.key.height));
    if (lower.isNotEmpty) return lower.last.value;
    // 全都高于目标 → 最低档
    final all = byQuality.entries.toList()
      ..sort((a, b) => a.key.height.compareTo(b.key.height));
    return all.first.value;
  }

  /// stream 的 filetype → 画质档。未知 filetype 归到 480p 档（不丢弃）。
  static MvQuality qualityOf(Map<String, dynamic> stream) =>
      qualityOfForTest(stream);

  static MvQuality qualityOfForTest(Map<String, dynamic> stream) {
    final ft = _num(stream['filetype']);
    for (final l in _levels) {
      if (l.filetype == ft) return l.quality;
    }
    return MvQuality.q480p;
  }

  /// 该流是否可用（测试钩子）。
  static bool isStreamUsableForTest(Map<String, dynamic> stream) =>
      _usableStreams([stream]).isNotEmpty;

  static int _num(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}
