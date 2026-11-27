// QQ 音乐 2 纯函数测试（v2.6.5）。
//
// 网络部分（search/cover/getStream）依赖外部服务，不进 CI；这里覆盖
// 响应解析、音质反查/降级链与 Song 映射等所有可离线验证的契约。
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:baiji_music/network/qq2/qq2_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('搜索响应解析', () {
    test('正常列表逐字段映射', () {
      final list = Qq2Api.parseSearchResponse({
        'code': 200,
        'data': [
          {
            'id': 154764,
            'mid': '0031mDbk0RU4CX',
            'name': '皇后大道东',
            'artist': '罗大佑、蒋志光',
            'album': '',
            'albummid': '',
          },
          {
            'id': 8523,
            'mid': '001372gx4Taqcf',
            'name': '皇后大道东',
            'artist': '罗大佑',
          },
        ],
      });
      expect(list, hasLength(2));
      expect(list.first.mid, '0031mDbk0RU4CX');
      expect(list.first.id, 154764);
      expect(list.first.singer, '罗大佑、蒋志光');
      expect(list.first.album, '');
      expect(list.last.albumMid, '');
    });

    test('异常/空响应不抛错', () {
      expect(Qq2Api.parseSearchResponse(null), isEmpty);
      expect(Qq2Api.parseSearchResponse(<String, dynamic>{}), isEmpty);
      expect(Qq2Api.parseSearchResponse({'data': 'x'}), isEmpty);
      expect(Qq2Api.parseSearchResponse({'data': [42]}), isEmpty);
    });

    test('缺 mid 的条目被丢弃', () {
      final list = Qq2Api.parseSearchResponse({
        'data': [
          {'name': '无 mid'},
          {'mid': '', 'name': '空 mid'},
          {'mid': 'ok', 'name': '保留'},
        ],
      });
      expect(list, hasLength(1));
      expect(list.single.mid, 'ok');
    });
  });

  group('封面响应解析与尺寸降级', () {
    test('正常响应取到 artwork 直链', () {
      expect(
        Qq2Api.parseCoverResponse({
          'code': 0,
          'data': {
            'artwork': 'https://y.gtimg.cn/T002R1500x1500M000xxx.jpg',
            'coverType': 'album',
          },
        }),
        'https://y.gtimg.cn/T002R1500x1500M000xxx.jpg',
      );
    });

    test('code 非 0 / data 缺失 / artwork 空 → null（触发降级）', () {
      expect(Qq2Api.parseCoverResponse({'code': -1, 'data': {'artwork': 'x'}}),
          isNull);
      expect(Qq2Api.parseCoverResponse({'code': 0, 'data': null}), isNull);
      expect(Qq2Api.parseCoverResponse({'code': 0, 'data': {}}), isNull);
      expect(Qq2Api.parseCoverResponse({'code': 0, 'data': {'artwork': ''}}),
          isNull);
      expect(Qq2Api.parseCoverResponse('not a map'), isNull);
      expect(Qq2Api.parseCoverResponse(null), isNull);
    });

    test('尺寸链从大到小，含 1500/1200/800/500/300', () {
      expect(Qq2Api.coverSizes,
          <int>[1500, 1200, 800, 500, 300]);
    });
  });

  group('音质档位', () {
    test('26 个 level 与文档一致（加密前缀）', () {
      expect(Qq2Quality.downloadOptions, hasLength(26));
      expect(
        Qq2Quality.downloadOptions.map((q) => q.code).toList(),
        [
          'DTM3', 'AIM0', 'V0M0', 'Q0M3', 'Q0M1', 'Q0M0',
          'RAM4', 'RAM3', 'RAM2', 'RAM1',
          'D0M9', 'D0M8', 'D0M7', 'D0M6', 'D0M5', 'D0M4', 'D0M3', 'D0M2', 'D0M1',
          'RSM1', 'TLM1', 'F0M0',
          'O8M0', 'O8M1', 'O6M0', 'O4M0',
        ],
      );
      expect(Qq2Quality.fromId('F0M0')!.label, 'flac');
      expect(Qq2Quality.fromId('unknown'), isNull);
    });

    test('v2.6.8 新增档位的加密前缀与解密后缀', () {
      expect(Qq2Quality.fromId('O8M1')!.ext, '.ogg'); // ogg640
      expect(Qq2Quality.fromId('TLM1')!.ext, '.nac'); // nac
      expect(Qq2Quality.fromId('Q0M3')!.ext, '.ogg'); // 臻品全景声3.0
      expect(Qq2Quality.fromId('V0M0')!.ext, '.flac'); // 黑胶
      expect(Qq2Quality.fromId('DTM3')!.ext, '.mp4'); // dts:x
      expect(Qq2Quality.fromId('RAM4')!.label, '360RA-4');
      expect(Qq2Quality.fromId('D0M9')!.label, 'dolby-9');
      // fromUrl 从加密前缀反查（360RA / dts）
      expect(
        Qq2Quality.fromUrl(
                'https://aqqmusic.tc.qq.com/RAM4001eGhxQ2Yl7zo.mmp4?vkey=X')
            !.code,
        'RAM4',
      );
      expect(
        Qq2Quality.fromUrl(
                'https://aqqmusic.tc.qq.com/DTM3001eGhxQ2Yl7zo.mmp4?vkey=X')
            !.ext,
        '.mp4',
      );
    });

    test('从直链文件名前缀反查实际档（服务端降级可识别）', () {
      expect(
        Qq2Quality.fromUrl(
                'https://aqqmusic.tc.qq.com/Q0M1002sCKXO2m18hy.mflac?guid=&vkey=X')
            !.code,
        'Q0M1',
      );
      expect(
        Qq2Quality.fromUrl(
                'https://aqqmusic.tc.qq.com/F0M00030gjVq15aShh.mflac?vkey=X')
            !.ext,
        '.flac',
      );
      expect(
        Qq2Quality.fromUrl(
                'https://aqqmusic.tc.qq.com/O6M0003ae8GI3mQimV.mgg?vkey=X')
            !.ext,
        '.ogg',
      );
      expect(Qq2Quality.fromUrl('https://x/y'), isNull);
    });

    test('level 参数映射为 qmc.php 档位名', () {
      expect(Qq2Api.levelOf(Qq2Quality.lossless), 'lossless');
      expect(Qq2Api.levelOf(Qq2Quality.zpqj), 'zpqj');
      expect(Qq2Api.levelOf(Qq2Quality.jymaster), 'jymaster');
      // v2.6.8 新增档位
      expect(Qq2Api.levelOf(Qq2Quality.ogg640), 'ogg640');
      expect(Qq2Api.levelOf(Qq2Quality.nac), 'nac');
      expect(Qq2Api.levelOf(Qq2Quality.dolby9), 'dolby9');
      expect(Qq2Api.levelOf(Qq2Quality.ra4), 'ra4');
      expect(Qq2Api.levelOf(Qq2Quality.zpqj3), 'zpqj3');
      expect(Qq2Api.levelOf(Qq2Quality.vinyl), 'vinyl');
      expect(Qq2Api.levelOf(Qq2Quality.dts), 'dts');
      expect(Qq2Api.levelOf(const Quality('XX', '.mp3', '', 0)), 'standard');
    });

    test('降级链只向下且末档为 low', () {
      final chain = Qq2Quality.downgradeChain(Qq2Quality.zpqj);
      expect(chain.first.code, 'Q0M1');
      expect(chain.last.code, 'O4M0');
      expect(chain.map((q) => q.code), contains('F0M0'));
      expect(chain.map((q) => q.code), isNot(contains('AIM0')));
      expect(Qq2Quality.downgradeChain(Qq2Quality.low), hasLength(1));
      expect(Qq2Quality.downgradeChain(const Quality('XX', '.mp3', '', 0)),
          hasLength(2));
    });
  });

  group('Song 映射', () {
    test('QQ2 歌曲标记为独立音源且保留 mid', () {
      final s = MusicApi.qq2SongToSong(
        const Qq2Song(
          mid: '0031mDbk0RU4CX',
          id: 154764,
          name: '皇后大道东',
          singer: '罗大佑、蒋志光',
        ),
        cover: 'https://y.gtimg.cn/art.jpg',
      );
      expect(s.source, Source.qq2);
      expect(s.isQq2, isTrue);
      expect(s.source, isNot(Source.qq));
      expect(s.mid, '0031mDbk0RU4CX');
      expect(s.songId, 154764);
      expect(s.cover, 'https://y.gtimg.cn/art.jpg');
      expect(s.sourceShort, 'QQ2');
      expect(s.sourceFull, 'QQ 音乐 2');
    });
  });
}
