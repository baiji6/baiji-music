// 网易云 v1 未登录混合格式（JSON 制作信息头 + 经典 LRC 尾）解析回归。
// 数据来自真实接口响应（netease id=186016 快照）。
import 'dart:io';

import 'package:baiji_music/lyrics/lyric_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用真实网易云 v1 混合格式（JSON 头 + LRC 尾）验证新解析器。
void main() {
  test('netease 混合格式：JSON 头 + LRC 尾全解析', () {
    final raw = File('test/fixtures/lyrics/netease_hybrid_186016.txt')
        .readAsStringSync();
    final lyrics = LyricParser.parse(raw);
    // JSON 头 11 行 + LRC 尾 51 行（其中 [02:21.989] 是空正文占位行，跳过）= 61
    expect(lyrics.length, 61);
    // 制作信息行按 t 时间戳落在开头
    expect(lyrics[0].startMs, 0);
    expect(lyrics[0].text, contains('作词'));
    expect(lyrics[1].startMs, 1000);
    expect(lyrics[1].text, contains('作曲'));
    // LRC 尾从 28.950s 开始
    expect(lyrics[11].startMs, 28950);
    // 时间严格升序
    for (var i = 1; i < lyrics.length; i++) {
      expect(lyrics[i].startMs >= lyrics[i - 1].startMs, true);
    }
    // 未登录形态没有逐字数据
    expect(lyrics.hasWordTiming, false);
  });

  test('netease 混合格式：LRC 尾带增强逐字也应保留', () {
    const hybrid = '{"t":0,"c":[{"tx":"作词: "},{"tx":" someone"}]}\n'
        '[00:10.00]<00:10.00>你<00:10.50>好<00:11.00>啊';
    final lyrics = LyricParser.parse(hybrid);
    expect(lyrics.length, 2);
    expect(lyrics[0].text, '作词:  someone');
    expect(lyrics[1].isWordLevel, true);
    expect(lyrics[1].words.length, 3);
    expect(lyrics.hasWordTiming, true);
  });

  test('netease 混合格式：纯 JSON 头无 LRC 尾', () {
    const hybrid = '{"t":0,"c":[{"tx":"作词: "},{"tx":"周杰伦"}]}\n'
        '{"t":1000,"c":[{"tx":"作曲: "},{"tx":"周杰伦"}]}';
    final lyrics = LyricParser.parse(hybrid);
    expect(lyrics.length, 2);
    expect(lyrics[0].text, '作词: 周杰伦');
    expect(lyrics[0].endMs, 990); // 下一行 1000 - 10
    expect(lyrics[1].endMs, 3000); // 末行占位
  });

  test('普通 LRC 不受影响', () {
    const lrc = '[ti:晴天]\n[00:01.00]故事的小黄花\n[00:05.00]从出生那年就飘着';
    final lyrics = LyricParser.parse(lrc);
    expect(lyrics.length, 2);
    expect(lyrics[0].text, '故事的小黄花');
    expect(lyrics.hasWordTiming, false);
  });

  test('增强 LRC 不受影响', () {
    const lrc = '[00:01.00]<00:01.00>你<00:01.50>好';
    final lyrics = LyricParser.parse(lrc);
    expect(lyrics.length, 1);
    expect(lyrics[0].isWordLevel, true);
  });

  test('JSON 行损坏时跳过不崩溃', () {
    const hybrid = '{"t":0,"c":[{"tx":"作词"}]}\n'
        '{"t":bad json\n'
        '{"t":2000,"c":[{"tx":"作曲"}]}';
    final lyrics = LyricParser.parse(hybrid);
    expect(lyrics.length, 2);
    expect(lyrics[0].text, '作词');
    expect(lyrics[1].startMs, 2000);
  });

  test('decode 辅助：records 记录', () {
    // 覆盖 jsonDecode 路径的防御分支
    const weird = '{"t":"notnum","c":[]}\n{"t":1,"c":"notlist"}\n{"t":2,"c":[]}';
    final lyrics = LyricParser.parse(weird);
    expect(lyrics.isEmpty, true);
  });
}
