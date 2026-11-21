// JOOX 核心网络层（搜索 / 取流 / 歌词 / 音质探测，v2.6.0）。
//
// 接口全部逆向自 bai music 4.7 APK（us.yibai.baimusic.api.JooxApi），
// 并逐个实测有效（2026-11）：
//   - 搜索：POST http://avatar.api.joox.com/commonCgi/search/get
//     JSON body，歌名/歌手/专辑是 base64，返回 songid(数字)+songmid(字符串)。
//   - 取流：GET molan joox_express.php?quality=&mid=（X-API-key: molan），
//     返回 items[0].urls[] 直链，filename 前缀标识档位。
//   - 歌词：GET cache.api.joox.com/openjoox2/v1/track/{songid}?...&secret=，
//     qrc_content(明文XML的base64) / lrc_content(明文LRC的base64)。
//
// 解析逻辑均为纯函数（parseSearchResponse / parseExpressResponse /
// parseTrackResponse / extractQrcLyric），离线单测直接喂真实片段。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../models/models.dart';
import 'joox_crypto.dart';

/// JOOX 单首歌曲元信息。
class JooxSong {
  /// 数字 id（歌词 track 接口用）。
  final String songId;

  /// 字符串 mid（取流 express 接口用）。
  final String songMid;

  final String name;
  final String singer;
  final String album;
  final int durationSeconds;
  final String mvId;

  /// 封面直链（image.joox.com）。
  final String cover;

  const JooxSong({
    required this.songId,
    required this.songMid,
    required this.name,
    required this.singer,
    this.album = '',
    this.durationSeconds = 0,
    this.mvId = '',
    this.cover = '',
  });
}

/// molan express 取流结果。
class JooxExpressInfo {
  /// 首个可用直链。
  final String url;

  /// 服务端返回的 filename（含档位前缀，如 AIM0xxx.flac）。
  final String filename;

  const JooxExpressInfo({required this.url, this.filename = ''});
}

/// JOOX track 接口返回的歌词结果。
class JooxLyricInfo {
  /// QRC 逐字歌词（已从 XML 提取 LyricContent，未解密/未解析）。
  final String qrc;

  /// 纯 LRC 逐行歌词。
  final String lrc;

  const JooxLyricInfo({this.qrc = '', this.lrc = ''});
}

class JooxApi {
  JooxApi._();

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    validateStatus: (_) => true,
  ));

  /// 搜索结果缓存（key = songMid），供歌词/取流补全元信息。
  static final Map<String, JooxSong> _songCache = <String, JooxSong>{};

  static JooxSong? cachedSong(String songMid) => _songCache[songMid];

  /// 搜索（page 从 1 起）。歌名等字段是 base64。
  static Future<List<JooxSong>> search(String keyword,
      {int page = 1, int num = 20}) async {
    final body = <String, dynamic>{
      'header': jsonDecode(jooxDeviceHeader),
      'type': 0,
      'keyword': keyword,
      'keyword_source': 0,
      'search_id': '0',
      'nqc_flag': 0,
      'page_size': num,
      'num_per_page': num,
      'page': page,
      'custom_params': <String, dynamic>{'ambi_data': ''},
    };
    final resp = await _dio.post<String>(
      'http://avatar.api.joox.com/commonCgi/search/get',
      data: jsonEncode(body),
      options: Options(headers: jooxSearchHeaders()),
    );
    final list = parseSearchResponse(_decodeJson(resp.data));
    for (final s in list) {
      _songCache[s.songMid] = s;
    }
    return list;
  }

  /// 解析搜索响应（纯函数）。
  ///
  /// 真实结构：song_aggregation_list[*].item_list[*].song_info{songid,songmid,
  /// songname(base64),singername(base64),albumname(base64),playtime,vid,...}
  static List<JooxSong> parseSearchResponse(dynamic raw) {
    final out = <JooxSong>[];
    if (raw is! Map) return out;
    final groups = raw['song_aggregation_list'];
    if (groups is! List) return out;
    for (final g in groups) {
      if (g is! Map) continue;
      final items = g['item_list'];
      if (items is! List) continue;
      for (final it in items) {
        if (it is! Map) continue;
        final info = it['song_info'];
        if (info is! Map) continue;
        final songId = _str(info['songid']);
        final songMid = _str(info['songmid']);
        if (songId.isEmpty || songMid.isEmpty) continue;
        out.add(JooxSong(
          songId: songId,
          songMid: songMid,
          name: _b64(_str(info['songname'])),
          singer: _b64(_str(info['singername'])),
          album: _b64(_str(info['albumname'])),
          durationSeconds: _intOf(info['playtime']) ?? 0,
          mvId: _intOf(info['vid'])?.toString() ?? _str(info['vid']),
          cover: _str(info['album_url']),
        ));
      }
    }
    return out;
  }

  /// 取流：按档位请求 molan express，返回首个可用直链。
  static Future<JooxExpressInfo> getExpress(String mid, JooxQuality q) async {
    final url = '$jooxExpressBase'
        '?quality=${Uri.encodeComponent(q.id)}&mid=${Uri.encodeComponent(mid)}';
    final resp = await _dio.get<String>(
      url,
      options: Options(headers: <String, String>{
        'X-API-key': jooxApiKey,
        'Accept': '*/*',
      }),
    );
    return parseExpressResponse(_decodeJson(resp.data));
  }

  /// 解析 express 响应（纯函数）。ok=false 视为无该档。
  static JooxExpressInfo parseExpressResponse(dynamic raw) {
    if (raw is! Map || raw['ok'] != true) return const JooxExpressInfo(url: '');
    final items = raw['items'];
    if (items is! List || items.isEmpty) return const JooxExpressInfo(url: '');
    final first = items.first;
    if (first is! Map) return const JooxExpressInfo(url: '');
    final urls = first['urls'];
    String url = '';
    if (urls is List) {
      for (final u in urls) {
        if (u is String && u.isNotEmpty) {
          url = u;
          break;
        }
      }
    }
    return JooxExpressInfo(url: url, filename: _str(first['filename']));
  }

  /// 音质探针缓存（key = songMid）与在途去重。
  static final Map<String, Set<String>> _probeCache = <String, Set<String>>{};
  static final Map<String, Future<Set<String>>> _probeInflight =
      <String, Future<Set<String>>>{};

  /// 逐档请求 express 接口，探测该歌曲实际拥有的音质档位。
  /// 只探测 downloadOptions 全集，结果作为 Song.qualityCodes 供 UI 收敛展示。
  static Future<Set<String>> probeQualityCodes(String songMid) async {
    final cached = _probeCache[songMid];
    if (cached != null) return cached;
    final inflight = _probeInflight[songMid];
    if (inflight != null) return inflight;

    final future = _doProbe(songMid);
    _probeInflight[songMid] = future;
    try {
      final codes = await future;
      _probeCache[songMid] = codes;
      return codes;
    } finally {
      _probeInflight.remove(songMid);
    }
  }

  static Future<Set<String>> _doProbe(String songMid) async {
    final codes = <String>{};
    // 6 档并发探测，单档失败乐观保留（播放降级链兜底）。
    final results = await Future.wait(
      JooxQuality.playbackOptions.map((q) async {
        try {
          final info = await getExpress(songMid, q);
          return info.url.isNotEmpty ? q.id : '';
        } catch (e) {
          AppLog.w('JooxApi', '音质探测 ${q.id} 失败: $e');
          return q.id; // 网络错误乐观保留
        }
      }),
    );
    for (final id in results) {
      if (id.isNotEmpty) codes.add(id);
    }
    return codes;
  }

  /// 歌词：JOOX 官方 track 接口。优先 QRC 逐字，回退 LRC。
  static Future<JooxLyricInfo> lyric(String songId) async {
    if (songId.isEmpty) return const JooxLyricInfo();
    final secret = jooxTrackSecret(songId);
    final url = 'http://cache.api.joox.com/openjoox2/v1/track/$songId'
        '?$jooxTrackQuery&secret=$secret';
    try {
      final resp = await _dio.get<String>(
        url,
        options: Options(headers: jooxTrackHeaders(), responseType: ResponseType.plain),
      );
      final raw = _decodeJson(resp.data);
      if (raw is! Map) return const JooxLyricInfo();
      final qrcB64 = _str(raw['qrc_content']);
      final lrcB64 = _str(raw['lrc_content']);
      final qrc = qrcB64.isEmpty ? '' : extractQrcLyric(_b64Decode(qrcB64));
      final lrc = lrcB64.isEmpty ? '' : _b64Decode(lrcB64);
      return JooxLyricInfo(qrc: qrc, lrc: lrc);
    } catch (e) {
      AppLog.w('JooxApi', '歌词获取失败 songId=$songId: $e');
      return const JooxLyricInfo();
    }
  }

  /// 从 JOOX QRC 明文 XML 中提取 LyricContent 属性值（纯函数）。
  ///
  /// 形如 `<Lyric_1 ... LyricContent="[ti:..]\n[0,3100]最(0,182)..."/>`
  /// 取第一个非空 LyricContent，并把 XML 转义还原。
  static String extractQrcLyric(String xml) {
    if (xml.isEmpty) return '';
    final m = RegExp(r'LyricContent="([^"]*)"').firstMatch(xml);
    if (m == null) return '';
    return m.group(1)!
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('\\n', '\n')
        .replaceAll('\\r', '\r');
  }

  static String _b64(String s) {
    if (s.isEmpty) return '';
    try {
      return utf8.decode(base64Decode(s));
    } catch (_) {
      return s;
    }
  }

  static String _b64Decode(String s) {
    if (s.isEmpty) return '';
    try {
      return utf8.decode(base64Decode(s));
    } catch (_) {
      return s;
    }
  }

  static String _str(dynamic v) => v == null ? '' : v.toString();

  /// 兼容 int / double / num字符串（JOOX 接口的 playtime/vid 类型不固定）。
  static int? _intOf(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static dynamic _decodeJson(String? body) {
    if (body == null || body.trim().isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}
