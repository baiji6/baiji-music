import 'dart:convert';
import 'dart:io';

import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/data/local_music_store.dart';
import 'package:baiji_music/local/local_scanner.dart';
import 'package:baiji_music/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/audio_samples.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local_scan_test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> put(String rel, List<int> bytes) async {
    final f = File('${root.path}${Platform.pathSeparator}$rel');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
  }

  // ==================== 扫描产出 ====================

  group('扫描产出', () {
    test('五种格式都能被识别并读出元数据', () async {
      await put('a.mp3', buildMp3(title: 'MP3曲', artist: '甲', xingFrames: 1000));
      await put('b.flac', buildFlac(title: 'FLAC曲', artist: '乙',
          sampleRate: 44100, totalSamples: 44100 * 3));
      await put('c.m4a', buildMp4(title: 'M4A曲', artist: '丙',
          timescale: 44100, duration: 44100 * 10));
      await put('d.ogg', buildOgg(title: 'OGG曲', artist: '丁',
          sampleRate: 44100, granule: 44100 * 6));
      await put('e.wav', buildWav(title: 'WAV曲', artist: '戊',
          byteRate: 176400, dataSize: 176400 * 2));

      final r = LocalScanner.scanSync(dirs: [root.path]);

      final byFormat = <String, Song>{};
      for (final s in r.songs) {
        byFormat[s.format] = s;
      }
      expect(byFormat.keys.toSet(), {'mp3', 'flac', 'm4a', 'ogg', 'wav'});

      expect(byFormat['mp3']!.name, 'MP3曲');
      expect(byFormat['mp3']!.singer, '甲');
      expect(byFormat['mp3']!.duration, 26122);

      expect(byFormat['flac']!.name, 'FLAC曲');
      expect(byFormat['flac']!.duration, 3000);

      expect(byFormat['m4a']!.name, 'M4A曲');
      expect(byFormat['m4a']!.duration, 10000);

      expect(byFormat['ogg']!.name, 'OGG曲');
      expect(byFormat['ogg']!.duration, 6000);

      expect(byFormat['wav']!.name, 'WAV曲');
      expect(byFormat['wav']!.duration, 2000);

      expect(r.failedCount, 0);
    });

    test('没有内嵌标签时用文件名兜底', () async {
      // 文件名约定「歌手 - 歌名」，且文件本身无任何标签
      await put('周杰伦 - 晴天.mp3', buildMp3(audioBytes: 8192));

      final r = LocalScanner.scanSync(dirs: [root.path]);
      expect(r.songs, hasLength(1));
      expect(r.songs.first.name, '晴天');
      expect(r.songs.first.singer, '周杰伦');
    });

    test('来源标记为 local，路径与 songId 可用', () async {
      await put('x/song.mp3', buildMp3(title: '某曲'));

      final r = LocalScanner.scanSync(dirs: [root.path]);
      final s = r.songs.single;

      expect(s.source, Source.local);
      expect(s.isLocal, isTrue);
      expect(s.localPath, endsWith('song.mp3'));
      expect(s.localSize, greaterThan(0));
      expect(s.localMtime, greaterThan(0));
      expect(s.songId, isNot(0));
    });

    test('递归子目录', () async {
      await put('a/b/c/deep.mp3', buildMp3(title: '深处'));

      final r = LocalScanner.scanSync(dirs: [root.path]);
      expect(r.songs, hasLength(1));
      expect(r.songs.first.name, '深处');
    });

    test('跳过隐藏目录与非音频文件', () async {
      await put('.hidden/secret.mp3', buildMp3(title: '不该被发现'));
      await put('cover.jpg', <int>[0xFF, 0xD8, 0xFF, 0xD9]);
      await put('notes.txt', utf8.encode('hello'));
      await put('visible.mp3', buildMp3(title: '正常'));

      final r = LocalScanner.scanSync(dirs: [root.path]);
      expect(r.songs, hasLength(1));
      expect(r.songs.first.name, '正常');
    });

    test('残片文件被跳过，不影响其余文件入库', () async {
      // 只有 'ID3' 三个字节 + 2 字节，既无标签也读不出时长 → 视为残片
      await put('broken.mp3', <int>[0x49, 0x44, 0x33, 0x03, 0x00]);
      await put('good.mp3', buildMp3(title: '好的'));

      final r = LocalScanner.scanSync(dirs: [root.path]);
      expect(r.songs, hasLength(1));
      expect(r.songs.first.name, '好的');
      expect(r.failedCount, 1);
    });

    test('随机垃圾冒充音频时被跳过', () async {
      final junk = List<int>.generate(2048, (i) => (i * 7919) % 251);
      await put('junk.flac', junk);
      await put('real.flac', buildFlac(title: '真的', totalSamples: 44100 * 2,
          sampleRate: 44100));

      final r = LocalScanner.scanSync(dirs: [root.path]);
      expect(r.songs, hasLength(1));
      expect(r.songs.first.name, '真的');
      expect(r.failedCount, 1);
    });

    test('无标签但有真实时长的文件仍会入库（用文件名兜底）', () async {
      // 文件名约定是「歌手 - 歌名」；没有任何内嵌标签，但 CBR 能算出 512ms
      await put('作曲家 - 无名曲.mp3', buildMp3(audioBytes: 8192));

      final r = LocalScanner.scanSync(dirs: [root.path]);
      expect(r.songs, hasLength(1));
      expect(r.songs.first.name, '无名曲');
      expect(r.songs.first.singer, '作曲家');
      expect(r.songs.first.duration, 512);
      expect(r.failedCount, 0);
    });

    test('歌曲按 艺术家→专辑→标题 排序', () async {
      await put('z.mp3', buildMp3(title: 'Z歌', artist: '张三'));
      await put('a.mp3', buildMp3(title: 'A歌', artist: '李四'));
      await put('m.mp3', buildMp3(title: 'M歌', artist: '张三'));

      final r = LocalScanner.scanSync(dirs: [root.path]);
      // 李四 < 张三（按拼音顺序 compareTo 用的是码位，这里只验证分组与组内有序）
      expect(r.songs.first.singer, r.songs[1].singer);
      final zhang = r.songs.where((s) => s.singer == '张三').toList();
      expect(zhang.map((s) => s.name).toList(), ['M歌', 'Z歌']);
    });

    test('目录不存在时返回空结果而不抛异常', () {
      final r = LocalScanner.scanSync(dirs: ['${root.path}/根本不存在']);
      expect(r.songs, isEmpty);
      expect(r.failedCount, 0);
    });
  });

  // ==================== 增量扫描 ====================

  group('增量扫描', () {
    test('指纹未变的文件直接复用，不再读盘', () async {
      await put('a.mp3', buildMp3(title: '旧标题', artist: '甲'));

      final first = LocalScanner.scanSync(dirs: [root.path]);
      expect(first.parsedCount, 1);
      expect(first.reusedCount, 0);

      // 构造第二次扫描所需的缓存
      final known = LocalMusicStore.songsByPathFor(first.songs);
      final fps = LocalMusicStore.fingerprintsFor(first.songs);

      final second = LocalScanner.scanSync(
        dirs: [root.path],
        known: known,
        knownFingerprints: fps,
      );

      expect(second.reusedCount, 1);
      expect(second.parsedCount, 0);
      expect(second.songs, hasLength(1));
      expect(second.songs.first.name, '旧标题');
    });

    test('文件内容变化（mtime 改变）后重新解析', () async {
      final p = await File('${root.path}${Platform.pathSeparator}a.mp3'
              .replaceAll('/', Platform.pathSeparator))
          .create(recursive: true);
      await p.writeAsBytes(buildMp3(title: '旧标题', artist: '甲'));

      final first = LocalScanner.scanSync(dirs: [root.path]);
      final known = LocalMusicStore.songsByPathFor(first.songs);
      final fps = LocalMusicStore.fingerprintsFor(first.songs);

      // 改内容：写入不同的字节，确保 size 也变（否则只改 mtime 也行）
      await p.writeAsBytes(buildMp3(title: '新标题', artist: '乙', audioBytes: 12000));

      final second = LocalScanner.scanSync(
        dirs: [root.path],
        known: known,
        knownFingerprints: fps,
      );

      expect(second.parsedCount, 1);
      expect(second.reusedCount, 0);
      expect(second.songs.first.name, '新标题');
      expect(second.songs.first.singer, '乙');
    });

    test('force=true 时忽略指纹全部重扫', () async {
      await put('a.mp3', buildMp3(title: '某标题'));

      final first = LocalScanner.scanSync(dirs: [root.path]);
      final known = LocalMusicStore.songsByPathFor(first.songs);
      final fps = LocalMusicStore.fingerprintsFor(first.songs);

      final second = LocalScanner.scanSync(
        dirs: [root.path],
        known: known,
        knownFingerprints: fps,
        force: true,
      );

      expect(second.parsedCount, 1);
      expect(second.reusedCount, 0);
    });

    test('已删除的文件出现在 missing 里', () async {
      await put('stay.mp3', buildMp3(title: '留下'));
      await put('gone.mp3', buildMp3(title: '将被删除'));

      final first = LocalScanner.scanSync(dirs: [root.path]);
      final known = LocalMusicStore.songsByPathFor(first.songs);
      final fps = LocalMusicStore.fingerprintsFor(first.songs);

      await File('${root.path}${Platform.pathSeparator}gone.mp3').delete();

      final second = LocalScanner.scanSync(
        dirs: [root.path],
        known: known,
        knownFingerprints: fps,
      );

      expect(second.missing, hasLength(1));
      expect(second.missing.first, endsWith('gone.mp3'));
      expect(second.songs, hasLength(1));
      expect(second.songs.first.name, '留下');
    });

    test('指纹相等性判定', () {
      expect(LocalFingerprint(1, 2), LocalFingerprint(1, 2));
      expect(LocalFingerprint(1, 2), isNot(LocalFingerprint(1, 3)));
      expect(LocalFingerprint(1, 2), isNot(LocalFingerprint(2, 2)));

      final j = LocalFingerprint(10, 20).toJson();
      expect(LocalFingerprint.fromJson(j), LocalFingerprint(10, 20));
      expect(LocalFingerprint.fromJson(null), isNull);
    });
  });

  // ==================== 播放 URI ====================

  group('播放 URI', () {
    test('存在的本地文件返回 file:// URI', () async {
      await put('a b/歌 名.mp3', buildMp3(title: '含空格路径'));
      final r = LocalScanner.scanSync(dirs: [root.path]);
      final s = r.songs.single;

      final uri = LocalScanner.playUri(s);
      expect(uri, startsWith('file://'));
      // 空格必须被转义，否则 media_kit 打不开
      expect(uri, isNot(contains(' ')));
    });

    test('文件被删后返回空串', () async {
      await put('a.mp3', buildMp3(title: '临时'));
      final r = LocalScanner.scanSync(dirs: [root.path]);
      await File(r.songs.single.localPath).delete();

      expect(LocalScanner.playUri(r.songs.single), isEmpty);
    });

    test('网络歌曲返回空串', () {
      final s = Song(
        mid: 'x',
        songId: 1,
        name: 'n',
        singer: 's',
        album: 'a',
        albumMid: '',
        duration: 0,
        cover: '',
      );
      expect(s.isLocal, isFalse);
      expect(LocalScanner.playUri(s), isEmpty);
    });
  });

  // ==================== 外部歌词 ====================

  group('歌词读取', () {
    test('外部 .lrc 优先于内嵌歌词', () async {
      await put('a.mp3', buildMp3(title: 'x', lyric: '[00:01.00]内嵌歌词'));
      await put('a.lrc', utf8.encode('[00:02.00]外部歌词\n'));

      final r = LocalScanner.scanSync(dirs: [root.path]);
      final lyric = await LocalScanner.readLyricFor(r.songs.single);
      expect(lyric, contains('外部歌词'));
      expect(lyric, isNot(contains('内嵌歌词')));
    });

    test('没有 .lrc 时回退到内嵌歌词', () async {
      await put('b.mp3', buildMp3(title: 'x', lyric: '[00:01.00]只有内嵌'));

      final r = LocalScanner.scanSync(dirs: [root.path]);
      final lyric = await LocalScanner.readLyricFor(r.songs.single);
      expect(lyric, contains('只有内嵌'));
    });

    test('都没有时返回空串', () async {
      await put('c.mp3', buildMp3(title: 'x'));

      final r = LocalScanner.scanSync(dirs: [root.path]);
      expect(await LocalScanner.readLyricFor(r.songs.single), isEmpty);
    });
  });

  // ==================== 持久化 ====================

  group('LocalMusicStore', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await KvStore.ensureInit();
    });

    test('歌曲清单读写往返保留全部字段', () async {
      final list = <Song>[
        Song(
          mid: '/m/a.mp3',
          songId: 42,
          name: '标题',
          singer: '歌手',
          album: '专辑',
          albumMid: '',
          duration: 26122,
          cover: '',
          source: Source.local,
          localPath: '/m/a.mp3',
          localSize: 8192,
          localMtime: 1700000000000,
          format: 'mp3',
        ),
      ];

      await LocalMusicStore.writeSongs(list);
      final back = LocalMusicStore.songs();

      expect(back, hasLength(1));
      final s = back.single;
      expect(s.name, '标题');
      expect(s.singer, '歌手');
      expect(s.album, '专辑');
      expect(s.duration, 26122);
      expect(s.source, Source.local);
      expect(s.localPath, '/m/a.mp3');
      expect(s.localSize, 8192);
      expect(s.localMtime, 1700000000000);
      expect(s.format, 'mp3');
      expect(s.isLocal, isTrue);
    });

    test('指纹读写往返', () async {
      await LocalMusicStore.writeFingerprints(<String, LocalFingerprint>{
        '/a.mp3': const LocalFingerprint(100, 200),
        '/b.flac': const LocalFingerprint(300, 400),
      });

      final back = LocalMusicStore.fingerprints();
      expect(back['/a.mp3'], const LocalFingerprint(100, 200));
      expect(back['/b.flac'], const LocalFingerprint(300, 400));
    });

    test('自定义目录增删去重', () async {
      await LocalMusicStore.addCustomDir('/music');
      await LocalMusicStore.addCustomDir('/music'); // 重复应被忽略
      await LocalMusicStore.addCustomDir('/downloads');
      expect(LocalMusicStore.customDirs(), ['/music', '/downloads']);

      await LocalMusicStore.removeCustomDir('/music');
      expect(LocalMusicStore.customDirs(), ['/downloads']);
    });

    test('保存扫描结果会写入清单、指纹并标记已扫描', () async {
      await put('a.mp3', buildMp3(title: '某曲', artist: '某人'));
      final r = LocalScanner.scanSync(dirs: [root.path]);

      expect(LocalMusicStore.hasScanned(), isFalse);
      final saved = await LocalMusicStore.save(r);

      expect(saved, hasLength(1));
      expect(LocalMusicStore.hasScanned(), isTrue);
      expect(LocalMusicStore.songs(), hasLength(1));
      expect(LocalMusicStore.fingerprints(), hasLength(1));
    });

    test('save 会剔除已删除文件的指纹', () async {
      await put('a.mp3', buildMp3(title: '留下'));
      await put('b.mp3', buildMp3(title: '删掉'));
      final first = LocalScanner.scanSync(dirs: [root.path]);
      await LocalMusicStore.save(first);
      expect(LocalMusicStore.fingerprints(), hasLength(2));

      await File('${root.path}${Platform.pathSeparator}b.mp3').delete();

      final second = LocalScanner.scanSync(
        dirs: [root.path],
        known: LocalMusicStore.songsByPath(),
        knownFingerprints: LocalMusicStore.fingerprints(),
      );
      expect(second.missing, hasLength(1));

      await LocalMusicStore.save(second);
      expect(LocalMusicStore.fingerprints(), hasLength(1));
      expect(LocalMusicStore.songs(), hasLength(1));
      expect(LocalMusicStore.songs().single.name, '留下');
    });

    test('clear 清空全部本地数据', () async {
      await put('a.mp3', buildMp3(title: '某曲'));
      final r = LocalScanner.scanSync(dirs: [root.path]);
      await LocalMusicStore.save(r);
      expect(LocalMusicStore.songs(), isNotEmpty);

      await LocalMusicStore.clear();
      expect(LocalMusicStore.songs(), isEmpty);
      expect(LocalMusicStore.fingerprints(), isEmpty);
      expect(LocalMusicStore.hasScanned(), isFalse);
    });

    test('读取损坏的 JSON 不抛异常', () async {
      await KvStore.instance.setString('local_songs', '{不是合法 JSON');
      expect(LocalMusicStore.songs(), isEmpty);

      await KvStore.instance.setString('local_fingerprints', '[[[[');
      expect(LocalMusicStore.fingerprints(), isEmpty);

      await KvStore.instance.setString('local_scan_dirs', '"不是数组"');
      expect(LocalMusicStore.customDirs(), isEmpty);
    });
  });

  // ==================== Isolate 路径 ====================

  group('Isolate 扫描', () {
    test('scan 与 scanSync 结果一致，且能收到进度', () async {
      await put('a.mp3', buildMp3(title: '甲演唱', artist: '甲'));
      await put('b.flac', buildFlac(title: '乙演奏', artist: '乙'));

      final progress = <LocalScanProgress>[];
      final r = await LocalScanner.scan(
        dirs: [root.path],
        onProgress: progress.add,
      );

      expect(r.songs, hasLength(2));
      expect(r.songs.map((s) => s.name).toSet(), {'甲演唱', '乙演奏'});
      expect(progress, isNotEmpty);
      expect(progress.last.done, progress.last.total);
    });

    test('目录下无音频时也能正常返回', () async {
      await put('readme.txt', utf8.encode('nothing here'));
      final r = await LocalScanner.scan(dirs: [root.path]);
      expect(r.songs, isEmpty);
    });
  });
}
