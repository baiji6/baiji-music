// 汽水音乐核心网络层（搜索 / 取流 / 歌词，v2.6.2 全音质）。
//
// 接口与解析均为纯函数化，便于离线单测：
//   - 搜索：GET api-vehicle.volcengine.com/v2/search/type
//     ?keyword=&search_source=qishui&search_type=music&limit=（零签名零登录），
//     返回 data.list[]：item_id / title / author_info.name / cover_url / duration。
//   - 取流：GET molan qishui2.php?quality=<档位名>&id=<item_id>
//     （header key: molan 必带）。一次返回全 14 档（Q01–Q14），每档含
//     code / quality / vtype / codec / url / spade_a / kid / encrypted / playable。
//     data.url 是本次命中档的主直链；encrypted=true 时需用同档 spade_a 走
//     本地 CENC 解密（见 qishui_cenc.dart / qishui_relay.dart）。
//     响应自带 data.lyric（标准 LRC + lines[]）。
//   - 歌词：优先复用取流响应的 data.lyric.lrc；独立取词走
//     GET beta-luna.douyin.com/luna/h5/seo_track?track_id=<id>&device_platform=web，
//     返回顶层 lyric.content（汽水 krc 逐字），此处转成项目 YRC 格式交给 LyricParser。
// ignore_for_file: curly_braces_in_flow_control_structures
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../models/models.dart';

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

/// molan qishui2.php 取流结果（全音质）。
class QishuiStreamInfo {
  /// 本次命中档的主直链（可能是 CENC 加密流）。
  final String url;

  /// 备用直链（兼容旧网关 urls[]；qishui2.php 通常为空）。
  final List<String> urls;

  /// 命中的档位名（original/lossless/hi_res/…）。
  final String actualQuality;

  /// 命中的编号（Q01/Q06a/Q14 …）。
  final String actualCode;

  /// 是否 CENC 加密（需本地解密）。
  final bool encrypted;

  /// 解密密钥材料（与音频同源），仅加密档非空。
  final String spadeA;
  final String kid;

  /// 容器 / 编码 / 码率（响应实测值）。
  final String vtype;
  final String codec;
  final int bitrate;

  /// 全部档位编号（探测用，如 Q01/Q03/Q06a …）。
  final List<String> availableCodes;

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
    this.actualCode = '',
    this.encrypted = false,
    this.spadeA = '',
    this.kid = '',
    this.vtype = '',
    this.codec = '',
    this.bitrate = 0,
    this.availableCodes = const [],
    this.lrc = '',
    this.cover = '',
    this.title = '',
    this.artist = '',
    this.album = '',
    this.durationSeconds = 0,
  });

  /// 直链可用；加密档必须有 spade_a 才能解密。
  bool get isUsable => url.isNotEmpty && (!encrypted || spadeA.isNotEmpty);

  /// 落盘扩展名：按实际编码推断（FLAC 档 → .flac，AAC 档 → .m4a）。
  String get outputExt {
    final c = codec.isNotEmpty ? codec : vtype;
    final l = c.toLowerCase();
    if (l.contains('flac')) return '.flac';
    if (l == 'wav') return '.wav';
    return '.m4a';
  }

  /// 映射到项目音质枚举（按档位名；请求降级时用实际命中名兜底）。
  QishuiQuality? get quality => QishuiQuality.fromId(actualQuality);
}

class QishuiApi {
  QishuiApi._();

  static const String searchBase =
      'https://api-vehicle.volcengine.com/v2/search/type';
  /// v2.6.2：全音质网关 qishui2.php（header key: molan）。
  static const String expressBase = 'http://molan.guoyue2010.cn/qishui2.php';
  static const String seoTrackBase =
      'https://beta-luna.douyin.com/luna/h5/seo_track';
  static const String apiKey = 'molan';

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
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

  /// 取流：调 molan qishui2.php，按档位名请求，返回全音质信息。
  ///
  /// [quality] 传档位名（QishuiQuality.id，如 'lossless'/'hi_res'）；
  /// 不传时默认 'medium'（兼容旧调用与歌词兜底）。
  static Future<QishuiStreamInfo> getStream(String itemId,
      {String quality = 'medium'}) async {
    final resp = await _dio.get<String>(
      expressBase,
      queryParameters: <String, dynamic>{
        'quality': quality,
        'id': itemId,
      },
      options: Options(headers: <String, String>{
        'key': apiKey,
        'Accept': '*/*',
      }),
    );
    return parseStreamResponse(_decodeJson(resp.data));
  }

  /// 探测该曲实际可用档位（打开音质弹层 / 首播时调用，避免搜索风暴）。
  ///
  /// qishui2.php 一次返回全部档位，故取 'best' 解析 qualities[] 即可，
  /// 再按 Q 编号段映射到项目 9 个逻辑档位。
  static Future<Set<String>> probeQualityCodes(String itemId) async {
    try {
      final info = await getStream(itemId, quality: 'best');
      return qualityCodesFromCodes(info.availableCodes);
    } catch (e) {
      AppLog.w('QishuiApi', '档位探测失败 id=$itemId: $e');
      return const <String>{};
    }
  }

  /// Q 编号 → 逻辑档位 id（Q01→original；Q02/Q03→lossless；带 a/b 后缀也认）。
  ///
  /// 纯函数，便于离线单测。VIP 歌缺档时只返回实际存在的档位。
  static Set<String> qualityCodesFromCodes(Iterable<String> codes) {
    final out = <String>{};
    for (final raw in codes) {
      final c = raw.toUpperCase();
      String base = c;
      if (base.length >= 4 && RegExp(r'[A-Z]$').hasMatch(base)) {
        base = base.substring(0, base.length - 1); // Q06a → Q06
      }
      final n = int.tryParse(base.replaceFirst('Q', ''));
      if (n == null) continue;
      String? id;
      if (n == 1) id = 'original';
      else if (n == 2 || n == 3) id = 'lossless';
      else if (n == 4) id = 'hi_res';
      else if (n == 5) id = 'spatial';
      else if (n == 6 || n == 7) id = 'highest';
      else if (n == 8 || n == 9) id = 'higher';
      else if (n == 10 || n == 11) id = 'medium';
      else if (n == 12 || n == 13) id = 'low';
      else if (n == 14) id = 'lowest';
      if (id != null) out.add(id);
    }
    return out;
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

    final actualCode = _str(data['actual_code']);
    final encrypted = data['encrypted'] == true;
    var spadeA = _str(data['spade_a']);
    var kid = _str(data['kid']);
    var vtype = _str(data['vtype']);
    var codec = _str(data['codec']);
    var bitrate = _intOf(data['bitrate']) ?? 0;
    final availableCodes = <String>[];

    // 从 qualities[] 用本次命中的 actual_code 精确取元数据；
    // 顶层 spade_a 在 qishui2.php 为空，必须从同档条目取。
    final qualities = data['qualities'];
    if (qualities is List) {
      for (final q in qualities) {
        if (q is! Map) continue;
        final code = _str(q['code']);
        if (code.isNotEmpty) availableCodes.add(code);
        if (code.isNotEmpty && code == actualCode) {
          if (spadeA.isEmpty) spadeA = _str(q['spade_a']);
          if (kid.isEmpty) kid = _str(q['kid']);
          if (vtype.isEmpty) vtype = _str(q['vtype']);
          if (codec.isEmpty) codec = _str(q['codec']);
          if (bitrate == 0) bitrate = _intOf(q['bitrate']) ?? 0;
        }
      }
    }
    // 加密档缺 spade_a 视为不可用，触发降级链。
    if (encrypted && spadeA.isEmpty) {
      return const QishuiStreamInfo(url: '');
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

    final actualQualityRaw = _str(data['actual_quality']);
    return QishuiStreamInfo(
      url: url,
      urls: urls,
      actualQuality: actualQualityRaw.isEmpty ? 'medium' : actualQualityRaw,
      actualCode: actualCode,
      encrypted: encrypted,
      spadeA: spadeA,
      kid: kid,
      vtype: vtype,
      codec: codec,
      bitrate: bitrate,
      availableCodes: availableCodes,
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
