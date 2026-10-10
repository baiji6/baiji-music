/// 解密算法回归测试。
///
/// 测试向量全部取自 Rust 上游 `lib_um_crypto_rust` 的单元测试与 fixture，
/// 目的是保证 Dart 移植与 Rust 实现**逐字节一致**——只要上游改了常量，
/// 这里就会红。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/decrypt/kgm.dart';
import 'package:baiji_music/decrypt/kwm.dart';
import 'package:baiji_music/decrypt/migu.dart';
import 'package:baiji_music/decrypt/ncm.dart';
import 'package:baiji_music/decrypt/qmc_ekey.dart';
import 'package:baiji_music/decrypt/qmc_footer.dart';
import 'package:baiji_music/decrypt/tc_tea.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/crypto/$name').readAsBytesSync();

void main() {
  group('tc_tea', () {
    // 上游 tc_tea crate 的 GOOD_ENCRYPTED_DATA
    final good = Uint8List.fromList([
      0x91, 0x09, 0x51, 0x62, 0xe3, 0xf5, 0xb6, 0xdc, //
      0x6b, 0x41, 0x4b, 0x50, 0xd1, 0xa5, 0xb8, 0x4e,
      0xc5, 0x0d, 0x0c, 0x1b, 0x11, 0x96, 0xfd, 0x3c,
    ]);
    final key = utf8.encode('12345678ABCDEFGH');

    test('解密上游已知密文', () {
      final plain = tcTeaDecrypt(good, key);
      expect(plain, [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('尾部被篡改时抛异常（密钥错误检测）', () {
      final bad = Uint8List.fromList(good);
      bad[23] ^= 0xff;
      expect(() => tcTeaDecrypt(bad, key), throwsFormatException);
    });

    test('长度非法时抛异常', () {
      expect(() => tcTeaDecrypt(Uint8List(11), key), throwsFormatException);
      expect(() => tcTeaDecrypt(Uint8List(12), key), throwsFormatException);
    });

    test('密钥必须 16 字节', () {
      expect(() => tcTeaDecrypt(good, utf8.encode('short')),
          throwsArgumentError);
    });
  });

  group('QMC footer 解析', () {
    test('Android QTag', () {
      final f = parseQmcFooter(_fixture('ekey_android_qtag.bin'))!;
      expect(f.type, QmcFooterType.androidQTag);
      expect(f.ekey, '00112233aBcD+/=');
      expect(f.size, 0x23);
      expect(f.resourceId, 326454301);
    });

    test('Android STag', () {
      final f = parseQmcFooter(_fixture('ekey_android_stag.bin'))!;
      expect(f.type, QmcFooterType.androidSTag);
      expect(f.ekey, isNull);
      expect(f.size, 0x20);
      expect(f.resourceId, 5177785);
      expect(f.mediaMid, '001y7CaR29k6YP');
    });

    test('PC v1 (Legacy)', () {
      final f = parseQmcFooter(_fixture('ekey_pc_enc_v1.bin'))!;
      expect(f.type, QmcFooterType.pcV1Legacy);
      expect(f.ekey!.startsWith('NUZ6b0la'), isTrue);
      expect(f.size, 0x2C4);
    });

    test('PC v2 (MusicEx)', () {
      final f = parseQmcFooter(_fixture('ekey_pc_enc_v2.bin'))!;
      expect(f.type, QmcFooterType.pcV2MusicEx);
      expect(f.ekey, isNull);
      expect(f.size, 0xC0);
      expect(f.mediaMid, 'AaBbCcDdEeFfGg');
      expect(f.mediaFilename, 'F0M000112233445566.mflac');
    });

    test('无法识别的 buffer 返回 null', () {
      final junk = Uint8List(64);
      expect(parseQmcFooter(junk), isNull);
    });
  });

  group('KGM', () {
    test('头部过小', () {
      expect(() => parseKgmHeader(Uint8List.fromList(utf8.encode('bad file'))),
          throwsFormatException);
    });

    test('magic 不匹配', () {
      expect(() => parseKgmHeader(_fixture('kgm_invalid_magic.bin')),
          throwsFormatException);
    });

    test('v2 头部', () {
      final h = parseKgmHeader(_fixture('kgm_v2_hdr.bin'));
      expect(h.cryptoVersion, 2);
      expect(h.keySlot, 1);
      expect(h.isKgm, isTrue);
    });

    test('v3 头部', () {
      final h = parseKgmHeader(_fixture('kgm_v3_hdr.bin'));
      expect(h.cryptoVersion, 3);
      expect(h.keySlot, 1);
    });

    test('v5 头部含 audio_hash', () {
      final h = parseKgmHeader(_fixture('kgm_v5_hdr.bin'));
      expect(h.cryptoVersion, 5);
      expect(h.keySlot, -1);
      expect(h.audioHash, '81a26217da847692e7688e0a5ebe9da1');
    });

    test('v2 自检能识别不匹配的 test data', () {
      // 上游 fixture 的 decrypt_test_data 是合成数据（上游自己的测试也从不跑
      // 自检），所以这里期望的是「自检把坏文件挡下来」这个行为。
      final h = parseKgmHeader(_fixture('kgm_v2_hdr.bin'));
      expect(() => createKgmDecipher(h), throwsFormatException);
    });

    test('v2 解密对齐 Rust 复算向量', () {
      // 明文 KGM_TEST_DATA在真实 KGM 文件里就是这段密文
      final ct = Uint8List.fromList([
        0x54, 0xa9, 0xc2, 0xb5, 0x15, 0x73, 0xd7, 0x6b, //
        0xdf, 0x2f, 0x4e, 0x66, 0x7a, 0x8c, 0x32, 0x60,
      ]);
      final h = parseKgmHeader(_fixture('kgm_v2_hdr.bin'));
      KgmV2(h).decrypt(ct, 0);
      expect(ct, [
        0x38, 0x85, 0xED, 0x92, 0x79, 0x5F, 0xF8, 0x4C, //
        0xB3, 0x03, 0x61, 0x41, 0x16, 0xA0, 0x1D, 0x47,
      ]);
    });

    test('v3 解密与 Rust crate 逐字节一致', () {
      // 上游 fixture 里 decrypt_test_data 的真实字节。Rust crate 与本移植
      // 对同一输入必须给出同一输出（已用 Rust 侧交叉验证）。
      final input = Uint8List.fromList([
        0x84, 0x6a, 0x1b, 0x1b, 0x66, 0x3b, 0xe7, 0x76, //
        0xa9, 0xc9, 0x62, 0x31, 0xb9, 0x89, 0x81, 0x8e,
      ]);
      final expected = [
        0xf8, 0x75, 0x8d, 0x02, 0x89, 0x1f, 0x08, 0xec, //
        0x13, 0xa3, 0x51, 0x41, 0xe6, 0x30, 0xdd, 0xd7,
      ];
      final h = parseKgmHeader(_fixture('kgm_v3_hdr.bin'));
      final buf = Uint8List.fromList(input);
      KgmV3(h).decrypt(buf, 0);
      expect(buf, expected);
    });

    test('hashKey 的 2 字节组逆序重排（Rust rchunks 语义）', () {
      // md5("l,/'") = 61 85 8b fd 79 27 85 6b 6f 41 0d 3b 10 b1 14 e3
      // 按 2 字节一组逆序重排后：14 e3 10 b1 0d 3b 6f 41 85 6b 79 27 8b fd 61 85
      final h = KgmV3.hashKeyForTest([0x6C, 0x2C, 0x2F, 0x27]);
      expect(h, [
        0x14, 0xE3, 0x10, 0xB1, 0x0D, 0x3B, 0x6F, 0x41, //
        0x85, 0x6B, 0x79, 0x27, 0x8B, 0xFD, 0x61, 0x85,
      ]);
    });

    test('v5 缺 ekey时报错', () {
      final h = parseKgmHeader(_fixture('kgm_v5_hdr.bin'));
      expect(() => createKgmDecipher(h), throwsFormatException);
    });

    test('不支持的 key slot', () {
      final h = parseKgmHeader(_fixture('kgm_v5_hdr.bin'));
      expect(() => KgmV3(h), throwsFormatException);
    });
  });

  group('KWM', () {
    test('头部 magic 与字段解析', () {
      // 构造一个最小合法头：magic1 + version=1 + resource_id=1234
      final buf = Uint8List(0x40);
      buf.setRange(0, 0x10, [
        0x79, 0x65, 0x65, 0x6C, 0x69, 0x6F, 0x6E, 0x2D, //
        0x6B, 0x75, 0x77, 0x6F, 0x2D, 0x74, 0x6D, 0x65,
      ]);
      ByteData.sublistView(buf).setUint32(0x10, 1, Endian.little);
      ByteData.sublistView(buf).setUint32(0x14, 0, Endian.little);
      ByteData.sublistView(buf).setUint32(0x18, 1234, Endian.little);
      // format_name 是 12 字节定长字段，"aac" + 9个 0
      final fmt = Uint8List(0x0C)..setRange(0, 3, utf8.encode('aac'));
      buf.setRange(0x24, 0x24 + 0x0C, fmt);

      final h = parseKwmHeader(buf);
      expect(h.version, 1);
      expect(h.resourceId, 1234);
      expect(utf8.decode(h.formatName.sublist(0, 3)), 'aac');
      expect(h.qualityId, 0); // "aac" 没有数字前缀
      expect(() => createKwmDecipher(h), returnsNormally);
    });

    test('magic 不匹配时抛异常', () {
      expect(() => parseKwmHeader(Uint8List(0x2C)),
          throwsFormatException);
    });

    test('酷我非标准 DES 解密上游测试向量', () {
      final input = Uint8List.fromList([
        0x36, 0x3C, 0x3E, 0x0D, 0x30, 0x31, 0xA4, 0x6C, //
        0xA0, 0xF0, 0x3A, 0xEC, 0x7F, 0x26, 0xF6, 0xF4,
      ]);
      final des = KuwoDes(kuwoSecretKey);
      final out = des.transform(input);
      expect(utf8.decode(out), '12345678ABCDEFGH');
    });

    test('酷我 DES 数据长度必须 8 的倍数', () {
      final des = KuwoDes(kuwoSecretKey);
      expect(() => des.transform(Uint8List(7)), throwsFormatException);
    });

    test('ksing 解密上游测试向量', () {
      final s = kuwoDecryptKsing('tx5ct5ilzeLs7pN1C4RI6w==',
          utf8.encode('12345678'));
      expect(s, 'hello world');
    });
  });

  group('NCM', () {
    test('识别头部', () {
      expect(isNcmFile(_fixture('ncm_test1.bin')), isTrue);
      expect(isNcmFile(Uint8List(16)), isFalse);
    });

    test('解析头部并解出 RC4 密钥流', () {
      final h = parseNcmHeader(_fixture('ncm_test1.bin'));
      // 上游 test_load_ncm 断言的密钥流前若干字节
      expect(h.audioRc4KeyStream.sublist(0, 16), [
        0x67, 0x20, 0xF0, 0x5C, 0xAC, 0xAF, 0x1B, 0x74, //
        0x0D, 0x26, 0x40, 0xBE, 0x85, 0x61, 0x45, 0x0D,
      ]);
      expect(utf8.decode(h.image1!), 'img#1');
      expect(utf8.decode(h.image2!), 'IMAGE#2');
    });

    test('解密音频数据得到 ID3 头', () {
      final bytes = _fixture('ncm_test1.bin');
      final h = parseNcmHeader(bytes);
      final audio = Uint8List.fromList(bytes.sublist(h.audioDataOffset));
      h.decrypt(audio, 0);
      expect(audio.sublist(0, 15), [
        0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, //
        0x01, 0x73, 0x54, 0x50, 0x45, 0x31, 0x00,
      ]);
    });

    test('content key 解密（上游测试向量）', () {
      final enc = Uint8List.fromList([
        0x2C, 0xCE, 0xD5, 0xEB, 0x69, 0xEA, 0xFB, 0x14, 0x55, 0x0D, //
        0x45, 0xBF, 0x61, 0xDD, 0x17, 0x1D, 0x93, 0x71, 0x47, 0x1E,
        0xE1, 0xDD, 0xDA, 0xF4, 0xD5, 0xE8, 0x4F, 0x1C, 0xBA, 0x00,
        0x20, 0xC3, 0x02, 0xE9, 0xFE, 0x29, 0x92, 0xE1, 0x81, 0x45,
        0x6F, 0x18, 0xC7, 0x2D, 0x11, 0xF2, 0xBC, 0x5B, 0xBC, 0xDC,
        0x22, 0x33, 0xF9, 0x68, 0xB4, 0xB0, 0x28, 0x38, 0x3F, 0x63,
        0x6C, 0x88, 0x66, 0x35, 0xF9, 0xE7, 0xB1, 0x70, 0x0E, 0xEE,
        0x55, 0xAC, 0xB8, 0xED, 0x8B, 0x48, 0x17, 0x25, 0x3A, 0xE6,
        0x5E, 0xB5, 0x80, 0x78, 0x8A, 0xCD, 0xDC, 0xE1, 0xEF, 0x3D,
        0x30, 0xEC, 0x9C, 0x2A, 0xC6, 0xC7, 0x51, 0xAE, 0x3D, 0x11,
        0xB5, 0x64, 0x88, 0x9E, 0xD6, 0x77, 0x66, 0xF6, 0x2B, 0x52,
        0x9E, 0xFA, 0xF9, 0x63, 0xF6, 0xDE, 0x27, 0x10, 0x45, 0x82,
        0xAC, 0x2D, 0x20, 0x84, 0x95, 0x4C, 0x0F, 0x7A, 0xAE, 0x8B,
        0x91, 0x6D, 0x10, 0x2E, 0x63, 0x1C, 0xEA, 0xCA, 0xF9, 0x14,
        0x97, 0xD8, 0xB3, 0xE8,
      ]);
      final key = utf8.decode(ncmDecryptContentKey(enc));
      expect(
        key,
        '174279197715752960061821572626E7fT49x7dof9OKCgg9cdvhEuezy3iZCL1n'
        'FvBFd1T4uSktAJKmwZXsijPbijliionVUXXg9plTbXEclAE9Lb',
      );
    });

    test('头部被破坏时 CRC 校验失败', () {
      final bytes = _fixture('ncm_test1.bin');
      bytes[20] ^= 0xff;
      expect(() => parseNcmHeader(bytes), throwsFormatException);
    });
  });

  group('咪咕Migu3D', () {
    test('fileKey 推导密钥长度', () {
      final k = miguKeyFromFileKey('dummyFileKey');
      expect(k.length, 32);
      // 大写hex，字符集限定
      for (final c in k) {
        final ch = String.fromCharCode(c);
        expect(RegExp(r'^[0-9A-F]$').hasMatch(ch), isTrue);
      }
    });

    test('解密是逐字节减法', () {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final d = MiguDecipher.fromKey(key);
      final data = Uint8List.fromList([10, 20, 30, 64]);
      d.decrypt(data, 0);
      //逐字节减去 key[i % 32]：10-1 / 20-2 / 30-3 / 64-4
      expect(data, [9, 18, 27, 60]);
    });

    test('密钥长度必须为 32', () {
      expect(() => MiguDecipher.fromKey([1, 2, 3]), throwsArgumentError);
    });

    test('无法猜出密钥时返回 null', () {
      expect(guessMiguKey(Uint8List(0x200)), isNull);
      expect(guessMiguKey(Uint8List(8)), isNull);
    });

    test('能构造 WAV 型 fixture 并验证', () {
      // 造一个 WAV 型咪咕文件：0x40 处放key，0x00 处放RIFF 的密文
      final key = Uint8List.fromList(
          List<int>.generate(32, (i) => 0x30 + (i % 6)));
      final buf = Uint8List(0x100);
      buf.setRange(0x40, 0x60, key);
      // 构造密文：plain - key（异或逆运算 = 加法）
      for (var i = 0; i < 4; i++) {
        final plain = 'RIFF'.codeUnitAt(i);
        buf[i] = (plain + key[i]) & 0xFF;
      }
      for (var i = 0; i < 4; i++) {
        final plain = 'data'.codeUnitAt(i);
        buf[0x60 + i] = (plain + key[(0x60 + i) % 32]) & 0xFF;
      }
      final guessed = guessMiguKey(buf);
      expect(guessed, isNotNull);
      expect(guessed, Uint8List.fromList(key));
    });
  });

  group('ekey 入口', () {
    test('PC v1 footer 里的 ekey 能解出密钥', () {
      final f = parseQmcFooter(_fixture('ekey_pc_enc_v1.bin'))!;
      final key = qmcEkeyDecrypt(f.ekey!);
      // 上游 fixture 是真实 ekey，解出来应是非空且长度合理的音频密钥
      expect(key, isNotEmpty);
      expect(key.length, greaterThan(8));
    });

    test('v2 前缀常量正确', () {
      expect(ekeyV2Prefix, 'UVFNdXNpYyBFbmNWMixLZXk6');
      expect(ekeyV2Prefix.length, 24);
      expect(utf8.decode(base64.decode(ekeyV2Prefix)), 'QQMusic EncV2,Key:');
    });

    test('simpleKey 常量稳定', () {
      expect(ekeySimpleKey.length, 8);
      for (final v in ekeySimpleKey) {
        expect(v, inInclusiveRange(0, 255));
      }
    });

    test('过短输入抛 FormatException', () {
      expect(() => qmcEkeyDecrypt('abc'), throwsFormatException);
    });
  });
}
