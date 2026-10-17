/// 备份文件加密（v2.3.0-fix1）：Base64 + RC4 + RSA 信封加密。
///
/// 布局：
/// ```
/// BAIJI1.<base64( magic(4) | rsaLen(2, BE) | rsaEncKey | rc4Data )>
/// ```
/// - 每次导出生成随机 16 字节 RC4 密钥；
/// - 备份 JSON 用 RC4 加密（备份含登录态与密钥库，绝不能明文落盘）；
/// - RC4 密钥用内置 RSA-1024 公钥 PKCS#1 v1.5 加密（信封），导入端用
///   内置私钥还原——密钥不进文件、不进剪贴板，文件本身可安全分享；
/// - 最终整体 Base64，首行带 `BAIJI1.` 前缀便于识别与版本演进。
///
/// RC4 与 RSA 均为纯 Dart 实现（RSA 的 BigInt 模幂与 QQ 登录协议里的
/// rsaPkcs1Encrypt 同源思路），不引入额外依赖。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'app_logger.dart';

class BackupCrypto {
  BackupCrypto._();

  /// 导出文件头（版本演进用：结构变化时递增尾巴数字）。
  static const String prefix = 'BAIJI1.';

  /// 内置 RSA 密钥对（1024 位，专用于备份）。
  /// 公钥加密 RC4 会话密钥；私钥只在导入端使用。
  static const String _rsaNHex =
      'CA905AFE65372FA939418AAE2FB7DF158DB04C50597E241BB8E4F69179E00155'
      '9B295087730300F57A23D0528B9090DEAE8848398E2D16E44703005D1B0E4C50'
      'CA3BB9744F0FA5BF02F3080AD89B5962B08082EF0608FB23A1306C7263E88A9A'
      'AD948577F292C95D470EA3C47394C41A8574827C503031662586E11FD549CBBF';
  static const int _rsaE = 65537;
  static const String _rsaDHex =
      '44DC54029D57E85CE7B8EF330DC7BD0FAFAE1A134A89062F62687BA5B2BFC2D4'
      '5E3DEA415188D8DF9A58E86DD7421AED88798DCBFB183AEAF974FCBFA9FDEF55'
      '0084184F24F8E9C285BFBC25DF7657989F3ABEFDBBE0EC04BE160C1C4C0CC0DF'
      '12886F787358465383EBE15D4CBF7A60C1AA112C569A9830034E483250A84C51';

  static final BigInt _n = _hexToBig(_rsaNHex);
  static final BigInt _d = _hexToBig(_rsaDHex);
  static final int _k = (_rsaNHex.length + 1) ~/ 2; // 128 字节

  static final Random _rng = Random.secure();

  // ==================== 导出 ====================

  /// 加密备份明文（JSON 字符串）→ 带前缀的 Base64 文本。
  static String encrypt(String plainJson) {
    // 1) 随机 RC4 会话密钥（16 字节）
    final rc4Key = Uint8List.fromList(
        List.generate(16, (_) => _rng.nextInt(256)));

    // 2) RC4 加密数据
    final data = rc4(rc4Key, utf8.encode(plainJson));

    // 3) RSA 公钥加密会话密钥（PKCS#1 v1.5）
    final encKey = _rsaEncryptPkcs1(rc4Key);

    // 4) 组包 + Base64
    final out = BytesBuilder();
    out.add(const [0x42, 0x41, 0x49, 0x4A]); // 'BAIJ' magic
    out.addByte((encKey.length >> 8) & 0xFF);
    out.addByte(encKey.length & 0xFF);
    out.add(encKey);
    out.add(data);
    return prefix + base64Encode(out.takeBytes());
  }

  /// 解密（导入）：识别前缀后还原 JSON 明文。
  ///
  /// 输入不是加密格式（无前缀）时返回 null——调用方可按旧的
  /// 明文 JSON 兼容处理。
  static String? decrypt(String input) {
    final s = input.trim();
    if (!s.startsWith(prefix)) return null;
    Uint8List raw;
    try {
      raw = base64Decode(s.substring(prefix.length));
    } catch (_) {
      throw const FormatException('备份文件 Base64 解码失败');
    }
    if (raw.length < 4 + 2 + _k || raw[0] != 0x42) {
      throw const FormatException('备份文件结构不正确');
    }
    final rsaLen = (raw[4] << 8) | raw[5];
    if (rsaLen <= 0 || 4 + 2 + rsaLen >= raw.length) {
      throw const FormatException('备份文件结构不正确');
    }
    final encKey = Uint8List.sublistView(raw, 6, 6 + rsaLen);
    final data = Uint8List.sublistView(raw, 6 + rsaLen);

    // RSA 私钥还原会话密钥
    final rc4Key = _rsaDecryptPkcs1(encKey);
    if (rc4Key == null || rc4Key.isEmpty) {
      throw const FormatException('备份密钥还原失败');
    }

    final plain = rc4(rc4Key, data);
    return utf8.decode(plain, allowMalformed: true);
  }

  // ==================== RC4 ====================

  /// RC4（对称流密码）：加密与解密同一函数。
  static Uint8List rc4(Uint8List key, Uint8List data) {
    final s = List<int>.generate(256, (i) => i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % key.length]) & 0xFF;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
    }
    var i = 0;
    j = 0;
    final out = Uint8List(data.length);
    for (var n = 0; n < data.length; n++) {
      i = (i + 1) & 0xFF;
      j = (j + s[i]) & 0xFF;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
      out[n] = data[n] ^ s[(s[i] + s[j]) & 0xFF];
    }
    return out;
  }

  // ==================== RSA ====================

  /// RSA PKCS#1 v1.5 加密（公钥 e=65537）。
  static Uint8List _rsaEncryptPkcs1(Uint8List input) {
    if (input.length > _k - 11) {
      throw ArgumentError('RSA 明文过长');
    }
    final em = Uint8List(_k);
    em[0] = 0x00;
    em[1] = 0x02;
    for (var i = 2; i < _k - input.length - 1; i++) {
      var b = 0;
      while (b == 0) {
        b = _rng.nextInt(256);
      }
      em[i] = b;
    }
    em[_k - input.length - 1] = 0x00;
    em.setRange(_k - input.length, _k, input);
    return _rawModPow(em, _n, BigInt.from(_rsaE), _k);
  }

  /// RSA PKCS#1 v1.5 解密（私钥 d）。
  static Uint8List? _rsaDecryptPkcs1(Uint8List input) {
    if (input.length != _k) return null;
    final em = _rawModPow(input, _n, _d, _k);
    // em = 0x00 0x02 PS 0x00 message
    if (em.length < 11 || em[0] != 0x00 || em[1] != 0x02) {
      AppLog.w('BackupCrypto', 'RSA 解密后填充格式不正确');
      return null;
    }
    final sep = em.indexOf(0x00, 2);
    if (sep < 0) return null;
    return Uint8List.sublistView(em, sep + 1);
  }

  /// 大端字节序的模幂（RSA 核心）。
  static Uint8List _rawModPow(Uint8List m, BigInt modulus, BigInt exp, int k) {
    var b = BigInt.zero;
    for (final byte in m) {
      b = (b << 8) | BigInt.from(byte);
    }
    var r = BigInt.one;
    var base = b % modulus;
    while (exp > BigInt.zero) {
      if (exp.isOdd) {
        r = (r * base) % modulus;
      }
      base = (base * base) % modulus;
      exp = exp >> 1;
    }
    final hex = r.toRadixString(16);
    final padded = hex.length.isOdd ? '0$hex' : hex;
    final raw = Uint8List.fromList([
      for (var i = 0; i < padded.length; i += 2)
        int.parse(padded.substring(i, i + 2), radix: 16),
    ]);
    final out = Uint8List(k);
    out.setRange(k - raw.length, k, raw);
    return out;
  }

  static BigInt _hexToBig(String hex) {
    var v = BigInt.zero;
    for (var i = 0; i < hex.length; i++) {
      v = (v << 4) | BigInt.from(int.parse(hex[i], radix: 16));
    }
    return v;
  }
}
