import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_logger.dart';
import '../../core/cache_manager.dart';
import '../../core/capture_trust.dart';
import '../../core/lyric_settings.dart';
import '../../core/theme_controller.dart';
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
  bool _showCacheLimitSheet = false;
  final _proxyController = TextEditingController();
  UpdateInfo? _updateInfo;
  List<CacheEntry> _cacheEntries = const [];

  LyricSettings get _lyricStyle => LyricSettings.instance;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _proxyController.dispose();
    super.dispose();
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

  Future<void> _confirmClearCache() async {
    setState(() => _showClearCacheDialog = false);

    // 删不掉的条目要如实上报：静默吞掉异常会让「权限不足 / 文件占用」
    // 表现为「点了没反应」，比报错更让人困惑。
    final issues = <String>[];
    final freed = await CacheManager.clear(
        onIssue: (path, reason) => issues.add(path));
    // 本地歌曲封面另有一份独立内存缓存，在 ui 层，这里一并清掉
    LocalCoverCache.clear();
    if (!mounted) return;
    if (issues.isNotEmpty) {
      _showSnack(
        '已释放 ${CacheManager.formatBytes(freed)}，'
        '但有 ${issues.length} 个文件删不掉（可能正被占用）',
      );
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

  /// 更新日志的排版：字号压到 12~13，整体偏灰，和 App 暗色玻璃主题一致。
  MarkdownStyleSheet get _changelogSheet => MarkdownStyleSheet(
        p: TextStyle(
            fontSize: 12.5, height: 1.5, color: AppColors.textSecondary),
        listBullet: TextStyle(color: AppColors.textTertiary),
        h1: TextStyle(
            fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
        h2: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary),
        h3: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary),
        h4: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary),
        h5: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary),
        h6: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary),
        code: TextStyle(
            fontSize: 12,
            color: AppColors.accent,
            backgroundColor: AppColors.surfaceGlass),
        codeblockDecoration: BoxDecoration(
          color: AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.strokeGlass),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: AppColors.accent.withValues(alpha: 0.7), width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.strokeGlass)),
        ),
        a: TextStyle(
            color: AppColors.accent, decoration: TextDecoration.underline),
        tableBorder: TableBorder.all(color: AppColors.strokeGlass),
        tableHead: const TextStyle(fontWeight: FontWeight.w600),
        tableBody: const TextStyle(fontSize: 12),
      );

  @override
  Widget build(BuildContext context) {
    return MiuixScaffold(
      containerColor: Colors.transparent,
      snackbarHost: MiuixSnackbarHost(state: _snackbarHostState),
      topBar: MiuixTopAppBar(
        title: '设置',
        titleColor: AppColors.skyBlue,
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.pop(context),
          child: Icon(Icons.arrow_back_rounded,
              color: AppColors.textPrimary),
        ),
      ),
      content: (padding) => SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '外观'),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              // 主题偏好是 ChangeNotifier，只重建这一行，不波及整个设置页
              child: AnimatedBuilder(
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
            const SectionHeader(title: '音质设置'),
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
                ],
              ),
            ),
            const SizedBox(height: 24),
            const SectionHeader(title: '下载设置'),
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
            const SectionHeader(title: '缓存管理'),
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
            const SizedBox(height: 24),
            const SectionHeader(title: '歌词显示'),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              // 歌词偏好是 ChangeNotifier，用 AnimatedBuilder 局部重建本行，
              // 避免整个设置页随字号调整重建。
              child: AnimatedBuilder(
                animation: _lyricStyle,
                builder: (ctx, _) => MiuixArrowPreference(
                  title: '歌词样式',
                  summary:
                      '${_lyricStyle.fontSize.toStringAsFixed(0)} px · '
                      '${_lyricStyle.alignLeft ? '左对齐' : '居中'}',
                  startAction: Icon(Icons.format_size_rounded,
                      color: AppColors.accent, size: 22),
                  onClick: () =>
                      setState(() => _showLyricStyleSheet = true),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const SectionHeader(title: '账号'),
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
                ],
              ),
            ),
            const SizedBox(height: 24),
            const SectionHeader(title: '抓包调试'),
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
                ],
              ),
            ),
            const SizedBox(height: 6),
            Padding(
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
                    title: '免责声明',
                    summary: '点击查看全文',
                    startAction: Icon(Icons.gavel_rounded,
                        color: AppColors.warning, size: 22),
                    onClick: () => showAgreementReader(
                      context,
                      initial: AgreementTab.disclaimer,
                    ),
                  ),
                  const MiuixHorizontalDivider(),
                  MiuixArrowPreference(
                    title: '使用协议',
                    summary: '点击查看全文',
                    startAction: Icon(Icons.article_rounded,
                        color: AppColors.accentAlt, size: 22),
                    onClick: () => showAgreementReader(
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
      // ===== 弹层 / 对话框（Miuix 声明式，随 Scaffold 渲染）=====
      floatingActionButton: null,
      // MiuixScaffold 没有「弹窗栈」之外的挂点，弹窗统一借助 root popup host：
      // 这里把各弹层作为 body 之上的 Stack 子节点插入。
      bottomBar: _buildDialogs(),
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
              MiuixTextField(
                controller: _proxyController,
                autofocus: true,
                label: 'host:port',
                singleLine: true,
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
                          styleSheet: _changelogSheet,
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
