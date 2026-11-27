// 第三方聚合音源纯函数测试（v2.6.7）。
//
// 网络请求依赖外部服务与用户自填 key，不进 CI；这里覆盖可离线验证的
// 契约：平台映射、songId 传参规则、音质映射与自动降级、ext/label、开关默认值。
import 'package:baiji_music/core/third_party_source.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/thirdparty/linglan_provider.dart';
import 'package:baiji_music/network/thirdparty/thirdparty_stream_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('平台映射', () {
    test('六端有第三方通道，JOOX/QQ2/本地没有', () {
      expect(ThirdPartyStreamApi.sourceCode(Source.qq), 'tx');
      expect(ThirdPartyStreamApi.sourceCode(Source.kugou), 'kg');
      expect(ThirdPartyStreamApi.sourceCode(Source.kuwo), 'kw');
      expect(ThirdPartyStreamApi.sourceCode(Source.netease), 'wy');
      expect(ThirdPartyStreamApi.sourceCode(Source.qishui), 'qs');
      expect(ThirdPartyStreamApi.sourceCode(Source.migu), 'mg');
      expect(ThirdPartyStreamApi.sourceCode(Source.joox), isNull);
      expect(ThirdPartyStreamApi.sourceCode(Source.qq2), isNull);
      expect(ThirdPartyStreamApi.sourceCode(Source.local), isNull);
    });
  });

  group('音质映射（App 档位 → 第三方规范串）', () {
    test('QQ', () {
      expect(ThirdPartyStreamApi.fromQq(Quality.mp3_128), '128k');
      expect(ThirdPartyStreamApi.fromQq(Quality.mp3_320), '320k');
      expect(ThirdPartyStreamApi.fromQq(Quality.flac), 'flac');
      expect(ThirdPartyStreamApi.fromQq(Quality.hires), 'hires');
      expect(ThirdPartyStreamApi.fromQq(Quality.master), 'master');
      expect(ThirdPartyStreamApi.fromQq(Quality.atmosEac3), 'atmos');
      expect(ThirdPartyStreamApi.fromQq(Quality.dtsX), 'atmos');
    });
    test('网易云', () {
      expect(ThirdPartyStreamApi.fromNetease(NeteaseQuality.standard), '128k');
      expect(ThirdPartyStreamApi.fromNetease(NeteaseQuality.exhigh), '320k');
      expect(ThirdPartyStreamApi.fromNetease(NeteaseQuality.lossless), 'flac');
      expect(ThirdPartyStreamApi.fromNetease(NeteaseQuality.hires), 'hires');
      expect(ThirdPartyStreamApi.fromNetease(NeteaseQuality.jymaster), 'master');
      expect(ThirdPartyStreamApi.fromNetease(NeteaseQuality.vivid), 'atmos');
    });
    test('咪咕 / 汽水', () {
      expect(ThirdPartyStreamApi.fromMigu(MiguQuality.flac24bit), 'flac24bit');
      expect(ThirdPartyStreamApi.fromQishui(QishuiQuality.lowest), '32k');
      expect(ThirdPartyStreamApi.fromQishui(QishuiQuality.medium), '128k');
      expect(ThirdPartyStreamApi.fromQishui(QishuiQuality.lossless), 'flac');
    });
  });

  group('音质自动降级（平台不支持则降到最高可用档）', () {
    test('汽水不支持 hires → 降到 flac', () {
      expect(ThirdPartyStreamApi.clampQuality('hires', 'qs'), 'flac');
    });
    test('酷我不支持 atmos/master → 降到 hires', () {
      expect(ThirdPartyStreamApi.clampQuality('atmos', 'kw'), 'hires');
      expect(ThirdPartyStreamApi.clampQuality('master', 'mg'), 'hires');
    });
    test('平台支持则保持原档', () {
      expect(ThirdPartyStreamApi.clampQuality('flac', 'tx'), 'flac');
      expect(ThirdPartyStreamApi.clampQuality('atmos_plus', 'tx'), 'atmos_plus');
      expect(ThirdPartyStreamApi.clampQuality('master', 'wy'), 'master');
    });
    test('低于平台最低档 → 取最低档', () {
      expect(ThirdPartyStreamApi.clampQuality('32k', 'tx'), '128k');
    });
    test('未知档位 → 取平台最低档', () {
      expect(ThirdPartyStreamApi.clampQuality('???', 'kg'), '128k');
    });
  });

  group('扩展名与展示名', () {
    test('ext 按规范档位推断', () {
      expect(ThirdPartyStreamApi.extOf('128k'), '.mp3');
      expect(ThirdPartyStreamApi.extOf('flac'), '.flac');
      expect(ThirdPartyStreamApi.extOf('master'), '.flac');
      expect(ThirdPartyStreamApi.extOf('atmos'), '.mp4');
    });
    test('label 非空', () {
      for (final q in ThirdPartyStreamApi.rank) {
        expect(ThirdPartyStreamApi.labelOf(q), isNotEmpty);
      }
    });
  });

  group('默认行为（发布包不内置 key）', () {
    test('默认走内置音源且未填 key', () {
      // 该单例在各测试进程内为初始态；getter 不读 KvStore，断言默认常量。
      expect(ThirdPartySource.defaultUseBuiltIn, isTrue);
    });
    test('初始态：默认内置、无 key、不走第三方', () {
      // 测试进程未调用 load()/setApiKey()，字段停在声明默认值，不触碰 KvStore。
      final s = ThirdPartySource.instance;
      expect(s.useBuiltIn, isTrue);
      expect(s.hasApiKey, isFalse);
      expect(s.shouldUseThirdParty, isFalse);
    });
    test('默认 provider 是聆澜', () {
      expect(ThirdPartySource.defaultProviderId, 'linglan');
      expect(ThirdPartySource.instance.providerId, 'linglan');
    });
  });

  group('可插拔 provider 架构', () {
    test('默认注册了聆澜，元数据正确', () {
      expect(ThirdPartyStreamApi.provider.displayName, '聆澜');
      expect(ThirdPartyProviderRegistry.contains('linglan'), isTrue);
      expect(ThirdPartyProviderRegistry.byId('linglan'),
          isA<LinglanProvider>());
    });
    test('未知 provider id 回退到默认（聆澜）', () {
      expect(ThirdPartyProviderRegistry.byId('not_exist'),
          isA<LinglanProvider>());
    });
    test('provider 的 songId 生成规则（不触发网络）', () {
      const p = LinglanProvider();
      Song song(String source, {String mid = 'M', int id = 7}) => Song(
            mid: mid,
            songId: id,
            name: 'n',
            singer: 's',
            album: 'a',
            albumMid: '',
            duration: 0,
            cover: '',
            source: source,
          );
      expect(
          p.songIdOf(song(Source.qq, mid: 'abc'), 'tx'), completion('abc'));
      expect(
          p.songIdOf(song(Source.netease, id: 12345), 'wy'),
          completion('12345'));
      expect(
          p.songIdOf(song(Source.qishui, mid: 'track9'), 'qs'),
          completion('track9'));
    });
  });
}
