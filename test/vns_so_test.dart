/// 蝰蛇母带原版 SO 直调引擎的回归测试。
///
/// 真机 SO 是 Android arm64 ELF，桌面测试环境无法加载；这里锁住两点：
/// 1. [probeVnsSo] 在非 Android 平台一律返回 null（保证桌面/CI 走纯 Dart）；
/// 2. 两种引擎满足同一 [ViperEngine] 接口，流式管线可无差别消费。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:baiji_music/viper/viper_super_resolution.dart';
import 'package:baiji_music/viper/vns_so.dart';

void main() {
  group('VNS SO 平台门控', () {
    test('非 Android 平台永远探测不到 SO', () {
      if (Platform.isAndroid) return; // 真机上此断言不成立，跳过
      expect(probeVnsSo('/data/app/lib/arm64'), isNull);
      expect(probeVnsSo(''), isNull);
    });

    test('空/非法目录不会误判为可用', () {
      expect(probeVnsSo(''), isNull);
      expect(probeVnsSo('/definitely/not/a/real/path'), isNull);
    });
  });

  group('升频引擎接口一致性', () {
    test('ViperStreamProcessor 满足 ViperEngine', () {
      final engine = ViperStreamProcessor(rate: ViperUpscaleRate.khz192);
      expect(engine, isA<ViperEngine>());
      expect(engine.ratio, 4);

      final left = Float64List(64)..fillRange(0, 64, 0.1);
      final right = Float64List(64)..fillRange(0, 64, 0.1);
      var got = 0;
      engine.pushStereo(left, right, 64, (_, frames) => got += frames);
      engine.flush((_, frames) => got += frames);
      expect(got, greaterThan(0));
    });

    test('96k 档比例正确（纯 Dart 引擎）', () {
      final engine = ViperStreamProcessor(rate: ViperUpscaleRate.khz96);
      expect(engine.ratio, 2);
    });
  });

  group('SO 升频倍率换算（真机实测回归）', () {
    test('192k 档第 4 参必须是 4（不是声道数 2）', () {
      // 真机实测：传 2 只升到 96k，但 WAV 头按 192k 声明会快一倍。
      expect(vnsSoRatio(192000, 48000), 4);
    });

    test('96k 档第 4 参是 2', () {
      expect(vnsSoRatio(96000, 48000), 2);
    });

    test('44100 系列倍率换算', () {
      expect(vnsSoRatio(176400, 44100), 4);
      expect(vnsSoRatio(88200, 44100), 2);
    });

    test('非法输入率返回 0，供 open 抛错回退', () {
      expect(vnsSoRatio(192000, 0), 0);
      expect(vnsSoRatio(192000, -1), 0);
    });
  });

  group('SO 配置值对象', () {
    test('路径原样保存', () {
      const cfg = VnsSoConfig(
        libVnsPath: '/data/app/lib/libvns.so',
        effectSoPath: '/data/app/lib/libeffect0.so',
      );
      expect(cfg.libVnsPath, '/data/app/lib/libvns.so');
      expect(cfg.effectSoPath, '/data/app/lib/libeffect0.so');
    });

    test('引擎标识稳定', () {
      expect(vnsSoEngineTag, 'vns-so/arm64-v8a');
    });
  });
}
