// 咪咕音乐 —— 核心网络层（搜索 / 取流 / 音质探针 / 歌词，v2.6.0）。
//
// 数据来源两处（均已实测有效，2026-11）：
//   - 搜索：洛雪 LX-X `musicSdk/mg/musicSearch.js` 的 jadeite v3 接口
//     （MD5 签名见 migu_crypto.dart）；
//   - 取流：附件「小熙」插件的官方 listen-url/v2.4 —— 拿 128k 基础直链，
//     再按档位替换 URL 路径派生 128k~master 七档。
//
// 关键设计：**音质靠探针探测**。派生 URL 未必真实存在（实测《雨爱》flac
// 以上派生 URL 返回 404），洛雪搜索的 audioFormats 只报 PQ/HQ/SQ/ZQ24
// 基础四档也不等于插件七档。因此 [probeQualityCodes] 对每档派生 URL 发
// Range 请求，200/206 = 有该档，404 = 无，结果作为 Song.qualityCodes
// 供 UI 收敛展示——这正是「按歌曲实际拥有的音质展示」的落地方式。
//
// 所有解析逻辑都是**纯函数**（parseSearchResponse / deriveUrl /
// codesFromStatuses），离线单测直接喂真实 JSON 片段，不依赖网络。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../models/models.dart';
import 'migu_crypto.dart';

/// 咪咕单首歌曲元信息。
class MiguSong {
  final String songId;
  final String copyrightId;
  final String albumId;
  final String name;
  final String singer;
  final String album;
  final int durationSeconds;
  final String mvId;
  final String cover;
  final String lrcUrl;
  final String mrcUrl;
  final String trcUrl;

  const MiguSong({
    required this.songId,
    required this.copyrightId,
    required this.albumId,
    required this.name,
    required this.singer,
    required this.album,
    this.durationSeconds = 0,
    this.mvId = '',
    this.cover = '',
    this.lrcUrl = '',
    this.mrcUrl = '',
    this.trcUrl = '',
  });
}

/// listen-url/v2.4 的取流结果（128k 基础直链 + 歌词链接）。
class MiguListenInfo {
  /// 128k 基础直链（URL 编码，带签名 query）。派生高档位时会去掉 query。
  final String url;
  final String lrcUrl;
  final String mrcUrl;
  final String trcUrl;

  const MiguListenInfo({
    required this.url,
    this.lrcUrl = '',
    this.mrcUrl = '',
    this.trcUrl = '',
  });
}

/// 封面相对路径 → 绝对 URL（咪咕返回 `/data/oss/...`，需拼 host 且转 https）。
String miguCoverUrl(String? raw) {
  final s = (raw ?? '').trim();
  if (s.isEmpty) return '';
  if (s.startsWith('http://') || s.startsWith('https://')) {
    return s.replaceFirst('http:', 'https:');
  }
  return 'https://d.musicapp.migu.cn$s';
}

class MiguApi {
  MiguApi._();

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
  ));

  /// v3 搜索的 searchSwitch（只搜歌曲）。
  static const String _searchSwitch =
      '{"song":1,"album":0,"singer":0,"tagSong":0,"mvSong":0,"bestShow":1,'
      '"songlist":0,"lyricSong":0}';

  /// 搜索结果缓存（key = songId），供歌词 / 音质补全复用元信息。
  static final Map<String, MiguSong> _songCache = <String, MiguSong>{};

  static MiguSong? cachedSong(String songId) => _songCache[songId];

  /// 搜索（分页）。返回解析后的 [MiguSong] 列表。
  static Future<List<MiguSong>> search(String keyword,
      {int page = 1, int num = 20}) async {
    final time = DateTime.now().millisecondsSinceEpoch;
    final sign = miguSign(keyword, time);
    final sw = Uri.encodeComponent(_searchSwitch);
    final url = 'https://jadeite.migu.cn/music_search/v3/search/searchAll'
        '?isCorrect=0&isCopyright=1&searchSwitch=$sw'
        '&pageSize=$num&text=${Uri.encodeComponent(keyword)}'
        '&pageNo=$page&sort=0&sid=USS';
    final resp = await _dio.get<String>(
      url,
      options: Options(headers: miguSearchHeaders(time, sign)),
    );
    final data = _decodeJson(resp.data);
    final list = parseSearchResponse(data);
    for (final s in list) {
      _songCache[s.songId] = s;
    }
    return list;
  }

  /// 解析 v3 搜索响应为 [MiguSong] 列表（纯函数）。
  ///
  /// `resultList` 是「数组的数组」（洛雪里 `item.forEach(data => ...)`），
  /// 这里全部摊平；按 songId 去重。`audioFormats` 刻意**不写入**任何音质
  /// 字段——音质由探针决定，见文件头说明。
  static List<MiguSong> parseSearchResponse(dynamic raw) {
    final json = raw is String ? _decodeJson(raw) : raw;
    if (json is! Map) return const [];
    final result = json['songResultData'];
    if (result is! Map) return const [];
    final groups = result['resultList'];
    if (groups is! List) return const [];

    final out = <MiguSong>[];
    final seen = <String>{};
    for (final group in groups) {
      if (group is! List) continue;
      for (final item in group) {
        if (item is! Map) continue;
        final song = _songFromMap(item);
        if (song == null || song.songId.isEmpty || seen.contains(song.songId)) {
          continue;
        }
        seen.add(song.songId);
        out.add(song);
      }
    }
    return out;
  }

  static MiguSong? _songFromMap(Map item) {
    final songId = _str(item['songId']);
    if (songId.isEmpty) return null;
    return MiguSong(
      songId: songId,
      copyrightId: _str(item['copyrightId']),
      albumId: _str(item['albumId']),
      name: _str(item['songName']).isNotEmpty
          ? _str(item['songName'])
          : _str(item['name']),
      singer: _singerNames(item['singerList']),
      album: _str(item['album']),
      durationSeconds: int.tryParse(_str(item['duration'])) ?? 0,
      mvId: _str(item['mvId']),
      cover: miguCoverUrl(_firstImage(item)),
      lrcUrl: _str(item['lrcUrl']),
      mrcUrl: _str(item['mrcUrl']),
      trcUrl: _str(item['trcUrl']),
    );
  }

  static String _firstImage(Map item) {
    for (final key in ['img3', 'img2', 'img1', 'albumImgs']) {
      final v = item[key];
      if (v is String && v.isNotEmpty) return v;
      if (v is List && v.isNotEmpty) {
        final first = v.first;
        if (first is String && first.isNotEmpty) return first;
        if (first is Map) {
          final img = _str(first['img']);
          if (img.isNotEmpty) return img;
        }
      }
    }
    return '';
  }

  static String _singerNames(dynamic list) {
    if (list is! List) return '';
    return list
        .whereType<Map>()
        .map((m) => _str(m['name']))
        .where((s) => s.isNotEmpty)
        .join('、');
  }

  /// 取 128k 基础直链（listen-url/v2.4）。
  static Future<MiguListenInfo> getListenUrl(String songId,
      {String albumId = '', String toneFlag = 'PQ'}) async {
    final q = <String>[
      'lowerQualityContentId=',
      'netType=00',
      'resourceType=2',
      'songId=${Uri.encodeComponent(songId)}',
      'toneFlag=$toneFlag',
    ];
    if (albumId.isNotEmpty) {
      q.add('albumId=${Uri.encodeComponent(albumId)}');
    }
    final url =
        'https://app.c.nf.migu.cn/MIGUM2.0/strategy/listen-url/v2.4?${q.join('&')}';
    final resp = await _dio.get<String>(
      url,
      options: Options(headers: miguListenHeaders()),
    );
    return parseListenResponse(resp.data);
  }

  /// 解析 listen-url 响应（纯函数，便于离线测试）。
  static MiguListenInfo parseListenResponse(dynamic raw) {
    final json = raw is String ? _decodeJson(raw) : raw;
    if (json is! Map) return const MiguListenInfo(url: '');
    if (_str(json['code']) != '000000') return const MiguListenInfo(url: '');
    final data = json['data'];
    if (data is! Map) return const MiguListenInfo(url: '');
    return MiguListenInfo(
      url: _str(data['url']),
      lrcUrl: _str(data['lrcUrl']),
      mrcUrl: _str(data['mrcUrl']),
      trcUrl: _str(data['trcUrl']),
    );
  }

  /// 从 128k 基础直链派生某档位的取流 URL（纯函数）。
  ///
  /// 严格按插件 JS 流程：`decodeURIComponent → split('?')[0] → 路径替换
  /// → 扩展名替换 → encodeURI`。中文目录必须先解码再替换，最后重新编码。
  /// [MiguQuality.k128] 直接返回去掉 query 的基础直链。
  static String deriveUrl(String baseUrl, MiguQuality q) {
    if (baseUrl.isEmpty) return '';
    String decoded;
    try {
      decoded = Uri.decodeFull(baseUrl);
    } catch (_) {
      decoded = baseUrl;
    }
    // 去掉签名 query（实测带 query 时替换路径会 404）。
    final noQuery = decoded.split('?').first;
    final qm = Uri.tryParse(noQuery);
    var dir = '';
    var file = '';
    if (qm != null && noQuery.contains('/')) {
      final idx = noQuery.lastIndexOf('/');
      dir = noQuery.substring(0, idx);
      file = noQuery.substring(idx + 1);
    } else {
      return noQuery;
    }

    // 替换倒数第一层目录：标清高清/MP3_128_16_Stero -> q.replacePath。
    // 基础直链末尾两段形如 `.../标清高清/MP3_128_16_Stero/xxx.mp3`。
    const baseTail = '标清高清/MP3_128_16_Stero';
    String newDir;
    if (dir.endsWith(baseTail)) {
      newDir = dir.substring(0, dir.length - baseTail.length) + q.replacePath;
    } else {
      // 兜底：只替换最后一段目录名。
      final lastSlash = dir.lastIndexOf('/');
      newDir = lastSlash >= 0
          ? '${dir.substring(0, lastSlash)}/${q.replacePath}'
          : q.replacePath;
    }

    // 替换扩展名（.mp3/.flac -> q.ext）。
    final newFile = file.replaceFirst(RegExp(r'\.[^./]+$'), q.ext);
    final full = '$newDir/$newFile';
    try {
      return Uri.encodeFull(full);
    } catch (_) {
      return full;
    }
  }

  /// 派生七档 URL（纯函数），返回 id → url。
  static Map<String, String> deriveAllUrls(String baseUrl) => {
        for (final q in MiguQuality.playbackOptions)
          q.id: deriveUrl(baseUrl, q),
      };

  /// 把派生 URL 的探测状态码映射为实际拥有的音质 id（纯函数）。
  ///
  /// - 200 / 206：该档可用；
  /// - 404：该档不存在；
  /// - -1（网络错误 / 超时）：乐观保留，交播放降级链兜底，避免误隐藏。
  static Set<String> codesFromStatuses(Map<String, int> statuses) {
    final codes = <String>{};
    statuses.forEach((id, status) {
      if (status == 200 || status == 206 || status < 0) {
        codes.add(id);
      }
    });
    return codes;
  }

  /// 探针缓存（key = songId）与在途去重。
  static final Map<String, Set<String>> _probeCache = <String, Set<String>>{};
  static final Map<String, Future<Set<String>>> _probeInflight =
      <String, Future<Set<String>>>{};

  /// 探测一首歌实际拥有的音质档位（懒探测 + 缓存 + 并发上限）。
  ///
  /// 仅在 `MusicApi.ensureQualityCodes`（打开音质弹层 / 首次播放）调用，
  /// 搜索阶段不触发，避免 N 首 × 7 档的请求风暴。
  static Future<Set<String>> probeQualityCodes(String songId,
      {String albumId = ''}) async {
    final cached = _probeCache[songId];
    if (cached != null) return cached;
    final inflight = _probeInflight[songId];
    if (inflight != null) return inflight;

    final future = _doProbe(songId, albumId: albumId);
    _probeInflight[songId] = future;
    try {
      final codes = await future;
      _probeCache[songId] = codes;
      return codes;
    } finally {
      _probeInflight.remove(songId);
    }
  }

  static Future<Set<String>> _doProbe(String songId,
      {String albumId = ''}) async {
    try {
      final listen = await getListenUrl(songId, albumId: albumId);
      if (listen.url.isEmpty) return const <String>{};
      final urls = deriveAllUrls(listen.url);
      final statuses = <String, int>{};

      // 并发上限 3（分组 Future.wait），每档超时 5s。
      final entries = urls.entries.toList();
      const groupSize = 3;
      for (var i = 0; i < entries.length; i += groupSize) {
        final batch = entries.skip(i).take(groupSize).toList();
        await Future.wait(batch.map((e) async {
          statuses[e.key] = await _probeOne(e.value);
        }));
      }
      return codesFromStatuses(statuses);
    } catch (e) {
      AppLog.w('MiguApi', '音质探针失败 $songId: $e');
      return const <String>{};
    }
  }

  static Future<int> _probeOne(String url) async {
    if (url.isEmpty) return -1;
    try {
      final resp = await _dio.head<String>(
        url,
        options: Options(
          headers: miguProbeHeaders(),
          receiveTimeout: const Duration(seconds: 5),
          connectTimeout: const Duration(seconds: 5),
          validateStatus: (_) => true,
        ),
      );
      return resp.statusCode ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// 取歌词（优先搜索/取流响应里的 lrcUrl 纯文本 LRC）。
  ///
  /// MRC 逐字歌词需额外解密（本期不做），有 lrcUrl 时直接返回纯 LRC。
  static Future<String> lyric(MiguSong song) async {
    var url = song.lrcUrl;
    if (url.isEmpty) {
      // 用 songId 现取一次基础直链拿 lrcUrl。
      try {
        final listen = await getListenUrl(song.songId, albumId: song.albumId);
        url = listen.lrcUrl;
      } catch (_) {
        return '';
      }
    }
    if (url.isEmpty) return '';
    try {
      final resp = await _dio.get<String>(
        url,
        options: Options(headers: miguLyricHeaders()),
      );
      return resp.data ?? '';
    } catch (e) {
      AppLog.w('MiguApi', '歌词获取失败 ${song.songId}: $e');
      return '';
    }
  }

  static Map _decodeJson(dynamic text) {
    if (text is Map) return text;
    if (text is String && text.isNotEmpty) {
      try {
        return jsonDecode(text) as Map;
      } catch (_) {
        return const {};
      }
    }
    return const {};
  }

  static String _str(dynamic v) => v == null ? '' : v.toString();
}
