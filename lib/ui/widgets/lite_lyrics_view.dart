// 轻量歌词视图（v2.6.3，BaiMusic 架构的 Flutter 移植）。
//
// 取代 v2.6.2 的 flutter_lyric（AMLL）引擎——后者每帧对所有可见行做
// saveLayer + glyph 栅格化，中端机逐字扫光卡顿。本实现复刻 BaiMusic 4.7
// （us/yibai/baimusic）的 LyricPane：
//
//   1. 一个 Ticker 每帧只读一次 player.position，算 activeIdx 与字符级
//      fillOffset（BaiMusic computeFillOffset 的线性插值，见 lite_lyric_math）；
//   2. 每行一个 CustomPaint，**只有当前活跃行**监听逐字进度 notifier；
//      每帧仅对该行 markNeedsPaint 一个薄矩形，clipRect + 两次 drawParagraph
//      实现扫光（不用 saveLayer），不重建任何 widget、不重排其它行；
//   3. activeIdx 变化（低频，每秒 1~3 次）才更新行状态并 animateTo 平滑滚动
//      （140ms easeOut，对齐 BaiMusic tween(140, LinearOutSlowInEasing)）；
//   4. 用户拖动时暂停自动跟随，松手 4s 后回弹到当前行。
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
///
/// API 与旧 [AmllLyricsView] 一致（lyrics + onSeek），调用方无需改动语义。
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
  late final Ticker _ticker;
  late final ScrollController _scroll;

  /// 活跃行下标（低频变化，驱动行的 active 状态）。
  final ValueNotifier<int> _activeIdx = ValueNotifier<int>(-1);

  /// 活跃行的字符级填充偏移（每帧变化，只驱动活跃行的 painter repaint）。
  final ValueNotifier<double> _fill = ValueNotifier<double>(0);

  int _lastIdx = -2;
  bool _userScrolling = false;
  DateTime? _userScrollEnd;
  bool _disposed = false;

  // 缓存：行视觉数据（text painter / 字符 x 表），key = (行号, 宽度取整, 是否活跃, 样式版本)
  final Map<String, _LineVisual> _visualCache = <String, _LineVisual>{};
  int _styleVersion = 0;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController();
    _ticker = createTicker(_onFrame);
    _ticker.start();
  }

  @override
  void didUpdateWidget(covariant LiteLyricsView old) {
    super.didUpdateWidget(old);
    if (!identical(old.lyrics, widget.lyrics)) {
      _visualCache.clear();
      _lastIdx = -2;
      _activeIdx.value = -1;
      _fill.value = 0;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  /// 每帧：读一次播放位置 → 算活跃行与逐字偏移。
  void _onFrame(Duration elapsed) {
    if (_disposed || widget.lyrics.isEmpty) return;
    final ms = (widget.positionProvider?.call() ??
            PlayerController.instance.position)
        .inMilliseconds;

    final idx = activeIndexAt(widget.lyrics, ms);
    if (idx != _lastIdx) {
      _lastIdx = idx;
      _activeIdx.value = idx;
      _fill.value = computeFillOffset(widget.lyrics.lines[idx], ms);
      if (!_userScrolling) _scrollToLine(idx);
    } else if (idx >= 0) {
      // 同一行内：只更新一个 double，触发活跃行 painter 重绘（零 rebuild）。
      _fill.value = computeFillOffset(widget.lyrics.lines[idx], ms);
    }

    // 用户停止拖动 4s 后回弹到当前行（对齐 BaiMusic resumeDelay）。
    final end = _userScrollEnd;
    if (_userScrolling && end != null) {
      if (DateTime.now().difference(end) > const Duration(seconds: 4)) {
        _userScrolling = false;
        _userScrollEnd = null;
        if (_lastIdx >= 0) _scrollToLine(_lastIdx);
      }
    }
  }

  void _scrollToLine(int idx) {
    if (!_scroll.hasClients || idx < 0) return;
    final itemExtent = _lineExtent;
    if (_scroll.position.maxScrollExtent <= 0) return;
    // 让当前行停在视口 42% 处（略高于正中，兼顾下方预告行）。
    final viewport = _scroll.position.viewportDimension;
    final target = (idx * itemExtent - viewport * 0.08)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target.toDouble(),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker.dispose();
    _scroll.dispose();
    _activeIdx.dispose();
    _fill.dispose();
    for (final v in _visualCache.values) {
      v.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = LyricSettings.instance;
    final hasTrans = widget.lyrics.hasTranslation || widget.lyrics.hasRomanization;
    // 设置变化（字号/字重/颜色/对齐）时让每行重建视觉缓存。
    final version = Object.hash(s.fontSize, s.activeScale, s.weight, s.alignLeft,
        s.readableSungColor.toARGB32(), s.readableUnsungColor.toARGB32(),
        s.readableInactiveColor.toARGB32(), hasTrans);
    if (version != _styleVersion) {
      _styleVersion = version;
      for (final v in _visualCache.values) {
        v.dispose();
      }
      _visualCache.clear();
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification && n.dragDetails != null) {
          _userScrolling = true;
          _userScrollEnd = null;
        } else if (n is ScrollUpdateNotification && n.dragDetails != null) {
          _userScrollEnd = null;
        } else if (n is ScrollEndNotification) {
          _userScrollEnd = DateTime.now();
        }
        return false;
      },
      child: ListView.builder(
        controller: _scroll,
        itemExtent: _lineExtent,
        itemCount: widget.lyrics.length,
        physics: const ClampingScrollPhysics(),
        padding: EdgeInsets.symmetric(
            vertical: MediaQuery.sizeOf(context).height * 0.34),
        itemBuilder: (context, i) => ValueListenableBuilder<int>(
          valueListenable: _activeIdx,
          child: _buildLine(i, false, s),
          builder: (context, activeIdx, child) {
            final isActive = i == activeIdx;
            if (isActive == (child as _LyricLine).isActive) return child;
            return _buildLine(i, isActive, s);
          },
        ),
      ),
    );
  }

  /// 单行高度（固定 itemExtent，滚动定位精确、sliver 无需测量每行）。
  static double get _lineExtent => 68.0;

  Widget _buildLine(int i, bool isActive, LyricSettings s) {
    final line = widget.lyrics.lines[i];
    return _LyricLine(
      key: ValueKey('lite_lyric_$i'),
      line: line,
      isActive: isActive,
      settings: s,
      fill: _fill,
      cache: _visualCache,
      cacheKey: '$i|${s.fontSize}|${s.activeScale}|${s.alignLeft}|$_styleVersion|$isActive',
      onTap: () => widget.onSeek(Duration(milliseconds: line.startMs)),
    );
  }
}

/// 单行 widget：普通行不监听逐字进度；活跃行的 painter 监听 [_fill]。
class _LyricLine extends StatelessWidget {
  const _LyricLine({
    super.key,
    required this.line,
    required this.isActive,
    required this.settings,
    required this.fill,
    required this.cache,
    required this.cacheKey,
    required this.onTap,
  });

  final LyricLine line;
  final bool isActive;
  final LyricSettings settings;
  final ValueNotifier<double> fill;
  final Map<String, _LineVisual> cache;
  final String cacheKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final width = math.max(MediaQuery.sizeOf(context).width - 48, 1.0);
    final visual = cache.putIfAbsent(
      cacheKey,
      () => _LineVisual.build(
        text: line.displayText,
        sub: line.translation ??
            (line.romanization != null && line.romanization!.isNotEmpty
                ? line.romanization
                : null),
        isActive: isActive,
        s: settings,
        width: width.toDouble(),
      ),
    );
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: double.infinity,
        height: _LiteLyricsViewState._lineExtent,
        child: CustomPaint(
          painter: _LyricLinePainter(
            visual: visual,
            fill: isActive ? fill : null,
            isActive: isActive,
            width: width.toDouble(),
          ),
        ),
      ),
    );
  }
}

/// 一行的可复用视觉数据（TextPainter + 字符 x 表）。layout 一次，逐帧复用。
class _LineVisual {
  _LineVisual({
    required this.main,
    required this.sung,
    required this.sub,
    required this.charEndX,
    required this.mainWidth,
    required this.mainHeight,
    required this.subHeight,
    required this.textAlign,
  });

  final TextPainter main;
  final TextPainter? sung;
  final TextPainter? sub;
  final List<double> charEndX;
  final double mainWidth;
  final double mainHeight;
  final double subHeight;
  final TextAlign textAlign;

  /// 构造一行的全部 TextPainter（各 layout 一次，逐帧复用，零分配）。
  ///
  /// [main] 是未唱色整行（活跃行=unsung，非活跃=inactive）；[sung] 是同排版
  /// 的已唱色整行，仅在活跃且逐字时构建；paint 时用 clipRect 露出它的左段。
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
          textAlign: s.textAlign,
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: width);

    final main = make(isActive ? s.readableUnsungColor : s.readableInactiveColor);
    // 已唱色 painter 只在实际会用到时构建，避免非活跃行的无谓开销。
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
        textAlign: s.textAlign,
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
      mainWidth: main.width,
      mainHeight: main.height,
      subHeight: subHeight,
      textAlign: s.textAlign,
    );
  }

  void dispose() {
    main.dispose();
    sung?.dispose();
    sub?.dispose();
  }
}

/// 逐字扫光 painter：静态层画整行未唱色；活跃层 clipRect 出一个薄矩形，
/// 只重画已唱部分为高亮色。全程无 saveLayer、无逐帧 TextPainter 分配。
class _LyricLinePainter extends CustomPainter {
  _LyricLinePainter({
    required this.visual,
    required this.fill,
    required this.isActive,
    required this.width,
  }) : super(repaint: fill);

  final _LineVisual visual;
  final ValueNotifier<double>? fill;
  final bool isActive;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final totalH = visual.mainHeight + visual.subHeight;
    var y = (size.height - totalH) / 2;
    if (y < 0) y = 0;

    // 文本起始 x（居中对齐时留白）。sung 与 main 排版一致，共用 startX。
    final startX = switch (visual.textAlign) {
      TextAlign.center => (width - visual.mainWidth) / 2,
      TextAlign.right => width - visual.mainWidth,
      _ => 0.0,
    };

    // 静态层：整行未唱色。
    visual.main.paint(canvas, Offset(startX, y));

    // 活跃层：clip 出已唱部分，直接画预建好的已唱色 painter（零分配）。
    final sung = visual.sung;
    if (isActive && sung != null && fill != null) {
      final fillX = fillOffsetToPixel(fill!.value, visual.charEndX);
      if (fillX > 0.01) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(
          startX, y - 2, fillX + 0.5, visual.mainHeight + 4,
        ));
        sung.paint(canvas, Offset(startX, y));
        canvas.restore();
      }
    }

    // 副文本（译文 / 罗马音）。
    if (visual.sub != null) {
      visual.sub!.paint(canvas, Offset(startX, y + visual.mainHeight));
    }
  }

  @override
  bool shouldRepaint(covariant _LyricLinePainter old) =>
      old.isActive != isActive ||
      old.visual != visual ||
      old.width != width;
}

/// 便于测试访问纯函数的桥（避免测试依赖私有类）。
double liteFillOffset(LyricLine line, int positionMs) =>
    computeFillOffset(line, positionMs);
