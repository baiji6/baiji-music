import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/app_version.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// 关于页。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MiuixScaffold(
      containerColor: Colors.transparent,
      topBar: MiuixTopAppBar(
        title: '关于',
        titleColor: AppColors.skyBlue,
        color: Colors.transparent,
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary, size: 20),
        ),
      ),
      content: (padding) => SingleChildScrollView(
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
                    color: AppColors.accentAlt.withValues(alpha: 0.4),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 40),
            ),
            SizedBox(height: 20),
            const NeonText(
              '白姬音乐',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              AppVersion.display,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            GlassCard(
              child: Column(
                children: [
                  _infoTile('平台支持', 'iOS / macOS / Windows / Linux / Android'),
                  MiuixHorizontalDivider(
                      thickness: 1, color: AppColors.strokeGlass),
                  _infoTile('音源', 'QQ 音乐 + 网易云音乐'),
                  MiuixHorizontalDivider(
                      thickness: 1, color: AppColors.strokeGlass),
                  _infoTile('技术栈', 'Flutter 3.47 · Dart · 纯 Dart 加密'),
                  MiuixHorizontalDivider(
                      thickness: 1, color: AppColors.strokeGlass),
                  _infoTile('构建加固', 'R8 / UPX / Dart Obfuscate / Strip'),
                  MiuixHorizontalDivider(
                      thickness: 1, color: AppColors.strokeGlass),
                  _infoTile('作者', '白姬9527'),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
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
          Text(label, style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
