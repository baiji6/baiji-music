// 歌词模型 → flutter_lyric（AMLL 风格渲染引擎）的适配层。
//
// 官方 AMLL（applemusic-like-lyrics）只有 DOM / React / Vue 绑定，没有
// Flutter 版；pub.dev 上语义最接近的是 `flutter_lyric`：Canvas 绘制、逐字
// 高亮、词级上弹/悬浮、前奏倒计时、点击跳转、滚动跟随，与 AMLL 的呈现
// 一致。v2.3.0 之前本工程是自绘的卡拉 OK 遮罩（karaoke_line.dart），
// 用户连续三个版本反馈「逐字歌词没有」，因此改用成熟引擎，只在数据层
// 做一次模型转换。
//
// 这里只放**纯函数**（模型转换 + 预设映射），便于单测，也让 UI 保持无逻辑。
library;

import 'package:flutter/material.dart';
// 与内部 `LyricLine` / `LyricWord` 同名，必须加别名
import 'package:flutter_lyric/flutter_lyric.dart' as amll;

import '../core/lyric_settings.dart';
import 'lyric_model.dart';

/// 把内部歌词模型转换为 `flutter_lyric` 的文档。
///
/// - 逐字时间轴（[LyricLine.words]）原样带过去，逐字高亮由引擎负责；
///   只有整行时间的行传 `null`，引擎按预设的 `simulateTiming` 模拟。
/// - 行结束时间 `endMs <= 0`（信息行等无有效时长）传 null，交给引擎按
///   下一行推，避免倒计时/空白判定被 0 长度污染。
/// - 译文优先；没有译文但有罗马音时，罗马音顶上（引擎每行只有一条副文本）。
amll.LyricDocument toLyricDocument(Lyrics lyrics) {
  return amll.LyricDocument(
    lines: [
      for (final l in lyrics.lines)
        amll.LyricLine(
          start: Duration(milliseconds: l.startMs),
          end: l.endMs > 0 ? Duration(milliseconds: l.endMs) : null,
          text: l.displayText,
          translation: l.translation ??
              (l.romanization != null && l.romanization!.isNotEmpty
                  ? l.romanization
                  : null),
          words: l.isWordLevel
              ? [
                  for (final w in l.words)
                    amll.LyricWord(
                      text: w.text,
                      start: Duration(milliseconds: w.startMs),
                      end: Duration(milliseconds: w.endMs),
                    ),
                ]
              : null,
        ),
    ],
  );
}

/// 把本工程的歌词样式设置映射为 AMLL 预设。
///
/// 三色语义对齐 AMLL：非当前行 = 未激活色，当前行底字 = 未唱色，
/// 逐字高亮（唱过的字）= 已唱色。字号/对齐/字重都来自设置页。
amll.LyricPreset lyricPresetFrom(LyricSettings s) {
  final base = amll.LyricPresets.appleMusic;
  return base.copyWith(
    textStyle: TextStyle(
      fontSize: s.fontSize,
      fontWeight: s.inactiveWeight,
      height: 1.35,
      color: s.readableInactiveColor,
    ),
    activeTextStyle: TextStyle(
      fontSize: s.fontSize * s.activeScale,
      fontWeight: s.activeWeight,
      color: s.readableUnsungColor,
    ),
    translationTextStyle: TextStyle(
      fontSize: s.fontSize * 0.6,
      fontWeight: s.inactiveWeight,
      height: 1.3,
      color: s.readableInactiveColor.withValues(alpha: 0.85),
    ),
    activeTranslationTextStyle: TextStyle(
      fontSize: s.fontSize * 0.6 * s.activeScale,
      color: s.readableUnsungColor.withValues(alpha: 0.9),
    ),
    highlight: amll.LyricHighlight.solid(s.readableSungColor, tailFadeWidth: 10),
    // 远处行可见性：appleMusic 预设的行过渡对非当前行施加 fade(.45)，
    // 叠加深色底上的 40% 白文字色后远处行几乎不可见（实测有效亮度
    // 不到背景的 1.15 倍），与参考视频1「灰色但清晰可读、仅虚化」不符。
    // 这里自建过渡：保留 0.92 缩放维持层次，不透明度提到 0.88——灰度
    // 由文字色本身（40% 白）承担，不再用透明度二次打折；虚化仍由
    // 预设自带的 distanceBlur（maxSigma 4）负责。
    lineTransition: amll.LyricLineTransition.effects(const [
      amll.LyricLineEffect.scale(.92),
      amll.LyricLineEffect.fade(.88),
    ]),
    // 预设自带的前奏/间奏圆点是白色的（面向深色底），浅色主题下会隐身；
    // 换成主题已唱色，既看得见又与逐字高亮同源。
    countdown: amll.LyricCountdown(
      color: s.readableSungColor.withValues(alpha: 0.8),
    ),
    textAlign: s.textAlign,
    contentAlignment:
        s.alignLeft
            ? amll.LyricContentAlignment.start
            : amll.LyricContentAlignment.center,
    // 用户停止浏览 5 秒后自动回到当前播放行（与旧实现一致）
    resumeDelay: const Duration(seconds: 5),
    interactive: true,
  );
}
