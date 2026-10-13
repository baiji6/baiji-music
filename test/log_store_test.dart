// v2.2.6 日志持久化回归。
//
// 旧版日志只活在内存环形缓冲里，每次打开软件都清空——用户闪退后
// 打开日志页一片空白。现在日志按天落盘（保留 7 天），启动回读当天。
import 'dart:io';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/log_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

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

void main() {
  late Directory fakeRoot;

  setUp(() async {
    fakeRoot = await Directory.systemTemp.createTemp('baiji_log_test');
    PathProviderPlatform.instance = FakePathProvider(fakeRoot.path);
    // 重置单例内部状态：LogStore 是进程级单例，每个用例都要全新落盘
    LogStore.instance.debugResetForTest();
    await LogStore.instance.init();
  });

  tearDown(() async {
    LogStore.instance.debugResetForTest();
    if (fakeRoot.existsSync()) await fakeRoot.delete(recursive: true);
  });

  group('LogStore 落盘', () {
    test('write + flushSync 后当天文件可回读', () async {
      LogStore.instance.write('第一行');
      LogStore.instance.write('第二行');
      LogStore.instance.flushSync();

      final back = await LogStore.instance.readToday();
      expect(back, ['第一行', '第二行']);
    });

    test('clearToday 清空当天文件', () async {
      LogStore.instance.write('待清理');
      LogStore.instance.flushSync();
      expect((await LogStore.instance.readToday()).isNotEmpty, true);

      await LogStore.instance.clearToday();
      expect(await LogStore.instance.readToday(), isEmpty);
    });

    test('保留 7 天内的文件，删除更早的', () async {
      final dir = Directory('${fakeRoot.path}${Platform.pathSeparator}logs');
      final now = DateTime.now();
      String stamp(int daysAgo) {
        final d = now.subtract(Duration(days: daysAgo));
        return '${d.year.toString().padLeft(4, '0')}'
            '${d.month.toString().padLeft(2, '0')}'
            '${d.day.toString().padLeft(2, '0')}';
      }

      final keep = File('${dir.path}${Platform.pathSeparator}baiji_${stamp(3)}.log');
      final old = File('${dir.path}${Platform.pathSeparator}baiji_${stamp(30)}.log');
      await keep.writeAsString('keep');
      await old.writeAsString('old');

      // 重新初始化触发清理
      LogStore.instance.debugResetForTest();
      await LogStore.instance.init();

      expect(keep.existsSync(), true);
      expect(old.existsSync(), false);
    });
  });

  group('AppLog 与文件联动', () {
    test('clear() 同时清掉当天文件（否则重启又回读回来）', () async {
      AppLog.instance.initFileSink();
      AppLog.i('Test', '一条日志');
      AppLog.instance.flushSync();
      expect(AppLog.instance.dump().isNotEmpty, true);

      AppLog.instance.clear();
      expect(AppLog.instance.dump(), isEmpty);
      expect(await LogStore.instance.readToday(), isEmpty);
    });

    test('initFileSink 回读当天历史，日志不再"每次打开就清空"', () async {
      LogStore.instance.write('10-13 12:00:00.000 INFO/历史 上一次运行的记录');
      LogStore.instance.flushSync();
      LogStore.instance.debugResetForTest();
      await LogStore.instance.init();

      await AppLog.instance.initFileSink();
      final dump = AppLog.instance.dump();
      expect(dump.any((l) => l.contains('上一次运行的记录')), true);
    });
  });
}
