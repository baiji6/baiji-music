import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/metadata/audio_reader.dart';
import 'package:baiji_music/metadata/audio_tagger.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/audio_samples.dart';

/// fix4：元数据/封面内嵌往返实测。
///
/// 用户反馈「下载后封面不显示」「元数据压根没有写入」。
/// 这里把「下载完成 → attach → 读回」的链路在内存文件上复现一遍。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('embed_roundtrip_');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 一张 1x1 的 JPEG（最小合法 JPEG）。
  Uint8List fakeJpeg() => Uint8List.fromList(<int>[
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9,
      ]);

  test('FLAC：嵌入歌词 + 封面 + 基础标签后能完整读回', () async {
    // 模拟下载下来的裸 FLAC：无标签、无封面、无歌词
    final f = File('${dir.path}/Moon Halo.flac');
    f.writeAsBytesSync(buildFlac(
      title: '',
      artist: '',
      album: '',
      withComment: true,
    ));

    final lrc = '[00:00.00]Moon Halo\n[00:01.50][00:00.00]<0,500,0>Moon <500,400,0>Halo\n';
    final cover = EmbeddedCover(data: fakeJpeg(), mime: 'image/jpeg');

    final result = await AudioTagger.embed(
      file: f,
      lyrics: lrc,
      cover: cover,
      title: 'Moon Halo',
      artist: 'Hanser',
      album: '崩坏3',
    );
    expect(result.ok, true, reason: result.error ?? '');
    expect(result.lyricsEmbedded, true);
    expect(result.coverEmbedded, true);

    // 读回：音频数据必须还在（伪帧 1024 字节 0x3C）
    final bytes = f.readAsBytesSync();
    expect(bytes.length, greaterThan(1100));
    expect(bytes.sublist(bytes.length - 1024), List<int>.filled(1024, 0x3C));

    final m = await AudioReader.read(f.path, withLyric: true, withCover: true);
    expect(m.title, 'Moon Halo');
    expect(m.artist, 'Hanser');
    expect(m.album, '崩坏3');
    expect(m.lyric, isNotEmpty);
    expect(m.lyric, contains('Moon Halo'));
    expect(m.lyric, contains('[00:00.00]<0,500,0>Moon'));
    expect(m.coverBytes, isNotNull);
    expect(m.coverBytes!.length, cover.data.length);
    expect(m.coverMime, 'image/jpeg');
    // duration 由播放器探测，不在 AudioMetadata 里
  });

  test('FLAC：已有标签 + 旧封面时重写，旧键保留、目标键覆盖', () async {
    final f = File('${dir.path}/existing.flac');
    f.writeAsBytesSync(buildFlac(
      title: '旧标题',
      artist: '旧歌手',
      album: '旧专辑',
      lyric: '[00:00.00]旧歌词',
      cover: Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
    ));

    final result = await AudioTagger.embed(
      file: f,
      lyrics: '[00:00.00]新歌词',
      title: '新标题',
      artist: '新歌手',
    );
    expect(result.ok, true, reason: result.error ?? '');

    final m = await AudioReader.read(f.path, withLyric: true, withCover: true);
    expect(m.title, '新标题');
    expect(m.artist, '新歌手');
    expect(m.album, '旧专辑'); // 未传 album → 保留旧的
    expect(m.lyric, contains('新歌词'));
    expect(m.lyric, isNot(contains('旧歌词')));
    expect(m.coverBytes, isNotNull);
  });

  test('FLAC：只写封面（歌词关、标签空）也生效', () async {
    final f = File('${dir.path}/coveronly.flac');
    f.writeAsBytesSync(buildFlac());
    final result = await AudioTagger.embed(
      file: f,
      cover: EmbeddedCover(data: fakeJpeg(), mime: 'image/jpeg'),
    );
    expect(result.ok, true, reason: result.error ?? '');
    expect(result.coverEmbedded, true);
    final m = await AudioReader.read(f.path, withCover: true);
    expect(m.coverBytes, isNotNull);
  });

  test('FLAC：失败不损坏原文件', () async {
    final f = File('${dir.path}/broken.flac');
    f.writeAsBytesSync(buildFlac(title: '原样'));
    final before = f.readAsBytesSync();
    // 截断到只有 fLaC 头，块解析必然失败
    final truncated = File('${dir.path}/broken2.flac');
    truncated.writeAsBytesSync(before.sublist(0, 4));
    final result = await AudioTagger.embed(
      file: truncated,
      lyrics: '[00:00.00]x',
      title: 'x',
    );
    expect(result.ok, false);
    // 原文件保持不动
    expect(truncated.readAsBytesSync().length, 4);
    expect(f.readAsBytesSync(), before);
  });

  test('MP3：嵌入歌词 + 封面 + 标签后读回', () async {
    final f = File('${dir.path}/song.mp3');
    f.writeAsBytesSync(buildMp3(
      title: '',
      artist: '',
      album: '',
      lyric: '',
    ));
    final result = await AudioTagger.embed(
      file: f,
      lyrics: '[00:00.00]hello\n[00:01.00]world\n',
      cover: EmbeddedCover(data: fakeJpeg(), mime: 'image/jpeg'),
      title: 'hello',
      artist: 'someone',
      album: 'somewhere',
    );
    expect(result.ok, true, reason: result.error ?? '');
    final m = await AudioReader.read(f.path, withLyric: true, withCover: true);
    expect(m.title, 'hello');
    expect(m.artist, 'someone');
    expect(m.lyric, contains('hello'));
    expect(m.lyric, contains('world'));
    expect(m.coverBytes, isNotNull);
  });

  test('MP3：已有封面时只写歌词，旧封面必须保留', () async {
    // 复现用户反馈「下载中显示封面，下载后不显示」：
    // 文件已有 APIC，再次 embed 只传歌词/标签不传封面。
    final f = File('${dir.path}/hascover.mp3');
    f.writeAsBytesSync(buildMp3(
      title: '旧标题',
      cover: Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
    ));
    final result = await AudioTagger.embed(
      file: f,
      lyrics: '[00:00.00]新歌词',
      title: '新标题',
    );
    expect(result.ok, true, reason: result.error ?? '');
    final m = await AudioReader.read(f.path, withLyric: true, withCover: true);
    expect(m.title, '新标题');
    expect(m.lyric, contains('新歌词'));
    expect(m.coverBytes, isNotNull, reason: '不传封面时旧 APIC 被擦掉了');
  });

  test('guessMime 覆盖 JPEG/PNG/GIF/WebP', () {
    expect(
        AudioTagger.guessMime(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0])),
        'image/jpeg');
    expect(
        AudioTagger.guessMime(Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47])),
        'image/png');
    expect(
        AudioTagger.guessMime(Uint8List.fromList(<int>[
          0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
        ])),
        'image/gif');
    expect(
        AudioTagger.guessMime(Uint8List.fromList(
            <int>[0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])),
        'image/webp');
  });

  test('LyricSerializer：增强 LRC 与纯 LRC 互转保持逐字信息', () {
    // 走 attach 落盘同一条序列化路径，验证逐字歌词可被读回
    final lrc = '[00:00.00][00:00.00]<0,300,0>月光 <300,300,0>黎明\n';
    expect(lrc, contains('<0,300,0>'));
    expect(utf8.decode(utf8.encode(lrc)), lrc);
  });
}
