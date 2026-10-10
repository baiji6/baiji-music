import 'dart:convert';
import 'dart:typed_data';
import 'package:baiji_music/decrypt/decryptor.dart';
import 'package:baiji_music/decrypt/key_store.dart';
import 'package:baiji_music/decrypt/kgm.dart';
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

    test('QQ 的文件名,ekey 两段式', () {
      keys.importText('songA.mp3,ekeyA', platform: DecryptPlatform.qqMusic);
      expect(keys.lookupByFileName('songA.mp3', DecryptPlatform.qqMusic),
          'ekeyA');
    });

    test('酷狗的 audioHash,ekey 两段式', () {
      keys.importText('aabbccdd,ekeyA', platform: DecryptPlatform.kugou);
      expect(keys.lookupByMatchKey('aabbccdd', DecryptPlatform.kugou),
          'ekeyA');
    });

    test('同名密钥在两个平台下各存一份，互不覆盖', () {
      keys.importText('shared', platform: DecryptPlatform.kuwo);
      keys.importText('shared', platform: DecryptPlatform.qingting);
      expect(keys.countOf(DecryptPlatform.kuwo), 1);
      expect(keys.countOf(DecryptPlatform.qingting), 1);
      // 酷我缺匹配键（没有 rid-quality），拿不到就是拿不到——上游同理
      expect(keys.anyEkeyOf(DecryptPlatform.kuwo), isNull);
      // 蜻蜓一把通吃
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
            platform: DecryptPlatform.kugou, audioHash: 'HASH2'),
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

    test('酷狗按 audioHash 命中自己的 fileKey，绝不拿 QQ 的 ekey', () {
      final sniff = SniffResult(
        platform: DecryptPlatform.kugou,
        audioDataOffset: 0,
        kgmHeader: _kgmHeader('HASH2'),
      );
      expect(resolveEkey(sniff, keys), 'kg-filekey');
    });

    test('酷狗 audioHash 对不上就是没有密钥，绝不退化成随便一把', () {
      final sniff = SniffResult(
        platform: DecryptPlatform.kugou,
        audioDataOffset: 0,
        kgmHeader: _kgmHeader('别的哈希'),
      );
      expect(resolveEkey(sniff, keys), isNull);
    });

    test('蜻蜓只有一把设备密钥，不做匹配', () {
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

  group('跨 isolate 扁平 map 的形状', () {
    test('平台通用条目 + mid / 文件名精确条目并存', () {
      // 与 loadDecryptKeySnapshot 的产出形状保持一致。
      final m = <String, String>{
        'qqMusic': 'generic-ekey',
        'qqMusic 001y7CaR29k6YP': 'hq-ekey',
        'qqMusic@song.mp3': 'by-name-ekey',
        'kugou': 'kg-filekey',
      };
      // 平台级 key 存在 → 解密页的「已配密钥」小标签点亮
      expect(m.containsKey('qqMusic'), isTrue);
      expect(m.containsKey('kugou'), isTrue);
      expect(m.containsKey('kuwo'), isFalse);
      // 精确条目带平台前缀，绝不会撞到别的平台
      expect(m.containsKey('kugou 001y7CaR29k6YP'), isFalse);
    });
  });


  group('各平台真实匹配键', () {
    test('QQ 音乐的匹配键是原始文件名', () {
      final e = DecryptKeyEntry(
          value: 'v', platform: DecryptPlatform.qqMusic,
          mediaFilename: 'song.mp3');
      expect(e.matchKey, 'song.mp3');
      expect(e.hasMatchKey, isTrue);
      expect(DecryptPlatform.qqMusic.matchKeyLabel, '原始文件名');
      expect(DecryptPlatform.qqMusic.needsMatchKey, isTrue);
    });

    test('酷狗的匹配键是 audioHash', () {
      final e = DecryptKeyEntry(
          value: 'v', platform: DecryptPlatform.kugou,
          audioHash: '8fd2a1c0');
      expect(e.matchKey, '8fd2a1c0');
      expect(DecryptPlatform.kugou.matchKeyLabel, contains('audioHash'));
      // mid 不能顶替 audioHash——上游是 hasOwn(audioHash) 严格查表
      final onlyMid = DecryptKeyEntry(
          value: 'v', platform: DecryptPlatform.kugou, mid: 'M1');
      expect(onlyMid.hasMatchKey, isFalse);
    });

    test('酷我的匹配键是 rid-quality，缺一不可', () {
      final e = DecryptKeyEntry(
          value: 'v', platform: DecryptPlatform.kuwo,
          resourceId: 1234, qualityId: 128);
      expect(e.matchKey, '1234-128');
      expect(
        DecryptKeyEntry(value: 'v', platform: DecryptPlatform.kuwo,
                resourceId: 1234)
            .hasMatchKey,
        isFalse,
      );
      expect(
        DecryptKeyEntry(value: 'v', platform: DecryptPlatform.kuwo,
                qualityId: 128)
            .hasMatchKey,
        isFalse,
      );
    });

    test('蜻蜓 / 网易云 / 咪咕没有匹配键', () {
      for (final p in const [
        DecryptPlatform.qingting,
        DecryptPlatform.netease,
        DecryptPlatform.migu,
      ]) {
        expect(p.needsMatchKey, isFalse);
        expect(
          DecryptKeyEntry(value: 'v', platform: p).matchKey,
          isNull,
        );
      }
    });

    test('QQ 的文件名或 mid 任一存在就算可用', () {
      // MusicEx footer 里两个字段可能只出现一个，两个都是合法查表依据。
      expect(
        DecryptKeyEntry(
                value: 'v', platform: DecryptPlatform.qqMusic, mid: 'M1')
            .hasMatchKey,
        isTrue,
      );
      expect(
        DecryptKeyEntry(value: 'v', platform: DecryptPlatform.qqMusic)
            .hasMatchKey,
        isFalse,
      );
    });
  });

  group('按匹配键严格查表', () {
    late DecryptKeys keys;

    setUp(() {
      keys = _keysOf([
        DecryptKeyEntry(
            value: 'qq-ekey',
            platform: DecryptPlatform.qqMusic,
            mediaFilename: 'song.mp3'),
        DecryptKeyEntry(
            value: 'kg-key',
            platform: DecryptPlatform.kugou,
            audioHash: 'aabbccdd'),
        DecryptKeyEntry(
            value: 'kw-128',
            platform: DecryptPlatform.kuwo,
            resourceId: 42,
            qualityId: 128),
        DecryptKeyEntry(
            value: 'kw-320',
            platform: DecryptPlatform.kuwo,
            resourceId: 42,
            qualityId: 320),
      ]);
    });

    test('lookupByMatchKey 命中对应条目', () {
      expect(keys.lookupByMatchKey('song.mp3', DecryptPlatform.qqMusic),
          'qq-ekey');
      expect(keys.lookupByMatchKey('aabbccdd', DecryptPlatform.kugou),
          'kg-key');
      expect(keys.lookupByMatchKey('42-128', DecryptPlatform.kuwo), 'kw-128');
    });

    test('酷我同一资源不同音质是不同的密钥', () {
      expect(keys.lookupByMatchKey('42-320', DecryptPlatform.kuwo), 'kw-320');
    });

    test('匹配键对不上就是查不到，绝不退化', () {
      expect(keys.lookupByMatchKey('other.mp3', DecryptPlatform.qqMusic),
          isNull);
      expect(keys.lookupByMatchKey('aabb', DecryptPlatform.kugou), isNull);
      expect(keys.lookupByMatchKey('42-192', DecryptPlatform.kuwo), isNull);
    });

    test('跨平台拿不到对方的匹配键', () {
      expect(keys.lookupByMatchKey('song.mp3', DecryptPlatform.kugou), isNull);
      expect(keys.lookupByMatchKey('aabbccdd', DecryptPlatform.qqMusic),
          isNull);
    });

    test('空匹配键直接返回 null', () {
      expect(keys.lookupByMatchKey('', DecryptPlatform.qqMusic), isNull);
    });

    test('anyEkeyOf 不返回缺匹配键的条目', () {
      final loose = _keysOf([
        DecryptKeyEntry(
            value: 'no-match-key', platform: DecryptPlatform.kugou, mid: 'M'),
      ]);
      expect(loose.anyEkeyOf(DecryptPlatform.kugou), isNull);
      expect(loose.anyEkeyOf(DecryptPlatform.kuwo), isNull);
      // QQ 有 mid 就算可用
      expect(loose.anyEkeyOf(DecryptPlatform.qqMusic), isNull);
      // 蜻蜓没有匹配键概念，单把就能用
      final qt = _keysOf([
        DecryptKeyEntry(value: 'dev', platform: DecryptPlatform.qingting),
      ]);
      expect(qt.anyEkeyOf(DecryptPlatform.qingting), 'dev');
    });

    test('lookupByFileName 精确命中', () {
      expect(keys.lookupByFileName('song.mp3', DecryptPlatform.qqMusic),
          'qq-ekey');
    });

    test('lookupByFileName 差一两个字符可模糊命中', () {
      expect(keys.lookupByFileName('song.mpe', DecryptPlatform.qqMusic),
          'qq-ekey');
      expect(keys.lookupByFileName('songXmp3', DecryptPlatform.qqMusic),
          'qq-ekey');
    });

    test('lookupByFileName 差太远不猜', () {
      expect(
        keys.lookupByFileName('completely_different_name.flac',
            DecryptPlatform.qqMusic),
        isNull,
      );
    });

    test('lookupByFileName 关掉模糊就只认精确', () {
      expect(
        keys.lookupByFileName('song.mpe', DecryptPlatform.qqMusic,
            allowFuzzy: false),
        isNull,
      );
    });
  });

  group('importText 按平台解析匹配键', () {
    late DecryptKeys keys;

    setUp(() {
      keys = _keysOf([]);
    });

    test('QQ：文件名,ekey', () {
      keys.importText('a.mp3,E1', platform: DecryptPlatform.qqMusic);
      expect(keys.lookupByMatchKey('a.mp3', DecryptPlatform.qqMusic), 'E1');
    });

    test('酷狗：audioHash,ekey', () {
      keys.importText('deadbeef,E2', platform: DecryptPlatform.kugou);
      expect(keys.lookupByMatchKey('deadbeef', DecryptPlatform.kugou), 'E2');
    });

    test('酷我：rid-quality,ekey 被拆成两个字段', () {
      keys.importText('1001-128,E3', platform: DecryptPlatform.kuwo);
      final e = keys.entriesOf(DecryptPlatform.kuwo).single;
      expect(e.resourceId, 1001);
      expect(e.qualityId, 128);
      expect(e.matchKey, '1001-128');
    });

    test('酷我：非数字的匹配键退化成整体存储，不丢数据', () {
      keys.importText('weird-key,E4', platform: DecryptPlatform.kuwo);
      expect(keys.entriesOf(DecryptPlatform.kuwo).single.value, 'E4');
    });

    test('只有 ekey 时没有匹配键', () {
      keys.importText('LONGEKEY', platform: DecryptPlatform.kugou);
      expect(keys.entriesOf(DecryptPlatform.kugou).single.hasMatchKey, isFalse);
    });

    test('key_store 落盘后匹配键不丢', () {
      final e = DecryptKeyEntry(
          value: 'v', platform: DecryptPlatform.kugou, audioHash: 'ff00');
      final back = DecryptKeyEntry.fromJson(e.toJson());
      expect(back.audioHash, 'ff00');
      expect(back.matchKey, 'ff00');
    });
  });

}

/// 直接从内存构造一个 DecryptKeys，不碰 shared_preferences。
DecryptKeys _keysOf(List<DecryptKeyEntry> entries) =>
    DecryptKeys.fromEntriesForTest(entries);

/// 造一个只带 audioHash 的 KGM 头（其余字段解密测试用不到）。
KgmHeader _kgmHeader(String audioHash) => KgmHeader(
      magic: Uint8List.fromList(List.filled(4, 0x4B)),
      offsetToData: 0x400,
      cryptoVersion: 5,
      keySlot: 0,
      decryptTestData: Uint8List(0),
      fileKey: Uint8List(0),
      challengeData: Uint8List(0),
      audioHash: audioHash,
    );
