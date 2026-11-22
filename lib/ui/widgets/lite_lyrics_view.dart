// 轻量歌词视图（v2.6.4，BaiMusic 架构的 Flutter 移植）。
//
// 彻底自绘（不用 ListView / ScrollView），对齐 BaiMusic 4.7 的 LyricPane：
//
//   1. 一个 Ticker 每帧读一次播放位置，经 [SmoothPlaybackClock] 外推成
//      **每帧连续的时钟**（media_kit 的 position 约 200ms 才上报一次，直接用
//      会让逐字扫光「停几帧、跳一格」）；
//   2. 整个视口分**两层**绘制（v2.6.4 的关键性能改造）：
//        - 静态层：所有非当前行，绘制一次后只在切行/样式变化时重画，
//          滚动由 widget 层的 Positioned 位移完成（GPU 平移，零重栅格化）；
//        - 活跃层：只有当前行，逐字扫光每帧重画。
//      上一版每帧都要重画全部 8~10 行（只为让一行的扫光前进），
//      低端机光栅化直接吃掉一帧预算；分层后每帧只重画一行。
//   3. 逐字扫光 = clipRect + 预建好的已唱色 TextPainter，无 saveLayer、
//      无逐帧 TextPainter 分配、无 widget 重建；
//   4. 滚动用指数逼近（时间常数 ≈ 300ms）逐帧收敛，无跳变；当前行严格
//      垂直居中（[centeredScrollOffset]），水平按对齐方式精确居中；
//   5. 拖动即接管、松手 4s 回弹；点击某行跳转到该行起点。
//
// 视觉与设置完全沿用 LyricSettings（三色 / 字号 / 字重 / 对齐 / 译文 /
// 繁转简）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/lyrics/lite_lyric_math.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/lyrics/trad_to_simp.dart';
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

  /// 指数逼近的时间常数（秒）。约 300ms 收敛 90%：比上一版 140ms 更柔和，
  /// 切行时整块歌词是「滑过去」而不是「弹过去」。
  static const double _followTau = 0.13;

  /// 松手后恢复跟随的等待时长。
  static const int _resumeDelayUs = 4000000;

  /// 静态层上下各多画几行（滚动缓冲，越大切窗口越少、单次重画越多）。
  static const int _windowBuffer = 3;

  late final Ticker _ticker;
  final SmoothPlaybackClock _clock = SmoothPlaybackClock();

  /// 单调递增的本地时间（微秒），由 Ticker 的 vsync 间隔累加。
  /// 不用 Stopwatch：测试环境的假时钟不会推进真实秒表，动画永远不开始；
  /// 且 vsync 时间才是与实际出帧一致的时基。
  int _nowUs = 0;
  Duration _lastElapsed = Duration.zero;

  /// 每帧递增，驱动活跃层重绘。
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  /// 滚动偏移（驱动静态层的布局位移）。
  final ValueNotifier<double> _scrollN = ValueNotifier<double>(0);

  /// 静态层重绘信号：切行时旧行要变回暗色、新行要让位给活跃层，
  /// 但滚动帧绝不能连带重画（否则分层就没有意义了）。
  final ValueNotifier<int> _staticRepaint = ValueNotifier<int>(0);

  StreamSubscription<void>? _seekSub;
  StreamSubscription<bool>? _playSub;

  /// 行视觉缓存：下标 `i*2`（非活跃）/ `i*2+1`（活跃）。
  final List<_LineVisual?> _visuals = <_LineVisual?>[];

  /// painter 读取的可变帧数据（State 与 painter 共享同一实例）。
  final _PaintFrame _frame = _PaintFrame();

  /// 当前实际渲染的歌词（可能是繁转简后的副本）。
  Lyrics _lyrics = Lyrics.empty;
  Lyrics? _simpSource;
  Lyrics? _simpResult;

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
    _lyrics = widget.lyrics;
    _ticker = createTicker(_onTick);
    // 样式面板 / 设置页改动（字号、三色、繁转简开关…）即时生效。
    LyricSettings.instance.addListener(_onSettingsChanged);
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
      _simpSource = null;
      _simpResult = null;
      _lyrics = widget.lyrics;
      _clearVisuals();
      _lastIdx = -2;
      _activeIdx = -1;
      _fill = 0;
      _hardSync = true;
      _scroll = 0;
      _target = 0;
      _scrollN.value = 0;
      _browsing = false;
      _browseEndUs = null;
      _startTicker();
      _syncFrame();
      _requestRepaint();
    }
  }

  void _onSettingsChanged() {
    if (_disposed || !mounted) return;
    setState(() {});
    // 字号/对齐变化会改滚动目标；暂停时 ticker 可能已休眠，这里唤醒它
    // 把新目标平滑滚过去（否则要等下次播放才会动）。
    _startTicker();
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
      ..lyrics = _lyrics
      ..visuals = _visuals
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
    if (_lyrics.isEmpty) {
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
    // 注入的 provider 也走一次推进，保证每帧位置连续。
    final posMs = provider != null
        ? provider().inMilliseconds
        : _clock.positionAt(us).inMilliseconds;

    var changed = false;
    var scrolled = false;

    final idx = activeIndexAt(_lyrics, posMs);
    if (idx != _lastIdx) {
      _lastIdx = idx;
      _activeIdx = idx;
      if (!_browsing && idx >= 0) {
        _target = centeredScrollOffset(idx, _extent, _viewportH);
      }
      changed = true;
      _staticRepaint.value++; // 旧活跃行要画回静态层、新行要让位
    }
    if (idx >= 0) {
      final f = computeFillOffset(_lyrics.lines[idx], posMs);
      if ((f - _fill).abs() > 1e-4) {
        _fill = f;
        changed = true;
      }
    }

    // 松手 4s 后恢复跟随当前行。
    final endUs = _browseEndUs;
    if (_browsing &&
        !_dragging &&
        endUs != null &&
        (us - endUs) > _resumeDelayUs) {
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
        scrolled = true;
      } else if (_scroll != _target) {
        _scroll = _target;
        changed = true;
        scrolled = true;
      }
    }

    if (scrolled) _scrollN.value = _scroll;
    if (changed) {
      _syncFrame();
      _requestRepaint();
    }
    _tickIdleCheck();
  }

  double get _minScroll {
    final n = _lyrics.length;
    if (n <= 0) return 0;
    final first = centeredScrollOffset(0, _extent, _viewportH);
    final last = centeredScrollOffset(n - 1, _extent, _viewportH);
    return math.min(first, last);
  }

  double get _maxScroll {
    final n = _lyrics.length;
    if (n <= 0) return 0;
    final first = centeredScrollOffset(0, _extent, _viewportH);
    final last = centeredScrollOffset(n - 1, _extent, _viewportH);
    return math.max(first, last);
  }

  void _handleTap(double localY) {
    final i = lineIndexAtScroll(_scroll, localY, _extent, _lyrics.length);
    if (i < 0) return;
    final line = _lyrics.lines[i];
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
    _scrollN.value = _scroll;
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

  void _clearVisuals() {
    // TextPainter 交给 GC；当帧 dispose 有被复用的风险。
    _visuals.clear();
  }

  /// 解析当前应渲染的歌词：开启「繁转简」时做一次带缓存的转换。
  Lyrics _resolveLyrics() {
    final src = widget.lyrics;
    if (!LyricSettings.instance.simplifyChinese) return src;
    if (identical(src, _simpSource) && _simpResult != null) return _simpResult!;
    _simpSource = src;
    _simpResult = tradToSimpLyrics(src);
    return _simpResult!;
  }

  @override
  void dispose() {
    _disposed = true;
    LyricSettings.instance.removeListener(_onSettingsChanged);
    _ticker.dispose();
    _seekSub?.cancel();
    _playSub?.cancel();
    _repaint.dispose();
    _scrollN.dispose();
    _staticRepaint.dispose();
    _clearVisuals();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = LyricSettings.instance;
    final resolved = _resolveLyrics();
    final changedLyrics = !identical(resolved, _lyrics);
    _lyrics = resolved;
    final hasTrans =
        _lyrics.hasTranslation || _lyrics.hasRomanization;

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
      _clearVisuals();
    }
    if (changedLyrics) {
      _lastIdx = -2;
      _activeIdx = -1;
      _fill = 0;
      _hardSync = true;
      _startTicker();
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
          if ((w - _viewportW).abs() > 0.5 ||
              (h - _viewportH).abs() > 0.5) {
            _viewportW = w;
            _viewportH = h;
            final n = _lyrics.length;
            if (n > 0) {
              final idx = _lastIdx < 0 ? 0 : _lastIdx;
              _target = centeredScrollOffset(idx, _extent, h);
              if (_lastIdx < 0) {
                _scroll = _target; // 首帧直接就位，避免从头滚
                _scrollN.value = _scroll;
              }
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
          child: ClipRect(
            child: SizedBox.expand(
              child: ValueListenableBuilder<double>(
                valueListenable: _scrollN,
                builder: (context, scroll, _) {
                  return Stack(
                    children: [
                      _buildStaticLayer(scroll, w, h),
                      // 活跃行：逐帧重绘，用 RepaintBoundary 与静态层隔离。
                      Positioned.fill(
                        child: IgnorePointer(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: _ActiveLinePainter(
                                _frame,
                                repaint: _repaint,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// 静态层：非当前行画一次，滚动只改 widget 位置（GPU 平移，不重画）。
  Widget _buildStaticLayer(double scroll, double w, double h) {
    final n = _lyrics.length;
    if (n <= 0) return const SizedBox.shrink();
    final extent = _extent;
    if (extent <= 0) return const SizedBox.shrink();

    // 可视窗口 + 上下缓冲；缓冲足够大时，普通切行滚动不会触发重画。
    var start = (scroll / extent).floor() - _windowBuffer;
    var end = ((scroll + h) / extent).ceil() + _windowBuffer + 1;
    start = start.clamp(0, n - 1);
    end = end.clamp(start + 1, n);

    return Positioned(
      left: 0,
      right: 0,
      top: start * extent - scroll,
      height: (end - start) * extent,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _StaticLinesPainter(
            _frame,
            repaint: _staticRepaint,
            start: start,
            count: end - start,
            width: w,
            snapshot: _LayerSnapshot(
              lyrics: _lyrics,
              styleVersion: _styleVersion,
              extent: extent,
              activeIdx: _activeIdx,
            ),
          ),
        ),
      ),
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
  List<_LineVisual?> visuals = <_LineVisual?>[];
  int styleVersion = -1;
  double extent = 64;
  double scroll = 0;
  int activeIdx = -1;
  double fill = 0;
}

/// 静态层的重绘判据（painter 不可变，必须把关键值快照进构造参数）。
class _LayerSnapshot {
  const _LayerSnapshot({
    required this.lyrics,
    required this.styleVersion,
    required this.extent,
    required this.activeIdx,
  });

  final Lyrics lyrics;
  final int styleVersion;
  final double extent;
  final int activeIdx;
}

/// 静态层：所有非当前行。只在切行 / 样式 / 行高变化时重画。
class _StaticLinesPainter extends CustomPainter {
  _StaticLinesPainter(
    this.frame, {
    required Listenable repaint,
    required this.start,
    required this.count,
    required this.width,
    required this.snapshot,
  }) : super(repaint: repaint);

  final _PaintFrame frame;
  final int start;
  final int count;
  final double width;
  final _LayerSnapshot snapshot;

  @override
  void paint(Canvas canvas, Size size) {
    final lyrics = frame.lyrics;
    final extent = frame.extent;
    if (lyrics.isEmpty || extent <= 0 || width <= 0) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var i = 0; i < count; i++) {
      final idx = start + i;
      if (idx >= lyrics.length) break;
      if (idx == frame.activeIdx) continue; // 当前行由活跃层画
      _paintLine(
        canvas,
        frame,
        idx,
        i * extent + extent / 2,
        width,
        active: false,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StaticLinesPainter old) {
    final a = old.snapshot;
    final b = snapshot;
    return !identical(a.lyrics, b.lyrics) ||
        a.styleVersion != b.styleVersion ||
        a.extent != b.extent ||
        a.activeIdx != b.activeIdx ||
        old.start != start ||
        old.count != count ||
        old.width != width;
  }
}

/// 活跃层：只有当前行，逐字扫光每帧重画。
class _ActiveLinePainter extends CustomPainter {
  _ActiveLinePainter(this.frame, {required Listenable repaint})
      : super(repaint: repaint);

  final _PaintFrame frame;

  @override
  void paint(Canvas canvas, Size size) {
    final lyrics = frame.lyrics;
    final extent = frame.extent;
    final i = frame.activeIdx;
    if (lyrics.isEmpty || extent <= 0 || i < 0 || i >= lyrics.length) return;
    if (size.width <= 0 || size.height <= 0) return;
    final centerY = i * extent + extent / 2 - frame.scroll;
    if (centerY < -extent * 1.5 || centerY > size.height + extent * 1.5) {
      return;
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    _paintLine(canvas, frame, i, centerY, size.width, active: true);
    canvas.restore();
  }

  // 重绘完全由 _repaint 驱动（帧数据是共享可变的，无法用字段比较判断）。
  @override
  bool shouldRepaint(covariant _ActiveLinePainter old) => true;
}

/// 画一行（主文本 + 逐字扫光 + 译文）。两层共用，保证视觉严格一致。
void _paintLine(
  Canvas canvas,
  _PaintFrame frame,
  int i,
  double centerY,
  double width, {
  required bool active,
}) {
  final visual = _visualFor(frame, i, active, width);
  final settings = LyricSettings.instance;

  final layoutW =
      math.max(width - _LiteLyricsViewState.sidePad * 2, 1.0);
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
  if (active && sung != null && fill > 0) {
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

/// 取（并按需构建）某行某形态的视觉数据。缓存下标 `i*2 + (active?1:0)`。
_LineVisual _visualFor(
  _PaintFrame frame,
  int i,
  bool active,
  double width,
) {
  final slot = i * 2 + (active ? 1 : 0);
  final visuals = frame.visuals;
  if (slot < visuals.length) {
    final cached = visuals[slot];
    if (cached != null) return cached;
  }

  final line = frame.lyrics.lines[i];
  final visual = _LineVisual.build(
    text: line.displayText,
    sub: _subOf(line),
    isActive: active,
    s: LyricSettings.instance,
    width: math.max(width - _LiteLyricsViewState.sidePad * 2, 1.0),
  );
  if (visuals.length <= slot) visuals.length = slot + 1;
  visuals[slot] = visual;
  return visual;
}

String? _subOf(LyricLine line) {
  final t = line.translation;
  if (t != null && t.isNotEmpty) return t;
  final r = line.romanization;
  if (r != null && r.isNotEmpty) return r;
  return null;
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

    final main =
        make(isActive ? s.readableUnsungColor : s.readableInactiveColor);
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
