import 'package:flutter/material.dart';

import '../../core/app_version.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// 关于页。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('关于'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: AppColors.neonGradient),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.magenta.withValues(alpha: 0.4),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 40),
            ),
            const SizedBox(height: 20),
            const NeonText(
              '白姬音乐',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              AppVersion.display,
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            GlassCard(
              child: Column(
                children: [
                  _infoTile('平台支持', 'iOS / macOS / Windows / Linux / Android'),
                  const Divider(height: 1, color: AppColors.strokeGlass),
                  _infoTile('音源', 'QQ 音乐 + 网易云音乐'),
                  const Divider(height: 1, color: AppColors.strokeGlass),
                  _infoTile('技术栈', 'Flutter 3.47 · Dart · 纯 Dart 加密'),
                  const Divider(height: 1, color: AppColors.strokeGlass),
                  _infoTile('构建加固', 'R8 / UPX / Dart Obfuscate / Strip'),
                  const Divider(height: 1, color: AppColors.strokeGlass),
                  _infoTile('作者', '白姬9527'),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '© 2024-2026 白姬音乐. All rights reserved.',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
