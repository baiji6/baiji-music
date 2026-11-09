import 'dart:io';

import 'package:baiji_music/lx/lx_source.dart';
import 'package:baiji_music/lx/lx_update_checker.dart';
import 'package:baiji_music/lx/lx_version.dart';
import 'package:flutter_test/flutter_test.dart';

const String _scriptV1 = '''
// ==UserScript==
// @name 测试音源
// @version 1.0.0
// @author tester
// @homepage https://github.com/example/repo
// @description 演示用网关源
// ==/UserScript==
const { EVENT_NAMES, on, send, request } = globalThis.lx
send(EVENT_NAMES.inited, { status: true, sources: { kw: { name: 'kw', type: 'music', actions: ['musicUrl'], qualitys: ['128k', 'flac'] } } })
on(EVENT_NAMES.request, async ({ action, source, info }) => { return 'http://cdn/' + info.type })
''';

final String _scriptV2 = _scriptV1.replaceAll('1.0.0', '1.1.0');

void main() {
  group('SourceVersion 版本比较', () {
    test('数字段逐位比较、位数补 0', () {
      expect(SourceVersion.isNewer('1.1.0', '1.0.0'), isTrue);
      expect(SourceVersion.isNewer('1.0.1', '1.0'), isTrue);
      expect(SourceVersion.isNewer('1.0.0', '1.0'), isFalse);
      expect(SourceVersion.compare('2.3.6', '2.3.6'), 0);
    });

    test('v 前缀 / 纯数字版本 / -fix 后缀', () {
      expect(SourceVersion.isNewer('v28', 'v27'), isTrue);
      expect(SourceVersion.isNewer('261108', '261107'), isTrue);
      expect(SourceVersion.isNewer('v27', '27'), isFalse);
      expect(SourceVersion.isNewer('2.3.6-fix2', '2.3.6-fix1'), isTrue);
      expect(SourceVersion.isNewer('2.3.6-fix1', '2.3.6'), isTrue);
    });

    test('无法解析时退化为字典序', () {
      expect(SourceVersion.compare('beta', 'alpha') > 0, isTrue);
    });
  });

  group('LxSource.parseHeader', () {
    test('解析头信息且 URL 不被截断', () {
      final m = LxSource.parseHeader(_scriptV1);
      expect(m['name'], '测试音源');
      expect(m['version'], '1.0.0');
      expect(m['author'], 'tester');
      expect(m['homepage'], 'https://github.com/example/repo');
      expect(m['description'], '演示用网关源');
    });

    test('fromScript 从 URL 导入时 updateUrl 默认等于导入链接', () {
      final s = LxSource.fromScript(_scriptV1,
          sourceUrl: 'https://c.example/script?key=abc');
      expect(s.name, '测试音源');
      expect(s.version, '1.0.0');
      expect(s.updateUrl, 'https://c.example/script?key=abc');
      expect(s.canCheckUpdate, isTrue);
    });

    test('文件导入时读取 @updateURL 作为默认更新地址', () {
      final withUpdate = _scriptV1.replaceFirst('// @description',
          '// @updateURL https://raw.example/src.js\n// @description');
      final s = LxSource.fromScript(withUpdate);
      expect(s.updateUrl, 'https://raw.example/src.js');
    });
  });

  group('LxSourceRepo 持久化', () {
    late Directory temp;
    late LxSourceRepo repo;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('lx_repo_test');
      repo = LxSourceRepo(directory: () async => temp);
    });
    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('导入 / 读取脚本 / 更新 / 删除', () async {
      final s = await repo.add(
          script: _scriptV1, sourceUrl: 'https://example/src.js');
      expect((await repo.all()).length, 1);
      expect(await repo.readScript(s), contains('@version 1.0.0'));

      await repo.update(s.copyWith(version: '1.0.1', enabled: false));
      final all = await repo.all();
      expect(all.first.version, '1.0.1');
      expect(all.first.enabled, isFalse);
      expect(await repo.enabled(), isEmpty);

      await repo.remove(s.id);
      expect(await repo.all(), isEmpty);
    });

    test('全局自动更新开关持久化', () async {
      expect(await repo.globalAutoUpdate(), isFalse);
      await repo.setGlobalAutoUpdate(true);
      expect(await repo.globalAutoUpdate(), isTrue);
    });
  });

  group('LxUpdateChecker 检测更新 / 自动更新', () {
    late Directory temp;
    late LxSourceRepo repo;
    late LxUpdateChecker checker;
    var reloadCalls = 0;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('lx_update_test');
      repo = LxSourceRepo(directory: () async => temp);
      reloadCalls = 0;
      checker = LxUpdateChecker(
        repo: repo,
        fetch: (String url) async => _scriptV2,
        onSourcesChanged: () async {
          reloadCalls++;
        },
      );
    });
    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('只检测不自动替换（开关关闭）', () async {
      final s = await repo.add(
          script: _scriptV1, sourceUrl: 'https://example/src.js');
      final outcomes = await checker.checkAll();
      expect(outcomes.length, 1);
      expect(outcomes.first.hasUpdate, isTrue);
      expect(outcomes.first.latestVersion, '1.1.0');
      expect(outcomes.first.applied, isFalse);
      // 脚本未被替换，但元数据记下了可更新版本与检测时间
      expect(await repo.readScript(s), contains('@version 1.0.0'));
      final stored = (await repo.all()).first;
      expect(stored.latestVersion, '1.1.0');
      expect(stored.lastCheckedAt, greaterThan(0));
      expect(reloadCalls, 0);
    });

    test('全局开关开启后检测即自动替换并重载', () async {
      final s = await repo.add(
          script: _scriptV1, sourceUrl: 'https://example/src.js');
      await repo.setGlobalAutoUpdate(true);
      final outcomes = await checker.checkAll();
      expect(outcomes.first.applied, isTrue);
      expect(await repo.readScript(s), contains('@version 1.1.0'));
      expect((await repo.all()).first.version, '1.1.0');
      expect(reloadCalls, 1);
      // 再检测一次应无更新（已是最新）
      final again = await checker.checkAll();
      expect(again.first.hasUpdate, isFalse);
    });

    test('单源 autoUpdate 也能触发自动更新', () async {
      final s = await repo.add(
          script: _scriptV1, sourceUrl: 'https://example/src.js');
      await repo.update(s.copyWith(autoUpdate: true));
      final outcomes = await checker.checkAll();
      expect(outcomes.first.applied, isTrue);
    });

    test('respectSwitch=false 时即使开关开也只检测', () async {
      final s = await repo.add(
          script: _scriptV1, sourceUrl: 'https://example/src.js');
      await repo.setGlobalAutoUpdate(true);
      final outcomes = await checker.checkAll(respectSwitch: false);
      expect(outcomes.first.hasUpdate, isTrue);
      expect(outcomes.first.applied, isFalse);
      expect(await repo.readScript(s), contains('@version 1.0.0'));
    });

    test('无更新地址 / 远端无版本头时给出明确错误', () async {
      final s0 = await repo.add(script: _scriptV1);
      expect(s0.canCheckUpdate, isFalse);
      final noUrl = await checker.checkOne(s0);
      expect(noUrl.isError, isTrue);
      expect(noUrl.error, contains('未设置更新地址'));

      final noVer = LxUpdateChecker(
        repo: repo,
        fetch: (String url) async => 'hello world',
      );
      final s1 = await repo.add(
          script: _scriptV1, sourceUrl: 'https://example/src.js');
      final bad = await noVer.checkOne(s1);
      expect(bad.isError, isTrue);
      expect(bad.error, contains('@version'));
    });
  });
}
