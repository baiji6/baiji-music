/// 网易云加密工具（对应原生 `network/netease/NeteaseCrypto.kt`）。
///
/// - EAPI 参数加密：AES-128-ECB/PKCS5 + hex
/// - 封面图片 ID 加密：XOR + MD5 + URL_SAFE base64
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

const String _aesKey = 'e82ckenh8dichen8';
const String _magic = '3go8&\$8*3*3h0k(2)2';

String md5Hex(String text) =>
    crypto.md5.convert(utf8.encode(text)).toString();

/// EAPI 参数加密。
/// 明文格式：`{apiPath}-36cd479b6b5-{payloadJson}-36cd479b6b5-{digest}`
/// digest = md5("nobody{apiPath}use{payloadJson}md5forencrypt")
class NeteaseCrypto {
  NeteaseCrypto._();

  static String encryptParams(String eapiPath, String payloadJson) {
    final path = eapiPath.replaceAll('/eapi/', '/api/');
    final digest = md5Hex('nobody${path}use${payloadJson}md5forencrypt');
    final text = '$path-36cd479b6b5-$payloadJson-36cd479b6b5-$digest';
    // AES-128-ECB + PKCS5（PKCS7 等价）
    final key = Uint8List.fromList(utf8.encode(_aesKey));
    final plain = utf8.encode(text);
    final padded = _pkcs7Pad(plain, 16);
    final enc = _aesEcbEncryptOnce(key, padded);
    return _hex(enc);
  }

  /// 网易云图片 ID 加密（XOR + MD5 + URL_SAFE base64，无填充）。
  static String encryptId(String id) {
    final sb = StringBuffer();
    for (var i = 0; i < id.length; i++) {
      sb.writeCharCode(id.codeUnitAt(i) ^ _magic.codeUnitAt(i % _magic.length));
    }
    final digest = crypto.md5.convert(utf8.encode(sb.toString())).bytes;
    return base64UrlEncode(digest).replaceAll('=', ''); // URL_SAFE 且无 '=' 补位
  }

  /// 由图片 ID 生成封面直链。
  static String picUrl(int? picId, [int size = 300]) {
    if (picId == null || picId == 0) return '';
    final enc = encryptId(picId.toString());
    return 'https://p3.music.126.net/$enc/$picId.jpg?param=${size}y$size';
  }
}

String _hex(List<int> data) {
  final sb = StringBuffer();
  for (final b in data) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _pkcs7Pad(Uint8List data, int blockSize) {
  final padLen = blockSize - (data.length % blockSize);
  final out = Uint8List(data.length + padLen);
  out.setAll(0, data);
  for (var i = data.length; i < out.length; i++) {
    out[i] = padLen;
  }
  return out;
}

/// 一次 AES-128-ECB 加密（单块直接 ECB，多块逐块独立）。
Uint8List _aesEcbEncryptOnce(Uint8List key, Uint8List input) {
  // 复用 qq_crypto.dart 的 AES 实现
  // （那里提供 aesCbcEncrypt；为了隔离依赖，这里内联一个简单的 ECB）。
  // 注意：网易云 EAPI 使用 AES/ECB/PKCS5。
  final out = Uint8List(input.length);
  // 直接用独立 AES ECB 实现
  for (var i = 0; i < input.length; i += 16) {
    final block = Uint8List.fromList(input.sublist(i, i + 16));
    final enc = _aesBlock(block, key);
    out.setRange(i, i + 16, enc);
  }
  return out;
}

// ---------- 纯 Dart AES-128 实现（单块加密，用于网易云 EAPI） ----------

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
  0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
];

int _aesMul(int a, int b) {
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

List<int> _aesExpandKey128(Uint8List key) {
  final w = List<int>.filled(176, 0);
  for (var i = 0; i < 16; i++) {
    w[i] = key[i];
  }
  int rcon(int i) {
    var r = 1;
    for (var j = 1; j < i; j++) {
      r = _aesMul(r, 2);
    }
    return r;
  }

  for (var i = 4; i < 44; i++) {
    var temp = w[(i - 1) * 4];
    final t1 = w[(i - 1) * 4 + 1];
    final t2 = w[(i - 1) * 4 + 2];
    final t3 = w[(i - 1) * 4 + 3];
    if (i % 4 == 0) {
      final t0saved = temp;
      temp = _aesSbox[t1] ^ rcon(i ~/ 4);
      w[i * 4] = w[(i - 4) * 4] ^ temp;
      w[i * 4 + 1] = w[(i - 4) * 4 + 1] ^ _aesSbox[t2];
      w[i * 4 + 2] = w[(i - 4) * 4 + 2] ^ _aesSbox[t3];
      w[i * 4 + 3] = w[(i - 4) * 4 + 3] ^ _aesSbox[t0saved];
    } else {
      w[i * 4] = w[(i - 4) * 4] ^ temp;
      w[i * 4 + 1] = w[(i - 4) * 4 + 1] ^ t1;
      w[i * 4 + 2] = w[(i - 4) * 4 + 2] ^ t2;
      w[i * 4 + 3] = w[(i - 4) * 4 + 3] ^ t3;
    }
  }
  return w;
}

Uint8List _aesBlock(Uint8List input, Uint8List key) {
  final wk = _aesExpandKey128(key);
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
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        state[r * 4 + c] = t[r * 4 + ((c + r) % 4)];
      }
    }
  }

  void mixColumns() {
    for (var c = 0; c < 4; c++) {
      final a0 = state[c * 4];
      final a1 = state[c * 4 + 1];
      final a2 = state[c * 4 + 2];
      final a3 = state[c * 4 + 3];
      state[c * 4] = _aesMul(a0, 2) ^ _aesMul(a1, 3) ^ a2 ^ a3;
      state[c * 4 + 1] = a0 ^ _aesMul(a1, 2) ^ _aesMul(a2, 3) ^ a3;
      state[c * 4 + 2] = a0 ^ a1 ^ _aesMul(a2, 2) ^ _aesMul(a3, 3);
      state[c * 4 + 3] = _aesMul(a0, 3) ^ a1 ^ a2 ^ _aesMul(a3, 2);
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
  return Uint8List.fromList(state.map((e) => e & 0xff).toList());
}