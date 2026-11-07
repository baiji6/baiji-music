// 酷狗 MV 播放源 —— m.kugou.com/app/i/mv.php。
//
// 逆向自用户上传的「酷狗（ikun）.js」插件的 `getMvSource`（v2.5.4）。
//
// 接口：`GET https://m.kugou.com/app/i/mv.php?cmd=100&ext=mp4&hash=<MvHash>`
//   - `cmd=100` 是取流；其它 cmd 返回 `errcode:2 Bad cmd`。
//   - `hash` 是歌曲的 `MvHash`（32 位 hex），来自搜索响应的 `MvHash` 字段。
//   - headers 要带 `Referer: https://www.kugou.com/` 与桌面 UA。
//
// 响应 `mvdata` 含 5 个画质档（脚本的 `KUGOU_MV_LEVELS`）：
//   le→480p、sd→720p、hd→1080p、sq→1080p、rq→4k
// 每档含 `downurl` / `backupdownurl` / `filesize` / `width` / `height` /
// `bitrate` / `timelength` / `codec`。
//
// **CDN 是 http 的**：脚本注释写明「Kugou's fsmvpc CDN currently serves the
// signed object over HTTP. The HTTPS endpoint has a certificate for a
// different host and is rejected by Chromium/Electron, while the HTTP URL
// supports ranges and CORS.」——所以这里**保留 http**（本地代理转发时
// 不受影响），只在必要时尝试 https。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/app_logger.dart';
import 'mv_source.dart';

/// 酷狗 MV 画质档定义（对应脚本 `KUGOU_MV_LEVELS`）。
class KugouMvLevel {
  const KugouMvLevel(this.key, this.quality, this.height);

  /// `mvdata` 里的字段名（`le` / `sd` / `hd` / `sq` / `rq`）。
  final String key;

  /// 展示用画质名（`480p` / `4k`）。
  final String quality;

  /// 目标高度（px）。
  final int height;
}

/// 酷狗 MV 的一个可用清晰度流。
class KugouMvStream {
  const KugouMvStream({
    required this.level,
    required this.url,
    this.backupUrls = const [],
    this.size = 0,
    this.width = 0,
    this.height = 0,
    this.bitrate = 0,
    this.codec = '',
    this.durationMs = 0,
  });

  final KugouMvLevel level;
  final String url;
  final List<String> backupUrls;
  final int size;
  final int width;
  final int height;
  final int bitrate;
  final String codec;

  /// 时长（毫秒；服务端 `timelength` 字段）。
  final int durationMs;
}

/// 酷狗 MV 接口客户端。
class KugouMvApi {
  KugouMvApi._();

  /// 取流端点。
  static const String mvUrl = 'https://m.kugou.com/app/i/mv.php';

  /// 画质档全集（顺序与脚本一致）。
  static const List<KugouMvLevel> levels = <KugouMvLevel>[
    KugouMvLevel('le', '480p', 480),
    KugouMvLevel('sd', '720p', 720),
    KugouMvLevel('hd', '1080p', 1080),
    KugouMvLevel('sq', '1080p', 1080),
    KugouMvLevel('rq', '4k', 2160),
  ];

  /// 桌面 UA（脚本同款；酷狗 CDN 校验 UA）。
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 Edg/107.0.1418.24';

  /// MV CDN 防盗链头（脚本同款）。
  static const Map<String, String> cdnHeaders = <String, String>{
    'Referer': 'https://www.kugou.com/',
    'User-Agent': userAgent,
  };

  /// 拉 MV 播放源。
  ///
  /// [mvHash] 是歌曲的 `MvHash`（32 位 hex）。非法 / 缺失时返回 null
  /// （调用方转为「该歌曲没有 MV」）。
  static Future<MvSource?> getSource(
    String mvHash,
    MvQuality quality,
  ) async {
    final hash = mvHash.trim();
    if (!isHashValid(hash)) return null;

    final uri = Uri.parse(mvUrl).replace(queryParameters: <String, String>{
      'cmd': '100',
      'ext': 'mp4',
      'hash': hash,
    });
    final resp = await http
        .get(uri, headers: cdnHeaders)
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw MvUnavailable('酷狗 MV 接口 HTTP ${resp.statusCode}');
    }
    final source = parseMvSource(resp.body, quality);
    if (source == null) {
      AppLog.i('KugouMvApi', '歌曲 $hash 没有可播放的 MV');
    }
    return source;
  }

  /// MvHash 有效性：32 位 hex（与脚本的 `/^[a-f\d]{32}$/i` 一致）。
  static bool isHashValid(String? hash) {
    final v = (hash ?? '').trim();
    return v.isNotEmpty && RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(v);
  }

  /// 解析 `mvdata` → 可用清晰度列表。
  ///
  /// 同 quality 的多档（如 hd 与 sq 都是 1080p）取 **filesize 更大**的
  /// 那一个（脚本 `getKugouMvStreams` 同逻辑）。
  static List<KugouMvStream> getMvStreams(dynamic mvdata) {
    final byQuality = <String, KugouMvStream>{};
    if (mvdata is! Map) return const [];
    for (final level in levels) {
      final raw = mvdata[level.key];
      if (raw is! Map) continue;
      final down = (raw['downurl'] ?? '').toString().trim();
      if (down.isEmpty) continue;
      final stream = KugouMvStream(
        level: level,
        url: down,
        backupUrls: _backupUrls(raw),
        size: _toInt(raw['filesize'] ?? raw['fileSize'] ?? raw['size']),
        width: _toInt(raw['width']),
        height: level.height,
        bitrate: _toInt(raw['bitrate']),
        codec: (raw['codec'] ?? raw['codecs'] ?? '').toString(),
        durationMs: _toInt(raw['timelength']),
      );
      final prev = byQuality[level.quality];
      if (prev == null || stream.size >= prev.size) {
        byQuality[level.quality] = stream;
      }
    }
    return byQuality.values.toList();
  }

  /// 按目标画质挑流：精确匹配 → ≤ 目标的最高档 → 第一档。
  ///
  /// 脚本 `pickKugouMvStream` 同逻辑。
  static KugouMvStream? pickStream(
    List<KugouMvStream> streams,
    MvQuality quality,
  ) {
    if (streams.isEmpty) return null;
    final target = quality == MvQuality.q4k
        ? 2160
        : (quality.height == 0 ? 1080 : quality.height);
    for (final s in streams) {
      if (s.level.height == target) return s;
    }
    final lower = streams.where((s) => s.level.height <= target).toList();
    if (lower.isNotEmpty) {
      lower.sort((a, b) => a.level.height.compareTo(b.level.height));
      return lower.last;
    }
    return streams.first;
  }

  /// 解析接口响应 → [MvSource]。
  ///
  /// 纯函数（供离线单测）：[body] 是原始响应文本。
  static MvSource? parseMvSource(String body, MvQuality quality) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw const MvUnavailable('酷狗 MV 接口返回的不是 JSON');
    }
    if (decoded is! Map) return null;
    if (_toInt(decoded['status']) != 1) return null;

    final streams = getMvStreams(decoded['mvdata']);
    final picked = pickStream(streams, quality);
    if (picked == null) return null;

    // 时长：优先用流自身的 `timelength`，否则用响应根节点的（脚本同款）。
    final durationMs =
        picked.durationMs > 0 ? picked.durationMs : _toInt(decoded['timelength']);
    return MvSource(
      url: picked.url,
      headers: cdnHeaders,
      videoQuality: picked.level.quality,
      mimeType: 'video/mp4',
      size: picked.size,
      width: picked.width,
      height: picked.height,
      bitrate: picked.bitrate,
      backupUrls: picked.backupUrls,
      expiresInSeconds: durationMs > 0 ? (durationMs / 1000).round() : 0,
    );
  }

  /// 该歌实际有哪些画质档（供画质切换菜单用）。
  static Future<List<MvQuality>> availableQualities(String mvHash) async {
    final hash = mvHash.trim();
    if (!isHashValid(hash)) return const [];
    final uri = Uri.parse(mvUrl).replace(queryParameters: <String, String>{
      'cmd': '100',
      'ext': 'mp4',
      'hash': hash,
    });
    final resp = await http
        .get(uri, headers: cdnHeaders)
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) return const [];
    final dynamic decoded;
    try {
      decoded = jsonDecode(resp.body);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) return const [];
    final streams = getMvStreams(decoded['mvdata']);
    final out = <MvQuality>[];
    for (final s in streams) {
      final q = MvQuality.fromKey(s.level.quality);
      if (!out.contains(q)) out.add(q);
    }
    out.sort((a, b) => a.height.compareTo(b.height));
    return out;
  }

  static List<String> _backupUrls(dynamic raw) {
    if (raw is! Map) return const [];
    final v = raw['backupdownurl'] ?? raw['backupDownUrl'] ?? raw['backupurl'];
    if (v is List) {
      return v
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? const [] : <String>[s];
  }

  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? 0;
    return 0;
  }
}
