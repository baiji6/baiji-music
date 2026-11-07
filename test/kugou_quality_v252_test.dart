/// v2.5.2 酷狗音质档位回归：新档位、本地升频取链参数、按歌实际能力推导。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/kugou/kugou_api.dart';

Map<String, dynamic> fakeSong({
  String hash = 'HASH128',
  String hq = 'HASH320',
  String sq = 'HASHFLAC',
  String res = 'HASHRES',
  String superHash = '',
  String superExt = '',
  Map<String, dynamic>? transParam,
}) =>
    <String, dynamic>{
      'MixSongID': '123456',
      'SongName': '测试曲目',
      'SingerName': '测试歌手',
      'AlbumName': '测试专辑',
      'AlbumID': '789',
      'FileHash': hash,
      'HQFileHash': hq,
      'SQFileHash': sq,
      'ResFileHash': res,
      'SuperFileHash': superHash,
      'SuperExtName': superExt,
      'Image': '',
      'Duration': '200',
      'trans_param': transParam ?? <String, dynamic>{},
    };

Set<String> ids(KugouSong s) => s.qualities.map((q) => q.id).toSet();

void main() {
  group('KugouQuality 档位', () {
    test('新增档位可由 id 反查，且本地升频档取链参数正确', () {
      final tape = KugouQuality.fromId('viper_tape');
      expect(tape, isNotNull);
      expect(tape!.isLocalUpscale, isTrue);
      expect(tape.fetchQualityTag, '320',
          reason: '本地升频档必须取 320k 源文件，不请求不存在的母带文件');
      expect(tape.fetchHashKey, 'HQFileHash');
      expect(tape.aiTag, contains('AI升频'));

      expect(KugouQuality.fromId('viper_clear'), isNotNull);
      expect(KugouQuality.fromId('viper_atmos'), isNotNull);
      expect(KugouQuality.fromId('dolby'), isNotNull);
      expect(KugouQuality.fromId('360ra')!.qualityTag, '360ra_l3',
          reason: '360RA 服务端代号实测为 360ra_l1/l2/l3');
    });

    test('播放档位全集按码率降序，下载档位不含本地升频档', () {
      final opts = KugouQuality.playbackOptions;
      for (var i = 1; i < opts.length; i++) {
        expect(opts[i - 1].bitrate >= opts[i].bitrate, isTrue);
      }
      expect(opts.first, KugouQuality.viperTape);
      expect(KugouQuality.downloadOptions.any((q) => q.isLocalUpscale), isFalse,
          reason: '下载不能把 320k 冒充 192k 母带');
      expect(KugouQuality.fromId(KugouQuality.playbackDefault.id), isNotNull);
    });
  });

  group('按歌曲实际能力推导', () {
    test('全字段歌曲：基础档 + 蝰蛇/杜比（有多轨），无 360RA 标记不常驻', () {
      final s = KugouApi.parseSong(fakeSong(transParam: <String, dynamic>{
        'hash_multitrack': 'MULTI123',
        'qualitymap': <String, dynamic>{'bits': '28fffc0db411ffffff3fc074'},
      }))!;
      final got = ids(s);
      expect(got.containsAll(<String>[
        'viper_tape', 'viper_atmos', 'viper_clear', 'dolby',
        'hires', 'flac', '320kmp3', '128kmp3',
      ]), isTrue);
      expect(got.contains('360ra'), isFalse,
          reason: '服务端没给 360RA 明确标记就不展示');
      expect(s.multiTrackHash, 'MULTI123');
      expect(s.qualityBits, '28fffc0db411ffffff3fc074');
    });

    test('只有 128k 的歌：不凭空出现升频档/高音质档', () {
      final s = KugouApi.parseSong(fakeSong(
        hash: 'ONLY128', hq: '', sq: '', res: '',
      ))!;
      expect(ids(s), <String>{'128kmp3'});
    });

    test('有 320k 但无多轨：只多一个本地升频档', () {
      final s = KugouApi.parseSong(fakeSong(sq: '', res: ''))!;
      final got = ids(s);
      expect(got.contains('viper_tape'), isTrue);
      expect(got.contains('320kmp3'), isTrue);
      expect(got.contains('viper_atmos'), isFalse);
      expect(got.contains('dolby'), isFalse);
      expect(got.contains('viper_clear'), isFalse);
      expect(got.contains('flac'), isFalse);
    });

    test('服务端给出 MHA1 / 360 标记时才展示 360RA', () {
      final byExt = KugouApi.parseSong(fakeSong(superExt: 'mha1'))!;
      expect(ids(byExt).contains('360ra'), isTrue);
      final byKey = KugouApi.parseSong(fakeSong(
        transParam: <String, dynamic>{'360ra_hash': 'ABC'},
      ))!;
      expect(ids(byKey).contains('360ra'), isTrue);
    });

    test('trans_param 为 JSON 字符串也能解析', () {
      final s = KugouApi.parseSong(fakeSong(
        transParam: null,
      )..['trans_param'] =
          '{"hash_multitrack":"MT","qualitymap":{"bits":"ab12"}}')!;
      expect(ids(s).contains('viper_atmos'), isTrue);
      expect(s.qualityBits, 'ab12');
    });

    test('hashFor：本地升频档取 320k hash，多轨档取 multitrack hash', () {
      final s = KugouApi.parseSong(fakeSong(transParam: <String, dynamic>{
        'hash_multitrack': 'MULTI123',
      }))!;
      expect(s.hashFor(KugouQuality.viperTape), 'HASH320');
      expect(s.hashFor(KugouQuality.dolby), 'MULTI123');
      expect(s.hashFor(KugouQuality.viperAtmos), 'MULTI123');
      expect(s.hashFor(KugouQuality.k128), 'HASH128');
    });
  });
}
