// 网易云 weapi 加密单测（v2.3.0-fix5）。
//
// 这个加密是「网易云写接口从 400 参数错误变成 200」的唯一变量，必须锁死：
// - 已知向量由**已打通线上 /weapi 的 Python 参考实现**逐位对齐生成
//   （同一 payload+secret，Python 与 Dart 输出一致，且 Dart 产物直接发
//   真实请求返回 code=200，测试评论已删除）；
// - 往返解密用 pointycastle 反向解开双层 AES，确认 params 解回原 JSON；
// - RSA 侧正向验算 encSecKey == pow(reverse(secret), 0x10001, n)。
import 'dart:convert';
import 'dart:typed_data';

import 'package:baiji_music/network/netease/netease_weapi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

const _fixedSecret = 'abcd1234efgh5678';
const _fixedJson =
    '{"threadId":"R_SO_4_657666","content":"weapi探测","csrf_token":"ABC123"}';

// Python 参考实现（线上实测可用）对同一输入的输出，逐位一致。
const _expectedParams =
    'j8Flgmjl7CglWwK9l83I5hG6Sso/YWnhFzcQAd2CDjLAgqA2PGRgSBaifCC5Nbn4HQvWK7LoTnEqsqar842eNx2mmhUaM4kw7SXmUzQOe+b6yWQ8vQHDMfFlkVfAGykMtU2bxmmp7zOxKc/1NCJ10w==';
const _expectedEncSecKey =
    '4983865ad6e5c2f1f5e4bc30d82d41730f4a320e8964d0f54d1e6b112338b397a0861f15d28adcb6e3c7cc442cb173f25f4950d2cc736bc926db626a70301a8e101616f620a4c7ff0f1f3c36d82bc3725a0445e2e66e8a6a630161b02ecdd80400bebd8cb9f458a51ddc7dc01f82b56adab971a21954e8821a3cd9c7b7c79c49';

/// 与 [NeteaseWeapi] 同算法的 AES-128-CBC 解密（PKCS#7），仅供测试验算。
String _aesCbcDecrypt(String base64Cipher, String key) {
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()));
  cipher.init(
    false,
    PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
      ParametersWithIV<KeyParameter>(
        KeyParameter(Uint8List.fromList(utf8.encode(key))),
        Uint8List.fromList(utf8.encode('0102030405060708')),
      ),
      null,
    ),
  );
  final out = cipher.process(base64.decode(base64Cipher));
  return utf8.decode(out);
}

void main() {
  group('NeteaseWeapi.encrypt', () {
    test('已知向量与线上实测的 Python 参考实现逐位一致', () {
      final p = NeteaseWeapi.encrypt(
        jsonDecode(_fixedJson) as Map<String, dynamic>,
        secretKey: _fixedSecret,
      );
      expect(p.params, _expectedParams);
      expect(p.encSecKey, _expectedEncSecKey);
    });

    test('params 双层 AES 可解密回原 JSON', () {
      final p = NeteaseWeapi.encrypt(
        jsonDecode(_fixedJson) as Map<String, dynamic>,
        secretKey: _fixedSecret,
      );
      // 第二层（随机 secret）→ 第一层（固定 nonce）→ 原文
      final once = _aesCbcDecrypt(p.params, _fixedSecret);
      final twice = _aesCbcDecrypt(once, '0CoJUm6Qyw8W8jud');
      expect(twice, _fixedJson);
    });

    test('encSecKey 是 256 位小写十六进制，且等于 RSA(reverse(secret))', () {
      final p = NeteaseWeapi.encrypt(
        jsonDecode(_fixedJson) as Map<String, dynamic>,
        secretKey: _fixedSecret,
      );
      expect(p.encSecKey, matches(RegExp(r'^[0-9a-f]{256}$')));
      final reversed = _fixedSecret.split('').reversed.join();
      final message = BigInt.parse(
          reversed.codeUnits
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
          radix: 16);
      final modulus = BigInt.parse(
          '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725'
          '152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312'
          'ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424'
          'd813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7',
          radix: 16);
      final expect_ = message
          .modPow(BigInt.parse('010001', radix: 16), modulus)
          .toRadixString(16)
          .padLeft(256, '0');
      expect(p.encSecKey, expect_);
    });

    test('不注入 secret 时每次生成 16 位随机字母数字，输出随之变化', () {
      final data = {'threadId': 'R_SO_4_1', 'content': 'x', 'csrf_token': 'y'};
      final a = NeteaseWeapi.encrypt(data);
      final b = NeteaseWeapi.encrypt(data);
      expect(a.params, isNot(b.params));
      expect(a.encSecKey, isNot(b.encSecKey));
      expect(a.encSecKey, matches(RegExp(r'^[0-9a-f]{256}$')));
    });

    test('payload 里的 csrf_token 与 query 一致时才通（形制锁）', () {
      // 网页端两个位置都带 csrf_token；payload 缺它网易云返回 400。
      // 这里只锁「调用方传进来的字段原样进 JSON」这一层。
      final p = NeteaseWeapi.encrypt(
        {'threadId': 'R_SO_4_1', 'content': 'hi', 'csrf_token': 'TOK'},
        secretKey: _fixedSecret,
      );
      final once = _aesCbcDecrypt(p.params, _fixedSecret);
      final twice = _aesCbcDecrypt(once, '0CoJUm6Qyw8W8jud');
      expect(jsonDecode(twice), containsPair('csrf_token', 'TOK'));
    });
  });
}
