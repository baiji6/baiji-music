/// QQ 音乐 QMC 系列解密算法。
///
/// 移植自 `lib_um_crypto_rust`（um-react 的加密内核）的 `um_crypto/qmc` crate，
/// 算法与常量逐行对照，并沿用其 Rust 单元测试向量做回归校验。
///
/// ## 三个版本
///
/// | 版本 | 密钥来源 | 特点 |
/// |---|---|---|
/// | QMC v1 (`.qmcflac`) | 内嵌静态密钥 | XOR + 固定 128 字节密钥表 |
/// | QMC v2 Map (`.mflac` 等) | ekey ≤ 300 字节 | 密钥压缩成 128 字节后 XOR |
/// | QMC v2 RC4 (`.mflac` 等) | ekey > 300 字节 | RC4 密钥流 + 分段偏移 |
///
/// ## 为什么 offset 参数不能省
///
/// 三种算法的密钥流都与**字节在原文件中的绝对位置**绑定（v1 用
/// `offset % 0x7FFF`、Map 用压缩后的 key 直接取模、RC4 用分段号），
/// 所以不能对分块各自从0 开始算，必须把文件偏移一路带下去。
library;

import 'dart:typed_data';

/// QMC v1 / v2-Map 使用的密钥表长度。
const int qmcV1KeySize = 128;

/// v1 偏移回绕边界。
const int _v1OffsetBoundary = 0x7FFF;

/// QMC v1 的静态密钥（对应 `v1::V1_STATIC_KEY`）。
const List<int> qmcV1StaticKey = [
  0xc3, 0x4a, 0xd6, 0xca, 0x90, 0x67, 0xf7, 0x52, 0xd8, 0xa1, //
  0x66, 0x62, 0x9f, 0x5b, 0x09, 0x00,
  0xc3, 0x5e, 0x95, 0x23, 0x9f, 0x13, 0x11, 0x7e, 0xd8, 0x92, 0x3f, 0xbc, 0x90, 0xbb, 0x74, 0x0e,
  0xc3, 0x47, 0x74, 0x3d, 0x90, 0xaa, 0x3f, 0x51, 0xd8, 0xf4, 0x11, 0x84, 0x9f, 0xde, 0x95, 0x1d,
  0xc3, 0xc6, 0x09, 0xd5, 0x9f, 0xfa, 0x66, 0xf9, 0xd8, 0xf0, 0xf7, 0xa0, 0x90, 0xa1, 0xd6, 0xf3,
  0xc3, 0xf3, 0xd6, 0xa1, 0x90, 0xa0, 0xf7, 0xf0, 0xd8, 0xf9, 0x66, 0xfa, 0x9f, 0xd5, 0x09, 0xc6,
  0xc3, 0x1d, 0x95, 0xde, 0x9f, 0x84, 0x11, 0xf4, 0xd8, 0x51, 0x3f, 0xaa, 0x90, 0x3d, 0x74, 0x47,
  0xc3, 0x0e, 0x74, 0xbb, 0x90, 0xbc, 0x3f, 0x92, 0xd8, 0x7e, 0x11, 0x13, 0x9f, 0x23, 0x95, 0x5e,
  0xc3, 0x00, 0x09, 0x5b, 0x9f, 0x62, 0x66, 0xa1, 0xd8, 0x52, 0xf7, 0x67, 0x90, 0xca, 0xd6, 0x4a,
];

/// 单字节变换：`value ^ key[offset % 128]`，偏移越过 0x7FFF 后回绕。
int qmc1Transform(List<int> key, int value, int offset) {
  final o = offset <= _v1OffsetBoundary ? offset : offset % _v1OffsetBoundary;
  return value ^ key[o % qmcV1KeySize];
}

/// QMC v1 解密（`.qmcflac`）：用内置静态密钥。
void qmc1Decrypt(Uint8List data, int offset, {List<int>? key}) {
  final k = key ?? qmcV1StaticKey;
  for (var i = 0; i < data.length; i++) {
    data[i] = qmc1Transform(k, data[i], offset + i);
  }
}

// ==================== v2 Map ====================

/// Map 模式的索引偏移常量（对应 `v2_map::key::INDEX_OFFSET`）。
const int _mapIndexOffset = 71214;

/// 把长密钥压缩成 128 字节的 Map 密钥表。
///
/// 每一步取 `(i*i + 71214) % n` 位置的字节，再按 `shift = (idx+4) % 8` 做
/// **截断移位**后按位或（不是循环移位！）。
///
/// 这个区别很关键：Rust 那边写的是 `wrapping_shl(shift) | wrapping_shr(shift)`，
/// 对 u8 而言 `wrapping_shr` 是逻辑右移、被 8 截断，所以 shift>0 时
/// 高位那一半会直接丢失，结果里出现 0。等价物不是 `rotate_left`——
/// 写成循环移位会解出完全不同的音频。
List<int> qmcKeyCompress(List<int> longKey) {
  if (longKey.isEmpty) {
    throw ArgumentError.value(longKey, 'longKey', '密钥为空');
  }
  final n = longKey.length;
  final result = List<int>.filled(qmcV1KeySize, 0);
  for (var i = 0; i < qmcV1KeySize; i++) {
    final idx = (i * i + _mapIndexOffset) % n;
    final b = longKey[idx];
    final shift = (idx + 4) % 8;
    // Rust: b.wrapping_shl(shift) | b.wrapping_shr(shift)，均按 u8 截断
    result[i] = (((b << shift) & 0xFF) | (b >> shift)) & 0xFF;
  }
  return result;
}

/// QMC v2 Map 模式解密器。
class Qmc2Map {
  Qmc2Map(List<int> longKey) : _key = qmcKeyCompress(longKey);

  final List<int> _key;

  void decrypt(Uint8List data, int offset) {
    for (var i = 0; i < data.length; i++) {
      data[i] = qmc1Transform(_key, data[i], offset + i);
    }
  }
}

// ==================== v2 RC4 ====================

/// RC4 状态机（对应 `v2_rc4::rc4`）。
/// ⚠️ state 的初值是 `i as u8`：**索引 ≥ 256 时回绕成 0**。
/// 上游用 512 字节密钥时state 里只有 256 个不同值，按普通 RC4 写会导致密钥流全错。
class _Rc4 {
  _Rc4(List<int> key)
      : _state = List<int>.generate(key.length, (i) => i & 0xFF) {
    final n = key.length;
    var j = 0;
    for (var i = 0; i < _state.length; i++) {
      j = (j + _state[i] + key[i % n]) % n;
      final t = _state[i];
      _state[i] = _state[j];
      _state[j] = t;
    }
  }

  final List<int> _state;
  int _i = 0;
  int _j = 0;

  int generate() {
    final n = _state.length;
    _i = (_i + 1) % n;
    _j = (_j + _state[_i]) % n;
    final t = _state[_i];
    _state[_i] = _state[_j];
    _state[_j] = t;
    final i = _state[_i];
    final j = _state[_j];
    return _state[(i + j) % n];
  }

  void deriveInto(List<int> buffer) {
    for (var i = 0; i < buffer.length; i++) {
      buffer[i] ^= generate();
    }
  }
}

/// 密钥哈希（对应 `v2_rc4::hash`）。
///
/// 注意 Rust 那边算的是 **u32 溢出后的值转 f64**，Dart 的 int 是 64 位，
/// 必须显式按 32 位截断才能得到同一个 hash，否则分段偏移全错。
double qmcRc4Hash(List<int> key) {
  var hash = 1;
  for (final v in key) {
    if (v == 0) continue;
    final next = (hash * v) & 0xFFFFFFFF;
    if (next == 0 || next <= hash) break;
    hash = next;
  }
  return hash.toDouble();
}

/// 分段密钥（对应 `v2_rc4::segment_key`）。
int qmcSegmentKey(int id, int seed, double hash) {
  if (seed == 0) return 0;
  // Rust 里是 (id+1).wrapping_mul(seed) 作为 u64，这里 Dart int 是 64 位有符号，
  // 乘积最大 512 * 255，不会溢出，直接算即可。
  final result = hash / ((id + 1) * seed) * 100.0;
  return result.toInt();
}

/// QMC v2 RC4 模式解密器。
class Qmc2Rc4 {
  Qmc2Rc4(List<int> key) : _key = List<int>.from(key) {
    _hash = qmcRc4Hash(_key);
    // 预生成一大段密钥流缓存，后续按skip 偏移直接切片
    final rc4 = _Rc4(_key);
    _keyStream = List<int>.filled(_rc4StreamCacheSize, 0);
    rc4.deriveInto(_keyStream);
  }

  static const int _firstSegmentSize = 0x0080;
  static const int _otherSegmentSize = 0x1400;
  static const int _rc4StreamCacheSize = _otherSegmentSize + 512;

  final List<int> _key;
  late final double _hash;
  late final List<int> _keyStream;

  void _processFirstSegment(Uint8List data, int offset) {
    final n = _key.length;
    for (var i = 0; i < data.length; i++) {
      final pos = offset + i;
      final idx = qmcSegmentKey(pos, _key[pos % n], _hash) % n;
      data[i] ^= _key[idx];
    }
  }

  void _processOtherSegment(Uint8List data, int offset) {
    final n = _key.length;
    final id = offset ~/ _otherSegmentSize;
    final blockOffset = offset % _otherSegmentSize;

    final seed = _key[id % n];
    final skip = qmcSegmentKey(id, seed, _hash) & 0x1FF;

    final start = skip + blockOffset;
    final end = (start + data.length) < _keyStream.length
        ? start + data.length
        : _keyStream.length;
    for (var i = 0; i < data.length && start + i < end; i++) {
      data[i] ^= _keyStream[start + i];
    }
  }

  void decrypt(Uint8List data, int offset) {
    var off = offset;
    var buf = data;
    var start = 0;

    if (off < _firstSegmentSize) {
      final n = (_firstSegmentSize - off) < buf.length
          ? _firstSegmentSize - off
          : buf.length;
      _processFirstSegment(Uint8List.sublistView(buf, 0, n), off);
      start = n;
      off += n;
    }

    final excess = off % _otherSegmentSize;
    if (excess != 0) {
      final remain = buf.length - start;
      final n = (_otherSegmentSize - excess) < remain
          ? _otherSegmentSize - excess
          : remain;
      if (n > 0) {
        _processOtherSegment(
            Uint8List.sublistView(buf, start, start + n), off);
        start += n;
        off += n;
      }
    }

    while (start < buf.length) {
      final remain = buf.length - start;
      final n = _otherSegmentSize < remain ? _otherSegmentSize : remain;
      _processOtherSegment(Uint8List.sublistView(buf, start, start + n), off);
      start += n;
      off += n;
    }
  }
}

// ==================== 统一入口 ====================

/// QMC v2 密文类型。
enum QmcV2CipherType { mapL, rc4 }

/// QMC v2 解密器，按密钥长度自动选择 Map / RC4。
///
/// 长度分界是 300 字节（对应 `QMCv2Cipher::new`）——这与 um-react 里
/// UI 校验的 ekey 长度 364 / 704 是同一件事：364 位 base64 解码后≈256 字节，
/// 704 位 ≈512 字节，都走 RC4。
class QmcV2Cipher {
  QmcV2Cipher(List<int> key)
      : type = key.length <= 300
            ? QmcV2CipherType.mapL
            : QmcV2CipherType.rc4 {
    if (key.isEmpty) {
      throw ArgumentError.value(key, 'key', '密钥为空');
    }
    _impl = type == QmcV2CipherType.mapL
        ? Qmc2Map(key)
        : Qmc2Rc4(key) as Object;
  }

  final QmcV2CipherType type;
  Object? _impl;

  void decrypt(Uint8List data, int offset) {
    final impl = _impl;
    if (impl is Qmc2Map) {
      impl.decrypt(data, offset);
    } else if (impl is Qmc2Rc4) {
      impl.decrypt(data, offset);
    }
  }
}