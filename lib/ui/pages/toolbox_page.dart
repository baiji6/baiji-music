/// 工具箱页面。
///
/// 目前收录「本地音乐解密」一个工具。后续要加工具就在 [_tools] 里加一项，
/// 页面结构不用动。
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'decrypt_page.dart';

class ToolboxPage extends StatelessWidget {
  const ToolboxPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('工具箱'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: const [
          SectionHeader(title: '音乐工具'),
          _ToolCard(
            icon: Icons.lock_open_rounded,
            color: AppColors.cyan,
            title: '本地音乐解密',
            subtitle: 'QQ 音乐 · 酷狗 · 酷我 · 网易云 · 咪咕',
            description: '批量解密已下载的加密音频文件，支持导入密钥与手动填写，'
                '可自定义保存位置。解密后的文件可直接在「本地音乐」里播放。',
            page: DecryptPage(),
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
                        style: const TextStyle(
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
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}
