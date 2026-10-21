import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/app_theme.dart';

/// 搜索页的平台下拉选择器（v2.4.0）。
///
/// 视觉与「酷我」App 一致：搜索框**左侧内嵌**一个带下拉箭头的平台名，
/// 点击展开菜单列出全部平台（QQ 音乐 / 网易云音乐 / 酷我音乐）。
///
/// 与旧版右上角的分段器（[_SourceSwitch]）相比，这个形态：
/// - 更贴近用户提供的视频效果（搜索栏左侧切换平台）；
/// - 三个平台时右上角放不下，分段器会被挤扁。
class PlatformPicker extends StatelessWidget {
  const PlatformPicker({
    super.key,
    required this.current,
    required this.onChanged,
  });

  /// 当前平台（[Source.qq] / [Source.netease] / [Source.kuwo]）。
  final String current;

  /// 平台切换回调。
  final ValueChanged<String> onChanged;

  /// 平台展示信息。
  static List<({String id, String label, Color color})> get platforms => [
        (id: Source.qq, label: 'QQ 音乐', color: AppColors.accent),
        (id: Source.netease, label: '网易云', color: AppColors.accentAlt),
        (id: Source.kuwo, label: '酷我', color: const Color(0xFF3B82F6)),
      ];

  static ({String label, Color color}) infoOf(String source) {
    for (final p in platforms) {
      if (p.id == source) return (label: p.label, color: p.color);
    }
    return (label: 'QQ 音乐', color: AppColors.accent);
  }

  @override
  Widget build(BuildContext context) {
    final info = infoOf(current);
    return PopupMenuButton<String>(
      tooltip: '切换平台',
      position: PopupMenuPosition.under,
      color: AppColors.bg2,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.strokeGlass),
      ),
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final p in platforms)
          PopupMenuItem<String>(
            value: p.id,
            height: 42,
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: p.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  p.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: p.id == current ? FontWeight.w700 : FontWeight.w500,
                    color: p.id == current ? p.color : AppColors.textSecondary,
                  ),
                ),
                if (p.id == current) ...[
                  const Spacer(),
                  Icon(Icons.check_rounded, size: 16, color: p.color),
                ],
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: info.color.withValues(alpha: 0.12),
          border: Border.all(color: info.color.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              info.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: info.color,
              ),
            ),
            Icon(Icons.arrow_drop_down_rounded, size: 18, color: info.color),
          ],
        ),
      ),
    );
  }
}
