/// 网易云音乐 NCM 解密。
///
/// 移植自 `um_crypto/ncm`。NCM 头部结构：
/// ```
/// "CTENFDAM" (8) | version(1) | clientVersion(1) | contentKeyLen(u32 LE)
/// | contentKey | metadataLen(u32 LE) | metadata | crc32(u32 LE)
/// | coverVersion(1) | coverFrameLen(u32 LE) | image1Len(u32 LE)
/// | image1 | image2 |音频数据...
/// ```
///
/// 解密链条是三步：
/// 1. `contentKey` 每个字节异或 `0x64` → AES-128-ECB 解密（PKCS#7 去填充）→ 去掉 `neteasecloudmusic` 前缀，得到真正的 RC4 密钥；
/// 2. 用该密钥跑一次标准 RC4 KSA/PRGA 生成 256 字节密钥流；
/// 3. 音频数据逐字节异或这个**固定**密钥流。
///
/// metadata 是另一条链：异或 `0x63` → 去 `163 key(Don't modify):` 前缀
/// → base64 解码 → AES-128-ECB 解密 → 去 `music:` 前缀 → JSON。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const List<int> _contentAesKey = [
  0x68, 0x7A, 0x48, 0x52, 0x41, 0x6D, 0x73, 0x6F, //
  0x35, 0x6B, 0x49, 0x6E, 0x62, 0x61, 0x78, 0x57,
]; // "hzHRAmso5kInbaxW"

const List<int> _metadataAesKey = [
  0x23, 0x31, 0x34, 0x6C, 0x6A, 0x6B, 0x5F, 0x21, //
  0x5C, 0x5D, 0x26, 0x45, 0x30, 0x55, 0x3C, 0x27,
]; // "#14ljk_!\]&0U<'("

const String _contentKeyPrefix = 'neteasecloudmusic';
const List<int> _metadataPrefix = [
  0x31, 0x36, 0x33, 0x20, 0x6B, 0x65, 0x79, 0x28, //
  0x44, 0x6F, 0x6E, 0x27, 0x74, 0x20, 0x6D, 0x6F,
  0x64, 0x69, 0x66, 0x79, 0x29, 0x3A,
]; // "163 key(Don't modify):"

int _u32le(Uint8List b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

/// AES-128-ECB 解密并去掉 PKCS#7 填充。
Uint8List _aesEcbDecryptPkcs7(Uint8List data, List<int> key) {
  if (data.isEmpty || data.length % 16 != 0) {
    throw FormatException('AES 数据长度非法: ${data.length}');
  }
  final cipher = ECBBlockCipher(AESEngine())
    ..init(false, KeyParameter(Uint8List.fromList(key)));
  final out = Uint8List(data.length);
  var off = 0;
  while (off < data.length) {
    cipher.processBlock(data, off, out, off);
    off += cipher.blockSize;
  }

  final pad = out.last;
  if (pad < 1 || pad > 16 || pad > out.length) {
    throw const FormatException('AES PKCS#7 填充非法');
  }
  for (var i = out.length - pad; i < out.length; i++) {
    if (out[i] != pad) {
      throw const FormatException('AES PKCS#7 填充非法');
    }
  }
  return Uint8List.sublistView(out, 0, out.length - pad);
}

/// 解密 content key，返回去掉 `neteasecloudmusic` 前缀的 RC4 密钥。
Uint8List ncmDecryptContentKey(Uint8List encrypted) {
  final xored = Uint8List(encrypted.length);
  for (var i = 0; i < encrypted.length; i++) {
    xored[i] = encrypted[i] ^ 0x64;
  }
  final plain = _aesEcbDecryptPkcs7(xored, _contentAesKey);
  final prefixBytes = utf8.encode(_contentKeyPrefix);
  for (var i = 0; i < prefixBytes.length; i++) {
    if (i >= plain.length || plain[i] != prefixBytes[i]) {
      throw FormatException('NCM content key 前缀异常: '
          '${utf8.decode(plain.sublist(0, plain.length < 12 ? plain.length : 12), allowMalformed: true)}');
    }
  }
  return Uint8List.fromList(plain.sublist(prefixBytes.length));
}

/// 解密 metadata，返回 JSON 字符串。
String ncmDecryptMetadata(Uint8List encrypted) {
  final xored = Uint8List(encrypted.length);
  for (var i = 0; i < encrypted.length; i++) {
    xored[i] = encrypted[i] ^ 0x63;
  }
  for (var i = 0; i < _metadataPrefix.length; i++) {
    if (i >= xored.length || xored[i] != _metadataPrefix[i]) {
      throw const FormatException('NCM metadata 前缀异常，不是 ncm 文件');
    }
  }
  final b64 = utf8.decode(
      Uint8List.sublistView(xored, _metadataPrefix.length),
      allowMalformed: true);
  final cleaned = b64.replaceAll(RegExp(r'\s'), '');
  final rest = cleaned.length % 4;
  final padded = rest == 0 ? cleaned : cleaned + '=' * (4 - rest);
  final plain = _aesEcbDecryptPkcs7(Uint8List.fromList(base64.decode(padded)), _metadataAesKey);

  const musicPrefix = [0x6D, 0x75, 0x73, 0x69, 0x63, 0x3A]; // "music:"
  for (var i = 0; i < musicPrefix.length; i++) {
    if (i >= plain.length || plain[i] != musicPrefix[i]) {
      throw const FormatException('NCM metadata JSON 前缀异常');
    }
  }
  return utf8.decode(
      Uint8List.sublistView(plain, musicPrefix.length),
      allowMalformed: true);
}

/// NCM 文件头。
class NcmHeader {
  NcmHeader({
    required this.version,
    required this.clientVersion,
    required this.contentKey,
    required this.metadata,
    required this.image1,
    required this.image2,
    required this.audioDataOffset,
    required this.audioRc4KeyStream,
  });

  final int version;
  final int clientVersion;

  /// 加密态的 content key（未解密）。
  final Uint8List contentKey;

  /// 加密态的 metadata。
  final Uint8List metadata;

  /// 内嵌封面，通常是 jpg。
  final Uint8List? image1;

  /// 第二张封面（同一帧的另一图）。
  final Uint8List? image2;

  /// 音频数据在文件中的起始偏移。
  final int audioDataOffset;

  /// 展开后的 256 字节 RC4 密钥流。
  final Uint8List audioRc4KeyStream;

  /// 解析并校验 metadata，返回 JSON。
  String readMetadata() => ncmDecryptMetadata(metadata);

  void decrypt(Uint8List data, int offset) {
    for (var i = 0; i < data.length; i++) {
      data[i] ^= audioRc4KeyStream[(offset + i) & 0xFF];
    }
  }
}

/// CRC-32（ISO-HDLC），用于校验头部完整性。
int _crc32(Uint8List data, [int start = 0, int? end]) {
  var crc = 0xFFFFFFFF;
  final last = end ?? data.length;
  for (var i = start; i < last; i++) {
    crc ^= data[i];
    for (var b = 0; b < 8; b++) {
      crc = (crc & 1) != 0 ? ((crc >>> 1) ^ 0xEDB88320) : (crc >>> 1);
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 生成音频用的 256 字节 RC4 密钥流。
Uint8List _buildAudioKeyStream(Uint8List encryptedContentKey) {
  final key = ncmDecryptContentKey(encryptedContentKey);

  final s = Uint8List.fromList(List<int>.generate(256, (i) => i));
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) & 0xFF;
    final t = s[i];
    s[i] = s[j];
    s[j] = t;
  }

  final stream = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    final idx = (i + 1) & 0xFF;
    final jj = (s[idx] + idx) & 0xFF;
    stream[i] = s[(s[idx] + s[jj]) & 0xFF];
  }
  return stream;
}

/// 判断是否 NCM 文件。
bool isNcmFile(Uint8List head) =>
    head.length >= 8 &&
    head[0] == 0x43 && // C
    head[1] == 0x54 && // T
    head[2] == 0x45 && // E
    head[3] == 0x4E && // N
    head[4] == 0x46 && // F
    head[5] == 0x44 && // D
    head[6] == 0x41 && // A
    head[7] == 0x4D; //   M

/// 解析 NCM 头部。至少需要 14 字节。
NcmHeader parseNcmHeader(Uint8List header) {
  if (header.length < 14) {
    throw const FormatException('NCM 头部太小');
  }
  if (!isNcmFile(header)) {
    throw const FormatException('不是 NCM 文件');
  }
  final version = header[8];
  final clientVersion = header[9];
  final contentKeyLen = _u32le(header, 10);

  var off = 14;
  void need(int n) {
    if (header.length < n) {
      throw FormatException('NCM 头部太小，需要 $n 字节，实际 ${header.length}');
    }
  }

  need(off + contentKeyLen + 4);
  final contentKey = Uint8List.fromList(header.sublist(off, off + contentKeyLen));
  off += contentKeyLen;

  final metadataLen = _u32le(header, off);
  off += 4;
  need(off + metadataLen + 9);
  final metadata = Uint8List.fromList(header.sublist(off, off + metadataLen));
  off += metadataLen;

  final expectedCrc = _u32le(header, off);
  final actualCrc = _crc32(header, 0, off);
  if (actualCrc != expectedCrc) {
    throw FormatException(
        'NCM 校验失败：期望 ${expectedCrc.toRadixString(16)}，实际 ${actualCrc.toRadixString(16)}');
  }
  off += 4;

  final coverVersion = header[off];
  off += 1;
  if (coverVersion != 1) {
    throw FormatException('不支持的封面版本: $coverVersion');
  }

  final coverFrameLen = _u32le(header, off);
  off += 4;
  need(off + 4);
  final image1Len = _u32le(header, off);
  off += 4;
  if (image1Len > coverFrameLen) {
    throw FormatException('NCM 封面帧异常：frame=$coverFrameLen image1=$image1Len');
  }

  need(off + coverFrameLen);
  final image2Len = coverFrameLen - image1Len;

  final image1 = image1Len == 0
      ? null
      : Uint8List.fromList(header.sublist(off, off + image1Len));
  off += image1Len;
  final image2 = image2Len == 0
      ? null
      : Uint8List.fromList(header.sublist(off, off + image2Len));
  off += image2Len;

  return NcmHeader(
    version: version,
    clientVersion: clientVersion,
    contentKey: contentKey,
    metadata: metadata,
    image1: image1,
    image2: image2,
    audioDataOffset: off,
    audioRc4KeyStream: _buildAudioKeyStream(contentKey),
  );
}
