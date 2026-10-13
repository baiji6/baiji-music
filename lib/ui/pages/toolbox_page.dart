/// 工具箱页面。
///
/// 收录本地音频相关的实用工具。后续要加工具就在 [_tools] 里加一项，
/// 页面结构不用动。
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
    return MiuixScaffold(
      containerColor: Colors.transparent,
      topBar: MiuixTopAppBar(
        title: '工具箱',
        titleColor: AppColors.skyBlue,
        color: Colors.transparent,
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary, size: 20),
        ),
      ),
      content: (padding) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          const SectionHeader(title: '音乐工具'),
          _ToolCard(
            icon: Icons.lock_open_rounded,
            color: AppColors.accent,
            title: '本地音乐解密',
            subtitle: 'QQ 音乐 · 酷狗 · 酷我 · 网易云 · 咪咕',
            description: '批量解密已下载的加密音频文件，支持导入密钥与手动填写，'
                '可自定义保存位置。解密后的文件可直接在「本地音乐」里播放。',
            page: const DecryptPage(),
          ),
          _ToolCard(
            icon: Icons.vpn_key_rounded,
            color: AppColors.skyBlue,
            title: '解密密钥管理',
            subtitle: 'ekey · 平台密钥',
            description: '按平台整理解密密钥，支持导入、编辑与删除。'
                '批量解密前可以先在这里把密钥准备好。',
            page: const DecryptKeysPage(),
          ),
          const SectionHeader(title: '诊断工具'),
          _ToolCard(
            icon: Icons.article_outlined,
            color: AppColors.success,
            title: '运行日志',
            subtitle: '抓包 · 崩溃 · 播放记录',
            description: '实时查看应用运行日志，按级别筛选、导出分享。'
                '遇到闪退或播放异常时，这里是定位问题的第一现场。',
            page: const LogPage(),
          ),
        ],
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.page,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String description;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GlassCard(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => page),
        ),
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
                      Text(
                        subtitle,
                        style: TextStyle(fontSize: 11, color: color),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}
