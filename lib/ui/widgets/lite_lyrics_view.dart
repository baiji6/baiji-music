// 轻量歌词视图（v2.6.3-fix1，BaiMusic 架构的 Flutter 移植）。
//
// 彻底自绘（不用 ListView / ScrollView），对齐 BaiMusic 4.7 的 LyricPane：
//
//   1. 一个 Ticker 每帧读一次播放位置，经 [SmoothPlaybackClock] 外推成
//      **每帧连续的时钟**（media_kit 的 position 约 200ms 才上报一次，直接用
//      会让逐字扫光「停几帧、跳一格」——这是上一版仍然卡顿的真因）；
//   2. 一个 CustomPaint 画整个视口，每帧只画可见的 8~10 行；逐字扫光 =
//      clipRect + 预建好的已唱色 TextPainter，无 saveLayer、无逐帧 TextPainter
//      分配、无 widget 重建；
//   3. 滚动用指数逼近（时间常数约等于 140ms 缓动）逐帧收敛，无跳变；
//      当前行严格垂直居中（[centeredScrollOffset]），水平按对齐方式精确居中；
//   4. 拖动即接管、松手 4s 回弹；点击某行跳转到该行起点。
//
// 视觉与设置完全沿用 LyricSettings（三色 / 字号 / 字重 / 对齐 / 译文）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/lyrics/lite_lyric_math.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/player/player_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

/// 轻量歌词视图：撑满给定的有界区域（Expanded / SizedBox）。
class LiteLyricsView extends StatefulWidget {
  const LiteLyricsView({
    super.key,
    required this.lyrics,
    required this.onSeek,
    this.positionProvider,
  });

  final Lyrics lyrics;

  /// 点击某行跳转到该行起点。
  final Future<void> Function(Duration) onSeek;

  /// 播放位置来源；null 时读 [PlayerController]（生产默认）。
  /// 注入点仅用于渲染测试精确控制位置。
  final Duration Function()? positionProvider;

  @override
  State<LiteLyricsView> createState() => _LiteLyricsViewState();
}

class _LiteLyricsViewState extends State<LiteLyricsView>
    with TickerProviderStateMixin {
  /// 左右安全边距（居中计算与超长省略都基于 `宽 - 2*sidePad`）。
  static const double sidePad = 24.0;

  /// 指数逼近的时间常数（秒）。约 140ms 收敛 85%，对齐 BaiMusic tween(140ms)。
  static const double _followTau = 0.075;

  /// 松手后恢复跟随的等待时长。
  static const int _resumeDelayUs = 4000000;

  late final Ticker _ticker;
  final SmoothPlaybackClock _clock = SmoothPlaybackClock();

  /// 单调递增的本地时间（微秒），由 Ticker 的 vsync 间隔累加。
  /// 不用 Stopwatch：测试环境的假时钟不会推进真实秒表，动画永远不开始；
  /// 且 vsync 时间才是与实际出帧一致的时基。
  int _nowUs = 0;
  Duration _lastElapsed = Duration.zero;

  /// 每帧递增，驱动 CustomPaint 重绘（painter 通过它拿到重画时机）。
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  StreamSubscription<void>? _seekSub;
  StreamSubscription<bool>? _playSub;

  /// 行视觉缓存，key = `行号|是否活跃|样式版本`。
  final Map<String, _LineVisual> _cache = <String, _LineVisual>{};

  /// painter 读取的可变帧数据（State 与 painter 共享同一实例）。
  final _PaintFrame _frame = _PaintFrame();

  double _scroll = 0; // 内容坐标 → 视口顶部
  double _target = 0;
  double _extent = 64; // 单行所占高度（含行距）
  double _viewportW = 0;
  double _viewportH = 0;

  int _activeIdx = -1;
  int _lastIdx = -2;
  double _fill = 0;
  int _styleVersion = -1;

  bool _dragging = false;
  bool _browsing = false;
  int? _browseEndUs;
  bool _hardSync = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    if (widget.positionProvider == null) {
      _seekSub = PlayerController.instance.onSeekOccurred.listen((_) {
        _hardSync = true;
        _startTicker();
      });
      _playSub = PlayerController.instance.onPlayStateChanged.listen((_) {
        _startTicker();
      });
    }
    _startTicker();
  }

  @override
  void didUpdateWidget(covariant LiteLyricsView old) {
    super.didUpdateWidget(old);
    if (!identical(old.lyrics, widget.lyrics)) {
      _cache.clear();
      _lastIdx = -2;
      _activeIdx = -1;
      _fill = 0;
      _hardSync = true;
      _scroll = 0;
      _target = 0;
      _browsing = false;
      _browseEndUs = null;
      _startTicker();
      _syncFrame();
      _requestRepaint();
    }
  }

  void _startTicker() {
    if (_disposed || _ticker.isActive) return;
    _lastElapsed = Duration.zero;
    _ticker.start();
  }

  void _stopTicker() {
    if (_ticker.isActive) _ticker.stop();
  }

  void _requestRepaint() {
    if (_disposed) return;
    _repaint.value++;
  }

  /// 把 State 的最新状态写进共享帧数据（painter 在 paint 时读取）。
  void _syncFrame() {
    _frame
      ..lyrics = widget.lyrics
      ..cache = _cache
      ..styleVersion = _styleVersion
      ..extent = _extent
      ..scroll = _scroll
      ..activeIdx = _activeIdx
      ..fill = _fill;
  }

  void _tickIdleCheck() {
    // 必须等活跃行解析过一次（_lastIdx >= 0）才允许休眠：否则第一帧
    // 目标与当前位置恰好相等会被误判为静止，ticker 一停就再也不会更新。
    final idle = _lastIdx >= 0 &&
        widget.positionProvider == null &&
        !_clock.playing &&
        !_dragging &&
        !_browsing &&
        (_target - _scroll).abs() < 0.02;
    if (idle) _stopTicker();
  }

  /// 每帧：推进平滑时钟 → 算活跃行与逐字填充 → 指数逼近滚动目标。
  void _onTick(Duration elapsed) {
    if (_disposed) return;
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) {
      // 无歌词时没有任何可推进的状态，直接休眠（切歌后 didUpdateWidget 重启）。
      _stopTicker();
      return;
    }

    // 用两帧之间的 vsync 间隔累加本地时间（ticker 重启后 elapsed 归零）。
    var deltaUs = (elapsed - _lastElapsed).inMicroseconds;
    _lastElapsed = elapsed;
    if (deltaUs < 0 || deltaUs > 50000) deltaUs = 16667; // 首帧/长卡顿归一到一帧
    _nowUs += deltaUs;
    final us = _nowUs;
    final dt = deltaUs / 1000000;

    final provider = widget.positionProvider;
    if (provider == null) {
      final player = PlayerController.instance;
      _clock.sync(
        player.position,
        nowUs: us,
        playing: player.isPlaying,
        rate: player.rate,
        hard: _hardSync,
      );
      _hardSync = false;
    }
    final posMs = (provider?.call() ?? _clock.positionAt(us)).inMilliseconds;

    var changed = false;

    final idx = activeIndexAt(lyrics, posMs);
    if (idx != _lastIdx) {
      _lastIdx = idx;
      _activeIdx = idx;
      if (!_browsing && idx >= 0) {
        _target = centeredScrollOffset(idx, _extent, _viewportH);
      }
      changed = true;
    }
    if (idx >= 0) {
      final f = computeFillOffset(lyrics.lines[idx], posMs);
      if ((f - _fill).abs() > 1e-4) {
        _fill = f;
        changed = true;
      }
    }

    // 松手 4s 后恢复跟随当前行。
    final endUs = _browseEndUs;
    if (_browsing && !_dragging && endUs != null && (us - endUs) > _resumeDelayUs) {
      _browsing = false;
      _browseEndUs = null;
      if (_lastIdx >= 0) {
        _target = centeredScrollOffset(_lastIdx, _extent, _viewportH);
      }
    }

    // 指数逼近：每帧收敛一点，视觉连续平滑，不会一格一格跳。
    if (!_dragging) {
      final diff = _target - _scroll;
      if (diff.abs() > 0.02) {
        final k = 1 - math.exp(-dt / _followTau);
        _scroll += diff * k;
        if ((_target - _scroll).abs() < 0.05) _scroll = _target;
        changed = true;
      } else if (_scroll != _target) {
        _scroll = _target;
        changed = true;
      }
    }

    if (changed) {
      _syncFrame();
      _requestRepaint();
    }
    _tickIdleCheck();
  }

  double get _minScroll {
    final n = widget.lyrics.length;
    if (n <= 0) return 0;
    final first = centeredScrollOffset(0, _extent, _viewportH);
    final last = centeredScrollOffset(n - 1, _extent, _viewportH);
    return math.min(first, last);
  }

  double get _maxScroll {
    final n = widget.lyrics.length;
    if (n <= 0) return 0;
    final first = centeredScrollOffset(0, _extent, _viewportH);
    final last = centeredScrollOffset(n - 1, _extent, _viewportH);
    return math.max(first, last);
  }

  void _handleTap(double localY) {
    final i =
        lineIndexAtScroll(_scroll, localY, _extent, widget.lyrics.length);
    if (i < 0) return;
    final line = widget.lyrics.lines[i];
    unawaited(widget.onSeek(Duration(milliseconds: line.startMs)));
  }

  void _onDragStart(DragStartDetails _) {
    _dragging = true;
    _browsing = true;
    _browseEndUs = null;
    _startTicker();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _scroll = (_scroll - d.delta.dy).clamp(_minScroll, _maxScroll);
    _target = _scroll;
    _browseEndUs = null;
    _syncFrame();
    _requestRepaint();
  }

  void _onDragEnd(DragEndDetails _) {
    _dragging = false;
    _browseEndUs = _nowUs;
    _startTicker();
  }

  /// 单行高度：按当前行最大的字号预留，再算上译文与行距。
  static double _computeExtent(LyricSettings s, bool hasTrans) {
    final mainH = s.fontSize * 1.25 * math.max(1.0, s.activeScale);
    final subH = hasTrans ? s.fontSize * 0.58 * 1.2 : 0.0;
    return mainH + subH + s.fontSize * 0.8;
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker.dispose();
    _seekSub?.cancel();
    _playSub?.cancel();
    _repaint.dispose();
    for (final v in _cache.values) {
      v.dispose();
    }
    _cache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = LyricSettings.instance;
    final hasTrans =
        widget.lyrics.hasTranslation || widget.lyrics.hasRomanization;

    final version = Object.hash(
      s.fontSize,
      s.activeScale,
      s.weight,
      s.alignLeft,
      s.readableSungColor.toARGB32(),
      s.readableUnsungColor.toARGB32(),
      s.readableInactiveColor.toARGB32(),
      hasTrans,
    );
    if (version != _styleVersion) {
      _styleVersion = version;
      _cache.clear(); // TextPainter 交给 GC；当帧 dispose 有被复用的风险
    }
    final nextExtent = _computeExtent(s, hasTrans);
    if (nextExtent != _extent) {
      _extent = nextExtent;
      // 行高变了（字号/缩放改动）：重新按当前行居中，否则活跃行会偏。
      if (_lastIdx >= 0 && !_browsing) {
        _target = centeredScrollOffset(_lastIdx, _extent, _viewportH);
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        if (w > 0 && h > 0) {
          if ((w - _viewportW).abs() > 0.5 || (h - _viewportH).abs() > 0.5) {
            _viewportW = w;
            _viewportH = h;
            final n = widget.lyrics.length;
            if (n > 0) {
              final idx = _lastIdx < 0 ? 0 : _lastIdx;
              _target = centeredScrollOffset(idx, _extent, h);
              if (_lastIdx < 0) _scroll = _target; // 首帧直接就位，避免从头滚
              _startTicker();
            }
          }
        }
        _syncFrame();

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _handleTap(d.localPosition.dy),
          onVerticalDragStart: _onDragStart,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: SizedBox.expand(
            // 逐字扫光每帧都会 markNeedsPaint：用 RepaintBoundary 把它隔离成
            // 独立图层，避免把整页（封面模糊、控制栏）一起重绘。
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _LyricsPainter(_frame, repaint: _repaint),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 每帧被 painter 读取的可变帧数据。
///
/// CustomPainter 是不可变的：若把 scroll/fill 作为构造参数拷贝进去，之后
/// `repaint` 只会在**旧值**上重画（v2.6.3 的滚动与扫光因此完全不生效）。
/// 这里让 State 持有唯一实例并原地更新，painter 每帧都读到最新值。
class _PaintFrame {
  Lyrics lyrics = Lyrics.empty;
  Map<String, _LineVisual> cache = <String, _LineVisual>{};
  int styleVersion = -1;
  double extent = 64;
  double scroll = 0;
  int activeIdx = -1;
  double fill = 0;
}

/// 整个歌词视口的绘制器：每帧只画可见行。
class _LyricsPainter extends CustomPainter {
  _LyricsPainter(this.frame, {required Listenable repaint})
      : super(repaint: repaint);

  final _PaintFrame frame;

  @override
  void paint(Canvas canvas, Size size) {
    final lyrics = frame.lyrics;
    final extent = frame.extent;
    if (lyrics.isEmpty || extent <= 0 || size.width <= 0 || size.height <= 0) {
      return;
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final n = lyrics.length;
    final scroll = frame.scroll;
    final first = math.max(0, ((scroll - extent) / extent).floor());
    final last = math.min(n, ((scroll + size.height) / extent).ceil() + 1);
    for (var i = first; i < last; i++) {
      _paintLine(canvas, i, i * extent + extent / 2 - scroll, size.width);
    }
    canvas.restore();
  }

  void _paintLine(Canvas canvas, int i, double centerY, double width) {
    final isActive = i == frame.activeIdx;
    final visual = _visualFor(i, isActive, width);
    final settings = LyricSettings.instance;

    final layoutW = math.max(width - _LiteLyricsViewState.sidePad * 2, 1.0);
    final textW = math.min(visual.textWidth, layoutW);
    final startX = lineStartX(
      viewportWidth: width,
      textWidth: textW,
      align: settings.textAlign,
      sidePad: _LiteLyricsViewState.sidePad,
    );

    final totalH = visual.mainHeight + visual.subHeight;
    final top = centerY - totalH / 2;

    // 静态层：未唱色整行。
    visual.main.paint(canvas, Offset(startX, top));

    // 已唱层：clip 出左侧已唱部分，画预建的已唱色 painter（零分配）。
    final sung = visual.sung;
    final fill = frame.fill;
    if (isActive && sung != null && fill > 0) {
      final px = fillOffsetToPixel(fill, visual.charEndX);
      if (px > 0.01) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(
          startX,
          top - 2,
          px + 0.5,
          visual.mainHeight + 4,
        ));
        sung.paint(canvas, Offset(startX, top));
        canvas.restore();
      }
    }

    // 译文 / 罗马音。
    final sub = visual.sub;
    if (sub != null) {
      sub.paint(canvas, Offset(startX, top + visual.mainHeight));
    }
  }

  _LineVisual _visualFor(int i, bool isActive, double width) {
    final key = '$i|${isActive ? 1 : 0}|${frame.styleVersion}';
    return frame.cache.putIfAbsent(
      key,
      () => _LineVisual.build(
        text: frame.lyrics.lines[i].displayText,
        sub: _subOf(frame.lyrics.lines[i]),
        isActive: isActive,
        s: LyricSettings.instance,
        width: math.max(width - _LiteLyricsViewState.sidePad * 2, 1.0),
      ),
    );
  }

  static String? _subOf(LyricLine line) {
    final t = line.translation;
    if (t != null && t.isNotEmpty) return t;
    final r = line.romanization;
    if (r != null && r.isNotEmpty) return r;
    return null;
  }

  // 重绘完全由 _repaint 驱动（帧数据是共享可变的，无法用字段比较判断）。
  @override
  bool shouldRepaint(covariant _LyricsPainter old) => true;
}

/// 一行的可复用视觉数据（TextPainter + 字符 x 表）。layout 一次，逐帧复用。
class _LineVisual {
  _LineVisual({
    required this.main,
    required this.sung,
    required this.sub,
    required this.charEndX,
    required this.textWidth,
    required this.mainHeight,
    required this.subHeight,
  });

  final TextPainter main;
  final TextPainter? sung;
  final TextPainter? sub;
  final List<double> charEndX;
  final double textWidth;
  final double mainHeight;
  final double subHeight;

  /// 构造一行的全部 TextPainter（各 layout 一次，逐帧复用，零分配）。
  ///
  /// 统一按 [TextAlign.left] 排版：水平居中/右对齐由绘制层按实测文本宽度
  /// 计算起点（v2.6.3 用 textAlign 排版又叠加偏移，导致文字整体左偏 24dp）。
  static _LineVisual build({
    required String text,
    required String? sub,
    required bool isActive,
    required LyricSettings s,
    required double width,
  }) {
    final fontSize = s.fontSize * (isActive ? s.activeScale : 1.0);
    TextStyle baseStyle({required Color color}) => TextStyle(
          fontSize: fontSize,
          fontWeight: isActive ? s.activeWeight : s.inactiveWeight,
          height: 1.25,
          color: color,
          leadingDistribution: TextLeadingDistribution.even,
        );

    TextPainter make(Color color) => TextPainter(
          text: TextSpan(text: text, style: baseStyle(color: color)),
          textAlign: TextAlign.left,
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: width);

    final main = make(isActive ? s.readableUnsungColor : s.readableInactiveColor);
    final sung = isActive ? make(s.readableSungColor) : null;

    final subStyle = TextStyle(
      fontSize: s.fontSize * 0.58,
      fontWeight: s.inactiveWeight,
      height: 1.2,
      color: s.readableInactiveColor.withValues(alpha: 0.82),
      leadingDistribution: TextLeadingDistribution.even,
    );
    TextPainter? subPainter;
    double subHeight = 0;
    if (sub != null && sub.isNotEmpty) {
      subPainter = TextPainter(
        text: TextSpan(text: sub, style: subStyle),
        textAlign: TextAlign.left,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: width);
      subHeight = subPainter.height;
    }

    // 逐字 x 表：getOffsetForCaret 返回第 i 个 UTF-16 单元边界的 x。
    final charEndX = buildCharEndX(
      text.length,
      (i) => main.getOffsetForCaret(TextPosition(offset: i), Rect.zero).dx,
    );

    return _LineVisual(
      main: main,
      sung: sung,
      sub: subPainter,
      charEndX: charEndX,
      textWidth: charEndX.isEmpty ? 0 : charEndX.last,
      mainHeight: main.height,
      subHeight: subHeight,
    );
  }

  void dispose() {
    main.dispose();
    sung?.dispose();
    sub?.dispose();
  }
}

/// 便于测试访问纯函数的桥（避免测试依赖私有类）。
double liteFillOffset(LyricLine line, int positionMs) =>
    computeFillOffset(line, positionMs);
