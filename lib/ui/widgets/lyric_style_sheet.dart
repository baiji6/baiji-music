import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/lyric_settings.dart';
import '../../theme/app_theme.dart';
import 'app_widgets.dart';

/// 歌词样式设置底部弹层：字号 / 对齐 / 当前行放大 / 字重 / 卡片圆角 / 三色。
///
/// 改动即时写入 [LyricSettings]（内部是 [ChangeNotifier]），
/// 播放页的歌词视图监听同一个实例，拖动滑杆时实时预览。
///
/// Miuix 弹层是声明式的：由调用方（设置页）把返回的 widget 挂到
/// [MiuixPopupScope] 内，用 [show] 控制显隐。
Widget showLyricStyleSheet({
  required bool show,
  required VoidCallback onDismiss,
}) {
  return MiuixOverlayBottomSheet(
    show: show,
    title: '歌词显示',
    backgroundColor: AppColors.bg2,
    onDismissRequest: onDismiss,
    content: _LyricStyleSheet(onDismiss: onDismiss),
  );
}

/// 字重档位名（300~900，步进 100）。
const List<String> _weightNames = ['细', '常规', '中等', '半粗', '粗', '特粗', '黑'];

class _LyricStyleSheet extends StatefulWidget {
  const _LyricStyleSheet({required this.onDismiss});

  /// 关闭整个弹层（由设置页的显隐状态驱动）。
  final VoidCallback onDismiss;

  @override
  State<_LyricStyleSheet> createState() => _LyricStyleSheetState();
}

class _LyricStyleSheetState extends State<_LyricStyleSheet> {
  late double _fontSize;
  late bool _alignLeft;
  late double _activeScale;

  /// 色选择器弹窗的显隐与上下文（标题 / 当前色 / 回调）。
  bool _showColorPicker = false;
  String _pickerTitle = '';
  Color _pickerColor = AppColors.karaoke;
  ValueChanged<Color>? _pickerOnPicked;

  @override
  void initState() {
    super.initState();
    _fontSize = LyricSettings.instance.fontSize;
    _alignLeft = LyricSettings.instance.alignLeft;
    _activeScale = LyricSettings.instance.activeScale;
  }

  /// 弹出色选择器（HSV 取色 + 实时预览）。改色即时生效，无需确认。
  void _pickColor(
    String title,
    Color current,
    ValueChanged<Color> onPicked,
  ) {
    setState(() {
      _pickerTitle = title;
      _pickerColor = current;
      _pickerOnPicked = onPicked;
      _showColorPicker = true;
    });
  }

  static String _hex(Color c) {
    final rgb = c.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final s = LyricSettings.instance;
    return Stack(
      children: [
        SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel('字号', Icons.format_size_rounded, AppColors.accent,
                    '${_fontSize.toStringAsFixed(0)} px'),
                MiuixSlider(
                  value: _fontSize,
                  min: LyricSettings.minFontSize,
                  max: LyricSettings.maxFontSize,
                  steps: (LyricSettings.maxFontSize -
                          LyricSettings.minFontSize)
                      .round(),
                  onValueChanged: (v) {
                    setState(() => _fontSize = v);
                    s.setFontSize(v);
                  },
                ),
                _sectionLabel('当前行放大', Icons.zoom_out_map_rounded,
                    AppColors.accentAlt, '${_activeScale.toStringAsFixed(2)}×'),
                MiuixSlider(
                  value: _activeScale,
                  min: LyricSettings.minActiveScale,
                  max: LyricSettings.maxActiveScale,
                  steps: 20,
                  onValueChanged: (v) {
                    setState(() => _activeScale = v);
                    s.setActiveScale(v);
                  },
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                      '正在唱的这一行会按这个倍率放大显示，默认 1.12×（轻微放大）。'
                      '1.00× 表示完全不放大，所有行字号一致——此时歌词的层次完全靠'
                      '颜色区分：当前行逐字填满（唱到的字从左往右填成已唱色），其余行统一暗灰。'
                      '调大后整屏能看到的歌词行会变少。',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textTertiary)),
                ),
                _sectionLabel(
                    '字重',
                    Icons.format_bold_rounded,
                    AppColors.violet,
                    '${s.weight} · ${_weightNames[((s.weight - LyricSettings.minWeight) / 100).round().clamp(0, _weightNames.length - 1)]}'),
                MiuixSlider(
                  value: s.weight.toDouble(),
                  min: LyricSettings.minWeight.toDouble(),
                  max: LyricSettings.maxWeight.toDouble(),
                  steps: (LyricSettings.maxWeight -
                          LyricSettings.minWeight) ~/
                      100,
                  onValueChanged: (v) => s.setWeight(v.round()),
                ),
                _sectionLabel('歌词卡片圆角', Icons.rounded_corner_rounded,
                    AppColors.aqua, '${s.corner.toStringAsFixed(0)} px'),
                MiuixSlider(
                  value: s.corner,
                  min: LyricSettings.minCorner,
                  max: LyricSettings.maxCorner,
                  steps: 40,
                  onValueChanged: (v) => s.setCorner(v),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 6, 20, 8),
                  child: Row(
                    children: [
                      Icon(Icons.palette_rounded,
                          size: 18, color: AppColors.success),
                      SizedBox(width: 10),
                      Text('歌词颜色',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Row(
                    children: [
                      _ColorChip(
                        label: '已唱',
                        color: s.sungColor,
                        defaultColor: AppColors.karaoke,
                        onTap: () => _pickColor(
                            '已唱颜色', s.sungColor, (c) => s.setSungColor(c)),
                      ),
                      const SizedBox(width: 10),
                      _ColorChip(
                        label: '未唱',
                        color: s.unsungColor,
                        defaultColor: AppColors.lyricUnsung,
                        onTap: () => _pickColor('未唱颜色', s.unsungColor,
                            (c) => s.setUnsungColor(c)),
                      ),
                      const SizedBox(width: 10),
                      _ColorChip(
                        label: '非当前行',
                        color: s.inactiveColor,
                        defaultColor: AppColors.lyricInactive,
                        onTap: () => _pickColor('非当前行颜色', s.inactiveColor,
                            (c) => s.setInactiveColor(c)),
                      ),
                      const Spacer(),
                      MiuixTextButton('恢复默认',
                          onPressed: () => s.resetColors()),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: GlassCard(
                    padding: const EdgeInsets.all(14),
                    radius: s.corner,
                    child: SizedBox(
                      width: double.infinity,
                      // 三行模拟真实播放：中间是当前行（放大加粗），上下是普通行
                      child: Column(
                        children: [
                          Text(
                            '♪ 这是一句唱过的歌词',
                            textAlign: s.textAlign,
                            style: TextStyle(
                              fontSize: _fontSize,
                              height: 1.45,
                              color: s.inactiveColor,
                              fontWeight: s.inactiveWeight,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '这是正在唱的当前行',
                            textAlign: s.textAlign,
                            style: TextStyle(
                              fontSize: _fontSize * _activeScale,
                              height: 1.32,
                              color: s.unsungColor,
                              fontWeight: s.activeWeight,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '这是还没唱到的歌词',
                            textAlign: s.textAlign,
                            style: TextStyle(
                              fontSize: _fontSize,
                              height: 1.45,
                              color: s.inactiveColor,
                              fontWeight: s.inactiveWeight,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
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
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: SizedBox(
                    width: double.infinity,
                    child: NeonButton(
                      label: '完成',
                      filled: false,
                      onPressed: widget.onDismiss,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // 色选择器（HSV 取色 + 实时预览）
        MiuixOverlayDialog(
          show: _showColorPicker,
          title: _pickerTitle,
          maxWidth: 360,
          onDismissRequest: () =>
              setState(() => _showColorPicker = false),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MiuixColorPicker(
                color: _pickerColor,
                onColorChanged: (c) {
                  setState(() => _pickerColor = c);
                  _pickerOnPicked?.call(c); // 实时生效，播放页跟着变
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: _pickerColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.strokeGlass),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: MiuixText(
                      _hex(_pickerColor),
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ),
                  MiuixTextButton(
                    '完成',
                    onPressed: () =>
                        setState(() => _showColorPicker = false),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(
      String title, IconData icon, Color accent, String value) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
      child: Row(
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 10),
          Text(title,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(value,
              style: TextStyle(
                  fontSize: 12, color: AppColors.textTertiary)),
        ],
      ),
    );
  }
}

/// 一个颜色入口：色块 + 名称；与默认值不同时显示小圆点提示。
class _ColorChip extends StatelessWidget {
  const _ColorChip({
    required this.label,
    required this.color,
    required this.defaultColor,
    required this.onTap,
  });

  final String label;
  final Color color;
  final Color defaultColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final changed = color != defaultColor;
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.strokeGlass),
              ),
              child: changed
                  ? Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.circle,
                            size: 7, color: AppColors.accent),
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 11, color: AppColors.textSecondary)),
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
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.12)
              : AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.strokeGlass,
            width: selected ? 1.2 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 17,
                color: selected ? AppColors.accent : AppColors.textTertiary),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? AppColors.accent : AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
