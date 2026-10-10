/// 酷狗 KGM / VPR 解密。
///
/// 移植自 `um_crypto/kgm`。KGM 文件头 0x400 字节，其中记录了
/// `crypto_version` 与 `key_slot`，据此选择解密算法：
///
/// | crypto_version | 算法 | 密钥来源 |
/// |---|---|---|
/// | 2 | 4 字节 slot key 直接 XOR | 内置 `l,/'` |
/// | 3 | slot key + file key + 偏移异或 | 内置 `l,/'` + 头内file_key |
/// | 5 | QMC v2（Map / RC4） | 必须有 ekey |
///
/// 所有版本在真正解密前都会先拿头里的 `decrypt_test_data` 做一次自检，
/// 解出来必须等于该magic 对应的常量，否则直接判定密钥/文件不匹配——
/// 这层校验能挡住「文件截断」「key_slot 不支持」这类误报。
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';


import 'qmc.dart';
import 'qmc_ekey.dart';

/// 音频数据起始偏移。
const int kgmDataStartOffset = 0x400;

const List<int> _kgmHeaderMagic = [
  0x7C, 0xD5, 0x32, 0xEB, 0x86, 0x02, 0x7F, 0x4B, //
  0xA8, 0xAF, 0xA6, 0x8E, 0x0F, 0xFF, 0x99, 0x14,
];

const List<int> _kgmTestData = [
  0x38, 0x85, 0xED, 0x92, 0x79, 0x5F, 0xF8, 0x4C, //
  0xB3, 0x03, 0x61, 0x41, 0x16, 0xA0, 0x1D, 0x47,
];

const List<int> _vprHeaderMagic = [
  0x05, 0x28, 0xBC, 0x96, 0xE9, 0xE4, 0x5A, 0x43, //
  0x91, 0xAA, 0xBD, 0xD0, 0x7A, 0xF5, 0x36, 0x31,
];

const List<int> _vprTestData = [
  0x1D, 0x5A, 0x05, 0x34, 0x0C, 0x41, 0x8D, 0x42, //
  0x9C, 0x83, 0x92, 0x6C, 0xAE, 0x16, 0xFE, 0x56,
];

/// 酷狗唯一支持的 key slot。
const List<int> _slotKey1 = [0x6C, 0x2C, 0x2F, 0x27]; // "l,/'"

/// KGM 文件头。
class KgmHeader {
  KgmHeader({
    required this.magic,
    required this.offsetToData,
    required this.cryptoVersion,
    required this.keySlot,
    required this.decryptTestData,
    required this.fileKey,
    required this.challengeData,
    required this.audioHash,
  });

  final Uint8List magic;
  final int offsetToData;
  final int cryptoVersion;
  final int keySlot;
  final Uint8List decryptTestData;
  final Uint8List fileKey;
  final Uint8List challengeData;

  /// v5 才有：32 位十六进制音频指纹。
  final String audioHash;

  /// 是否是合法的 KGM/VPR 文件。
  bool get isKgm => _eq(magic, _kgmHeaderMagic);
  bool get isVpr => _eq(magic, _vprHeaderMagic);

  /// 音频数据起点，未指定时回落到 0x400。
  int get dataOffset => offsetToData == 0 ? kgmDataStartOffset : offsetToData;
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _u32le(Uint8List b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

/// 解析 KGM 文件头（至少需要 0x40 字节）。
KgmHeader parseKgmHeader(Uint8List buffer) {
  if (buffer.length < 0x40) {
    throw const FormatException('KGM 头部太小，至少需要 0x40 字节');
  }
  final magic = Uint8List.fromList(buffer.sublist(0, 0x10));

  final Uint8List challengeData;
  if (_eq(magic, _kgmHeaderMagic)) {
    challengeData = Uint8List.fromList(_kgmTestData);
  } else if (_eq(magic, _vprHeaderMagic)) {
    challengeData = Uint8List.fromList(_vprTestData);
  } else {
    throw const FormatException('不是 KGM 文件（magic 不匹配）');
  }

  var p = 0x10;
  final offsetToData = _u32le(buffer, p);
  p += 4;
  final cryptoVersion = _u32le(buffer, p);
  p += 4;
  // key_slot 在 Rust 侧是 i32，v5 用 -1 表示「无 slot key，改用 ekey」，
  // 所以这里必须按有符号读，否则 -1 会变成 4294967295 而匹配不上分支。
  final keySlot = ByteData.sublistView(buffer).getInt32(p, Endian.little);
  p += 4;
  final decryptTestData = Uint8List.fromList(buffer.sublist(p, p + 0x10));
  p += 0x10;
  final fileKey = Uint8List.fromList(buffer.sublist(p, p + 0x10));
  p += 0x10;

  var audioHash = '';
  if (cryptoVersion == 5) {
    p += 8; // padding
    final hashSize = _u32le(buffer, p);
    p += 4;
    if (hashSize != 0x20) {
      throw FormatException('KGM v5 audio_hash 长度异常: $hashSize');
    }
    if (p + hashSize > buffer.length) {
      throw const FormatException('KGM v5 audio_hash 越界');
    }
    audioHash = String.fromCharCodes(buffer.sublist(p, p + hashSize));
  }

  return KgmHeader(
    magic: magic,
    offsetToData: offsetToData,
    cryptoVersion: cryptoVersion,
    keySlot: keySlot,
    decryptTestData: decryptTestData,
    fileKey: fileKey,
    challengeData: challengeData,
    audioHash: audioHash,
  );
}

List<int> _getSlotKey(int keySlot) {
  if (keySlot != 1) {
    throw FormatException('不支持的 KGM key slot: $keySlot');
  }
  return _slotKey1;
}

/// 酷狗解密器基类接口。
abstract class KgmDecipher {
  void decrypt(Uint8List data, int offset);
}

/// v2：4 字节 slot key 直接 XOR。
class KgmV2 implements KgmDecipher {
  KgmV2(KgmHeader header)
      : key = Uint8List.fromList(_getSlotKey(header.keySlot).sublist(0, 4));

  final Uint8List key;

  @override
  void decrypt(Uint8List data, int offset) {
    for (var i = 0; i < data.length; i++) {
      data[i] ^= key[(offset + i) % key.length];
    }
  }
}

/// v3：slot key 与 file key 做 md5 后，按偏移逐字节变换。
class KgmV3 implements KgmDecipher {
  KgmV3(KgmHeader header) {
    final slotKey = _getSlotKey(header.keySlot);
    _slotKey = _hashKey(slotKey);
    // file_key 长度是 17 而不是 16：末位固定 0x6B，这是算法的一部分
    final fk = Uint8List(17)..fillRange(0, 17, 0x6B);
    fk.setRange(0, 16, _hashKey(header.fileKey));
    _fileKey = fk;
  }

  late final Uint8List _slotKey;
  late final Uint8List _fileKey;

  /// 上游的 `hash_key`。
  ///
  /// ⚠️ 这里有个非常隐蔽的坑：Rust 写的是
  /// `result.rchunks_exact_mut(2).zip(digest.chunks_exact(2))`，
  /// 看起来只是把 md5 原样拷贝一遍（恒等），但 `rchunks`是**从尾部**取块，
  /// `chunks` 从头部取块，两者顺序相反——所以实际语义是
  ///「每 2 字节为一组做逆序重排」：
  /// `[a b c d] → [c d a b]`。
  ///
  /// 按恒等拷贝实现会解出完全不同的音频，且不会报任何错。
  static Uint8List _hashKey(List<int> data) {
    final digest = Uint8List.fromList(md5.convert(data).bytes);
    final out = Uint8List(16);
    for (var g = 0; g < 8; g++) {
      final dst = 16 - 2 * (g + 1); // rchunks：从尾往头
      final src = 2 * g; // chunks：从头往尾
      out[dst] = digest[src];
      out[dst + 1] = digest[src + 1];
    }
    return out;
  }

  /// 供测试调用，验证 2 字节组逆序重排的语义。
  static Uint8List hashKeyForTest(List<int> data) => _hashKey(data);

  /// 偏移量的 4 个字节异或。
  static int _offsetKey(int offset) {
    final b = offset & 0xFFFFFFFF;
    return (b & 0xFF) ^ ((b >> 8) & 0xFF) ^ ((b >> 16) & 0xFF) ^ ((b >> 24) & 0xFF);
  }

  @override
  void decrypt(Uint8List data, int offset) {
    for (var i = 0; i < data.length; i++) {
      final pos = offset + i;
      final ok = _offsetKey(pos);
      var temp = data[i] ^ _fileKey[pos % _fileKey.length];
      temp ^= (temp << 4) & 0xFF;
      temp ^= _slotKey[pos % _slotKey.length];
      temp ^= ok;
      data[i] = temp & 0xFF;
    }
  }
}

/// v5：复用 QMC v2，密钥来自 ekey。
class KgmV5 implements KgmDecipher {
  KgmV5(String ekey) : cipher = QmcV2Cipher(qmcEkeyDecrypt(ekey));

  final QmcV2Cipher cipher;

  @override
  void decrypt(Uint8List data, int offset) => cipher.decrypt(data, offset);
}

/// 按头部信息创建解密器，并做自检。
///
/// [ekey] 只有 v5 需要；其余版本传null 即可。
KgmDecipher createKgmDecipher(KgmHeader header, {String? ekey}) {
  final KgmDecipher d;
  switch (header.cryptoVersion) {
    case 2:
      d = KgmV2(header);
    case 3:
      d = KgmV3(header);
    case 5:
      if (ekey == null || ekey.isEmpty) {
        throw const FormatException('KGM v5 需要 ekey，请先导入密钥');
      }
      d = KgmV5(ekey);
    default:
      throw FormatException('不支持的 KGM 加密版本: ${header.cryptoVersion}');
  }

  // 自检：解密头部里的 test data，必须得到该 magic 对应的常量
  final probe = Uint8List.fromList(header.decryptTestData);
  d.decrypt(probe, 0);
  if (!_eq(probe, header.challengeData)) {
    throw const FormatException('KGM 自检失败：文件不匹配或密钥错误');
  }
  return d;
}
