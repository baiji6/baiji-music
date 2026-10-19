// 网易云 weapi 参数加密（网页版同款）。
//
// 为什么需要它（v2.3.0-fix5 实测）：
// 评论写接口 `/api/resource/comments/add|reply` 的**明文参数形态已废弃**——
// 带完整浏览器 Cookie 直接 POST 表单恒定返回 `{"code":400,"message":"参数错误"}`，
// 与账号/频率无关；App 之前把它误判成「250 风控」。
// 改用网页版同款 `/weapi/...` + AES-CBC 双层加密 + RSA(encSecKey) 后，
// 同一账号、同一 Cookie 立即 `code=200` 发评成功（实测后已删除测试评论）。
//
// 算法（与 music.163.com 网页端一致）：
//   secret   = 16 位随机字母数字
//   params   = base64(AES-CBC(json, key=NONCE, iv=IV))
//   params   = base64(AES-CBC(params, key=secret, iv=IV))
//   encSecKey= RSA(reverse(secret), e=0x10001, n=MODULUS) 的 256 位十六进制
// 注意 RSA 是**无填充**的教科书实现：把 secret 反转后当成大端整数做模幂。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 一次加密的产物：表单里的 `params` 与 `encSecKey`。
class WeapiPayload {
  const WeapiPayload({required this.params, required this.encSecKey});

  final String params;
  final String encSecKey;
}

/// 网易云 weapi 加密器（纯 Dart，无网络副作用，便于单测）。
abstract final class NeteaseWeapi {
  /// 第一层 AES 的固定密钥（网页端硬编码）。
  static const String _nonce = '0CoJUm6Qyw8W8jud';

  /// AES-CBC 固定 IV。
  static const String _iv = '0102030405060708';

  /// RSA 公钥指数。
  static const String _pubExp = '010001';

  /// RSA 模数（网页端硬编码，256 字节十六进制）。
  static const String _modulus =
      '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab1'
      '7a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870'
      '114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97d'
      'def52741d546b8e289dc6935b3ece0462db0a22b8e7';

  static const String _alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  /// 加密一组参数。[secretKey] 仅供测试注入固定密钥，生产不传。
  static WeapiPayload encrypt(
    Map<String, dynamic> data, {
    String? secretKey,
  }) {
    final secret = secretKey ?? _randomSecret();
    final json = jsonEncode(data);
    // 第一层：固定 nonce 加密
    final once = _aesCbcBase64(json, _nonce);
    // 第二层：随机 secret 加密（真正的会话密钥）
    final twice = _aesCbcBase64(once, secret);
    return WeapiPayload(params: twice, encSecKey: _rsaEncrypt(secret));
  }

  /// AES-128-CBC/PKCS#7 → Base64。
  static String _aesCbcBase64(String plain, String key) {
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()));
    cipher.init(
      true,
      PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
        ParametersWithIV<KeyParameter>(
          KeyParameter(Uint8List.fromList(utf8.encode(key))),
          Uint8List.fromList(utf8.encode(_iv)),
        ),
        null,
      ),
    );
    final out = cipher.process(Uint8List.fromList(utf8.encode(plain)));
    return base64.encode(out);
  }

  /// RSA 无填充模幂，输出**小写十六进制、左补零到 256 字符**。
  static String _rsaEncrypt(String secret) {
    // 关键细节：明文按字符反转（网页端 `text.split('').reverse().join('')`）
    final reversed = secret.split('').reversed.join();
    final message = BigInt.parse(_toHex(utf8.encode(reversed)), radix: 16);
    final exponent = BigInt.parse(_pubExp, radix: 16);
    final modulus = BigInt.parse(_modulus, radix: 16);
    return message.modPow(exponent, modulus).toRadixString(16).padLeft(256, '0');
  }

  static String _toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _randomSecret() {
    final rnd = Random.secure();
    return String.fromCharCodes(
      List.generate(16, (_) => _alphabet.codeUnitAt(rnd.nextInt(_alphabet.length))),
    );
  }
}
