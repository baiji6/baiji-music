import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../download/download_extras.dart';
import '../../theme/app_theme.dart';

/// 下载选项弹层内容：**歌词 + 音质**二合一。
///
/// 用于播放页与搜索页的下载入口（QQ 音乐 / 网易云通用）：
/// - 顶部歌词区点某一行 = **只下载歌词文件**（独立动作，不下载音乐），
///   同时该行成为选中态；没有逐字数据时逐字项自动回退逐行落盘；
/// - 下面音质区点某一行 = 下载音乐，并**自动附带**当前选中的歌词与封面
///   （歌词粒度即上面选中的那行）。
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
    required this.onLyricOnly,
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

  /// 点歌词行（逐行/逐字）：只下载歌词文件，不下载音乐。
  final void Function(LyricDownloadMode mode) onLyricOnly;

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
            const _SectionLabel('歌词 · 点此只下载歌词'),
            for (final m in LyricDownloadMode.values)
              _LyricOptionRow(
                mode: m,
                selected: m == _lyric,
                onTap: () {
                  setState(() => _lyric = m);
                  // 「不下载」只是取消选中态；逐行/逐字即独立下载歌词文件
                  if (m != LyricDownloadMode.off) {
                    widget.onLyricOnly(m);
                  }
                },
              ),
            const SizedBox(height: 10),
            Divider(color: AppColors.strokeGlass, height: 1),
            const SizedBox(height: 10),
            const _SectionLabel('下载音乐 · 自动附带所选歌词与封面'),
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

/// 歌词粒度单选行。逐字项带「无逐字自动回退逐行」的说明；
/// 点击即触发独立歌词下载，行尾的「仅下载」徽标提示这一语义。
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
            if (mode != LyricDownloadMode.off)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.strokeGlass,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('仅下载',
                    style: TextStyle(
                        fontSize: 10, color: AppColors.textSecondary)),
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
