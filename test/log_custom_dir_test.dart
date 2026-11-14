// v2.5.8-fix1 日志自定义保存位置：目录选择 / 回落 / 键名冲突。
//
// 用户希望能自己挑日志目录（比如导出到 SD 卡上，方便用文件管理器抓日志
// 排查问题）。这里锁三件事：
// 1. 自定义目录能存下来、也能读回来；
// 2. 自定义目录不可用时静默回落到默认目录，**日志功能不能整体失效**；
// 3. 切换目录只影响之后的写入，旧文件留在原处（不迁移）。
//
// 另外校验 KvStore 键名不与现有键冲突——撞键意味着两个功能互相覆盖
// 对方的设置，排查起来极其费劲。
import 'dart:io';

import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/log_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 把 path_provider 的所有路径都指到同一个临时目录（test 环境无平台实现）。
class FakePathProvider extends PathProviderPlatform {
  FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getExternalStoragePath() async => root;

  @override
  Future<String?> getDownloadsPath() async => root;
}

/// 收集 lib/ 下所有 .dart 源文件（测试可能从别的工作目录启动）。
List<File> libSources() {
  for (final p in ['lib', '../lib']) {
    final dir = Directory(p);
    if (!dir.existsSync()) continue;
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
  }
  throw StateError('找不到 lib 目录，测试工作目录不对');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  late Directory fakeRoot;

  setUp(() async {
    fakeRoot = await Directory.systemTemp.createTemp('baiji_logdir_test');
    PathProviderPlatform.instance = FakePathProvider(fakeRoot.path);
    // KvStore 是进程级单例：统一清空重来（setMockInitialValues 对已创建
    // 的实例无效）。
    await KvStore.ensureInit();
    await KvStore.instance.clear();
    LogStore.instance.debugResetForTest();
    // 真实启动流程里 main() 会先初始化日志落盘（AppLog.initFileSink →
    // LogStore.init），这里保持一致，后续用例拿到的"当前目录"才是真值。
    await LogStore.instance.init();
  });

  tearDown(() async {
    LogStore.instance.debugResetForTest();
    if (fakeRoot.existsSync()) await fakeRoot.delete(recursive: true);
  });

  group('自定义目录的读写', () {
    test('默认没有自定义目录', () {
      expect(LogStore.customDir, isNull);
    });

    test('setCustomDir 持久化，customDir 能读回来', () async {
      final dir = Directory(
          '${fakeRoot.path}${Platform.pathSeparator}custom_logs');
      await dir.create(recursive: true);

      final effective = await LogStore.instance.setCustomDir(dir.path);

      expect(LogStore.customDir, dir.path);
      // KvStore 里确实落了盘（换进程/重启后仍在）。
      expect(KvStore.instance.getString(LogStore.customDirKey), dir.path);
      // 生效目录就是刚选的那个。
      expect(effective, dir.path);
      expect(LogStore.instance.currentDirPath, dir.path);
    });

    test('setCustomDir(null) 清除自定义，恢复默认目录', () async {
      final dir = Directory(
          '${fakeRoot.path}${Platform.pathSeparator}custom_logs');
      await dir.create(recursive: true);
      await LogStore.instance.setCustomDir(dir.path);
      expect(LogStore.customDir, isNotNull);

      await LogStore.instance.setCustomDir(null);

      expect(LogStore.customDir, isNull);
      expect(KvStore.instance.getString(LogStore.customDirKey), isNull);
      // 回到默认目录（应用支持目录下的 logs 子目录）。
      final def = await LogStore.defaultDirPath();
      expect(LogStore.instance.currentDirPath, def);
    });

    test('空串等价于 null（恢复默认）', () async {
      await LogStore.instance.setCustomDir('   ');
      expect(LogStore.customDir, isNull);
      expect(KvStore.instance.getString(LogStore.customDirKey), isNull);
    });

    test('目录写不进去时不落盘（不制造"设置成功"的假象）', () async {
      // 用一个「父路径是普通文件」的目录：建不出来，必然不可写。
      final blocker = File(
          '${fakeRoot.path}${Platform.pathSeparator}blocker_file');
      await blocker.writeAsString('x');
      final bad = '${blocker.path}${Platform.pathSeparator}sub';

      final effective = await LogStore.instance.setCustomDir(bad);

      expect(LogStore.customDir, isNull);
      expect(KvStore.instance.getString(LogStore.customDirKey), isNull);
      // 仍然用原来的（默认）目录，不影响日志功能。
      final def = await LogStore.defaultDirPath();
      expect(effective, def);
    });
  });

  group('自定义目录不可用时回落', () {
    test('init() 优先使用可写的自定义目录', () async {
      final dir = Directory(
          '${fakeRoot.path}${Platform.pathSeparator}custom_logs');
      await dir.create(recursive: true);
      await KvStore.instance
          .setString(LogStore.customDirKey, dir.path);

      LogStore.instance.debugResetForTest();
      await LogStore.instance.init();

      expect(LogStore.instance.currentDirPath, dir.path);
      expect(LogStore.instance.fallbackNote, isNull);
      expect(LogStore.instance.isActive, isTrue);
    });

    test('自定义目录不存在 → 静默回落到默认目录，日志功能不失效', () async {
      // 模拟 SD 卡被拔：路径还在配置里，但目录已经不存在了。
      final missing =
          '${fakeRoot.path}${Platform.pathSeparator}sdcard_logs';
      await KvStore.instance.setString(LogStore.customDirKey, missing);

      LogStore.instance.debugResetForTest();
      await LogStore.instance.init();

      final def = await LogStore.defaultDirPath();
      expect(LogStore.instance.currentDirPath, def);
      // 回落原因留在 fallbackNote 里，供上层记一条 warn。
      expect(LogStore.instance.fallbackNote, contains('不可用'));
      // 关键：日志功能没有因此挂掉。
      expect(LogStore.instance.isActive, isTrue);
      LogStore.instance.write('回落之后照样能写');
      LogStore.instance.flushSync();
      expect(await LogStore.instance.readToday(), contains('回落之后照样能写'));
    });

    test('自定义目录不可写 → 静默回落到默认目录', () async {
      // 父路径是普通文件，目录建不出来也写不进去。
      final blocker = File(
          '${fakeRoot.path}${Platform.pathSeparator}blocker_file');
      await blocker.writeAsString('x');
      await KvStore.instance.setString(LogStore.customDirKey,
          '${blocker.path}${Platform.pathSeparator}sub');

      LogStore.instance.debugResetForTest();
      await LogStore.instance.init();

      final def = await LogStore.defaultDirPath();
      expect(LogStore.instance.currentDirPath, def);
      expect(LogStore.instance.fallbackNote, isNotNull);
      expect(LogStore.instance.isActive, isTrue);
    });
  });

  group('切换目录只影响之后的写入', () {
    test('旧日志留在旧目录，新日志写进新目录（不迁移）', () async {
      final oldDir = Directory(
          '${fakeRoot.path}${Platform.pathSeparator}old_logs');
      await oldDir.create(recursive: true);
      final newDir = Directory(
          '${fakeRoot.path}${Platform.pathSeparator}new_logs');
      await newDir.create(recursive: true);

      // 先用旧目录写一条。
      await LogStore.instance.setCustomDir(oldDir.path);
      LogStore.instance.write('切换前的日志');
      LogStore.instance.flushSync();
      final oldFile = File('${oldDir.path}${Platform.pathSeparator}'
          'baiji_${_stamp(DateTime.now())}.log');
      expect(oldFile.existsSync(), isTrue);
      expect(oldFile.readAsStringSync(), contains('切换前的日志'));

      // 切到新目录。
      await LogStore.instance.setCustomDir(newDir.path);
      LogStore.instance.write('切换后的日志');
      LogStore.instance.flushSync();

      final newFile = File('${newDir.path}${Platform.pathSeparator}'
          'baiji_${_stamp(DateTime.now())}.log');
      expect(newFile.existsSync(), isTrue);
      expect(newFile.readAsStringSync(), contains('切换后的日志'));
      // 旧文件原地不动：既没被搬走，也没被追加新内容。
      expect(oldFile.readAsStringSync(), contains('切换前的日志'));
      expect(oldFile.readAsStringSync(), isNot(contains('切换后的日志')));
    });

    test('切回默认目录后继续写默认目录', () async {
      final customDir = Directory(
          '${fakeRoot.path}${Platform.pathSeparator}custom_logs');
      await customDir.create(recursive: true);
      await LogStore.instance.setCustomDir(customDir.path);
      expect(LogStore.instance.currentDirPath, customDir.path);

      await LogStore.instance.setCustomDir(null);

      final def = await LogStore.defaultDirPath();
      expect(LogStore.instance.currentDirPath, def);
      LogStore.instance.write('回到默认目录');
      LogStore.instance.flushSync();
      final defFile = File('${def!}${Platform.pathSeparator}'
          'baiji_${_stamp(DateTime.now())}.log');
      expect(defFile.existsSync(), isTrue);
      expect(defFile.readAsStringSync(), contains('回到默认目录'));
    });
  });

  group('KvStore 键名不冲突', () {
    test('键名常量存在且稳定', () {
      expect(LogStore.customDirKey, isNotEmpty);
      expect(LogStore.customDirKey, 'log_custom_dir');
    });

    test('该键名在整个 lib/ 里只有 log_store.dart 一处定义', () {
      // 撞键意味着两个功能互相覆盖对方的设置——用户改了 A 结果 B 变了。
      // 这里扫全量源码，出现第二次就说明有人复用了同一个字符串。
      final hits = <String>[];
      for (final f in libSources()) {
        if (f.readAsStringSync().contains("'${LogStore.customDirKey}'")) {
          hits.add(f.path);
        }
      }
      expect(
        hits.length,
        1,
        reason: '键名 ${LogStore.customDirKey} 出现在多个文件里：$hits',
      );
      expect(hits.single, contains('log_store.dart'));
    });

    test('与现有 KvStore 键名集合无交集', () {
      // 把 lib/ 下所有 KvStore 键名常量与直接字面量都收集起来比对。
      final keys = <String>{};
      final keyConstRe = RegExp(
          r'''(?:static\s+)?const\s+String\s+_\w+\s*=\s*'([^']+)' ''');
      final directRe = RegExp(r'''KvStore\.instance\.\w+\(\s*'([^']+)' ''');
      for (final f in libSources()) {
        final text = f.readAsStringSync();
        for (final m in keyConstRe.allMatches(text)) {
          keys.add(m.group(1)!);
        }
        for (final m in directRe.allMatches(text)) {
          keys.add(m.group(1)!);
        }
      }
      expect(
        keys.contains(LogStore.customDirKey),
        isFalse,
        reason: '键名 ${LogStore.customDirKey} 与现有键名冲突',
      );
    });
  });
}

/// `baiji_YYYYMMDD.log` 里的日期戳。
String _stamp(DateTime d) {
  return '${d.year.toString().padLeft(4, '0')}'
      '${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}';
}
