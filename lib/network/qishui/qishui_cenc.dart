// 汽水音乐 CENC（cenc-aes-ctr）音频解密库（v2.6.2）。
//
// 移植自随附的 qishui_decrypt.dart（1:1 复刻官方 audioDecryptor.js），
// 去掉 CLI / dart:io 下载部分，作为纯函数库供本地流式中继调用。
//
// 流程：
//   1. spade_a → 32 位 hex AES-128 key（私有位运算 decryptSpade）；
//   2. 解析 MP4 box：stsz(样本大小)/senc(每样本 8 字节 IV 前缀)/
//      stsc/stco(chunk 偏移)/mdat(密文)/stsd(FLAC 元数据)；
//   3. 逐样本 AES-128-CTR 解密（IV = 8B senc_iv + 8B 0）；
//   4. FLAC 档：fLaC + metadata + 明文样本 → .flac
//      AAC 档：重建干净 MP4（enca→mp4a，剥离 sinf/senc/tenc，重写 stco）→ .m4a
//
// 关键约束：spade_a / key 必须与音频字节来自【同一次】取流响应。
// ignore_for_file: curly_braces_in_flow_control_structures
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// 解密结果：明文字节 + 落盘扩展名 / 内容类型 / 编码 / 样本数。
class QishuiDecryptResult {
  final Uint8List buffer;
  final String extension;
  final String contentType;
  final String codec;
  final int sampleCount;

  const QishuiDecryptResult(
    this.buffer,
    this.extension,
    this.contentType,
    this.codec,
    this.sampleCount,
  );
}

// ---------------- AES-128（仅 ECB 单块加密，CTR 由本文件组合）----------------
class _Aes128 {
  final List<List<int>> _roundKeys;

  _Aes128(Uint8List key) : _roundKeys = _expandKey(key);

  static const List<int> _sbox = [
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
  ];
  static const List<int> _rcon = [
    0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36,
  ];

  static List<List<int>> _expandKey(Uint8List key) {
    if (key.length != 16) throw ArgumentError('AES key 必须为 16 字节');
    final w = List<List<int>>.generate(44, (_) => List<int>.filled(4, 0));
    for (var i = 0; i < 4; i++) {
      w[i][0] = key[i * 4]; w[i][1] = key[i * 4 + 1];
      w[i][2] = key[i * 4 + 2]; w[i][3] = key[i * 4 + 3];
    }
    for (var i = 4; i < 44; i++) {
      final t = List<int>.from(w[i - 1]);
      if (i % 4 == 0) {
        final tmp = t[0];
        t[0] = _sbox[t[1]] ^ _rcon[(i ~/ 4) - 1];
        t[1] = _sbox[t[2]]; t[2] = _sbox[t[3]]; t[3] = _sbox[tmp];
      }
      for (var j = 0; j < 4; j++) w[i][j] = w[i - 4][j] ^ t[j];
    }
    final rk = <List<int>>[];
    for (var r = 0; r < 11; r++) {
      final round = <int>[];
      for (var c = 0; c < 4; c++) {
        for (var row = 0; row < 4; row++) round.add(w[r * 4 + c][row]);
      }
      rk.add(round);
    }
    return rk;
  }

  Uint8List encryptBlock(Uint8List input) {
    final s = List<int>.from(input.take(16));
    _addRoundKey(s, 0);
    for (var round = 1; round < 10; round++) {
      _subBytes(s); _shiftRows(s); _mixColumns(s); _addRoundKey(s, round);
    }
    _subBytes(s); _shiftRows(s); _addRoundKey(s, 10);
    return Uint8List.fromList(s);
  }

  void _addRoundKey(List<int> s, int round) {
    final rk = _roundKeys[round];
    for (var i = 0; i < 16; i++) s[i] ^= rk[i];
  }
  void _subBytes(List<int> s) {
    for (var i = 0; i < 16; i++) s[i] = _sbox[s[i]];
  }
  void _shiftRows(List<int> s) {
    int at(int c, int r) => s[c * 4 + r];
    void set(int c, int r, int v) => s[c * 4 + r] = v;
    final t0 = at(0,1), t1 = at(1,1), t2 = at(2,1), t3 = at(3,1);
    set(0,1,t1); set(1,1,t2); set(2,1,t3); set(3,1,t0);
    final u0 = at(0,2), u1 = at(1,2), u2 = at(2,2), u3 = at(3,2);
    set(0,2,u2); set(1,2,u3); set(2,2,u0); set(3,2,u1);
    final v0 = at(0,3), v1 = at(1,3), v2 = at(2,3), v3 = at(3,3);
    set(0,3,v3); set(1,3,v0); set(2,3,v1); set(3,3,v2);
  }
  static int _xtime(int x) => ((x << 1) ^ (((x & 0x80) != 0) ? 0x1b : 0)) & 0xff;
  void _mixColumns(List<int> s) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = s[i], a1 = s[i+1], a2 = s[i+2], a3 = s[i+3];
      final all = a0 ^ a1 ^ a2 ^ a3;
      s[i]   = a0 ^ all ^ _xtime(a0 ^ a1);
      s[i+1] = a1 ^ all ^ _xtime(a1 ^ a2);
      s[i+2] = a2 ^ all ^ _xtime(a2 ^ a3);
      s[i+3] = a3 ^ all ^ _xtime(a3 ^ a0);
    }
  }
}

// ---------------- AES-128-CTR（16 字节 IV 作为初始计数器，大端递增）----------------
class _AesCtr {
  final _Aes128 _aes;
  final Uint8List _counter;
  Uint8List? _keystream;
  int _offset = 16;

  _AesCtr(Uint8List key, Uint8List iv)
      : _aes = _Aes128(key), _counter = Uint8List.fromList(iv);

  void _nextBlock() {
    _keystream = _aes.encryptBlock(_counter);
    _offset = 0;
    for (var i = 15; i >= 0; i--) {
      _counter[i] = (_counter[i] + 1) & 0xff;
      if (_counter[i] != 0) break;
    }
  }

  Uint8List decrypt(Uint8List data) {
    final out = Uint8List(data.length);
    var pos = 0;
    while (pos < data.length) {
      if (_offset >= 16) _nextBlock();
      final n = min(16 - _offset, data.length - pos);
      for (var i = 0; i < n; i++) out[pos + i] = data[pos + i] ^ _keystream![_offset + i];
      _offset += n; pos += n;
    }
    return out;
  }
}

// ---------------- spade_a → 32 位 hex AES key ----------------
int _decodeBase36(int cp) {
  if (cp >= 48 && cp <= 57) return cp - 48;
  if (cp >= 97 && cp <= 122) return cp - 97 + 10;
  return 0xFF;
}

int _bitCount(int n) {
  var v = 0;
  while (n > 0) { v += n & 1; n >>= 1; }
  return v;
}

Uint8List _decryptSpadeInner(Uint8List spadeKey) {
  final result = Uint8List.fromList(spadeKey);
  final buffer = Uint8List(spadeKey.length + 2);
  buffer[0] = 0xFA; buffer[1] = 0x55;
  buffer.setRange(2, buffer.length, spadeKey);
  for (var i = 0; i < result.length; i++) {
    var value = (spadeKey[i] ^ buffer[i]) - _bitCount(i) - 21;
    while (value < 0) value += 0xFF;
    result[i] = value & 0xff;
  }
  return result;
}

/// 把 base64 的 spade_a 解成 32 位 hex AES key；失败返回空串。
String decryptSpadeA(String spadeA) {
  try {
    final bytes = base64.decode(spadeA.trim());
    if (bytes.length < 3) return '';
    final paddingLength = (bytes[0] ^ bytes[1] ^ bytes[2]) - 48;
    if (bytes.length < paddingLength + 2) return '';
    final inner = bytes.sublist(1, bytes.length - paddingLength);
    final decoded = _decryptSpadeInner(inner);
    if (decoded.isEmpty) return '';
    final skip = _decodeBase36(decoded[0]);
    final msgLen = bytes.length - paddingLength - 2;
    final end = 1 + msgLen - skip;
    if (end > decoded.length || end < 1) return '';
    return utf8.decode(decoded.sublist(1, end), allowMalformed: true);
  } catch (_) {
    return '';
  }
}

const String _hexChars = '0123456789abcdef';
Uint8List _hexDecode(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = (_hexChars.indexOf(s[i*2]) << 4) | _hexChars.indexOf(s[i*2+1]);
  }
  return out;
}
String _hexEncode(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) { sb.write(_hexChars[(b >> 4) & 0xf]); sb.write(_hexChars[b & 0xf]); }
  return sb.toString();
}
bool _isHex32(String s) => RegExp(r'^[a-f0-9]{32}$', caseSensitive: false).hasMatch(s.trim());

/// 解析 AES-128 key：优先 hexKey，其次 spade_a。
Uint8List qishuiResolveKey({String? spadeA, String? hexKey}) {
  if (hexKey != null && _isHex32(hexKey)) return _hexDecode(hexKey.trim().toLowerCase());
  if (spadeA != null && spadeA.isNotEmpty) {
    final h = decryptSpadeA(spadeA).trim();
    if (_isHex32(h)) return _hexDecode(h.toLowerCase());
  }
  throw ArgumentError('无法从 spade_a / key 解析出合法 AES-128 密钥');
}

/// 调试用：把 key 转 hex。
String qishuiKeyToHex(List<int> key) => _hexEncode(key);

// ---------------- MP4 box 工具 ----------------
class _Box {
  final String type;
  final int offset;
  final int size;
  _Box(this.type, this.offset, this.size);
  int get dataStart => offset + 8;
  int get dataEnd => offset + size;
}

int _u32(Uint8List d, int o) {
  if (o < 0 || o + 4 > d.length) return 0;
  return (d[o] << 24) | (d[o+1] << 16) | (d[o+2] << 8) | d[o+3];
}
Uint8List _w32(int v) => Uint8List.fromList([
  (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff,
]);

_Box? _findBox(Uint8List d, String type, [int start = 0, int? end]) {
  end ??= d.length;
  var pos = start;
  while (pos < end) {
    if (pos + 8 > end) break;
    final sz = _u32(d, pos);
    if (sz < 8 || pos + sz > end) break;
    final t = String.fromCharCodes(d.sublist(pos + 4, pos + 8));
    if (t == type) return _Box(t, pos, sz);
    final r = _findBox(d, type, pos + 8, pos + sz);
    if (r != null) return r;
    pos += sz;
  }
  return null;
}

const Set<String> _encryptedBoxes = {
  'senc','saio','saiz','sinf','schi','tenc','schm','frma',
};
const Set<String> _containerBoxes = {
  'moov','trak','mdia','minf','stbl','stsd',
};

class _SampleInfo {
  final List<int> sizes;
  final List<Uint8List> ivs;
  final int mdatDataStart;
  final _Box moov, ftyp, stsd;
  _SampleInfo(this.sizes, this.ivs, this.mdatDataStart, this.moov, this.ftyp, this.stsd);
}

_SampleInfo _parseSamples(Uint8List d) {
  final stsz = _findBox(d, 'stsz')!;
  final sampleSize = _u32(d, stsz.dataStart + 4);
  final count = _u32(d, stsz.dataStart + 8);
  final sizes = <int>[];
  if (sampleSize != 0) {
    sizes.addAll(List<int>.filled(count, sampleSize));
  } else {
    for (var i = 0; i < count; i++) sizes.add(_u32(d, stsz.dataStart + 12 + i * 4));
  }
  final senc = _findBox(d, 'senc')!;
  final ivCount = _u32(d, senc.dataStart + 4);
  final ivs = <Uint8List>[];
  for (var i = 0; i < ivCount; i++) {
    final off = senc.dataStart + 8 + i * 8;
    final iv = Uint8List(16);
    iv.setRange(0, 8, d.sublist(off, off + 8));
    ivs.add(iv);
  }
  final mdat = _findBox(d, 'mdat')!;
  final moov = _findBox(d, 'moov')!;
  final ftyp = _findBox(d, 'ftyp')!;
  final stsd = _findBox(d, 'stsd')!;
  return _SampleInfo(sizes, ivs, mdat.dataStart, moov, ftyp, stsd);
}

List<int>? _findFlacMeta(Uint8List stsdData) {
  final marker = utf8.encode('dfLa');
  for (var i = 4; i < stsdData.length - 4; i++) {
    if (stsdData[i] == marker[0] && stsdData[i+1] == marker[1] &&
        stsdData[i+2] == marker[2] && stsdData[i+3] == marker[3]) {
      final boxSize = _u32(stsdData, i - 4);
      if (boxSize >= 8 && i - 4 + boxSize <= stsdData.length) {
        return stsdData.sublist(i + 4, i - 4 + boxSize);
      }
    }
  }
  return null;
}

Uint8List _concat(List<Uint8List> parts) {
  final total = parts.fold<int>(0, (s, p) => s + p.length);
  final out = Uint8List(total);
  var off = 0;
  for (final p in parts) { out.setRange(off, off + p.length, p); off += p.length; }
  return out;
}

QishuiDecryptResult _decryptAudio(Uint8List input, Uint8List key) {
  final info = _parseSamples(input);
  final d = input;

  final decrypted = <Uint8List>[];
  var off = info.mdatDataStart;
  for (var i = 0; i < info.sizes.length; i++) {
    final sz = info.sizes[i];
    if (off + sz > d.length) throw StateError('样本数据越界');
    final iv = info.ivs[i];
    final ctr = _AesCtr(key, iv);
    decrypted.add(ctr.decrypt(Uint8List.fromList(d.sublist(off, off + sz))));
    off += sz;
  }

  // FLAC 档：拼 fLaC + metadata + 明文样本。
  final flacMeta = _findFlacMeta(Uint8List.fromList(
      d.sublist(info.stsd.dataStart, info.stsd.dataEnd)));
  if (flacMeta != null) {
    final metaStart = flacMeta.length > 4 ? 4 : 0;
    final out = _concat([
      Uint8List.fromList(utf8.encode('fLaC')),
      Uint8List.fromList(flacMeta.sublist(metaStart)),
      ...decrypted,
    ]);
    return QishuiDecryptResult(out, 'flac', 'audio/flac', 'flac', info.sizes.length);
  }

  // AAC 档：重建干净 MP4。
  final stsc = _findBox(d, 'stsc')!;
  final stco = _findBox(d, 'stco')!;
  final entryCount = _u32(d, stsc.dataStart + 4);
  final entries = <List<int>>[];
  for (var i = 0; i < entryCount; i++) {
    final b = stsc.dataStart + 8 + i * 12;
    entries.add([_u32(d, b), _u32(d, b + 4)]);
  }
  final chunkCount = _u32(d, stco.dataStart + 4);
  final stcoHeader = Uint8List.fromList(d.sublist(stco.dataStart, stco.dataStart + 8));

  List<int> calcOffsets(int base) {
    final offsets = <int>[];
    var cur = base, si = 0;
    for (var ci = 1; ci <= chunkCount; ci++) {
      offsets.add(cur);
      var spc = 0;
      for (var ei = 0; ei < entries.length; ei++) {
        final fc = entries[ei][0];
        final nxt = ei + 1 < entries.length ? entries[ei+1][0] : null;
        if (ci >= fc && (nxt == null || ci < nxt)) { spc = entries[ei][1]; break; }
      }
      for (var k = 0; k < spc; k++) {
        if (si < info.sizes.length) cur += info.sizes[si];
        si++;
      }
    }
    return offsets;
  }

  List<int> chunkOffsets = [];
  Uint8List processTree(int off, int size) {
    final parts = <Uint8List>[];
    var p = off + 8;
    final end = off + size;
    while (p < end) {
      if (p + 8 > end) { parts.add(Uint8List.fromList(d.sublist(p, end))); break; }
      final sz = _u32(d, p);
      final t = String.fromCharCodes(d.sublist(p + 4, p + 8));
      if (sz < 8 || p + sz > end) { parts.add(Uint8List.fromList(d.sublist(p, end))); break; }
      if (_encryptedBoxes.contains(t)) { p += sz; continue; }
      if (t == 'enca' || _containerBoxes.contains(t)) {
        final inner = processTree(p, sz);
        final nt = t == 'enca' ? 'mp4a' : t;
        parts.add(_w32(inner.length + 8));
        parts.add(Uint8List.fromList(utf8.encode(nt)));
        parts.add(inner);
        p += sz; continue;
      }
      if (t == 'stco') {
        final body = _concat(chunkOffsets.map(_w32).toList());
        final nb = _concat([stcoHeader, body]);
        parts.add(_w32(nb.length + 8));
        parts.add(Uint8List.fromList(utf8.encode('stco')));
        parts.add(nb);
        p += sz; continue;
      }
      parts.add(Uint8List.fromList(d.sublist(p, p + sz)));
      p += sz;
    }
    return _concat(parts);
  }

  chunkOffsets = calcOffsets(0);
  final dummyMoov = processTree(info.moov.offset, info.moov.size);
  final newMdatOffset = info.ftyp.size + dummyMoov.length + 16;
  chunkOffsets = calcOffsets(newMdatOffset);
  final cleanMoov = processTree(info.moov.offset, info.moov.size);
  final mdatData = _concat(decrypted);

  final out = _concat([
    Uint8List.fromList(d.sublist(info.ftyp.offset, info.ftyp.offset + info.ftyp.size)),
    _w32(cleanMoov.length + 8),
    Uint8List.fromList(utf8.encode('moov')),
    cleanMoov,
    _w32(mdatData.length + 8),
    Uint8List.fromList(utf8.encode('mdat')),
    mdatData,
  ]);
  return QishuiDecryptResult(out, 'm4a', 'audio/mp4', 'mp4', info.sizes.length);
}

/// 公开入口：解密完整 CENC 音频字节（spade_a 需与音频同源）。
QishuiDecryptResult qishuiDecrypt(Uint8List input,
    {String? spadeA, String? hexKey}) {
  final key = qishuiResolveKey(spadeA: spadeA, hexKey: hexKey);
  return _decryptAudio(input, key);
}
