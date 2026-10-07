import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_logger.dart';
import '../../core/capture_trust.dart';
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
  bool _captureEnabled = false;
  String _captureProxy = '';

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
      _captureEnabled = CaptureTrust.enabled;
      _captureProxy = CaptureTrust.proxy;
    });
  }

  // ===== 抓包调试 =====

  Future<void> _toggleCapture(bool v) async {
    await CaptureTrust.setEnabled(v);
    setState(() => _captureEnabled = v);
    _showSnack(v
        ? '已开启：Dart 层放行中间人证书（抓包工具现在能解密 HTTPS）'
        : '已关闭：恢复严格证书校验');
  }

  Future<void> _editProxy() async {
    final controller = TextEditingController(text: _captureProxy);
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('抓包代理', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('格式 host:port，例如 127.0.0.1:8888',
                style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: '留空 = 不强制代理',
                hintStyle: const TextStyle(
                    fontSize: 13, color: AppColors.textTertiary),
                filled: true,
                fillColor: AppColors.surfaceGlass,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('清空',
                style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存',
                style: TextStyle(color: AppColors.cyan)),
          ),
        ],
      ),
    );
    if (input == null) return;
    await CaptureTrust.setProxy(input);
    if (!mounted) return;
    setState(() => _captureProxy = CaptureTrust.proxy);
    _showSnack(CaptureTrust.proxyEnabled
        ? '代理已设为 ${CaptureTrust.proxy}（重启应用后生效）'
        : '已清除抓包代理');
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
      isScrollControlled: true,
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
      isScrollControlled: true,
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
              const SectionHeader(title: '抓包调试'),
              GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: Icon(
                        Icons.bug_report_rounded,
                        color: _captureEnabled
                            ? AppColors.warning
                            : AppColors.textTertiary,
                        size: 22,
                      ),
                      title: const Text('允许抓包调试',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: const Text(
                        '放行中间人证书，供 Reqable / Charles 解密 HTTPS（正式版同样可开）',
                        style:
                            TextStyle(fontSize: 12, color: AppColors.textTertiary),
                      ),
                      activeColor: AppColors.cyan,
                      value: _captureEnabled,
                      onChanged: _toggleCapture,
                    ),
                    const Divider(height: 1, color: AppColors.strokeGlass, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.router_rounded,
                          color: AppColors.violet, size: 22),
                      title: const Text('抓包代理',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        _captureProxy.isEmpty ? '未设置（走系统/环境变量代理）' : _captureProxy,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textTertiary),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded,
                          color: AppColors.textTertiary),
                      onTap: _editProxy,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Android 端还需在手机上装好抓包工具的 CA（设置 → 安全 → 凭据），'
                  'App 已在 network_security_config 中放行用户证书；'
                  'Dart 层的证书校验由上面的开关控制，两者都要开才能抓全。'
                  '桌面端若抓不到，可在这里填 Reqable 的代理地址（本机一般 127.0.0.1:8888）。',
                  style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
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
    // 固定 72% 屏高 + ListView + 常驻滚动条：
    // QQ 音乐有 17 档（末档 AAC 48），旧的 55% 高度 + SingleChildScrollView
    // 会把末档裁在可视区之外且没有滚动提示。
    return Container(
      height: MediaQuery.of(context).size.height * 0.72,
      decoration: const BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
              child: Text(
                title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ),
            const Divider(height: 1, color: AppColors.strokeGlass),
            Expanded(
              child: Scrollbar(
                thumbVisibility: true,
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
                  itemCount: options.length,
                  itemBuilder: (ctx, i) {
                    final q = options[i];
                    final selected = q == current;
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => onSelect(q),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          decoration: BoxDecoration(
                            color: selected
                                ? AppColors.cyan.withValues(alpha: 0.12)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                selected
                                    ? Icons.check_circle_rounded
                                    : Icons.audiotrack_rounded,
                                size: 18,
                                color: selected
                                    ? AppColors.cyan
                                    : AppColors.textTertiary,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  label(q),
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: selected
                                        ? AppColors.cyan
                                        : AppColors.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
