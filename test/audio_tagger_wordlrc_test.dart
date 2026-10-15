// 临时诊断：逐字 LRC 内嵌 MP3/FLAC/M4A 往返，验证逐字是否保住。
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

void _u32le(BytesBuilder b, int v) =>
    b.add(<int>[v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

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
  out.add(<int>[(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F]);
  out.add(body);
  out.add(List<int>.filled(2048, 0x5A));
  return out.takeBytes();
}

Uint8List _buildFlac() {
  final out = _bb();
  out.add(ascii.encode('fLaC'));
  final si = List<int>.filled(34, 0x11);
  out.add(<int>[0x00, 0x00, 0x00, si.length]);
  out.add(si);

  final cm = _bb();
  final vendor = ascii.encode('old-vendor');
  _u32le(cm, vendor.length);
  cm.add(vendor);
  final items = <String>['DATE=2024', 'TITLE=OldTitle'];
  _u32le(cm, items.length);
  for (final it in items) {
    final e = utf8.encode(it);
    _u32le(cm, e.length);
    cm.add(e);
  }
  final data = cm.takeBytes();
  out.add(<int>[
    0x80 | 4,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
  ]);
  out.add(data);
  out.add(List<int>.filled(1024, 0x3C));
  return out.takeBytes();
}

Uint8List _mkBox(String type, List<int> payload) {
  final b = _bb();
  _u32be(b, 8 + payload.length);
  final t = utf8.encode(type);
  b.add(t.length == 4 ? t : t.sublist(0, 4));
  b.add(payload);
  return b.takeBytes();
}

Uint8List _buildM4a() {
  final ftyp = _mkBox('ftyp', [
    ...ascii.encode('M4A '),
    0x00, 0x00, 0x00, 0x00,
    ...ascii.encode('M4A mp42isom'),
  ]);
  // ilst 里放一个 ©nam
  final nameData = _mkBox('data', [
    0x00, 0x00, 0x00, 1, // type = UTF-8
    0x00, 0x00, 0x00, 0x00, // locale
    ...utf8.encode('Old'),
  ]);
  final ilst = _mkBox('ilst', _mkBox('\u00A9nam', nameData));
  final meta = _mkBox('meta', [
    0x00, 0x00, 0x00, 0x00, // version/flags
    ..._mkBox('hdlr', [
      ...ascii.encode('mdir'),
      ...ascii.encode('appl'),
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      ...utf8.encode('\u00A9nam'),
    ]),
    ...ilst,
  ]);
  final moov = _mkBox('moov', meta);
  final mdat = _mkBox('mdat', List<int>.filled(1024, 0x3C));
  return Uint8List.fromList([...ftyp, ...moov, ...mdat]);
}

void main() {
  test('逐字 LRC 全格式内嵌往返', () async {
    final full =
        jsonDecode(File('test/fixtures/lyrics/qq_qrc_186016.json')
            .readAsStringSync());
    final dec = qrcDecrypt((full['lyric'] as String).trim());
    final lyrics = LyricParser.parse(dec);
    final wordLrc = LyricSerializer.toLrc(lyrics, wordLevel: true);

    final dir = Directory.systemTemp.createTempSync('baiji_fmt_rt');
    for (final entry in <String, Uint8List>{
      't.mp3': _buildMp3(),
      't.flac': _buildFlac(),
      't.m4a': _buildM4a(),
    }.entries) {
      final f = File('${dir.path}/${entry.key}')..writeAsBytesSync(entry.value);
      final r = await AudioTagger.embed(
        file: f,
        lyrics: wordLrc,
        cover: null,
        title: '其实',
        artist: '薛之谦',
        album: '意外',
      );
      expect(r.error, isNull, reason: '${entry.key} 内嵌失败');
      expect(r.lyricsEmbedded, isTrue, reason: '${entry.key} 未写入歌词');
      final m = await AudioReader.read(f.path, withCover: false);
      final back = LyricParser.parse(m.lyric);
      // 逐字时间轴必须原样保住：46 行全 word-level
      expect(back.length, 46, reason: '${entry.key} 行数不对');
      expect(back.hasWordTiming, isTrue, reason: '${entry.key} 丢了逐字');
      expect(back.lines.where((l) => l.isWordLevel).length, 46,
          reason: '${entry.key} word-level 行数不对');
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
