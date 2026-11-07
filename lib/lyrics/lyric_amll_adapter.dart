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
/// 视觉对齐参考实现 kunyin（ikunshare/kunyin，Apple Music 风格歌词）：
/// - **当前行只靠不透明度 / 颜色区分，不做放大**：非当前行 0.4 白、当前行未唱
///   0.6 白、逐字已唱纯白 1.0——层次完全由文字色建立，当前行字号与相邻行
///   一致（[LyricSettings.defaultActiveScale]=1.0），避免「当前行大一号」撑开行距。
/// - **逐字软边擦除**：已唱歌词纯白不透明，未唱部分半透明白，尾迹柔边
///   （[LyricHighlight] 的 tailFadeWidth）做平滑扫光。
/// - **译文在主词下方**：translation 文本排在正文之下，行距单独留白。
/// - **距离模糊关闭**：[LyricDistanceBlur.maxSigma]=0，远处行不再高斯模糊
///   （中端机逐帧模糊开销大，且 kunyin 默认不开）。
/// - **平滑滚动锚点居中**：[LyricAnchor.fraction]=0.5，当前行停在视口正中。
/// - **间奏圆点**：[LyricCountdown] 主题化到已唱色，前奏 / 间奏显示呼吸圆点。
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
      height: 1.35,
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
    highlight: amll.LyricHighlight.solid(s.readableSungColor, tailFadeWidth: 14),
    // 不缩放非当前行：层次全靠文字色（非当前 0.4 / 当前未唱 0.6 / 已唱 1.0）。
    // 空 effects 表示 inactive 态为恒等变换，缩放与额外淡入都交给文字色本身，
    // 对应 kunyin「当前行不放大、只靠不透明度区分」。逐字卡拉 OK 填充与
    // 当前行配色过渡仍由引擎按 playback 进度平滑驱动。
    lineTransition: amll.LyricLineTransition.effects(const []),
    // kunyin 默认关闭远处行虚化：maxSigma=0 彻底关掉逐帧高斯模糊（既省
    // 中端机开销，也避免远处行被糊掉看不清）。
    distanceBlur:
        const amll.LyricDistanceBlur(maxSigma: 0, sigmaPerLine: 0, whenBrowsing: false),
    countdown: amll.LyricCountdown(
      color: s.readableSungColor.withValues(alpha: 0.8),
    ),
    // 平滑滚动锚点居中：当前播放行停在视口正中（kunyin 默认 0.5）。
    activeAnchor:
        const amll.LyricAnchor.fraction(0.5, target: amll.LyricAnchorTarget.mainText),
    selectionAnchor:
        const amll.LyricAnchor.fraction(0.5, target: amll.LyricAnchorTarget.mainText),
    // 译文与主词之间留白，保证译文清晰排在正文下方。
    translationSpacing: 10,
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
