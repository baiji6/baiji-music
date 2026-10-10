import 'dart:io';

import 'package:baiji_music/metadata/audio_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/audio_samples.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audio_reader_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> write(String name, List<int> bytes) async {
    final f = File('${tmp.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  // ==================== MP3 / ID3v2 ====================

  group('MP3 标签', () {
    test('ID3v2.3 + UTF-8 读出标题/艺术家/专辑/歌词/封面', () async {
      final p = await write(
        'a.mp3',
        buildMp3(
          title: '起风了',
          artist: '买辣椒也用券',
          album: '起风了',
          lyric: '[00:01.00]这一路上走走停停',
          cover: kJpeg,
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.format, 'mp3');
      expect(m.title, '起风了');
      expect(m.artist, '买辣椒也用券');
      expect(m.album, '起风了');
      expect(m.lyric, contains('这一路上走走停停'));
      expect(m.hasCover, isTrue);
      expect(m.coverMime, 'image/jpeg');
      expect(m.coverBytes, equals(kJpeg));
      expect(m.hasTags, isTrue);
    });

    test('UTF-16 BOM 编码（ID3 enc=01）', () async {
      final p = await write(
        'b.mp3',
        buildMp3(
          title: '海阔天空',
          artist: 'Beyond',
          album: '乐与怒',
          enc: Id3Enc.utf16bom,
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.title, '海阔天空');
      expect(m.artist, 'Beyond');
      expect(m.album, '乐与怒');
    });

    test('UTF-16BE 无 BOM（ID3 enc=02）', () async {
      final p = await write(
        'c.mp3',
        buildMp3(title: '晴天', artist: '周杰伦', enc: Id3Enc.utf16be),
      );

      final m = await AudioReader.read(p);
      expect(m.title, '晴天');
      expect(m.artist, '周杰伦');
    });

    test('Latin-1 编码（ID3 enc=00）', () async {
      final p = await write(
        'd.mp3',
        buildMp3(title: 'Hotel California', enc: Id3Enc.latin1),
      );

      final m = await AudioReader.read(p);
      expect(m.title, 'Hotel California');
    });

    test('ID3v2.4 用 syncsafe 帧长度', () async {
      final p = await write(
        'e.mp3',
        buildMp3(
          title: '夜空中最亮的星',
          artist: '逃跑计划',
          id3Major: 4,
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.title, '夜空中最亮的星');
      expect(m.artist, '逃跑计划');
    });

    test('v2.4 大帧（长度超过 127，考验 syncsafe 解码）', () async {
      final long = '啊' * 200;
      final p = await write(
        'f.mp3',
        buildMp3(title: long, id3Major: 4),
      );

      final m = await AudioReader.read(p);
      expect(m.title, long);
    });
  });

  group('MP3 时长', () {
    test('Xing 头给出精确时长', () async {
      // 1000 帧 * 1152 样本 / 44100 = 26122 ms
      final p = await write(
        'x.mp3',
        buildMp3(
          xingFrames: 1000,
          sampleRate: 44100,
          audioBytes: 8192, // 故意远小于实际，验证走的是 Xing 而非估算
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.durationMs, 26122);
      expect(m.sampleRate, 44100);
      expect(m.bitrate, 128);
    });

    test('VBRI 头给出精确时长', () async {
      final p = await write(
        'v.mp3',
        buildMp3(vbriFrames: 500, audioBytes: 8192),
      );

      final m = await AudioReader.read(p);
      // 500 * 1152 / 44100 * 1000 = 13061 ms
      expect(m.durationMs, 13061);
    });

    test('无 Xing/VBRI 时走 CBR 估算，误差 < 5%', () async {
      // 8192 字节 / 128kbps = 8192*8/128 = 512 ms
      final p = await write(
        'cbr.mp3',
        buildMp3(audioBytes: 8192, bitrateKbps: 128),
      );

      final m = await AudioReader.read(p);
      expect(m.durationMs, 512);
      // 与理论值 512 完全一致，这里再确认通用容差
      expect((m.durationMs - 512).abs() / 512, lessThan(0.05));
    });

    test('CBR 估算会扣掉尾部 ID3v1 的 128 字节', () async {
      final p = await write(
        'cbr1.mp3',
        buildMp3(
          audioBytes: 8192,
          bitrateKbps: 128,
          withId3v2: false,
          withId3v1: true,
        ),
      );

      final m = await AudioReader.read(p);
      // 文件长度 = 8192 音频 + 128 标签；扣掉标签后回到 8192 → 512 ms。
      // 若忘记扣除，会算成 8320 * 8 / 128 = 520 ms。
      expect(m.durationMs, 512);
      expect(m.durationMs, isNot(520));
    });

    test('Xing 优先于 CBR 估算', () async {
      // 音频区只有 8192 字节（CBR 会算出 512ms），Xing 说 1000 帧
      final p = await write(
        'pref.mp3',
        buildMp3(xingFrames: 1000, audioBytes: 8192),
      );

      final m = await AudioReader.read(p);
      expect(m.durationMs, 26122); // 走 Xing，不是 512
    });
  });

  group('MP3 ID3v1 兜底', () {
    test('无 ID3v2 时回退读取文件尾的 ID3v1', () async {
      final p = await write(
        'v1.mp3',
        buildMp3(
          withId3v2: false,
          withId3v1: true,
          v1Title: 'Old Song',
          v1Artist: 'Old Band',
          v1Album: 'Old Album',
          audioBytes: 8192,
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.title, 'Old Song');
      expect(m.artist, 'Old Band');
      expect(m.album, 'Old Album');
    });

    test('ID3v2 有内容时不覆盖为 ID3v1', () async {
      final p = await write(
        'both.mp3',
        buildMp3(
          title: '来自 v2 的标题',
          withId3v1: true,
          v1Title: '来自 v1 的标题',
          audioBytes: 8192,
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.title, '来自 v2 的标题');
    });
  });

  // ==================== FLAC ====================

  group('FLAC', () {
    test('Vorbis Comment + STREAMINFO 精确时长 + PICTURE 封面', () async {
      final p = await write(
        'a.flac',
        buildFlac(
          title: '富士山下',
          artist: '陈奕迅',
          album: "What's Going On...?",
          lyric: '[00:12.00]拦路雨偏似雪花',
          cover: kJpeg,
          sampleRate: 44100,
          totalSamples: 44100 * 3, // 3 秒
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.format, 'flac');
      expect(m.title, '富士山下');
      expect(m.artist, '陈奕迅');
      expect(m.album, "What's Going On...?");
      expect(m.lyric, contains('拦路雨偏似雪花'));
      expect(m.durationMs, 3000);
      expect(m.sampleRate, 44100);
      expect(m.hasCover, isTrue);
      expect(m.coverBytes, equals(kJpeg));
    });

    test('无注释块时只出时长，标签为空', () async {
      final p = await write(
        'nocmt.flac',
        buildFlac(
          withComment: false,
          sampleRate: 48000,
          totalSamples: 48000 * 2, // 2 秒
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.durationMs, 2000);
      expect(m.sampleRate, 48000);
      expect(m.hasTags, isFalse);
      expect(m.hasCover, isFalse);
    });

    test('高采样率（96kHz）时长仍精确', () async {
      final p = await write(
        'hi.flac',
        buildFlac(sampleRate: 96000, totalSamples: 96000 * 5),
      );

      final m = await AudioReader.read(p);
      expect(m.durationMs, 5000);
    });
  });

  // ==================== MP4 / M4A ====================

  group('M4A', () {
    test('ilst 全字段 + mvhd v0 时长', () async {
      final p = await write(
        'a.m4a',
        buildMp4(
          title: '七里香',
          artist: '周杰伦',
          album: '七里香',
          lyric: '[00:20.00]窗外的麻雀',
          cover: kJpeg,
          timescale: 44100,
          duration: 44100 * 10, // 10 秒
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.format, 'm4a');
      expect(m.title, '七里香');
      expect(m.artist, '周杰伦');
      expect(m.album, '七里香');
      expect(m.lyric, contains('窗外的麻雀'));
      expect(m.durationMs, 10000);
      expect(m.sampleRate, 44100);
      expect(m.hasCover, isTrue);
      expect(m.coverBytes, equals(kJpeg));
    });

    test('mvhd v1（64 位 duration）', () async {
      final p = await write(
        'v1.m4a',
        buildMp4(
          title: '长音频',
          timescale: 48000,
          duration: 48000 * 7,
          mvhdVersion: 1,
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.title, '长音频');
      expect(m.durationMs, 7000);
      expect(m.sampleRate, 48000);
    });

    test('moov 在文件尾部也能读到', () async {
      final p = await write(
        'tail.m4a',
        buildMp4(
          title: '尾部 moov',
          artist: '测试',
          timescale: 44100,
          duration: 44100 * 4,
          moovAtTail: true,
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.title, '尾部 moov');
      expect(m.artist, '测试');
      expect(m.durationMs, 4000);
    });
  });

  // ==================== OGG ====================

  group('OGG', () {
    test('Vorbis：注释 + granule 时长 + base64 封面', () async {
      final p = await write(
        'a.ogg',
        buildOgg(
          title: 'Bad Guy',
          artist: 'Billie Eilish',
          album: 'When We All Fall Asleep',
          lyric: '[00:05.00]White shirt now red',
          cover: kJpeg,
          sampleRate: 44100,
          granule: 44100 * 6, // 6 秒
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.format, 'ogg');
      expect(m.title, 'Bad Guy');
      expect(m.artist, 'Billie Eilish');
      expect(m.album, 'When We All Fall Asleep');
      expect(m.lyric, contains('White shirt now red'));
      expect(m.durationMs, 6000);
      expect(m.sampleRate, 44100);
      expect(m.hasCover, isTrue);
      expect(m.coverBytes, equals(kJpeg));
    });

    test('Opus：采样率恒 48000，走 OpusTags', () async {
      final p = await write(
        'a.opus',
        buildOgg(
          title: 'Opus 测试',
          artist: '编码器',
          opus: true,
          granule: 48000 * 5, // 5 秒
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.format, 'ogg');
      expect(m.title, 'Opus 测试');
      expect(m.artist, '编码器');
      expect(m.sampleRate, 48000);
      expect(m.durationMs, 5000);
    });
  });

  // ==================== WAV ====================

  group('WAV', () {
    test('LIST/INFO 标签 + byteRate 时长', () async {
      final p = await write(
        'a.wav',
        buildWav(
          title: '测试曲',
          artist: '测试者',
          album: '测试专辑',
          sampleRate: 44100,
          byteRate: 176400,
          dataSize: 176400 * 2, // 2 秒
        ),
      );

      final m = await AudioReader.read(p);
      expect(m.format, 'wav');
      expect(m.title, '测试曲');
      expect(m.artist, '测试者');
      expect(m.album, '测试专辑');
      expect(m.durationMs, 2000);
      expect(m.sampleRate, 44100);
    });

    test('无 INFO 块时只出时长', () async {
      final p = await write(
        'bare.wav',
        buildWav(byteRate: 88200, dataSize: 88200),
      );

      final m = await AudioReader.read(p);
      expect(m.durationMs, 1000);
      expect(m.hasTags, isFalse);
    });
  });

  // ==================== 读取开关 ====================

  group('读取开关', () {
    test('withCover=false 时丢弃封面但保留标签', () async {
      final p = await write(
        'nc.mp3',
        buildMp3(title: '无封面', artist: '测试', cover: kJpeg),
      );

      final m = await AudioReader.read(p, withCover: false);
      expect(m.title, '无封面');
      expect(m.hasCover, isFalse);
      expect(m.coverBytes, isNull);
    });

    test('withLyric=false 时丢弃歌词', () async {
      final p = await write(
        'nl.mp3',
        buildMp3(title: '无歌词', lyric: '[00:01.00]不要读我'),
      );

      final m = await AudioReader.read(p, withLyric: false);
      expect(m.title, '无歌词');
      expect(m.lyric, isEmpty);
    });
  });

  // ==================== 文件名兜底 ====================

  group('parseFileName', () {
    test('「歌手 - 歌名」拆出艺术家与标题', () {
      final r = AudioReader.parseFileName('/music/周杰伦 - 晴天.mp3');
      expect(r.$1, '晴天'); // (title, artist)
      expect(r.$2, '周杰伦');
    });

    test('无分隔符时整段作为标题', () {
      final r = AudioReader.parseFileName('/music/夜曲.mp3');
      expect(r.$1, '夜曲');
      expect(r.$2, isEmpty);
    });

    test('Windows 反斜杠路径', () {
      final r = AudioReader.parseFileName(r'C:\Music\Beyond - 海阔天空.flac');
      expect(r.$1, '海阔天空');
      expect(r.$2, 'Beyond');
    });

    test('多个连字符只按第一个拆分', () {
      final r = AudioReader.parseFileName('/m/A - B - C.mp3');
      expect(r.$1, 'B - C');
      expect(r.$2, 'A');
    });

    test('无扩展名的文件', () {
      final r = AudioReader.parseFileName('/m/纯音乐');
      expect(r.$1, '纯音乐');
    });
  });

  // ==================== 健壮性 ====================

  group('脏文件不抛异常', () {
    test('空文件', () async {
      final p = await write('empty.mp3', <int>[]);
      final m = await AudioReader.read(p);
      expect(m.title, isEmpty);
      expect(m.durationMs, 0);
    });

    test('截断到 30 字节', () async {
      final full = buildMp3(
        title: '完整标签',
        artist: '歌手',
        xingFrames: 1000,
      );
      final p = await write('cut.mp3', full.sublist(0, 30));
      final m = await AudioReader.read(p);
      expect(m.title, isEmpty); // 截断了读不出标签，但不该崩
    });

    test('全零填充', () async {
      final p = await write('zero.mp3', List<int>.filled(4096, 0));
      final m = await AudioReader.read(p);
      expect(m.durationMs, 0);
    });

    test('随机垃圾字节', () async {
      final junk = List<int>.generate(2048, (i) => (i * 7919) % 251);
      final p = await write('junk.flac', junk);
      final m = await AudioReader.read(p);
      expect(m.title, isEmpty);
    });

    test('文件不存在', () async {
      final m = await AudioReader.read('${tmp.path}/不存在的文件.mp3');
      expect(m.title, isEmpty);
      expect(m.format, isEmpty);
    });

    test('扩展名不受支持时返回空', () async {
      final p = await write('note.txt', utf8Bytes('hello'));
      final m = await AudioReader.read(p);
      expect(m.format, isEmpty);
    });

    test('ID3 头声明超大长度（越过文件末尾）不崩', () async {
      final b = <int>[
        ...asciiBytes('ID3'),
        0x03, 0x00, 0x00,
        0x7F, 0x7F, 0x7F, 0x7F, // syncsafe 长度 ≈ 268 MB
        ...List<int>.filled(64, 0),
      ];
      final p = await write('huge.mp3', b);
      final m = await AudioReader.read(p);
      expect(m.title, isEmpty);
    });

    test('FLAC 块长度越界不崩', () async {
      final b = <int>[
        ...asciiBytes('fLaC'),
        0x00, 0x7F, 0xFF, 0xFF, // STREAMINFO 声称 8 MB
        ...List<int>.filled(40, 0),
      ];
      final p = await write('bad.flac', b);
      final m = await AudioReader.read(p);
      expect(m.title, isEmpty);
    });
  });
}

List<int> asciiBytes(String s) => s.codeUnits;
List<int> utf8Bytes(String s) => s.codeUnits;
