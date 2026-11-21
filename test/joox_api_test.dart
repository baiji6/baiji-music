// JOOX 音源纯函数契约测试（v2.6.0）。
//
// 网络层不测（需真实接口），这里固化逆向 bai music 4.7 得到的关键契约：
// 搜索响应解析、express 取流解析、QRC 明文 XML 提取、签名算法、音质降级链、
// 路由分发。喂真实 JSON 片段，纯离线。
import 'dart:convert';

import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/joox/joox_api.dart';
import 'package:baiji_music/network/joox/joox_crypto.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:flutter_test/flutter_test.dart';

String _b64(String s) => base64.encode(utf8.encode(s));

void main() {
  group('JooxQuality 定义', () {
    test('6 档且 atmos/master 均为 flac 无解密', () {
      expect(JooxQuality.downloadOptions.length, 6);
      for (final q in JooxQuality.downloadOptions) {
        if (q.id == 'atmos' || q.id == 'master') {
          expect(q.format, 'flac');
          expect(q.ext, '.flac');
        }
      }
      expect(JooxQuality.atmos.code, 'Q0M0');
      expect(JooxQuality.master.code, 'AIM0');
      expect(JooxQuality.k128.code, 'M500');
      expect(JooxQuality.k320.code, 'M800');
      expect(JooxQuality.flac.code, 'F000');
      expect(JooxQuality.hires.code, 'RS01');
    });

    test('无 atmos_plus 档', () {
      expect(JooxQuality.fromId('atmos_plus'), isNull);
    });

    test('从高到低排序，fromId 往返', () {
      expect(JooxQuality.downloadOptions.first.id, 'master');
      expect(JooxQuality.downloadOptions.last.id, '128k');
      for (final q in JooxQuality.downloadOptions) {
        expect(JooxQuality.fromId(q.id), same(q));
      }
    });
  });

  group('jooxDowngradeChain', () {
    test('从中档起向下，末档兜底 128k', () {
      final chain = MusicApi.jooxDowngradeChain(JooxQuality.hires);
      expect(chain.map((q) => q.id).toList(),
          <String>['hires', 'flac', '320k', '128k']);
    });

    test('从最低档起只含 128k', () {
      final chain = MusicApi.jooxDowngradeChain(JooxQuality.k128);
      expect(chain.map((q) => q.id).toList(), <String>['128k']);
    });
  });

  group('搜索响应解析（parseSearchResponse）', () {
    test('真实结构：song_aggregation_list → item_list → song_info', () {
      final body = {
        'song_aggregation_list': [
          {
            'item_list': [
              {
                'song_info': {
                  'songid': '5177785',
                  'songmid': 'ZD6C3E51DA8BE8',
                  'songname': _b64('最長的電影'),
                  'singername': _b64('周杰倫'),
                  'albumname': _b64('我很忙'),
                  'playtime': 235,
                  'vid': 3454775,
                  'album_url': 'https://image.joox.com/JOOXcover/0/abc/1000',
                }
              }
            ]
          }
        ]
      };
      final list = JooxApi.parseSearchResponse(body);
      expect(list.length, 1);
      expect(list.first.songId, '5177785');
      expect(list.first.songMid, 'ZD6C3E51DA8BE8');
      expect(list.first.name, '最長的電影');
      expect(list.first.singer, '周杰倫');
      expect(list.first.album, '我很忙');
      expect(list.first.durationSeconds, 235);
      expect(list.first.cover, contains('image.joox.com'));
    });

    test('空/异常结构不崩', () {
      expect(JooxApi.parseSearchResponse(null), isEmpty);
      expect(JooxApi.parseSearchResponse(<String, dynamic>{}), isEmpty);
      expect(JooxApi.parseSearchResponse({'song_aggregation_list': 'bad'}),
          isEmpty);
    });
  });

  group('取流响应解析（parseExpressResponse）', () {
    test('ok=true 取首个直链', () {
      final body = {
        'ok': true,
        'items': [
          {
            'filename': 'AIM0ZB9234F70CE134.flac',
            'urls': ['http://a/1.flac?vkey=x', 'http://b/1.flac?vkey=x'],
          }
        ]
      };
      final r = JooxApi.parseExpressResponse(body);
      expect(r.url, 'http://a/1.flac?vkey=x');
      expect(r.filename, 'AIM0ZB9234F70CE134.flac');
    });

    test('ok=false / 空 items 返回空', () {
      expect(JooxApi.parseExpressResponse({'ok': false}).url, '');
      expect(JooxApi.parseExpressResponse({'ok': true, 'items': []}).url, '');
      expect(JooxApi.parseExpressResponse(null).url, '');
    });
  });

  group('QRC 明文 XML 提取（extractQrcLyric）', () {
    test('从 LyricContent 属性取出逐字内容并还原转义', () {
      final xml = '<?xml version="1.0"?><QrcInfos><LyricInfo>'
          '<Lyric_1 LyricType="1" LyricContent="[ti:歌]\n'
          '[0,3100]最(0,182)長(182,182) A&amp;B"/></LyricInfo></QrcInfos>';
      final qrc = JooxApi.extractQrcLyric(xml);
      expect(qrc, contains('[0,3100]最(0,182)長(182,182)'));
      expect(qrc, contains('A&B'));
    });

    test('无 LyricContent 返回空', () {
      expect(JooxApi.extractQrcLyric('<QrcInfos/>'), '');
      expect(JooxApi.extractQrcLyric(''), '');
    });
  });

  group('签名算法', () {
    test('jooxTrackSecret 与逆向公式一致', () {
      // MD5("Jo0x@t3Nc3nTcountry=hk&lang=zh_cn&lyric=1&id=5177785")
      expect(jooxTrackSecret('5177785'), '282864968345dbbe237b9d3b8deb0244');
    });

    test('jooxSign 与 HMAC-SHA256 逆向公式一致', () {
      expect(jooxSign('ZB9234F70CE134', 'master', 1795277413000),
          '5e395224892d47b1b2881455888c5674d886444cccefae1fbbb877554ec53e99');
    });
  });

  group('Song 分流', () {
    test('JOOX 歌曲 → Song 后 source/getter 正确', () {
      final s = MusicApi.jooxSongToSong(const JooxSong(
        songId: '5177785',
        songMid: 'ZD6C3E51DA8BE8',
        name: '最長的電影',
        singer: '周杰倫',
      ));
      expect(s.isJoox, isTrue);
      expect(s.isMigu, isFalse);
      expect(s.mid, 'ZD6C3E51DA8BE8');
      expect(s.songId, 5177785);
      expect(s.sourceShort, 'JOOX');
      expect(s.sourceFull, 'JOOX');
    });
  });
}
