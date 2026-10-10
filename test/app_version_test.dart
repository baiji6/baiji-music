// 版本号一致性测试。
//
// UI 里显示的版本来自 `AppVersion` 常量，而实际构建版本来自 pubspec.yaml。
// 两者一旦漂移（比如发版时只改了 pubspec），「关于」页就会显示错误版本，
// 而且没人会注意到。这里直接读 pubspec 做断言，把漂移挡在 CI 里。
import 'dart:io';

import 'package:baiji_music/core/app_version.dart';
import 'package:flutter_test/flutter_test.dart';

/// 从 pubspec.yaml 里取出 `version:` 的值。
String readPubspecVersion() {
  final f = File('pubspec.yaml');
  if (!f.existsSync()) {
    // 测试有可能从别的工作目录启动，往上找一层
    final fallback = File('../pubspec.yaml');
    if (!fallback.existsSync()) {
      throw StateError('找不到 pubspec.yaml，测试工作目录不对');
    }
    return _parse(fallback.readAsStringSync());
  }
  return _parse(f.readAsStringSync());
}

String _parse(String text) {
  for (final line in text.split('\n')) {
    final m = RegExp(r'^\s*version\s*:\s*(\S+)\s*$').firstMatch(line);
    if (m != null) return m.group(1)!;
  }
  throw StateError('pubspec.yaml 里没有 version 字段');
}

void main() {
  test('AppVersion 与 pubspec.yaml 的 version 一致', () {
    final pubspec = readPubspecVersion();
    // pubspec 允许 `2.2.0+7` 这种带构建号的写法，比较主版本号部分
    final core = pubspec.split('+').first;
    expect(
      AppVersion.current,
      core,
      reason: 'AppVersion.current 是 ${AppVersion.current}，'
          'pubspec.yaml 是 $core；请同步 lib/core/app_version.dart',
    );
  });

  test('版本号是合法的三段语义化版本', () {
    expect(
      RegExp(r'^\d+\.\d+\.\d+$').hasMatch(AppVersion.current),
      isTrue,
      reason: '版本号应为 x.y.z 形式，实际是 ${AppVersion.current}',
    );
  });

  test('展示文案包含版本号与渠道名', () {
    expect(AppVersion.display, contains('v${AppVersion.current}'));
    expect(AppVersion.display, contains(AppVersion.channel));
  });

  test('tagged 是 v 前缀的版本号（用于 git tag）', () {
    expect(AppVersion.tagged, 'v${AppVersion.current}');
    expect(AppVersion.tagged, startsWith('v'));
  });
}
