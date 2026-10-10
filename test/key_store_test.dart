import 'dart:convert';
import 'package:baiji_music/decrypt/decryptor.dart';
import 'package:baiji_music/decrypt/key_store.dart';
import 'package:baiji_music/decrypt/qmc_footer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 密钥按平台隔离的行为约束。
///
/// 核心不变量：**同一串密钥在不同平台下是两条独立记录，查找时绝不串味。**
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DecryptKeyEntry JSON', () {
    test('toJson 带平台字段', () {
      final e = DecryptKeyEntry(
        value: 'v1',
        platform: DecryptPlatform.kugou,
        mid: 'm1',
      );
      final j = e.toJson();
      expect(j['p'], 'kugou');
      expect(j['v'], 'v1');
      expect(j['mid'], 'm1');
    });

    test('fromJson 读回平台', () {
      final e = DecryptKeyEntry.fromJson(
          json.decode('{"v":"v1","p":"kuwo","mid":"m"}'));
      expect(e.platform, DecryptPlatform.kuwo);
      expect(e.value, 'v1');
    });

    test('v1 老数据没有平台字段 → 归到 QQ 音乐', () {
      // 迁移路径：旧版本存下来的 key 只有 value / mid。
      final e = DecryptKeyEntry.fromJson(json.decode('{"v":"v1","mid":"m"}'));
      expect(e.platform, DecryptPlatform.qqMusic);
    });
  });

  group('DecryptPlatform 语义', () {
    test('六个平台', () {
      expect(DecryptPlatform.values.length, 6);
      expect(DecryptPlatform.qingting.extensions, ['.qta']);
    });

    test('keyIsHex 只有蜻蜓 FM', () {
      for (final p in DecryptPlatform.values) {
        expect(p.keyIsHex, p == DecryptPlatform.qingting, reason: p.name);
      }
    });

    test('needsKey：酷狗 / 酷我 / 蜻蜓需要密钥', () {
      final needs = DecryptPlatform.values.where((p) => p.needsKey).toList();
      expect(needs, [
        DecryptPlatform.kugou,
        DecryptPlatform.kuwo,
        DecryptPlatform.qingting,
      ]);
    });
  });

  group('importText 的平台归属', () {
    late DecryptKeys keys;

    setUp(() {
      keys = _keysOf([
        DecryptKeyEntry(value: 'a', platform: DecryptPlatform.qqMusic),
      ]);
    });

    test('逐行 ekey 全部归到指定平台', () {
      final n = keys.importText('k1\nk2\nk3',
          platform: DecryptPlatform.kugou);
      expect(n, 3);
      expect(keys.countOf(DecryptPlatform.kugou), 3);
      expect(keys.countOf(DecryptPlatform.qqMusic), 1);
    });

    test('mid,ekey 两段式', () {
      keys.importText('midA,ekeyA', platform: DecryptPlatform.kugou);
      final e = keys.lookupByMid('midA', DecryptPlatform.kugou);
      expect(e, 'ekeyA');
    });

    test('mid,文件名,ekey 三段式', () {
      keys.importText('midB,a.mp3,ekeyB', platform: DecryptPlatform.kuwo);
      final e = keys.lookupByMediaFilename('a.mp3', DecryptPlatform.kuwo);
      expect(e, 'ekeyB');
      expect(e, keys.lookupByMediaFilename('a.mp3', DecryptPlatform.kuwo));
    });

    test('同名密钥在两个平台下各存一份，互不覆盖', () {
      keys.importText('shared', platform: DecryptPlatform.kuwo);
      keys.importText('shared', platform: DecryptPlatform.qingting);
      expect(keys.countOf(DecryptPlatform.kuwo), 1);
      expect(keys.countOf(DecryptPlatform.qingting), 1);
      expect(keys.anyEkeyOf(DecryptPlatform.kuwo), 'shared');
      expect(keys.anyEkeyOf(DecryptPlatform.qingting), 'shared');
    });

    test('# 注释与空行被跳过', () {
      final n = keys.importText('# 注释\n\nreal\n  \n',
          platform: DecryptPlatform.migu);
      expect(n, 1);
    });
  });

  group('查找严格限定平台', () {
    late DecryptKeys keys;

    setUp(() {
      keys = _keysOf([
        DecryptKeyEntry(
            value: 'qq-ekey', platform: DecryptPlatform.qqMusic, mid: 'M1'),
        DecryptKeyEntry(
            value: 'kg-filekey', platform: DecryptPlatform.kugou, mid: 'M1'),
        DecryptKeyEntry(
            value: 'qt-hex', platform: DecryptPlatform.qingting, mid: 'M1'),
      ]);
    });

    test('lookupByMid 按平台区分', () {
      expect(keys.lookupByMid('M1', DecryptPlatform.qqMusic), 'qq-ekey');
      expect(keys.lookupByMid('M1', DecryptPlatform.kugou), 'kg-filekey');
      expect(keys.lookupByMid('M1', DecryptPlatform.qingting), 'qt-hex');
    });

    test('anyEkeyOf 绝不跨平台返回', () {
      expect(keys.anyEkeyOf(DecryptPlatform.netease), isNull);
      expect(keys.anyEkeyOf(DecryptPlatform.kuwo), isNull);
      expect(keys.anyEkeyOf(DecryptPlatform.migu), isNull);
    });

    test('hasKeysFor / countOf按平台', () {
      expect(keys.hasKeysFor(DecryptPlatform.qqMusic), isTrue);
      expect(keys.hasKeysFor(DecryptPlatform.kuwo), isFalse);
      expect(keys.countOf(DecryptPlatform.kugou), 1);
      expect(keys.countOf(DecryptPlatform.netease), 0);
    });
  });

  group('resolveEkey 按嗅探平台派发', () {
    late DecryptKeys keys;

    setUp(() {
      keys = _keysOf([
        DecryptKeyEntry(
            value: 'qq-ekey', platform: DecryptPlatform.qqMusic, mid: 'M1'),
        DecryptKeyEntry(value: 'kg-filekey',
            platform: DecryptPlatform.kugou, mid: 'M2'),
        DecryptKeyEntry(
            value: 'qt-hex', platform: DecryptPlatform.qingting, mid: 'M3'),
      ]);
    });

    test('QQ 音乐命中自己的 ekey', () {
      final sniff = SniffResult(
        platform: DecryptPlatform.qqMusic,
        audioDataOffset: 0,
        footer: const QmcFooter(type: QmcFooterType.pcV1Legacy, size: 0, mediaMid: 'M1'),
      );
      expect(resolveEkey(sniff, keys), 'qq-ekey');
    });

    test('酷狗文件绝不会拿到 QQ 的 ekey', () {
      final sniff = SniffResult(
        platform: DecryptPlatform.kugou,
        audioDataOffset: 0,
        footer: const QmcFooter(type: QmcFooterType.pcV1Legacy, size: 0, mediaMid: 'M2'),
      );
      expect(resolveEkey(sniff, keys), 'kg-filekey');
    });

    test('mid 匹配不上时退到该平台的任意一把', () {
      final sniff = SniffResult(
        platform: DecryptPlatform.qingting,
        audioDataOffset: 0,
        footer: const QmcFooter(type: QmcFooterType.pcV1Legacy, size: 0, mediaMid: '未知mid'),
      );
      expect(resolveEkey(sniff, keys), 'qt-hex');
    });

    test('该平台没密钥 → 返回 null，绝不借用别的平台', () {
      final sniff = SniffResult(
        platform: DecryptPlatform.kuwo,
        audioDataOffset: 0,
      );
      expect(resolveEkey(sniff, keys), isNull);
    });

    test('文件内嵌 ekey 优先级最高', () {
      final sniff = SniffResult(
        platform: DecryptPlatform.qqMusic,
        audioDataOffset: 0,
        footer: const QmcFooter(
            type: QmcFooterType.pcV1Legacy, size: 0, mediaMid: 'M1', ekey: 'embedded'),
      );
      expect(resolveEkey(sniff, keys), 'embedded');
    });
  });
}

/// 直接从内存构造一个 DecryptKeys，不碰 shared_preferences。
DecryptKeys _keysOf(List<DecryptKeyEntry> entries) =>
    DecryptKeys.fromEntriesForTest(entries);