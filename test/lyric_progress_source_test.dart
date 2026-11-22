// 歌词进度源 changes 流契约测试（v2.6.2-fix2 卡顿修复）。
//
// 根因回归：v2.6.2 把播放器的 onPositionChanged（逐帧）转发到引擎 changes，
// 与引擎自带 Ticker 形成双重采样 → 每帧 rebuild/configure → 歌词卡顿抖动。
// fix1? 不——fix2 改为 changes 只携带离散事件（playState / seek）。
// 这里锁定：只有离散流能触发 changes，且签名不含 position 流（类型级保证）。
import 'dart:async';

import 'package:baiji_music/ui/widgets/amll_lyrics_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playState 事件会转发到 changes', () async {
    final play = StreamController<void>.broadcast();
    final seek = StreamController<void>.broadcast();
    final changes = lyricChangesStream(playState: play.stream, seek: seek.stream);
    final got = <int>[];
    final sub = changes.listen((_) => got.add(1));

    play.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(got.length, 1);

    await sub.cancel();
    await play.close();
    await seek.close();
  });

  test('seek 事件会转发到 changes', () async {
    final play = StreamController<void>.broadcast();
    final seek = StreamController<void>.broadcast();
    final changes = lyricChangesStream(playState: play.stream, seek: seek.stream);
    final got = <int>[];
    final sub = changes.listen((_) => got.add(1));

    seek.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(got.length, 1);

    await sub.cancel();
    await play.close();
    await seek.close();
  });

  test('取消订阅后离散事件不再转发（无泄漏）', () async {
    final play = StreamController<void>.broadcast();
    final seek = StreamController<void>.broadcast();
    final changes = lyricChangesStream(playState: play.stream, seek: seek.stream);
    final got = <int>[];
    final sub = changes.listen((_) => got.add(1));

    await sub.cancel();
    play.add(null);
    seek.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(got, isEmpty);

    await play.close();
    await seek.close();
  });
}
