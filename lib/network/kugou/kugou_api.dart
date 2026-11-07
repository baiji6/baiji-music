// 酷狗音乐 —— 网络接口层（搜索 / 歌曲信息 / 播放链接）。
//
// 抄 HotDownloader（gateway.kugou.com，appid=1005）的酷狗实现：
//   搜索     GET gateway.kugou.com/v2/search/song   （x-router=complexsearch.kugou.com）
//   播放链接 GET gateway.kugou.com/v5/url           （x-router=trackercdn.kugou.com）
// 签名见 [kugou_cipher.dart]。酷狗同一首歌的多个音质是不同文件，靠各自的
// hash（FileHash / HQFileHash / SQFileHash / ResFileHash）区分，取链接口按
// hash 直接定位。匿名即可取 128k，登录可解锁更高音质（本版先走匿名）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../lyrics/lyric_model.dart';
import '../../models/models.dart';
import 'kugou_cipher.dart';
import 'kugou_lyric.dart';

/// 酷狗封面归一化（对齐 Lyrico kugou 插件 `normalizeImage`）。
String kugouCoverUrl(String? raw) {
  final s = (raw ?? '').trim();
  if (s.isEmpty) return '';
  return s.replaceAll('{size}', '480').replaceFirst('http:', 'https:');
}

/// 酷狗单首歌曲的元信息 + 可用音质列表。
class KugouSong {
  final String albumAudioId; // MixSongID
  final String albumId;
  final String hash; // 128k
  final String hqHash; // 320k
  final String sqHash; // flac
  final String resHash; // hires
  final String name;
  final String singer;
  final String album;
  final String pic;
  final int durationSeconds;
  final List<KugouQuality> qualities;

  const KugouSong({
    required this.albumAudioId,
    required this.albumId,
    required this.hash,
    required this.hqHash,
    required this.sqHash,
    required this.resHash,
    required this.name,
    required this.singer,
    required this.album,
    required this.pic,
    required this.durationSeconds,
    required this.qualities,
  });

  /// 该音质档对应的 hash；没有（接口未返回）返回空串。
  String hashFor(KugouQuality q) {
    switch (q.hashKey) {
      case 'FileHash':
        return hash;
      case 'HQFileHash':
        return hqHash;
      case 'SQFileHash':
        return sqHash;
      case 'ResFileHash':
        return resHash;
      default:
        return '';
    }
  }
}

/// 酷狗播放链接结果。
class KugouPlayLink {
  final String url;
  final KugouQuality quality;

  const KugouPlayLink({required this.url, required this.quality});

  String get ext => quality.ext;
}

/// 酷狗接口客户端。
class KugouApi {
  KugouApi._();

  static const String searchUrl = 'https://gateway.kugou.com/v2/search/song';
  static const String urlV5 = 'https://gateway.kugou.com/v5/url';

  static const String ua =
      'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
  ));

  /// 按 MixSongID 缓存歌曲（含各音质 hash），避免播放时反复搜索。
  static final Map<String, KugouSong> _songCache = <String, KugouSong>{};

  static Future<Map<String, dynamic>> _getJson(
    String url, {
    Map<String, String>? headers,
  }) async {
    final resp = await _dio.get<String>(url,
        options: Options(headers: headers ?? const {'User-Agent': ua}));
    final body = resp.data ?? '';
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw Exception('酷狗接口返回的不是 JSON 对象：${body.length > 120 ? body.substring(0, 120) : body}');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// 搜索歌曲。返回 [KugouSong] 列表（已写入缓存）。
  static Future<List<KugouSong>> search(
    String keyword, {
    int page = 1,
    int num = 20,
  }) async {
    final mid = kugouDeviceMid();
    final params = <String, String>{
      'keyword': keyword,
      'page': '$page',
      'pagesize': '$num',
      'platform': 'AndroidFilter',
      'iscorrection': '1',
      'privilegefilter': '0',
      'area_code': '1',
      'dopicfull': '1',
      'albumhide': '0',
      'nocollect': '0',
      ...kugouGatewayCommon(mid: mid),
    };
    params['signature'] = kugouSign(params, kugouGatewaySalt);
    final url = '$searchUrl?${kugouBuildQuery(params)}';
    final headers = {
      'User-Agent': ua,
      'x-router': 'complexsearch.kugou.com',
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
      'kg-tid': '255',
    };
    final data = await _getJson(url, headers: headers);
    final list = (data['data'] is Map
            ? (data['data'] as Map)['lists']
            : null) ??
        const [];
    if (list is! List) return const [];
    final out = <KugouSong>[];
    for (final item in list) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final song = _parseSong(m);
      if (song != null) {
        _songCache[song.albumAudioId] = song;
        out.add(song);
      }
    }
    AppLog.i('KugouApi', '搜索「$keyword」命中 ${out.length} 首');
    return out;
  }

  /// 从搜索/详情接口的单个条目解析 [KugouSong]。
  static KugouSong? _parseSong(Map<String, dynamic> m) {
    final albumAudioId = _str(m['MixSongID']) ?? _str(m['album_audio_id']) ?? '';
    if (albumAudioId.isEmpty) return null;
    final name = _str(m['SongName']) ?? _str(m['audio_name']) ?? '';
    if (name.isEmpty) return null;
    final singer = _str(m['SingerName']) ?? _str(m['author_name']) ?? '';
    final album = _str(m['AlbumName']) ?? _str(m['album_name']) ?? '';
    final albumId = _str(m['AlbumID']) ?? _str(m['album_id']) ?? '';
    final hash = _str(m['FileHash']) ?? _str(m['hash']) ?? '';
    final hqHash = _str(m['HQFileHash']) ?? '';
    final sqHash = _str(m['SQFileHash']) ?? '';
    final resHash = _str(m['ResFileHash']) ?? '';
    final pic = kugouCoverUrl(_str(m['Image']) ?? _str(m['sizable_cover']) ??
        _str(m['img']) ?? '');
    final duration = int.tryParse(_str(m['Duration']) ?? '0') ?? 0;

    // 音质由 hash 存在性推导（与 [KugouQuality] 顺序一致）。
    final qualities = <KugouQuality>[];
    if (resHash.isNotEmpty) qualities.add(KugouQuality.hires);
    if (sqHash.isNotEmpty) qualities.add(KugouQuality.flac);
    if (hqHash.isNotEmpty) qualities.add(KugouQuality.k320);
    if (hash.isNotEmpty) qualities.add(KugouQuality.k128);

    return KugouSong(
      albumAudioId: albumAudioId,
      albumId: albumId,
      hash: hash,
      hqHash: hqHash,
      sqHash: sqHash,
      resHash: resHash,
      name: name,
      singer: singer,
      album: album,
      pic: pic,
      durationSeconds: duration,
      qualities: qualities,
    );
  }

  /// 按 MixSongID 取缓存；没有则按「歌名 + 歌手」再搜一次补回。
  static Future<KugouSong?> _resolveSong(String mixSongId, String name,
      String singer) async {
    final cached = _songCache[mixSongId];
    if (cached != null) return cached;
    if (name.isEmpty) return null;
    final list = await search('$name $singer'.trim(), num: 1);
    for (final s in list) {
      if (s.name == name ||
          s.albumAudioId == mixSongId) {
        _songCache[mixSongId] = s;
        return s;
      }
    }
    return list.isNotEmpty ? list.first : null;
  }

  // ==================== 播放链接 ====================

  /// 取播放链接（按 [quality] 定位对应 hash，失败沿降级链下探）。
  static Future<KugouPlayLink> playUrlWithFallback(
    String mixSongId,
    String name,
    String singer,
    KugouQuality from,
  ) async {
    final song = await _resolveSong(mixSongId, name, singer);
    if (song == null) throw Exception('酷狗未找到歌曲: $name');
    Exception? last;
    final chain = KugouQuality.downloadOptions
        .skip(KugouQuality.downloadOptions.indexOf(from))
        .toList();
    if (chain.isEmpty) chain.add(from);
    for (final q in chain) {
      final h = song.hashFor(q);
      if (h.isEmpty) continue;
      try {
        final url = await _fetchUrl(h, song.albumId, song.albumAudioId, q);
        if (url.isNotEmpty) {
          return KugouPlayLink(url: url, quality: q);
        }
      } catch (e) {
        last = e is Exception ? e : Exception('$e');
      }
    }
    throw last ?? Exception('酷狗无可用音质: $name');
  }

  /// 单档取链：gateway.kugou.com/v5/url。
  static Future<String> _fetchUrl(
    String hash,
    String albumId,
    String albumAudioId,
    KugouQuality quality,
  ) async {
    final mid = kugouDeviceMid();
    final params = <String, String>{
      'hash': hash,
      'album_id': albumId,
      'album_audio_id': albumAudioId,
      'quality': quality.qualityTag,
      'area_code': '1',
      'ssa_flag': 'is_fromtrack',
      'version': '11430',
      'page_id': '151369488',
      'behavior': 'play',
      'pid': '2',
      'cmd': '26',
      'pidversion': '3001',
      'IsFreePart': '0',
      'ppage_id': '463467626,350369493,788954147',
      'cdnBackup': '1',
      'module': '',
      'clientver': '11430',
      'dfid': '-',
      'uuid': '-',
      'appid': '1005',
      'userid': '0',
      'mid': mid,
      'clienttime': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    };
    params['key'] = kugouUrlKey(hash, mid);
    params['signature'] = kugouSign(params, kugouGatewaySalt);
    final url = '$urlV5?${kugouBuildQuery(params)}';
    final headers = {
      'User-Agent': ua,
      'x-router': 'trackercdn.kugou.com',
      'kg-tid': '255',
    };
    final data = await _getJson(url, headers: headers);
    final free = data['is_free_part'] ?? data['free_part'];
    if (free == 1) return ''; // 试听片段，不可用
    final urlField = data['url'];
    if (urlField is String && urlField.isNotEmpty) return urlField;
    if (urlField is List && urlField.isNotEmpty) {
      final first = urlField.first;
      if (first is String && first.isNotEmpty) return first;
    }
    return '';
  }

  // ==================== 歌词 ====================

  /// 取歌词（KRC 逐字解密 → [Lyrics]）。
  static Future<Lyrics> lyric(String mixSongId, String name, String singer) async {
    return getLyrics(mixSongId, name, singer);
  }

  static String? _str(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }
}
