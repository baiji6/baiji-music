// 酷我音乐 —— 网络接口层（搜索 / 歌曲信息 / 播放链接 / 歌词）
//
// 逆向自 bai music_4.0.apk 的 KuwoApi / nmobi.kuwo.cn 公开接口，
// 无需签名、无需登录。
//
//   搜索     GET http://www.kuwo.cn/search/searchMusicBykeyWord
//   歌曲信息 GET http://musicpay.kuwo.cn/music.pay?op=query&action=play&ids=<rid>
//   播放链接 GET http://nmobi.kuwo.cn/mobi.s?type=convert_url_with_sign&rid=&br=
//   歌词     GET http://newlyric.kuwo.cn/newlyric.lrc?<XOR+Base64 参数>
//
// 播放链接有两种形态：
//   - 明文（mp4 杜比等，ekey 为空）→ 直链可播；
//   - QMC 加密（flac/mflac/mgg/mp3/ogg/aac）→ 需本地中继边下边解，
//     见 [qmc_stream.dart] 的 [QmcRelayServer]。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';

import '../../core/app_logger.dart';
import '../../models/models.dart';
import 'kuwo_link.dart';
import 'kuwo_lyric.dart';
import 'qmc_stream.dart';

/// 酷我单首歌曲的元信息 + 可用音质列表。
class KuwoSong {
  final String rid;
  final String name;
  final String artist;
  final String album;
  final String pic;
  final int durationSeconds;
  final List<KuwoQuality> qualities;

  const KuwoSong({
    required this.rid,
    required this.name,
    required this.artist,
    required this.album,
    required this.pic,
    required this.durationSeconds,
    required this.qualities,
  });
}

/// 酷我播放链接结果。
class KuwoPlayLink {
  final String url;

  /// 服务端原始 bitrate（kbps）。
  final int bitrate;

  /// 服务端实际格式（flac / mflac / mp3 / ogg / aac / mp4）。
  final String format;

  /// 是否 QMC 加密。
  final bool encrypted;

  /// QMC ekey（明文时为空）。
  final String ekey;

  /// 实际生效的音质 id（如 `flac` / `128k`）。
  final String qualityId;

  /// 真正可喂给播放器的地址（加密时是本地中继地址）。
  final String playUrl;

  const KuwoPlayLink({
    required this.url,
    required this.bitrate,
    required this.format,
    required this.encrypted,
    required this.ekey,
    required this.qualityId,
    required this.playUrl,
  });

  String get ext {
    switch (format) {
      case 'mp3':
      case 'mmp3':
        return '.mp3';
      case 'ogg':
      case 'mgg':
      case 'mggl':
        return '.ogg';
      case 'aac':
        return '.aac';
      case 'mp4':
        return '.mp4';
      default:
        return '.flac';
    }
  }
}

/// 酷我接口客户端。
class KuwoApi {
  KuwoApi._();

  static const String searchUrl = 'http://www.kuwo.cn/search/searchMusicBykeyWord';
  static const String songInfoUrl = 'http://musicpay.kuwo.cn/music.pay';
  static const String linkUrl = 'http://nmobi.kuwo.cn/mobi.s';

  static const String browserUa = 'Mozilla/5.0 (Linux; Android 15; V2453A '
      'Build/AP3A.240905.015.A2_V000L1) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/141.0.7390.5 Mobile Safari/537.36';

  static const Map<String, String> browserHeaders = {
    'User-Agent': browserUa,
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
  };

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.bytes,
  ));

  /// 本地 QMC 中继（仅加密音轨才需要）。
  static QmcRelayServer? _relay;

  static Future<QmcRelayServer> _ensureRelay() async {
    final r = _relay;
    if (r != null) return r;
    final server = QmcRelayServer();
    await server.start();
    _relay = server;
    return server;
  }

  /// 关闭本地中继（App 退出时调用）。
  static Future<void> disposeRelay() async {
    await _relay?.stop();
    _relay = null;
  }

  /// 请求 JSON 接口。
  ///
  /// **不能直接用 `ResponseType.json`**：酷我搜索接口
  /// (`www.kuwo.cn/search/searchMusicBykeyWord`) 的响应头是
  /// `Content-Type: text/plain`，dio 会因此把响应体原样当字符串返回，
  /// 后续 `as Map<String, dynamic>` 直接抛
  /// `type 'String' is not a subtype of type 'Map<String, dynamic>'`。
  /// 所以这里统一按 bytes 收，自己解码（utf8 优先，失败退 gbk）再 jsonDecode。
  static Future<Map<String, dynamic>> _getJson(
    String url, {
    Map<String, String>? headers,
  }) async {
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: headers ?? browserHeaders,
      ),
    );
    final body = _decodeBody(resp.data ?? const []);
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw Exception('酷我接口返回的不是 JSON 对象：${body.substring(0, body.length > 120 ? 120 : body.length)}');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// 响应体解码：优先 UTF-8，失败退 GBK（酷我部分接口仍是 GBK）。
  static String _decodeBody(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return gbk.decode(bytes, allowMalformed: true);
    }
  }

  // ==================== 搜索 ====================

  /// 搜索歌曲。返回 [KuwoSong] 列表。
  static Future<List<KuwoSong>> search(
    String keyword, {
    int pn = 0,
    int rn = 30,
  }) async {
    final q = Uri.encodeComponent(keyword);
    final url = '$searchUrl?all=$q&pn=$pn&rn=$rn'
        '&vipver=1&ft=music&encoding=utf8&issubtitle=1&mobi=1';
    final data = await _getJson(url);
    final list = (data['abslist'] ?? const []) as List<dynamic>;
    final out = <KuwoSong>[];
    for (final item in list) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final rid = (m['DC_TARGETID'] ?? '').toString();
      if (rid.isEmpty) continue;
      final pic = (m['web_albumpic_short'] ?? '').toString();
      out.add(KuwoSong(
        rid: rid,
        name: (m['SONGNAME'] ?? '').toString(),
        artist: (m['ARTIST'] ?? '').toString(),
        album: (m['ALBUM'] ?? '').toString(),
        pic: pic.isNotEmpty ? 'http://img2.kuwo.cn/star/albumcover/$pic' : '',
        durationSeconds:
            int.tryParse((m['DURATION'] ?? '0').toString()) ?? 0,
        qualities: _qualitiesOf(m['N_MINFO']?.toString()),
      ));
    }
    AppLog.i('KuwoApi', '搜索「$keyword」命中 ${out.length} 首');
    return out;
  }

  /// 按 rid 取歌曲详情（含更完整的音质列表）。
  static Future<KuwoSong?> songInfo(String rid) async {
    final data = await _getJson('$songInfoUrl?op=query&action=play&ids=$rid');
    final list = (data['songs'] ?? const []) as List<dynamic>;
    if (list.isEmpty) return null;
    final m = Map<String, dynamic>.from(list.first as Map);
    return KuwoSong(
      rid: (m['id'] ?? rid).toString(),
      name: (m['name'] ?? '').toString(),
      artist: (m['artist'] ?? '').toString(),
      album: (m['album'] ?? '').toString(),
      pic: (m['albumPic'] ?? '').toString(),
      durationSeconds:
          int.tryParse((m['duration'] ?? '0').toString()) ?? 0,
      qualities: _qualitiesOf(m['N_MINFO']?.toString()),
    );
  }

  // ==================== 播放链接 ====================

  /// 取播放链接。加密音轨自动走本地中继解密。
  ///
  /// [quality] 为空时自动从高到低尝试可用音质。
  static Future<KuwoPlayLink> playUrl(
    String rid, {
    KuwoQuality? quality,
  }) async {
    final Map<String, dynamic> link;
    if (quality != null) {
      link = await KuwoLink.getPlayUrl(rid, br: quality.br);
    } else {
      link = await KuwoLink.getBestUrl(rid);
    }
    final encrypted = (link['encrypted'] as bool?) ?? false;
    final url = (link['url'] ?? '').toString();
    final ekey = (link['ekey'] ?? '').toString();
    final format = (link['format'] ?? '').toString();

    String playUrl = url;
    if (encrypted && url.isNotEmpty) {
      final relay = await _ensureRelay();
      playUrl = relay.urlFor(url, ekey, ext: _extFor(format));
    }

    return KuwoPlayLink(
      url: url,
      bitrate: (link['bitrate'] as num?)?.toInt() ?? 0,
      format: format,
      encrypted: encrypted,
      ekey: ekey,
      qualityId: _qualityIdOfBitrate(
        (link['bitrate'] as num?)?.toInt() ?? 0,
        format,
      ),
      playUrl: playUrl,
    );
  }

  /// 依次尝试从 [from] 起向下降级，返回第一个成功的链接。
  ///
  /// 酷我未登录时无损/母带档普遍不可用，必须有降级链，
  /// 否则搜索结果能点播放却直接失败。
  static Future<KuwoPlayLink> playUrlWithFallback(
    String rid,
    KuwoQuality from,
  ) async {
    final chain = KuwoLink.downgradeChain(from.id);
    Exception? last;
    for (final br in chain) {
      try {
        final link = await playUrl(rid, quality: _qualityOfBr(br));
        if (link.playUrl.isNotEmpty) return link;
      } catch (e) {
        last = e is Exception ? e : Exception('$e');
      }
    }
    throw last ?? Exception('酷我无可用音质: rid=$rid');
  }

  /// br 串 → 音质对象（找不到时退化为同 bitrate 的常见档）。
  static KuwoQuality? _qualityOfBr(String br) {
    for (final q in KuwoQuality.downloadOptions) {
      if (q.br == br) return q;
    }
    // 高阶特殊档（母带 / 全景声）不在 UI 选项里，命中时用最接近的展示档。
    final rule = KuwoLink.qualityRules.firstWhere(
      (r) => KuwoLink.brOf(r) == br,
      orElse: () => const [],
    );
    if (rule.isEmpty) return null;
    final id = rule[2] as String;
    return KuwoQuality.fromId(id) ?? _qualityByBitrate(int.tryParse(rule[0] as String) ?? 0);
  }

  static KuwoQuality? _qualityByBitrate(int bitrate) {
    KuwoQuality? best;
    for (final q in KuwoQuality.downloadOptions) {
      if (q.bitrate == bitrate) return q;
      if (best == null || q.bitrate > best.bitrate) best = q;
    }
    return best;
  }

  /// 由服务端返回的 bitrate + format 反查音质 id。
  static String _qualityIdOfBitrate(int bitrate, String format) {
    for (final rule in KuwoLink.qualityRules) {
      if (rule[0] == '$bitrate' &&
          (rule[1] == format ||
              (format == 'mflac' && rule[1] == 'mflac'))) {
        return rule[2] as String;
      }
    }
    return KuwoQuality.mp3_128.id;
  }

  static String _extFor(String format) {
    switch (format) {
      case 'mgg':
      case 'mggl':
      case 'ogg':
        return 'ogg';
      case 'mp3':
      case 'mmp3':
        return 'mp3';
      case 'aac':
        return 'aac';
      case 'mp4':
        return 'mp4';
      default:
        return 'flac';
    }
  }

  // ==================== 歌词 ====================

  /// 取歌词（返回普通 LRC 文本，酷我逐字标记会被剥离）。
  static Future<String> lyric(String rid) async {
    final r = await KuwoLyric.getLyric(rid);
    final lrc = (r['lrc'] ?? '') as String;
    return lrc;
  }

  // ==================== 工具 ====================

  /// 解析 `N_MINFO` 里的音质串（"level:ff,bitrate:2000,format:flac,size:52.83Mb;…"）。
  static List<KuwoQuality> _qualitiesOf(String? nmInfo) {
    final out = <KuwoQuality>[];
    final seen = <String>{};
    for (final entry in (nmInfo ?? '').split(';')) {
      final kv = <String, String>{};
      for (final part in entry.split(',')) {
        final i = part.indexOf(':');
        if (i >= 0) kv[part.substring(0, i).trim()] = part.substring(i + 1).trim();
      }
      final format = kv['format'];
      final bitrate = kv['bitrate'];
      if (format == null || bitrate == null) continue;
      final br = int.tryParse(bitrate);
      if (br == null) continue;
      for (final rule in KuwoLink.qualityRules) {
        if (rule[0] == bitrate && rule[1] == format) {
          final id = rule[2] as String;
          if (seen.add(id)) {
            final q = KuwoQuality.fromId(id);
            if (q != null) out.add(q);
          }
          break;
        }
      }
    }
    out.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return out;
  }
}

/// GBK/GB18030 容错解码（QQ 酷我接口编码在 utf-8 / gb2312 间浮动）。
String decodeMaybeGbk(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return gbk.decode(bytes, allowMalformed: true);
  }
}

/// 字节流 → Uint8List（保留类型信息，避免 Uint8List.view 的偏移问题）。
Uint8List toBytes(List<int> raw) => Uint8List.fromList(raw);
