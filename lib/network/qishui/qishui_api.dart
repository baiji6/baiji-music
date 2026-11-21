// 汽水音乐核心网络层（搜索 / 取流 / 歌词，v2.6.1）。
//
// 接口与解析均为纯函数化，便于离线单测：
//   - 搜索：GET api-vehicle.volcengine.com/v2/search/type
//     ?keyword=&search_source=qishui&search_type=music&limit=（零签名零登录），
//     返回 data.list[]：item_id / title / author_info.name / cover_url / duration。
//   - 取流：GET molan qishui.php?quality=medium&id=<item_id>（header key: molan 必带），
//     返回 data.url（明文 medium M4A 直链），响应自带 data.lyric（标准 LRC + lines[]）。
//   - 歌词：优先复用取流响应的 data.lyric.lrc；独立取词走
//     GET beta-luna.douyin.com/luna/h5/seo_track?track_id=<id>&device_platform=web，
//     返回顶层 lyric.content（汽水 krc 逐字），此处转成项目 YRC 格式交给 LyricParser。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/app_logger.dart';

/// 汽水单首歌曲元信息。
class QishuiSong {
  /// 音频文章 itemId（取流 id / 歌词 track_id 都用它）。
  final String itemId;

  final String name;
  final String singer;
  final String album;
  final int durationSeconds;

  /// 封面直链（p3-luna.douyinpic.com，可改末尾 :0:N 尺寸）。
  final String cover;

  const QishuiSong({
    required this.itemId,
    required this.name,
    this.singer = '',
    this.album = '',
    this.durationSeconds = 0,
    this.cover = '',
  });
}

/// molan qishui.php 取流结果。
class QishuiStreamInfo {
  /// 明文 medium 直链。
  final String url;

  /// 备用直链（urls[]）。
  final List<String> urls;

  /// 服务端实际下发音质（匿名通道恒 medium）。
  final String actualQuality;

  /// 取流响应自带的歌词（标准 LRC，可能为空）。
  final String lrc;

  /// 封面 1080 直链（取流响应 covers.1080 / cover）。
  final String cover;

  final String title;
  final String artist;
  final String album;
  final int durationSeconds;

  const QishuiStreamInfo({
    required this.url,
    this.urls = const [],
    this.actualQuality = 'medium',
    this.lrc = '',
    this.cover = '',
    this.title = '',
    this.artist = '',
    this.album = '',
    this.durationSeconds = 0,
  });
}

class QishuiApi {
  QishuiApi._();

  static const String searchBase =
      'https://api-vehicle.volcengine.com/v2/search/type';
  static const String expressBase = 'http://molan.guoyue2010.cn/qishui.php';
  static const String seoTrackBase =
      'https://beta-luna.douyin.com/luna/h5/seo_track';
  static const String apiKey = 'molan';

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    validateStatus: (_) => true,
  ));

  static const String _searchUa =
      'com.bytedance.byteautoservice/320001 (Linux; U; Android 11; zh_CN)';
  static const String _webUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1';

  /// 搜索（page 从 1 起）。匿名接口 limit 实测支持 10/20/30/50，无截断。
  static Future<List<QishuiSong>> search(String keyword,
      {int page = 1, int num = 20}) async {
    final query = <String, dynamic>{
      'keyword': keyword,
      'search_source': 'qishui',
      'search_type': 'music',
      'limit': num < 10 ? 10 : num,
    };
    // 翻页：把上一页的 search_params 原样回传（v2.6.1 先支持首页，
    // 传 offset 作为兜底；服务端实际以 search_params 为准）。
    if (page > 1) {
      query['real_offset'] = (page - 1) * num;
    }
    final resp = await _dio.get<String>(
      searchBase,
      queryParameters: query,
      options: Options(headers: <String, String>{
        'User-Agent': _searchUa,
        'Accept': 'application/json',
      }),
    );
    final list = parseSearchResponse(_decodeJson(resp.data));
    for (final s in list) {
      _songCache[s.itemId] = s;
    }
    return list;
  }

  /// 搜索结果缓存（itemId → song），供歌词/取流补全。
  static final Map<String, QishuiSong> _songCache = <String, QishuiSong>{};
  static QishuiSong? cachedSong(String itemId) => _songCache[itemId];

  /// 解析搜索响应（纯函数）。
  static List<QishuiSong> parseSearchResponse(dynamic raw) {
    final out = <QishuiSong>[];
    if (raw is! Map) return out;
    final data = raw['data'];
    if (data is! Map) return out;
    final list = data['list'];
    if (list is! List) return out;
    for (final it in list) {
      if (it is! Map) continue;
      final itemId = _str(it['item_id']);
      if (itemId.isEmpty) continue;
      final author = it['author_info'];
      String singer = '';
      if (author is Map) {
        singer = _str(author['name']);
      }
      out.add(QishuiSong(
        itemId: itemId,
        name: _str(it['title']),
        singer: singer,
        durationSeconds: _intOf(it['duration']) ?? 0,
        cover: _str(it['cover_url']),
      ));
    }
    return out;
  }

  /// 取流：调 molan qishui.php，返回首个可用直链 + 自带歌词。
  static Future<QishuiStreamInfo> getStream(String itemId) async {
    final resp = await _dio.get<String>(
      expressBase,
      queryParameters: <String, dynamic>{
        'quality': 'medium',
        'id': itemId,
      },
      options: Options(headers: <String, String>{
        'key': apiKey,
        'Accept': '*/*',
      }),
    );
    return parseStreamResponse(_decodeJson(resp.data));
  }

  /// 解析取流响应（纯函数）。code!=0 视为失败（url 空）。
  static QishuiStreamInfo parseStreamResponse(dynamic raw) {
    if (raw is! Map || raw['code'] != 0) {
      return const QishuiStreamInfo(url: '');
    }
    final data = raw['data'];
    if (data is! Map) return const QishuiStreamInfo(url: '');

    final url = _str(data['url']);
    if (url.isEmpty) return const QishuiStreamInfo(url: '');

    final urls = <String>[];
    final candidates = data['urls'];
    if (candidates is List) {
      for (final u in candidates) {
        if (u is String && u.isNotEmpty) urls.add(u);
      }
    }

    // 歌词：优先标准 LRC。
    String lrc = '';
    final lyric = data['lyric'];
    if (lyric is Map) lrc = _str(lyric['lrc']);

    // 封面：优先 covers.1080，回退 cover。
    String cover = _str(data['cover']);
    final covers = data['covers'];
    if (covers is Map && _str(covers['1080']).isNotEmpty) {
      cover = _str(covers['1080']);
    }

    return QishuiStreamInfo(
      url: url,
      urls: urls,
      actualQuality: _str(data['actual_quality']).isEmpty
          ? 'medium'
          : _str(data['actual_quality']),
      lrc: lrc,
      cover: cover,
      title: _str(data['title']),
      artist: _str(data['artist']),
      album: _str(data['album']),
      durationSeconds: _intOf(data['duration']) ?? 0,
    );
  }

  /// 独立歌词：seo_track 顶层 lyric.content（汽水 krc）。
  /// 返回已转成项目 YRC 格式的文本（可直接交 LyricParser.parse）。
  static Future<String> lyric(String itemId) async {
    if (itemId.isEmpty) return '';
    try {
      final resp = await _dio.get<String>(
        seoTrackBase,
        queryParameters: <String, dynamic>{
          'track_id': itemId,
          'device_platform': 'web',
        },
        options: Options(headers: <String, String>{
          'User-Agent': _webUa,
          'Accept': 'application/json',
        }),
      );
      final raw = _decodeJson(resp.data);
      if (raw is! Map) return '';
      final lyricObj = raw['lyric'];
      if (lyricObj is! Map) return '';
      // hide_request_lyrics=true 表示无展示授权。
      if (lyricObj['hide_request_lyrics'] == true) return '';
      final content = _str(lyricObj['content']);
      return krcToYrc(content);
    } catch (e) {
      AppLog.w('QishuiApi', '歌词获取失败 id=$itemId: $e');
      return '';
    }
  }

  /// 把汽水 krc 逐字文本转成项目 LyricParser 支持的 YRC 格式。
  ///
  /// 汽水 krc：
  ///   `[行开始ms,行时长ms]<字相对行首偏移ms,字时长ms,0>字<...>字...`
  /// 项目 YRC：
  ///   `[行开始ms,行时长ms](字绝对ms,字时长ms,0)字(...)字...`
  /// 差异：①尖括号→圆括号；②字偏移是相对行首，需 + 行起始时间。
  static String krcToYrc(String krc) {
    if (krc.trim().isEmpty) return '';
    final lineRe = RegExp(r'^\[(\d+),(\d+)\](.*)$');
    final wordRe = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');
    final buf = StringBuffer();

    for (final rawLine in const LineSplitter().convert(krc)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final m = lineRe.firstMatch(line);
      if (m == null) {
        // 非 krc 行（如 [ti:..] 元信息）原样保留。
        buf.writeln(line);
        continue;
      }
      final lineStart = int.tryParse(m.group(1)!) ?? 0;
      final lineDur = int.tryParse(m.group(2)!) ?? 0;
      final body = m.group(3) ?? '';
      final out = StringBuffer('[$lineStart,$lineDur]');
      final matches = wordRe.allMatches(body).toList();
      if (matches.isEmpty) {
        // 整行无逐字：保留纯文本。
        out.write(_decodeEntities(body.trim()));
        buf.writeln(out.toString());
        continue;
      }
      for (final wm in matches) {
        final rel = int.tryParse(wm.group(1)!) ?? 0;
        final dur = int.tryParse(wm.group(2)!) ?? 0;
        final text = _decodeEntities(wm.group(3) ?? '');
        out.write('(${lineStart + rel},$dur,0)$text');
      }
      buf.writeln(out.toString());
    }
    return buf.toString().trim();
  }

  static String _decodeEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");

  static String _str(dynamic v) => v == null ? '' : v.toString();

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
