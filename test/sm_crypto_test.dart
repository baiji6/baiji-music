// 国密算法测试：标准测试向量 + gmssl 交叉验证 + 往返。
import 'dart:convert';
import 'dart:typed_data';

import 'package:baiji_music/core/sm_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String s) => Uint8List.fromList(
    List.generate(s.length ~/ 2, (i) => int.parse(s.substring(2 * i, 2 * i + 2), radix: 16)));

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('SM3（GM/T 0004-2012 标准向量，gmssl 对照）', () {
    test('SM3("abc")', () {
      expect(_toHex(SmCrypto.sm3(utf8.encode('abc'))),
          '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0');
    });

    test('SM3("")', () {
      expect(_toHex(SmCrypto.sm3(const [])),
          '1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b');
    });

    test('SM3("abcd"*16)（多分组长消息）', () {
      expect(_toHex(SmCrypto.sm3(utf8.encode('abcd' * 16))),
          'debe9ff92275b8a138604889c18e5a4d6fdb70e5387e5765293dcba39c0c5732');
    });
  });

  group('SM4（GB/T 32907-2016 标准向量）', () {
    // 标准附录 A.1：key = plaintext = 0123456789abcdeffedcba9876543210
    final key = _hex('0123456789abcdeffedcba9876543210');
    final plain = _hex('0123456789abcdeffedcba9876543210');
    const cipherHex = '681edf34d206965e86b3e94f536e4246';

    test('单分组加密', () {
      expect(_toHex(SmCrypto.sm4EncryptBlock(key, plain)), cipherHex);
    });

    test('单分组解密往返', () {
      final enc = SmCrypto.sm4EncryptBlock(key, plain);
      expect(_toHex(SmCrypto.sm4DecryptBlock(key, enc)), _toHex(plain));
    });

    test('CBC 加密往返（含 PKCS#7 填充）', () {
      final iv = Uint8List.fromList(List.generate(16, (i) => i));
      const msg = '白姬音乐备份加密测试 SM4-CBC payload 2026';
      final enc = SmCrypto.sm4CbcEncrypt(
          key, iv, Uint8List.fromList(utf8.encode(msg)));
      // 明文 50 字节（10 汉字 ×3 + 20 ASCII）→ 补 14 字节到 64
      expect(enc.length, 64);
      expect(utf8.decode(SmCrypto.sm4CbcDecrypt(key, iv, enc)), msg);
    });

    test('CBC：明文恰为整分组时补满一组', () {
      final iv = Uint8List(16);
      final msg = Uint8List(16); // 全零 16 字节
      final enc = SmCrypto.sm4CbcEncrypt(key, iv, msg);
      expect(enc.length, 32);
      expect(_toHex(SmCrypto.sm4CbcDecrypt(key, iv, enc)), _toHex(msg));
    });

    test('CBC：不同 IV 必然不同密文', () {
      final iv1 = Uint8List(16);
      final iv2 = Uint8List.fromList(List.generate(16, (i) => 0xFF));
      final msg = Uint8List.fromList(utf8.encode('hello sm4'));
      final e1 = SmCrypto.sm4CbcEncrypt(key, iv1, msg);
      final e2 = SmCrypto.sm4CbcEncrypt(key, iv2, msg);
      expect(_toHex(e1) == _toHex(e2), false);
    });

    test('CBC：篡改密文 → PKCS#7 校验失败', () {
      final iv = Uint8List(16);
      final msg = Uint8List.fromList(utf8.encode('tamper test'));
      final enc = SmCrypto.sm4CbcEncrypt(key, iv, msg);
      enc[0] ^= 0xFF;
      expect(() => SmCrypto.sm4CbcDecrypt(key, iv, enc), throwsFormatException);
    });
  });

  group('SM2（GM/T 0003 曲线与加解密）', () {
    test('d=1 时公钥即基点 G（曲线参数自洽）', () {
      final g = SmCrypto.publicKeyFromPrivate(_hex('01'.padLeft(64, '0')));
      expect(
          _toHex(g),
          '32c4ae2c1f1981195f9904466a39c9948fe30bbff2660be1715a4589334c74c7'
          'bc3736a2f4f6779c59bdcee36b692153d0a9877cc62a474002df32e52139f0a0');
    });

    test('gmssl 交叉验证：解 gmssl 加密的密文（C1||C3||C2）', () {
      // 由 Python gmssl（mode=1，GM/T 0003.5-2012 格式）生成
      const sk =
          '1d7d6b95c2f29b2fe1112aef1e64124de471646ce6455db1233628e8c16ba751';
      const msg = '000102030405060708090a0b0c0d0e0f';
      const enc =
          'e84c084727775264783600083d0cc0c7772addc56096b6aad826e29d3767e396'
          'b24219091a9c5d5dfc6497f62ce3fb0a1f0aa7aa7304687c9a0444b1889ebffd'
          '9e67e3477f1f242d6fbd018a75c7f2e4629dcf96a1f660642537ab5481d94ab5'
          '4d64f8a76bc73af83932f76c8caa42eb';
      final back = SmCrypto.sm2Decrypt(_hex(sk), _hex(enc));
      expect(_toHex(back), msg);
    });

    test('gmssl 交叉验证：另一把密钥、19 字节消息', () {
      const sk =
          '8be48e09d8dff6a1260444bd5b3443cefffd4abd9eed36f019663af209d67d18';
      const enc =
          '2f28712aa788010a970eb9efbc075fa7c7832b58823b829f8279338b2b76ddef'
          'ba288b4eb1db142f81e6746ab55967bf19a9cdea86b2d08a8ddc0b2ca10d1345'
          'b8efd64cc2940c170fa83ad86ae9f4c51e45d2e38356074154fb120abb17960f'
          '19f5067efe81c5bd24b41e98cd5a2a38d1ffa7';
      final back = SmCrypto.sm2Decrypt(_hex(sk), _hex(enc));
      expect(utf8.decode(back), 'baiji-music backup!');
    });

    test('加密往返（16 字节会话密钥）', () {
      final kp = SmCrypto.generateKeyPair();
      final sk = Uint8List.fromList(List.generate(16, (i) => 0x11 * i));
      final enc = SmCrypto.sm2Encrypt(kp.publicKey, sk);
      expect(enc.length, 64 + 32 + 16);
      expect(_toHex(SmCrypto.sm2Decrypt(kp.privateKey, enc)), _toHex(sk));
    });

    test('加密往返（长消息 300 字节）', () {
      final kp = SmCrypto.generateKeyPair();
      final msg = Uint8List.fromList(List.generate(300, (i) => (i * 7 + 3) & 0xFF));
      final enc = SmCrypto.sm2Encrypt(kp.publicKey, msg);
      expect(_toHex(SmCrypto.sm2Decrypt(kp.privateKey, enc)), _toHex(msg));
    });

    test('错误私钥 → C3 校验失败', () {
      final kp = SmCrypto.generateKeyPair();
      final wrong = SmCrypto.generateKeyPair();
      final msg = Uint8List.fromList(utf8.encode('secret key'));
      final enc = SmCrypto.sm2Encrypt(kp.publicKey, msg);
      expect(() => SmCrypto.sm2Decrypt(wrong.privateKey, enc),
          throwsFormatException);
    });

    test('篡改 C1 → 结构/校验失败', () {
      final kp = SmCrypto.generateKeyPair();
      final msg = Uint8List.fromList(utf8.encode('secret key'));
      final enc = SmCrypto.sm2Encrypt(kp.publicKey, msg);
      enc[10] ^= 0x01;
      expect(() => SmCrypto.sm2Decrypt(kp.privateKey, enc), throwsA(anything));
    });

    test('公钥推导：d·G 与内置公钥一致', () {
      final derived =
          SmCrypto.publicKeyFromPrivate(_hex(SmCrypto.sm2PrivateKeyHex));
      expect(_toHex(derived), SmCrypto.sm2PublicKeyHex);
    });

    test('内置密钥对可完成信封往返', () {
      final sk = Uint8List.fromList(List.generate(16, (i) => 0xAB));
      final enc = SmCrypto.sm2Encrypt(_hex(SmCrypto.sm2PublicKeyHex), sk);
      final back = SmCrypto.sm2Decrypt(_hex(SmCrypto.sm2PrivateKeyHex), enc);
      expect(_toHex(back), _toHex(sk));
    });

    test('非曲线点公钥 → 拒绝', () {
      final bad = Uint8List(64)..[0] = 0x01; // 几乎必然不在曲线上
      expect(() => SmCrypto.sm2Encrypt(bad, Uint8List(4)),
          throwsFormatException);
    });
  });
}
