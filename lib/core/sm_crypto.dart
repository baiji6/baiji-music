/// 国密算法（SM2/SM3/SM4）纯 Dart 实现，用于备份文件加密（v2.3.0-fix3）。
///
/// 标准依据：
/// - SM2：GM/T 0003.2-2012（椭圆曲线参数）/ GM/T 0003.5-2012（加密）
/// - SM3：GM/T 0004-2012（复用 pointycastle 的 `SM3Digest`）
/// - SM4：GB/T 32907-2016（分组密码，S 盒 / CK / FK 均为标准固定值）
///
/// 实现要点：
/// - SM4 为 32 轮非平衡 Feistel，分组 16 字节、密钥 16 字节；
///   S 盒表逐字取自国家密码管理局标准正文（经 GB/T 32907 附录测试
///   向量验证：key=plaintext=0123..3210 → 681edf34d206965e86b3e94f536e4246）。
/// - SM2 加密输出 `C = C1 || C3 || C2`（GM/T 0003.5-2012 5.1 节），
///   C1 为 64 字节未压缩点（x||y，无 0x04 前缀），C3 = SM3(x2||M||y2)。
/// - SM2 密钥对由 [Sm2KeyPair] 持有；导入端（解密）只需私钥 d，
///   导出端（加密）只需公钥 P。
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/digests/sm3.dart';

/// SM2/SM3/SM4 国密算法集合。
abstract final class SmCrypto {
  // ==================== SM4 ====================

  /// SM4 分组长度（字节）。
  static const int sm4BlockSize = 16;

  /// SM4 密钥长度（字节）。
  static const int sm4KeySize = 16;

  /// S 盒（GB/T 32907-2016，国家密码管理局标准正文表格）。
  static const List<int> _sbox = [
    0xd6, 0x90, 0xe9, 0xfe, 0xcc, 0xe1, 0x3d, 0xb7, 0x16, 0xb6, 0x14, 0xc2,
    0x28, 0xfb, 0x2c, 0x05, 0x2b, 0x67, 0x9a, 0x76, 0x2a, 0xbe, 0x04, 0xc3,
    0xaa, 0x44, 0x13, 0x26, 0x49, 0x86, 0x06, 0x99, 0x9c, 0x42, 0x50, 0xf4,
    0x91, 0xef, 0x98, 0x7a, 0x33, 0x54, 0x0b, 0x43, 0xed, 0xcf, 0xac, 0x62,
    0xe4, 0xb3, 0x1c, 0xa9, 0xc9, 0x08, 0xe8, 0x95, 0x80, 0xdf, 0x94, 0xfa,
    0x75, 0x8f, 0x3f, 0xa6, 0x47, 0x07, 0xa7, 0xfc, 0xf3, 0x73, 0x17, 0xba,
    0x83, 0x59, 0x3c, 0x19, 0xe6, 0x85, 0x4f, 0xa8, 0x68, 0x6b, 0x81, 0xb2,
    0x71, 0x64, 0xda, 0x8b, 0xf8, 0xeb, 0x0f, 0x4b, 0x70, 0x56, 0x9d, 0x35,
    0x1e, 0x24, 0x0e, 0x5e, 0x63, 0x58, 0xd1, 0xa2, 0x25, 0x22, 0x7c, 0x3b,
    0x01, 0x21, 0x78, 0x87, 0xd4, 0x00, 0x46, 0x57, 0x9f, 0xd3, 0x27, 0x52,
    0x4c, 0x36, 0x02, 0xe7, 0xa0, 0xc4, 0xc8, 0x9e, 0xea, 0xbf, 0x8a, 0xd2,
    0x40, 0xc7, 0x38, 0xb5, 0xa3, 0xf7, 0xf2, 0xce, 0xf9, 0x61, 0x15, 0xa1,
    0xe0, 0xae, 0x5d, 0xa4, 0x9b, 0x34, 0x1a, 0x55, 0xad, 0x93, 0x32, 0x30,
    0xf5, 0x8c, 0xb1, 0xe3, 0x1d, 0xf6, 0xe2, 0x2e, 0x82, 0x66, 0xca, 0x60,
    0xc0, 0x29, 0x23, 0xab, 0x0d, 0x53, 0x4e, 0x6f, 0xd5, 0xdb, 0x37, 0x45,
    0xde, 0xfd, 0x8e, 0x2f, 0x03, 0xff, 0x6a, 0x72, 0x6d, 0x6c, 0x5b, 0x51,
    0x8d, 0x1b, 0xaf, 0x92, 0xbb, 0xdd, 0xbc, 0x7f, 0x11, 0xd9, 0x5c, 0x41,
    0x1f, 0x10, 0x5a, 0xd8, 0x0a, 0xc1, 0x31, 0x88, 0xa5, 0xcd, 0x7b, 0xbd,
    0x2d, 0x74, 0xd0, 0x12, 0xb8, 0xe5, 0xb4, 0xb0, 0x89, 0x69, 0x97, 0x4a,
    0x0c, 0x96, 0x77, 0x7e, 0x65, 0xb9, 0xf1, 0x09, 0xc5, 0x6e, 0xc6, 0x84,
    0x18, 0xf0, 0x7d, 0xec, 0x3a, 0xdc, 0x4d, 0x20, 0x79, 0xee, 0x5f, 0x3e,
    0xd7, 0xcb, 0x39, 0x48,
  ];

  /// 系统参数 FK（GB/T 32907-2016）。
  static const List<int> _fk = [0xa3b1bac6, 0x56aa3350, 0x677d9197, 0xb27022dc];

  /// 轮常量 CK（GB/T 32907-2016，32 个）。
  static const List<int> _ck = [
    0x00070e15, 0x1c232a31, 0x383f464d, 0x545b6269, //
    0x70777e85, 0x8c939aa1, 0xa8afb6bd, 0xc4cbd2d9,
    0xe0e7eef5, 0xfc030a11, 0x181f262d, 0x343b4249,
    0x50575e65, 0x6c737a81, 0x888f969d, 0xa4abb2b9,
    0xc0c7ced5, 0xdce3eaf1, 0xf8ff060d, 0x141b2229,
    0x30373e45, 0x4c535a61, 0x686f767d, 0x848b9299,
    0xa0a7aeb5, 0xbcc3cad1, 0xd8dfe6ed, 0xf4fb0209,
    0x10171e25, 0x2c333a41, 0x484f565d, 0x646b7279,
  ];

  static const int _mask32 = 0xFFFFFFFF;

  /// 32 位循环左移。
  static int _rotl(int x, int n) =>
      ((x << n) | ((x & _mask32) >> (32 - n))) & _mask32;

  /// 非线性变换 τ：4 字节并行过 S 盒。
  static int _tau(int a) {
    return (_sbox[(a >> 24) & 0xFF] << 24) |
        (_sbox[(a >> 16) & 0xFF] << 16) |
        (_sbox[(a >> 8) & 0xFF] << 8) |
        _sbox[a & 0xFF];
  }

  /// 轮函数线性变换 L。
  static int _l(int b) =>
      b ^ _rotl(b, 2) ^ _rotl(b, 10) ^ _rotl(b, 18) ^ _rotl(b, 24);

  /// 密钥扩展线性变换 L'。
  static int _lPrime(int b) => b ^ _rotl(b, 13) ^ _rotl(b, 23);

  /// SM4 轮密钥扩展（32 个 32 位字）。
  static List<int> _expandKey(Uint8List key) {
    final mk = <int>[];
    for (var i = 0; i < 4; i++) {
      mk.add(((key[4 * i] << 24) |
              (key[4 * i + 1] << 16) |
              (key[4 * i + 2] << 8) |
              key[4 * i + 3]) &
          _mask32);
    }
    final k = List<int>.filled(36, 0);
    for (var i = 0; i < 4; i++) {
      k[i] = mk[i] ^ _fk[i];
    }
    for (var i = 0; i < 32; i++) {
      final t = k[i + 1] ^ k[i + 2] ^ k[i + 3] ^ _ck[i];
      k[i + 4] = k[i] ^ _lPrime(_tau(t));
    }
    return k.sublist(4, 36);
  }

  /// SM4 单分组加/解密（rk 为轮密钥；解密传逆序轮密钥）。
  static void _cryptBlock(
      List<int> x, List<int> rk, Uint8List out, int outOff) {
    for (var i = 0; i < 32; i++) {
      final t = x[i + 1] ^ x[i + 2] ^ x[i + 3] ^ rk[i];
      x[i + 4] = x[i] ^ _l(_tau(t));
    }
    for (var i = 0; i < 4; i++) {
      final v = x[35 - i];
      out[outOff + 4 * i] = (v >> 24) & 0xFF;
      out[outOff + 4 * i + 1] = (v >> 16) & 0xFF;
      out[outOff + 4 * i + 2] = (v >> 8) & 0xFF;
      out[outOff + 4 * i + 3] = v & 0xFF;
    }
  }

  static List<int> _blockWords(Uint8List b, int off) => [
        ((b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]) &
            _mask32,
        ((b[off + 4] << 24) |
                (b[off + 5] << 16) |
                (b[off + 6] << 8) |
                b[off + 7]) &
            _mask32,
        ((b[off + 8] << 24) |
                (b[off + 9] << 16) |
                (b[off + 10] << 8) |
                b[off + 11]) &
            _mask32,
        ((b[off + 12] << 24) |
                (b[off + 13] << 16) |
                (b[off + 14] << 8) |
                b[off + 15]) &
            _mask32,
      ];

  /// SM4-ECB 单分组加密（测试与调试用；正式备份走 [sm4CbcEncrypt]）。
  static Uint8List sm4EncryptBlock(Uint8List key, Uint8List block) {
    assert(key.length == sm4KeySize);
    assert(block.length == sm4BlockSize);
    final rk = _expandKey(key);
    final x = List<int>.filled(36, 0)..setRange(0, 4, _blockWords(block, 0));
    final out = Uint8List(sm4BlockSize);
    _cryptBlock(x, rk, out, 0);
    return out;
  }

  /// SM4-ECB 单分组解密。
  static Uint8List sm4DecryptBlock(Uint8List key, Uint8List block) {
    assert(key.length == sm4KeySize);
    assert(block.length == sm4BlockSize);
    final rk = _expandKey(key).reversed.toList();
    final x = List<int>.filled(36, 0)..setRange(0, 4, _blockWords(block, 0));
    final out = Uint8List(sm4BlockSize);
    _cryptBlock(x, rk, out, 0);
    return out;
  }

  /// PKCS#7 填充（分组 16 字节）。
  static Uint8List _pkcs7Pad(Uint8List data) {
    final pad = sm4BlockSize - (data.length % sm4BlockSize);
    final out = Uint8List(data.length + pad);
    out.setRange(0, data.length, data);
    for (var i = 0; i < pad; i++) {
      out[data.length + i] = pad;
    }
    return out;
  }

  /// 去掉 PKCS#7 填充并校验合法性。
  static Uint8List _pkcs7Unpad(Uint8List data) {
    if (data.isEmpty || data.length % sm4BlockSize != 0) {
      throw const FormatException('SM4 密文长度不合法');
    }
    final pad = data.last;
    if (pad < 1 || pad > sm4BlockSize || pad > data.length) {
      throw const FormatException('SM4 PKCS#7 填充不合法');
    }
    for (var i = data.length - pad; i < data.length; i++) {
      if (data[i] != pad) {
        throw const FormatException('SM4 PKCS#7 填充不合法');
      }
    }
    return Uint8List.sublistView(data, 0, data.length - pad);
  }

  /// SM4-CBC 加密（自动 PKCS#7 填充）。[key] 16 字节，[iv] 16 字节。
  static Uint8List sm4CbcEncrypt(
      Uint8List key, Uint8List iv, Uint8List plain) {
    if (key.length != sm4KeySize) {
      throw ArgumentError('SM4 密钥必须为 16 字节');
    }
    if (iv.length != sm4BlockSize) {
      throw ArgumentError('SM4 IV 必须为 16 字节');
    }
    final rk = _expandKey(key);
    final padded = _pkcs7Pad(plain);
    final out = Uint8List(padded.length);
    var prev = Uint8List.fromList(iv);
    final block = Uint8List(sm4BlockSize);
    for (var off = 0; off < padded.length; off += sm4BlockSize) {
      for (var i = 0; i < sm4BlockSize; i++) {
        block[i] = padded[off + i] ^ prev[i];
      }
      final x = List<int>.filled(36, 0)
        ..setRange(0, 4, _blockWords(block, 0));
      _cryptBlock(x, rk, out, off);
      prev = Uint8List.sublistView(out, off, off + sm4BlockSize);
    }
    return out;
  }

  /// SM4-CBC 解密（自动去除 PKCS#7 填充）。
  static Uint8List sm4CbcDecrypt(
      Uint8List key, Uint8List iv, Uint8List cipher) {
    if (key.length != sm4KeySize) {
      throw ArgumentError('SM4 密钥必须为 16 字节');
    }
    if (iv.length != sm4BlockSize) {
      throw ArgumentError('SM4 IV 必须为 16 字节');
    }
    if (cipher.length % sm4BlockSize != 0) {
      throw const FormatException('SM4 密文长度不合法');
    }
    final rk = _expandKey(key).reversed.toList();
    final out = Uint8List(cipher.length);
    var prev = Uint8List.fromList(iv);
    final block = Uint8List(sm4BlockSize);
    for (var off = 0; off < cipher.length; off += sm4BlockSize) {
      final x = List<int>.filled(36, 0)
        ..setRange(0, 4, _blockWords(cipher, off));
      _cryptBlock(x, rk, block, 0);
      for (var i = 0; i < sm4BlockSize; i++) {
        out[off + i] = block[i] ^ prev[i];
      }
      prev = Uint8List.sublistView(cipher, off, off + sm4BlockSize);
    }
    return _pkcs7Unpad(out);
  }

  // ==================== SM3（复用 pointycastle） ====================

  /// SM3 摘要（GM/T 0004-2012）。
  static Uint8List sm3(List<int> data) {
    final d = SM3Digest();
    final bytes = Uint8List.fromList(data);
    d.update(bytes, 0, bytes.length);
    final out = Uint8List(32);
    d.doFinal(out, 0);
    return out;
  }

  // ==================== SM2（GM/T 0003.2-2012 / 0003.5-2012） ====================

  /// 曲线参数 p。
  static final BigInt _p = BigInt.parse(
      'FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF',
      radix: 16);

  /// 曲线参数 a = p - 3。
  static final BigInt _a = _p - BigInt.from(3);

  /// 曲线参数 b。
  static final BigInt _b = BigInt.parse(
      '28E9FA9E9D9F5E344D5A9E4BCF6509A7F39789F515AB8F92DDBCBD414D940E93',
      radix: 16);

  /// 基点 G 的阶 n。
  static final BigInt _n = BigInt.parse(
      'FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFF7203DF6B21C6052B53BBF40939D54123',
      radix: 16);

  /// 基点 G 的 x 坐标。
  static final BigInt _gx = BigInt.parse(
      '32C4AE2C1F1981195F9904466A39C9948FE30BBFF2660BE1715A4589334C74C7',
      radix: 16);

  /// 基点 G 的 y 坐标。
  static final BigInt _gy = BigInt.parse(
      'BC3736A2F4F6779C59BDCEE36B692153D0A9877CC62A474002DF32E52139F0A0',
      radix: 16);

  /// SM2 公钥（64 字节 x||y）。
  ///
  /// 与 [sm2PrivateKeyHex] 配对，专用于备份信封；由 [generateKeyPair]
  /// 生成后固定（2026-10-18），并经 gmssl 交叉验证（见测试）。
  static const String sm2PublicKeyHex =
      '08b5e5a29fcc617cca3a7e40c673dcc3ea713faf612d6f704a82ba78c7e430c5'
      '51ef045de3eae17ed6903853234835e42811c911e39ce29ee78c111f8ddd8a18';

  /// SM2 私钥（32 字节 d）。
  static const String sm2PrivateKeyHex =
      '1d7d6b95c2f29b2fe1112aef1e64124de471646ce6455db1233628e8c16ba751';

  static Uint8List _pointBytes(BigInt x, BigInt y) {
    final out = Uint8List(64);
    _bigTo32(x, out, 0);
    _bigTo32(y, out, 32);
    return out;
  }

  static void _bigTo32(BigInt v, Uint8List out, int off) {
    final hex = v.toRadixString(16).padLeft(64, '0');
    for (var i = 0; i < 32; i++) {
      out[off + i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
    }
  }

  /// 解析 64 字节点 → (x, y)；不在曲线上抛 [FormatException]。
  static (BigInt, BigInt) _parsePoint(Uint8List bytes) {
    if (bytes.length != 64) {
      throw const FormatException('SM2 点编码长度必须为 64 字节');
    }
    final x = _bytesToBig(bytes, 0);
    final y = _bytesToBig(bytes, 32);
    if (x >= _p || y >= _p) {
      throw const FormatException('SM2 点坐标越界');
    }
    final lhs = (y * y) % _p;
    final rhs = (x * x * x + _a * x + _b) % _p;
    if (lhs != rhs) {
      throw const FormatException('SM2 点不在曲线上');
    }
    return (x, y);
  }

  static BigInt _bytesToBig(Uint8List b, int off) {
    var v = BigInt.zero;
    for (var i = 0; i < 32; i++) {
      v = (v << 8) | BigInt.from(b[off + i]);
    }
    return v;
  }

  /// 点加（仿射坐标）。
  static (BigInt, BigInt)? _add((BigInt, BigInt)? p1, (BigInt, BigInt)? p2) {
    if (p1 == null) return p2;
    if (p2 == null) return p1;
    final (x1, y1) = p1;
    final (x2, y2) = p2;
    if (x1 == x2) {
      if ((y1 + y2) % _p == BigInt.zero) return null; // 互为逆元
      return _double(p1);
    }
    final lambda = ((y2 - y1) * (x2 - x1).modInverse(_p)) % _p;
    final x3 = (lambda * lambda - x1 - x2) % _p;
    final y3 = (lambda * (x1 - x3) - y1) % _p;
    return (x3 % _p, y3 % _p);
  }

  /// 点倍（仿射坐标）。
  static (BigInt, BigInt) _double((BigInt, BigInt) p) {
    final (x1, y1) = p;
    if (y1 % _p == BigInt.zero) {
      throw StateError('SM2 点倍遇到 2-挠点');
    }
    final lambda = ((BigInt.from(3) * x1 * x1 + _a) *
            (BigInt.from(2) * y1).modInverse(_p)) %
        _p;
    final x3 = (lambda * lambda - BigInt.from(2) * x1) % _p;
    final y3 = (lambda * (x1 - x3) - y1) % _p;
    return (x3 % _p, y3 % _p);
  }

  /// 标量乘（double-and-add；备份操作为一次性低频，性能足够）。
  static (BigInt, BigInt)? _mul(BigInt k, (BigInt, BigInt) p) {
    (BigInt, BigInt)? acc;
    var addend = p;
    var scalar = k;
    while (scalar > BigInt.zero) {
      if (scalar.isOdd) acc = _add(acc, addend);
      addend = _double(addend);
      scalar >>= 1;
    }
    return acc;
  }

  /// KDF（GM/T 0003.5-2012 5.4.3）：SM3(Z||ct) 迭代拼接。
  static Uint8List _kdf(Uint8List z, int klen) {
    final out = <int>[];
    var ct = 1;
    while (out.length < klen) {
      final input = <int>[...z, ..._ctBytes(ct)];
      out.addAll(sm3(input));
      ct++;
    }
    return Uint8List.fromList(out.sublist(0, klen));
  }

  static List<int> _ctBytes(int ct) => [
        (ct >> 24) & 0xFF,
        (ct >> 16) & 0xFF,
        (ct >> 8) & 0xFF,
        ct & 0xFF,
      ];

  /// SM2 加密（GM/T 0003.5-2012）：[publicKey] 为 64 字节公钥，
  /// 输出 `C1(64) || C3(32) || C2(len(M))`。
  static Uint8List sm2Encrypt(Uint8List publicKey, Uint8List message) {
    if (publicKey.length != 64) {
      throw ArgumentError('SM2 公钥必须为 64 字节');
    }
    final p = _parsePoint(publicKey);
    final rng = Random.secure();
    BigInt k;
    while (true) {
      final bytes = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        bytes[i] = rng.nextInt(256);
      }
      final candidate = _bytesToBig(bytes, 0);
      if (candidate >= BigInt.one && candidate < _n) {
        k = candidate;
        break;
      }
    }
    final c1 = _mul(k, (_gx, _gy))!;
    final s = _mul(k, p)!;
    final (x2, y2) = s;
    final z = Uint8List(64)
      ..setRange(0, 32, _big32Bytes(x2))
      ..setRange(32, 64, _big32Bytes(y2));
    final t = _kdf(z, message.length);
    var allZero = true;
    for (final b in t) {
      if (b != 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) {
      throw StateError('SM2 KDF 输出全零，请重试');
    }
    final c2 = Uint8List(message.length);
    for (var i = 0; i < message.length; i++) {
      c2[i] = message[i] ^ t[i];
    }
    final c3 = sm3(<int>[..._big32Bytes(x2), ...message, ..._big32Bytes(y2)]);
    final out = Uint8List(64 + 32 + message.length);
    _bigTo32(c1.$1, out, 0);
    _bigTo32(c1.$2, out, 32);
    out.setRange(64, 96, c3);
    out.setRange(96, out.length, c2);
    return out;
  }

  static Uint8List _big32Bytes(BigInt v) {
    final out = Uint8List(32);
    _bigTo32(v, out, 0);
    return out;
  }

  /// SM2 解密：[privateKey] 为 32 字节私钥 d，[cipher] 为
  /// `C1(64) || C3(32) || C2`。校验 C3 不一致或结构非法时抛
  /// [FormatException]。
  static Uint8List sm2Decrypt(Uint8List privateKey, Uint8List cipher) {
    if (privateKey.length != 32) {
      throw ArgumentError('SM2 私钥必须为 32 字节');
    }
    if (cipher.length < 64 + 32) {
      throw const FormatException('SM2 密文长度不合法');
    }
    final d = _bytesToBig(privateKey, 0);
    if (d >= _n) {
      throw const FormatException('SM2 私钥越界');
    }
    final c1 = Uint8List.sublistView(cipher, 0, 64);
    final c3 = Uint8List.sublistView(cipher, 64, 96);
    final c2 = Uint8List.sublistView(cipher, 96);
    final point = _parsePoint(c1);
    final s = _mul(d, point)!;
    final (x2, y2) = s;
    final z = Uint8List(64)
      ..setRange(0, 32, _big32Bytes(x2))
      ..setRange(32, 64, _big32Bytes(y2));
    final t = _kdf(z, c2.length);
    final m = Uint8List(c2.length);
    for (var i = 0; i < c2.length; i++) {
      m[i] = c2[i] ^ t[i];
    }
    final expect = sm3(<int>[..._big32Bytes(x2), ...m, ..._big32Bytes(y2)]);
    var same = true;
    for (var i = 0; i < 32; i++) {
      if (expect[i] != c3[i]) {
        same = false;
        break;
      }
    }
    if (!same) {
      throw const FormatException('SM2 密文校验失败（C3 不匹配）');
    }
    return m;
  }

  /// 生成 SM2 密钥对（d ∈ [1, n-1]，P = d·G）。
  static Sm2KeyPair generateKeyPair([Random? rng]) {
    final r = rng ?? Random.secure();
    BigInt d;
    while (true) {
      final bytes = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        bytes[i] = r.nextInt(256);
      }
      final candidate = _bytesToBig(bytes, 0);
      if (candidate >= BigInt.one && candidate < _n) {
        d = candidate;
        break;
      }
    }
    final p = _mul(d, (_gx, _gy))!;
    return Sm2KeyPair(
      privateKey: _big32Bytes(d),
      publicKey: _pointBytes(p.$1, p.$2),
    );
  }

  /// 从私钥推导公钥（导入端核对用）。
  static Uint8List publicKeyFromPrivate(Uint8List privateKey) {
    final d = _bytesToBig(privateKey, 0);
    if (d >= _n || d < BigInt.one) {
      throw const FormatException('SM2 私钥越界');
    }
    final p = _mul(d, (_gx, _gy))!;
    return _pointBytes(p.$1, p.$2);
  }
}

/// SM2 密钥对。
class Sm2KeyPair {
  const Sm2KeyPair({required this.privateKey, required this.publicKey});

  /// 私钥 d（32 字节）。
  final Uint8List privateKey;

  /// 公钥 P（64 字节 x||y）。
  final Uint8List publicKey;
}
