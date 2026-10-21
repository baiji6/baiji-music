// 酷我音乐 —— 老版「获取播放链接」接口（type=convert_url_with_sign）
//
// 逆向自 bai music_4.0.apk 的 nmobi.kuwo.cn/mobi.s 接口（无签名、无 Cookie）。
//
// 给定 音乐id + 音质，返回:
//   { rid, bitrate, format, url, ekey, duration, encrypted }
//   - encrypted=true  : QMC 加密（mflac/mgg/flac/mp3/ogg/aac），需本地解密后才可播放
//   - encrypted=false : 明文（mp4 杜比/视频等），url 可直接播放，无 ekey
library;

import 'package:dio/dio.dart';

class KuwoLink {
  /// 老接口域名与公共参数
  static const String api = 'http://nmobi.kuwo.cn/mobi.s';
  static const String source =
      'kwplayerhd_ar_6.6.6.6_tianbao_T1A_qirui.apk';
  static const String ua = 'okhttp/4.9.0';

  /// 音质规则: [bitrate, format, 音质id, 名称, 排序值]
  static const List<List<dynamic>> qualityRules = [
    ['24000', 'mgg', 'atmos_714', '全景声(7.1.4)', 24000],
    ['23000', 'flac', 'vinyl', '黑胶音质', 23000],
    ['22000', 'mgg', 'bcms', '臻品音质(BCMS)', 22000],
    ['20900', 'mflac', 'master', '臻品母带', 20900],
    ['20501', 'mflac', 'atmos_plus', '全景声(5.1)', 20501],
    ['20201', 'mflac', 'atmos', '全景声(2.0)', 20201],
    ['11700', 'mp4', 'dolby_dd7', '杜比全景声(E-AC-3)', 11700],
    ['11600', 'mp4', 'dolby_640', '杜比全景声(640)', 11600],
    ['11500', 'mp4', 'dolby_448', '杜比全景声(448)', 11500],
    ['11000', 'mp4', 'dolby_ac4', '杜比全景声(AC-4)', 11000],
    ['4000', 'flac', 'hires', 'Hi-Res音质', 4000],
    ['2000', 'flac', 'flac', '无损音质', 2000],
    ['320', 'mp3', '320k', '极高音质', 320],
    ['300', 'ogg', '300k', '极高音质(ogg)', 300],
    ['192', 'ogg', '192k', '高品质ogg', 192],
    ['128', 'mp3', '128k', '标准音质', 128],
    ['100', 'ogg', '100k', '高清ogg', 100],
    ['48', 'aac', '48k', '省流aac', 48],
  ];

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
  ));

  /// 取 br 参数字符串: "{bitrate}k{format}"
  static String brOf(List<dynamic> rule) => '${rule[0]}k${rule[1]}';

  /// 按音质 id 找规则
  static List<dynamic>? ruleById(String id) {
    for (final r in qualityRules) {
      if (r[2] == id) return r;
    }
    return null;
  }

  /// 按音质 id 取 br 字符串
  static String? brById(String id) {
    final r = ruleById(id);
    return r == null ? null : brOf(r);
  }

  /// 全部可用 br 字符串列表（按音质从高到低）
  static List<String> allBr() => qualityRules.map(brOf).toList();

  /// 从 [from] 起按 bitrate 降序的降级链（不含 from 之后的重复项）。
  ///
  /// 酷我未登录/无版权时高档位会直接失败，必须有降级链兜底。
  static List<String> downgradeChain(String fromId) {
    final out = <String>[];
    final start = qualityRules.indexWhere((r) => r[2] == fromId);
    final ordered = start < 0
        ? qualityRules
        : qualityRules.sublist(start);
    for (final r in ordered) {
      final br = brOf(r);
      if (!out.contains(br)) out.add(br);
    }
    return out;
  }

  /// 获取播放链接。
  /// [rid] 音乐 id；[br] 音质 br 字符串，如 "20900kmflac"；
  /// 也可传 [qualityId]（如 "master"）自动换算。
  static Future<Map<String, dynamic>> getPlayUrl(
    String rid, {
    String? br,
    String? qualityId,
  }) async {
    final useBr = br ?? (qualityId != null ? brById(qualityId) : null);
    if (useBr == null) {
      throw ArgumentError('必须提供 br 或 qualityId');
    }
    final url = Uri.parse(api).replace(queryParameters: {
      'f': 'web',
      'user': '0',
      'source': source,
      'type': 'convert_url_with_sign',
      'rid': rid,
      'br': useBr,
    }).toString();

    final resp = await _dio.get<Map<String, dynamic>>(
      url,
      options: Options(
        responseType: ResponseType.json,
        headers: {'User-Agent': ua},
      ),
    );
    final json = resp.data;
    if (json == null) throw Exception('酷我播放链接接口返回空');
    final data = (json['data'] ?? const {}) as Map<String, dynamic>;

    final ekey = (data['ekey'] ?? '').toString();
    final format = (data['format'] ?? '').toString();
    return {
      'rid': data['rid']?.toString() ?? rid,
      'bitrate': data['bitrate'],
      'format': format,
      'url': data['url'] ?? '',
      'ekey': ekey,
      'duration': data['duration'],
      'encrypted': ekey.isNotEmpty,
    };
  }

  /// 便捷: 依次尝试从高到低音质，取第一个成功拿到链接的结果
  static Future<Map<String, dynamic>> getBestUrl(String rid) async {
    for (final r in qualityRules) {
      try {
        final res = await getPlayUrl(rid, br: brOf(r));
        if ((res['url'] ?? '').toString().isNotEmpty) return res;
      } catch (_) {
        // 该音质不可用, 继续尝试更低音质
      }
    }
    throw Exception('没有任何可用音质: rid=$rid');
  }
}
