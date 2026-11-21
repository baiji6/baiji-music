// 汽水音乐音源纯函数契约测试（v2.6.1）。
//
// 网络层不测（需真实接口），这里固化关键契约：
// 搜索响应解析、取流响应解析、krc→YRC 逐字格式转换、单档音质、路由分发。
// 喂真实 JSON / krc 片段，纯离线。
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:baiji_music/network/qishui/qishui_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QishuiQuality 定义', () {
    test('匿名通道仅 medium 单档', () {
      expect(QishuiQuality.downloadOptions.length, 1);
      expect(QishuiQuality.medium.id, 'medium');
      expect(QishuiQuality.medium.format, 'm4a');
      expect(QishuiQuality.medium.ext, '.m4a');
      expect(QishuiQuality.playbackDefault, same(QishuiQuality.medium));
    });

    test('fromId 往返', () {
      expect(QishuiQuality.fromId('medium'), same(QishuiQuality.medium));
      expect(QishuiQuality.fromId('hires'), isNull);
      expect(QishuiQuality.fromId(null), isNull);
    });
  });

  group('qishuiDowngradeChain', () {
    test('永远只有 medium 单档', () {
      expect(MusicApi.qishuiDowngradeChain(QishuiQuality.medium)
          .map((q) => q.id)
          .toList(), <String>['medium']);
    });
  });

  group('搜索响应解析（parseSearchResponse）', () {
    test('真实结构：data.list[] → item_id/title/author_info.name/cover_url', () {
      final body = {
        'errno': 0,
        'data': {
          'list': [
            {
              'item_id': '7706108005905319974',
              'title': '等你下课（杰伦）',
              'author_info': {'name': '孤独0321'},
              'duration': 220,
              'cover_url':
                  'https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/abc~tplv.image',
              'media_type': 'music',
            },
            {
              'item_id': '6732899843179546625',
              'title': '蜗牛',
              'author_info': {'name': '动力火车'},
              'duration': 308,
              'cover_url': 'https://p6-luna.douyinpic.com/img/xyz.image',
            },
          ],
          'search_params': '{"offset":10}',
        }
      };
      final list = QishuiApi.parseSearchResponse(body);
      expect(list.length, 2);
      expect(list.first.itemId, '7706108005905319974');
      expect(list.first.name, '等你下课（杰伦）');
      expect(list.first.singer, '孤独0321');
      expect(list.first.durationSeconds, 220);
      expect(list.first.cover, contains('douyinpic.com'));
      expect(list.last.singer, '动力火车');
    });

    test('空/异常结构不崩', () {
      expect(QishuiApi.parseSearchResponse(null), isEmpty);
      expect(QishuiApi.parseSearchResponse(<String, dynamic>{}), isEmpty);
      expect(QishuiApi.parseSearchResponse({'data': {'list': 'bad'}}), isEmpty);
    });
  });

  group('取流响应解析（parseStreamResponse）', () {
    test('code=0 取直链 + 自带 LRC + 封面 1080', () {
      final body = {
        'code': 0,
        'msg': 'ok',
        'data': {
          'url': 'https://sf6-cdn-tos.douyinstatic.com/obj/tos-cn-ve-2774/abc',
          'urls': [
            'https://sf6-cdn-tos.douyinstatic.com/obj/tos-cn-ve-2774/abc',
            'https://sf3-cdn-tos.douyinstatic.com/obj/tos-cn-ve-2774/abc',
          ],
          'actual_quality': 'medium',
          'encrypted': false,
          'title': '骄傲的少年',
          'artist': '南征北战NZBZ',
          'duration': 259.626,
          'cover': 'https://p3-luna.douyinpic.com/img/def:0:1080.image',
          'covers': {
            '360': 'https://p3-luna.douyinpic.com/img/def:0:360.image',
            '1080': 'https://p3-luna.douyinpic.com/img/def:0:1080.image',
          },
          'lyric': {
            'type': 'krc',
            'source': 'seo_track',
            'lrc': '[00:21.860]在一开始\n[00:24.240]当初我还是',
            'lines': [],
          },
        }
      };
      final r = QishuiApi.parseStreamResponse(body);
      expect(r.url, contains('douyinstatic.com'));
      expect(r.urls.length, 2);
      expect(r.actualQuality, 'medium');
      expect(r.title, '骄傲的少年');
      expect(r.lrc, contains('在一开始'));
      expect(r.cover, contains(':0:1080.image'));
      expect(r.durationSeconds, 259);
    });

    test('code!=0 / url 空返回空', () {
      expect(QishuiApi.parseStreamResponse({'code': 502}).url, '');
      expect(QishuiApi.parseStreamResponse({'code': 0, 'data': {}}).url, '');
      expect(QishuiApi.parseStreamResponse(null).url, '');
    });
  });

  group('krc → YRC 逐字转换（krcToYrc）', () {
    test('相对偏移加行起始时间变绝对，尖括号转圆括号', () {
      // 汽水 krc：字偏移相对行首，尖括号
      const krc = '[21860,1630]<0,250,0>在<250,220,0>一<470,180,0>开';
      final yrc = QishuiApi.krcToYrc(krc);
      // 期望 YRC：字起始绝对时间，圆括号
      expect(yrc,
          '[21860,1630](21860,250,0)在(22110,220,0)一(22330,180,0)开');
    });

    test('多行 + 元信息行保留', () {
      const krc = '[ti:歌名]\n[1000,2000]<0,500,0>你<500,500,0>好';
      final yrc = QishuiApi.krcToYrc(krc);
      expect(yrc, contains('[ti:歌名]'));
      expect(yrc, contains('(1000,500,0)你'));
      expect(yrc, contains('(1500,500,0)好'));
    });

    test('XML 实体还原', () {
      const krc = '[0,1000]<0,1000,0>A&amp;B';
      final yrc = QishuiApi.krcToYrc(krc);
      expect(yrc, contains('A&B'));
    });

    test('空输入返回空', () {
      expect(QishuiApi.krcToYrc(''), '');
      expect(QishuiApi.krcToYrc('   '), '');
    });
  });

  group('Song 分流', () {
    test('汽水歌曲 → Song 后 source/getter 正确且单档标记', () {
      final s = MusicApi.qishuiSongToSong(const QishuiSong(
        itemId: '7120513872380823590',
        name: '骄傲的少年',
        singer: '南征北战NZBZ',
        durationSeconds: 259,
      ));
      expect(s.isQishui, isTrue);
      expect(s.isJoox, isFalse);
      expect(s.mid, '7120513872380823590');
      expect(s.songId, 7120513872380823590);
      expect(s.sourceShort, '汽水');
      expect(s.sourceFull, '汽水音乐');
      expect(s.qualityCodes, <String>{'medium'});
    });
  });

  group('Source 常量', () {
    test('汽水 source 独立不冲突', () {
      expect(Source.qishui, 'qishui');
      expect(Source.qishui == Source.joox, isFalse);
    });
  });
}
