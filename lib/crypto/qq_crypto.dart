/// QQ 音乐私有协议算法库（纯 Dart 移植）。
///
/// 所有实现均 1:1 对应原 Android 工程的 `cpp/qqapi/alg/*.c`，
/// 用于替代原方案中依赖 JNI 的原生 .so，使算法在六个平台完全可移植。
/// 注意：Dart int 为 64 位，所有 32 位运算需显式掩码保持语义一致。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:crypto/crypto.dart' as crypto;

// ==================== hex / base64 ====================

/// 字节数组 -> 小写 hex 字符串。
String hexEncode(Uint8List data) {
  const chars = '0123456789abcdef';
  final sb = StringBuffer();
  for (final b in data) {
    sb.write(chars[b >> 4]);
    sb.write(chars[b & 0xf]);
  }
  return sb.toString();
}

/// hex 字符串 -> 字节数组。
Uint8List hexDecode(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  var n = 0;
  for (var i = 0; i + 1 < hex.length; i += 2) {
    final hi = _hexVal(hex.codeUnitAt(i));
    final lo = _hexVal(hex.codeUnitAt(i + 1));
    if (hi < 0 || lo < 0) break;
    out[n++] = (hi << 4) | lo;
  }
  return out.sublist(0, n);
}

int _hexVal(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  return -1;
}

/// 标准 base64 编码（带尾随 '=' 补位，与 C 实现一致）。
String b64Encode(Uint8List data) => base64.encode(data);

/// 标准 base64 解码。
Uint8List b64Decode(String s) => base64.decode(s);

// ==================== random（自研 xorshift，保证六端一致） ====================

class QqRandom {
  int _state;

  QqRandom([int? seed])
      : _state = seed ??
            (DateTime.now().microsecondsSinceEpoch ^
                (DateTime.now().millisecond << 32)) |
                0x123456789abcdef0;

  void _seed() {
    if (_state == 0) {
      _state = (DateTime.now().microsecondsSinceEpoch ^
              (DateTime.now().millisecond << 32)) |
          0x123456789abcdef0;
    }
  }

  /// 与 C 实现保持一致（xorshift64：13/7/17 轮换，按 64 位无符号语义）。
  void randomBytes(Uint8List out) {
    _seed();
    const mask = 0xFFFFFFFFFFFFFFFF;
    for (var i = 0; i < out.length; i++) {
      // << 与 >> 按 C 的 uint64 逻辑移位语义：
      // 左移截断用 & mask；右移必须用无符号右移 >>>，避免符号扩展。
      _state = (_state ^ (_state << 13)) & mask;
      _state = (_state ^ (_state >>> 7)) & mask;
      _state = (_state ^ (_state << 17)) & mask;
      out[i] = _state & 0xff;
    }
  }

  /// [min, max] 闭区间随机整数（64 位无符号取模，与 C qq_rand_int 一致）。
  int randInt(int min, int max) {
    if (max < min) return min;
    final b = Uint8List(8);
    randomBytes(b);
    var v = BigInt.zero;
    for (final byte in b) {
      v = (v << 8) | BigInt.from(byte);
    }
    final range = BigInt.from(max - min + 1);
    return min + (v % range).toInt();
  }

  /// 生成 UUID v4 风格字符串。
  String uuid() {
    final b = Uint8List(16);
    randomBytes(b);
    b[6] = ((b[6] & 0x0f) | 0x40);
    b[8] = ((b[8] & 0x3f) | 0x80);
    final sb = StringBuffer();
    for (var i = 0; i < 16; i++) {
      sb.write(b[i].toRadixString(16).padLeft(2, '0'));
      if (i == 3 || i == 5 || i == 7 || i == 9) sb.write('-');
    }
    return sb.toString();
  }
}

// ==================== hash33（JS 有符号 32 位语义） ====================

/// 与 C 实现一致的 hash33（模拟 JS 32 位有符号溢出，最后 & 0x7FFFFFFF）。
/// C 按 UTF-8 字节逐个处理，Dart 用 utf8.encode 保持逐字节语义一致。
int hash33(String s, [int seed = 0]) {
  var h = seed;
  final bytes = utf8.encode(s);
  for (final c in bytes) {
    h = ((h << 5) + h + c) & 0xFFFFFFFF;
    if (h >= 0x80000000) h -= 0x100000000;
    if (h < -0x80000000) h += 0x100000000;
  }
  return 0x7FFFFFFF & h;
}

// ==================== zzc sign（SHA1 派生签名） ====================

const List<int> _part1Indexes = [23, 14, 6, 36, 16, 7, 19];
const List<int> _part2Indexes = [16, 1, 32, 12, 19, 27, 8, 5];
const List<int> _scrambleValues = [
  89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143,
  161, 121, 179,
];

/// 计算 zzc 签名：sha1 -> 取段 -> xor -> base64(去特殊字符) -> 拼接小写。
String zzcSign(String payload) {
  final digest = crypto.sha1.convert(utf8.encode(payload)).bytes;
  var hashHex = hexEncode(Uint8List.fromList(digest)).toUpperCase();

  final part1 = StringBuffer();
  for (final i in _part1Indexes) {
    part1.write(hashHex[i]);
  }
  final part2 = StringBuffer();
  for (final i in _part2Indexes) {
    part2.write(hashHex[i]);
  }

  final part3 = Uint8List(20);
  for (var i = 0; i < 20; i++) {
    final pair = int.parse(hashHex.substring(i * 2, i * 2 + 2), radix: 16);
    part3[i] = (_scrambleValues[i] ^ pair) & 0xff;
  }
  var b64Raw = b64Encode(part3);
  final b64 = StringBuffer();
  for (var i = 0; i < b64Raw.length; i++) {
    final ch = b64Raw[i];
    if (ch == '/' || ch == '\\' || ch == '+' || ch == '=') continue;
    b64.write(ch);
  }

  final buf = 'zzc$part1$b64$part2'.toLowerCase();
  return buf;
}

// ==================== 3DES（严格对应 JS tripledes.js 移植） ====================

const List<List<int>> _sbox = [
  [
    14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2,
    13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7,
    3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13
  ],
  [
    15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2,
    8, 15, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6,
    9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9
  ],
  [
    10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4,
    6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12,
    5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12
  ],
  [
    7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15,
    0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14,
    5, 2, 8, 4, 3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14
  ],
  [
    2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7,
    13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5,
    6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3
  ],
  [
    12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12,
    9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1,
    13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13
  ],
  [
    4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9,
    1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6,
    8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12
  ],
  [
    13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3,
    7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13,
    15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11
  ],
];

int _sboxBit(int a) => (a & 32) | ((a & 31) >> 1) | ((a & 1) << 4);

(int, int) _initialPermutation(Uint8List input) {
  final v0 = input[0] |
      (input[1] << 8) |
      (input[2] << 16) |
      (input[3] << 24);
  final v1 = input[4] |
      (input[5] << 8) |
      (input[6] << 16) |
      (input[7] << 24);
  int bitOf(int v, int n) => (v >> n) & 1;
  final s0 = (bitOf(v1, 6) << 31) |
      (bitOf(v1, 14) << 30) |
      (bitOf(v1, 22) << 29) |
      (bitOf(v1, 30) << 28) |
      (bitOf(v0, 6) << 27) |
      (bitOf(v0, 14) << 26) |
      (bitOf(v0, 22) << 25) |
      (bitOf(v0, 30) << 24) |
      (bitOf(v1, 4) << 23) |
      (bitOf(v1, 12) << 22) |
      (bitOf(v1, 20) << 21) |
      (bitOf(v1, 28) << 20) |
      (bitOf(v0, 4) << 19) |
      (bitOf(v0, 12) << 18) |
      (bitOf(v0, 20) << 17) |
      (bitOf(v0, 28) << 16) |
      (bitOf(v1, 2) << 15) |
      (bitOf(v1, 10) << 14) |
      (bitOf(v1, 18) << 13) |
      (bitOf(v1, 26) << 12) |
      (bitOf(v0, 2) << 11) |
      (bitOf(v0, 10) << 10) |
      (bitOf(v0, 18) << 9) |
      (bitOf(v0, 26) << 8) |
      (bitOf(v1, 0) << 7) |
      (bitOf(v1, 8) << 6) |
      (bitOf(v1, 16) << 5) |
      (bitOf(v1, 24) << 4) |
      (bitOf(v0, 0) << 3) |
      (bitOf(v0, 8) << 2) |
      (bitOf(v0, 16) << 1) |
      bitOf(v0, 24);
  final s1 = (bitOf(v1, 7) << 31) |
      (bitOf(v1, 15) << 30) |
      (bitOf(v1, 23) << 29) |
      (bitOf(v1, 31) << 28) |
      (bitOf(v0, 7) << 27) |
      (bitOf(v0, 15) << 26) |
      (bitOf(v0, 23) << 25) |
      (bitOf(v0, 31) << 24) |
      (bitOf(v1, 5) << 23) |
      (bitOf(v1, 13) << 22) |
      (bitOf(v1, 21) << 21) |
      (bitOf(v1, 29) << 20) |
      (bitOf(v0, 5) << 19) |
      (bitOf(v0, 13) << 18) |
      (bitOf(v0, 21) << 17) |
      (bitOf(v0, 29) << 16) |
      (bitOf(v1, 3) << 15) |
      (bitOf(v1, 11) << 14) |
      (bitOf(v1, 19) << 13) |
      (bitOf(v1, 27) << 12) |
      (bitOf(v0, 3) << 11) |
      (bitOf(v0, 11) << 10) |
      (bitOf(v0, 19) << 9) |
      (bitOf(v0, 27) << 8) |
      (bitOf(v1, 1) << 7) |
      (bitOf(v1, 9) << 6) |
      (bitOf(v1, 17) << 5) |
      (bitOf(v1, 25) << 4) |
      (bitOf(v0, 1) << 3) |
      (bitOf(v0, 9) << 2) |
      (bitOf(v0, 17) << 1) |
      bitOf(v0, 25);
  return (s0, s1);
}

Uint8List _inversePermutation(int s0, int s1) {
  final data = Uint8List(8);
  data[3] = (bit(s1, 24) << 7) |
      (bit(s0, 24) << 6) |
      (bit(s1, 16) << 5) |
      (bit(s0, 16) << 4) |
      (bit(s1, 8) << 3) |
      (bit(s0, 8) << 2) |
      (bit(s1, 0) << 1) |
      bit(s0, 0);
  data[2] = (bit(s1, 25) << 7) |
      (bit(s0, 25) << 6) |
      (bit(s1, 17) << 5) |
      (bit(s0, 17) << 4) |
      (bit(s1, 9) << 3) |
      (bit(s0, 9) << 2) |
      (bit(s1, 1) << 1) |
      bit(s0, 1);
  data[1] = (bit(s1, 26) << 7) |
      (bit(s0, 26) << 6) |
      (bit(s1, 18) << 5) |
      (bit(s0, 18) << 4) |
      (bit(s1, 10) << 3) |
      (bit(s0, 10) << 2) |
      (bit(s1, 2) << 1) |
      bit(s0, 2);
  data[0] = (bit(s1, 27) << 7) |
      (bit(s0, 27) << 6) |
      (bit(s1, 19) << 5) |
      (bit(s0, 19) << 4) |
      (bit(s1, 11) << 3) |
      (bit(s0, 11) << 2) |
      (bit(s1, 3) << 1) |
      bit(s0, 3);
  data[7] = (bit(s1, 28) << 7) |
      (bit(s0, 28) << 6) |
      (bit(s1, 20) << 5) |
      (bit(s0, 20) << 4) |
      (bit(s1, 12) << 3) |
      (bit(s0, 12) << 2) |
      (bit(s1, 4) << 1) |
      bit(s0, 4);
  data[6] = (bit(s1, 29) << 7) |
      (bit(s0, 29) << 6) |
      (bit(s1, 21) << 5) |
      (bit(s0, 21) << 4) |
      (bit(s1, 13) << 3) |
      (bit(s0, 13) << 2) |
      (bit(s1, 5) << 1) |
      bit(s0, 5);
  data[5] = (bit(s1, 30) << 7) |
      (bit(s0, 30) << 6) |
      (bit(s1, 22) << 5) |
      (bit(s0, 22) << 4) |
      (bit(s1, 14) << 3) |
      (bit(s0, 14) << 2) |
      (bit(s1, 6) << 1) |
      bit(s0, 6);
  data[4] = (bit(s1, 31) << 7) |
      (bit(s0, 31) << 6) |
      (bit(s1, 23) << 5) |
      (bit(s0, 23) << 4) |
      (bit(s1, 15) << 3) |
      (bit(s0, 15) << 2) |
      (bit(s1, 7) << 1) |
      bit(s0, 7);
  return data;
}

int bit(int v, int n) => (v >> n) & 1;

int _fstate(int state, List<int> key) {
  final t1 = ((state & 1) << 31) |
      ((state & 0xf8000000) >> 1) |
      ((state & 0x1f800000) >> 3) |
      ((state & 0x01f80000) >> 5) |
      ((state & 0x001f8000) >> 7);
  final t2 = ((state & 0x0001f800) << 15) |
      ((state & 0x00001f80) << 13) |
      ((state & 0x000001f8) << 11) |
      ((state & 0x0000001f) << 9) |
      ((state & 0x80000000) >> 23);

  final k0 = (((t1 >> 24) & 0xff) ^ (key[0] & 0xff)) & 0xff;
  final k1 = (((t1 >> 16) & 0xff) ^ (key[1] & 0xff)) & 0xff;
  final k2 = (((t1 >> 8) & 0xff) ^ (key[2] & 0xff)) & 0xff;
  final k3 = (((t2 >> 24) & 0xff) ^ (key[3] & 0xff)) & 0xff;
  final k4 = (((t2 >> 16) & 0xff) ^ (key[4] & 0xff)) & 0xff;
  final k5 = (((t2 >> 8) & 0xff) ^ (key[5] & 0xff)) & 0xff;

  var st = (_sbox[0][_sboxBit(k0 >> 2)] << 28) |
      (_sbox[1][_sboxBit(((k0 & 0x03) << 4) | (k1 >> 4))] << 24) |
      (_sbox[2][_sboxBit(((k1 & 0x0f) << 2) | (k2 >> 6))] << 20) |
      (_sbox[3][_sboxBit(k2 & 0x3f)] << 16) |
      (_sbox[4][_sboxBit(k3 >> 2)] << 12) |
      (_sbox[5][_sboxBit(((k3 & 0x03) << 4) | (k4 >> 4))] << 8) |
      (_sbox[6][_sboxBit(((k4 & 0x0f) << 2) | (k5 >> 6))] << 4) |
      _sbox[7][_sboxBit(k5 & 0x3f)];
  st &= 0xFFFFFFFF;

  st = ((bit(st, 16) << 31) |
          (bit(st, 25) << 30) |
          (bit(st, 12) << 29) |
          (bit(st, 11) << 28) |
          (bit(st, 3) << 27) |
          (bit(st, 20) << 26) |
          (bit(st, 4) << 25) |
          (bit(st, 15) << 24) |
          (bit(st, 31) << 23) |
          (bit(st, 17) << 22) |
          (bit(st, 9) << 21) |
          (bit(st, 6) << 20) |
          (bit(st, 27) << 19) |
          (bit(st, 14) << 18) |
          (bit(st, 1) << 17) |
          (bit(st, 22) << 16) |
          (bit(st, 30) << 15) |
          (bit(st, 24) << 14) |
          (bit(st, 8) << 13) |
          (bit(st, 18) << 12) |
          (bit(st, 0) << 11) |
          (bit(st, 5) << 10) |
          (bit(st, 29) << 9) |
          (bit(st, 23) << 8) |
          (bit(st, 13) << 7) |
          (bit(st, 19) << 6) |
          (bit(st, 2) << 5) |
          (bit(st, 26) << 4) |
          (bit(st, 10) << 3) |
          (bit(st, 21) << 2) |
          (bit(st, 28) << 1) |
          bit(st, 7)) &
      0xFFFFFFFF;
  return st;
}

Uint8List _cryptBlock(Uint8List input, List<List<int>> schedule) {
  final (s0, s1) = _initialPermutation(input);
  var s0v = s0;
  var s1v = s1;
  for (var i = 0; i < 15; i++) {
    final prev = s1v;
    s1v = (_fstate(s1v, schedule[i]) ^ s0v) & 0xFFFFFFFF;
    s0v = prev;
  }
  final out = (_fstate(s1v, schedule[15]) ^ s0v) & 0xFFFFFFFF;
  return _inversePermutation(out, s1v);
}

List<List<int>> _keySchedule(Uint8List key, int mode) {
  const keyRndShift = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
  const keyPermC = [
    56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34,
    26, 18, 10, 2, 59, 51, 43, 35
  ];
  const keyPermD = [
    62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44,
    36, 28, 20, 12, 4, 27, 19, 11, 3
  ];
  const keyCompression = [
    13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26,
    19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55,
    33, 52, 45, 41, 49, 35, 28, 31
  ];

  final v0 = key[0] | (key[1] << 8) | (key[2] << 16) | (key[3] << 24);
  final v1 = key[4] | (key[5] << 8) | (key[6] << 16) | (key[7] << 24);
  var c = 0;
  for (var i = 0; i < 28; i++) {
    final b = keyPermC[i];
    final bv = b < 32 ? bit(v0, 31 - b) : bit(v1, 63 - b);
    c |= (bv << (31 - i));
  }
  var d = 0;
  for (var i = 0; i < 28; i++) {
    final b = keyPermD[i];
    final bv = b < 32 ? bit(v0, 31 - b) : bit(v1, 63 - b);
    d |= (bv << (31 - i));
  }

  final schedule = List.generate(16, (_) => List<int>.filled(6, 0));
  for (var i = 0; i < 16; i++) {
    final sft = keyRndShift[i];
    c = (((c << sft) | (c >> (28 - sft))) & 0xfffffff0);
    d = (((d << sft) | (d >> (28 - sft))) & 0xfffffff0);
    final togen = (mode == 0) ? (15 - i) : i;
    for (var j = 0; j < 24; j++) {
      final bv = bit(c, 31 - keyCompression[j]);
      schedule[togen][j >> 3] |= (bv << (7 - (j & 7)));
    }
    for (var j = 24; j < 48; j++) {
      final bv = bit(d, 31 - (keyCompression[j] - 27));
      schedule[togen][j >> 3] |= (bv << (7 - (j & 7)));
    }
  }
  return schedule;
}

/// 3DES-EDE 加解密（encrypt: true=加密; false=解密），输入长度需为 8 的倍数。
/// 严格对应 C：encrypt 时 K1 加密 / K2 解密 / K3 加密；
/// decrypt 时 K3 解密 / K2 加密 / K1 解密。
Uint8List tripledesCbc(
    {required Uint8List key24,
    required Uint8List input,
    required bool encrypt}) {
  final groups = encrypt
      ? [
          _keySchedule(key24.sublist(0, 8), 1),
          _keySchedule(key24.sublist(8, 16), 0),
          _keySchedule(key24.sublist(16, 24), 1),
        ]
      : [
          _keySchedule(key24.sublist(16, 24), 0),
          _keySchedule(key24.sublist(8, 16), 1),
          _keySchedule(key24.sublist(0, 8), 0),
        ];
  final out = Uint8List(input.length);
  for (var i = 0; i < input.length; i += 8) {
    var tmp = _cryptBlock(Uint8List.fromList(input.sublist(i, i + 8)),
        groups[0]);
    tmp = _cryptBlock(tmp, groups[1]);
    tmp = _cryptBlock(tmp, groups[2]);
    out.setRange(i, i + 8, tmp);
  }
  return out;
}

// ==================== QRC 解密（3DES + zlib inflate） ====================

const _qrc3DesKey = '!@#)(*\$%123ZXC!@!@#)(NHL';

/// 解密 QRC 歌词数据：hex -> 3DES 解密 -> zlib 解压。
String qrcDecrypt(String hex) {
  final bytes = hexDecode(hex);
  if (bytes.isEmpty) return '';
  final dec = tripledesCbc(
    key24: Uint8List.fromList(utf8.encode(_qrc3DesKey)),
    input: bytes,
    encrypt: false,
  );
  // zlib inflate（raw deflate 兼容：先尝试 zlib 格式，失败则 raw）
  try {
    final inflated = _zlibInflate(dec, raw: false);
    return utf8.decode(inflated, allowMalformed: true);
  } catch (_) {
    try {
      final inflated = _zlibInflate(dec, raw: true);
      return utf8.decode(inflated, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }
}

Uint8List _zlibInflate(Uint8List data, {required bool raw}) {
  return const ZLibDecoder().decodeBytes(data, raw: raw);
}

// ==================== device（生成默认设备信息 JSON） ====================

final _rng = QqRandom();

/// 生成默认设备 JSON（对应 qq_device_make_default）。
Map<String, dynamic> deviceMakeDefault() {
  final uuid = _rng.uuid();
  final openUdid = uuid.replaceAll('-', '');
  final imei = _randomImei();
  final osid = hexEncode(_randBytes(16));
  final androidId = hexEncode(_randBytes(8));
  final procHex = hexEncode(_randBytes(4));
  final displayRand = _rng.randInt(100000, 999998);
  final fpRand = _rng.randInt(1000000, 9999998);
  return {
    'display': 'QMAPI.$displayRand.001',
    'product': 'iarim',
    'device': 'sagit',
    'board': 'eomam',
    'model': 'MI 6',
    'fingerprint':
        'xiaomi/iarim/sagit:10/eomam.200122.001/$fpRand:user/release-keys',
    'bootId': uuid,
    'procVersion':
        'Linux 5.4.0-54-generic-$procHex (android-build@google.com)',
    'imei': imei,
    'brand': 'Xiaomi',
    'bootloader': 'U-boot',
    'baseBand': '',
    'version': {
      'incremental': '5891938',
      'release': '10',
      'codename': 'REL',
      'sdk': 29,
    },
    'simInfo': 'T-Mobile',
    'osType': 'android',
    'macAddress': '00:50:56:C0:00:08',
    'ipAddress': [10, 0, 1, 3],
    'wifiBssid': '00:50:56:C0:00:08',
    'wifiSsid': '<unknown ssid>',
    'imsiMd5': [osid],
    'androidId': androidId,
    'apn': 'wifi',
    'vendorName': 'MIUI',
    'vendorOsName': 'qmapi',
    'openUdid': openUdid,
  };
}

Uint8List _randBytes(int n) {
  final b = Uint8List(n);
  _rng.randomBytes(b);
  return b;
}

String _randomImei() {
  final digits = List<int>.filled(15, 0);
  for (var i = 0; i < 14; i++) {
    digits[i] = _rng.randInt(0, 9);
  }
  var sum = 0;
  for (var i = 0; i < 14; i++) {
    var v = digits[i];
    if (i % 2 == 1) {
      v *= 2;
      if (v > 9) v -= 9;
    }
    sum += v;
  }
  digits[14] = (10 - (sum % 10)) % 10;
  return digits.join();
}

// ==================== comm（构建 comm JSON） ====================

/// 构建 comm 参数（对应 qq_build_comm）。
String buildComm({
  required Map<String, dynamic> credential,
  required Map<String, dynamic> device,
  required bool loggedIn,
  required String q16,
  required String q36,
  required int sessionUid,
  required String sessionSid,
}) {
  final musicid = _jstr(credential['musicid']);
  final musickey = _jstr(credential['musickey']);
  final loginType = _jstr(credential['loginType']);
  final openUdid =
      _jstr(device['openUdid']) ?? '00000000000000000000000000000000';
  final androidId = _jstr(device['androidId']) ?? '00000000';
  final model = _jstr(device['model']) ?? 'MI 6';
  final fingerprint = _jstr(device['fingerprint']) ??
      'xiaomi/iarim/sagit:10/eomam.200122.001/1000000:user/release-keys';
  final version = device['version'];
  var release = '10';
  var sdk = '29';
  if (version is Map) {
    release = version['release']?.toString() ?? '10';
    sdk = version['sdk']?.toString() ?? '29';
  }
  final sb = StringBuffer();
  sb.write('{"ct":11,"cv":14090008,"v":14090008,"chid":"10003505"');
  if (loggedIn && musicid != null) sb.write(',"qq":$musicid');
  if (loggedIn && musickey != null) sb.write(',"authst":"$musickey"');
  sb.write(',"tmeAppID":"qqmusic"');
  if (loginType != null) sb.write(',"tmeLoginType":$loginType');
  sb.write(',"QIMEI":"$q16","QIMEI36":"$q36","OpenUDID":"$openUdid"');
  sb.write(
      ',"udid":"$openUdid","OpenUDID2":"$openUdid","uid":$sessionUid,"sid":"$sessionSid","aid":"$androidId"');
  sb.write(
      ',"os_ver":"$release","phonetype":"$model","devicelevel":"$sdk","newdevicelevel":"$sdk","rom":"$fingerprint"}');
  return sb.toString();
}

String? _jstr(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toString();
  final s = v.toString();
  return s.isEmpty ? null : s;
}

// ==================== qimei（QIMEI 注册参数构建） ====================

const _publicKeyDerB64 =
    'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDEIxgwoutfwoJxcGQeedgP7FG9qaIuS0qzfR8gWkrkTZKM2iWHn2ajQpBRZjMSoSf6+KJGvar2ORhBfpDXyVtZCKpqLQ+FLkpncClKVIrBwv6PHyUvuCb0rIarmgDnzkfQAqVufEtR64iazGDKatvJ9y6B9NMbHddGSAUmRTCrHQIDAQAB';
const _secret = 'ZdJqM15EeO2zWc08';
const _qimeiAppKey = '0AND0HD6FE4HY80F';
const _channelId = '10003505';
const _packageId = 'com.tencent.qqmusic';

const _k1set = [1, 2, 13, 14, 17, 18, 21, 22, 25, 26, 29, 30, 33, 34, 37, 38];

String _randomBeaconId() {
  final sb = StringBuffer();
  final now = DateTime.now().toUtc();
  final monthStart = '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
  final rand1 = _rng.randInt(100000, 999999);
  final rand2 = _rng.randInt(100000000, 999999999);
  for (var i = 1; i <= 40; i++) {
    if (_k1set.contains(i)) {
      sb.write('k$i:$monthStart$rand1.$rand2;');
    } else if (i == 3) {
      sb.write('k3:0000000000000000;');
    } else if (i == 4) {
      var hex = hexEncode(_randBytes(8));
      if (hex[0] == '0') hex = '1${hex.substring(1)}';
      sb.write('k4:$hex;');
    } else {
      sb.write('k$i:${_rng.randInt(0, 9999)};');
    }
  }
  return sb.toString();
}

String _randomHexStr(int n) => hexEncode(_randBytes((n + 1) ~/ 2)).substring(0, n);

/// 构建 QIMEI 注册请求参数（对应 qq_qimei_build）。
/// 返回 { key, params, time, nonce, sign, extra, header_sign }。
Map<String, String> qimeiBuild(Map<String, dynamic> device) {
  final now = DateTime.now().toUtc();
  final tsMs = now.millisecondsSinceEpoch;
  final ts = (tsMs ~/ 1000).toString();
  final brand = device['brand']?.toString() ?? 'Xiaomi';
  final devName = device['device']?.toString() ?? 'sagit';
  final model = device['model']?.toString() ?? 'MI 6';
  final procVersion = device['procVersion']?.toString() ??
      'Linux 5.4.0-54-generic (android-build@google.com)';
  final androidId = device['androidId']?.toString() ?? '00000000';
  final imei = device['imei']?.toString() ?? '000000000000000';
  final version = device['version'];
  final release = (version is Map && version['release'] != null)
      ? version['release'].toString()
      : '10';
  final sdk = (version is Map && version['sdk'] != null)
      ? version['sdk'].toString()
      : '29';

  final beacon = _randomBeaconId();
  final fixedRand = _rng.randInt(0, 14400);
  final upTime = now.subtract(Duration(seconds: fixedRand));
  String two(int v) => v.toString().padLeft(2, '0');
  final upTimeStr =
      '${upTime.year}-${two(upTime.month)}-${two(upTime.day)} ${two(upTime.hour)}:${two(upTime.minute)}:${two(upTime.second)}';

  final payload =
      '{"androidId":"$androidId","platformId":1,"appKey":"$_qimeiAppKey","appVersion":"14.9.0.8",'
      '"beaconIdSrc":"$beacon","brand":"$brand","channelId":"$_channelId","cid":"",'
      '"imei":"$imei","imsi":"","mac":"","model":"$model","networkType":"unknown",'
      '"oaid":"","osVersion":"Android $release,level $sdk","qimei":"","qimei36":"",'
      '"sdkVersion":"1.2.13.6","targetSdkVersion":"33","audit":"",'
      '"userId":"{}","packageId":"$_packageId","deviceType":"Phone","sdkName":"",'
      '"reserved":"{\\"harmony\\":\\"0\\",\\"clone\\":\\"0\\",\\"containe\\":\\"\\",'
      '\\"oz\\":\\"UhYmelwouA+V2nPWbOvLTgN2/m8jwGB+yUB5v9tysQg=\\",'
      '\\"oo\\":\\"Xecjt+9S1+f8Pz2VLSxgpw==\\",\\"kelong\\":\\"0\\",'
      '\\"uptimes\\":\\"$upTimeStr\\",\\"multiUser\\":\\"0\\",\\"bod\\":\\"$brand\\",'
      '\\"dv\\":\\"$devName\\",\\"firstLevel\\":\\"\\",\\"manufact\\":\\"$brand\\",'
      '\\"name\\":\\"$model\\",\\"host\\":\\"se.infra\\",\\"kernel\\":\\"$procVersion\\"}"'
      '}';

  final cryptKeyHex = _randomHexStr(16);
  final nonceHex = _randomHexStr(16);

  final rsaOut = rsaPkcs1Encrypt(utf8.encode(cryptKeyHex));
  final keyB64 = b64Encode(rsaOut);

  // AES-CBC: IV=key，无填充块按 PKCS7
  final plen = utf8.encode(payload).length;
  final padLen = 16 - (plen % 16);
  final paddedLen = plen + padLen;
  final padded = Uint8List(paddedLen);
  padded.setAll(0, utf8.encode(payload));
  for (var i = plen; i < paddedLen; i++) {
    padded[i] = padLen;
  }
  final aesOut = aesCbcEncrypt(
      key: Uint8List.fromList(utf8.encode(cryptKeyHex)),
      input: padded);
  final paramsB64 = b64Encode(aesOut);

  final extra = '{"appKey":"$_qimeiAppKey"}';
  final reqParts = [keyB64, paramsB64, tsMs.toString(), nonceHex, _secret, extra];
  final reqSign = crypto.md5
      .convert(utf8.encode(reqParts.join()))
      .toString();
  const hdrConst = 'qimei_qq_androidpzAuCmaFAaFaHrdakPjLIEqKrGnSOOvH';
  final headerSign = crypto.md5.convert(utf8.encode('$hdrConst$ts')).toString();

  return {
    'key': keyB64,
    'params': paramsB64,
    'time': ts,
    'nonce': nonceHex,
    'sign': reqSign,
    'extra': extra,
    'header_sign': headerSign,
  };
}

/// RSA PKCS#1 v1.5 加密（1024 位公钥，对应 C 中 mbedtls_rsa_pkcs1_encrypt）。
Uint8List rsaPkcs1Encrypt(Uint8List input) {
  // n: 公钥模数（base64 解码 DER 后取 128 字节）
  final der = base64.decode(_publicKeyDerB64);
  // DER 解析：SEQUENCE (30 82 xx xx) -> SEQUENCE -> BIT STRING -> OCTET STRING
  // 简化：1024 位 RSA 公钥 DER 定长，模数位于尾部 128 字节前 2 字节索引
  final mod = der.sublist(der.length - 130, der.length - 2);
  final e = 65537;
  // RSA-OAEP 未使用；PKCS#1 v1.5：PS = 0xFF 填充
  final k = mod.length; // 128
  final em = Uint8List(k);
  em[0] = 0x00;
  em[1] = 0x02;
  // 填充 PS（随机非零）
  for (var i = 2; i < k - input.length - 1; i++) {
    var b = 0;
    while (b == 0) {
      b = _rng.randInt(1, 255);
    }
    em[i] = b;
  }
  em[k - input.length - 1] = 0x00;
  em.setRange(k - input.length, k, input);
  return _rsaModPow(em, mod, e);
}

Uint8List _rsaModPow(Uint8List m, Uint8List mod, int e) {
  final modulus = _bytesToBigInt(mod);
  var exp = BigInt.from(e);
  var b = _bytesToBigInt(m);
  var r = BigInt.one;
  while (exp > BigInt.zero) {
    if (exp & BigInt.one == BigInt.one) {
      r = (r * b) % modulus;
    }
    b = (b * b) % modulus;
    exp = exp >> 1;
  }
  final bytes = r.toUnsigned(((modulus.bitLength + 7) ~/ 8) * 8).toRadixString(16);
  // 转换为固定长度大端字节
  final out = Uint8List(mod.length);
  var hex = bytes;
  if (hex.length % 2 != 0) hex = '0$hex';
  final raw = hexDecode(hex);
  out.setRange(mod.length - raw.length, mod.length, raw);
  return out;
}

BigInt _bytesToBigInt(Uint8List b) {
  var v = BigInt.zero;
  for (final byte in b) {
    v = (v << 8) | BigInt.from(byte);
  }
  return v;
}

/// AES-128-CBC 加密（IV = key，PKCS#7 由调用方补齐）。
Uint8List aesCbcEncrypt({required Uint8List key, required Uint8List input}) {
  Uint8List encBlock(Uint8List block) {
    final out = Uint8List(16);
    _aesBlockEncrypt(key, block, out);
    return out;
  }

  final out = Uint8List(input.length);
  final iv = List<int>.from(key);
  for (var i = 0; i < input.length; i += 16) {
    final block = Uint8List(16);
    for (var j = 0; j < 16; j++) {
      block[j] = (input[i + j] ^ iv[j]) & 0xff;
    }
    final enc = encBlock(block);
    out.setRange(i, i + 16, enc);
    for (var j = 0; j < 16; j++) {
      iv[j] = enc[j];
    }
  }
  return out;
}

// ---------------- 纯 Dart AES-128 实现（S 盒/密钥扩展） ----------------

const List<int> _aesSbox = [
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe,
  0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4,
  0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7,
  0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15, 0x04, 0xc7, 0x23, 0xc3,
  0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75, 0x09,
  0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3,
  0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe,
  0x39, 0x4a, 0x4c, 0x58, 0xcf, 0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85,
  0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92,
  0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c,
  0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19,
  0x73, 0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14,
  0xde, 0x5e, 0x0b, 0xdb, 0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2,
  0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5,
  0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08, 0xba, 0x78, 0x25,
  0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
  0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86,
  0xc1, 0x1d, 0x9e, 0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e,
  0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf, 0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42,
  0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
];

int _gfmul(int a, int b) {
  var r = 0;
  var aa = a;
  var bb = b;
  for (var i = 0; i < 8; i++) {
    if ((bb & 1) != 0) r ^= aa;
    final hi = aa & 0x80;
    aa = (aa << 1) & 0xff;
    if (hi != 0) aa ^= 0x1b;
    bb >>= 1;
  }
  return r & 0xff;
}

Uint8List _aesExpandKey(Uint8List key) {
  final w = List<int>.filled(176, 0);
  for (var i = 0; i < 16; i++) {
    w[i] = key[i];
  }
  for (var i = 4; i < 44; i++) {
    final a = w[(i - 1) * 4];
    final b = w[(i - 1) * 4 + 1];
    final c = w[(i - 1) * 4 + 2];
    final d = w[(i - 1) * 4 + 3];
    if (i % 4 == 0) {
      // RotWord + SubWord + Rcon
      final new0 = _aesSbox[b] ^ _rcon(i ~/ 4);
      final new1 = _aesSbox[c];
      final new2 = _aesSbox[d];
      final new3 = _aesSbox[a];
      w[i * 4] = w[(i - 4) * 4] ^ new0;
      w[i * 4 + 1] = w[(i - 4) * 4 + 1] ^ new1;
      w[i * 4 + 2] = w[(i - 4) * 4 + 2] ^ new2;
      w[i * 4 + 3] = w[(i - 4) * 4 + 3] ^ new3;
    } else {
      w[i * 4] = w[(i - 4) * 4] ^ a;
      w[i * 4 + 1] = w[(i - 4) * 4 + 1] ^ b;
      w[i * 4 + 2] = w[(i - 4) * 4 + 2] ^ c;
      w[i * 4 + 3] = w[(i - 4) * 4 + 3] ^ d;
    }
  }
  return Uint8List.fromList(w);
}

int _rcon(int i) {
  var r = 1;
  for (var j = 1; j < i; j++) {
    r = _gfmul(r, 2);
  }
  return r;
}

void _aesBlockEncrypt(Uint8List key, Uint8List input, Uint8List out) {
  final wk = _aesExpandKey(key);
  final state = List<int>.from(input);
  void addRoundKey(int round) {
    for (var i = 0; i < 16; i++) {
      state[i] ^= wk[round * 16 + i];
    }
  }

  void subBytes() {
    for (var i = 0; i < 16; i++) {
      state[i] = _aesSbox[state[i]];
    }
  }

  void shiftRows() {
    final t = List<int>.from(state);
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        state[i * 4 + j] = t[i * 4 + ((j + i) % 4)];
      }
    }
  }

  void mixColumns() {
    for (var c = 0; c < 4; c++) {
      final a0 = state[c * 4];
      final a1 = state[c * 4 + 1];
      final a2 = state[c * 4 + 2];
      final a3 = state[c * 4 + 3];
      state[c * 4] = _gfmul(a0, 2) ^ _gfmul(a1, 3) ^ a2 ^ a3;
      state[c * 4 + 1] = a0 ^ _gfmul(a1, 2) ^ _gfmul(a2, 3) ^ a3;
      state[c * 4 + 2] = a0 ^ a1 ^ _gfmul(a2, 2) ^ _gfmul(a3, 3);
      state[c * 4 + 3] = _gfmul(a0, 3) ^ a1 ^ a2 ^ _gfmul(a3, 2);
    }
  }

  addRoundKey(0);
  for (var round = 1; round <= 9; round++) {
    subBytes();
    shiftRows();
    mixColumns();
    addRoundKey(round);
  }
  subBytes();
  shiftRows();
  addRoundKey(10);
  for (var i = 0; i < 16; i++) {
    out[i] = state[i] & 0xff;
  }
}