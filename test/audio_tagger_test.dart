import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/metadata/audio_tagger.dart';
import 'package:flutter_test/flutter_test.dart';

// ===================== 字节工具 =====================

BytesBuilder _bb() => BytesBuilder(copy: false);

void _u32be(BytesBuilder b, int v) =>
    b.add(<int>[(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);

void _u32le(BytesBuilder b, int v) =>
    b.add(<int>[v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

int _r32be(Uint8List d, int o) =>
    (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];

int _r32le(Uint8List d, int o) =>
    d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);

/// 一张 1x1 的 JPEG（最小合法文件），用来当作封面。
final Uint8List kJpeg = Uint8List.fromList(<int>[
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, //
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, //
  0xFF, 0xD9, //
]);

const String kLrc = '[00:01.00]白姬音乐\n[00:02.50]测试歌词\n';

/// 写入前会 trim，比较时用去掉首尾空白的版本。
final String kLrcWritten = kLrc.trim();

EmbeddedCover _cover() => EmbeddedCover(data: kJpeg, mime: 'image/jpeg');

// ===================== 样例文件构造 =====================

/// 最小 MP3：ID3v2.3（含一个 TIT2 帧）+ 伪音频数据。
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
  out.add(<int>[0x03, 0x00, 0x00]); // v2.3, 无 flag
  // syncsafe 长度（每字节只用低 7 位）
  final n = body.length;
  out.add(<int>[
    (n >> 21) & 0x7F,
    (n >> 14) & 0x7F,
    (n >> 7) & 0x7F,
    n & 0x7F,
  ]);
  out.add(body);
  out.add(List<int>.filled(2048, 0x5A)); // 伪音频
  return out.takeBytes();
}

/// 最小 FLAC：fLaC + STREAMINFO（last=1） + 一段已有 Vorbis Comment。
Uint8List _buildFlac({bool withComment = true}) {
  final out = _bb();
  out.add(ascii.encode('fLaC'));

  // STREAMINFO（type 0），内容不重要，34 字节即可
  final si = List<int>.filled(34, 0x11);
  out.add(<int>[0x00, 0x00, 0x00, si.length]);
  out.add(si);

  if (withComment) {
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
      0x80 | 4, // last-block + VORBIS_COMMENT
      (data.length >> 16) & 0xFF,
      (data.length >> 8) & 0xFF,
      data.length & 0xFF,
    ]);
    out.add(data);
  } else {
    // 让 STREAMINFO 成为最后一块
    final bytes = out.takeBytes();
    bytes[4] = 0x80 | 0x00;
    final res = _bb();
    res.add(bytes);
    res.add(List<int>.filled(1024, 0x3C)); // 伪音频
    return res.takeBytes();
  }

  out.add(List<int>.filled(1024, 0x3C)); // 伪音频
  return out.takeBytes();
}

/// MP4 盒子。
Uint8List _mkBox(String type, List<int> payload) {
  final b = _bb();
  _u32be(b, 8 + payload.length);
  b.add(latin1.encode(type).length == 4
      ? latin1.encode(type)
      : ascii.encode(type).sublist(0, 4));
  b.add(payload);
  return b.takeBytes();
}

/// 最小 MP4：ftyp + moov(含 udta/meta/ilst 与 stco) + mdat。
/// 布局刻意让 moov 在 mdat **之前**，这样 moov 变长必须修正 stco 偏移。
Uint8List _buildMp4() {
  // 先占位的 stco（后面填真实偏移）
  final stcoPayload = Uint8List(8 + 2 * 4);
  stcoPayload[3] = 0; // version/flags
  stcoPayload[7] = 2; // entry_count
  final stco = _mkBox('stco', stcoPayload);

  final stbl = _mkBox('stbl', stco);
  final minf = _mkBox('minf', stbl);
  final mdia = _mkBox('mdia', minf);
  final trak = _mkBox('trak', mdia);
  final mvhd = _mkBox('mvhd', List<int>.filled(100, 0));

  // 已存在的 ilst：一个 ©nam（写入时 title 传了值 → 应被覆盖）
  final namData = _bb();
  _u32be(namData, 1);
  _u32be(namData, 0);
  namData.add(ascii.encode('OldName'));
  final namBox = _mkBox('©nam', _mkBox('data', namData.takeBytes()));
  final ilst = _mkBox('ilst', namBox);
  final hdlr = _mkBox('hdlr', List<int>.filled(24, 0));
  final metaPayload = <int>[0, 0, 0, 0, ...hdlr, ...ilst];
  final meta = _mkBox('meta', metaPayload);
  final udta = _mkBox('udta', meta);

  final moov = _mkBox('moov', <int>[...mvhd, ...trak, ...udta]);

  final mdatPayloadLen = 1000;
  final ftyp = _mkBox('ftyp', List<int>.filled(8, 0));
  final mdat = _mkBox('mdat', List<int>.filled(mdatPayloadLen, 0x77));

  final mdatStart = ftyp.length + moov.length;
  final mdatPayloadStart = mdatStart + 8;

  // 把 stco 的两个 chunk offset 填成 mdat 内的真实位置
  final all = <int>[...ftyp, ...moov, ...mdat];
  final stcoIdx = _indexOf(all, ascii.encode('stco'))!;
  final entryStart = stcoIdx + 4 + 8; // 'stco' 之后 4 字节 type，再 8 字节 fullbox 头
  _writeU32BEInto(all, entryStart, mdatPayloadStart);
  _writeU32BEInto(all, entryStart + 4, mdatPayloadStart + 500);

  return Uint8List.fromList(all);
}

void _writeU32BEInto(List<int> d, int o, int v) {
  d[o] = (v >> 24) & 0xFF;
  d[o + 1] = (v >> 16) & 0xFF;
  d[o + 2] = (v >> 8) & 0xFF;
  d[o + 3] = v & 0xFF;
}

int? _indexOf(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return null;
}

/// Ogg 页：poly 0x04C11DB7，初值 0，无反射。
int _oggCrc(Uint8List data) {
  final table = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var r = i << 24;
    for (var j = 0; j < 8; j++) {
      r = ((r & 0x80000000) != 0) ? ((r << 1) ^ 0x04C11DB7) : (r << 1);
      r &= 0xFFFFFFFF;
    }
    table[i] = r;
  }
  var crc = 0;
  for (final b in data) {
    final idx = (((crc >> 24) & 0xFF) ^ b) & 0xFF;
    crc = (((crc << 8) & 0xFFFFFFFF) ^ table[idx]) & 0xFFFFFFFF;
  }
  return crc;
}

Uint8List _oggPage({
  required int headerType,
  required int granule,
  required int serial,
  required int seq,
  required Uint8List packet,
}) {
  final segCount = (packet.length / 255).ceil();
  final seg = <int>[];
  var left = packet.length;
  for (var i = 0; i < segCount; i++) {
    final n = left > 255 ? 255 : left;
    seg.add(n);
    left -= n;
  }
  final b = _bb();
  b.add(ascii.encode('OggS'));
  b.addByte(0); // version
  b.addByte(headerType);
  for (var i = 0; i < 8; i++) {
    b.addByte((granule >> (8 * i)) & 0xFF);
  }
  for (var i = 0; i < 4; i++) {
    b.addByte((serial >> (8 * i)) & 0xFF);
  }
  for (var i = 0; i < 4; i++) {
    b.addByte((seq >> (8 * i)) & 0xFF);
  }
  b.addByte(0); // CRC 占位（22..25，共 4 字节）
  b.addByte(0);
  b.addByte(0);
  b.addByte(0);
  b.addByte(segCount); // 26
  for (final s in seg) {
    b.addByte(s);
  }
  b.add(packet);
  final bytes = b.takeBytes();
  // 回填 CRC（页头 + 段表 + 载荷，CRC 字段本身置 0）
  final crc = _oggCrc(bytes);
  bytes[22] = crc & 0xFF;
  bytes[23] = (crc >> 8) & 0xFF;
  bytes[24] = (crc >> 16) & 0xFF;
  bytes[25] = (crc >> 24) & 0xFF;
  return bytes;
}

/// 最小 Ogg Vorbis：识别头 + 注释头 + 一页音频。
Uint8List _buildOgg() {
  final id = _bb();
  id.addByte(0x01);
  id.add(ascii.encode('vorbis'));
  id.add(List<int>.filled(23, 0));
  final p1 = _oggPage(
    headerType: 2,
    granule: 0,
    serial: 0x1234,
    seq: 0,
    packet: id.takeBytes(),
  );

  final cm = _bb();
  cm.addByte(0x03);
  cm.add(ascii.encode('vorbis'));
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
  final p2 = _oggPage(
    headerType: 0,
    granule: 0,
    serial: 0x1234,
    seq: 1,
    packet: cm.takeBytes(),
  );

  final p3 = _oggPage(
    headerType: 4,
    granule: 1024,
    serial: 0x1234,
    seq: 2,
    packet: Uint8List.fromList(List<int>.filled(600, 0x2F)),
  );

  return Uint8List.fromList(<int>[...p1, ...p2, ...p3]);
}

// ===================== 读取 / 校验 =====================

class _Id3 {
  _Id3(this.id, this.data);
  final String id;
  final Uint8List data;
}

List<_Id3> _readId3(Uint8List d) {
  final out = <_Id3>[];
  if (d.length < 10 || d[0] != 0x49 || d[1] != 0x44 || d[2] != 0x33) {
    return out;
  }
  final size = ((d[6] & 0x7F) << 21) |
      ((d[7] & 0x7F) << 14) |
      ((d[8] & 0x7F) << 7) |
      (d[9] & 0x7F);
  var p = 10;
  final end = 10 + size;
  while (p + 10 <= end) {
    final id = ascii.decode(d.sublist(p, p + 4));
    final len = _r32be(d, p + 4);
    if (len <= 0 || p + 10 + len > end) break;
    out.add(_Id3(id, Uint8List.sublistView(d, p + 10, p + 10 + len)));
    p += 10 + len;
  }
  return out;
}

List<String> _readVorbisComments(Uint8List data) {
  var p = 0;
  final vLen = _r32le(data, p);
  p += 4 + vLen;
  final count = _r32le(data, p);
  p += 4;
  final out = <String>[];
  for (var i = 0; i < count; i++) {
    final len = _r32le(data, p);
    p += 4;
    out.add(utf8.decode(data.sublist(p, p + len), allowMalformed: true));
    p += len;
  }
  return out;
}

class _FlacBlk {
  _FlacBlk(this.type, this.data, this.last);
  final int type;
  final Uint8List data;
  final bool last;
}

List<_FlacBlk> _readFlac(Uint8List d) {
  final out = <_FlacBlk>[];
  var p = 4;
  while (p + 4 <= d.length) {
    final last = (d[p] & 0x80) != 0;
    final type = d[p] & 0x7F;
    final len = (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3];
    p += 4;
    out.add(_FlacBlk(type, Uint8List.sublistView(d, p, p + len), last));
    p += len;
    if (last) break;
  }
  return out;
}

class _Mp4Box {
  _Mp4Box(this.type, this.start, this.size);
  final String type;
  final int start;
  final int size;
}

List<_Mp4Box> _readBoxes(Uint8List d, int start, int end) {
  final out = <_Mp4Box>[];
  var p = start;
  while (p + 8 <= end) {
    final size = _r32be(d, p);
    final type = String.fromCharCodes(d.sublist(p + 4, p + 8));
    if (size < 8 || p + size > end) break;
    out.add(_Mp4Box(type, p, size));
    p += size;
  }
  return out;
}

// ===================== 测试 =====================

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('baiji_tagger_');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<File> writeSample(String name, Uint8List bytes) async {
    final f = File('${tmp.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  test('MP3：写入 USLT 与 APIC，音频数据不丢失', () async {
    final src = _buildMp3();
    final f = await writeSample('t.mp3', src);
    final r = await AudioTagger.embed(
      file: f,
      lyrics: kLrc,
      cover: _cover(),
      title: '新标题',
      artist: '歌手',
      album: '专辑',
    );

    expect(r.error, isNull, reason: r.error ?? '');
    expect(r.lyricsEmbedded, isTrue);
    expect(r.coverEmbedded, isTrue);

    final out = await f.readAsBytes();
    final frames = _readId3(out);
    final ids = frames.map((e) => e.id).toList();

    expect(ids, contains('USLT'));
    expect(ids, contains('APIC'));
    expect(ids, contains('TIT2'));

    final uslt = frames.firstWhere((e) => e.id == 'USLT');
    // USLT 载荷：编码字节 + 3 字节语言 + 描述符 + 正文
    expect(utf8.decode(uslt.data, allowMalformed: true), contains('测试歌词'));

    final apic = frames.firstWhere((e) => e.id == 'APIC');
    final jpegStart = _indexOf(apic.data, <int>[0xFF, 0xD8, 0xFF]);
    expect(jpegStart, isNotNull);
    expect(
        apic.data.sublist(jpegStart!), equals(kJpeg), reason: '封面字节应完整保留');

    // 音频尾巴必须原样保留
    final audioTail = Uint8List.sublistView(out, out.length - 2048);
    expect(audioTail, equals(Uint8List.fromList(List.filled(2048, 0x5A))));

    // 原有的 TIT2 旧值不应残留（会被重写为传入的标题）
    final tit2 = frames.firstWhere((e) => e.id == 'TIT2');
    expect(utf8.decode(tit2.data, allowMalformed: true), contains('新标题'));
  });

  test('FLAC：写入 Vorbis Comment LYRICS 与 PICTURE 块', () async {
    final f = await writeSample('t.flac', _buildFlac());
    final r = await AudioTagger.embed(
      file: f,
      lyrics: kLrc,
      cover: _cover(),
      title: '标题',
    );
    expect(r.error, isNull, reason: r.error ?? '');

    final out = await f.readAsBytes();
    final blocks = _readFlac(out);

    expect(blocks.first.type, 0, reason: 'STREAMINFO 必须仍是第一块');
    expect(blocks.last.last, isTrue, reason: '最后一块必须带 last 标志');

    final comment = blocks.firstWhere((b) => b.type == 4);
    final items = _readVorbisComments(comment.data);
    expect(items, contains('LYRICS=$kLrcWritten'));
    expect(items, contains('DATE=2024'), reason: '未知键应保留');
    expect(items.where((e) => e.startsWith('TITLE=')).length, 1,
        reason: '旧 TITLE 应被覆盖而不是重复');
    expect(items, contains('TITLE=标题'));

    final pic = blocks.firstWhere((b) => b.type == 6);
    final jpegStart = _indexOf(pic.data, <int>[0xFF, 0xD8, 0xFF]);
    expect(jpegStart, isNotNull);
    expect(
        pic.data.sublist(jpegStart!), equals(kJpeg), reason: '封面字节应完整保留');
  });

  test('FLAC：STREAMINFO 是唯一块时也能写入', () async {
    final f = await writeSample('t2.flac', _buildFlac(withComment: false));
    final r = await AudioTagger.embed(file: f, lyrics: kLrc);
    expect(r.error, isNull, reason: r.error ?? '');
    final blocks = _readFlac(await f.readAsBytes());
    final comment = blocks.firstWhere((b) => b.type == 4);
    expect(_readVorbisComments(comment.data), contains('LYRICS=$kLrcWritten'));
  });

  test('MP4：写入 ©lyr / covr，并修正 stco 偏移', () async {
    final src = _buildMp4();
    final f = await writeSample('t.m4a', src);

    // 写入前记录 stco 的两个 chunk offset
    int stcoEntry(List<int> d) => _indexOf(d, ascii.encode('stco'))! + 12;
    final beforeEntry = stcoEntry(src);
    final offBefore = <int>[_r32be(src, beforeEntry), _r32be(src, beforeEntry + 4)];

    final r = await AudioTagger.embed(
      file: f,
      lyrics: kLrc,
      cover: _cover(),
      title: '新歌名',
    );
    expect(r.error, isNull, reason: r.error ?? '');

    final out = await f.readAsBytes();
    final roots = _readBoxes(out, 0, out.length);
    final moov = roots.firstWhere((b) => b.type == 'moov');
    final mdat = roots.firstWhere((b) => b.type == 'mdat');

    // 找到 moov → udta → meta → ilst
    final moovKids = _readBoxes(out, moov.start + 8, moov.start + moov.size);
    final udta = moovKids.firstWhere((b) => b.type == 'udta');
    final metaKids = _readBoxes(out, udta.start + 8, udta.start + udta.size);
    final meta = metaKids.firstWhere((b) => b.type == 'meta');
    final ilstKids = _readBoxes(out, meta.start + 12, meta.start + meta.size);
    final ilst = ilstKids.firstWhere((b) => b.type == 'ilst');
    final items = _readBoxes(out, ilst.start + 8, ilst.start + ilst.size);
    final itemTypes = items.map((b) => b.type).toList();

    expect(itemTypes, contains('©lyr'), reason: '实际写入: $itemTypes');
    expect(itemTypes, contains('covr'));
    expect(itemTypes, contains('©nam'));

    // ©nam 只应有一个，且内容被覆盖
    expect(itemTypes.where((t) => t == '©nam').length, 1);

    // stco 必须整体后移了 moov 变长的量
    final afterEntry = stcoEntry(out);
    final offAfter = <int>[_r32be(out, afterEntry), _r32be(out, afterEntry + 4)];
    final delta = out.length - src.length;
    expect(delta, greaterThan(0));
    for (var i = 0; i < 2; i++) {
      expect(offAfter[i], offBefore[i] + delta,
          reason: 'chunk offset #$i 未随 moov 变长而修正');
    }

    // 修正后的偏移必须真的落在 mdat 数据区内
    for (final o in offAfter) {
      expect(o, greaterThanOrEqualTo(mdat.start + 8));
      expect(o, lessThan(mdat.start + mdat.size));
    }
  });

  test('OGG：替换注释包并写入 LYRICS，CRC 与后续页正确', () async {
    final src = _buildOgg();
    final f = await writeSample('t.ogg', src);
    final r = await AudioTagger.embed(
      file: f,
      lyrics: kLrc,
      cover: _cover(),
      title: 'OGG 标题',
    );
    expect(r.error, isNull, reason: r.error ?? '');

    final out = await f.readAsBytes();

    // 第 1 页必须原样保留
    final p1Len = _oggPageLen(src, 0);
    expect(out.sublist(0, p1Len), equals(src.sublist(0, p1Len)));

    // 第 2 页：CRC 必须有效。
    // Ogg 的 CRC 字段是小端存储（libogg 如此），因此不能用"整页 CRC 余数为 0"
    // 来验证（那只在大端追加时成立），要把 CRC 字段清零后重算再比对。
    final p2Start = p1Len;
    final p2Len = _oggPageLen(out, p2Start);
    final p2Page = Uint8List.sublistView(out, p2Start, p2Start + p2Len);
    final stored = _r32le(p2Page, 22);
    final zeroed = Uint8List.fromList(p2Page);
    zeroed[22] = 0;
    zeroed[23] = 0;
    zeroed[24] = 0;
    zeroed[25] = 0;
    expect(_oggCrc(zeroed), stored, reason: '新注释页的 CRC 必须有效');

    final p2Payload = _oggPayload(out, p2Start);
    expect(p2Payload[0], 0x03);
    expect(ascii.decode(p2Payload.sublist(1, 7)), 'vorbis');
    final items = _readVorbisComments(
        Uint8List.sublistView(p2Payload, 7, p2Payload.length));
    expect(items, contains('LYRICS=$kLrcWritten'));
    expect(items, contains('DATE=2024'));
    expect(items.where((e) => e.startsWith('TITLE=')).length, 1);
    expect(items, contains('TITLE=OGG 标题'));
    expect(items.any((e) => e.startsWith('METADATA_BLOCK_PICTURE=')), isTrue);

    // 第 3 页（音频）必须原样保留
    final p3SrcStart = p1Len + _oggPageLen(src, p1Len);
    final tail = src.sublist(p3SrcStart);
    expect(out.sublist(out.length - tail.length), equals(tail));
  });

  test('不支持的扩展名返回错误而不改动文件', () async {
    final src = Uint8List.fromList(List.filled(64, 7));
    final f = await writeSample('t.wav', src);
    final r = await AudioTagger.embed(file: f, lyrics: kLrc);
    expect(r.error, isNotNull);
    expect(await f.readAsBytes(), equals(src), reason: '失败时原文件必须原样保留');
  });
}

int _oggPageLen(List<int> d, int start) {
  final segCount = d[start + 26] & 0xFF;
  var payload = 0;
  for (var i = 0; i < segCount; i++) {
    payload += d[start + 27 + i];
  }
  return 27 + segCount + payload;
}

Uint8List _oggPayload(List<int> d, int start) {
  final segCount = d[start + 26] & 0xFF;
  var payload = 0;
  for (var i = 0; i < segCount; i++) {
    payload += d[start + 27 + i];
  }
  return Uint8List.fromList(d.sublist(start + 27 + segCount, start + 27 + segCount + payload));
}
