// 网易云 yrc 字段回归（v2.2.9-fix4）：
// yrc 的整体形态是「JSON 制作信息头 + YRC 逐字尾」，旧混合分支把 YRC 尾
// 交给 _parseLrc（只认 [mm:ss.xx]）导致整段逐字歌词被丢弃——
// 用户看到的就是「网易云逐字歌词直接不显示，只剩作词/作曲几行」。
// fixture 为 2026-10-16 对 /api/song/lyric/v1 的实测响应（未登录也有 yrc）。
import 'dart:convert';
import 'dart:io';

import 'package:baiji_music/lyrics/lyric_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('网易云 yrc：JSON 头 + YRC 尾必须解析出逐字歌词', () {
    final raw = jsonDecode(
        File('test/fixtures/lyrics/netease_api_422104138.json').readAsStringSync());
    final yrc = (raw['yrc'] as Map<String, dynamic>)['lyric'] as String;

    final ly = LyricParser.parse(yrc);

    // 3 行制作信息 + 55 行 YRC 逐字行
    expect(ly.isEmpty, isFalse, reason: 'yrc 解析结果不能为空');
    expect(ly.lines.length, greaterThan(50),
        reason: 'YRC 尾不能被丢弃（旧 bug：只剩 3 行制作信息）');
    expect(ly.hasWordTiming, isTrue, reason: 'yrc 必须解析出词级时间轴');

    final wordLines = ly.lines.where((l) => l.isWordLevel).length;
    expect(wordLines, greaterThan(50),
        reason: '绝大多数行应是词级歌词，实际 $wordLines');

    // 制作信息行应保留（JSON 头），且排在最早的时间点
    final first = ly.lines.first;
    expect(first.text, contains('作词'),
        reason: 'JSON 制作信息头应保留在结果里');

    // 抽查第一行 YRC：「然后呢」三个字，词级时间单调递增
    final thenLine = ly.lines.firstWhere(
      (l) => l.text == '然后呢',
      orElse: () => ly.lines[0],
    );
    expect(thenLine.isWordLevel, isTrue);
    expect(thenLine.words.map((w) => w.text).join(), '然后呢');
    for (var i = 1; i < thenLine.words.length; i++) {
      expect(thenLine.words[i].startMs,
          greaterThanOrEqualTo(thenLine.words[i - 1].startMs));
    }
  });

  test('网易云 lrc：JSON 头 + 经典 LRC 尾（未登录回退路径）', () {
    final raw = jsonDecode(
        File('test/fixtures/lyrics/netease_api_422104138.json').readAsStringSync());
    final lrc = (raw['lrc'] as Map<String, dynamic>)['lyric'] as String;

    final ly = LyricParser.parse(lrc);

    expect(ly.isEmpty, isFalse);
    expect(ly.hasWordTiming, isFalse, reason: 'lrc 字段是经典逐行格式');
    expect(ly.lines.length, greaterThan(20));
    // LRC 尾行应原样解析出来
    expect(ly.lines.any((l) => l.text.contains('后来的我们')), isTrue);
  });
}
