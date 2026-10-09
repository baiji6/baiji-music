import 'package:flutter/material.dart';

import '../../core/lyric_settings.dart';
import '../../theme/app_theme.dart';
import 'app_widgets.dart';

/// 歌词样式设置底部弹层：字号滑杆 + 左对齐 / 居中。
///
/// 改动即时写入 [LyricSettings]（内部是 [ChangeNotifier]），
/// 播放页的歌词视图监听同一个实例，拖动滑杆时实时预览。
Future<void> showLyricStyleSheet(BuildContext context) {
  final settings = LyricSettings.instance;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => const _LyricStyleSheet(),
  ).then((_) => settings);
}

class _LyricStyleSheet extends StatefulWidget {
  const _LyricStyleSheet();

  @override
  State<_LyricStyleSheet> createState() => _LyricStyleSheetState();
}

class _LyricStyleSheetState extends State<_LyricStyleSheet> {
  late double _fontSize;
  late bool _alignLeft;

  @override
  void initState() {
    super.initState();
    _fontSize = LyricSettings.instance.fontSize;
    _alignLeft = LyricSettings.instance.alignLeft;
  }

  @override
  Widget build(BuildContext context) {
    final s = LyricSettings.instance;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.strokeGlass,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 6, 20, 12),
              child: Text(
                '歌词显示',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ),
            const Divider(height: 1, color: AppColors.strokeGlass),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  const Icon(Icons.format_size_rounded,
                      size: 18, color: AppColors.cyan),
                  const SizedBox(width: 10),
                  const Text('字号',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text(
                    '${_fontSize.toStringAsFixed(0)} px',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
            Slider(
              value: _fontSize,
              min: LyricSettings.minFontSize,
              max: LyricSettings.maxFontSize,
              divisions:
                  (LyricSettings.maxFontSize - LyricSettings.minFontSize)
                      .round(),
              activeColor: AppColors.cyan,
              onChanged: (v) {
                setState(() => _fontSize = v);
                s.setFontSize(v);
              },
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 6, 20, 8),
              child: Row(
                children: [
                  Icon(Icons.format_align_left_rounded,
                      size: 18, color: AppColors.violet),
                  SizedBox(width: 10),
                  Text('对齐方式',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Row(
                children: [
                  Expanded(
                    child: _AlignOption(
                      icon: Icons.format_align_left_rounded,
                      label: '左对齐',
                      selected: _alignLeft,
                      onTap: () {
                        setState(() => _alignLeft = true);
                        s.setAlignLeft(true);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AlignOption(
                      icon: Icons.format_align_center_rounded,
                      label: '居中',
                      selected: !_alignLeft,
                      onTap: () {
                        setState(() => _alignLeft = false);
                        s.setAlignLeft(false);
                      },
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
              child: GlassCard(
                padding: const EdgeInsets.all(14),
                radius: 16,
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    '白姬音乐 · 歌词预览效果',
                    textAlign: s.textAlign,
                    style: TextStyle(
                      fontSize: _fontSize,
                      height: 1.45,
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: NeonButton(
                  label: '完成',
                  filled: false,
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlignOption extends StatelessWidget {
  const _AlignOption({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.cyan.withValues(alpha: 0.12)
                : AppColors.surfaceGlass,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? AppColors.cyan : AppColors.strokeGlass,
              width: selected ? 1.2 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 17,
                  color: selected ? AppColors.cyan : AppColors.textTertiary),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? AppColors.cyan : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
