import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_logger.dart';
import '../../core/backup_service.dart';
import '../../core/cache_manager.dart';
import '../../core/capture_trust.dart';
import '../../core/device_guid.dart';
import '../../core/dev_mode.dart';
import '../../core/lyric_settings.dart';
import '../../core/telemetry.dart';
import '../../core/theme_controller.dart';
import '../../core/ui_settings.dart';
import '../../core/update_checker.dart';
import '../../download/download_extras.dart';
import '../../download/download_manager.dart';
import '../../models/models.dart';
import '../../network/music_api.dart';
import '../../network/kuwo/kuwo_auth.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/cover_image.dart';
import '../widgets/info_dialog.dart';
import '../widgets/lyric_style_sheet.dart';
import 'kuwo_login_page.dart';
import 'qq_login_page.dart';
import 'netease_login_page.dart';

/// 歌词字重档位名（300~900，步进 100）。
const List<String> _lyricWeightNames = ['细', '常规', '中等', '半粗', '粗', '特粗', '黑'];

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
  KuwoQuality _kuwoQuality = KuwoQuality.playbackDefault;
  bool _checkingUpdate = false;
  bool _captureEnabled = false;
  String _captureProxy = '';
  LyricDownloadMode _lyricMode = LyricDownloadMode.line;
  bool _saveCover = true;

  /// Miuix Snackbar 宿主状态（脚手架 snackbarHost 槽位）。
  final _snackbarHostState = MiuixSnackbarHostState();

  // ===== 各类弹层 / 对话框的显隐（Miuix 弹窗是声明式的）=====
  bool _showProxyDialog = false;
  bool _showClearCacheDialog = false;
  bool _showUpdateDialog = false;
  bool _showLyricModeSheet = false;
  bool _showLyricStyleSheet = false;
  bool _showQQQualitySheet = false;
  bool _showNeteaseQualitySheet = false;
  bool _showKuwoQualitySheet = false;
  bool _showCacheLimitSheet = false;
  bool _showBackupDialog = false;
  bool _showBackupImportConfirm = false;
  bool _backupBusy = false;
  String? _backupImportPath;

  /// v2.2.7：歌词字重 / 界面圆角改为弹窗调节（带实时预览）。
  bool _showWeightDialog = false;
  bool _showCornerDialog = false;
  final _proxyController = TextEditingController();
  UpdateInfo? _updateInfo;
  List<CacheEntry> _cacheEntries = const [];

  LyricSettings get _lyricStyle => LyricSettings.instance;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    // 开发者模式是进程级单例；这里兜底 load 一次（main 里也会 load，幂等）
    DevMode.instance.load();
    // 酷我登录/退出后刷新账号区的登录态摘要
    KuwoAuth.addListener(_onKuwoAuthChanged);
  }

  @override
  void dispose() {
    KuwoAuth.removeListener(_onKuwoAuthChanged);
    _proxyController.dispose();
    super.dispose();
  }

  void _onKuwoAuthChanged() {
    if (mounted) setState(() {});
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
      _kuwoQuality = player.currentKuwoQuality;
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

  void _selectLyricMode(LyricDownloadMode picked) {
    setState(() => _showLyricModeSheet = false);
    DownloadExtras.setLyricMode(picked).then((_) {
      if (!mounted) return;
      setState(() => _lyricMode = picked);
    });
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

  void _editProxy() {
    _proxyController.text = _captureProxy;
    setState(() => _showProxyDialog = true);
  }

  Future<void> _saveProxy() async {
    setState(() => _showProxyDialog = false);
    await CaptureTrust.setProxy(_proxyController.text);
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

  void _selectCacheMemoryLimit(int v) {
    setState(() => _showCacheLimitSheet = false);
    CacheManager.setMemoryLimitMb(v).then((_) {
      CacheManager.applyMemoryLimit();
      if (!mounted) return;
      setState(() => _cacheMemoryMb = v);
      _showSnack('内存图片缓存上限设为 $v MB');
    });
  }

  void _selectQQQuality(Quality q) {
    setState(() => _showQQQualitySheet = false);
    PlayerController.instance.saveDefaultQuality(q);
    setState(() => _qqQuality = q);
    _showSnack('QQ 音质已设为 ${q.label}');
  }

  void _selectNeteaseQuality(NeteaseQuality q) {
    setState(() => _showNeteaseQualitySheet = false);
    PlayerController.instance.saveNeteaseQuality(q);
    setState(() => _neQuality = q);
    _showSnack('网易云音质已设为 ${q.label}');
  }

  void _selectKuwoQuality(KuwoQuality q) {
    setState(() => _showKuwoQualitySheet = false);
    PlayerController.instance.saveKuwoQuality(q);
    setState(() => _kuwoQuality = q);
    _showSnack('酷我音质已设为 ${q.label}');
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
          setState(() {
            _updateInfo = outcome.info;
            _showUpdateDialog = true;
          });
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

  Future<void> _ignoreUpdate() async {
    final info = _updateInfo;
    if (info == null) return;
    setState(() => _showUpdateDialog = false);
    await UpdateChecker.instance.ignore(info.tag);
  }

  void _openRelease() {
    final info = _updateInfo;
    setState(() => _showUpdateDialog = false);
    if (info != null) UpdateChecker.instance.openRelease(info.url);
  }

  void _showSnack(String msg, {bool isError = false}) {
    _snackbarHostState.showSnackbar(msg);
  }

  // ==================== 备份与恢复（v2.3.0） ====================

  /// 导出备份：JSON 写入可管理的缓存目录后走系统分享（可存网盘/发送）。
  Future<void> _exportBackup() async {
    if (_backupBusy) return;
    setState(() => _backupBusy = true);
    try {
      final json = BackupService.export();
      final stamp = DateTime.now()
          .toIso8601String()
          .substring(0, 16)
          .replaceAll(RegExp(r'[:T]'), '-');
      final file = await CacheManager.cacheFile('baiji_backup_$stamp.json');
      await file.writeAsString(json, encoding: utf8);
      if (!mounted) return;
      setState(() => _showBackupDialog = false);
      await Share.shareXFiles(
        [XFile(file.path)],
        text: '白姬音乐备份（含歌单/历史/登录态/设置，请妥善保管）',
        subject: file.uri.pathSegments.last,
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack('导出备份失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  /// 选择备份文件并进入确认弹层。
  Future<void> _pickBackupFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final f = res.files.single;
      if (f.path == null && f.bytes == null) {
        _showSnack('无法读取所选文件', isError: true);
        return;
      }
      setState(() {
        _backupImportPath = f.path;
        _backupImportBytes = f.bytes;
        _showBackupImportConfirm = true;
      });
    } catch (e) {
      _showSnack('选择文件失败: $e', isError: true);
    }
  }

  Uint8List? _backupImportBytes;

  Future<void> _confirmImportBackup() async {
    if (_backupBusy) return;
    setState(() {
      _backupBusy = true;
      _showBackupImportConfirm = false;
    });
    try {
      String raw;
      final bytes = _backupImportBytes;
      if (bytes != null && bytes.isNotEmpty) {
        raw = utf8.decode(bytes, allowMalformed: true);
      } else {
        raw = await File(_backupImportPath!).readAsString();
      }
      final n = await BackupService.import(raw);
      if (!mounted) return;
      _showSnack('已恢复 $n 条数据，重启应用后全部生效');
    } on FormatException catch (e) {
      if (!mounted) return;
      _showSnack('恢复失败: ${e.message}', isError: true);
    } catch (e) {
      if (!mounted) return;
      _showSnack('恢复失败: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _backupBusy = false;
          _backupImportPath = null;
          _backupImportBytes = null;
        });
      }
    }
  }

  Future<void> _confirmClearCache() async {
    setState(() => _showClearCacheDialog = false);

    // 删不掉的条目要如实上报：静默吞掉异常会让「权限不足 / 文件占用」
    // 表现为「点了没反应」，比报错更让人困惑。
    final issues = <String>[];
    var freed = await CacheManager.clear(
        onIssue: (path, reason) => issues.add(path));

    // v2.4.0-fix2：歌曲播放缓存。
    // - 受管的 `playback` 目录已由 CacheManager.clear() 一并清掉（它就在
    //   managedDirNames 里）；
    // - libmpv 在各平台的默认缓存目录是额外的残留，**只在没有在播放时动**：
    //   播放中删它的活动句柄，Windows 上直接失败，POSIX 上也可能读到截断数据。
    String? playbackNote;
    if (PlayerController.instance.isPlaying) {
      playbackNote = '播放中，libmpv 缓存目录未清理';
    } else {
      freed += await CacheManager.clearPlaybackExtras(
          onIssue: (path, reason) => issues.add(path));
    }

    // 本地歌曲封面另有一份独立内存缓存，在 ui 层，这里一并清掉
    LocalCoverCache.clear();
    if (!mounted) return;
    if (issues.isNotEmpty) {
      _showSnack(
        '已释放 ${CacheManager.formatBytes(freed)}，'
        '但有 ${issues.length} 个文件删不掉（可能正被占用）',
      );
    } else if (playbackNote != null) {
      _showSnack(freed <= 0
          ? '缓存已清理（$playbackNote）'
          : '缓存已清理，释放 ${CacheManager.formatBytes(freed)}（$playbackNote）');
    } else {
      _showSnack(freed <= 0
          ? '缓存已清理'
          : '缓存已清理，释放 ${CacheManager.formatBytes(freed)}');
    }
    _refreshCacheSize();
  }

  Future<void> _prepareClearCache() async {
    final entries = await CacheManager.breakdown();
    if (!mounted) return;
    setState(() {
      _cacheEntries = entries;
      _showClearCacheDialog = true;
    });
  }


  @override
  Widget build(BuildContext context) {
    final body = SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            const SectionHeader(title: '账号', icon: Icons.account_circle_outlined),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  MiuixArrowPreference(
                    title: 'QQ 音乐',
                    summary: AppServices.instance.qq.isLoggedIn()
                        ? '已登录: ${AppServices.instance.qq.credential.strMusicid}'
                        : '未登录 · 点击登录',
                    startAction: Icon(
                      AppServices.instance.qq.isLoggedIn()
                          ? Icons.verified_rounded
                          : Icons.person_outline,
                      color: AppServices.instance.qq.isLoggedIn()
                          ? AppColors.accent
                          : AppColors.textTertiary,
                      size: 22,
                    ),
                    onClick: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(builder: (_) => const QQLoginPage()),
                    ),
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixArrowPreference(
                    title: '网易云音乐',
                    summary: AppServices.instance.netease.isLoggedIn()
                        ? '已登录'
                        : '未登录 · 点击登录',
                    startAction: Icon(
                      AppServices.instance.netease.isLoggedIn()
                          ? Icons.verified_rounded
                          : Icons.person_outline,
                      color: AppServices.instance.netease.isLoggedIn()
                          ? AppColors.accentAlt
                          : AppColors.textTertiary,
                      size: 22,
                    ),
                    onClick: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const NeteaseLoginPage()),
                    ),
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixArrowPreference(
                    title: '酷我音乐',
                    summary: KuwoAuth.isLoggedIn
                        ? '已登录: ${KuwoAuth.session?.nickname.isNotEmpty == true ? KuwoAuth.session!.nickname : "UID ${KuwoAuth.session?.uid}"}'
                        : '未登录 · 点击登录',
                    startAction: Icon(
                      KuwoAuth.isLoggedIn
                          ? Icons.verified_rounded
                          : Icons.person_outline,
                      color: KuwoAuth.isLoggedIn
                          ? AppColors.accent
                          : AppColors.textTertiary,
                      size: 22,
                    ),
                    onClick: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(builder: (_) => const KuwoLoginPage()),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const SectionHeader(title: '播放与音质', icon: Icons.equalizer_rounded),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  MiuixArrowPreference(
                    title: 'QQ 音乐播放音质',
                    summary: _qqQuality.label,
                    startAction: Icon(Icons.equalizer_rounded,
                        color: AppColors.accent, size: 22),
                    onClick: () =>
                        setState(() => _showQQQualitySheet = true),
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixArrowPreference(
                    title: '网易云音乐播放音质',
                    summary: _neQuality.label,
                    startAction: Icon(Icons.equalizer_rounded,
                        color: AppColors.accentAlt, size: 22),
                    onClick: () =>
                        setState(() => _showNeteaseQualitySheet = true),
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixArrowPreference(
                    title: '酷我音乐播放音质',
                    summary: _kuwoQuality.label,
                    startAction: Icon(Icons.equalizer_rounded,
                        color: AppColors.violet, size: 22),
                    onClick: () =>
                        setState(() => _showKuwoQualitySheet = true),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const SectionHeader(title: '歌词与显示', icon: Icons.music_note_outlined),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              // 歌词偏好是 ChangeNotifier，用 AnimatedBuilder 局部重建本行，
              // 避免整个设置页随字号调整重建。
              child: Column(
                children: [
                  AnimatedBuilder(
                    animation: _lyricStyle,
                    builder: (ctx, _) => MiuixArrowPreference(
                      title: '歌词样式',
                      summary:
                          '${_lyricStyle.fontSize.toStringAsFixed(0)} px · '
                          '${_lyricStyle.alignLeft ? '左对齐' : '居中'} · '
                          '字重 ${_lyricStyle.weight}',
                      startAction: Icon(Icons.format_size_rounded,
                          color: AppColors.accent, size: 22),
                      onClick: () =>
                          setState(() => _showLyricStyleSheet = true),
                    ),
                  ),
                  const MiuixHorizontalDivider(),
                  // 歌词字重：点击弹出调节面板（v2.2.7 起不再行内嵌 slider，
                  // 弹窗里带实时预览，调完一眼能看到效果）
                  AnimatedBuilder(
                    animation: _lyricStyle,
                    builder: (ctx, _) => MiuixArrowPreference(
                      title: '歌词字重',
                      summary: '${_lyricStyle.weight} · '
                          '${_lyricWeightNames[((_lyricStyle.weight - LyricSettings.minWeight) / 100).round().clamp(0, _lyricWeightNames.length - 1)]}',
                      startAction: const Icon(Icons.format_bold_rounded,
                          color: AppColors.violet, size: 22),
                      onClick: () =>
                          setState(() => _showWeightDialog = true),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const SectionHeader(title: '下载与存储', icon: Icons.folder_outlined),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  MiuixArrowPreference(
                    title: '下载目录',
                    summary: _downloadPath.isEmpty ? '默认目录' : _downloadPath,
                    startAction: const Icon(Icons.folder_rounded,
                        color: AppColors.violet, size: 22),
                    onClick: _pickDownloadDir,
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixArrowPreference(
                    title: '恢复默认目录',
                    startAction: Icon(Icons.restore_rounded,
                        color: AppColors.textTertiary, size: 22),
                    onClick: _resetDownloadDir,
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixArrowPreference(
                    title: '下载歌词',
                    summary: '${_lyricMode.label} · ${_lyricMode.description}',
                    startAction: Icon(Icons.lyrics_rounded,
                        color: AppColors.accentAlt, size: 22),
                    onClick: () =>
                        setState(() => _showLyricModeSheet = true),
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixSwitchPreference(
                    title: '下载封面',
                    summary: '取最高分辨率原图，写入音频文件内嵌标签',
                    startAction: Icon(Icons.image_rounded,
                        color: AppColors.accent, size: 22),
                    value: _saveCover,
                    onChanged: _toggleSaveCover,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Padding(
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
            const SizedBox(height: 6),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  MiuixArrowPreference(
                    title: '清理缓存',
                    summary: '当前占用 $_cacheSize',
                    startAction: Icon(Icons.cleaning_services_rounded,
                        color: AppColors.accent, size: 22),
                    onClick: _prepareClearCache,
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixArrowPreference(
                    title: '缓存目录',
                    summary: _cachePath,
                    startAction: const Icon(Icons.sd_storage_rounded,
                        color: AppColors.violet, size: 22),
                    onClick: _pickCacheDir,
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixArrowPreference(
                    title: '恢复默认缓存目录',
                    startAction: Icon(Icons.restore_rounded,
                        color: AppColors.textTertiary, size: 22),
                    onClick: _resetCacheDir,
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixArrowPreference(
                    title: '内存图片缓存上限',
                    summary: '$_cacheMemoryMb MB',
                    startAction: Icon(Icons.memory_rounded,
                        color: AppColors.accentAlt, size: 22),
                    onClick: () =>
                        setState(() => _showCacheLimitSheet = true),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '封面在 App 内是通过内存缓存加载的（不落盘），所以「清理缓存」清的是'
                '内存里的封面、日志导出文件与临时文件。'
                '缓存目录被手动删除后会自动回落到系统默认目录，不会导致缓存读写失败。',
                style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
              ),
            ),
            const SectionHeader(title: '通用', icon: Icons.tune_rounded),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  // 主题偏好是 ChangeNotifier，只重建这一行，不波及整个设置页
                  AnimatedBuilder(
                    animation: ThemeController.instance,
                    builder: (ctx, _) => MiuixSwitchPreference(
                      title: '莫奈取色',
                      summary: '开启后主题色跟随系统壁纸取色'
                          '（Android 支持；其他平台回退品牌紫）',
                      startAction: const Icon(Icons.palette_rounded,
                          color: AppColors.violet, size: 22),
                      value: ThemeController.instance.monet,
                      onChanged: (v) => ThemeController.instance.setMonet(v),
                    ),
                  ),
                  const MiuixHorizontalDivider(),
                  // 界面圆角（全局）：作用于 App 内自绘卡片（玻璃卡等）。
                  // v2.2.7 起点击弹出调节面板，带实时预览。
                  AnimatedBuilder(
                    animation: UiSettings.instance,
                    builder: (ctx, _) => MiuixArrowPreference(
                      title: '界面圆角',
                      summary: '${UiSettings.instance.cornerRadius.toStringAsFixed(0)} px',
                      startAction: const Icon(Icons.rounded_corner_rounded,
                          color: AppColors.aqua, size: 22),
                      onClick: () =>
                          setState(() => _showCornerDialog = true),
                    ),
                  ),
                  const MiuixHorizontalDivider(),
                  // 数据上报（v2.4.0）：把 GUID / 平台 / 搜索 / 播放行为
                  // 上报到自建服务器（upload.php）。默认开启，可随时关闭。
                  MiuixSwitchPreference(
                    title: '数据上报',
                    summary: '上报设备 GUID、使用的平台、搜索与播放记录'
                        '（用于统计，关闭后不再发送任何数据）',
                    startAction: const Icon(Icons.cloud_upload_outlined,
                        color: AppColors.aqua, size: 22),
                    value: Telemetry.instance.enabled,
                    onChanged: (v) async {
                      await Telemetry.instance.setEnabled(v);
                      if (!mounted) return;
                      setState(() {});
                    },
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixArrowPreference(
                    title: '设备 GUID',
                    summary: '本机唯一标识（用于数据统计去重）',
                    startAction: const Icon(Icons.fingerprint_rounded,
                        color: AppColors.violet, size: 22),
                    onClick: () async {
                      // GUID 可能还没生成（首次启动读平台设备 ID 是异步的），
                      // 这里 await ensure() 拿到真值再展示。
                      final guid = await DeviceGuid.ensure();
                      if (!context.mounted) return;
                      await showAppInfoDialog(
                        context,
                        title: '设备 GUID',
                        summary: '本机唯一标识，用于数据统计去重。'
                            '已随搜索/播放记录一起上报，可直接复制。',
                        lines: [
                          guid,
                          '',
                          '平台: ${DeviceGuid.platformName}',
                        ],
                        copyText: guid,
                      );
                    },
                  ),
                  const MiuixHorizontalDivider(),
MiuixArrowPreference(
                    title: '检查更新',
                    summary: '手动检查最新版本',
                    startAction: const Icon(Icons.system_update_rounded,
                        color: AppColors.violet, size: 22),
                    endActions: [
                      if (_checkingUpdate)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: MiuixCircularProgressIndicator(
                            strokeWidth: 2,
                            size: 18,
                          ),
                        ),
                    ],
                    onClick: _checkingUpdate ? null : _checkUpdate,
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixArrowPreference(
                    title: '备份与恢复',
                    summary: '导出 / 导入歌单、历史、登录态与设置（JSON）',
                    startAction: const Icon(Icons.backup_rounded,
                        color: AppColors.aqua, size: 22),
                    onClick: () =>
                        setState(() => _showBackupDialog = true),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '整体界面默认跟随系统自动切换深色 / 浅色；标题文字为天蓝色。'
                '莫奈取色只影响主题强调色（按钮 / 开关 / 选中态），'
                '玻璃底、背景光晕与标题天蓝保持不变。',
                style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
              ),
            ),
            const SizedBox(height: 24),
            // 开发者模式：默认隐藏，在「关于」页连点版本号 10 次输密码开启。
            // 抓包调试这类会影响网络安全的开关收在这里，避免普通用户误触。
            AnimatedBuilder(
              animation: DevMode.instance,
              builder: (context, _) {
                if (!DevMode.instance.enabled) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SectionHeader(title: '开发者模式', icon: Icons.developer_mode_rounded),
                    GlassCard(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        children: [
                          MiuixSwitchPreference(
                            title: '允许抓包调试',
                            summary: '放行中间人证书，供 Reqable / Charles 解密 HTTPS（正式版同样可开）',
                            startAction: Icon(
                              Icons.bug_report_rounded,
                              color: _captureEnabled
                                  ? AppColors.warning
                                  : AppColors.textTertiary,
                              size: 22,
                            ),
                            value: _captureEnabled,
                            onChanged: _toggleCapture,
                          ),
                          const MiuixHorizontalDivider(),
                          MiuixArrowPreference(
                            title: '抓包代理',
                            summary: _captureProxy.isEmpty
                                ? '未设置（走系统/环境变量代理）'
                                : _captureProxy,
                            startAction: const Icon(Icons.router_rounded,
                                color: AppColors.violet, size: 22),
                            onClick: _editProxy,
                          ),
                          const MiuixHorizontalDivider(),
                          MiuixSwitchPreference(
                            title: '开发者模式',
                            summary: '关闭后设置页重新隐藏本分区（可在关于页再次开启）',
                            startAction: Icon(Icons.developer_mode_rounded,
                                color: AppColors.accent, size: 22),
                            value: true,
                            onChanged: (v) {
                              if (v) return;
                              DevMode.instance.setEnabled(false).then((_) {
                                if (!mounted) return;
                                _showSnack('开发者模式已关闭');
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        'Android 端还需在手机上装好抓包工具的 CA（设置 → 安全 → 凭据），'
                        'App 已在 network_security_config 中放行用户证书；'
                        'Dart 层的证书校验由上面的开关控制，两者都要开才能抓全。'
                        '桌面端若抓不到，可在这里填 Reqable 的代理地址（本机一般 127.0.0.1:8888）。',
                        style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                );
              },
            ),
          ],
        ),
      );
    // ===== 弹层 / 对话框（Miuix 声明式，随 Scaffold 渲染）=====
    // MiuixScaffold 没有「弹窗栈」之外的挂点，弹窗统一借助 root popup host：
    // 这里把各弹层作为 body 之上的 Stack 子节点插入。
    return PageScaffold(
      title: '设置',
      snackbarHost: _snackbarHostState,
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      bottomBar: _buildDialogs(),
      child: body,
    );
  }

  /// 所有声明式弹层的挂载点。
  ///
  /// Miuix 的 OverlayDialog / OverlayBottomSheet 会自己注册到 root popup
  /// 注册表并由 PopupHost 渲染，挂载位置只要在 MiuixPopupScope 内即可，
  /// 放 bottomBar 槽位只是图个集中。
  Widget _buildDialogs() {
    return Stack(
      children: [
        // 备份与恢复（导出 / 导入入口）
        MiuixOverlayDialog(
          show: _showBackupDialog,
          title: '备份与恢复',
          summary: '歌单、播放/搜索历史、收藏、本地音乐库、'
              '网易云与 QQ 登录态、解密密钥库、全部个性化设置',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () =>
              setState(() => _showBackupDialog = false),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  '当前可备份 ${BackupService.countBackupItems()} 条数据。'
                  '导出文件经 SM4+SM2 国密算法加密（Base64 封装），不含明文，'
                  '可安全传输保存。恢复为合并写回：只覆盖备份里有的键，本机其他'
                  '数据保留；恢复后重启应用生效。',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: AppColors.textTertiary),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MiuixTextButton(
                    '导出备份',
                    onPressed: _backupBusy ? null : _exportBackup,
                  ),
                  const SizedBox(width: 8),
                  MiuixTextButton(
                    '导入备份',
                    onPressed: _backupBusy ? null : _pickBackupFile,
                  ),
                ],
              ),
            ],
          ),
        ),
        // 导入确认：备份文件会覆盖本机同名数据
        MiuixOverlayDialog(
          show: _showBackupImportConfirm,
          title: '确认导入备份？',
          summary: '备份里的歌单、历史、登录态与设置将覆盖本机同名数据。'
              '该操作不可撤销，建议先「导出备份」留一份当前状态。',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () =>
              setState(() => _showBackupImportConfirm = false),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MiuixTextButton('取消', onPressed: () {
                    setState(() => _showBackupImportConfirm = false);
                  }),
                  const SizedBox(width: 8),
                  MiuixTextButton(
                    '导入',
                    onPressed: _backupBusy ? null : _confirmImportBackup,
                  ),
                ],
              ),
            ],
          ),
        ),
        // 歌词字重调节（实时预览：示例歌词按当前字重渲染）
        MiuixOverlayDialog(
          show: _showWeightDialog,
          title: '歌词字重',
          summary: '拖动调节，效果实时生效',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () =>
              setState(() => _showWeightDialog = false),
          content: AnimatedBuilder(
            animation: _lyricStyle,
            builder: (ctx, _) {
              final w = _lyricStyle.weight;
              final name = _lyricWeightNames[
                  ((w - LyricSettings.minWeight) / 100)
                      .round()
                      .clamp(0, _lyricWeightNames.length - 1)];
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 当前值 + 预览歌词
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 18),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceGlass,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.strokeGlass),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '$w · $name',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.accent,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '而那些昨日依然缤纷着',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: _lyricStyle.activeWeight,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  MiuixSlider(
                    value: w.toDouble(),
                    min: LyricSettings.minWeight.toDouble(),
                    max: LyricSettings.maxWeight.toDouble(),
                    steps: (LyricSettings.maxWeight -
                            LyricSettings.minWeight) ~/
                        100,
                    onValueChanged: (v) => _lyricStyle.setWeight(v.round()),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      MiuixTextButton('取消', onPressed: () {
                        setState(() => _showWeightDialog = false);
                      }),
                      const SizedBox(width: 8),
                      MiuixTextButton('完成', onPressed: () {
                        setState(() => _showWeightDialog = false);
                      }),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
        // 界面圆角调节（实时预览：玻璃卡本身跟随全局圆角）
        MiuixOverlayDialog(
          show: _showCornerDialog,
          title: '界面圆角',
          summary: '拖动调节，效果实时生效',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () =>
              setState(() => _showCornerDialog = false),
          content: AnimatedBuilder(
            animation: UiSettings.instance,
            builder: (ctx, _) {
              final r = UiSettings.instance.cornerRadius;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 预览卡：radius 传 null = 跟随全局，拖动时肉眼可见圆角变化
                  GlassCard(
                    radius: null,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 18),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppColors.accent.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.palette_rounded,
                              color: AppColors.accent, size: 18),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            '卡片圆角实时预览',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          '${r.toStringAsFixed(0)} px',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  MiuixSlider(
                    value: r,
                    min: UiSettings.minCorner,
                    max: UiSettings.maxCorner,
                    steps:
                        (UiSettings.maxCorner - UiSettings.minCorner).round(),
                    onValueChanged: (v) =>
                        UiSettings.instance.setCornerRadius(v),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      MiuixTextButton('恢复默认', onPressed: () {
                        UiSettings.instance.resetCorner();
                      }),
                      const SizedBox(width: 8),
                      MiuixTextButton('完成', onPressed: () {
                        setState(() => _showCornerDialog = false);
                      }),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
        // 抓包代理输入
        MiuixOverlayDialog(
          show: _showProxyDialog,
          title: '抓包代理',
          summary: '格式 host:port，例如 127.0.0.1:8888；留空 = 不强制代理',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () =>
              setState(() => _showProxyDialog = false),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppTextField(
                controller: _proxyController,
                autofocus: true,
                label: 'host:port',
                singleLine: true,
                leadingIcon: Icon(Icons.lan_outlined,
                    size: 18, color: AppColors.textTertiary),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MiuixTextButton('清空', onPressed: () {
                    _proxyController.text = '';
                  }),
                  const SizedBox(width: 8),
                  MiuixTextButton('保存', onPressed: _saveProxy),
                ],
              ),
            ],
          ),
        ),
        // 清理缓存确认（列出各项占用）
        MiuixOverlayDialog(
          show: _showClearCacheDialog,
          title: '清理缓存',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () =>
              setState(() => _showClearCacheDialog = false),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in _cacheEntries) ...[
                Text(
                  '${e.label} · ${e.readable}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (e.detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 6),
                    child: Text(
                      e.detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textTertiary),
                    ),
                  ),
              ],
              const SizedBox(height: 4),
              Text(
                '会清空：内存里的封面缓存，以及缓存目录下的'
                'audio_cache / http_cache / logs / decrypt'
                '（含日志导出与解密时的文件副本）。\n'
                '下载的歌曲、播放历史、歌单与本地音乐库都不受影响。',
                style: TextStyle(
                    fontSize: 11, color: AppColors.textTertiary),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MiuixTextButton('取消', onPressed: () {
                    setState(() => _showClearCacheDialog = false);
                  }),
                  const SizedBox(width: 8),
                  MiuixTextButton('清理', onPressed: _confirmClearCache),
                ],
              ),
            ],
          ),
        ),
        // 更新日志（Markdown 全文 + 滚动）
        MiuixOverlayDialog(
          show: _showUpdateDialog,
          title: _updateInfo == null
              ? '发现新版本'
              : (_updateInfo!.name.isNotEmpty
                  ? '${_updateInfo!.name}（${_updateInfo!.tag}）'
                  : _updateInfo!.tag),
          backgroundColor: AppColors.bg2,
          maxWidth: 560,
          onDismissRequest: () =>
              setState(() => _showUpdateDialog = false),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                ),
                child: SingleChildScrollView(
                  child: _updateInfo == null ||
                          _updateInfo!.body.trim().isEmpty
                      ? Text('该版本没有提供更新说明。',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.textTertiary))
                      : MarkdownBody(
                          data: _updateInfo!.body,
                          selectable: true,
                          styleSheet: changelogSheet,
                          // 更新日志里的图片多是 badge，加载不出来时别把布局撑破。
                          imageBuilder: (uri, title, alt) => ConstrainedBox(
                            constraints:
                                const BoxConstraints(maxWidth: 260),
                            child: Image.network(
                              uri.toString(),
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stack) => Text(
                                alt?.isNotEmpty == true ? alt! : '[图片]',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textTertiary),
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
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MiuixTextButton('忽略此版本', onPressed: _ignoreUpdate),
                  const SizedBox(width: 8),
                  MiuixTextButton('稍后', onPressed: () {
                    setState(() => _showUpdateDialog = false);
                  }),
                  const SizedBox(width: 8),
                  MiuixTextButton('前往更新', onPressed: _openRelease),
                ],
              ),
            ],
          ),
        ),
        // 下载歌词粒度
        MiuixOverlayBottomSheet(
          show: _showLyricModeSheet,
          title: '下载歌词',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () =>
              setState(() => _showLyricModeSheet = false),
          content: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final m in LyricDownloadMode.values)
                  _LyricModeTile(
                    mode: m,
                    selected: m == _lyricMode,
                    onTap: () => _selectLyricMode(m),
                  ),
              ],
            ),
          ),
        ),
        // 歌词样式（字号 / 对齐 / 放大 / 字重 / 圆角 / 三色）
        showLyricStyleSheet(
          show: _showLyricStyleSheet,
          onDismiss: () => setState(() => _showLyricStyleSheet = false),
        ),
        // QQ 音质
        MiuixOverlayBottomSheet(
          show: _showQQQualitySheet,
          title: 'QQ 音乐播放音质',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () =>
              setState(() => _showQQQualitySheet = false),
          content: _QualitySheet<Quality>(
            options: Quality.playbackOptions,
            current: _qqQuality,
            label: (q) => q.label,
            onSelect: _selectQQQuality,
          ),
        ),
        // 网易云音质
        MiuixOverlayBottomSheet(
          show: _showNeteaseQualitySheet,
          title: '网易云音乐播放音质',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () =>
              setState(() => _showNeteaseQualitySheet = false),
          content: _QualitySheet<NeteaseQuality>(
            options: NeteaseQuality.playbackOptions,
            current: _neQuality,
            label: (q) => q.label,
            onSelect: _selectNeteaseQuality,
          ),
        ),
        // 酷我音质（v2.4.2 #140：之前只有 QQ / 网易云，酷我无法设默认）
        MiuixOverlayBottomSheet(
          show: _showKuwoQualitySheet,
          title: '酷我音乐播放音质',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () =>
              setState(() => _showKuwoQualitySheet = false),
          content: _QualitySheet<KuwoQuality>(
            options: KuwoQuality.playbackOptions,
            current: _kuwoQuality,
            label: (q) => q.label,
            onSelect: _selectKuwoQuality,
          ),
        ),
        // 内存缓存上限
        MiuixOverlayBottomSheet(
          show: _showCacheLimitSheet,
          title: '内存图片缓存上限',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () =>
              setState(() => _showCacheLimitSheet = false),
          content: _QualitySheet<int>(
            options: const [32, 64, 100, 200, 400, 800],
            current: _cacheMemoryMb,
            label: (v) => '$v MB',
            onSelect: _selectCacheMemoryLimit,
          ),
        ),
      ],
    );
  }
}

/// 下载歌词的粒度选择（不下载 / 逐行 / 逐字）。
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
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.12)
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
              color: selected ? AppColors.accent : AppColors.textTertiary,
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
                          ? AppColors.accent
                          : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    mode.description,
                    style: TextStyle(
                        fontSize: 11, color: AppColors.textTertiary),
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

/// 音质选择底部弹层（泛型支持 QQ 和网易云）。
class _QualitySheet<T> extends StatelessWidget {
  const _QualitySheet({
    required this.options,
    required this.current,
    required this.label,
    required this.onSelect,
  });

  final List<T> options;
  final T current;
  final String Function(T) label;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    // 固定 72% 屏高 + ListView + 常驻滚动条：
    // QQ 音乐有 17 档（末档 AAC 48），旧的 55% 高度 + SingleChildScrollView
    // 会把末档裁在可视区之外且没有滚动提示。
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: Scrollbar(
        thumbVisibility: true,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
          itemCount: options.length,
          itemBuilder: (ctx, i) {
            final q = options[i];
            final selected = q == current;
            return MiuixPressable(
              onPressed: () => onSelect(q),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.accent.withValues(alpha: 0.12)
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
                          ? AppColors.accent
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
                              ? AppColors.accent
                              : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
