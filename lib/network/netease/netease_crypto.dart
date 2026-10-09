/// 网易云加密工具（对应原生 `network/netease/NeteaseCrypto.kt`）。
///
/// - EAPI 参数加密：AES-128-ECB/PKCS5 + hex（使用 pointycastle）
/// - 封面图片 ID 加密：XOR + MD5 + URL_SAFE base64
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

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
    final key = Uint8List.fromList(utf8.encode(_aesKey));
    final plain = utf8.encode(text);
    final padded = _pkcs7Pad(plain, 16);
    final enc = _aesEcbEncrypt(key, padded);
    return _hex(enc);
  }

  /// 网易云图片 ID 加密（XOR + MD5 + URL_SAFE base64，无填充）。
  static String encryptId(String id) {
    final sb = StringBuffer();
    for (var i = 0; i < id.length; i++) {
      sb.writeCharCode(id.codeUnitAt(i) ^ _magic.codeUnitAt(i % _magic.length));
    }
    final digest = crypto.md5.convert(utf8.encode(sb.toString())).bytes;
    return base64UrlEncode(digest).replaceAll('=', '');
  }

  /// 由图片 ID 生成封面直链。
  ///
  /// 默认取 **3000**：网易云 CDN 的 `param={n}y{n}` 上限为 3000，
  /// 且超出原图分辨率时会自动截断（不会报错），等价于「取原图」。
  /// 降级由 [CoverUrl.candidates] + `CoverImage` 在加载失败时下探。
  static String picUrl(int? picId, [int size = 3000]) {
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

Uint8List _pkcs7Pad(List<int> data, int blockSize) {
  final padLen = blockSize - (data.length % blockSize);
  final out = Uint8List(data.length + padLen);
  out.setAll(0, data);
  for (var i = data.length; i < out.length; i++) {
    out[i] = padLen;
  }
  return out;
}

/// 使用 pointycastle 的 AES-128-ECB 加密。
Uint8List _aesEcbEncrypt(Uint8List key, Uint8List input) {
  final cipher = ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(key));
  final out = Uint8List(input.length);
  var offset = 0;
  while (offset < input.length) {
    cipher.processBlock(input, offset, out, offset);
    offset += cipher.blockSize;
  }
  return out;
}
