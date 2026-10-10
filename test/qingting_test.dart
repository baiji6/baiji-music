import 'dart:convert';
import 'dart:typed_data';

import 'package:baiji_music/decrypt/aes_ctr.dart';
import 'package:baiji_music/decrypt/qingting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

void main() {
  group('makeDecipherIv（对齐 Rust nonce.rs 的 test_make_nonce_key）', () {
    test('".p!MTIzNDU2.qta" → base64("123456")', () {
      final iv = makeDecipherIv('.p!MTIzNDU2.qta');
      expect(iv.length, 16);
      expect(
          iv.sublist(0, 8),
          Uint8List.fromList([
            0x4c, 0x43, 0x18, 0xd9, 0x98, 0xe6, 0xef, 0x57 //
          ]));
      expect(iv.sublist(8, 16), Uint8List(8), reason: '后 8 字节必须是 0');
    });

    test('".p!OTg3NjU0MzIx.qta" → base64("987654321")', () {
      final iv = makeDecipherIv('.p!OTg3NjU0MzIx.qta');
      expect(
          iv.sublist(0, 8),
          Uint8List.fromList([
            0x32, 0xef, 0xa8, 0xef, 0x16, 0xc4, 0x98, 0x33 //
          ]));
    });

    test('".p~!MTIzNED_-w==.qta" → URL-safe base64("1234@\xff\xfb")', () {
      final iv = makeDecipherIv('.p~!MTIzNED_-w==.qta');
      expect(
          iv.sublist(0, 8),
          Uint8List.fromList([
            0x2e, 0x08, 0x09, 0x99, 0x62, 0x7a, 0xea, 0xac //
          ]));
    });
  });

  group('makeDecipherIv 边界', () {
    test('带目录前缀时只取文件名', () {
      final a = makeDecipherIv('/storage/emulated/0/QTMusic/.p!MTIzNDU2.qta');
      expect(
          a.sublist(0, 8),
          makeDecipherIv('.p!MTIzNDU2.qta').sublist(0, 8));
    });

    test('Windows 反斜杠路径也能正确切', () {
      final a = makeDecipherIv(r'C:\Music\.p!MTIzNDU2.qta');
      expect(
          a.sublist(0, 8),
          makeDecipherIv('.p!MTIzNDU2.qta').sublist(0, 8));
    });

    test('缺 padding 也能解', () {
      // base64("123456") = MTIzNDU2，去掉 = 后长度 7
      expect(() => makeDecipherIv('.p!MTIzNDU2'), returnsNormally);
    });

    test('没有 .p! / .p~! 前缀时报错', () {
      expect(() => makeDecipherIv('random.qta'),
          throwsA(isA<QingTingFailure>()));
    });

    test('base64 非法时报错', () {
      expect(() => makeDecipherIv('.p!!!!'), throwsA(isA<QingTingFailure>()));
    });

    test('有 @ 时只取 @ 之前的部分', () {
      // base64("1234@abc") 与 base64("1234") 应产生相同的 IV
      final withAt = makeDecipherIv('.p!${base64.encode(utf8.encode('1234@abcdef'))}.qta');
      final only = makeDecipherIv('.p!${base64.encode(utf8.encode('1234'))}.qta');
      expect(withAt, only);
    });
  });

  group('makeDeviceSecret（对齐 Rust secret.rs 的 test_secret_generation）', () {
    test('六段固定字符串的派生结果与上游一致', () {
      final key = makeDeviceSecret(
        product: 'product',
        device: 'device',
        manufacturer: 'manufacturer',
        brand: 'brand',
        board: 'board',
        model: 'model',
      );
      expect(
        key,
        Uint8List.fromList([
          0x59, 0x64, 0x91, 0x77, 0x45, 0x46, 0x75, 0x6d, //
          0x08, 0x00, 0x08, 0x0a, 0x14, 0x12, 0x11, 0x12,
        ]),
      );
    });

    test('六段之间是求和关系——交换顺序结果相同', () {
      // Rust 侧是 fold(wrapping_add)，本质是求和，所以顺序无关。
      final a = makeDeviceSecret(
          product: 'a', device: 'b', manufacturer: 'c',
          brand: 'd', board: 'e', model: 'f');
      final b = makeDeviceSecret(
          product: 'b', device: 'a', manufacturer: 'c',
          brand: 'd', board: 'e', model: 'f');
      expect(a, b);
    });

    test('改一段值会得到不同的密钥', () {
      final a = makeDeviceSecret(
          product: 'a', device: 'b', manufacturer: 'c',
          brand: 'd', board: 'e', model: 'f');
      final b = makeDeviceSecret(
          product: 'zzz', device: 'b', manufacturer: 'c',
          brand: 'd', board: 'e', model: 'f');
      expect(a, isNot(equals(b)));
    });

    test('始终返回 16 字节', () {
      final key = makeDeviceSecret(
          product: '', device: '', manufacturer: '',
          brand: '', board: '', model: '');
      expect(key.length, 16);
    });

    test('hex 输出是32 个小写字符', () {
      final key = makeDeviceSecret(
          product: 'product', device: 'device', manufacturer: 'm',
          brand: 'b', board: 'd', model: 'x');
      final hex = deviceSecretToHex(key);
      expect(hex.length, 32);
      expect(hex, hex.toLowerCase());
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(hex), isTrue);
    });
  });

  group('javaStringHashCode', () {
    test('空串为 0', () => expect(javaStringHashCode(''), 0));

    test('"a" → 97', () => expect(javaStringHashCode('a'), 97));

    test('"ab" → 97*31+98 = 3105', () {
      expect(javaStringHashCode('ab'), 97 * 31 + 98);
    });

    test('超长串不溢出（Dart 任意精度需手动截断）', () {
      final v = javaStringHashCode('a' * 200);
      expect(v, lessThanOrEqualTo(0xFFFFFFFF));
    });
  });

  group('AesCtr64BeStream', () {
    // FIPS-197 的 AES-128 测试向量
    final key = Uint8List.fromList([
      0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, //
      0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    ]);
    final iv = Uint8List.fromList([
      0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, //
      0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
    ]);

    test('第一个块 = AES-ECB(key, iv前8字节 ‖ 计数器0)', () {
      // Ctr64BE 的计数器块不是整个 IV：前 8 字节是 IV 的 nonce 段，
      // 后 8 字节是**独立的**64 位大端块偏移（从 0 起）。
      final s = ctrStreamForTest(key, iv);
      final out = Uint8List(16);
      s.processBytes(Uint8List(16), 0, 16, out, 0);

      final c0 = Uint8List(16)
        ..setRange(0, 8, iv.sublist(0, 8)); // 后 8 字节留 0
      expect(out, aesEcbForTest(key, c0));
      // 权威值来自 Python pycryptodome 独立复算
      expect(out.sublist(0, 4),
          Uint8List.fromList([0x17, 0x65, 0xb2, 0xbf]));
    });

    test('第二个块计数器 +1，只改后 8 字节', () {
      final s = ctrStreamForTest(key, iv);
      final out = Uint8List(32);
      s.processBytes(Uint8List(32), 0, 32, out, 0);

      // nonce 段固定为 IV 前 8 字节，计数器依次为 0 与 1
      final c0 = Uint8List(16)..setRange(0, 8, iv.sublist(0, 8));
      final c1 = Uint8List(16)..setRange(0, 8, iv.sublist(0, 8));
      ByteData.sublistView(c1).setUint64(8, 1, Endian.big);
      expect(out.sublist(0, 16), aesEcbForTest(key, c0));
      expect(out.sublist(16, 32), aesEcbForTest(key, c1));
      // 权威值来自 Python pycryptodome 独立复算
      expect(out.sublist(16, 20),
          Uint8List.fromList([0x76, 0x10, 0x6f, 0x17]));
    });

    test('nonce 段（前 8 字节）永不递增', () {
      // 直接检查计数器块：构造时的 IV 前 8 字节必须原样保留，
      // 只有后 8 字节在递增。
      final s = AesCtr64BeStream(_newAes(key, iv), iv);
      expect(s.counterBlockForTest.sublist(0, 8), iv.sublist(0, 8));
      expect(
        ByteData.sublistView(s.counterBlockForTest).getUint64(8, Endian.big),
        0,
        reason: '块偏移从 0 起，而不是 IV 后 8 字节的值',
      );

      for (var b = 0; b < 4; b++) {
        s.processBytes(Uint8List(16), 0, 16, Uint8List(16), 0);
        expect(s.counterBlockForTest.sublist(0, 8), iv.sublist(0, 8),
            reason: '第 $b 块之后 nonce 段被改动了');
        expect(
          ByteData.sublistView(s.counterBlockForTest).getUint64(8, Endian.big),
          b + 1,
          reason: '第 $b 块之后计数器应为 ${b + 1}',
        );
      }
    });

    test('seek 到指定块：与「从头连续解」的对应片段一致', () {
      final data = Uint8List.fromList(List<int>.generate(64, (i) => i));

      //基准：一次性解完 64 字节
      final whole = Uint8List.fromList(data);
      ctrStreamForTest(key, iv).processBytes(whole, 0, 64, whole, 0);

      // seek 到第 3 块（字节偏移 48），只解这 16 字节
      final part = Uint8List(16);
      ctrStreamForTest(key, iv)
          .seek(3)
          .processBytes(data, 48, 16, part, 0);

      expect(part, whole.sublist(48, 64));
    });

    test('seek 到块内偏移：先跳块再空跑到对齐点', () {
      final data = Uint8List.fromList(List<int>.generate(80, (i) => i * 7));

      final whole = Uint8List.fromList(data);
      ctrStreamForTest(key, iv).processBytes(whole, 0, 80, whole, 0);

      // 目标：从字节偏移 53 开始解 16 字节。
      // 53 = 3 * 16 + 5，所以先 seek 到第 3 块，再空跑 5 字节。
      final part = Uint8List(16);
      final s = ctrStreamForTest(key, iv)..seek(3);
      s.processBytes(Uint8List(5), 0, 5, Uint8List(5), 0);
      s.processBytes(data, 53, 16, part, 0);

      expect(part, whole.sublist(53, 69));
    });

    test('原地解密（input == output）结果正确', () {
      final data = Uint8List.fromList(List<int>.generate(48, (i) => i * 3));
      // 局部变量不能叫 expect——会遮蔽测试框架的 expect() 函数。
      final want = Uint8List.fromList(data);
      ctrStreamForTest(key, iv).processBytes(want, 0, 48, want, 0);

      final actual = Uint8List.fromList(data);
      ctrStreamForTest(key, iv).processBytes(actual, 0, 48, actual, 0);

      expect(actual, want);
      expect(actual, isNot(data));
    });
  });

  group('QingTingDecipher', () {
    test('非法密钥长度报错', () {
      expect(
        () => QingTingDecipher(Uint8List(8), Uint8List(16)),
        throwsA(isA<QingTingFailure>()),
      );
    });

    test('非法 IV 长度报错', () {
      expect(
        () => QingTingDecipher(Uint8List(16), Uint8List(8)),
        throwsA(isA<QingTingFailure>()),
      );
    });

    test('fromHexKey 正常构造', () {
      final hex = '00'.padRight(32, '0');
      expect(() => QingTingDecipher.fromHexKey(hex, '.p!MTIzNDU2.qta'),
          returnsNormally);
    });

    test('奇数长度 hex 报错', () {
      expect(
        () => QingTingDecipher.fromHexKey('abc', '.p!MTIzNDU2.qta'),
        throwsA(isA<QingTingFailure>()),
      );
    });

    test('非 hex 字符报错', () {
      expect(
        () => QingTingDecipher.fromHexKey('zz' * 16, '.p!MTIzNDU2.qta'),
        throwsA(isA<QingTingFailure>()),
      );
    });

    test('同一密钥下分块解密 == 整体解密', () {
      final d = QingTingDecipher(
        Uint8List(16),
        makeDecipherIv('.p!MTIzNDU2.qta'),
      );
      final plain = Uint8List.fromList(
          List<int>.generate(1000, (i) => (i * 31) & 0xFF));

      // 整体
      final whole = Uint8List.fromList(plain);
      for (var off = 0; off < whole.length; off += 4 * 1024 * 1024) {
        final end = off + 4 * 1024 * 1024 < whole.length
            ? off + 4 * 1024 * 1024
            : whole.length;
        d.decrypt(Uint8List.sublistView(whole, off, end), off);
      }

      // 分块
      final chunked = Uint8List.fromList(plain);
      for (var off = 0; off < chunked.length; off += 333) {
        final end = off + 333 < chunked.length ? off + 333 : chunked.length;
        d.decrypt(Uint8List.sublistView(chunked, off, end), off);
      }

      expect(chunked, whole);
      expect(chunked, isNot(plain));
    });

    test('空 buffer 不崩', () {
      final d = QingTingDecipher(Uint8List(16), Uint8List(16));
      expect(() => d.decrypt(Uint8List(0), 0), returnsNormally);
    });
  });

  group('isQingTingFileName', () {
    test('识别 .p! 与 .p~! 两种前缀', () {
      expect(isQingTingFileName('.p!MTIz.qta'), isTrue);
      expect(isQingTingFileName('.p~!MTIz.qta'), isTrue);
      expect(isQingTingFileName('/a/b/.p!MTIz.qta'), isTrue);
    });

    test('不含前缀的 .qta 返回 false', () {
      expect(isQingTingFileName('random.qta'), isFalse);
      expect(isQingTingFileName('song.mp3'), isFalse);
    });
  });

  group('parseHexOrThrow', () {
    test('正常解析', () {
      expect(parseHexOrThrow('00ff10', 'x'),
          Uint8List.fromList([0x00, 0xff, 0x10]));
    });

    test('大写也认', () {
      expect(parseHexOrThrow('AB', 'x'), Uint8List.fromList([0xab]));
    });

    test('奇数长度报错', () {
      expect(() => parseHexOrThrow('abc', 'x'),
          throwsA(isA<QingTingFailure>()));
    });

    test('非法字符报错', () {
      expect(() => parseHexOrThrow('zz', 'x'),
          throwsA(isA<QingTingFailure>()));
    });
  });
}

// ==================== 测试辅助 ====================

/// 建一个已初始化的 AES 引擎（encrypt 模式）。
BlockCipher _newAes(Uint8List key, Uint8List iv) =>
    AESEngine()..init(true, KeyParameter(key));

/// 建一个 seek 到第 0 块的 CTR 流。
AesCtr64BeStream ctrStreamForTest(Uint8List key, Uint8List iv) {
  final s = AesCtr64BeStream(_newAes(key, iv), iv);
  return s.seek(0);
}

/// 用 AES-ECB 加密一个块（把 16 字节块直接当 counter block 喂进去）。
Uint8List aesEcbForTest(Uint8List key, Uint8List block) {
  final out = Uint8List(16);
  _newAes(key, block).processBlock(block, 0, out, 0);
  return out;
}
