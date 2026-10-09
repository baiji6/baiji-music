// 版本解析与比较的契约测试 —— 第 6 项「检查更新没反应」的两个真实根因：
// 1. tag 带后缀（如 v2.0.11-fix2）时旧实现 int.tryParse('11-fix2') 返回 null，
//    导致整条 release 被跳过，永远提示"已是最新"；
// 2. 位数不一致（2.0 vs 2.0.0）被误判为有新版本。
import 'package:baiji_music/core/update_checker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('版本比较', () {
    test('普通递增', () {
      expect(checkerDebugIsNewer('2.1.0', '2.0.11'), isTrue);
      expect(checkerDebugIsNewer('2.0.11', '2.1.0'), isFalse);
      expect(checkerDebugIsNewer('2.1.0', '2.1.0'), isFalse);
    });

    test('位数不一致时按 0 补齐，不误报', () {
      expect(checkerDebugIsNewer('2.0', '2.0.0'), isFalse,
          reason: '2.0 与 2.0.0 是同一版本');
      expect(checkerDebugIsNewer('2.0.1', '2.0'), isTrue);
    });

    test('tag 带后缀也能正确解析（v2.0.11-fix2 场景）', () {
      // 这是旧的 /releases/latest 查不到、解析也失败的典型 tag
      expect(checkerDebugParse('v2.0.11-fix2'), <int>[2, 0, 11]);
      expect(checkerDebugParse('2.0.11-fix2'), <int>[2, 0, 11]);
      expect(checkerDebugIsNewer('v2.0.11-fix2', '2.0.10'), isTrue);
    });

    test('构建号后缀被忽略', () {
      expect(checkerDebugParse('2.1.0+7'), <int>[2, 1, 0]);
      expect(checkerDebugIsNewer('2.1.0+7', '2.1.0'), isFalse);
    });

    test('大写 V 前缀与空白容忍', () {
      expect(checkerDebugParse(' V2.1.0 '), <int>[2, 1, 0]);
      expect(checkerDebugParse('  v2.1.0\n'), <int>[2, 1, 0]);
    });

    test('非法输入返回 null 而不是崩溃', () {
      expect(checkerDebugParse(''), isNull);
      expect(checkerDebugParse('nightly'), isNull);
      expect(checkerDebugParse('v'), isNull);
      expect(checkerDebugParse('2..1'), isNotNull,
          reason: '正则只吃到 2 就停，属于可接受的降级行为');
    });

    test('多段版本号逐位比较', () {
      expect(checkerDebugIsNewer('2.1.0.1', '2.1.0'), isTrue);
      expect(checkerDebugIsNewer('2.1.0', '2.1.0.1'), isFalse);
    });
  });

  group('更新提示文案', () {
    test('summary 在超长时截断并加省略号', () {
      final info = UpdateInfo(
        tag: 'v9.9.9',
        version: const <int>[9, 9, 9],
        url: 'https://example.com',
        body: 'a' * 500,
        name: 'v9.9.9',
      );
      final s = info.summary(200);
      expect(s.length, 201, reason: '200 个字符 + 一个省略号');
      expect(s.endsWith('…'), isTrue);
    });

    test('summary 不切断代理对（emoji）', () {
      final info = UpdateInfo(
        tag: 'v1',
        version: const <int>[1],
        url: 'u',
        body: '🎵' * 10,
        name: '',
      );
      final s = info.summary(3);
      expect(s, '🎵🎵🎵…');
    });

    test('短文本原样返回', () {
      final info = UpdateInfo(
        tag: 'v1',
        version: const <int>[1],
        url: 'u',
        body: '  修复若干问题  ',
        name: '',
      );
      expect(info.summary(), '修复若干问题');
    });
  });
}
