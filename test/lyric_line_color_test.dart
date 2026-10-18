// 歌词行颜色三态（AMLL / 倾听语义）回归测试。
//
// v2.3.0-fix2 用户反馈「逐字歌词渲染成了逐行歌词」：根因是非当前行
// 统一暗灰，唱过的行瞬间熄灭，满屏只有当前行在动——逐字的时间维度
// 轨迹不可见。修复：已唱行保留已唱色（lyricLineColor 三态）。
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/ui/widgets/karaoke_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _unsung = Color(0xFFF2F5FF);
const _sung = Color(0xFFA8F685);
const _inactive = Color(0xFF5A6686);

LyricLine _line(int start, int end, {List<LyricWord>? words}) => LyricLine(
      startMs: start,
      endMs: end,
      text: '测试行',
      words: words ??
          [
            LyricWord(startMs: start, endMs: end, text: '测试行'),
          ],
    );

void main() {
  group('lyricLineColor 三态', () {
    test('当前行返回未唱色（行内明暗交给 KaraokeLine 遮罩）', () {
      final c = lyricLineColor(
        line: _line(1000, 2000),
        isActive: true,
        positionMs: 1500,
        unsung: _unsung,
        sung: _sung,
        inactive: _inactive,
      );
      expect(c, _unsung);
    });

    test('已唱行（endMs <= pos）保留已唱色', () {
      final c = lyricLineColor(
        line: _line(1000, 2000),
        isActive: false,
        positionMs: 2000,
        unsung: _unsung,
        sung: _sung,
        inactive: _inactive,
      );
      expect(c, _sung);
    });

    test('已唱行边界：pos 超过 endMs 很多仍保持已唱色', () {
      final c = lyricLineColor(
        line: _line(1000, 2000),
        isActive: false,
        positionMs: 99000,
        unsung: _unsung,
        sung: _sung,
        inactive: _inactive,
      );
      expect(c, _sung);
    });

    test('未唱行（startMs > pos）返回暗灰', () {
      final c = lyricLineColor(
        line: _line(1000, 2000),
        isActive: false,
        positionMs: 500,
        unsung: _unsung,
        sung: _sung,
        inactive: _inactive,
      );
      expect(c, _inactive);
    });

    test('行内演唱中但非当前行（理论上不出现）按未唱处理', () {
      final c = lyricLineColor(
        line: _line(1000, 2000),
        isActive: false,
        positionMs: 1500,
        unsung: _unsung,
        sung: _sung,
        inactive: _inactive,
      );
      expect(c, _inactive);
    });

    test('endMs <= 0（信息行无行止时间）按未唱处理', () {
      final c = lyricLineColor(
        line: LyricLine(startMs: 0, endMs: 0, text: '作词: 某人'),
        isActive: false,
        positionMs: 99000,
        unsung: _unsung,
        sung: _sung,
        inactive: _inactive,
      );
      expect(c, _inactive);
    });

    test('三态互不相同：层次可辨（不会糊成一色）', () {
      final line = _line(1000, 2000);
      final active = lyricLineColor(
          line: line, isActive: true, positionMs: 1500,
          unsung: _unsung, sung: _sung, inactive: _inactive);
      final played = lyricLineColor(
          line: line, isActive: false, positionMs: 3000,
          unsung: _unsung, sung: _sung, inactive: _inactive);
      final pending = lyricLineColor(
          line: line, isActive: false, positionMs: 500,
          unsung: _unsung, sung: _sung, inactive: _inactive);
      expect({active, played, pending}.length, 3);
    });
  });
}
