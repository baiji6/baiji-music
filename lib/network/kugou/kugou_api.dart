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
import 'kugou_auth.dart';
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
  final String superHash; // SuperFileHash（超品 / 蝰蛇 HiFi）
  final String multiTrackHash; // trans_param.hash_multitrack（多轨 / 空间音频）
  final String qualityBits; // trans_param.qualitymap.bits
  final bool has360ra; // 服务端给出的 360RA 标记
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
    this.superHash = '',
    this.multiTrackHash = '',
    this.qualityBits = '',
    this.has360ra = false,
    required this.name,
    required this.singer,
    required this.album,
    required this.pic,
    required this.durationSeconds,
    required this.qualities,
  });

  /// 该音质档对应的 hash；没有（接口未返回）返回空串。
  ///
  /// 本地升频档用 [KugouQuality.fetchHashKey] 覆盖，确保取的是 320k
  /// 源文件而不是一个服务端并不存在的「母带 hash」。
  String hashFor(KugouQuality q) {
    final key = q.fetchHashKey.isNotEmpty ? q.fetchHashKey : q.hashKey;
    switch (key) {
      case 'FileHash':
        return hash;
      case 'HQFileHash':
        return hqHash;
      case 'SQFileHash':
        return sqHash;
      case 'ResFileHash':
        return resHash;
      case 'SuperFileHash':
        return superHash;
      case 'HashMultiTrack':
        return multiTrackHash.isNotEmpty ? multiTrackHash : hash;
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
      final song = parseSong(m);
      if (song != null) {
        _songCache[song.albumAudioId] = song;
        out.add(song);
      }
    }
    AppLog.i('KugouApi', '搜索「$keyword」命中 ${out.length} 首');
    return out;
  }

  /// 从搜索/详情接口的单个条目解析 [KugouSong]。
  ///
  /// 公开是为了让离线测试能直接喂假响应，锁定「音质只展示歌曲实际有的」
  /// 的推导逻辑；生产链路仍是 [search] 调用它。
  static KugouSong? parseSong(Map<String, dynamic> m) {
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
    final superHash = _str(m['SuperFileHash']) ?? '';
    final superExt = _str(m['SuperExtName']) ?? '';

    // trans_param 两种形态都见过：JSON 字符串（搜索接口）或直接 Map。
    Map<String, dynamic> tp = const <String, dynamic>{};
    final tpRaw = m['trans_param'];
    if (tpRaw is Map) {
      tp = Map<String, dynamic>.from(tpRaw);
    } else if (tpRaw is String && tpRaw.isNotEmpty) {
      try {
        tp = Map<String, dynamic>.from(jsonDecode(tpRaw) as Map);
      } catch (_) {}
    }
    final qm = tp['qualitymap'];
    final bits = qm is Map ? (_str(qm['bits']) ?? '') : '';
    final multiTrack = _str(tp['hash_multitrack']) ?? '';

    // 360RA（MPEG-H / MHA1）：只在服务端给出明确标记时展示，绝不常驻。
    // 已知显式信号：SuperExtName 含 mha、trans_param 里出现 360/mha 键。
    // qualitymap.bits 的完整位语义由官方客户端解析，未可靠破译前不猜位，
    // 宁可少显示也不把「实际没有」的档位塞进列表。
    final has360ra = superExt.toLowerCase().contains('mha') ||
        tp.keys.any((k) {
          final s = k.toLowerCase();
          return s.contains('360') || s.contains('mha');
        });

    // 音质按「这首歌实际有的」推导（v2.5.2）：
    // - 基础四档：严格看各自 hash 是否存在；
    // - 蝰蛇母带（本地升频）：只要有 320k / FLAC 源文件就能本地重建；
    // - 蝰蛇超清（AI升频）：有 FLAC 基础文件；
    // - 蝰蛇全景声 / 杜比全景声：需要 hash_multitrack（真的有多轨内容）；
    // - 360RA：需要服务端明确的 MHA1 / 360 标记。
    final qualities = <KugouQuality>[
      if (hqHash.isNotEmpty || sqHash.isNotEmpty) KugouQuality.viperTape,
      if (multiTrack.isNotEmpty) KugouQuality.viperAtmos,
      if (sqHash.isNotEmpty) KugouQuality.viperClear,
      if (multiTrack.isNotEmpty) KugouQuality.dolby,
      if (has360ra) KugouQuality.ra360,
      if (resHash.isNotEmpty) KugouQuality.hires,
      if (sqHash.isNotEmpty) KugouQuality.flac,
      if (hqHash.isNotEmpty) KugouQuality.k320,
      if (hash.isNotEmpty) KugouQuality.k128,
    ];

    return KugouSong(
      albumAudioId: albumAudioId,
      albumId: albumId,
      hash: hash,
      hqHash: hqHash,
      sqHash: sqHash,
      resHash: resHash,
      superHash: superHash,
      multiTrackHash: multiTrack,
      qualityBits: bits,
      has360ra: has360ra,
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
    // 降级链用播放档位全集（含本地升频档与服务端高规格档）。
    // from 不在全集里时（旧持久化值等）兜底成「先试它自己，再走全集」，
    // 避免 indexOf 返回 -1 让 skip(-1) 直接抛 RangeError。
    final idx = KugouQuality.playbackOptions.indexOf(from);
    final chain = idx < 0
        ? <KugouQuality>[from, ...KugouQuality.playbackOptions]
        : KugouQuality.playbackOptions.skip(idx).toList();
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
  ///
  /// v2.5.1：登录凭据（userid/token）+ 持久化设备三件套（mid/dfid/dev）
  /// 随请求注入——HotDownloader `link.rs` 的 `get_download_link_with_
  /// credentials` 就是这么解锁 flac / Hi-Res 的。未登录时 userid=0、
  /// token 缺省，服务端按匿名处理（通常只能取 128k）。
  /// 注意签名用的是 **gateway** salt（域名是 gateway.kugou.com），
  /// 不是登录接口的 login salt；`key` 里也要带上真实 userid。
  static Future<String> _fetchUrl(
    String hash,
    String albumId,
    String albumAudioId,
    KugouQuality quality,
  ) async {
    final auth = await KugouAuth.requestParams();
    final mid = auth['mid'] ?? kugouDeviceMid();
    final userid = auth['userid'] ?? '0';
    final params = <String, String>{
      'hash': hash,
      'album_id': albumId,
      'album_audio_id': albumAudioId,
      // 本地升频档实际取的是 320k 源文件（服务端并无「母带文件」，
      // 192kHz/24bit 由 App 本地重建），所以取链参数要覆盖成 320。
      'quality': quality.fetchQualityTag.isNotEmpty
          ? quality.fetchQualityTag
          : quality.qualityTag,
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
      'uuid': '-',
      'appid': '1005',
      'clienttime': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      // 设备 + 登录态：mid/dfid/dev 覆盖默认值，userid/token 解锁高音质。
      ...auth,
    };
    params['key'] = kugouUrlKey(hash, mid, userid: userid);
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
