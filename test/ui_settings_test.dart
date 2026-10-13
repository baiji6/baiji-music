// v2.2.6 全局界面圆角回归：默认值 / 持久化 / 越界钳制 / 通知。
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/ui_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await KvStore.ensureInit();
    await KvStore.instance.clear();
    await UiSettings.instance.load();
  });

  group('UiSettings 界面圆角', () {
    test('默认 16', () {
      expect(UiSettings.instance.cornerRadius, 16.0);
    });

    test('设置后持久化，重新 load 恢复', () async {
      await UiSettings.instance.setCornerRadius(24);
      expect(UiSettings.instance.cornerRadius, 24.0);
      expect(KvStore.instance.getDouble('ui:corner_radius'), 24.0);

      await UiSettings.instance.load();
      expect(UiSettings.instance.cornerRadius, 24.0);

      await UiSettings.instance.resetCorner();
      expect(UiSettings.instance.cornerRadius, UiSettings.defaultCorner);
      await UiSettings.instance.load();
      expect(UiSettings.instance.cornerRadius, 16.0);
    });

    test('越界值钳制到 [8, 28]', () async {
      await UiSettings.instance.setCornerRadius(0);
      expect(UiSettings.instance.cornerRadius, UiSettings.minCorner);
      await UiSettings.instance.setCornerRadius(999);
      expect(UiSettings.instance.cornerRadius, UiSettings.maxCorner);
    });

    test('重复设置同一值不通知', () async {
      var notified = 0;
      void listener() => notified++;
      UiSettings.instance.addListener(listener);
      await UiSettings.instance.setCornerRadius(20);
      await UiSettings.instance.setCornerRadius(20);
      UiSettings.instance.removeListener(listener);
      expect(notified, 1);
    });
  });
}
