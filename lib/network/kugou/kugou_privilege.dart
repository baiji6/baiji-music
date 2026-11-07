// 酷狗音乐 —— 权威音质档位探测（v2.5.4）。
//
// **为什么需要这个文件**：v2.5.2 的音质推导靠猜——搜索响应里的
// `FileHash / HQFileHash / SQFileHash / ResFileHash / SuperFileHash` 与
// `trans_param.hash_multitrack`，再对 360RA 猜测「`SuperExtName` 含 mha
// 或 `trans_param` 的 key 名含 360/mha」。但搜索接口**根本不返回
// `trans_param`**（实测 30 首歌曲一个都没有），那个启发式**永不命中**，
// 于是「支持 360RA 的歌曲里看不到 360RA 选项」。
//
// 服务端真正决定「这首歌有哪些音质」的接口是
// `POST gateway.kugou.com/goodsmstore/v1/get_res_privilege`：请求体里
// `qualities` 数组列出想探测的档位，响应 `data[].relate_goods[]` 逐档
// 回 `quality` / `hash` / `info.filesize` / `info.extname` / `level`。
//
// 沙箱实测（2026-11-07，周杰伦《稻香》hash=8909E180…）：
//   128 / 320 / flac / high / viper_atmos / viper_tape / viper_clear /
//   viper_hifi / dolby / dolby2_448k / dolby2_1500k / 360ra_l1~l3 / super
//   → 合法，返回对应条目；
//   360ra / master / mha1 / sony360ra / viper_tape_master
//   → `error_code 20010`（**整个请求直接失败**，一个非法代号会拖垮整批）。
//
// 所以 [probeQualities] 里的全集必须是**服务端认得的**代号，且一旦发现
// 非法代号要能被服务端整体拒绝——因此这里用「一个探测请求覆盖全部
// 候选档位」而不是逐个试。
//
// 该接口**不校验 gateway 签名**（只认 appid / clientver），但仍带上
// 设备 mid 保持与登录态一致。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import 'kugou_auth.dart';

/// 一个服务端下发的音质档位。
class KugouQualityOption {
  /// 服务端 quality 代号（如 `flac` / `viper_hifi` / `360ra_l3`）。
  final String quality;

  /// 该档位的文件 hash（取链时直接用它）。
  final String hash;

  /// 文件字节数（0 = 未知）。
  final int filesize;

  /// 容器扩展名（`flac` / `mp3` / `mp4`；可能为空）。
  final String extname;

  /// 服务端画质等级（2=128k 4=320k 5=flac 6=Hi-Res；高级档为 0）。
  final int level;

  const KugouQualityOption({
    required this.quality,
    required this.hash,
    this.filesize = 0,
    this.extname = '',
    this.level = 0,
  });

  @override
  String toString() => 'KugouQualityOption($quality,$hash)';
}

/// 酷狗权威档位探测。
abstract final class KugouPrivilegeApi {
  /// 探测端点（注意是 POST，且不校验 gateway 签名）。
  static const String privilegeUrl =
      'https://gateway.kugou.com/goodsmstore/v1/get_res_privilege';

  /// 探测用的 quality 全集。
  ///
  /// **每一个都必须是服务端认得的代号**：实测只要混入一个非法代号
  /// （如 `360ra` / `master`），整批请求直接返回 `error_code 20010`。
  static const List<String> qualityCatalog = <String>[
    '128',
    '320',
    'flac',
    'high',
    'dolby',
    'viper_atmos',
    'viper_tape',
    'viper_clear',
    'viper_hifi',
    '360ra_l1',
    '360ra_l2',
    '360ra_l3',
    'dolby2_448k',
    'dolby2_1500k',
    'super',
  ];

  /// 一次最多探测多少首歌（服务端对 resource 数组长度有上限，
  /// 过大容易被拒；实测 30 首一次可过）。
  static const int maxBatchSize = 30;

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 25),
    // 服务端在个别网关节点会回 `text/html`（WAF 拦截页），强制按文本
    // 收，再自己 JSON 解析——否则 Dio 会因 content-type 不符而抛类型错误。
    responseType: ResponseType.plain,
  ));

  /// 批量探测歌曲的真实音质档位。
  ///
  /// 返回 `hash → {quality → option}`；某首探测失败则该首不出现，
  /// **不抛异常**（调用方应降级到启发式推导，不让音质探测拖垮搜索）。
  static Future<Map<String, Map<String, KugouQualityOption>>> probeQualities(
    List<String> hashes,
  ) async {
    final out = <String, Map<String, KugouQualityOption>>{};
    if (hashes.isEmpty) return out;

    final valid = <String>[];
    for (final h in hashes) {
      final t = h.trim();
      if (t.isEmpty) continue;
      if (!valid.contains(t)) valid.add(t);
      if (valid.length >= maxBatchSize) break;
    }
    if (valid.isEmpty) return out;

    try {
      // 设备 mid：拿不到就用占位值——**不能**因为存储未初始化就让整次
      // 探测失败（测试环境 / 早期启动阶段 KvStore 可能还没 ensureInit）。
      var mid = 'NeZha';
      try {
        final auth = await KugouAuth.requestParams();
        mid = auth['mid'] ?? mid;
      } catch (_) {
        // 忽略：探测接口不校验 mid，用占位值即可。
      }
      final payload = <String, dynamic>{
        'behavior': 'play',
        'clientver': '20049',
        'resource': [
          for (final h in valid)
            <String, dynamic>{'id': 0, 'type': 'audio', 'hash': h},
        ],
        'area_code': '1',
        'quality': '128',
        'qualities': qualityCatalog,
      };
      final resp = await _dio.post<String>(
        privilegeUrl,
        queryParameters: <String, dynamic>{
          'appid': '1005',
          'clientver': '20049',
          'clienttime': DateTime.now().millisecondsSinceEpoch,
          'mid': mid,
        },
        data: payload,
        options: Options(
          headers: <String, String>{
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36',
          },
        ),
      );
      final raw = resp.data;
      if (raw == null || raw.trim().isEmpty) return out;
      final dynamic decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        AppLog.w('KugouPrivilege',
            '档位探测返回的不是 JSON: ${raw.length > 120 ? raw.substring(0, 120) : raw}');
        return out;
      }
      if (decoded is! Map) return out;
      final data = Map<String, dynamic>.from(decoded);
      final code = _toInt(data['error_code']);
      if (code != 0) {
        AppLog.w('KugouPrivilege', '档位探测失败 error_code=$code');
        return out;
      }
      final list = data['data'];
      if (list is! List) return out;
      for (var i = 0; i < list.length && i < valid.length; i++) {
        final item = list[i];
        if (item is! Map) continue;
        final opts = parseQualities(item);
        if (opts.isEmpty) continue;
        // 服务端按 resource 顺序回包，但保险起见用 hash 字段反查。
        final hash = (item['hash'] ?? '').toString().trim();
        out[hash.isNotEmpty ? hash : valid[i]] = opts;
      }
      AppLog.i('KugouPrivilege', '档位探测 ${valid.length} 首，命中 ${out.length}');
    } catch (e) {
      AppLog.w('KugouPrivilege', '档位探测异常: $e');
    }
    return out;
  }

  /// 解析单首歌曲的 `relate_goods` → `quality → option`。
  ///
  /// 公开是为了让离线测试能直接喂真实响应片段（项目惯例，见
  /// `KugouApi.parseSong` 的同款说明）。
  static Map<String, KugouQualityOption> parseQualities(dynamic raw) {
    final out = <String, KugouQualityOption>{};
    if (raw is! Map) return out;
    final goods = raw['relate_goods'];
    if (goods is! List) return out;
    for (final g in goods) {
      if (g is! Map) continue;
      final quality = (g['quality'] ?? '').toString().trim();
      final hash = (g['hash'] ?? '').toString().trim();
      if (quality.isEmpty || hash.isEmpty) continue;
      final info = g['info'];
      final infoMap = info is Map ? info : const <String, dynamic>{};
      final size = _toInt(infoMap['filesize']);
      // 服务端偶尔给 filesize=0 的条目（高级档常见），跳过空档。
      if (size <= 0) continue;
      out[quality] = KugouQualityOption(
        quality: quality,
        hash: hash,
        filesize: size,
        extname: (infoMap['extname'] ?? '').toString().trim(),
        level: _toInt(g['level']),
      );
    }
    return out;
  }

  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? 0;
    return 0;
  }
}
