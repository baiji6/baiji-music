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
    test('9 个 level 与文档一致', () {
      expect(
        Qq2Quality.downloadOptions.map((q) => q.code).toList(),
        [
          'AIM0', 'Q0M1', 'Q0M0', 'RSM1', 'F0M0',
          'O8M0', 'O6M0', 'D0M1', 'O4M0',
        ],
      );
      expect(Qq2Quality.fromId('F0M0')!.label, '无损音质');
      expect(Qq2Quality.fromId('unknown'), isNull);
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
