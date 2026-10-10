/// 咪咕音乐 Migu3D 解密。
///
/// 移植自 `um_crypto/mg3d`。算法极简：把每个字节减去一个 32 字节密钥的
/// 对应位（即 `b = b - key[i % 32]`），真正难的是**密钥本身**。
///
/// 密钥有两种来源：
/// - **file_key**（推荐）：客户端配置里的 `androidFileKey` / `iosFileKey`，
///   密钥 = `MD5("AC89EC47A70B76F307CB39A0D74BCCB0" + fileKey)` 的**大写十六进制字符串**（32 字节）；
/// - **猜密钥**：直接读文件头，靠已知明文反推。上游提供两种猜测策略：
///   - WAV 型（`0x40`处是 key）：用 `RIFF` / `data` 两个已知明文做交叉验证；
///   - M4A 型（`0x00` 处是 key）：先按`ftypM4A mp42isom` 的固定布局还原 key，
///     再用首字节频率统计修正末尾 5 个字符（加密后 0 频次最高的就是 key 里字符最多的那个）。
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 音频数据起始偏移（咪咕文件在头部之后才是音频）。
const int miguDataStartOffset = 0x1000;

const String _saltHex = 'AC89EC47A70B76F307CB39A0D74BCCB0';

/// M4A 型已知明文布局。
const List<int> _guessPlainText = [
  0x00, 0x00, 0x00, 0x00, 0x66, 0x74, 0x79, 0x70, //
  0x4D, 0x34, 0x41, 0x20, 0x00, 0x00, 0x00, 0x00,
  0x4D, 0x34, 0x41, 0x20, 0x6D, 0x70, 0x34, 0x32,
  0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x00, 0x00,
];

bool _isPasswordChr(int c) =>
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46); // 0-9 A-F

String _toHexUpper(List<int> bytes) {
  const digits = '0123456789ABCDEF';
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(digits[b >> 4]);
    sb.write(digits[b & 0xF]);
  }
  return sb.toString();
}

/// 由 file_key 推导 32 字节密钥。
Uint8List miguKeyFromFileKey(String fileKey) {
  final digest = md5.convert([...utf8Bytes(_saltHex), ...utf8Bytes(fileKey)]).bytes;
  final hex = _toHexUpper(digest);
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = hex.codeUnitAt(i);
  }
  return out;
}

/// `utf8.encode` 的简写，避免额外 import dart:convert 的符号冲突。
List<int> utf8Bytes(String s) => s.codeUnits.map((c) => c & 0xFF).toList();

void _rawDecrypt(Uint8List data, List<int> key, int offset) {
  for (var i = 0; i < data.length; i++) {
    data[i] = (data[i] - key[(offset + i) % key.length]) & 0xFF;
  }
}

/// 咪咕解密器。
class MiguDecipher {
  MiguDecipher.fromFileKey(String fileKey) : key = miguKeyFromFileKey(fileKey);

  MiguDecipher.fromKey(List<int> key32)
      : key = Uint8List.fromList(key32) {
    if (key.length != 32) {
      throw ArgumentError.value(key32.length, 'key32', '咪咕密钥必须是 32 字节');
    }
  }

  final Uint8List key;

  void decrypt(Uint8List data, int offset) => _rawDecrypt(data, key, offset);
}

/// 尝试从文件头猜测密钥，失败返回 null。
Uint8List? guessMiguKey(Uint8List buffer) => _guessWav(buffer) ?? _guessM4a(buffer);

/// WAV 型：`0x40` 处 32 字节就是 key，用 `RIFF`(0x00) 与 `data`(0x60) 交叉验证。
Uint8List? _guessWav(Uint8List buffer) {
  if (buffer.length < 0x100) return null;
  final key = Uint8List.fromList(buffer.sublist(0x40, 0x60));
  for (final c in key) {
    if (!_isPasswordChr(c)) return null;
  }

  final riff = Uint8List.fromList(buffer.sublist(0, 4));
  _rawDecrypt(riff, key, 0x00);
  final data = Uint8List.fromList(buffer.sublist(0x60, 0x64));
  _rawDecrypt(data, key, 0x60);

  final isRiff = riff[0] == 0x52 && riff[1] == 0x49 && riff[2] == 0x46 && riff[3] == 0x46;
  final isData = data[0] == 0x64 && data[1] == 0x61 && data[2] == 0x74 && data[3] == 0x61;
  return (isRiff && isData) ? key : null;
}

/// M4A 型：先按固定明文布局还原，再用字节频率统计修正 key 的 5 个位置。
Uint8List? _guessM4a(Uint8List buffer) {
  if (buffer.length < 0x100) return null;

  final key = Uint8List(32);
  for (var i = 0; i < 0x20; i++) {
    key[i] = (buffer[i] - _guessPlainText[i]) & 0xFF;
  }
  for (var i = 0x04; i < 0x1C; i++) {
    if (!_isPasswordChr(key[i])) return null;
  }

  // 加密后的这 5 个位置，明文都是 0，所以「频次最高的字符」就是 key 里出现最多的那个
  final freqIdx = [0x03, 0x1C, 0x1D, 0x1E, 0x1F];
  final freqs = List.generate(5, (_) => <int, int>{});
  for (var off = 0; off < 0x100; off += 0x20) {
    for (var f = 0; f < 5; f++) {
      final c = buffer[off + freqIdx[f]];
      if (!_isPasswordChr(c)) continue;
      freqs[f].update(c, (v) => v + 1, ifAbsent: () => 1);
    }
  }
  for (var f = 0; f < 5; f++) {
    var best = 0;
    var bestCount = 0;
    freqs[f].forEach((item, count) {
      if (count > bestCount) {
        best = item;
        bestCount = count;
      }
    });
    key[freqIdx[f]] = best;
  }

  if (!_isPasswordChr(key[0x03])) return null;
  for (var i = 0x1C; i < 0x20; i++) {
    if (!_isPasswordChr(key[i])) return null;
  }
  return key;
}

/// 判断是否是咪咕文件。
///
/// 咪咕没有固定 magic，只能靠「能否猜出合法密钥」来判定。
bool isMiguFile(Uint8List head) => guessMiguKey(head) != null;
