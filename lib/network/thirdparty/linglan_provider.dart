/// 「聆澜」第三方聚合取流 provider（v2.6.7）。
///
/// GET `https://source.shiqianjiang.cn/api/music/url`
///   ?source=平台&songId=id&quality=音质
///   Header: X-API-Key: 用户自填（代码里没有默认值）
///
/// 响应（实测）：`{"code":200,"message":"成功","type":1,"url":"https://..."}`，
/// 返回**明文直链**，无需本地解密；扩展名 / 展示名由所用音质串推断。
///
/// 覆盖 QQ(tx) / 酷狗(kg) / 酷我(kw) / 网易(wy) / 汽水(qs) / 咪咕(mg)
/// 六端取流；JOOX / QQ2 / 本地不支持（sourceCode 返回 null）。
/// songId：QQ=mid、酷狗=FileHash、网易=id、汽水=trackid、咪咕=id、酷我=rid。
/// 音质：用户所选先映射成规范串，平台不支持则沿档位序自动降级。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../models/models.dart';
import '../kugou/kugou_api.dart';
import 'third_party_provider.dart';

class LinglanProvider extends ThirdPartyProvider {
  const LinglanProvider();

  static const String apiBase = 'https://source.shiqianjiang.cn/api/music/url';

  @override
  String get id => 'linglan';

  @override
  String get displayName => '聆澜';

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    validateStatus: (_) => true,
  ));

  /// 全局档位序（低 → 高）；各平台列表都是它的有序子序列。
  static const List<String> rank = <String>[
    '32k', '64k', '128k', '256k', '320k', 'flac', 'flac24bit', 'hires',
    'atmos', 'atmos_plus', 'master',
  ];

  /// 聆澜各平台支持的音质（用户给定，低 → 高）。
  static const Map<String, List<String>> platformQualities =
      <String, List<String>>{
    'kg': <String>['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'master'],
    'kw': <String>['128k', '320k', 'flac', 'flac24bit', 'hires'],
    'mg': <String>['128k', '320k', 'flac', 'flac24bit', 'hires'],
    'qs': <String>['32k', '64k', '128k', '256k', '320k', 'flac'],
    'tx': <String>[
      '128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'atmos_plus', 'master'
    ],
    'wy': <String>[
      '128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'master'
    ],
  };

  @override
  String? sourceCode(String source) {
    switch (source) {
      case Source.qq:
        return 'tx';
      case Source.kugou:
        return 'kg';
      case Source.kuwo:
        return 'kw';
      case Source.netease:
        return 'wy';
      case Source.qishui:
        return 'qs';
      case Source.migu:
        return 'mg';
      default:
        // joox / qq2 / local 无第三方通道。
        return null;
    }
  }

  @override
  String clampQuality(String desired, String platform) {
    final list = platformQualities[platform] ?? const <String>['128k'];
    final target = rank.indexOf(desired);
    final targetRank = target < 0 ? 0 : target;
    var best = list.first;
    var bestRank = -1;
    for (final q in list) {
      final r = rank.indexOf(q);
      if (r <= targetRank && r > bestRank) {
        best = q;
        bestRank = r;
      }
    }
    return bestRank < 0 ? list.first : best;
  }

  @override
  String extOf(String quality) {
    switch (quality) {
      case 'flac':
      case 'flac24bit':
      case 'hires':
      case 'master':
        return '.flac';
      case 'atmos':
      case 'atmos_plus':
        return '.mp4';
      default:
        return '.mp3';
    }
  }

  @override
  String labelOf(String quality) {
    switch (quality) {
      case '32k': return '极速 32k';
      case '64k': return '省流 64k';
      case '128k': return '标准 128k';
      case '256k': return '高品 256k';
      case '320k': return '极高 320k';
      case 'flac': return '无损 FLAC';
      case 'flac24bit': return '24bit 无损';
      case 'hires': return 'Hi-Res';
      case 'atmos': return '杜比全景声';
      case 'atmos_plus': return '杜比全景声 Plus';
      case 'master': return '臻品母带';
      default: return quality;
    }
  }

  // ==================== App 音质 → 规范音质串 ====================

  static String fromQq(Quality? q) {
    if (q == null) return '128k';
    switch (q.code) {
      case 'M500':
      case 'C200':
      case 'C400':
      case 'C600':
        return '128k';
      case 'M800':
      case 'O600':
      case 'O800':
      case 'O801':
        return '320k';
      case 'F000':
      case 'TL01':
        return 'flac';
      case 'RS01':
        return 'hires';
      case 'AI00':
        return 'master';
      case 'V0M0':
        return 'flac24bit';
      case 'D001':
      case 'D002':
      case 'D003':
      case 'D004':
      case 'Q000':
      case 'Q001':
      case 'Q003':
      case 'DT03':
        return 'atmos';
      default:
        if (q.code.startsWith('RA0')) return 'atmos';
        return q.bitrate >= 320 ? '320k' : '128k';
    }
  }

  static String fromNetease(NeteaseQuality? q) {
    if (q == null) return '128k';
    switch (q.level) {
      case 'standard': return '128k';
      case 'exhigh': return '320k';
      case 'lossless': return 'flac';
      case 'hires': return 'hires';
      case 'jymaster': return 'master';
      case 'sky':
      case 'jyeffect':
      case 'dolby':
      case 'vivid':
        return 'atmos';
      default: return '128k';
    }
  }

  static String fromKuwo(KuwoQuality? q) {
    if (q == null) return '128k';
    switch (q.id) {
      case '128k': return '128k';
      case '320k':
      case '300k': return '320k';
      case '192k':
      case '100k':
      case '48k': return '64k';
      case 'flac': return 'flac';
      case 'hires': return 'hires';
      case 'master': return 'master';
      case 'bcms':
      case 'vinyl': return 'flac24bit';
      case 'atmos':
      case 'atmos_plus':
      case 'atmos_714':
      case 'dolby_dd7':
      case 'dolby_640':
      case 'dolby_448':
      case 'dolby_ac4':
        return 'atmos';
      default: return '128k';
    }
  }

  static String fromKugou(KugouQuality? q) {
    if (q == null) return '128k';
    switch (q.id) {
      case '128kmp3': return '128k';
      case '320kmp3': return '320k';
      case 'flac': return 'flac';
      case 'hires': return 'hires';
      default:
        final id = q.id.toLowerCase();
        if (id.contains('dolby') ||
            id.contains('atmos') ||
            id.startsWith('ra0') ||
            id.contains('multi') ||
            id.contains('viper')) {
          return 'atmos';
        }
        if (q.bitrate >= 1000) return 'master';
        if (q.bitrate >= 400) return 'hires';
        if (q.bitrate >= 320) return '320k';
        return '128k';
    }
  }

  static String fromMigu(MiguQuality? q) => q?.id ?? '128k';

  static String fromQishui(QishuiQuality? q) {
    if (q == null) return '128k';
    switch (q.id) {
      case 'lowest': return '32k';
      case 'low': return '64k';
      case 'medium': return '128k';
      case 'higher': return '256k';
      case 'highest': return '320k';
      case 'lossless':
      case 'hi_res':
      case 'spatial':
      case 'original':
        return 'flac';
      default: return '128k';
    }
  }

  @override
  String desiredQuality(String platform, ThirdPartyQuery q) {
    switch (platform) {
      case 'tx': return fromQq(q.qqQuality);
      case 'wy': return fromNetease(q.neQuality);
      case 'kw': return fromKuwo(q.kuwoQuality);
      case 'kg': return fromKugou(q.kugouQuality);
      case 'mg': return fromMigu(q.miguQuality);
      case 'qs': return fromQishui(q.qishuiQuality);
      default: return '128k';
    }
  }

  @override
  Future<String> songIdOf(Song song, String platform) async {
    switch (platform) {
      case 'tx':
      case 'qs':
      case 'mg':
      case 'kw':
        return song.mid;
      case 'wy':
        return song.songId > 0 ? song.songId.toString() : song.mid;
      case 'kg':
        // 酷狗第三方要 FileHash，通用模型只有 MixSongID，按歌名反查。
        return KugouApi.fileHashOf(song.mid, song.name, song.singer);
      default:
        return '';
    }
  }

  @override
  Future<ThirdPartyStreamInfo?> fetch({
    required Song song,
    required String apiKey,
    required ThirdPartyQuery query,
  }) async {
    final platform = sourceCode(song.source);
    if (platform == null || apiKey.isEmpty) return null;

    final songId = await songIdOf(song, platform);
    if (songId.isEmpty) return null;

    final desired = desiredQuality(platform, query);
    final quality = clampQuality(desired, platform);

    try {
      final resp = await _dio.get<String>(
        apiBase,
        queryParameters: <String, dynamic>{
          'source': platform,
          'songId': songId,
          'quality': quality,
        },
        options: Options(headers: <String, String>{'X-API-Key': apiKey}),
      );
      final body = resp.data ?? '';
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        AppLog.w('ThirdParty', '响应非 JSON 对象: ${body.substring(0, body.length.clamp(0, 120))}');
        return null;
      }
      final code = decoded['code'] is num ? (decoded['code'] as num).toInt() : -1;
      if (code != 200) {
        AppLog.w('ThirdParty', '取流失败 code=$code msg=${decoded['message'] ?? decoded['msg'] ?? ''}');
        return null;
      }
      final url = decoded['url']?.toString() ?? '';
      if (url.isEmpty) {
        AppLog.w('ThirdParty', '取流成功但 url 为空');
        return null;
      }
      return ThirdPartyStreamInfo(url: url, quality: quality);
    } catch (e) {
      AppLog.w('ThirdParty', '取流异常: $e');
      return null;
    }
  }
}
