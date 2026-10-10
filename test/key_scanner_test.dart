import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/decrypt/decryptor.dart' show DecryptPlatform;
import 'package:baiji_music/decrypt/key_scanner.dart'
    show KeyScanResult, isMmkv, isSqlite, looksLikeEkey;
import 'package:baiji_music/decrypt/key_scanner.dart' as scanner;
import 'package:flutter_test/flutter_test.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/keys/$name').readAsBytesSync();

// 密钥现在按平台隔离，扫描时也必须指明平台。这几个壳函数把默认平台固定成
// QQ 音乐，免得每个用例都写一遍样板；需要测别的平台时显式调scanner.*。
KeyScanResult scanKeys(Uint8List bytes, {String hint = ''}) =>
    scanner.scanKeys(bytes,
        platform: DecryptPlatform.qqMusic, hint: hint);

KeyScanResult scanMmkvKeys(Uint8List bytes) =>
    scanner.scanMmkvKeys(bytes, platform: DecryptPlatform.qqMusic);

KeyScanResult scanSqliteKeys(Uint8List bytes) =>
    scanner.scanSqliteKeys(bytes, platform: DecryptPlatform.qqMusic);

void main() {
  group('looksLikeEkey', () {
    test('接受各平台常见长度的 base64', () {
      expect(looksLikeEkey(base64.encode(List<int>.filled(128, 7))), isTrue);
      expect(looksLikeEkey(base64.encode(List<int>.filled(364, 7))), isTrue);
      expect(looksLikeEkey(base64.encode(List<int>.filled(32, 7))), isTrue);
    });

    test('拒绝非 base64 / 过短 / 解码后过长的串', () {
      expect(looksLikeEkey('not base64 at all!!'), isFalse);
      expect(looksLikeEkey(base64.encode(List<int>.filled(2, 7))), isFalse,
          reason: '解出来只有 2 字节');
      expect(looksLikeEkey(base64.encode(List<int>.filled(2048, 7))), isFalse,
          reason: '解出来 2048 字节，超出上限');
      expect(looksLikeEkey('abc'), isFalse);
    });
  });

  group('MMKV 解析', () {
    late Uint8List bytes;

    setUp(() => bytes = _fixture('mmkv_sample.bin'));

    test('识别魔数', () {
      expect(isMmkv(bytes), isTrue);
      expect(isMmkv(_fixture('sqlite_sample.db')), isFalse);
    });

    test('解出全部 3 条密钥，且跳过非密钥字段', () {
      final r = scanMmkvKeys(bytes);
      expect(r.source, 'MMKV');
      expect(r.entries.length, 3,
          reason: 'some_flag 的值是明文短串，不该被收进来');
    });

    test('从 key 名里抠出 mid', () {
      final r = scanMmkvKeys(bytes);
      final withMid = r.entries.where((e) => e.mid != null).toList();
      expect(withMid.length, 2);
      expect(withMid.map((e) => e.mid), containsAll(['001y7CaR29k6YP']));
      expect(withMid.any((e) => e.mid == '0038mTc14ImRv0'), isTrue,
          reason: 'kugou_file_key_0038mTc14ImRv0 里的 14 位数字应被识别为 mid');
    });

    test('来源标记为 MMKV 导入', () {
      expect(scanMmkvKeys(bytes).entries.every((e) => e.source.name == 'importedMmkv'),
          isTrue);
    });

    test('同一份数据扫两次结果一致（无内部状态污染）', () {
      final a = scanMmkvKeys(bytes).entries.map((e) => e.value).toList()..sort();
      final b = scanMmkvKeys(bytes).entries.map((e) => e.value).toList()..sort();
      expect(a, b);
    });
  });

  group('SQLite 解析', () {
    late Uint8List bytes;

    setUp(() => bytes = _fixture('sqlite_sample.db'));

    test('识别魔数', () {
      expect(isSqlite(bytes), isTrue);
      expect(isSqlite(_fixture('mmkv_sample.bin')), isFalse);
    });

    test('只收 ekey 列，跳过无密钥列的表', () {
      final r = scanSqliteKeys(bytes);
      expect(r.source, 'SQLite');
      expect(r.entries.length, 2, reason: 'music 表两行；kvlog 表无密钥列');
      expect(r.note, contains('music'));
    });

    test('同行把 mid / quality_id 一起带出来', () {
      final r = scanSqliteKeys(bytes);
      final e = r.entries.firstWhere((e) => e.mid == '001y7CaR29k6YP');
      expect(e.qualityId, 3);
      final e2 = r.entries.firstWhere((e) => e.mid == '0038mTc14ImRv0');
      expect(e2.qualityId, 5);
    });

    test('抠出的密钥能还原成原始字节', () {
      final r = scanSqliteKeys(bytes);
      final e = r.entries.firstWhere((e) => e.mid == '001y7CaR29k6YP');
      expect(base64.decode(e.value).length, 364);
    });
  });

  group('统一入口分派', () {
    test('MMKV 文件走 MMKV 分支', () {
      final r = scanKeys(_fixture('mmkv_sample.bin'));
      expect(r.source, 'MMKV');
      expect(r.entries, isNotEmpty);
    });

    test('SQLite 文件走 SQLite 分支', () {
      final r = scanKeys(_fixture('sqlite_sample.db'));
      expect(r.source, 'SQLite');
      expect(r.entries.length, 2);
    });

    test('PLAIN 之类的裸文本走兜底分支', () {
      final key = base64.encode(List<int>.filled(64, 3));
      final r = scanKeys(latin1.encode('some prefix\n$key\nsome suffix'));
      expect(r.source, '二进制扫描');
      expect(r.entries.single.value, key);
    });

    test('空输入不崩', () {
      final r = scanKeys(Uint8List(0));
      expect(r.isEmpty, isTrue);
    });

    test('魔数缺失但文件名带 mmkv 时仍能按 MMKV 解析', () {
      final raw = _fixture('mmkv_sample.bin');
      // 抹掉魔数
      final stripped = Uint8List.fromList(raw)..[0] = 0x00;
      final byHint = scanKeys(stripped, hint: 'music_cache.mmkv');
      final direct = scanMmkvKeys(stripped);
      expect(byHint.entries.length, direct.entries.length);
      expect(byHint.entries.length, greaterThan(0));
    });
  });

  group('健壮性', () {
    test('随机字节不会崩且不误报', () {
      final rnd = Uint8List(4096);
      var s = 12345;
      for (var i = 0; i < rnd.length; i++) {
        s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
        rnd[i] = (s >> 16) & 0xFF;
      }
      final r = scanKeys(rnd);
      expect(r.isEmpty, isTrue);
    });

    test('被截断的 SQLite 不崩', () {
      final full = _fixture('sqlite_sample.db');
      expect(() => scanKeys(Uint8List.sublistView(full, 0, 512)), returnsNormally);
    });

    test('被截断的 MMKV 不崩', () {
      final full = _fixture('mmkv_sample.bin');
      expect(() => scanMmkvKeys(Uint8List.sublistView(full, 0, 20)),
          returnsNormally);
    });
  });
}
