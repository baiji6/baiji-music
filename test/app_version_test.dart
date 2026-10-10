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
    //允许 `-fix1` 这类预发布后缀（2.2.2-fix1 形式），
    // 但主体必须严格是 x.y.z 三段。
    expect(
      RegExp(r'^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$')
          .hasMatch(AppVersion.current),
      isTrue,
      reason: '版本号应为 x.y.z 形式（可带 -后缀），实际是 ${AppVersion.current}',
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

  group('CHANGELOG.md 同步（自 v2.2.1 起 Release 正文取自这里）', () {
    /// 找到 CHANGELOG.md，测试可能从别的工作目录启动。
    File changelogFile() {
      for (final p in ['CHANGELOG.md', '../CHANGELOG.md']) {
        final f = File(p);
        if (f.existsSync()) return f;
      }
      throw StateError('找不到 CHANGELOG.md');
    }

    test('存在当前版本的条目，CI 才能生成 Release 更新日志', () {
      final text = changelogFile().readAsStringSync();
      final v = AppVersion.current;
      final pattern = RegExp('^##\\s+${RegExp.escape(v)}\\s*\$', multiLine: true);
      expect(
        pattern.hasMatch(text),
        isTrue,
        reason: 'CHANGELOG.md 里没有 `## $v` 这一节；'
            'CI 的 Extract changelog 步骤会失败，Release 发布不出去',
      );
    });

    test('当前版本的条目不是空的', () {
      final text = changelogFile().readAsStringSync();
      final re = RegExp(
        r'^##\s+' + RegExp.escape(AppVersion.current) + r'\s*$(.+?)(?=^##\s|\z)',
        multiLine: true,
        dotAll: true,
      );
      final m = re.firstMatch(text);
      expect(m, isNotNull);
      // 去掉标题行后至少要有实际内容（列表或小节）
      expect(
        m!.group(1)!.trim().length,
        greaterThan(20),
        reason: 'CHANGELOG.md 的 ${AppVersion.current} 条目几乎是空的',
      );
    });

    test('当前版本号在 CHANGELOG 里出现（防止改了 tag 却忘了写日志）', () {
      final text = changelogFile().readAsStringSync();
      expect(text, contains(AppVersion.current));
    });
  });
}
