/// 腾讯改良 TEA（tc_tea）解密。
///
/// 移植自 `tc_tea` crate 0.2.1（`lib_um_crypto_rust` 的依赖）。
/// 与标准 TEA 有两处差异，移植时不能按标准 TEA 写：
/// 1. **轮数是 16轮**，不是 32 轮；
/// 2. 字节序是**大端（BE）**，不是小端；
/// 3. 外层是" tweaked CBC"：密文块先与 `iv2` 异或再进 TEA，而 TEA 的输出
///    才是新的 `iv2`（标准 CBC 用密文块本身做下一个 IV）。
///
/// 这是 QQ 音乐 ekey 解密、以及 QMC v2 `.mflac` 的前置步骤。
library;

import 'dart:typed_data';

/// 固定填充长度：1 字节 pad_size + 2 字节 salt + 7 字节 0。
const int _saltLen = 2;
const int _zeroLen = 7;
const int _fixedPaddingLen = 1 + _saltLen + _zeroLen;

const int _rounds = 16;
const int _delta = 0x9e3779b9;

/// u32 截断。
int _u32(int v) => v & 0xFFFFFFFF;

/// TEA 单轮非线性变换。
int _singleRound(int value, int sum, int key1, int key2) {
  final left = _u32(_u32(value << 4) + key1);
  final right = _u32(_u32(value >>> 5) + key2);
  final mid = _u32(sum + value);
  return (left ^ mid ^ right) & 0xFFFFFFFF;
}

/// TEA ECB 单块解密：入参/返回值是一个 64 位块（高 32 位 = y，低 32 位 = z）。
int _teaDecryptBlock(int block, List<int> key) {
  var y = _u32((block >>> 32) & 0xFFFFFFFF);
  var z = _u32(block & 0xFFFFFFFF);
  var sum = _u32(_delta * _rounds);

  for (var i = 0; i < _rounds; i++) {
    z = _u32(z - _singleRound(y, sum, key[2], key[3]));
    y = _u32(y - _singleRound(z, sum, key[0], key[1]));
    sum = _u32(sum - _delta);
  }
  return (_u32(y) << 32) | _u32(z);
}

/// 把 16 字节密钥拆成 4 个大端 u32。
List<int> parseTeaKey(List<int> key) {
  if (key.length != 16) {
    throw ArgumentError.value(key.length, 'key', 'tc_tea 密钥必须是 16 字节');
  }
  return List<int>.generate(4, (i) {
    final o = i * 4;
    return _u32((key[o] << 24) | (key[o + 1] << 16) | (key[o + 2] << 8) | key[o + 3]);
  });
}

/// tc_tea 解密。返回去掉了头尾填充的明文。
///
/// 失败时抛出 [FormatException]（长度不合法或尾部 7 字节不是全0，
/// 后者意味着密钥不对）。
Uint8List tcTeaDecrypt(List<int> cipher, List<int> key) {
  final k = parseTeaKey(key);
  final inputLen = cipher.length;
  if (inputLen < _fixedPaddingLen || inputLen % 8 != 0) {
    throw FormatException('tc_tea 密文长度非法: $inputLen（需≥$_fixedPaddingLen 且为 8 的倍数）');
  }

  final plain = Uint8List(inputLen);
  var iv1 = 0;
  var iv2 = 0;

  for (var off = 0; off < inputLen; off += 8) {
    // 密文块按大端读成 64 位
    final cBlock = ((cipher[off] << 56) |
            (cipher[off + 1] << 48) |
            (cipher[off + 2] << 40) |
            (cipher[off + 3] << 32) |
            (cipher[off + 4] << 24) |
            (cipher[off + 5] << 16) |
            (cipher[off + 6] << 8) |
            cipher[off + 7]) &
        0xFFFFFFFFFFFFFFFF;

    final result = (cBlock ^ iv2) & 0xFFFFFFFFFFFFFFFF;
    final nextIv2 = _teaDecryptBlock(result, k);
    final pBlock = (nextIv2 ^ iv1) & 0xFFFFFFFFFFFFFFFF;

    plain[off] = (pBlock >>> 56) & 0xFF;
    plain[off + 1] = (pBlock >>> 48) & 0xFF;
    plain[off + 2] = (pBlock >>> 40) & 0xFF;
    plain[off + 3] = (pBlock >>> 32) & 0xFF;
    plain[off + 4] = (pBlock >>> 24) & 0xFF;
    plain[off + 5] = (pBlock >>> 16) & 0xFF;
    plain[off + 6] = (pBlock >>> 8) & 0xFF;
    plain[off + 7] = pBlock & 0xFF;

    // 注意：新的 iv2 是 TEA 的**输出**，不是密文块本身
    iv1 = cBlock;
    iv2 = nextIv2;
  }

  final padSize = plain[0] & 0x07;
  final startLoc = 1 + padSize + _saltLen;
  final endLoc = inputLen - _zeroLen;
  if (startLoc > endLoc) {
    throw const FormatException('tc_tea 填充长度非法');
  }
  for (var i = endLoc; i < inputLen; i++) {
    if (plain[i] != 0) {
      throw const FormatException('tc_tea 尾部校验失败，密钥不正确');
    }
  }
  return Uint8List.sublistView(plain, startLoc, endLoc);
}
