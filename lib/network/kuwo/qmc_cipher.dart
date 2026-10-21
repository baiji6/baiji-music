// QMC 解密算法 —— Dart 移植
// 来源: kuwo-music-relay-main/decrypt.php (开源实现, PolyForm Noncommercial 1.0.0)
//      并与 bai music_4.0 的 libyibaiqmc.so 交叉验证:
//        QMC_V2_DERIVE_KEY_1 == .rodata 0x2910 "386ZJY!@#*$%^&"
//        QMC_V2_DERIVE_KEY_2 == .rodata 0x29B0 "**#!(#$%&^a1cZ,T"
//        Rc4Cipher 的 KSA(模 keyLen) / segmentSkip 公式 与 so 中 0x109a0 / 0x10f74 一致
//
// 组成:
//   EkeyCipher       DES 变体(LSB-first), key="ylzsxkwm"  —— 解 Kuwo 的 ekey
//   QmcTea           腾讯 TEA(CBC 变体)                    —— 密钥派生
//   QmcKeyDerivation ekey -> rawKey -> 最终 key
//   MapCipher        QMC v1 (key <= 300 字节)
//   Rc4Cipher        QMC v2 (key >  300 字节)
//
// 注意: 需 64 位 Dart(VM/AOT); Web(JS) 下 int 只有 53 位, DES 的 64 位运算会出错。

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// QMC 解密器接口: 都是「按文件偏移」寻址, 因此天然支持随机访问 / 流式 / seek
abstract class QmcCipher {
  /// 解密 [data], 其中 [offset] 是该数据在**整个文件**中的偏移
  Uint8List decrypt(Uint8List data, int offset);
}

// ============================================================
// EkeyCipher — DES 变体
// ============================================================
class EkeyCipher {
  static const String kuwoKey = 'ylzsxkwm';

  static const List<int> iperm = [
    57,49,41,33,25,17,9,1, 59,51,43,35,27,19,11,3,
    61,53,45,37,29,21,13,5, 63,55,47,39,31,23,15,7,
    56,48,40,32,24,16,8,0, 58,50,42,34,26,18,10,2,
    60,52,44,36,28,20,12,4, 62,54,46,38,30,22,14,6,
  ];
  static const List<int> fperm = [
    39,7,47,15,55,23,63,31, 38,6,46,14,54,22,62,30,
    37,5,45,13,53,21,61,29, 36,4,44,12,52,20,60,28,
    35,3,43,11,51,19,59,27, 34,2,42,10,50,18,58,26,
    33,1,41,9,49,17,57,25, 32,0,40,8,48,16,56,24,
  ];
  static const List<int> exp = [
    31,0,1,2,3,4,-1,-1, 3,4,5,6,7,8,-1,-1,
    7,8,9,10,11,12,-1,-1, 11,12,13,14,15,16,-1,-1,
    15,16,17,18,19,20,-1,-1, 19,20,21,22,23,24,-1,-1,
    23,24,25,26,27,28,-1,-1, 27,28,29,30,31,30,-1,-1,
  ];
  static const List<int> roundP = [
    15,6,19,20,28,11,27,16, 0,14,22,25,4,17,30,9,
    1,7,23,13,31,26,2,8, 18,12,29,5,21,10,3,24,
  ];
  static const List<int> kpc1 = [
    56,48,40,32,24,16,8,0, 57,49,41,33,25,17,9,1,
    58,50,42,34,26,18,10,2, 59,51,43,35,62,54,46,38,
    30,22,14,6,61,53,45,37, 29,21,13,5,60,52,44,36,
    28,20,12,4,27,19,11,3,
  ];
  static const List<int> kpc2 = [
    13,16,10,23,0,4,-1,-1, 2,27,14,5,20,9,-1,-1,
    22,18,11,3,25,7,-1,-1, 15,6,26,19,12,1,-1,-1,
    40,51,30,36,46,54,-1,-1, 29,39,50,44,32,47,-1,-1,
    43,48,38,55,33,52,-1,-1, 45,41,49,35,28,31,-1,-1,
  ];
  static const List<int> rot = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1];
  static const List<int> rotMask = [0, 0x100001, 0x300003];

  static const List<List<int>> sbox = [
    [14,4,3,15,2,13,5,3,13,14,6,9,11,2,0,5,4,1,10,12,15,6,9,10,1,8,12,7,8,11,7,0,0,15,10,5,14,4,9,10,7,8,12,3,13,1,3,6,15,12,6,11,2,9,5,0,4,2,11,14,1,7,8,13],
    [15,0,9,5,6,10,12,9,8,7,2,12,3,13,5,2,1,14,7,8,11,4,0,3,14,11,13,6,4,1,10,15,3,13,12,11,15,3,6,0,4,10,1,7,8,4,11,14,13,8,0,6,2,15,9,5,7,1,10,12,14,2,5,9],
    [10,13,1,11,6,8,11,5,9,4,12,2,15,3,2,14,0,6,13,1,3,15,4,10,14,9,7,12,5,0,8,7,13,1,2,4,3,6,12,11,0,13,5,14,6,8,15,2,7,10,8,15,4,9,11,5,9,0,14,3,10,7,1,12],
    [7,10,1,15,0,12,11,5,14,9,8,3,9,7,4,8,13,6,2,1,6,11,12,2,3,0,5,14,10,13,15,4,13,3,4,9,6,10,1,12,11,0,2,5,0,13,14,2,8,15,7,4,15,1,10,7,5,6,12,11,3,8,9,14],
    [2,4,8,15,7,10,13,6,4,1,3,12,11,7,14,0,12,2,5,9,10,13,0,3,1,11,15,5,6,8,9,14,14,11,5,6,4,1,3,10,2,12,15,0,13,2,8,5,11,8,0,15,7,14,9,4,12,7,10,9,1,13,6,3],
    [12,9,0,7,9,2,14,1,10,15,3,4,6,12,5,11,1,14,13,0,2,8,7,13,15,5,4,10,8,3,11,6,10,4,6,11,7,9,0,6,4,2,13,1,9,15,3,8,15,3,1,14,12,5,11,0,2,12,14,7,5,10,8,13],
    [4,1,3,10,15,12,5,0,2,11,9,6,8,7,6,9,11,4,12,15,0,3,10,5,14,13,7,8,13,14,1,2,13,6,14,9,4,1,2,14,11,13,5,0,1,10,8,3,0,11,3,5,9,4,15,2,7,8,12,15,10,7,6,12],
    [13,7,10,0,6,9,5,15,8,4,3,10,11,14,12,5,2,11,9,6,15,12,0,3,4,1,14,13,1,2,7,8,1,2,12,15,10,4,0,3,13,14,6,9,7,8,9,6,15,1,5,12,3,10,14,5,8,7,11,0,4,13,2,11],
  ];

  /// 位级置换: 输出第 p 位 = 输入第 tbl[p] 位; -1 跳过
  static int _shuffle(List<int> tbl, int bits, int val) {
    var r = 0;
    for (var p = 0; p < bits; p++) {
      final s = tbl[p];
      if (s >= 0) r |= ((val >> s) & 1) << p;
    }
    return r;
  }

  static int _execBlock(int blk, List<int> rkeys) {
    final v = _shuffle(iperm, 64, blk);
    var lo = v & 0xFFFFFFFF;
    var hi = (v >> 32) & 0xFFFFFFFF;

    for (final rk in rkeys) {
      final e = _shuffle(exp, 64, hi) ^ rk;
      var s = 0;
      for (var b = 0; b < 8; b++) {
        final six = (e >> (b * 8)) & 0x3F;
        s |= sbox[b][six] << (b * 4);
      }
      final p = _shuffle(roundP, 32, s);
      final newLo = hi;
      final newHi = lo ^ p;
      lo = newLo;
      hi = newHi;
    }

    final pre = ((lo << 32) | hi);
    return _shuffle(fperm, 64, pre);
  }

  static List<int> _buildRoundKeys(int keyVal, bool forDecrypt) {
    var cv = _shuffle(kpc1, 56, keyVal);
    final keys = <int>[];
    for (var r = 0; r < 16; r++) {
      final amt = rot[r];
      final m = rotMask[amt];
      cv = ((cv & m) << (28 - amt)) | ((cv & ~m) >> amt);
      keys.add(_shuffle(kpc2, 64, cv));
    }
    return forDecrypt ? keys.reversed.toList() : keys;
  }

  static int _readU64LE(Uint8List b, int off) {
    var v = 0;
    for (var i = 7; i >= 0; i--) {
      v = (v << 8) | b[off + i];
    }
    return v;
  }

  static void _writeU64LE(Uint8List b, int off, int v) {
    for (var i = 0; i < 8; i++) {
      b[off + i] = (v >> (8 * i)) & 0xFF;
    }
  }

  /// DES 解密(ECB, 8 字节分组)
  static Uint8List decrypt(Uint8List cipher, Uint8List key) {
    if (cipher.length % 8 != 0) {
      throw ArgumentError('密文长度必须是 8 的倍数');
    }
    final rk = _buildRoundKeys(_readU64LE(key, 0), true);
    final out = Uint8List(cipher.length);
    for (var i = 0; i < cipher.length; i += 8) {
      _writeU64LE(out, i, _execBlock(_readU64LE(cipher, i), rk));
    }
    return out;
  }

  /// Kuwo ekey 解密: Base64 -> DES 解密 -> 去尾部 \0
  static Uint8List decryptEkeyBase64(String b64) {
    final raw = base64Decode(b64);
    final dec = decrypt(raw, Uint8List.fromList(utf8.encode(kuwoKey)));
    var end = dec.length;
    while (end > 0 && dec[end - 1] == 0) {
      end--;
    }
    return Uint8List.sublistView(dec, 0, end);
  }
}

// ============================================================
// QmcTea — 腾讯 TEA (CBC 变体)
// ============================================================
class QmcTea {
  static const int _delta = 0x9E3779B9;
  static const int _m32 = 0xFFFFFFFF;

  static Uint8List _teaDecryptBlock(Uint8List block, Uint8List key) {
    var v0 = (block[0] << 24) | (block[1] << 16) | (block[2] << 8) | block[3];
    var v1 = (block[4] << 24) | (block[5] << 16) | (block[6] << 8) | block[7];
    final k0 = (key[0] << 24) | (key[1] << 16) | (key[2] << 8) | key[3];
    final k1 = (key[4] << 24) | (key[5] << 16) | (key[6] << 8) | key[7];
    final k2 = (key[8] << 24) | (key[9] << 16) | (key[10] << 8) | key[11];
    final k3 = (key[12] << 24) | (key[13] << 16) | (key[14] << 8) | key[15];

    var sum = (_delta * 16) & _m32;
    for (var i = 0; i < 16; i++) {
      final t1 = ((v0 << 4) + k2) & _m32;
      final t2 = (v0 + sum) & _m32;
      final t3 = ((v0 >> 5) + k3) & _m32;
      v1 = (v1 - (t1 ^ t2 ^ t3)) & _m32;

      final u1 = ((v1 << 4) + k0) & _m32;
      final u2 = (v1 + sum) & _m32;
      final u3 = ((v1 >> 5) + k1) & _m32;
      v0 = (v0 - (u1 ^ u2 ^ u3)) & _m32;

      sum = (sum - _delta) & _m32;
    }

    return Uint8List.fromList([
      (v0 >> 24) & 0xFF, (v0 >> 16) & 0xFF, (v0 >> 8) & 0xFF, v0 & 0xFF,
      (v1 >> 24) & 0xFF, (v1 >> 16) & 0xFF, (v1 >> 8) & 0xFF, v1 & 0xFF,
    ]);
  }

  static Uint8List _xor8(Uint8List a, Uint8List b) {
    final o = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      o[i] = a[i] ^ b[i];
    }
    return o;
  }

  /// TC-TEA 解密
  static Uint8List decryptTencentTea(Uint8List input, Uint8List key) {
    const saltLen = 2;
    const zeroLen = 7;
    final inputLen = input.length;
    if (inputLen % 8 != 0) throw ArgumentError('输入长度必须是 8 的倍数');
    if (inputLen < 16) throw ArgumentError('输入长度过小');

    var decBlock = _teaDecryptBlock(Uint8List.sublistView(input, 0, 8), key);
    final padLen = decBlock[0] & 0x7;
    final outputLen = inputLen - 1 - padLen - saltLen - zeroLen;
    if (outputLen < 0) throw StateError('无效的填充长度');

    final output = Uint8List(outputLen);
    Uint8List ivPrev = Uint8List(8);
    Uint8List ivCur = Uint8List.sublistView(input, 0, 8);
    var inputPos = 8;
    var destIdx = 1 + padLen;

    void nextBlock() {
      ivPrev = ivCur;
      ivCur = Uint8List.sublistView(input, inputPos, inputPos + 8);
      decBlock = _teaDecryptBlock(_xor8(decBlock, ivCur), key);
      inputPos += 8;
      destIdx = 0;
    }

    var i = 1;
    while (i <= saltLen) {
      if (destIdx < 8) {
        destIdx++;
        i++;
      } else {
        nextBlock();
      }
    }

    var outPos = 0;
    while (outPos < outputLen) {
      if (destIdx < 8) {
        output[outPos] = decBlock[destIdx] ^ ivPrev[destIdx];
        destIdx++;
        outPos++;
      } else {
        nextBlock();
      }
    }

    i = 1;
    while (i <= zeroLen) {
      if (destIdx < 8) {
        if (decBlock[destIdx] != ivPrev[destIdx]) {
          throw StateError('尾部零字节校验失败');
        }
        destIdx++;
        i++;
      } else {
        nextBlock();
      }
    }
    return output;
  }
}

// ============================================================
// QmcKeyDerivation — ekey -> 最终 key
// ============================================================
class QmcKeyDerivation {
  static const List<int> rawKeyLengths = [704, 364];
  static const String v2KeyPrefix = 'QQMusic EncV2,Key:';
  static final Uint8List deriveKey1 = Uint8List.fromList([
    0x33, 0x38, 0x36, 0x5A, 0x4A, 0x59, 0x21, 0x40,
    0x23, 0x2A, 0x24, 0x25, 0x5E, 0x26, 0x29, 0x28,
  ]); // "386ZJY!@#*\$%^&"
  static final Uint8List deriveKey2 = Uint8List.fromList([
    0x2A, 0x2A, 0x23, 0x21, 0x28, 0x23, 0x24, 0x25,
    0x26, 0x5E, 0x61, 0x31, 0x63, 0x5A, 0x2C, 0x54,
  ]); // "**#!(#\$%&^a1cZ,T"

  /// 从 ekey 中提取 QMC raw key(Base64 字符串)
  static String extractRawKeyFromEkey(String ekey) {
    final dec = EkeyCipher.decryptEkeyBase64(ekey);
    for (final len in rawKeyLengths) {
      if (dec.length < len) continue;
      final start = dec.length - len;
      final candidate = String.fromCharCodes(
          Uint8List.sublistView(dec, start, dec.length));
      try {
        base64Decode(candidate); // 必须是合法 Base64
        return candidate;
      } catch (_) {
        continue;
      }
    }
    throw StateError('无法从 ekey 提取 QMC raw key');
  }

  static Uint8List _simpleMakeKey(int salt, int length) {
    final key = Uint8List(length);
    for (var i = 0; i < length; i++) {
      key[i] = (math.tan(salt + i * 0.1).abs() * 100.0).toInt() & 0xFF;
    }
    return key;
  }

  static Uint8List _deriveKeyV1(Uint8List raw) {
    if (raw.length < 16) throw StateError('密钥过短');
    final simpleKey = _simpleMakeKey(106, 8);
    final teaKey = Uint8List(16);
    for (var i = 0; i < 8; i++) {
      teaKey[i * 2] = simpleKey[i];
      teaKey[i * 2 + 1] = raw[i];
    }
    final decrypted = QmcTea.decryptTencentTea(
        Uint8List.sublistView(raw, 8), teaKey);
    final out = Uint8List(8 + decrypted.length);
    out.setRange(0, 8, raw);
    out.setRange(8, out.length, decrypted);
    return out;
  }

  static Uint8List _deriveKeyV2(Uint8List raw) {
    var buf = QmcTea.decryptTencentTea(raw, deriveKey1);
    buf = QmcTea.decryptTencentTea(buf, deriveKey2);
    return base64Decode(String.fromCharCodes(buf));
  }

  static Uint8List deriveQmcKey(String rawKey) {
    var decoded = base64Decode(rawKey);
    final prefix = utf8.encode(v2KeyPrefix);
    if (decoded.length >= prefix.length &&
        _startsWith(decoded, Uint8List.fromList(prefix))) {
      decoded = _deriveKeyV2(Uint8List.sublistView(decoded, prefix.length));
    }
    return _deriveKeyV1(decoded);
  }

  static bool _startsWith(Uint8List a, Uint8List prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (a[i] != prefix[i]) return false;
    }
    return true;
  }

  /// 直接用 ekey 构造解密器
  static QmcCipher createCipherFromEkey(String ekey) {
    final rawKey = extractRawKeyFromEkey(ekey);
    final key = deriveQmcKey(rawKey);
    return QmcCipherFactory.create(key);
  }
}

// ============================================================
// MapCipher — QMC v1
// ============================================================
class MapCipher implements QmcCipher {
  final Uint8List key;
  final int size;
  MapCipher(this.key) : size = key.length {
    if (size == 0) throw ArgumentError('Map cipher key 不能为空');
  }

  static int _rotate(int value, int bits) {
    final r = (bits + 4) % 8;
    return ((value << r) | (value >> r)) & 0xFF;
  }

  int _getMask(int offset) {
    final norm = offset > 0x7FFF ? offset % 0x7FFF : offset;
    final index = ((norm * norm) + 71214) % size;
    return _rotate(key[index], index & 0x7);
  }

  @override
  Uint8List decrypt(Uint8List data, int offset) {
    final out = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      out[i] = data[i] ^ _getMask(offset + i);
    }
    return out;
  }
}

// ============================================================
// Rc4Cipher — QMC v2 (首段 128 字节查表 + 5120 字节分段 RC4)
// ============================================================
class Rc4Cipher implements QmcCipher {
  static const int firstSegmentSize = 128;
  static const int segmentSize = 5120;

  final Uint8List key;
  final int size;
  late List<int> boxState;
  late int hash;
  Uint8List? _firstSegmentKeystream;
  final Map<int, int> _segmentSkipCache = {};

  Rc4Cipher(this.key) : size = key.length {
    if (size == 0) throw ArgumentError('RC4 cipher key 不能为空');

    boxState = List<int>.generate(size, (i) => i & 0xFF);
    var j = 0;
    for (var i = 0; i < size; i++) {
      j = (j + boxState[i] + key[i]) % size;
      final t = boxState[i];
      boxState[i] = boxState[j];
      boxState[j] = t;
    }
    hash = _getHashBase(key);
  }

  static int _getHashBase(Uint8List key) {
    var result = 1;
    for (final v in key) {
      if (v == 0) continue;
      final next = (result * v) & 0xFFFFFFFF;
      if (next == 0 || next <= result) break;
      result = next;
    }
    return result;
  }

  int _getSegmentSkip(int segmentId) {
    final cached = _segmentSkipCache[segmentId];
    if (cached != null) return cached;
    final seed = key[segmentId % size];
    final result = seed == 0
        ? 0
        : ((hash / ((segmentId + 1) * seed)) * 100.0).toInt() % size;
    _segmentSkipCache[segmentId] = result;
    return result;
  }

  void _decryptFirstSegment(Uint8List data, int fileOffset, int dataOffset, int length) {
    _firstSegmentKeystream ??= Uint8List.fromList(
      List<int>.generate(firstSegmentSize, (i) => key[_getSegmentSkip(i)]),
    );
    for (var i = 0; i < length; i++) {
      data[dataOffset + i] ^= _firstSegmentKeystream![fileOffset + i];
    }
  }

  void _decryptSegmentRange(Uint8List data, int fileOffset, int dataOffset, int length) {
    final box = List<int>.of(boxState);
    var j = 0;
    var k = 0;
    final segmentId = fileOffset ~/ segmentSize;
    final skipLength = (fileOffset % segmentSize) + _getSegmentSkip(segmentId);

    final keystream = Uint8List(length);
    final totalLen = skipLength + length;
    for (var index = 0; index < totalLen; index++) {
      j = (j + 1) % size;
      k = (box[j] + k) % size;
      final t = box[j];
      box[j] = box[k];
      box[k] = t;
      if (index >= skipLength) {
        final xorIndex = (box[j] + box[k]) % size;
        // PHP 的 chr() 会隐式 & 0xFF, 这里必须保持一致(box 值可能 > 255)
        keystream[index - skipLength] = box[xorIndex] & 0xFF;
      }
    }
    for (var i = 0; i < length; i++) {
      data[dataOffset + i] ^= keystream[i];
    }
  }

  @override
  Uint8List decrypt(Uint8List data, int offset) {
    if (data.isEmpty) return data;
    final result = Uint8List.fromList(data);
    var toProcess = result.length;
    var processed = 0;
    var pos = offset;

    if (pos < firstSegmentSize) {
      final blockSize = math.min(toProcess, firstSegmentSize - pos);
      _decryptFirstSegment(result, pos, processed, blockSize);
      pos += blockSize;
      toProcess -= blockSize;
      processed += blockSize;
      if (toProcess == 0) return result;
    }

    while (toProcess > 0) {
      final blockSize = math.min(toProcess, segmentSize - (pos % segmentSize));
      _decryptSegmentRange(result, pos, processed, blockSize);
      pos += blockSize;
      toProcess -= blockSize;
      processed += blockSize;
    }
    return result;
  }
}

// ============================================================
// 工厂
// ============================================================
class QmcCipherFactory {
  static QmcCipher create(Uint8List key) {
    if (key.length > 300) return Rc4Cipher(key);
    if (key.isNotEmpty) return MapCipher(key);
    throw ArgumentError('QMC key 不能为空');
  }
}
