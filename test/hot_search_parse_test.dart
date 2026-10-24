// 热搜 / 热门歌单解析（#142）：三平台字段名不同，之前统一按 word/count
// 解析导致 QQ、网易云读成空串被过滤掉，热搜榜一片空白。
//
// 用例里的样本是 2026-10 真实抓包（已裁剪），字段形状与线上一致。
import 'package:baiji_music/network/hot_search_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('#142 QQ 热搜词（k / n）', () {
    test('解析出词与热度', () {
      final j = <String, dynamic>{'k': '我们的歌 ', 'n': 765562};
      final kw = HotKeyword.fromQq(j);
      expect(kw.word, '我们的歌');
      expect(kw.count, '765562');
    });

    test('空词会被过滤（真实响应里不会出现）', () {
      final list = <Map<String, dynamic>>[
        {'k': '', 'n': 1},
        {'k': '张杰', 'n': 2},
      ].map(HotKeyword.fromQq).where((e) => e.word.isNotEmpty).toList();
      expect(list.length, 1);
      expect(list.single.word, '张杰');
    });
  });

  group('#142 网易云热搜词（first / second）', () {
    test('取 first 作词，second 不当次数展示', () {
      final j = <String, dynamic>{
        'first': '第五人格',
        'second': 1,
        'third': null,
        'iconType': 1,
      };
      final kw = HotKeyword.fromNetease(j);
      expect(kw.word, '第五人格');
      expect(kw.count, isNull,
          reason: 'second 是热度档位（几乎都是 1），当次数展示没有意义');
    });
  });

  test('通用 fromJson 容错：三种字段名都认', () {
    expect(HotKeyword.fromJson({'word': 'a'}).word, 'a');
    expect(HotKeyword.fromJson({'k': 'b'}).word, 'b');
    expect(HotKeyword.fromJson({'first': 'c'}).word, 'c');
    expect(HotKeyword.fromJson({'n': 12}).count, '12');
  });

  group('#143 热门歌单字段', () {
    test('QQ：dissid / dissname / imgurl / creator.name / listennum', () {
      final j = <String, dynamic>{
        'dissid': '7707261125',
        'createtime': '2020-09-06',
        'dissname': '甜度爆表 | 旋律说唱狙击少女心',
        'imgurl': 'http://qpic.y.qq.com/music_cover/xxx/300?n=1',
        'listennum': 8555208,
        'creator': {
          'type': 0,
          'qq': 3509852917,
          'name': '某某',
          'isVip': 0,
        },
      };
      final p = HotPlaylist.fromQq(j);
      expect(p.id, '7707261125');
      expect(p.name, '甜度爆表 | 旋律说唱狙击少女心');
      expect(p.creator, '某某');
      expect(p.playCount, '8555208');
      expect(p.cover.startsWith('https://'), isTrue,
          reason: 'http 明文封面在 Android 9+ 加载不了，必须转 https');
    });

    test('网易云：id / name / coverImgUrl / creator.nickname / trackCount', () {
      final j = <String, dynamic>{
        'name': '倾吐隐秘情绪｜百位R&B歌手精选',
        'id': 2936255937,
        'trackCount': 300,
        'playCount': 12345678,
        'coverImgUrl': 'http://p1.music.126.net/xxx.jpg',
        'creator': {'userId': 1, 'nickname': '蜜糖男孩'},
      };
      final p = HotPlaylist.fromNetease(j);
      expect(p.id, '2936255937');
      expect(p.name, '倾吐隐秘情绪｜百位R&B歌手精选');
      expect(p.creator, '蜜糖男孩');
      expect(p.playCount, '12345678');
      expect(p.trackCount, 300);
      expect(p.cover.startsWith('https://'), isTrue);
    });

    test('creator 是字符串时也能兜住', () {
      expect(HotPlaylist.fromQq({'dissid': '1', 'creator': '小明'}).creator,
          '小明');
      expect(
          HotPlaylist.fromNetease({'id': '1', 'creator': '小红'}).creator,
          '小红');
    });

    test('https 封面不会被二次改写', () {
      expect(
          HotPlaylist.fromNetease(
              {'id': '1', 'coverImgUrl': 'https://x/1.jpg'}).cover,
          'https://x/1.jpg');
    });
  });
}
