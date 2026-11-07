// v2.5.4 酷狗 MV 接口回归测试。
//
// 全部离线：用**真实接口响应片段**驱动纯函数解析，不联网。
//
// 逆向自用户上传的「酷狗（ikun）.js」插件的 `getMvSource` /
// `pickKugouMvStream` / `getKugouMvStreams`：
//   `GET https://m.kugou.com/app/i/mv.php?cmd=100&ext=mp4&hash=<MvHash>`
//
// 样本来自沙箱真实抓包（2026-11-07，周杰伦《稻香》MvHash=
// FA30DAD34632AAFF8AC33BCF24ACC241），只保留解析需要的字段。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:baiji_music/network/mv/kugou_mv.dart';
import 'package:baiji_music/network/mv/mv_source.dart';

/// 真实响应（精简：去掉 authors / mp3data 等无关字段，保留全部 mvdata）。
/// 这首歌服务端只给了 3 档：le(480p) / sq(1080p) / rq(4k)。
const String _realBody = '''
{
  "mvdata": {
    "le": {
      "downurl": "http://fsmvpc.tx.kugou.com/202611072104/f0bb59bf58b6d79925466dac47beb4e0/v2/00966e219c5beaae078d1ae804c70fbf/KGTX/CLTX002/00966e219c5beaae078d1ae804c70fbf.mp4",
      "filesize": 15021936,
      "timelength": 224057,
      "bitrate": 536287
    },
    "sq": {
      "downurl": "http://fsmvpc.tx.kugou.com/202611072104/8487db1bf405ef14784e6a7d9e3a32cc/v2/c88babff62c04e6bd55bc8238a5bc328/KGTX/CLTX002/c88babff62c04e6bd55bc8238a5bc328.mp4",
      "filesize": 59933303,
      "timelength": 224057,
      "bitrate": 2139634
    },
    "rq": {
      "downurl": "http://fsmvpc.tx.kugou.com/202611072104/985104d0066c948363414e04c5f8a14b/v2/503de3153bff970f348e27e355139d24/KGTX/CLTX002/503de3153bff970f348e27e355139d24.mp4",
      "filesize": 116056070,
      "timelength": 224057,
      "bitrate": 4143231
    }
  },
  "hash": "00966E219C5BEAAE078D1AE804C70FBF",
  "id": 592103,
  "status": 1,
  "errcode": 0,
  "songname": "稻香",
  "singer": "周杰伦",
  "timelength": 224057,
  "comment_count": 15658,
  "play_count": 51378025
}
''';

/// 构造一段 mvdata（用于覆盖「同一 quality 多档」「缺字段」等分支）。
String _bodyWithMvData(Map<String, dynamic> mvdata, {int status = 1}) =>
    jsonEncode(<String, dynamic>{
      'mvdata': mvdata,
      'status': status,
      'timelength': 224057,
    });

/// 解析 JSON 片段。
dynamic _decode(String s) => jsonDecode(s);

void main() {
  group('KugouMvApi.isHashValid', () {
    test('接受 32 位 hex（大小写均可）', () {
      expect(KugouMvApi.isHashValid('FA30DAD34632AAFF8AC33BCF24ACC241'), isTrue);
      expect(KugouMvApi.isHashValid('fa30dad34632aaff8ac33bcf24acc241'), isTrue);
      expect(
        KugouMvApi.isHashValid('  FA30DAD34632AAFF8AC33BCF24ACC241  '),
        isTrue,
        reason: '两端空白应被裁掉',
      );
    });

    test('拒绝非 32 位 hex', () {
      expect(KugouMvApi.isHashValid(''), isFalse);
      expect(KugouMvApi.isHashValid(null), isFalse);
      expect(KugouMvApi.isHashValid('FA30DAD34632AAFF8AC33BCF24ACC24'), isFalse);
      expect(KugouMvApi.isHashValid('FA30DAD34632AAFF8AC33BCF24ACC2411'), isFalse);
      expect(KugouMvApi.isHashValid('ZZ30DAD34632AAFF8AC33BCF24ACC241'), isFalse);
    });
  });

  group('KugouMvApi.getMvStreams', () {
    test('真实响应解析出 3 档，字段完整', () {
      final dynamic decoded = _decode(_realBody);
      final streams = KugouMvApi.getMvStreams(decoded['mvdata']);
      expect(streams.length, 3);

      final byQuality = <String, KugouMvStream>{
        for (final s in streams) s.level.quality: s,
      };
      expect(byQuality.keys, containsAll(<String>['480p', '1080p', '4k']));

      final hd = byQuality['1080p']!;
      expect(hd.url, startsWith('http://fsmvpc.tx.kugou.com/'));
      expect(hd.size, 59933303);
      expect(hd.height, 1080);
      expect(hd.bitrate, 2139634);
      expect(hd.durationMs, 224057);
      expect(hd.level.key, 'sq');
    });

    test('同一 quality 多档（hd 与 sq 都是 1080p）取 filesize 更大者', () {
      final body = _bodyWithMvData(<String, dynamic>{
        'hd': <String, dynamic>{
          'downurl': 'http://x/hd.mp4',
          'filesize': 1000,
        },
        'sq': <String, dynamic>{
          'downurl': 'http://x/sq.mp4',
          'filesize': 9000,
        },
      });
      final streams = KugouMvApi.getMvStreams(_decode(body)['mvdata']);
      expect(streams.length, 1, reason: '同 quality 合并成一档');
      expect(streams.first.url, 'http://x/sq.mp4');
      expect(streams.first.size, 9000);
    });

    test('缺 downurl 的档位被跳过', () {
      final body = _bodyWithMvData(<String, dynamic>{
        'le': <String, dynamic>{'filesize': 100},
        'sd': <String, dynamic>{'downurl': 'http://x/sd.mp4', 'filesize': 200},
      });
      final streams = KugouMvApi.getMvStreams(_decode(body)['mvdata']);
      expect(streams.length, 1);
      expect(streams.first.level.quality, '720p');
    });

    test('非 Map 输入返回空列表', () {
      expect(KugouMvApi.getMvStreams(null), isEmpty);
      expect(KugouMvApi.getMvStreams('x'), isEmpty);
      expect(KugouMvApi.getMvStreams(<String, dynamic>{}), isEmpty);
    });

    test('兼容 fileSize / size 两种字段名', () {
      final body = _bodyWithMvData(<String, dynamic>{
        'le': <String, dynamic>{'downurl': 'http://x/le.mp4', 'fileSize': 111},
      });
      final streams = KugouMvApi.getMvStreams(_decode(body)['mvdata']);
      expect(streams.first.size, 111);

      final body2 = _bodyWithMvData(<String, dynamic>{
        'le': <String, dynamic>{'downurl': 'http://x/le.mp4', 'size': 222},
      });
      final streams2 = KugouMvApi.getMvStreams(_decode(body2)['mvdata']);
      expect(streams2.first.size, 222);
    });

    test('backupdownurl 支持数组与字符串两种形态', () {
      final body = _bodyWithMvData(<String, dynamic>{
        'le': <String, dynamic>{
          'downurl': 'http://x/le.mp4',
          'filesize': 10,
          'backupdownurl': <String>['http://b1', 'http://b2'],
        },
        'sd': <String, dynamic>{
          'downurl': 'http://x/sd.mp4',
          'filesize': 20,
          'backupdownurl': 'http://only',
        },
      });
      final streams = KugouMvApi.getMvStreams(_decode(body)['mvdata']);
      final le = streams.firstWhere((s) => s.level.quality == '480p');
      final sd = streams.firstWhere((s) => s.level.quality == '720p');
      expect(le.backupUrls, <String>['http://b1', 'http://b2']);
      expect(sd.backupUrls, <String>['http://only']);
    });
  });

  group('KugouMvApi.pickStream', () {
    final streams = KugouMvApi.getMvStreams(_decode(_realBody)['mvdata']);

    test('精确匹配高度', () {
      expect(
        KugouMvApi.pickStream(streams, MvQuality.q480p)!.level.quality,
        '480p',
      );
      expect(
        KugouMvApi.pickStream(streams, MvQuality.q1080p)!.level.quality,
        '1080p',
      );
      expect(
        KugouMvApi.pickStream(streams, MvQuality.q4k)!.level.quality,
        '4k',
      );
    });

    test('目标档不存在时降级到 ≤ 目标的最高档', () {
      // 真实样本没有 720p（sd），请求 720p 应降到 480p。
      expect(
        KugouMvApi.pickStream(streams, MvQuality.q720p)!.level.quality,
        '480p',
      );
      // 请求 4K 但只有 480p 时降到 480p。
      final only480 = KugouMvApi.getMvStreams(
        _decode(_bodyWithMvData(<String, dynamic>{
          'le': <String, dynamic>{'downurl': 'http://x/le.mp4', 'filesize': 1},
        }))['mvdata'],
      );
      expect(
        KugouMvApi.pickStream(only480, MvQuality.q4k)!.level.quality,
        '480p',
      );
    });

    test('空列表返回 null', () {
      expect(KugouMvApi.pickStream(const [], MvQuality.q1080p), isNull);
    });
  });

  group('KugouMvApi.parseMvSource', () {
    test('真实响应解析出可播放源', () {
      final src = KugouMvApi.parseMvSource(_realBody, MvQuality.q1080p);
      expect(src, isNotNull);
      expect(src!.videoQuality, '1080p');
      expect(src.url, startsWith('http://fsmvpc.tx.kugou.com/'));
      expect(src.size, 59933303);
      expect(src.height, 1080);
      expect(src.bitrate, 2139634);
      expect(src.mimeType, 'video/mp4');
      expect(src.headers['Referer'], 'https://www.kugou.com/');
      expect(src.headers['User-Agent'], isNotEmpty);
      expect(src.expiresInSeconds, 224, reason: 'timelength 224057ms → 224s');
    });

    test('请求 4K 时挑 rq 档', () {
      final src = KugouMvApi.parseMvSource(_realBody, MvQuality.q4k)!;
      expect(src.videoQuality, '4k');
      expect(src.size, 116056070);
    });

    test('status != 1 返回 null（没有 MV）', () {
      final body = _bodyWithMvData(<String, dynamic>{
        'le': <String, dynamic>{'downurl': 'http://x/le.mp4', 'filesize': 1},
      }, status: 0);
      expect(KugouMvApi.parseMvSource(body, MvQuality.q1080p), isNull);
    });

    test('mvdata 为空返回 null', () {
      expect(
        KugouMvApi.parseMvSource('{"status":1,"mvdata":{}}', MvQuality.q1080p),
        isNull,
      );
    });

    test('非 JSON 抛 MvUnavailable', () {
      expect(
        () => KugouMvApi.parseMvSource('<html>502</html>', MvQuality.q1080p),
        throwsA(isA<MvUnavailable>()),
      );
    });

    test('时长兜底用响应根节点的 timelength', () {
      final body = '{"mvdata":{"le":{"downurl":"http://x/le.mp4","filesize":1}},'
          '"status":1,"timelength":224057}';
      final src = KugouMvApi.parseMvSource(body, MvQuality.q480p)!;
      expect(src.expiresInSeconds, 224);
    });
  });

  group('KugouMvApi.levels', () {
    test('与上传 JS 的 KUGOU_MV_LEVELS 一致', () {
      expect(KugouMvApi.levels.map((l) => l.key).toList(),
          <String>['le', 'sd', 'hd', 'sq', 'rq']);
      expect(KugouMvApi.levels.map((l) => l.quality).toList(),
          <String>['480p', '720p', '1080p', '1080p', '4k']);
      expect(KugouMvApi.levels.map((l) => l.height).toList(),
          <int>[480, 720, 1080, 1080, 2160]);
    });

    test('CDN 防盗链头与 JS 一致', () {
      expect(KugouMvApi.cdnHeaders['Referer'], 'https://www.kugou.com/');
      expect(KugouMvApi.cdnHeaders['User-Agent'], KugouMvApi.userAgent);
      expect(KugouMvApi.mvUrl, 'https://m.kugou.com/app/i/mv.php');
    });
  });
}
