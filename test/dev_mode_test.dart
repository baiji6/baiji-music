// v2.2.6 开发者模式回归：密码校验 / 持久化 / 监听通知。
import 'package:baiji_music/core/dev_mode.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await KvStore.ensureInit();
    await KvStore.instance.clear();
    await DevMode.instance.load();
    // 每个用例从关闭状态出发
    await DevMode.instance.setEnabled(false);
  });

  group('DevMode 密码', () {
    test('molan 正确，大小写与首尾空白不敏感', () {
      expect(DevMode.checkPassword('molan'), true);
      expect(DevMode.checkPassword('MOLAN'), true);
      expect(DevMode.checkPassword('  molan  '), true);
    });

    test('错误密码拒绝', () {
      expect(DevMode.checkPassword('molan1'), false);
      expect(DevMode.checkPassword(''), false);
      expect(DevMode.checkPassword('balan'), false);
    });
  });

  group('DevMode 开关', () {
    test('默认关闭', () {
      expect(DevMode.instance.enabled, false);
    });

    test('开启后持久化，重新 load 能恢复', () async {
      await DevMode.instance.setEnabled(true);
      expect(DevMode.instance.enabled, true);
      expect(KvStore.instance.getBool('dev_mode_enabled'), true);

      // 模拟重启：单例还在，重新 load 读盘
      await DevMode.instance.load();
      expect(DevMode.instance.enabled, true);

      await DevMode.instance.setEnabled(false);
      expect(KvStore.instance.getBool('dev_mode_enabled'), false);
      await DevMode.instance.load();
      expect(DevMode.instance.enabled, false);
    });

    test('重复设置同一值不通知', () async {
      var notified = 0;
      void listener() => notified++;
      DevMode.instance.addListener(listener);
      await DevMode.instance.setEnabled(true);
      await DevMode.instance.setEnabled(true); // 重复：不再通知
      DevMode.instance.removeListener(listener);
      expect(notified, 1);
      await DevMode.instance.setEnabled(false);
    });
  });
}
