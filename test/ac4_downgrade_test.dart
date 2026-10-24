// v2.4.2 回归测试：AC-4 无法解码的自动降级（#139）。
//
// 背景：播放走 media_kit（libmpv + 预编译 ffmpeg）。其构建脚本用白名单
// 制启用解码器（ac3/eac3/dca/truehd 有，**ac4 没有**），上游 FFmpeg
// 至今没有原生 AC-4 解码器（Jellyfin 靠自编译补丁才支持，见
// jellyfin/jellyfin-ffmpeg#387）。实测确认的 AC-4 档位：
//   - QQ 音乐「杜比全景声」D004 = AC-4/mp4；D008 是它的别名（同文件）；
//     D001~D003（= D005~D007 别名）是 E-AC-3(JOC)，本机可解码。
//   - 酷我「杜比全景声(AC-4)」dolby_ac4（br=11000kmp4）= AC-4；
//     同站 dolby_dd7/dolby_640/dolby_448 是 E-AC-3，可解码。
//   - 网易云「dolby」是 E-AC-3，无需处理。
//
// 取流层（MusicApi / KuwoApi）据此跳过不可解码档位；播放器运行时再兜底
// 一层（libmpv tracks codec 检测 + 预算制降级重试，见 player_controller）。
// 本文件覆盖前两层的纯逻辑；运行时兜底依赖真机 libmpv，不在此单测。
import 'dart:convert';
import 'dart:typed_data';

import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/kuwo/kuwo_api.dart';
import 'package:baiji_music/network/kuwo/kuwo_link.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假适配器：按请求 URL 里的 br 参数回灌预设响应，并记录请求顺序。
///
/// 酷我播放链接接口是 GET，br 在 query 里；响应 JSON 形如
/// `{"code":200,"data":{"rid":..,"bitrate":..,"format":..,"url":..,"ekey":""}}`。
class _FakeLinkAdapter implements HttpClientAdapter {
  _FakeLinkAdapter(this.replyFor);

  /// br → 响应 data  Map（测试里按场景预设）。
  final Map<String, dynamic> Function(String br) replyFor;

  final List<String> requestedBrs = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final br = Uri.parse(options.uri.toString())
        .queryParameters['br']
        ?.toString() ?? '';
    requestedBrs.add(br);
    final data = replyFor(br);
    final body = jsonEncode({'code': 200, 'data': data});
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 造一条「服务端按某档位应答」的 data Map。
Map<String, dynamic> _linkData({
  required int bitrate,
  required String format,
  String url = 'http://cdn.example/track.bin',
  String ekey = '',
}) =>
    {
      'rid': '7149583',
      'bitrate': bitrate,
      'format': format,
      'url': url,
      'ekey': ekey,
      'duration': 200,
    };

void main() {
  // 保存/恢复真适配器：本文件只动 KuwoLink.dio，不影响其它测试文件
  // （flutter test 每文件独立 isolate，这里只是防御性写法）。
  final original = KuwoLink.dio.httpClientAdapter;
  tearDown(() => KuwoLink.dio.httpClientAdapter = original);

  group('QQ 杜比全景声档位模型（v2.4.2）', () {
    test('D001~D003 是 E-AC-3 可解码，D004 是 AC-4 不可解码', () {
      expect(Quality.atmosEac3Plus.code, 'D003');
      expect(Quality.atmosEac3.code, 'D002');
      expect(Quality.atmosEac3Lite.code, 'D001');
      expect(Quality.atmosDb.code, 'D004');
      expect(Quality.undecodableCodes, {'D004'});
      for (final q in [
        Quality.atmosEac3Plus,
        Quality.atmosEac3,
        Quality.atmosEac3Lite
      ]) {
        expect(Quality.undecodableCodes.contains(q.code), isFalse,
            reason: '${q.code} 是 E-AC-3(JOC)，本机可解码');
      }
    });

    test('D005~D008 是 D001~D004 的别名（官方客户端默认请求 D005）', () {
      expect(Quality.dolbyAlias, {
        'D005': 'D001',
        'D006': 'D002',
        'D007': 'D003',
        'D008': 'D004',
      });
    });

    test('fromUrlPrefix 归一杜比别名（D005~D008 → D001~D004）', () {
      expect(
          Quality.fromUrlPrefix('https://x/D005abc.mp4'), Quality.atmosEac3Lite);
      expect(
          Quality.fromUrlPrefix('https://x/D006abc.mp4'), Quality.atmosEac3);
      expect(Quality.fromUrlPrefix('https://x/D007abc.mp4'),
          Quality.atmosEac3Plus);
      expect(
          Quality.fromUrlPrefix('https://x/D008abc.mp4'), Quality.atmosDb);
      // 原名（D001~D004）仍然认得
      expect(
          Quality.fromUrlPrefix('https://x/D001abc.mp4'), Quality.atmosEac3Lite);
      expect(
          Quality.fromUrlPrefix('https://x/D004abc.mp4'), Quality.atmosDb);
    });

    test('fromUrlPrefix 非杜比档不受别名影响', () {
      expect(Quality.fromUrlPrefix('https://x/M800abc.mp3?k=1'), Quality.mp3_320);
      expect(Quality.fromUrlPrefix('https://x/F000abc.flac'), Quality.flac);
      expect(Quality.fromUrlPrefix('https://x/RS020abc.flac'), isNull);
    });

    test('downloadOptions 四档杜比齐全、D004 排在 E-AC-3 之后', () {
      final codes = Quality.downloadOptions.map((q) => q.code).toList();
      for (final c in ['D001', 'D002', 'D003', 'D004']) {
        expect(codes.contains(c), isTrue, reason: '$c 缺失');
      }
      expect(codes.indexOf('D003'), lessThan(codes.indexOf('D004')));
    });
  });

  group('QQ 取流降级链过滤 AC-4', () {
    test('从 D004 出发：D004 不进链，首档即 ladder 下一档 Q003', () {
      final chain = MusicApi.qqDowngradeChain(Quality.atmosDb);
      expect(chain.first.code, 'Q003',
          reason: 'D004 被过滤后应从 downloadOptions 里的下一档起步');
      expect(chain.any((q) => Quality.undecodableCodes.contains(q.code)),
          isFalse);
    });

    test('任意起点都不会链出不可解码档', () {
      for (final from in Quality.downloadOptions) {
        final chain = MusicApi.qqDowngradeChain(from);
        expect(
            chain.any((q) => Quality.undecodableCodes.contains(q.code)), isFalse,
            reason: '从 ${from.code} 出发的链里混进了 AC-4');
      }
    });

    test('链上必含兜底档 mp3_128（保证永远有得播）', () {
      for (final from in [
        Quality.atmosDb,
        Quality.atmosEac3Plus,
        Quality.mp3_320,
        Quality.dtsX,
        Quality.aac48,
      ]) {
        expect(
            MusicApi.qqDowngradeChain(from)
                .any((q) => q.code == Quality.mp3_128.code),
            isTrue,
            reason: '从 ${from.code} 出发没有兜底');
      }
    });

    test('qqDecodableSubstitute：D004 → ladder 下一档 Q003，可解码档原样返回', () {
      expect(MusicApi.qqDecodableSubstitute(Quality.atmosDb).code, 'Q003');
      expect(
          MusicApi.qqDecodableSubstitute(Quality.atmosEac3Plus).code, 'D003');
      expect(MusicApi.qqDecodableSubstitute(Quality.mp3_128).code,
          Quality.mp3_128.code);
    });
  });

  group('酷我 AC-4 档位规则（v2.4.2）', () {
    test('undecodableIds 只有 dolby_ac4', () {
      expect(KuwoLink.undecodableIds, {'dolby_ac4'});
    });

    test('dolby_ac4 在规则表里存在，E-AC-3 三档排在它前面（bitrate 更高）', () {
      final ids = KuwoLink.qualityRules.map((r) => r[2] as String).toList();
      expect(ids.contains('dolby_ac4'), isTrue);
      for (final id in ['dolby_dd7', 'dolby_640', 'dolby_448']) {
        expect(ids.indexOf(id), lessThan(ids.indexOf('dolby_ac4')),
            reason: '$id 应按 bitrate 降序排在 dolby_ac4 之前');
      }
    });

    test('downgradeRules(dolby_ac4)：首条是自己，下一条按 bitrate 降序', () {
      final rules = KuwoLink.downgradeRules('dolby_ac4');
      expect(rules.first[2], 'dolby_ac4');
      // 表按 bitrate 降序，ac4(11000) 之后是 hires(4000)——降级链不看
      // 「同家族最近」，只看「不高于请求档位」，与其它档位行为一致。
      final next = rules.skip(1).first;
      expect(next[2], 'hires');
      expect(KuwoLink.undecodableIds.contains(next[2] as String), isFalse);
    });

    test('KuwoQuality.fromId 找到 AC-4 档，label 明示 AC-4', () {
      final q = KuwoQuality.fromId('dolby_ac4');
      expect(q, isNotNull);
      expect(q!.br, '11000kmp4');
      expect(q.label.contains('AC-4'), isTrue);
    });
  });

  group('酷我取流跳过 AC-4（playUrlWithFallback，假 dio）', () {
    test('用户选了 AC-4 档：根本不为它发请求，首档即 hires', () async {
      final adapter = _FakeLinkAdapter((br) => _linkData(
          bitrate: 4000, format: 'flac', url: 'http://cdn/hires.flac'));
      KuwoLink.dio.httpClientAdapter = adapter;

      final link = await KuwoApi.playUrlWithFallback(
        '7149583',
        KuwoQuality.fromId('dolby_ac4')!,
      );

      expect(adapter.requestedBrs, ['4000kflac'],
          reason: 'AC-4 档位必须被跳过，不能发出 11000kmp4 请求');
      expect(link.qualityId, 'hires');
      expect(link.playUrl, isNotEmpty);
    });

    test('服务端 mislabel：请求 E-AC-3 却回 AC-4，继续下探到 E-AC-3', () async {
      // br=11700kmp4（dolby_dd7）→ 服务端回 AC-4（bitrate 11000/mp4）
      // br=11600kmp4（dolby_640）→ 服务端回 448k 档（11500/mp4）
      final adapter = _FakeLinkAdapter((br) {
        if (br == '11700kmp4') {
          return _linkData(
              bitrate: 11000, format: 'mp4', url: 'http://cdn/ac4.mp4');
        }
        return _linkData(
            bitrate: 11500, format: 'mp4', url: 'http://cdn/eac3.mp4');
      });
      KuwoLink.dio.httpClientAdapter = adapter;

      final link = await KuwoApi.playUrlWithFallback(
        '7149583',
        KuwoQuality.fromId('dolby_dd7')!,
      );

      expect(adapter.requestedBrs, ['11700kmp4', '11600kmp4'],
          reason: '回 AC-4 必须继续降级，而不是硬着头皮返回');
      expect(link.qualityId, 'dolby_448');
      expect(link.playUrl, isNotEmpty);
    });

    test('服务端对每一档都回 AC-4：最终抛错而不是返回放不出的链接', () async {
      final adapter = _FakeLinkAdapter((br) =>
          _linkData(bitrate: 11000, format: 'mp4', url: 'http://cdn/ac4.mp4'));
      KuwoLink.dio.httpClientAdapter = adapter;

      expect(
          () async => KuwoApi.playUrlWithFallback(
                '7149583',
                KuwoQuality.fromId('dolby_dd7')!,
              ),
          throwsA(isA<Exception>()));
    });

    test('正常档位一次命中，不发多余请求', () async {
      final adapter = _FakeLinkAdapter((br) => _linkData(
          bitrate: 2000, format: 'flac', url: 'http://cdn/flac.flac'));
      KuwoLink.dio.httpClientAdapter = adapter;

      final link = await KuwoApi.playUrlWithFallback(
        '7149583',
        KuwoQuality.fromId('flac')!,
      );

      expect(adapter.requestedBrs, ['2000kflac']);
      expect(link.qualityId, 'flac');
    });
  });
}
