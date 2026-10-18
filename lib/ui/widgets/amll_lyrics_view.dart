// 歌词视图（flutter_lyric / AMLL 风格引擎）。
//
// 取代 v2.3.0 自绘的 `_LyricView`：引擎负责逐字高亮、滚动跟随、点击跳转、
// 前奏倒计时与切句动效，本页只做三件事——把歌词文档喂给控制器、把播放器
// 位置接成进度源、把歌词样式设置映射成预设。
import 'dart:async';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/lyrics/lyric_amll_adapter.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/player/player_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lyric/flutter_lyric.dart' as amll;

/// 把 [PlayerController] 接到歌词引擎的进度口子上。
///
/// 引擎不自建播放时钟：行进中时由它每帧采样 [position]（逐字高亮才跟手），
/// 暂停 / seek / 切歌由 [changes] 事件驱动一次采样。
class PlayerLyricProgressSource implements amll.LyricProgressSource {
  PlayerLyricProgressSource(this._player);

  final PlayerController _player;

  @override
  Duration get position => _player.position;

  @override
  bool get isAdvancing => _player.isPlaying;

  @override
  Stream<void> get changes => Stream<void>.multi((controller) {
        final subs = <StreamSubscription>[
          _player.onPositionChanged.listen((_) => controller.add(null)),
          _player.onPlayStateChanged.listen((_) => controller.add(null)),
        ];
        controller.onCancel = () {
          for (final s in subs) {
            s.cancel();
          }
        };
      });
}

/// AMLL 风格歌词视图：撑满给定的有界区域（SizedBox / Expanded）。
class AmllLyricsView extends StatefulWidget {
  const AmllLyricsView({
    super.key,
    required this.lyrics,
    required this.onSeek,
  });

  final Lyrics lyrics;

  /// 点击某行时的跳转回调（引擎给出该行的 seek 位置）。
  final Future<void> Function(Duration) onSeek;

  @override
  State<AmllLyricsView> createState() => _AmllLyricsViewState();
}

class _AmllLyricsViewState extends State<AmllLyricsView> {
  amll.LyricController? _controller;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  @override
  void didUpdateWidget(covariant AmllLyricsView old) {
    super.didUpdateWidget(old);
    // 换歌必须重建文档：沿用旧 controller 会残留上一首的行索引与滚动位置
    if (!identical(old.lyrics, widget.lyrics)) {
      _teardown();
      _setup();
    }
  }

  void _setup() {
    final source = PlayerLyricProgressSource(PlayerController.instance);
    _controller = amll.LyricController(
      document: toLyricDocument(widget.lyrics),
      progressSource: source,
      initialPosition: PlayerController.instance.position,
    );
    AppLog.d('LyricView',
        'AMLL 歌词文档: lines=${widget.lyrics.length} '
        '词级=${widget.lyrics.lines.where((l) => l.isWordLevel).length} '
        'hasWordTiming=${widget.lyrics.hasWordTiming}');
  }

  void _teardown() {
    // 先解绑进度源，再 dispose controller（顺序反了会在 dispose 后收事件）
    _controller?.progressSource = null;
    _controller?.dispose();
    _controller = null;
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    // 样式设置（字号 / 对齐 / 三色）改动后立刻重排
    return AnimatedBuilder(
      animation: LyricSettings.instance,
      builder: (context, _) => amll.LyricView(
        controller: controller,
        preset: lyricPresetFrom(LyricSettings.instance),
        onLineTap: (line) => widget.onSeek(line.seekPosition),
      ),
    );
  }
}
