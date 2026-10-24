// 平台切换标签（#143 / #145）：内联三标签，点一下就切。
//
// 与 PlatformPicker（下拉菜单）的区别：这个用在分区标题右侧 /
// 分区内容上方，切换零层级。discover_home 与 library_home 共用。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../models/models.dart';
import '../../theme/app_theme.dart';
import 'platform_picker.dart';

class PlatformChips extends StatelessWidget {
  const PlatformChips({
    super.key,
    required this.current,
    required this.onChanged,
    this.compact = false,
  });

  final String current;
  final ValueChanged<String> onChanged;

  /// 紧凑模式（分区标题右侧空间有限时用两字简称）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final p in PlatformPicker.platforms) ...[
          if (p.id != PlatformPicker.platforms.first.id)
            const SizedBox(width: 6),
          MiuixPressable(
            onPressed: () => onChanged(p.id),
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: EdgeInsets.symmetric(
                  horizontal: compact ? 7 : 9,
                  vertical: compact ? 3 : 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: p.id == current
                    ? p.color.withValues(alpha: 0.16)
                    : Colors.transparent,
                border: Border.all(
                  color: p.id == current
                      ? p.color.withValues(alpha: 0.55)
                      : AppColors.strokeGlass,
                ),
              ),
              child: Text(
                compact ? _short(p.id) : p.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight:
                      p.id == current ? FontWeight.w700 : FontWeight.w500,
                  color:
                      p.id == current ? p.color : AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  static String _short(String id) {
    if (id == Source.netease) return '网易';
    if (id == Source.kuwo) return '酷我';
    return 'QQ';
  }
}
