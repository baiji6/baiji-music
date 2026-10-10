/// 酷我 KWM 解密。
///
/// 移植自 `um_crypto/kuwo`。KWM 前 0x400 字节是头部，其中 magic 有两种
/// （`yeelion-kuwo-tme` 与 `yeelion-kuwo\0\0\0\0`），`version` 决定算法：
///
/// | version | 算法 | 密钥来源 |
/// |---|---|---|
/// | 1 (LegacyKWM) | 32 字节 KEY 与 resource_id 字符串循环 XOR | 头内 resource_id |
/// | 2 (TME) | 复用 QMC v2 | 必须有 ekey |
///
/// 另外还移植了酷我的**非标准 DES**（`des/`），用于解密客户端配置里的
/// `ksing` 密文（ekey 数据库的 value 就是这种格式）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'qmc.dart';
import 'qmc_ekey.dart';

/// 音频数据起始偏移。
const int kwmDataStartOffset = 0x400;

/// 酷我服务通用密钥。
const List<int> kuwoSecretKey = [0x79, 0x6C, 0x7A, 0x73, 0x78, 0x6B, 0x77, 0x6D]; // "ylzsxkwm"

const List<int> _magic1 = [
  0x79, 0x65, 0x65, 0x6C, 0x69, 0x6F, 0x6E, 0x2D, //
  0x6B, 0x75, 0x77, 0x6F, 0x2D, 0x74, 0x6D, 0x65,
]; // "yeelion-kuwo-tme"
const List<int> _magic2 = [
  0x79, 0x65, 0x65, 0x6C, 0x69, 0x6F, 0x6E, 0x2D, //
  0x6B, 0x75, 0x77, 0x6F, 0x00, 0x00, 0x00, 0x00,
]; // "yeelion-kuwo\0\0\0\0"

/// Legacy KWM 的 32 字节静态密钥。
const List<int> _kwmV1Key = [
  0x4D, 0x6F, 0x4F, 0x74, 0x4F, 0x69, 0x54, 0x76, //
  0x49, 0x4E, 0x47, 0x77, 0x64, 0x32, 0x45, 0x36,
  0x6E, 0x30, 0x45, 0x31, 0x69, 0x37, 0x4C, 0x35,
  0x74, 0x32, 0x49, 0x6F, 0x4F, 0x6F, 0x4E, 0x6B,
];

/// KWM 文件头。
class KwmHeader {
  KwmHeader({
    required this.magic,
    required this.version,
    required this.resourceId,
    required this.formatName,
  });

  final Uint8List magic;

  /// 1 = LegacyKWM，2 = TME/QMCv2。
  final int version;
  final int resourceId;

  /// 12 字节，形如 `aac`、`flac`，用于匹配 Android MMKV 里的音质条目。
  final Uint8List formatName;

  /// 音质 id（取format_name 开头连续数字）。
  int get qualityId {
    var sum = 0;
    for (final c in formatName) {
      if (c == 0 || c < 0x30 || c > 0x39) break;
      sum = sum * 10 + (c - 0x30);
    }
    return sum;
  }
}

int _u32le(Uint8List b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

/// 解析 KWM 文件头（至少 0x2C 字节）。
KwmHeader parseKwmHeader(Uint8List buffer) {
  if (buffer.length < 0x2C) {
    throw const FormatException('KWM 头部太小');
  }
  final magic = Uint8List.fromList(buffer.sublist(0, 0x10));
  final valid = _eq(magic, _magic1) || _eq(magic, _magic2);
  if (!valid) {
    throw const FormatException('不是 KWM 文件（magic 不匹配）');
  }
  final version = _u32le(buffer, 0x10);
  final resourceId = _u32le(buffer, 0x18);
  final formatName = Uint8List.fromList(buffer.sublist(0x24, 0x24 + 0x0C));
  return KwmHeader(
    magic: magic,
    version: version,
    resourceId: resourceId,
    formatName: formatName,
  );
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// KWM v1 解密器。
class KwmV1 {
  KwmV1(int resourceId) {
    final rid = Uint8List.fromList(utf8.encode(resourceId.toString()));
    key = Uint8List.fromList(_kwmV1Key);
    for (var i = 0; i < key.length; i++) {
      key[i] ^= rid[i % rid.length];
    }
  }

  late final Uint8List key;

  void decrypt(Uint8List data, int offset) {
    for (var i = 0; i < data.length; i++) {
      data[i] ^= key[(offset + i) % key.length];
    }
  }
}

/// KWM 解密器。
class KwmDecipher {
  KwmDecipher.v1(KwmV1 impl) : _v1 = impl, _v2 = null;
  KwmDecipher.v2(String ekey)
      : _v1 = null,
        _v2 = QmcV2Cipher(qmcEkeyDecrypt(ekey));

  final KwmV1? _v1;
  final QmcV2Cipher? _v2;

  void decrypt(Uint8List data, int offset) {
    final v1 = _v1;
    if (v1 != null) {
      v1.decrypt(data, offset);
    } else {
      _v2!.decrypt(data, offset);
    }
  }
}

/// 按头部创建解密器。[ekey] 仅 v2 需要。
KwmDecipher createKwmDecipher(KwmHeader header, {String? ekey}) {
  switch (header.version) {
    case 1:
      return KwmDecipher.v1(KwmV1(header.resourceId));
    case 2:
      if (ekey == null || ekey.isEmpty) {
        throw const FormatException('KWM v2 需要 ekey，请先导入密钥');
      }
      return KwmDecipher.v2(ekey);
    default:
      throw FormatException('不支持的 KWM 版本: ${header.version}');
  }
}

// ==================== 非标准 DES ====================
//
// 酷我用的是改了密钥编排表与S 盒的 DES 变体，和标准 DES 完全不兼容，
// 因此这里按上游`des/` 逐表移植，不能用 pointycastle 的 DES 替代。

const List<int> _keyRndShifts = [
  1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1,
];

const List<int> _keyShiftMasks = [0, 0x100001, 0x300003];

final List<int> _keyShiftLeftMasks = List<int>.generate(
  16,
  (i) => _keyShiftMasks[_keyRndShifts[i]],
  growable: false,
);

const List<List<int>> _sboxes = [
  [
    13, 7, 10, 0, 6, 9, 5, 15, 8, 4, 3, 10, 11, 14, 12, 5,
    2, 11, 9, 6, 15, 12, 0, 3, 4, 1, 14, 13, 1, 2, 7, 8,
    1, 2, 12, 15, 10, 4, 0, 3, 13, 14, 6, 9, 7, 8, 9, 6,
    15, 1, 5, 12, 3, 10, 14, 5, 8, 7, 11, 0, 4, 13, 2, 11,
  ],
  [
    4, 1, 3, 10, 15, 12, 5, 0, 2, 11, 9, 6, 8, 7, 6, 9,
    11, 4, 12, 15, 0, 3, 10, 5, 14, 13, 7, 8, 13, 14, 1, 2,
    13, 6, 14, 9, 4, 1, 2, 14, 11, 13, 5, 0, 1, 10, 8, 3,
    0, 11, 3, 5, 9, 4, 15, 2, 7, 8, 12, 15, 10, 7, 6, 12,
  ],
  [
    12, 9, 0, 7, 9, 2, 14, 1, 10, 15, 3, 4, 6, 12, 5, 11,
    1, 14, 13, 0, 2, 8, 7, 13, 15, 5, 4, 10, 8, 3, 11, 6,
    10, 4, 6, 11, 7, 9, 0, 6, 4, 2, 13, 1, 9, 15, 3, 8,
    15, 3, 1, 14, 12, 5, 11, 0, 2, 12, 14, 7, 5, 10, 8, 13,
  ],
  [
    2, 4, 8, 15, 7, 10, 13, 6, 4, 1, 3, 12, 11, 7, 14, 0,
    12, 2, 5, 9, 10, 13, 0, 3, 1, 11, 15, 5, 6, 8, 9, 14,
    14, 11, 5, 6, 4, 1, 3, 10, 2, 12, 15, 0, 13, 2, 8, 5,
    11, 8, 0, 15, 7, 14, 9, 4, 12, 7, 10, 9, 1, 13, 6, 3,
  ],
  [
    7, 10, 1, 15, 0, 12, 11, 5, 14, 9, 8, 3, 9, 7, 4, 8,
    13, 6, 2, 1, 6, 11, 12, 2, 3, 0, 5, 14, 10, 13, 15, 4,
    13, 3, 4, 9, 6, 10, 1, 12, 11, 0, 2, 5, 0, 13, 14, 2,
    8, 15, 7, 4, 15, 1, 10, 7, 5, 6, 12, 11, 3, 8, 9, 14,
  ],
  [
    10, 13, 1, 11, 6, 8, 11, 5, 9, 4, 12, 2, 15, 3, 2, 14,
    0, 6, 13, 1, 3, 15, 4, 10, 14, 9, 7, 12, 5, 0, 8, 7,
    13, 1, 2, 4, 3, 6, 12, 11, 0, 13, 5, 14, 6, 8, 15, 2,
    7, 10, 8, 15, 4, 9, 11, 5, 9, 0, 14, 3, 10, 7, 1, 12,
  ],
  [
    15, 0, 9, 5, 6, 10, 12, 9, 8, 7, 2, 12, 3, 13, 5, 2,
    1, 14, 7, 8, 11, 4, 0, 3, 14, 11, 13, 6, 4, 1, 10, 15,
    3, 13, 12, 11, 15, 3, 6, 0, 4, 10, 1, 7, 8, 4, 11, 14,
    13, 8, 0, 6, 2, 15, 9, 5, 7, 1, 10, 12, 14, 2, 5, 9,
  ],
  [
    14, 4, 3, 15, 2, 13, 5, 3, 13, 14, 6, 9, 11, 2, 0, 5,
    4, 1, 10, 12, 15, 6, 9, 10, 1, 8, 12, 7, 8, 11, 7, 0,
    0, 15, 10, 5, 14, 4, 9, 10, 7, 8, 12, 3, 13, 1, 3, 6,
    15, 12, 6, 11, 2, 9, 5, 0, 4, 2, 11, 14, 1, 7, 8, 13,
  ],
];

const List<int> _pbox = [
  15, 6, 19, 20, 28, 11, 27, 16, 0, 14, 22, 25, 4, 17, 30, 9,
  1, 7, 23, 13, 31, 26, 2, 8, 18, 12, 29, 5, 21, 10, 3, 24,
];

const List<int> _ip = [
  57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
  61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
  56, 48, 40, 32, 24, 16, 8, 0, 58, 50, 42, 34, 26, 18, 10, 2,
  60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6,
];

const List<int> _ipInv = [
  39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30,
  37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28,
  35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26,
  33, 1, 41, 9, 49, 17, 57, 25, 32, 0, 40, 8, 48, 16, 56, 24,
];

const List<int> _keyPermutationTable = [
  56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1,
  58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 62, 54, 46, 38,
  30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36,
  28, 20, 12, 4, 27, 19, 11, 3,
];

const List<int> _keyCompression = [
  13, 16, 10, 23, 0, 4, 255, 255, 2, 27, 14, 5, 20, 9, 255, 255,
  22, 18, 11, 3, 25, 7, 255, 255, 15, 6, 26, 19, 12, 1, 255, 255,
  40, 51, 30, 36, 46, 54, 255, 255, 29, 39, 50, 44, 32, 47, 255, 255,
  43, 48, 38, 55, 33, 52, 255, 255, 45, 41, 49, 35, 28, 31, 255, 255,
];

const List<int> _keyExpansion = [
  31, 0, 1, 2, 3, 4, 255, 255, 3, 4, 5, 6, 7, 8, 255, 255,
  7, 8, 9, 10, 11, 12, 255, 255, 11, 12, 13, 14, 15, 16, 255, 255,
  15, 16, 17, 18, 19, 20, 255, 255, 19, 20, 21, 22, 23, 24, 255, 255,
  23, 24, 25, 26, 27, 28, 255, 255, 27, 28, 29, 30, 31, 30, 255, 255,
];

const int _u64Mask = 0xFFFFFFFFFFFFFFFF;

int _getShift(int v) => v == 255 ? 0 : (1 << v);

/// 按 `table` 把 `src` 的位重新映射（`table[i] = 255` 表示该位丢弃）。
int _mapU64(int src, List<int> table) {
  var acc = 0;
  for (var i = 0; i < table.length; i++) {
    final idx = table[i];
    if (idx == 255) continue;
    if ((_getShift(idx) & src) != 0) {
      acc |= _getShift(i);
    }
  }
  return acc;
}

int _makeU64(int hi, int lo) => ((hi & 0xFFFFFFFF) << 32) | (lo & 0xFFFFFFFF);

/// 酷我非标准 DES。
class KuwoDes {
  KuwoDes(List<int> key, {this.decrypt = true}) {
    final k = Uint8List.fromList(key);
    var param = _mapU64(_leU64(k), _keyPermutationTable);
    final subkeys = List<int>.filled(16, 0);
    final order = decrypt
        ? List<int>.generate(16, (i) => 15 - i)
        : List<int>.generate(16, (i) => i);
    for (var k2 = 0; k2 < 16; k2++) {
      final shl = _keyRndShifts[k2];
      final mask = _keyShiftLeftMasks[k2];
      param = (((param & mask) << (28 - shl)) | ((param & ~mask & _u64Mask) >> shl)) &
          _u64Mask;
      subkeys[order[k2]] = _mapU64(param, _keyCompression);
    }
    _subkeys = subkeys;
  }

  final bool decrypt;
  late final List<int> _subkeys;

  static int _leU64(Uint8List b) {
    var v = 0;
    for (var i = 7; i >= 0; i--) {
      v = (v << 8) | b[i];
    }
    return v & _u64Mask;
  }

  static int _hi(int v) => (v >>> 32) & 0xFFFFFFFF;
  static int _lo(int v) => v & 0xFFFFFFFF;

  int _round(int state, int subkey) {
    final oldLeft = _hi(state);
    final oldRight = _lo(state);

    var s = _mapU64(oldLeft, _keyExpansion) & _u64Mask;
    s = (s ^ subkey) & _u64Mask;

    // 8 个 S 盒逐字节查表，拼成 32 位
    var right = 0;
    for (var i = 0; i < 8; i++) {
      final b = (s >>> (56 - 8 * i)) & 0xFF;
      right = ((right << 4) | _sboxes[i][b]) & 0xFFFFFFFF;
    }
    right = _mapU64(right, _pbox) & 0xFFFFFFFF;
    right = (right ^ oldRight) & 0xFFFFFFFF;
    return _makeU64(right, oldLeft);
  }

  /// 解密/加密一个 8 字节块。
  Uint8List transformBlock(Uint8List block) {
    var state = _mapU64(_leU64(block), _ip) & _u64Mask;
    for (final sk in _subkeys) {
      state = _round(state, sk);
    }
    // 交换高低 32 位
    state = (((state & 0xFFFFFFFF) << 32) | _hi(state)) & _u64Mask;
    state = _mapU64(state, _ipInv) & _u64Mask;

    final out = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      out[i] = (state >>> (8 * i)) & 0xFF; // 小端写出
    }
    return out;
  }

  /// 批量变换（长度必须是 8 的倍数）。
  Uint8List transform(Uint8List data) {
    if (data.length % 8 != 0) {
      throwFormat('酷我 DES 数据长度必须是 8 的倍数，实际 ${data.length}');
    }
    final out = Uint8List(data.length);
    for (var off = 0; off < data.length; off += 8) {
      out.setRange(off, off + 8, transformBlock(data.sublist(off, off + 8)));
    }
    return out;
  }
}

Never throwFormat(String msg) => throw FormatException(msg);

/// 解密酷我的 `ksing` 密文（base64 承载），返回去掉尾部 0 的字符串。
String kuwoDecryptKsing(String data, List<int> key) {
  final cleaned = data.replaceAll(RegExp(r'\s'), '');
  final rest = cleaned.length % 4;
  final padded = rest == 0 ? cleaned : cleaned + '=' * (4 - rest);
  final decoded = base64.decode(padded);
  final des = KuwoDes(key);
  final plain = des.transform(Uint8List.fromList(decoded));
  var end = plain.length;
  while (end > 0 && plain[end - 1] == 0) {
    end--;
  }
  return utf8.decode(plain.sublist(0, end), allowMalformed: true);
}

/// 从 `ksing` 密文中取出 ekey（前 16 字节是校验头，跳过）。
String kuwoDecodeEkey(String data, List<int> key) {
  final decoded = kuwoDecryptKsing(data, key);
  if (decoded.length <= 16) {
    throw const FormatException('酷我 ksing 密文长度异常');
  }
  return decoded.substring(16);
}
