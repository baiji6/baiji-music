import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../download/download_extras.dart';
import '../../theme/app_theme.dart';

/// 下载选项弹层内容：**歌词粒度 + 音质**二合一。
///
/// 用于播放页与搜索页的下载入口（QQ 音乐 / 网易云通用）：
/// - 顶部选歌词：不下载 / 逐行歌词 / 逐字歌词，默认跟随全局设置
///   （全局默认为逐字，且没有逐字数据时自动回退逐行，见
///   [DownloadExtras.resolveLyricMode]）；
/// - 下面点音质行即确认下载，与旧版「点音质即下载」的交互一致。
///
/// 泛型 [T] 对应平台音质档（QQ 音质 / 网易云音质），
/// 由调用方传入选项列表与展示方式。
class DownloadOptionsSheet<T> extends StatefulWidget {
  const DownloadOptionsSheet({
    super.key,
    required this.options,
    required this.current,
    required this.label,
    required this.lyricMode,
    required this.onConfirm,
    this.subtitle,
  });

  final List<T> options;
  final T current;
  final String Function(T) label;
  final String Function(T)? subtitle;

  /// 初始选中的歌词粒度（通常传 [DownloadExtras.lyricMode]）。
  final LyricDownloadMode lyricMode;

  /// 点音质行确认：带回所选音质与歌词粒度。
  final void Function(T quality, LyricDownloadMode lyricMode) onConfirm;

  @override
  State<DownloadOptionsSheet<T>> createState() =>
      _DownloadOptionsSheetState<T>();
}

class _DownloadOptionsSheetState<T> extends State<DownloadOptionsSheet<T>> {
  late LyricDownloadMode _lyric = widget.lyricMode;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.62;
    return SizedBox(
      height: height,
      child: Scrollbar(
        thumbVisibility: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
          children: [
            _SectionLabel('歌词（LRC）'),
            for (final m in LyricDownloadMode.values)
              _LyricOptionRow(
                mode: m,
                selected: m == _lyric,
                onTap: () => setState(() => _lyric = m),
              ),
            const SizedBox(height: 10),
            Divider(color: AppColors.strokeGlass, height: 1),
            const SizedBox(height: 10),
            const _SectionLabel('音质'),
            for (final q in widget.options)
              _QualityRow<T>(
                value: q,
                selected: q == widget.current,
                label: widget.label(q),
                subtitle: widget.subtitle?.call(q) ?? '',
                onTap: () => widget.onConfirm(q, _lyric),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6, top: 2),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.textTertiary,
            letterSpacing: 0.5,
          ),
        ),
      );
}

/// 歌词粒度单选行。逐字项带「无逐字自动回退逐行」的说明。
class _LyricOptionRow extends StatelessWidget {
  const _LyricOptionRow({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final LyricDownloadMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.lyrics_outlined,
              size: 18,
              color: selected ? AppColors.accent : AppColors.textTertiary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    mode.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? AppColors.accent
                          : AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    mode.description,
                    style: TextStyle(
                        fontSize: 10, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 音质行：点一下即确认下载（带上当前选中的歌词粒度）。
class _QualityRow<T> extends StatelessWidget {
  const _QualityRow({
    required this.value,
    required this.selected,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final T value;
  final bool selected;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle_rounded : Icons.audiotrack_rounded,
              size: 18,
              color: selected ? AppColors.accent : AppColors.textTertiary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                      color:
                          selected ? AppColors.accent : AppColors.textPrimary,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: TextStyle(
                          fontSize: 10, color: AppColors.textTertiary),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
