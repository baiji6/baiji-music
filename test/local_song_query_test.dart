import 'package:baiji_music/local/local_song_query.dart';
import 'package:baiji_music/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Song _s(
  String name, {
  String singer = '',
  String album = '',
  int duration = 0,
  int size = 0,
  int mtime = 0,
  String format = '',
  String path = '',
}) =>
    Song(
      mid: 'm$name$singer$album',
      songId: 0,
      name: name,
      singer: singer,
      album: album,
      albumMid: '',
      duration: duration,
      cover: '',
      localPath: path.isEmpty ? '/music/$singer - $name.mp3' : path,
      localSize: size,
      localMtime: mtime,
      format: format,
    );

void main() {
  group('LocalSongQuery.filter', () {
    final songs = [
      _s('晴天', singer: '周杰伦', album: '叶惠美'),
      _s('七里香', singer: '周杰伦', album: '叶惠美'),
      _s('红豆', singer: '王菲', album: '唱吧'),
      _s('Instrumental', singer: 'Unknown', album: ''),
    ];

    test('空关键词返回原列表', () {
      expect(LocalSongQuery.filter(songs, ''), same(songs));
      expect(LocalSongQuery.filter(songs, '   '), same(songs));
    });

    test('按歌名匹配（忽略大小写）', () {
      final r = LocalSongQuery.filter(songs, '晴天');
      expect(r.length, 1);
      expect(r.first.name, '晴天');
    });

    test('按歌手匹配可命中多首', () {
      final r = LocalSongQuery.filter(songs, '周杰伦');
      expect(r.length, 2);
    });

    test('按专辑匹配', () {
      final r = LocalSongQuery.filter(songs, '叶惠美');
      expect(r.length, 2);
    });

    test('英文字母忽略大小写', () {
      final r = LocalSongQuery.filter(songs, 'instrumental');
      expect(r.length, 1);
    });

    test('空格分隔的多关键词是「与」关系', () {
      final r = LocalSongQuery.filter(songs, '周杰伦 七里香');
      expect(r.length, 1);
      expect(r.first.name, '七里香');
    });

    test('文件名也在搜索范围内', () {
      final withPath = [
        _s('无标题', singer: '甲', path: '/music/misc/现场录音.wav'),
      ];
      expect(LocalSongQuery.filter(withPath, '现场录音').length, 1);
    });

    test('无匹配返回空列表', () {
      expect(LocalSongQuery.filter(songs, '不存在的歌'), isEmpty);
    });

    test('查询不会改动原列表', () {
      LocalSongQuery.filter(songs, '晴天');
      expect(songs.length, 4);
    });
  });

  group('LocalSongQuery.sort', () {
    test('按标题升序 / 降序', () {
      final songs = [_s('B'), _s('A'), _s('C')];
      expect(LocalSongQuery.sort(songs, LocalSortKey.title).map((e) => e.name),
          ['A', 'B', 'C']);
      expect(LocalSongQuery.sort(songs, LocalSortKey.title, desc: true).map((e) => e.name),
          ['C', 'B', 'A']);
    });

    test('按歌手排序时同歌手内按标题排', () {
      final songs = [
        _s('第二', singer: 'A组'),
        _s('第一', singer: 'A组'),
        _s('唯一', singer: 'B组'),
      ];
      final r = LocalSongQuery.sort(songs, LocalSortKey.singer);
      expect(r.map((e) => e.name), ['第一', '第二', '唯一']);
    });

    test('中文按 Unicode 码位排序（不引pinyin 依赖，行为确定即可）', () {
      // 乙 U+4E59 < 甲 U+7532，所以「乙组」排在「甲组」前面。
      // 这里锁定的是「顺序确定、不依赖本地化库」这一契约。
      final songs = [_s('x', singer: '甲组'), _s('y', singer: '乙组')];
      expect(LocalSongQuery.sort(songs, LocalSortKey.singer).first.singer, '乙组');
    });

    test('按专辑排序', () {
      final songs = [_s('x', album: 'B专辑'), _s('y', album: 'A专辑')];
      expect(LocalSongQuery.sort(songs, LocalSortKey.album).first.album, 'A专辑');
    });

    test('按时长排序，时长 0 沉到最后', () {
      final songs = [
        _s('未知时长', duration: 0),
        _s('短', duration: 60000),
        _s('长', duration: 300000),
      ];
      final r = LocalSongQuery.sort(songs, LocalSortKey.duration);
      expect(r.map((e) => e.name), ['短', '长', '未知时长']);
    });

    test('按时长降序时，未知时长仍在最后', () {
      final songs = [
        _s('未知时长', duration: 0),
        _s('短', duration: 60000),
        _s('长', duration: 300000),
      ];
      final r = LocalSongQuery.sort(songs, LocalSortKey.duration, desc: true);
      expect(r.last.name, '未知时长');
    });

    test('按修改时间排序', () {
      final songs = [
        _s('旧', mtime: 1000),
        _s('新', mtime: 9999),
      ];
      expect(LocalSongQuery.sort(songs, LocalSortKey.date).first.name, '旧');
    });

    test('按文件大小排序', () {
      final songs = [
        _s('大', size: 900),
        _s('小', size: 100),
      ];
      expect(LocalSongQuery.sort(songs, LocalSortKey.size).first.name, '小');
    });

    test('按格式排序，同格式内按标题', () {
      final songs = [
        _s('b', format: 'mp3'),
        _s('a', format: 'flac'),
        _s('c', format: 'mp3'),
      ];
      final r = LocalSongQuery.sort(songs, LocalSortKey.format);
      expect(r.map((e) => e.name), ['a', 'b', 'c']);
    });

    test('排序稳定：同样输入永远同样顺序', () {
      final songs = [
        _s('同名', singer: '甲', path: '/b.mp3'),
        _s('同名', singer: '甲', path: '/a.mp3'),
      ];
      final r1 = LocalSongQuery.sort(songs, LocalSortKey.title).map((e) => e.localPath);
      final r2 = LocalSongQuery.sort(songs, LocalSortKey.title).map((e) => e.localPath);
      expect(r1.toList(), r2.toList());
    });

    test('排序不改动原列表', () {
      final songs = [_s('B'), _s('A')];
      LocalSongQuery.sort(songs, LocalSortKey.title);
      expect(songs.first.name, 'B');
    });
  });

  group('LocalSortKey', () {
    test('fromId 未知 id 回退到标题', () {
      expect(LocalSortKey.fromId('不存在的键'), LocalSortKey.title);
      expect(LocalSortKey.fromId(null), LocalSortKey.title);
    });

    test('fromId 能还原每个枚举值', () {
      for (final k in LocalSortKey.values) {
        expect(LocalSortKey.fromId(k.id), k);
      }
    });
  });

  group('LocalSongQuery.apply', () {
    test('过滤 + 排序一次完成', () {
      final songs = [
        _s('B歌', singer: '甲'),
        _s('A歌', singer: '甲'),
        _s('C歌', singer: '乙'),
      ];
      final r = LocalSongQuery.apply(
        songs,
        query: '甲',
        key: LocalSortKey.title,
      );
      expect(r.map((e) => e.name), ['A歌', 'B歌']);
    });
  });
}