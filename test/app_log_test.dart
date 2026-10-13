// v2.2.8 日志模块重构回归：结构化条目、崩溃转储噪声识别、
// snapshot 过滤（级别 / 关键词 / 隐藏纯转储）。
import 'package:baiji_music/core/app_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    AppLog.instance.clear();
  });

  group('AppLog 结构化条目', () {
    test('log() 产出带 level/tag/message/raw 的条目', () {
      AppLog.i('TestTag', '你好');
      final e = AppLog.instance.entries;
      expect(e, hasLength(1));
      expect(e.first.level, AppLog.info);
      expect(e.first.tag, 'TestTag');
      expect(e.first.message, '你好');
      expect(e.first.raw, contains('INFO/TestTag 你好'));
    });

    test('error 参数拼进 message', () {
      AppLog.e('T', '炸了', StateError('x'));
      // StateError('x').toString() = 'Bad state: x'
      expect(AppLog.instance.entries.single.message, contains('err=Bad state: x'));
    });

    test('级别开关关闭时丢弃', () {
      AppLog.instance.setEnabled(AppLog.trace, false);
      AppLog.t('T', '不应出现');
      expect(AppLog.instance.entries, isEmpty);
    });
  });

  group('崩溃转储噪声识别', () {
    test('tombstone / backtrace 行被计数', () {
      const dump = '*** *** ***\n'
          'Build fingerprint: x/y/z\n'
          'pid: 1234, tid: 5678  >>> app <<<\n'
          '#00 abs 0000000000001234 pc 0000000000005678\n'
          '#01 pc 0000000000009abc  /data/app/lib.so\n';
      expect(AppLog.countNoiseLines(dump), 5);
    });

    test('普通消息零噪声', () {
      expect(AppLog.countNoiseLines('一切正常'), 0);
      expect(AppLog.countNoiseLines('#12 不是转储（无 abs/pc 后缀）'), 0);
    });

    test('含转储的日志条目被标记 noiseLines', () {
      AppLog.f('Platform', '未捕获的平台错误',
          'tombstone:\n*** *** ***\n#00 abs 0000 pc 1111');
      final e = AppLog.instance.entries.single;
      expect(e.level, AppLog.fatal);
      expect(e.hasNoise, isTrue);
      expect(e.noiseLines, 2);
    });
  });

  group('snapshot 过滤', () {
    setUp(() {
      AppLog.d('T', 'debug 消息');
      AppLog.i('Player', '播放开始');
      AppLog.w('Net', '网络超时');
      AppLog.f('Platform', '崩溃\n*** *** ***\n#00 abs 1 pc 2');
    });

    test('按级别下限过滤', () {
      expect(AppLog.instance.snapshot(minLevel: AppLog.warn), hasLength(2));
      expect(AppLog.instance.snapshot(minLevel: AppLog.trace), hasLength(4));
    });

    test('关键词匹配 tag 与消息', () {
      expect(AppLog.instance.snapshot(keyword: 'player'), hasLength(1));
      expect(AppLog.instance.snapshot(keyword: '超时'), hasLength(1));
      expect(AppLog.instance.snapshot(keyword: '不存在的词'), isEmpty);
    });

    test('hideNoise 隐藏纯转储条目，保留有正文的条目', () {
      // 整条都是转储（无正文）的条目
      AppLog.f('Dump', '*** *** ***\n#00 abs 1 pc 2');
      final all = AppLog.instance.snapshot(minLevel: AppLog.trace);
      expect(all.where((e) => e.hasNoise), hasLength(2));

      final hidden = AppLog.instance.snapshot(
        minLevel: AppLog.trace,
        hideNoise: true,
      );
      // 「崩溃\n***…」有正文行，保留；纯转储的 Dump 条目被隐藏。
      expect(hidden.where((e) => e.hasNoise), hasLength(1));
      expect(hidden.where((e) => e.tag == 'Dump'), isEmpty);
      // 其他条目不受影响
      expect(hidden, hasLength(all.length - 1));
    });

    test('dump() 仍是完整原始行（导出格式不变）', () {
      final dump = AppLog.instance.dump();
      expect(dump, hasLength(4));
      expect(dump.last, contains('FATAL/Platform'));
      expect(dump.last, contains('#00 abs 1 pc 2'));
    });
  });
}
