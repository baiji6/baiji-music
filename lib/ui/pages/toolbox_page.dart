/// 工具箱页面。
///
/// 收录本地音频相关的实用工具。v2.2.7 起视觉与设置页统一：
/// 分区头 + 一张玻璃卡 + 卡内多行（divider 分隔），不再是孤立大卡。
/// 后续要加工具就往 [_musicTools] / [_diagTools] 里加一项。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'decrypt_keys_page.dart';
import 'decrypt_page.dart';
import 'log_page.dart';

class ToolboxPage extends StatelessWidget {
  const ToolboxPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '工具箱',
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      child: ListView(
        children: [
          SectionHeader(
              title: '音乐工具', icon: Icons.build_outlined),
          GlassCard(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                _ToolRow(
                  icon: Icons.lock_open_rounded,
                  color: AppColors.accent,
                  title: '本地音乐解密',
                  tag: 'QQ 音乐 · 酷狗 · 酷我 · 网易云 · 咪咕',
                  description: '批量解密已下载的加密音频文件，支持导入密钥与手动填写，'
                      '可自定义保存位置。解密后的文件可直接在「本地音乐」里播放。',
                  page: DecryptPage(),
                ),
                MiuixHorizontalDivider(
                    thickness: 1, color: AppColors.strokeGlass),
                _ToolRow(
                  icon: Icons.vpn_key_rounded,
                  color: AppColors.skyBlue,
                  title: '解密密钥管理',
                  tag: 'ekey · 平台密钥',
                  description: '按平台整理解密密钥，支持导入、编辑与删除。'
                      '批量解密前可以先在这里把密钥准备好。',
                  page: DecryptKeysPage(),
                ),
              ],
            ),
          ),
          SizedBox(height: 24),
          SectionHeader(
              title: '诊断工具', icon: Icons.bug_report_outlined),
          GlassCard(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                _ToolRow(
                  icon: Icons.article_outlined,
                  color: AppColors.success,
                  title: '运行日志',
                  tag: '抓包 · 崩溃 · 播放记录',
                  description: '实时查看应用运行日志，按级别筛选、导出分享。'
                      '遇到闪退或播放异常时，这里是定位问题的第一现场。',
                  page: LogPage(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 工具箱列表行：与设置页的偏好行同一视觉语言
/// （彩色图标容器 + 标题 + 标签 + 描述 + 箭头）。
class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.tag,
    required this.description,
    required this.page,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String tag;
  final String description;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return MiuixPressable(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => page),
      ),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题 + 标签同行：标签可收缩，长标签不再把 Row 撑爆
                  Row(
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          tag,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: color),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 11),
              child: Icon(Icons.chevron_right_rounded,
                  color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
