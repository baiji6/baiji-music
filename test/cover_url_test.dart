import 'package:baiji_music/core/cover_url.dart';
import 'package:baiji_music/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QQ 音乐封面', () {
    test('默认取 1500 最大档，失败时按 800 → 500 → 300 降级', () {
      final song = Song(
        mid: 'm1',
        songId: 1,
        name: '测试',
        singer: '歌手',
        album: '专辑',
        albumMid: '003DFRzD192KKD',
        duration: 200,
        cover: '',
      );
      final c = CoverUrl.candidates(song);
      expect(c.length, 4);
      expect(c[0],
          'https://y.qq.com/music/photo_new/T002R1500x1500M000003DFRzD192KKD.jpg');
      expect(c[1], contains('T002R800x800M000'));
      expect(c[2], contains('T002R500x500M000'));
      expect(c[3], contains('T002R300x300M000'));
    });

    test('已有 photo_new 地址时只替换尺寸段，其余部分保留', () {
      const raw =
          'https://y.gtimg.cn/music/photo_new/T002R300x300M000003DFRzD192KKD.jpg';
      final song = Song(
        mid: 'm1',
        songId: 1,
        name: 'n',
        singer: 's',
        album: 'a',
        albumMid: 'x',
        duration: 1,
        cover: raw,
      );
      final c = CoverUrl.candidates(song);
      expect(c.first,
          'https://y.gtimg.cn/music/photo_new/T002R1500x1500M000003DFRzD192KKD.jpg');
      // CDN 前缀不能被改写成 y.qq.com
      expect(c.first, startsWith('https://y.gtimg.cn/'));
    });

    test('裸 cover 时至少保留原地址作为唯一候选', () {
      const raw = 'https://example.com/a.jpg';
      final song = Song(
        mid: 'm',
        songId: 1,
        name: 'n',
        singer: 's',
        album: 'a',
        albumMid: '',
        duration: 1,
        cover: raw,
      );
      expect(CoverUrl.candidates(song), <String>[raw]);
    });
  });

  group('网易云封面', () {
    Song ne(String cover) => Song(
          mid: 'm',
          songId: 1,
          name: 'n',
          singer: 's',
          album: 'a',
          albumMid: '',
          duration: 1,
          cover: cover,
          source: 'netease',
        );

    test('默认取 3000 最大档', () {
      final c = CoverUrl.candidates(
          ne('https://p3.music.126.net/abc/123.jpg'));
      expect(c.first, 'https://p3.music.126.net/abc/123.jpg?param=3000y3000');
      expect(c.length, 4);
      expect(c[1], contains('param=1000y1000'));
    });

    test('保留 param 之外的查询参数', () {
      final c = CoverUrl.candidates(
          ne('https://p3.music.126.net/abc/123.jpg?param=100y100&imageView=1'));
      expect(c.first,
          'https://p3.music.126.net/abc/123.jpg?param=3000y3000&imageView=1');
      // 旧 param 不应残留
      expect(c.first, isNot(contains('100y100')));
    });
  });

  group('maximize', () {
    test('QQ 拉到 1500', () {
      expect(
          CoverUrl.maximize(
              'https://y.qq.com/music/photo_new/T002R300x300M00000A.jpg'),
          'https://y.qq.com/music/photo_new/T002R1500x1500M00000A.jpg');
    });

    test('网易云拉到 3000 并保留其它参数', () {
      expect(
          CoverUrl.maximize(
              'https://p3.music.126.net/x/1.jpg?param=200y200&imageView=2'),
          'https://p3.music.126.net/x/1.jpg?param=3000y3000&imageView=2');
    });

    test('无法识别时原样返回', () {
      const url = 'https://example.com/cover.webp';
      expect(CoverUrl.maximize(url), url);
      expect(CoverUrl.maximize(''), '');
    });
  });
}
