// 真实逐字 LRC → MP3 内嵌 → 读回 → 解析，逐字时间轴保住。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/crypto/qq_crypto.dart';
import 'package:baiji_music/lyrics/lyric_parser.dart';
import 'package:baiji_music/lyrics/lyric_serializer.dart';
import 'package:baiji_music/metadata/audio_reader.dart';
import 'package:baiji_music/metadata/audio_tagger.dart';
import 'package:flutter_test/flutter_test.dart';

BytesBuilder _bb() => BytesBuilder(copy: false);

void _u32be(BytesBuilder b, int v) =>
    b.add(<int>[(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);

Uint8List _buildMp3() {
  final frame = _bb();
  frame.add(ascii.encode('TIT2'));
  final payload = <int>[0x00, ...ascii.encode('Old Title')];
  _u32be(frame, payload.length);
  frame.add(<int>[0x00, 0x00]);
  frame.add(payload);

  final pad = List<int>.filled(64, 0);
  final body = <int>[...frame.takeBytes(), ...pad];

  final out = _bb();
  out.add(ascii.encode('ID3'));
  out.add(<int>[0x03, 0x00, 0x00]);
  final n = body.length;
  out.add(<int>[
    (n >> 21) & 0x7F,
    (n >> 14) & 0x7F,
    (n >> 7) & 0x7F,
    n & 0x7F,
  ]);
  out.add(body);
  out.add(List<int>.filled(2048, 0x5A));
  return out.takeBytes();
}

void main() {
  test('逐字 LRC 内嵌 MP3 往返', () async {
    final full =
        jsonDecode(File('test/fixtures/lyrics/qq_qrc_186016.json')
            .readAsStringSync());
    final dec = qrcDecrypt((full['lyric'] as String).trim());
    final lyrics = LyricParser.parse(dec);
    final wordLrc = LyricSerializer.toLrc(lyrics, wordLevel: true);

    final dir = Directory.systemTemp.createTempSync('baiji_lyric_rt');
    final f = File('${dir.path}/t.mp3')..writeAsBytesSync(_buildMp3());

    final embedResult = await AudioTagger.embed(
      file: f,
      lyrics: wordLrc,
      cover: null,
      title: '其实',
      artist: '薛之谦',
      album: '意外',
    );
    expect(embedResult.error, isNull);
    expect(embedResult.lyricsEmbedded, isTrue);

    final m = await AudioReader.read(f.path, withCover: false);
    final back = LyricParser.parse(m.lyric);
    // 逐字时间轴必须原样保住：46 行全 word-level
    expect(back.length, 46);
    expect(back.hasWordTiming, isTrue);
    expect(back.lines.where((l) => l.isWordLevel).length, 46);
    dir.deleteSync(recursive: true);
  });
}
