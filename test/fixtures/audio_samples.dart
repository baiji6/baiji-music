/// 音频样本构造器（仅供测试使用）。
///
/// 与 `audio_tagger_test.dart` 里的样本不同：那边是「最小可写」样本，
/// 字段大量留空；这里为读取端设计，全部参数化，能精确指定标签、时长、
/// 编码方式，好让 `audio_reader` 的每条解析分支都有可验算的期望值。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ===================== 通用字节工具 =====================

BytesBuilder bb() => BytesBuilder(copy: false);

void u32be(BytesBuilder b, int v) =>
    b.add(<int>[(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);

void u32le(BytesBuilder b, int v) =>
    b.add(<int>[v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

void u16be(BytesBuilder b, int v) => b.add(<int>[(v >> 8) & 0xFF, v & 0xFF]);

void u16le(BytesBuilder b, int v) => b.add(<int>[v & 0xFF, (v >> 8) & 0xFF]);

/// 一张 1x1 的最小 JPEG，当作封面样本。
final Uint8List kJpeg = Uint8List.fromList(<int>[
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, //
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, //
  0xFF, 0xD9, //
]);

// ===================== ID3v2 =====================

/// ID3 文本编码方式（对应标签里的 encoding 字节）。
enum Id3Enc { latin1, utf16bom, utf16be, utf8 }

int get _bomBe => 0xFEFF;

Uint8List _encText(String text, Id3Enc enc) {
  final b = bb();
  switch (enc) {
    case Id3Enc.latin1:
      b.addByte(0x00);
      b.add(latin1.encode(text));
    case Id3Enc.utf16bom:
      b.addByte(0x01);
      u16be(b, _bomBe);
      b.add(_utf16Units(text, bigEndian: true));
    case Id3Enc.utf16be:
      b.addByte(0x02);
      b.add(_utf16Units(text, bigEndian: true));
    case Id3Enc.utf8:
      b.addByte(0x03);
      b.add(utf8.encode(text));
  }
  return b.takeBytes();
}

/// 把字符串拆成 UTF-16 码元（大端序），供手工编码使用。
Uint8List _utf16Units(String s, {required bool bigEndian}) {
  final out = <int>[];
  for (final unit in s.codeUnits) {
    if (bigEndian) {
      out.add((unit >> 8) & 0xFF);
      out.add(unit & 0xFF);
    } else {
      out.add(unit & 0xFF);
      out.add((unit >> 8) & 0xFF);
    }
  }
  return Uint8List.fromList(out);
}

/// ID3v2 帧：id(4) + size(4) + flags(2) + payload。
///
/// [major] 决定 size 是否用 syncsafe 编码（v2.4 起）。
Uint8List _id3Frame(String id, List<int> payload, int major) {
  final b = bb();
  b.add(ascii.encode(id));
  if (major >= 4) {
    final n = payload.length;
    b.add(<int>[
      (n >> 21) & 0x7F,
      (n >> 14) & 0x7F,
      (n >> 7) & 0x7F,
      n & 0x7F,
    ]);
  } else {
    u32be(b, payload.length);
  }
  b.add(<int>[0x00, 0x00]);
  b.add(payload);
  return b.takeBytes();
}

/// TIT2 / TPE1 / TALB 这类文本帧。
Uint8List _textFrame(String id, String text, Id3Enc enc, int major) =>
    _id3Frame(id, _encText(text, enc), major);

/// USLT：`enc(1) + lang(3) + 描述符 + 终止符 + 正文`，描述符这里留空。
Uint8List _usltFrame(String lyric, Id3Enc enc, int major) {
  final b = bb();
  b.addByte(enc.index);
  b.add(ascii.encode('eng'));
  // 空描述符：直接跟终止符
  if (enc == Id3Enc.utf16bom || enc == Id3Enc.utf16be) {
    b.add(<int>[0x00, 0x00]);
    b.add(_utf16Units(lyric, bigEndian: true));
  } else {
    b.addByte(0x00);
    b.add(enc == Id3Enc.utf8 ? utf8.encode(lyric) : latin1.encode(lyric));
  }
  return _id3Frame('USLT', b.takeBytes(), major);
}

/// APIC：`enc(1) + mime\0 + picType(1) + 描述 + 终止符 + 图片数据`。
Uint8List _apicFrame(Uint8List image, String mime, Id3Enc enc, int major) {
  final b = bb();
  b.addByte(enc.index);
  b.add(latin1.encode(mime));
  b.addByte(0x00);
  b.addByte(0x03); // 封面（正面）
  if (enc == Id3Enc.utf16bom || enc == Id3Enc.utf16be) {
    b.add(<int>[0x00, 0x00]); // 空描述 + 终止符
  } else {
    b.addByte(0x00);
  }
  b.add(image);
  return _id3Frame('APIC', b.takeBytes(), major);
}

/// 完整的 ID3v2 标签（含 10 字节头）。
Uint8List buildId3v2({
  String title = '',
  String artist = '',
  String album = '',
  String lyric = '',
  Uint8List? cover,
  String coverMime = 'image/jpeg',
  Id3Enc enc = Id3Enc.utf8,
  int major = 3,
  int padding = 0,
}) {
  final body = bb();
  if (title.isNotEmpty) body.add(_textFrame('TIT2', title, enc, major));
  if (artist.isNotEmpty) body.add(_textFrame('TPE1', artist, enc, major));
  if (album.isNotEmpty) body.add(_textFrame('TALB', album, enc, major));
  if (lyric.isNotEmpty) body.add(_usltFrame(lyric, enc, major));
  if (cover != null) body.add(_apicFrame(cover, coverMime, enc, major));
  if (padding > 0) body.add(List<int>.filled(padding, 0));

  final payload = body.takeBytes();
  final out = bb();
  out.add(ascii.encode('ID3'));
  out.add(<int>[major, 0x00, 0x00]);
  final n = payload.length;
  out.add(<int>[
    (n >> 21) & 0x7F,
    (n >> 14) & 0x7F,
    (n >> 7) & 0x7F,
    n & 0x7F,
  ]);
  out.add(payload);
  return out.takeBytes();
}

/// ID3v1：固定 128 字节，贴在文件末尾。
Uint8List buildId3v1({
  String title = '',
  String artist = '',
  String album = '',
}) {
  final t = Uint8List(128);
  t.setRange(0, 3, ascii.encode('TAG'));
  _putFixed(t, 3, 30, title);
  _putFixed(t, 33, 30, artist);
  _putFixed(t, 63, 30, album);
  return t;
}

/// ID3v1 只能存 Latin-1，写不进去的字符退化成 `?`（与真实编码器行为一致）。
void _putFixed(Uint8List dst, int off, int len, String value) {
  var s = value.length > len ? value.substring(0, len) : value;
  s = s.replaceAll(RegExp(r'[^\x00-\xFF]'), '?');
  final bytes = latin1.encode(s);
  dst.setRange(off, off + bytes.length, bytes);
}

// ===================== MP3 =====================

/// MPEG1 Layer3 码率（kbps）→ 帧头索引。
const _kMp3Bitrates = <int, int>{
  32: 1, 40: 2, 48: 3, 56: 4, 64: 5, 80: 6, 96: 7, 112: 8, 128: 9,
  160: 10, 192: 11, 224: 12, 256: 13, 320: 14,
};

/// MPEG1 采样率 → 帧头索引。
const _kMp3SampleRates = <int, int>{44100: 0, 48000: 1, 32000: 2};

/// MPEG1 Layer3 帧头（4 字节）。
Uint8List mpegFrameHeader({
  int bitrateKbps = 128,
  int sampleRate = 44100,
  bool mono = false,
}) {
  final br = _kMp3Bitrates[bitrateKbps] ?? 9;
  final sr = _kMp3SampleRates[sampleRate] ?? 0;
  return Uint8List.fromList(<int>[
    0xFF,
    0xFB, // MPEG1 / Layer3 / 无 CRC
    (br << 4) | (sr << 2),
    mono ? 0xC0 : 0x00, // 11 = 单声道，00 = 立体声
  ]);
}

/// 帧长（字节）：MPEG1 Layer3 为 `144 * bitrate / sampleRate + padding`。
int mpegFrameSize({int bitrateKbps = 128, int sampleRate = 44100}) =>
    144 * bitrateKbps * 1000 ~/ sampleRate;

/// 构造 MP3 样本。
///
/// 布局：`[ID3v2][帧头 + 侧信息 + Xing/VBRI][音频填充][ID3v1]`
///
/// - [xingFrames] 非空时写 Xing 头，读取端应算出
///   `frames * 1152 / sampleRate` 秒
/// - [vbriFrames] 非空时写 VBRI 头（与 Xing 同位置，二者互斥）
/// - 两者都没有时走 CBR 估算：`音频字节数 * 8 / 码率`
Uint8List buildMp3({
  String title = '',
  String artist = '',
  String album = '',
  String lyric = '',
  Uint8List? cover,
  String coverMime = 'image/jpeg',
  Id3Enc enc = Id3Enc.utf8,
  int id3Major = 3,
  bool withId3v2 = true,
  bool withId3v1 = false,
  String? v1Title,
  String? v1Artist,
  String? v1Album,
  int? xingFrames,
  int? vbriFrames,
  int audioBytes = 8192,
  int bitrateKbps = 128,
  int sampleRate = 44100,
}) {
  final out = bb();

  if (withId3v2) {
    out.add(buildId3v2(
      title: title,
      artist: artist,
      album: album,
      lyric: lyric,
      cover: cover,
      coverMime: coverMime,
      enc: enc,
      major: id3Major,
    ));
  }

  // 第一个 MPEG 帧：帧头 + 侧信息(32) + 可选 Xing/VBRI
  out.add(mpegFrameHeader(bitrateKbps: bitrateKbps, sampleRate: sampleRate));
  out.add(List<int>.filled(32, 0)); // 侧信息（MPEG1 立体声）

  if (xingFrames != null) {
    final x = bb();
    x.add(ascii.encode('Xing'));
    u32be(x, 0x0001); // flags: 含 frames 字段
    u32be(x, xingFrames);
    out.add(x.takeBytes());
  } else if (vbriFrames != null) {
    final v = bb();
    v.add(ascii.encode('VBRI'));
    v.add(List<int>.filled(10, 0)); // version(2) + delay(2) + quality(2) + bytes(4)
    u32be(v, vbriFrames); // 偏移 14 处是总帧数
    v.add(List<int>.filled(12, 0));
    out.add(v.takeBytes());
  }

  // 音频填充（0x5A 不会误判成帧头）
  final used = 4 + 32 + (xingFrames != null || vbriFrames != null ? 12 : 0);
  final rest = audioBytes - used;
  if (rest > 0) out.add(List<int>.filled(rest, 0x5A));

  if (withId3v1) {
    out.add(buildId3v1(
      title: v1Title ?? title,
      artist: v1Artist ?? artist,
      album: v1Album ?? album,
    ));
  }

  return out.takeBytes();
}

// ===================== FLAC =====================

/// FLAC METADATA_BLOCK：`[last|type](1) + length(3) + payload`。
Uint8List _flacBlock(int type, List<int> payload, {bool last = false}) {
  final b = bb();
  b.addByte((last ? 0x80 : 0x00) | (type & 0x7F));
  final n = payload.length;
  b.add(<int>[(n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF]);
  b.add(payload);
  return b.takeBytes();
}

/// STREAMINFO：34 字节。采样率在 payload[10..12]，总样本数在 payload[13..17]。
Uint8List flacStreamInfo({int sampleRate = 44100, int totalSamples = 0}) {
  final p = Uint8List(34);
  // 最小/最大块大小
  p[0] = 0x10;
  p[1] = 0x00;
  p[2] = 0x10;
  p[3] = 0x00;
  // 采样率 20 位：payload[10]<<12 | payload[11]<<4 | payload[12]>>4
  p[10] = (sampleRate >> 12) & 0xFF;
  p[11] = (sampleRate >> 4) & 0xFF;
  p[12] = ((sampleRate & 0x0F) << 4) | 0x01; // 低 4 位 + 声道(2 声道=001)
  // 总样本数 36 位：payload[13] 低 4 位 + payload[14..17]
  p[13] = (totalSamples >> 32) & 0x0F;
  p[14] = (totalSamples >> 24) & 0xFF;
  p[15] = (totalSamples >> 16) & 0xFF;
  p[16] = (totalSamples >> 8) & 0xFF;
  p[17] = totalSamples & 0xFF;
  return Uint8List.fromList(p);
}

/// Vorbis Comment：`vendorLen(LE32) + vendor + count(LE32) + 条目…`
Uint8List vorbisCommentBlock(List<String> comments, {String vendor = 'baiji'}) {
  final b = bb();
  u32le(b, vendor.length);
  b.add(ascii.encode(vendor));
  u32le(b, comments.length);
  for (final c in comments) {
    final e = utf8.encode(c);
    u32le(b, e.length);
    b.add(e);
  }
  return b.takeBytes();
}

/// FLAC PICTURE：`type(4) + mimeLen(4) + mime + descLen(4) + desc +
/// w(4) + h(4) + depth(4) + colors(4) + dataLen(4) + data`
Uint8List flacPictureBlock(Uint8List image, String mime) {
  final b = bb();
  u32be(b, 3); // 封面（正面）
  u32be(b, mime.length);
  b.add(latin1.encode(mime));
  u32be(b, 0); // 空描述
  u32be(b, 1); // 宽
  u32be(b, 1); // 高
  u32be(b, 24); // 色深
  u32be(b, 0); // 颜色数
  u32be(b, image.length);
  b.add(image);
  return b.takeBytes();
}

Uint8List buildFlac({
  String title = '',
  String artist = '',
  String album = '',
  String lyric = '',
  Uint8List? cover,
  String coverMime = 'image/jpeg',
  int sampleRate = 44100,
  int totalSamples = 0,
  bool withComment = true,
}) {
  final out = bb();
  out.add(ascii.encode('fLaC'));

  out.add(_flacBlock(0, flacStreamInfo(
    sampleRate: sampleRate,
    totalSamples: totalSamples,
  )));

  if (withComment) {
    final items = <String>[];
    if (title.isNotEmpty) items.add('TITLE=$title');
    if (artist.isNotEmpty) items.add('ARTIST=$artist');
    if (album.isNotEmpty) items.add('ALBUM=$album');
    if (lyric.isNotEmpty) items.add('LYRICS=$lyric');
    out.add(_flacBlock(4, vorbisCommentBlock(items)));
  }

  if (cover != null) {
    out.add(_flacBlock(6, flacPictureBlock(cover, coverMime), last: true));
  }

  out.add(List<int>.filled(1024, 0x3C)); // 伪音频帧
  return out.takeBytes();
}

// ===================== MP4 / M4A =====================

/// MP4 盒子：`size(4, BE) + type(4) + payload`。
Uint8List mkBox(String type, List<int> payload) {
  final b = bb();
  u32be(b, 8 + payload.length);
  b.add(latin1.encode(type));
  b.add(payload);
  return b.takeBytes();
}

/// mvhd 盒：version 0 用 32 位字段，version 1 用 64 位。
Uint8List mvhdBox({int timescale = 44100, int duration = 0, int version = 0}) {
  final p = bb();
  p.add(<int>[version, 0, 0, 0]); // version + flags
  if (version == 1) {
    p.add(List<int>.filled(8, 0)); // creation (64)
    p.add(List<int>.filled(8, 0)); // modification (64)
    u32be(p, timescale);
    // duration (64)
    p.add(<int>[
      0, 0, 0, 0,
      (duration >> 24) & 0xFF,
      (duration >> 16) & 0xFF,
      (duration >> 8) & 0xFF,
      duration & 0xFF,
    ]);
  } else {
    p.add(List<int>.filled(4, 0)); // creation (32)
    p.add(List<int>.filled(4, 0)); // modification (32)
    u32be(p, timescale);
    u32be(p, duration);
  }
  p.add(List<int>.filled(76, 0)); // 矩阵 / 预定义字段 / next_track_id
  return mkBox('mvhd', p.takeBytes());
}

/// ilst 条目：`data` 盒包一层，内容为 UTF-8 文本或图片字节。
Uint8List _ilstTextItem(String type, String text) {
  final d = bb();
  d.add(<int>[0, 0, 0, 1]); // version + flags(type=1 表示 UTF-8)
  d.add(<int>[0, 0, 0, 0]); // locale
  d.add(utf8.encode(text));
  return mkBox(type, mkBox('data', d.takeBytes()));
}

Uint8List _ilstCoverItem(Uint8List image) {
  final d = bb();
  d.add(<int>[0, 0, 0, 13]); // flags = 13 表示 JPEG（PNG 为 14）
  d.add(<int>[0, 0, 0, 0]);
  d.add(image);
  return mkBox('covr', mkBox('data', d.takeBytes()));
}

Uint8List buildMp4({
  String title = '',
  String artist = '',
  String album = '',
  String lyric = '',
  Uint8List? cover,
  int timescale = 44100,
  int duration = 0,
  int mvhdVersion = 0,
  bool moovAtTail = false,
}) {
  final items = bb();
  if (title.isNotEmpty) items.add(_ilstTextItem('©nam', title));
  if (artist.isNotEmpty) items.add(_ilstTextItem('©ART', artist));
  if (album.isNotEmpty) items.add(_ilstTextItem('©alb', album));
  if (lyric.isNotEmpty) items.add(_ilstTextItem('©lyr', lyric));
  if (cover != null) items.add(_ilstCoverItem(cover));

  final ilst = mkBox('ilst', items.takeBytes());
  final hdlr = mkBox('hdlr', List<int>.filled(24, 0));
  // meta 是 FullBox：4 字节 version/flags 之后才是子盒
  final meta = mkBox('meta', <int>[0, 0, 0, 0, ...hdlr, ...ilst]);
  final udta = mkBox('udta', meta);
  final mvhd = mvhdBox(
    timescale: timescale,
    duration: duration,
    version: mvhdVersion,
  );
  final trak = mkBox('trak', List<int>.filled(32, 0));
  final moov = mkBox('moov', <int>[...mvhd, ...trak, ...udta]);

  final ftyp = mkBox('ftyp', List<int>.filled(8, 0));
  final mdat = mkBox('mdat', List<int>.filled(1000, 0x77));

  final all = bb();
  if (moovAtTail) {
    all.add(ftyp);
    all.add(mdat);
    all.add(moov);
  } else {
    all.add(ftyp);
    all.add(moov);
    all.add(mdat);
  }
  return all.takeBytes();
}

// ===================== OGG =====================

/// Ogg 页 CRC：多项式 0x04C11DB7，初值 0，无反射。
///
/// 读取端不校验 CRC，但样本保持格式完整，便于将来扩展。
int oggCrc(Uint8List data) {
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

Uint8List oggPage({
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

  final b = bb();
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
  b.add(<int>[0, 0, 0, 0]); // CRC 占位
  b.addByte(segCount);
  b.add(seg);
  b.add(packet);

  final bytes = b.takeBytes();
  final crc = oggCrc(bytes);
  bytes[22] = crc & 0xFF;
  bytes[23] = (crc >> 8) & 0xFF;
  bytes[24] = (crc >> 16) & 0xFF;
  bytes[25] = (crc >> 24) & 0xFF;
  return bytes;
}

/// 构造 Ogg 样本。
///
/// [opus] 为真时首页写 OpusHead（采样率恒 48000），否则写 Vorbis
/// identification header。末页的 granulePosition 决定时长。
Uint8List buildOgg({
  String title = '',
  String artist = '',
  String album = '',
  String lyric = '',
  Uint8List? cover,
  String coverMime = 'image/jpeg',
  int sampleRate = 44100,
  int granule = 0,
  bool opus = false,
}) {
  final out = bb();

  // ---- 第 1 页：identification header ----
  final id = bb();
  if (opus) {
    id.add(ascii.encode('OpusHead'));
    id.addByte(1); // version
    id.addByte(2); // channels
    u16le(id, 312); // pre-skip
    u32le(id, 48000); // input sample rate
    id.add(<int>[0, 0]); // output gain + channel mapping family
  } else {
    id.addByte(0x01);
    id.add(ascii.encode('vorbis'));
    id.add(List<int>.filled(4, 0)); // version(4)
    id.addByte(2); // channels
    u32le(id, sampleRate); // 偏移 11 处
    id.add(List<int>.filled(14, 0)); // bitrate 三元组等
  }
  out.add(oggPage(
    headerType: 2, // BOS
    granule: 0,
    serial: 0x1234,
    seq: 0,
    packet: id.takeBytes(),
  ));

  // ---- 第 2 页：注释头 ----
  final items = <String>[];
  if (title.isNotEmpty) items.add('TITLE=$title');
  if (artist.isNotEmpty) items.add('ARTIST=$artist');
  if (album.isNotEmpty) items.add('ALBUM=$album');
  if (lyric.isNotEmpty) items.add('LYRICS=$lyric');
  if (cover != null) {
    final blk = flacPictureBlock(cover, coverMime);
    items.add('METADATA_BLOCK_PICTURE=${base64Encode(blk)}');
  }

  final cm = bb();
  if (opus) {
    cm.add(ascii.encode('OpusTags'));
  } else {
    cm.addByte(0x03);
    cm.add(ascii.encode('vorbis'));
  }
  cm.add(vorbisCommentBlock(items));
  out.add(oggPage(
    headerType: 0,
    granule: 0,
    serial: 0x1234,
    seq: 1,
    packet: cm.takeBytes(),
  ));

  // ---- 第 3 页：音频数据（granule 决定时长） ----
  out.add(oggPage(
    headerType: 4, // EOS
    granule: granule,
    serial: 0x1234,
    seq: 2,
    packet: Uint8List.fromList(List<int>.filled(600, 0x2F)),
  ));

  return out.takeBytes();
}

// ===================== WAV =====================

/// 构造 WAV 样本。
///
/// fmt 块按标准 16 字节 PCM 布局：
/// `format(2) + channels(2) + sampleRate(4) + byteRate(4) + blockAlign(2) + bits(2)`
Uint8List buildWav({
  String title = '',
  String artist = '',
  String album = '',
  int sampleRate = 44100,
  int byteRate = 176400,
  int dataSize = 176400,
}) {
  final fmt = Uint8List(16);
  fmt[0] = 0x01; // PCM
  fmt[2] = 0x02; // 2 声道
  fmt.setRange(4, 8, <int>[
    sampleRate & 0xFF,
    (sampleRate >> 8) & 0xFF,
    (sampleRate >> 16) & 0xFF,
    (sampleRate >> 24) & 0xFF,
  ]);
  fmt.setRange(8, 12, <int>[
    byteRate & 0xFF,
    (byteRate >> 8) & 0xFF,
    (byteRate >> 16) & 0xFF,
    (byteRate >> 24) & 0xFF,
  ]);
  fmt[12] = 0x04; // blockAlign
  fmt[14] = 0x10; // 16 bit

  final out = bb();
  out.add(ascii.encode('RIFF'));
  // RIFF size 只对完整文件有意义，样本里先占位
  u32le(out, 0);
  out.add(ascii.encode('WAVE'));

  out.add(ascii.encode('fmt '));
  u32le(out, fmt.length);
  out.add(fmt);

  // LIST/INFO（NAM / IART / IPRD 都是定长字段，按其对齐全长写入）
  final infoItems = <List<int>>[];
  if (title.isNotEmpty) infoItems.add(_infoChunk('INAM', title));
  if (artist.isNotEmpty) infoItems.add(_infoChunk('IART', artist));
  if (album.isNotEmpty) infoItems.add(_infoChunk('IPRD', album));
  if (infoItems.isNotEmpty) {
    final infoBody = bb();
    infoBody.add(ascii.encode('INFO'));
    for (final it in infoItems) {
      infoBody.add(it);
    }
    out.add(ascii.encode('LIST'));
    u32le(out, infoBody.length);
    out.add(infoBody.takeBytes());
  }

  out.add(ascii.encode('data'));
  u32le(out, dataSize);
  out.add(List<int>.filled(dataSize, 0));

  final bytes = out.takeBytes();
  // 回填 RIFF size = 文件长度 - 8
  final riffSize = bytes.length - 8;
  bytes[4] = riffSize & 0xFF;
  bytes[5] = (riffSize >> 8) & 0xFF;
  bytes[6] = (riffSize >> 16) & 0xFF;
  bytes[7] = (riffSize >> 24) & 0xFF;
  return bytes;
}

/// INFO 子块：值按偶数长度对齐（不足补 0）。
List<int> _infoChunk(String id, String value) {
  final raw = utf8.encode(value);
  final padded = raw.length.isEven ? raw : <int>[...raw, 0];
  final b = bb();
  b.add(ascii.encode(id));
  u32le(b, padded.length);
  b.add(padded);
  return b.takeBytes();
}

// ===================== 落盘工具 =====================

/// 把样本写到临时目录，返回路径。
///
/// 读取器按扩展名做格式回退识别，所以后缀必须给对。
Future<String> writeSample(
  Directory dir,
  String fileName,
  List<int> bytes,
) async {
  final f = File('${dir.path}${Platform.pathSeparator}$fileName');
  await f.writeAsBytes(bytes);
  return f.path;
}
