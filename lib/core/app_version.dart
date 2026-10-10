/// 应用版本号（UI 展示用）。
///
/// **必须与 `pubspec.yaml` 的 `version` 字段保持一致**——
/// `test/app_version_test.dart` 会读取 pubspec 做断言，
/// 忘记同步时 CI 会直接失败，避免「关于」页显示的版本落后于实际版本。
///
/// 真正的构建版本（含构建号）由 `package_info_plus` 在运行时提供，
/// 更新检查走 `UpdateChecker`，不用这里的常量。
class AppVersion {
  AppVersion._();

  /// 语义化版本，不含 `v` 前缀。
  static const String current = '2.2.2';

  /// 版本后缀说明。
  static const String channel = '跨平台重构版';

  /// 「v2.2.0 · 跨平台重构版」这类完整展示文案。
  static String get display => 'v$current · $channel';

  /// 仅版本号部分，如 `v2.2.0`。
  static String get tagged => 'v$current';
}
