// 歌词视图兼容门面（v2.6.3）。
//
// v2.6.3 起歌词渲染改为自研轻量引擎 LiteLyricsView（BaiMusic 架构），
// 取代 flutter_lyric（AMLL）引擎。本文件保留旧路径的符号，避免调用点与
// 测试大规模改动：
//   - AmllLyricsView          → 指向 LiteLyricsView 的 typedef
//   - lyricChangesStream      → 仅供历史单测使用（新引擎不再逐帧转发 position）
//   - PlayerLyricProgressSource → 历史符号保留
//
// 新代码请直接 import lite_lyrics_view.dart。
library;

import 'dart:async';

import 'package:baiji_music/player/player_controller.dart';
import 'package:flutter_lyric/flutter_lyric.dart' as amll;

import 'lite_lyrics_view.dart' show LiteLyricsView;

/// 兼容别名：旧调用点（player_page.dart / 渲染测试）无需改动。
typedef AmllLyricsView = LiteLyricsView;

/// 把两个【离散事件流】（播放状态切换、seek 跳变）合并成 changes 流。
///
/// 保留仅为历史单测（lyric_progress_source_test）契约；新引擎通过 Ticker
/// 直接采样播放器 position，不再使用本流。
Stream<void> lyricChangesStream({
  required Stream<void> playState,
  required Stream<void> seek,
}) {
  return Stream<void>.multi((controller) {
    final subs = <StreamSubscription<void>>[
      seek.listen((_) => controller.add(null)),
      playState.listen((_) => controller.add(null)),
    ];
    controller.onCancel = () {
      for (final s in subs) {
        unawaited(s.cancel());
      }
    };
  });
}

/// 历史进度源符号保留（新引擎不使用，仅为兼容历史测试）。
class PlayerLyricProgressSource implements amll.LyricProgressSource {
  PlayerLyricProgressSource(this._player);

  final PlayerController _player;

  @override
  Duration get position => _player.position;

  @override
  bool get isAdvancing => _player.isPlaying;

  @override
  Stream<void> get changes => lyricChangesStream(
        playState: _player.onPlayStateChanged,
        seek: _player.onSeekOccurred,
      );
}
