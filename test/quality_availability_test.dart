// 音质列表「按歌曲实际有的音质展示」回归测试（v2.4.9）。
// 全部离线：用真实接口响应片段驱动解析，不联网、不依赖平台通道。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/kuwo/kuwo_api.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:baiji_music/network/netease/netease_api.dart';
import 'package:baiji_music/network/netease/netease_client.dart';

// QQ 搜索接口真实 track_info.file（「晴天 周杰伦」，2026-11 抓取）。
// 这首歌：128/320/flac/aac/ogg 有，Hi-Res / DTS / 杜比 / 360RA 都没有，
// size_new 里有母带、臻品 2.0、全景声 5.1、OGG320/640、全景声 7.1、NAC。
const String _qqFileJson = '''
{"b_30s":0,"df":[],"e_30s":60000,"hires_bitdepth":0,"hires_sample":0,
"media_mid":"003Qui1q2u1Zho","size_128mp3":4317292,"size_192aac":6519764,
"size_192ogg":5860576,"size_24aac":0,"size_320mp3":10792943,"size_360ra":[],
"size_48aac":1642440,"size_96aac":3283546,"size_96ogg":2927865,"size_ape":0,
"size_dolby":0,"size_dts":0,"size_flac":55397039,"size_hires":0,
"size_new":[186980254,31168013,80437198,10331568,0,23183008,36638639,
2563200,58805051,0,0,0,28055659,0,0,0],
"size_try":960887,"try_begin":84346,"try_end":142843,"url":"","vm":[]}
''';

// 另一首带杜比全景声（size_dolby > 0），且 size_new 位图不同。
const String _qqFileDolbyJson = '''
{"media_mid":"002DMfDx1macLz","size_128mp3":3997575,"size_192aac":6051053,
"size_192ogg":5447636,"size_320mp3":9993618,"size_360ra":[],
"size_48aac":1520767,"size_96aac":3042719,"size_96ogg":2789256,
"size_dolby":8026443,"size_dts":0,"size_flac":54393782,"size_hires":0,
"size_new":[169477025,0,0,9387289,0,19478996,0,2374452,55794271,
0,14028904,46890410,25978667,0,0,0]}
''';

// 网易云搜索接口真实 song.privilege（「晴天 周杰伦」，2026-11 抓取）。
const String _nePrivilegeJson = '''
{"flag":3641604,"code":0,"dlLevel":"none","subp":1,"fl":320000,"fee":8,
"dl":0,"plLevel":"exhigh","maxBrLevel":"vivid","rightSource":0,
"maxbr":999000,"playMaxBrLevel":"vivid","playMaxbr":999000,
"flLevel":"exhigh","pl":320000}
''';

void main() {
  group('QQ：file.size_* + size_new 位图 → 可用音质 code', () {
    test('无高档音源的歌曲：命名字段与 size_new 都正确解析', () {
      final f = jsonDecode(_qqFileJson) as Map<String, dynamic>;
      final codes = Quality.availableCodesFrom(f);

      // 命名字段：有的要出现
      expect(codes, containsAll(<String>[
        Quality.mp3_128.code, // M500
        Quality.mp3_320.code, // M800
        Quality.flac.code, // F000
        Quality.aac48.code, // C200
        Quality.aac96.code, // C400
        Quality.aac192.code, // C600
        Quality.ogg192.code, // O600
      ]));
      // 命名字段：明确为 0 的要隐藏
      expect(codes, isNot(contains(Quality.hires.code))); // RS01
      expect(codes, isNot(contains(Quality.dtsX.code))); // DT03
      for (final c in <String>[
        Quality.atmosDb.code,
        Quality.atmosEac3.code,
        Quality.atmosEac3Plus.code,
        Quality.atmosEac3Lite.code,
        Quality.ra360a.code,
        Quality.ra360b.code,
        Quality.ra360c.code,
        Quality.ra360d.code,
      ]) {
        expect(codes, isNot(contains(c)), reason: '不应出现 $c');
      }

      // size_new 位图：非零索引对应的高级档位
      expect(codes, containsAll(<String>[
        Quality.master.code, // [0] AI00 臻品母带
        Quality.atmos2.code, // [1] Q000 臻品音质 2.0
        Quality.atmos51.code, // [2] Q001 全景声 5.1
        Quality.ogg320.code, // [3] O800
        Quality.ogg640.code, // [5] O801
        Quality.atmos71.code, // [6] Q003 全景声 7.1
        Quality.nac.code, // [7] TL01
      ]));
      expect(codes, isNot(contains(Quality.vinylVip.code))); // [4] = 0
    });

    test('带杜比全景声的歌曲：4 档杜比都列出', () {
      final f = jsonDecode(_qqFileDolbyJson) as Map<String, dynamic>;
      final codes = Quality.availableCodesFrom(f);
      expect(codes, containsAll(<String>[
        Quality.atmosEac3Lite.code,
        Quality.atmosEac3.code,
        Quality.atmosEac3Plus.code,
        Quality.atmosDb.code,
      ]));
      expect(codes, isNot(contains(Quality.atmos51.code))); // size_new[2]=0
      expect(codes, isNot(contains(Quality.atmos71.code))); // size_new[6]=0
    });

    test('360RA 数组按非空元素给出 RA 档位', () {
      final codes = Quality.availableCodesFrom(<String, dynamic>{
        'size_360ra': <int>[0, 12345, 0, 67890],
      });
      expect(codes, contains(Quality.ra360b.code));
      expect(codes, contains(Quality.ra360d.code));
      expect(codes, isNot(contains(Quality.ra360a.code)));
      expect(codes, isNot(contains(Quality.ra360c.code)));
    });

    test('无 file / 空 Map 时返回空集合（调用方回退全量）', () {
      expect(Quality.availableCodesFrom(null), isEmpty);
      expect(Quality.availableCodesFrom('bad'), isEmpty);
      expect(Quality.availableCodesFrom(<String, dynamic>{}), isEmpty);
    });

    test('Song.fromTrack 把 file 标记带进 qualityCodes', () {
      final song = Song.fromTrack(<String, dynamic>{
        'mid': '003Qui1q2u1Zho',
        'id': 266839735,
        'name': '晴天',
        'file': jsonDecode(_qqFileJson),
      });
      expect(song.qualityCodes, contains(Quality.flac.code));
      expect(song.qualityCodes, contains(Quality.master.code));
      expect(song.qualityCodes, isNot(contains(Quality.dtsX.code)));
    });
  });

  group('网易云：privilege → 可用 level', () {
    test('maxBrLevel=vivid：基础档 + 无损 + Hi-Res + vivid，不虚报其它空间音质', () {
      final song = <String, dynamic>{
        'privilege': jsonDecode(_nePrivilegeJson),
        'sq': <String, dynamic>{'br': 999000},
        'hr': <String, dynamic>{'br': 1394128},
      };
      final levels = NeteaseQuality.availableLevelsFrom(song);
      expect(levels, containsAll(<String>[
        NeteaseQuality.standard.level,
        NeteaseQuality.exhigh.level,
        NeteaseQuality.lossless.level,
        NeteaseQuality.hires.level,
        NeteaseQuality.vivid.level,
      ]));
      expect(levels, isNot(contains(NeteaseQuality.dolby.level)));
      expect(levels, isNot(contains(NeteaseQuality.sky.level)));
      expect(levels, isNot(contains(NeteaseQuality.jymaster.level)));
      expect(levels, isNot(contains(NeteaseQuality.jyeffect.level)));
    });

    test('只有 320k 权限且无 sq/hr：只显示标准与极高', () {
      final levels = NeteaseQuality.availableLevelsFrom(<String, dynamic>{
        'privilege': <String, dynamic>{
          'playMaxBrLevel': 'exhigh',
          'maxBrLevel': 'exhigh',
          'flLevel': 'exhigh',
          'plLevel': 'exhigh',
        },
      });
      expect(levels, equals(<String>{
        NeteaseQuality.standard.level,
        NeteaseQuality.exhigh.level,
      }));
    });

    test('无 privilege / 未知 level 时返回空集合（回退全量）', () {
      expect(NeteaseQuality.availableLevelsFrom(<String, dynamic>{}), isEmpty);
      expect(
        NeteaseQuality.availableLevelsFrom(<String, dynamic>{
          'privilege': <String, dynamic>{'playMaxBrLevel': 'none'},
        }),
        isEmpty,
      );
    });

    test('NeteaseApi.toSong 把标记带进 Song', () {
      // toSong 需要最小歌曲对象；用 NeteaseApi 实例调用。
      final api = NeteaseApi(NeteaseClient());
      final song = api.toSong(<String, dynamic>{
        'id': 266839735,
        'name': '晴天',
        'privilege': jsonDecode(_nePrivilegeJson),
        'hr': <String, dynamic>{'br': 1394128},
      });
      expect(song, isNotNull);
      expect(song!.qualityCodes, contains(NeteaseQuality.vivid.level));
      expect(song.qualityCodes, contains(NeteaseQuality.hires.level));
      expect(song.qualityCodes, isNot(contains(NeteaseQuality.dolby.level)));
    });
  });

  group('酷我：KuwoSong.qualities → Song.qualityCodes', () {
    test('只带入这首歌实际有的档位', () {
      final k = KuwoSong(
        rid: '123456',
        name: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        pic: '',
        durationSeconds: 269,
        qualities: <KuwoQuality>[
          KuwoQuality.flac,
          KuwoQuality.mp3_128,
        ],
      );
      final song = MusicApi.kuwoSongToSong(k);
      expect(song.source, Source.kuwo);
      expect(song.qualityCodes,
          equals(<String>{KuwoQuality.flac.id, KuwoQuality.mp3_128.id}));
      expect(song.qualityCodes, isNot(contains(KuwoQuality.master.id)));
    });
  });

  group('filterQualityOptions：过滤与回退', () {
    test('codes 为空时回退全量', () {
      expect(
        filterQualityOptions(const <String>{}, Quality.downloadOptions,
            (q) => q.code),
        same(Quality.downloadOptions),
      );
    });

    test('codes 非空时只留标记存在的档位，且保持原顺序', () {
      final out = filterQualityOptions(
        <String>{Quality.mp3_128.code, Quality.flac.code},
        Quality.downloadOptions,
        (q) => q.code,
      );
      expect(out, equals(<Quality>[Quality.flac, Quality.mp3_128]));
    });

    test('过滤结果为空时也回退全量，避免弹层空白', () {
      expect(
        filterQualityOptions(<String>{'NOT_A_CODE'}, Quality.downloadOptions,
            (q) => q.code),
        same(Quality.downloadOptions),
      );
    });

    test('三个平台的 codeOf 都能正确过滤', () {
      expect(
        filterQualityOptions(<String>{NeteaseQuality.lossless.level},
            NeteaseQuality.downloadOptions, (q) => q.level),
        equals(<NeteaseQuality>[NeteaseQuality.lossless]),
      );
      expect(
        filterQualityOptions(<String>{KuwoQuality.flac.id},
            KuwoQuality.downloadOptions, (q) => q.id),
        equals(<KuwoQuality>[KuwoQuality.flac]),
      );
    });
  });

  group('Song.qualityCodes 持久化与 copyWith', () {
    test('toJson → fromJson 往返不丢失，旧数据无该字段时为空集合', () {
      final s = Song(
        mid: 'abc',
        songId: 1,
        name: '晴天',
        singer: '周杰伦',
        album: '',
        albumMid: '',
        duration: 269000,
        cover: '',
        qualityCodes: <String>{Quality.flac.code, Quality.master.code},
      );
      final restored = Song.fromJson(jsonDecode(jsonEncode(s.toJson()))
          as Map<String, dynamic>);
      expect(restored.qualityCodes, s.qualityCodes);

      final legacy = Song.fromJson(<String, dynamic>{'mid': 'old'});
      expect(legacy.qualityCodes, isEmpty);
    });

    test('copyWith 可覆盖 qualityCodes', () {
      final s = Song(
        mid: 'abc',
        songId: 1,
        name: 'x',
        singer: '',
        album: '',
        albumMid: '',
        duration: 0,
        cover: '',
        qualityCodes: <String>{Quality.mp3_128.code},
      );
      expect(s.copyWith(qualityCodes: <String>{Quality.flac.code}).qualityCodes,
          equals(<String>{Quality.flac.code}));
      expect(s.copyWith().qualityCodes, equals(<String>{Quality.mp3_128.code}));
    });
  });
}
