import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_logger.dart';
import '../../core/cache_manager.dart';
import '../../core/capture_trust.dart';
import '../../core/lyric_settings.dart';
import '../../core/update_checker.dart';
import '../../download/download_extras.dart';
import '../../download/download_manager.dart';
import '../../models/models.dart';
import '../../network/music_api.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/agreement_dialog.dart';
import '../widgets/app_widgets.dart';
import '../widgets/cover_image.dart';
import '../widgets/lyric_style_sheet.dart';
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
  String _cachePath = '';
  int _cacheMemoryMb = 100;
  String _cacheSize = '计算中…';
  Quality _qqQuality = Quality.playbackDefault;
  NeteaseQuality _neQuality = NeteaseQuality.playbackDefault;
  bool _checkingUpdate = false;
  bool _captureEnabled = false;
  String _captureProxy = '';
  LyricDownloadMode _lyricMode = LyricDownloadMode.line;
  bool _saveCover = true;

  LyricSettings get _lyricStyle => LyricSettings.instance;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final dir = await DownloadManager.instance.getDownloadDir();
    final player = PlayerController.instance;
    final cacheRoot = await CacheManager.cacheRoot();
    if (!mounted) return;
    setState(() {
      _downloadPath = dir.path;
      _cachePath = cacheRoot.path;
      _cacheMemoryMb = CacheManager.memoryLimitMb;
      _qqQuality = player.currentQuality;
      _neQuality = player.currentNeteaseQuality;
      _captureEnabled = CaptureTrust.enabled;
      _captureProxy = CaptureTrust.proxy;
      _lyricMode = DownloadExtras.lyricMode;
      _saveCover = DownloadExtras.saveCover;
    });
    _refreshCacheSize();
  }

  /// 缓存占用统计要递归扫盘，放后台算，别卡住设置页首帧。
  Future<void> _refreshCacheSize() async {
    final total = await CacheManager.totalBytes();
    if (!mounted) return;
    setState(() => _cacheSize = CacheManager.formatBytes(total));
  }

  // ===== 下载附加项（歌词 / 封面） =====

  Future<void> _selectLyricMode() async {
    final picked = await showModalBottomSheet<LyricDownloadMode>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _LyricModeSheet(current: _lyricMode),
    );
    if (picked == null || !mounted) return;
    await DownloadExtras.setLyricMode(picked);
    if (!mounted) return;
    setState(() => _lyricMode = picked);
  }

  Future<void> _toggleSaveCover(bool v) async {
    await DownloadExtras.setSaveCover(v);
    if (!mounted) return;
    setState(() => _saveCover = v);
  }

  // ===== 抓包调试 =====

  Future<void> _toggleCapture(bool v) async {
    await CaptureTrust.setEnabled(v);
    if (!mounted) return;
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
      if (!mounted) return;
      setState(() => _downloadPath = result);
      _showSnack('下载目录已更新');
    } catch (e) {
      AppLog.w('SettingsPage', '选择目录失败: $e');
      if (!mounted) return;
      _showSnack('选择目录失败: $e', isError: true);
    }
  }

  Future<void> _pickCacheDir() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择缓存目录',
      );
      if (result == null || result.isEmpty) return;
      // setCustomRoot 会校验：目录里已有别的文件就拒绝，避免日后清理时误删
      await CacheManager.setCustomRoot(result);
      final root = await CacheManager.cacheRoot();
      if (!mounted) return;
      setState(() => _cachePath = root.path);
      _showSnack('缓存目录已更新');
      _refreshCacheSize();
    } on StateError catch (e) {
      AppLog.w('SettingsPage', '缓存目录被拒绝: ${e.message}');
      if (!mounted) return;
      _showSnack(e.message, isError: true);
    } catch (e) {
      AppLog.w('SettingsPage', '选择缓存目录失败: $e');
      if (!mounted) return;
      _showSnack('选择目录失败: $e', isError: true);
    }
  }

  Future<void> _resetCacheDir() async {
    await CacheManager.setCustomRoot(null);
    final root = await CacheManager.cacheRoot();
    if (!mounted) return;
    setState(() => _cachePath = root.path);
    _showSnack('已恢复默认缓存目录');
    _refreshCacheSize();
  }

  Future<void> _selectCacheMemoryLimit() async {
    const presets = [32, 64, 100, 200, 400, 800];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _QualitySheet(
        title: '内存图片缓存上限',
        options: presets,
        current: _cacheMemoryMb,
        label: (v) => '$v MB',
        onSelect: (v) async {
          // Navigator / SnackBar 都得用 sheet 的 ctx，先在 await 之前取好
          final nav = Navigator.of(ctx);
          await CacheManager.setMemoryLimitMb(v);
          CacheManager.applyMemoryLimit();
          if (!mounted) return;
          setState(() => _cacheMemoryMb = v);
          nav.pop();
          _showSnack('内存图片缓存上限设为 $v MB');
        },
      ),
    );
  }

  Future<void> _clearCache() async {
    final entries = await CacheManager.breakdown();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('清理缓存', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in entries) ...[
              Text(
                '${e.label} · ${e.readable}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              if (e.detail.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 6),
                  child: Text(
                    e.detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                  ),
                ),
            ],
            const SizedBox(height: 4),
            const Text(
              '只会删除内存中的封面缓存与缓存目录里的临时文件（含日志导出）。'
              '下载的歌曲、播放历史、歌单与本地音乐库都不受影响。',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清理', style: TextStyle(color: AppColors.cyan)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final freed = await CacheManager.clear();
    // 本地歌曲封面另有一份独立内存缓存，在 ui 层，这里一并清掉
    LocalCoverCache.clear();
    if (!mounted) return;
    _showSnack(
      freed <= 0 ? '缓存已清理' : '缓存已清理，释放 ${CacheManager.formatBytes(freed)}',
    );
    _refreshCacheSize();
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
    if (!mounted) return;
    setState(() => _downloadPath = defaultDir.path);
    _showSnack('已恢复默认下载目录');
  }

  Future<void> _checkUpdate() async {
    setState(() => _checkingUpdate = true);
    try {
      // force: 手动检查时忽略「此版本已忽略」的记录
      final outcome = await UpdateChecker.instance.check(force: true);
      if (!mounted) return;
      switch (outcome.state) {
        case UpdateState.available:
          _showUpdateDialog(outcome.info!);
        case UpdateState.upToDate:
          _showSnack('当前已是最新版本');
        case UpdateState.failed:
          _showSnack(outcome.message ?? '检查更新失败', isError: true);
      }
    } catch (e) {
      if (mounted) _showSnack('检查更新失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  /// 更新弹窗：完整渲染 Release 的更新日志（Markdown），可上下滚动。
  ///
  /// 以前这里直接 `Text(info.summary(200))` —— 既只有前 200 字，
  /// 又把 `##` `**` `-` 这类标记原样显示出来。
  void _showUpdateDialog(UpdateInfo info) {
    final media = MediaQuery.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.bg2,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            // 留出上下按钮的高度，日志区自己滚
            maxHeight: media.size.height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Row(
                  children: [
                    const Icon(Icons.system_update_rounded,
                        color: AppColors.cyan, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        info.name.isNotEmpty
                            ? '${info.name}（${info.tag}）'
                            : info.tag,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.strokeGlass),
              Flexible(
                child: Container(
                  width: double.infinity,
                  alignment: Alignment.topLeft,
                  padding: const EdgeInsets.fromLTRB(20, 14, 14, 8),
                  child: SingleChildScrollView(
                    child: info.body.trim().isEmpty
                        ? const Text('该版本没有提供更新说明。',
                            style: TextStyle(
                                fontSize: 12, color: AppColors.textTertiary))
                        : MarkdownBody(
                            data: info.body,
                            selectable: true,
                            styleSheet: _changelogSheet,
                            // 更新日志里的图片多是 badge，加载不出来时别把布局撑破。
                            // 宽度不能写死：Dialog 在窄屏上可用宽度只有 280 出头，
                            // 写死 320 会直接 RenderFlex 溢出。
                            imageBuilder: (uri, title, alt) => ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 260),
                              child: Image.network(
                                uri.toString(),
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stack) => Text(
                                  alt?.isNotEmpty == true ? alt! : '[图片]',
                                  style: const TextStyle(
                                      fontSize: 11, color: AppColors.textTertiary),
                                ),
                              ),
                            ),
                            onTapLink: (text, href, title) {
                              final uri = Uri.tryParse(href ?? '');
                              if (uri != null && uri.hasScheme) {
                                launchUrl(uri,
                                    mode: LaunchMode.externalApplication);
                              }
                            },
                          ),
                  ),
                ),
              ),
              const Divider(height: 1, color: AppColors.strokeGlass),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () async {
                        await UpdateChecker.instance.ignore(info.tag);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('忽略此版本',
                          style: TextStyle(color: AppColors.textTertiary)),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('稍后',
                          style: TextStyle(color: AppColors.textTertiary)),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        UpdateChecker.instance.openRelease(info.url);
                      },
                      child: const Text('前往更新',
                          style: TextStyle(color: AppColors.cyan)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 更新日志的排版：字号压到 12~13，整体偏灰，和 App 暗色玻璃主题一致。
  MarkdownStyleSheet get _changelogSheet => MarkdownStyleSheet(
        p: const TextStyle(
            fontSize: 12.5, height: 1.5, color: AppColors.textSecondary),
        listBullet: const TextStyle(color: AppColors.textTertiary),
        h1: const TextStyle(
            fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
        h2: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary),
        h3: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary),
        h4: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary),
        h5: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary),
        h6: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary),
        code: const TextStyle(
            fontSize: 12,
            color: AppColors.cyan,
            backgroundColor: AppColors.surfaceGlass),
        codeblockDecoration: BoxDecoration(
          color: AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.strokeGlass),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: AppColors.cyan.withValues(alpha: 0.7), width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.strokeGlass)),
        ),
        a: const TextStyle(
            color: AppColors.cyan, decoration: TextDecoration.underline),
        tableBorder: TableBorder.all(color: AppColors.strokeGlass),
        tableHead: const TextStyle(fontWeight: FontWeight.w600),
        tableBody: const TextStyle(fontSize: 12),
      );

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
                    const Divider(height: 1, color: AppColors.strokeGlass, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.lyrics_rounded, color: AppColors.magenta, size: 22),
                      title: const Text('下载歌词', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '${_lyricMode.label} · ${_lyricMode.description}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: _selectLyricMode,
                    ),
                    const Divider(height: 1, color: AppColors.strokeGlass, indent: 56),
                    SwitchListTile(
                      secondary: const Icon(Icons.image_rounded, color: AppColors.cyan, size: 22),
                      title: const Text('下载封面', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: const Text(
                        '取最高分辨率原图，写入音频文件内嵌标签',
                        style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
                      ),
                      activeThumbColor: AppColors.cyan,
                      value: _saveCover,
                      onChanged: _toggleSaveCover,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '歌词与封面的保存方式：优先写入音频文件内部（MP3 → ID3v2 USLT/APIC，'
                  'FLAC → Vorbis Comment LYRICS + PICTURE，M4A → ilst ©lyr/covr，'
                  'OGG → Vorbis Comment LYRICS）；'
                  '遇到不支持内嵌的格式时自动退回同名外挂 .lrc / .jpg 文件。'
                  '写入过程不会改动音频数据本身。',
                  style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
              ),
              const SizedBox(height: 24),
              const SectionHeader(title: '缓存管理'),
              GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.cleaning_services_rounded, color: AppColors.cyan, size: 22),
                      title: const Text('清理缓存', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '当前占用 $_cacheSize',
                        style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: _clearCache,
                    ),
                    const Divider(height: 1, color: AppColors.strokeGlass, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.sd_storage_rounded, color: AppColors.violet, size: 22),
                      title: const Text('缓存目录', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        _cachePath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: _pickCacheDir,
                    ),
                    const Divider(height: 1, color: AppColors.strokeGlass, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.restore_rounded, color: AppColors.textTertiary, size: 22),
                      title: const Text('恢复默认缓存目录', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: _resetCacheDir,
                    ),
                    const Divider(height: 1, color: AppColors.strokeGlass, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.memory_rounded, color: AppColors.magenta, size: 22),
                      title: const Text('内存图片缓存上限', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '$_cacheMemoryMb MB',
                        style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: _selectCacheMemoryLimit,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '封面在 App 内是通过内存缓存加载的（不落盘），所以「清理缓存」清的是'
                  '内存里的封面、日志导出文件与临时文件。'
                  '缓存目录被手动删除后会自动回落到系统默认目录，不会导致缓存读写失败。',
                  style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
              ),
              const SizedBox(height: 24),
              const SectionHeader(title: '歌词显示'),
              GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.format_size_rounded, color: AppColors.cyan, size: 22),
                      title: const Text('歌词字号与对齐', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: AnimatedBuilder(
                        animation: _lyricStyle,
                        builder: (ctx, _) => Text(
                          '${_lyricStyle.fontSize.toStringAsFixed(0)} px · '
                          '${_lyricStyle.alignLeft ? '左对齐' : '居中'}',
                          style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: () => showLyricStyleSheet(context),
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
                      activeThumbColor: AppColors.cyan,
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
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.system_update_rounded, color: AppColors.violet, size: 22),
                      title: const Text('检查更新', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: const Text('手动检查最新版本', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                      trailing: _checkingUpdate
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.cyan))
                          : const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: _checkingUpdate ? null : _checkUpdate,
                    ),
                    const Divider(height: 1, color: AppColors.strokeGlass, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.gavel_rounded, color: AppColors.warning, size: 22),
                      title: const Text('免责声明', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: const Text('点击查看全文', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: () => showAgreementReader(
                        context,
                        initial: AgreementTab.disclaimer,
                      ),
                    ),
                    const Divider(height: 1, color: AppColors.strokeGlass, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.article_rounded, color: AppColors.magenta, size: 22),
                      title: const Text('使用协议', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: const Text('点击查看全文', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
                      onTap: () => showAgreementReader(
                        context,
                        initial: AgreementTab.terms,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 下载歌词的粒度选择（不下载 / 逐行 / 逐字）。
class _LyricModeSheet extends StatelessWidget {
  const _LyricModeSheet({required this.current});

  final LyricDownloadMode current;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 6, 20, 12),
              child: Text(
                '下载歌词',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ),
            const Divider(height: 1, color: AppColors.strokeGlass),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
              child: Column(
                children: [
                  for (final m in LyricDownloadMode.values)
                    _LyricModeTile(
                      mode: m,
                      selected: m == current,
                      onTap: () => Navigator.pop(context, m),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LyricModeTile extends StatelessWidget {
  const _LyricModeTile({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final LyricDownloadMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 18,
                color: selected ? AppColors.cyan : AppColors.textTertiary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode.label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected
                            ? AppColors.cyan
                            : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      mode.description,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textTertiary),
                    ),
                  ],
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
