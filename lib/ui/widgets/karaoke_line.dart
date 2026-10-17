import 'dart:math' as math;

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/lyrics/karaoke_fill.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:flutter/foundation.dart' show listEquals, ValueListenable;
import 'package:flutter/material.dart';

/// 当前行的逐字卡拉 OK 填充（AMLL / 倾听同款语义的 Flutter 移植）。
///
/// 每个词是一条独立遮罩：词被唱到时，一条宽度为半个行高的柔和亮/暗
/// 边界从词的左缘匀速扫到右缘，扫完瞬间恰好等于词唱完；还没开口的词
/// 保持全暗，已唱完的词保持全亮。遮罩算法见 [KaraokeFill]。
///
/// 实现方式：底层画一整行未唱色，再按**视觉行**（自动换行产生）逐行
/// 叠一层已唱色，用该行的分段渐变做 `dstIn` 遮罩。按视觉行分组是
/// AMLL 的做法——换行后第二行从 x=0 重新开始，整行单一渐变的 stops
/// 会乱序失效，分组后每行独立，天然支持换行。
///
/// 与"整行放大"是两条独立的渲染链路：放大决定字号，逐字填充决定颜色，
/// 两者必须同时存在——只放大不填充，逐字歌词就等于没了。
class KaraokeLine extends StatefulWidget {
  const KaraokeLine({
    super.key,
    required this.line,
    required this.head,
    required this.fontSize,
    required this.height,
    required this.align,
    required this.weight,
  });

  final LyricLine line;

  /// 播放位置（毫秒）。每帧变化驱动逐字边界推进。
  final ValueListenable<int> head;
  final double fontSize;

  /// 行高倍数（TextStyle.height）。
  final double height;
  final TextAlign align;

  /// 当前行字重。字重变化会改变每个字的字形宽度，缓存必须失效重量排。
  final FontWeight weight;

  @override
  State<KaraokeLine> createState() => KaraokeLineState();
}

class KaraokeLineState extends State<KaraokeLine> {
  /// 排版量字结果缓存。文本/字号/宽度/颜色不变时复用，避免每帧重排版。
  KaraokeLayout? _layout;

  /// 未唱色的可读版本：自定义浅色字在浅色主题下会隐身，
  /// 与逐行歌词当前行同源的问题（#80），统一走对比度保障。
  Color get _readableUnsung =>
      LyricSettings.instance.readableUnsungColor;

  Color get _readableSung => LyricSettings.instance.readableSungColor;

  void _measure(double maxWidth) {
    final sung = _readableSung;
    final unsung = _readableUnsung;
    final cached = _layout;
    if (cached != null &&
        cached.maxWidth == maxWidth &&
        cached.sung == sung &&
        cached.unsung == unsung) {
      return;
    }
    final layout = measureKaraokeLine(
      words: widget.line.words,
      maxWidth: maxWidth,
      fontSize: widget.fontSize,
      height: widget.height,
      align: widget.align,
      weight: widget.weight,
      sungColor: sung,
      unsungColor: unsung,
    );
    _layout = layout;

    // 诊断（一次）：量字失败（有效盒=0）时逐字渲染会退回纯文本，
    // 这条日志能直接区分「量字失败」与「数据无词级」。
    if (!_diagMeasured) {
      _diagMeasured = true;
      final valid = layout.wordRects.where((r) => r != null).length;
      AppLog.d('LyricView',
          '卡拉OK量字: 词数=${widget.line.words.length} 有效盒=$valid '
          '视觉行=${layout.rows.length} 文本宽=${layout.unsungPainter.width.toStringAsFixed(0)} '
          '羽化=${layout.feather.toStringAsFixed(1)}');
    }
  }

  bool _diagMeasured = false;

  @override
  void didUpdateWidget(covariant KaraokeLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.line != widget.line ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.height != widget.height ||
        oldWidget.align != widget.align ||
        oldWidget.weight != widget.weight) {
      _layout = null;
    }
  }

  @override
  void dispose() {
    _layout?.dispose();
    _layout = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: widget.head,
        builder: (ctx, posMs, _) => LayoutBuilder(
          builder: (ctx, constraints) {
            final maxWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : double.infinity;
            _measure(maxWidth);
            final layout = _layout;
            // 兜底：没量出来（无字/排版失败）时退回纯未唱色文本
            if (layout == null || layout.rows.isEmpty) {
              return RichText(
                textAlign: widget.align,
                text: TextSpan(
                  children: [
                    for (final w in widget.line.words)
                      TextSpan(
                        text: w.text,
                        style: TextStyle(
                          fontSize: widget.fontSize,
                          height: widget.height,
                          fontWeight: widget.weight,
                          color: _readableUnsung,
                        ),
                      ),
                  ],
                ),
              );
            }
            final ratios = [
              for (final w in widget.line.words) w.progressAt(posMs),
            ];
            return CustomPaint(
              size: Size(
                maxWidth.isFinite ? maxWidth : layout.unsungPainter.width,
                layout.unsungPainter.height,
              ),
              painter: layout.painter(
                ratios: ratios,
                align: widget.align,
                maxWidth: maxWidth.isFinite ? maxWidth : layout.unsungPainter.width,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 一行歌词的排版量字结果（[KaraokeLine] 缓存它，播放期间只重算进度）。
class KaraokeLayout {
  KaraokeLayout({
    required this.wordRects,
    required this.rows,
    required this.unsungPainter,
    required this.sungPainter,
    required this.feather,
    required this.maxWidth,
    required this.sung,
    required this.unsung,
  });

  /// 每个字在行内的盒子（含换行时的 top/bottom）。
  /// null = 该字无文本（QRC 罗马音占位）。
  final List<Rect?> wordRects;

  /// 视觉行分组（AMLL 同款 per-line mask）。
  final List<KaraokeRow> rows;

  final TextPainter unsungPainter;
  final TextPainter sungPainter;

  /// 羽化宽度（半个行高，AMLL wordFadeWidth=0.5）。
  final double feather;

  final double maxWidth;
  final Color sung;
  final Color unsung;

  /// 用当前播放进度构造一帧绘制器。
  KaraokePainter painter({
    required List<double> ratios,
    required TextAlign align,
    required double maxWidth,
  }) =>
      KaraokePainter(
        unsungPainter: unsungPainter,
        sungPainter: sungPainter,
        rows: rows,
        wordRects: wordRects,
        ratios: ratios,
        feather: feather,
        align: align,
        maxWidth: maxWidth,
      );

  void dispose() {
    unsungPainter.dispose();
    sungPainter.dispose();
  }
}

/// 量字 + 按视觉行分组（纯函数，无副作用；[KaraokeLine] 与像素级
/// 测试共用同一份实现，测试验的就是生产代码本身）。
KaraokeLayout measureKaraokeLine({
  required List<LyricWord> words,
  required double maxWidth,
  required double fontSize,
  required double height,
  required TextAlign align,
  required FontWeight weight,
  required Color sungColor,
  required Color unsungColor,
}) {
  TextSpan span(Color color) => TextSpan(
        children: [
          for (final w in words)
            TextSpan(
              text: w.text,
              style: TextStyle(
                fontSize: fontSize,
                height: height,
                fontWeight: weight,
                color: color,
              ),
            ),
        ],
      );

  final painter = TextPainter(
    text: span(unsungColor),
    textAlign: align,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth);

  final rects = List<Rect?>.filled(words.length, null);
  var offset = 0;
  for (var i = 0; i < words.length; i++) {
    final len = words[i].text.length;
    if (len > 0) {
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: offset, extentOffset: offset + len),
      );
      if (boxes.isNotEmpty) {
        var l = double.infinity, r = double.negativeInfinity;
        var t = double.infinity, b = double.negativeInfinity;
        for (final bx in boxes) {
          if (bx.left < l) l = bx.left;
          if (bx.right > r) r = bx.right;
          if (bx.top < t) t = bx.top;
          if (bx.bottom > b) b = bx.bottom;
        }
        rects[i] = Rect.fromLTRB(l, t, r, b);
      }
    }
    offset += len;
  }

  // 按视觉行分组：top 相近（半个字高以内）且 left 递增的字属于同一
  // 显示行。排序键必须含 left——Dart 的 List.sort 不保证稳定，只按
  // top 排序时同一行的词可能乱序，行内渐变 stops 随之乱序被单调保护
  // 丢弃，换行的后半段就染不上色。
  final rows = <KaraokeRow>[];
  final lineTolerance = fontSize * 0.5;
  final order = [
    for (var i = 0; i < rects.length; i++)
      if (rects[i] != null) i,
  ]..sort((a, b) {
      final ra = rects[a]!;
      final rb = rects[b]!;
      final byTop = ra.top.compareTo(rb.top);
      return byTop != 0 ? byTop : ra.left.compareTo(rb.left);
    });
  for (final i in order) {
    final rect = rects[i]!;
    if (rows.isEmpty ||
        (rect.top - rows.last.rect.top).abs() > lineTolerance) {
      rows.add(KaraokeRow(rect: rect, wordIndexes: [i]));
    } else {
      final last = rows.last;
      last.wordIndexes.add(i);
      last.rect = Rect.fromLTRB(
        math.min(last.rect.left, rect.left),
        math.min(last.rect.top, rect.top),
        math.max(last.rect.right, rect.right),
        math.max(last.rect.bottom, rect.bottom),
      );
    }
  }

  final sungPainter = TextPainter(
    text: span(sungColor),
    textAlign: align,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth);

  return KaraokeLayout(
    wordRects: rects,
    rows: rows,
    unsungPainter: painter,
    sungPainter: sungPainter,
    feather: fontSize * height * kKaraokeWordFadeWidth,
    maxWidth: maxWidth,
    sung: sungColor,
    unsung: unsungColor,
  );
}

/// 一个视觉行：同一显示行内的字下标 + 该行的盒子。
class KaraokeRow {
  KaraokeRow({required this.rect, required this.wordIndexes});

  Rect rect;
  final List<int> wordIndexes;
}

/// 逐字卡拉OK绘制器（AMLL 同款思路：底层整行未唱色，每个视觉行
/// 叠一层已唱色，再用该行的分段渐变做 dstIn 遮罩）。
///
/// 遮罩渐变由 [KaraokeFill.build] 产出—— sung 传不透明白、unsung 传
/// 全透明白，dstIn 只取 alpha：已唱段 alpha=1 保留已唱色文字，
/// 未唱段 alpha=0 透出底层的未唱色文字，过渡带（半个行高）柔和扫过。
class KaraokePainter extends CustomPainter {
  KaraokePainter({
    required this.unsungPainter,
    required this.sungPainter,
    required this.rows,
    required this.wordRects,
    required this.ratios,
    required this.feather,
    required this.align,
    required this.maxWidth,
  });

  final TextPainter unsungPainter;
  final TextPainter sungPainter;
  final List<KaraokeRow> rows;
  final List<Rect?> wordRects;
  final List<double> ratios;

  /// 羽化宽度（半个行高），透传给 [KaraokeFill.build]。
  final double feather;
  final TextAlign align;

  /// 绘制约束宽度：居中 / 右对齐时按它算水平偏移。
  final double maxWidth;

  /// 水平对齐偏移。
  ///
  /// TextPainter 单行短文本时 paint 从 (0,0) 起、glyph 不随 textAlign
  /// 偏移（实测三种 align 墨迹都在 [0, 文本宽]），用户设置的「居中」
  /// 会被丢掉。这里手动补偏移：center = 剩余宽度的一半，right = 全部。
  double get _dx {
    switch (align) {
      case TextAlign.center:
        return ((maxWidth - unsungPainter.width) / 2).clamp(0.0, maxWidth);
      case TextAlign.right:
        return (maxWidth - unsungPainter.width).clamp(0.0, maxWidth);
      default:
        return 0;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(_dx, 0);
    // 1) 底层：整行未唱色
    unsungPainter.paint(canvas, Offset.zero);

    // 2) 每个视觉行叠加已唱层 + 渐变遮罩
    const opaqueWhite = Color(0xFFFFFFFF);
    const transparentWhite = Color(0x00FFFFFF);
    for (final row in rows) {
      final rowRatios = [
        for (final i in row.wordIndexes) ratios[i],
      ];
      final allUnsung = rowRatios.every((r) => r <= 0);
      if (allUnsung) continue; // 整行没唱：底层已画，省一次离屏合成
      final allSung = rowRatios.every((r) => r >= 1);

      canvas.saveLayer(row.rect.inflate(2), Paint());

      if (allSung) {
        // 整行唱完：直接画已唱层，无需遮罩
        sungPainter.paint(canvas, Offset.zero);
      } else {
        // 遮罩渐变的字区间以行为基准（第二行从 0 重新开始，各自独立）
        final spans = <List<double>>[
          for (final i in row.wordIndexes)
            wordRects[i] == null
                ? const <double>[]
                : [
                    wordRects[i]!.left - row.rect.left,
                    wordRects[i]!.right - row.rect.left,
                  ],
        ];
        final built = KaraokeFill.build(
          wordSpans: spans,
          ratios: rowRatios,
          width: row.rect.width,
          sung: opaqueWhite,
          unsung: transparentWhite,
          feather: feather,
        );
        sungPainter.paint(canvas, Offset.zero);
        if (built != null) {
          canvas.drawRect(
            row.rect,
            Paint()
              ..blendMode = BlendMode.dstIn
              ..shader = LinearGradient(
                colors: built.$2,
                stops: built.$1,
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ).createShader(row.rect),
          );
        }
      }
      canvas.restore();
    }
    canvas.restore(); // 对齐偏移的 save
  }

  @override
  bool shouldRepaint(covariant KaraokePainter oldDelegate) =>
      oldDelegate.feather != feather ||
      oldDelegate.align != align ||
      oldDelegate.maxWidth != maxWidth ||
      oldDelegate.rows != rows ||
      oldDelegate.wordRects != wordRects ||
      oldDelegate.unsungPainter != unsungPainter ||
      oldDelegate.sungPainter != sungPainter ||
      !listEquals(oldDelegate.ratios, ratios);
}
