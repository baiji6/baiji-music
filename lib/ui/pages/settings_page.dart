import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_logger.dart';
import '../../core/update_checker.dart';
import '../../download/download_manager.dart';
import '../../models/models.dart';
import '../../network/music_api.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'qq_login_page.dart';
import 'netease_login_page.dart';

/// 设置页面：音质偏好、下载目录、缓存管理、账号信息。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _downloadPath = '';
  Quality _qqQuality = Quality.playbackDefault;
  NeteaseQuality _neQuality = NeteaseQuality.playbackDefault;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final dir = await DownloadManager.instance.getDownloadDir();
    final player = PlayerController.instance;
    setState(() {
      _downloadPath = dir.path;
      _qqQuality = player.currentQuality;
      _neQuality = player.currentNeteaseQuality;
    });
  }

  Future<void> _pickDownloadDir() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath();
      if (result == null || result.isEmpty) return;
      await DownloadManager.instance.setDownloadDir(result);
      setState(() => _downloadPath = result);
      _showSnack('下载目录已更新');
    } catch (e) {
      AppLog.w('SettingsPage', '选择目录失败: $e');
      _showSnack('选择目录失败: $e', isError: true);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: isError ? AppColors.danger : AppColors.cyan,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _selectQQQuality() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _QualitySheet(
        title: 'QQ 音乐播放音质',
        options: Quality.playbackOptions,
        current: _qqQuality,
        label: (q) => q.label,
        onSelect: (q) {
          PlayerController.instance.saveDefaultQuality(q);
          setState(() => _qqQuality = q);
          Navigator.pop(ctx);
          _showSnack('QQ 音质已设为 ${q.label}');
        },
      ),
    );
  }

  void _selectNeteaseQuality() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _QualitySheet(
        title: '网易云音乐播放音质',
        options: NeteaseQuality.playbackOptions,
        current: _neQuality,
        label: (q) => q.label,
        onSelect: (q) {
          PlayerController.instance.saveNeteaseQuality(q);
          setState(() => _neQuality = q);
          Navigator.pop(ctx);
          _showSnack('网易云音质已设为 ${q.label}');
        },
      ),
    );
  }

  Future<void> _resetDownloadDir() async {
    final defaultDir = await DownloadManager.instance.getDefaultDownloadDir();
    await DownloadManager.instance.setDownloadDir(defaultDir.path);
    setState(() => _downloadPath = defaultDir.path);
    _showSnack('已恢复默认下载目录');
  }

  Future<void> _checkUpdate() async {
    setState(() => _checkingUpdate = true);
    try {
      final info = await UpdateChecker.instance.check();
      if (!mounted) return;
      if (info != null) {
        _showUpdateDialog(info);
      } else {
        _showSnack('当前已是最新版本', isError: false);
      }
    } catch (e) {
      if (mounted) _showSnack('检查更新失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('发现新版本', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '最新版本: ${info.tag}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              info.body.isNotEmpty ? info.body.substring(0, info.body.length > 200 ? 200 : info.body.length) : '',
              style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后', style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              UpdateChecker.instance.openRelease(info.url);
            },
            child: const Text('前往更新', style: TextStyle(color: AppColors.cyan)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('设置'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(title: '音质设置'),
              GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.equalizer_rounded, color: AppColors.cyan, size: 22),
                      title: const Text('QQ 音乐播放音质', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: Text(_qqQuality.label, style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: _selectQQQuality,
                    ),
                    const Divider(height: 1, color: AppColors.strokeGlass, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.equalizer_rounded, color: AppColors.magenta, size: 22),
                      title: const Text('网易云音乐播放音质', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: Text(_neQuality.label, style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: _selectNeteaseQuality,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const SectionHeader(title: '下载设置'),
              GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.folder_rounded, color: AppColors.violet, size: 22),
                      title: const Text('下载目录', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        _downloadPath.isEmpty ? '默认目录' : _downloadPath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: _pickDownloadDir,
                    ),
                    const Divider(height: 1, color: AppColors.strokeGlass, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.restore_rounded, color: AppColors.textTertiary, size: 22),
                      title: const Text('恢复默认目录', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: _resetDownloadDir,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const SectionHeader(title: '账号'),
              GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        AppServices.instance.qq.isLoggedIn() ? Icons.verified_rounded : Icons.person_outline,
                        color: AppServices.instance.qq.isLoggedIn() ? AppColors.cyan : AppColors.textTertiary,
                        size: 22,
                      ),
                      title: const Text('QQ 音乐', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        AppServices.instance.qq.isLoggedIn()
                            ? '已登录: ${AppServices.instance.qq.credential.strMusicid}'
                            : '未登录 · 点击登录',
                        style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(builder: (_) => const QQLoginPage()),
                      ),
                    ),
                    const Divider(height: 1, color: AppColors.strokeGlass, indent: 56),
                    ListTile(
                      leading: Icon(
                        AppServices.instance.netease.isLoggedIn() ? Icons.verified_rounded : Icons.person_outline,
                        color: AppServices.instance.netease.isLoggedIn() ? AppColors.magenta : AppColors.textTertiary,
                        size: 22,
                      ),
                      title: const Text('网易云音乐', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        AppServices.instance.netease.isLoggedIn() ? '已登录' : '未登录 · 点击登录',
                        style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(builder: (_) => const NeteaseLoginPage()),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const SectionHeader(title: '关于'),
              GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.system_update_rounded, color: AppColors.violet, size: 22),
                  title: const Text('检查更新', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: const Text('手动检查最新版本', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                  trailing: _checkingUpdate
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.cyan))
                      : const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                  onTap: _checkingUpdate ? null : _checkUpdate,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 音质选择底部弹层（泛型支持 QQ 和网易云）。
class _QualitySheet<T> extends StatelessWidget {
  const _QualitySheet({
    required this.title,
    required this.options,
    required this.current,
    required this.label,
    required this.onSelect,
  });

  final String title;
  final List<T> options;
  final T current;
  final String Function(T) label;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
      decoration: const BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.55,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final q in options)
                    ListTile(
                      dense: true,
                      title: Text(
                        label(q),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: q == current ? FontWeight.w700 : FontWeight.w500,
                          color: q == current ? AppColors.cyan : AppColors.textPrimary,
                        ),
                      ),
                      trailing: q == current
                          ? const Icon(Icons.check_rounded, color: AppColors.cyan, size: 20)
                          : null,
                      onTap: () => onSelect(q),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
