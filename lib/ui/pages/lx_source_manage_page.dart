import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../lx/lx_music_api.dart';
import '../../lx/lx_source.dart';
import '../../lx/lx_update_checker.dart';
import '../../network/source_fallback.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';
import 'source_test_page.dart';

/// 洛雪音源管理（v2.5.7）。
///
/// App 本体不内置任何音源：用户从本地 `.js` 文件或在线链接自行导入，
/// 脚本存应用私有目录。这里提供：
/// - 导入（文件多选 / URL）；
/// - 启用开关、单源「自动更新」开关；
/// - **检测更新**与**自动更新**（全局开关，检测后按开关自动下载替换）；
/// - 编辑更新地址、删除；
/// - 「取链失败自动切换音源」全局开关与音源测试页入口。
class LxSourceManagePage extends StatefulWidget {
  const LxSourceManagePage({super.key});

  @override
  State<LxSourceManagePage> createState() => _LxSourceManagePageState();
}

class _LxSourceManagePageState extends State<LxSourceManagePage> {
  late LxSourceRepo _repo;
  late LxUpdateChecker _checker;
  List<LxSource> _sources = <LxSource>[];
  bool _loading = true;
  bool _checking = false;
  bool _globalAuto = false;
  bool _fallbackEnabled = true;
  List<LxUpdateOutcome>? _outcomes;

  // 声明式弹层显隐
  bool _showUrlDialog = false;
  bool _showUpdateUrlDialog = false;
  bool _showDeleteDialog = false;
  bool _showResultDialog = false;
  LxSource? _editing;
  LxSource? _deleting;

  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _updateUrlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 与全局取流入口共用同一个仓库实例，避免重复 closeAll/reload。
    _repo = LxMusicApi.instance.repo;
    _checker = LxUpdateChecker(
      repo: _repo,
      onSourcesChanged: () => LxMusicApi.instance.reload(),
    );
    _refresh();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _updateUrlController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final sources = await _repo.all();
    final globalAuto = await _repo.globalAutoUpdate();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _globalAuto = globalAuto;
      _fallbackEnabled = SourceFallback.enabled();
      _loading = false;
    });
    // 进入管理页时按开关做一次静默检测（30 分钟节流），实现
    // 「检测到更新后自动更新音源」而不必用户手动点。
    await _silentCheck();
  }

  Future<void> _refreshSources() async {
    final sources = await _repo.all();
    if (!mounted) return;
    setState(() => _sources = sources);
  }

  Future<void> _silentCheck() async {
    final last = await _repo.lastCheckAt();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < 30 * 60 * 1000) return;
    final anyAuto = _globalAuto || _sources.any((s) => s.autoUpdate);
    if (!anyAuto) return;
    await _runCheck(showDialog: false);
  }

  Future<void> _runCheck({required bool showDialog}) async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final outcomes = await _checker.checkAll();
      await LxMusicApi.instance.reload();
      await _refreshSources();
      if (!mounted) return;
      setState(() {
        _checking = false;
        _outcomes = outcomes;
        _showResultDialog = showDialog;
      });
      final applied = outcomes.where((o) => o.applied).length;
      if (applied > 0) {
        showAppSnack('已自动更新 $applied 个洛雪音源');
      } else if (!showDialog) {
        // 静默检测无需打扰用户
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _checking = false);
      showAppSnack('检测更新失败：$e');
    }
  }

  // ---------------- 导入 ----------------

  Future<void> _importFiles() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['js'],
        allowMultiple: true,
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      var count = 0;
      final warnings = <String>[];
      for (final f in res.files) {
        String script;
        if (f.bytes != null) {
          script = utf8.decode(f.bytes!, allowMalformed: true);
        } else if (f.path != null) {
          script = await File(f.path!).readAsString();
        } else {
          continue;
        }
        for (final w in LxSource.validateScript(script)) {
          warnings.add('${f.name}: $w');
        }
        await _repo.add(script: script);
        count++;
      }
      await LxMusicApi.instance.reload();
      await _refreshSources();
      showAppSnack(count > 0 ? '已导入 $count 个洛雪音源' : '未导入任何音源');
      if (warnings.isNotEmpty) {
        showAppSnack('安全提示：${warnings.take(2).join("；")}');
      }
    } catch (e) {
      showAppSnack('导入失败：$e');
    }
  }

  Future<void> _importUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || !(url.startsWith('http://') || url.startsWith('https://'))) {
      showAppSnack('请填写有效的 http(s) 音源链接');
      return;
    }
    setState(() => _showUrlDialog = false);
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
        responseType: ResponseType.plain,
      ));
      final resp = await dio.get(url);
      final data = resp.data;
      final script = data is String
          ? data
          : (data is List<int> ? utf8.decode(data, allowMalformed: true) : '');
      if (script.isEmpty) {
        showAppSnack('链接未返回脚本内容');
        return;
      }
      final src = await _repo.add(script: script, sourceUrl: url);
      await LxMusicApi.instance.reload();
      await _refreshSources();
      showAppSnack('已导入「${src.name}」${src.version}（更新地址=导入链接）');
      for (final w in LxSource.validateScript(script)) {
        showAppSnack('安全提示：$w');
      }
    } catch (e) {
      showAppSnack('从链接导入失败：$e');
    }
  }

  // ---------------- 单源操作 ----------------

  Future<void> _toggleEnabled(LxSource s, bool v) async {
    await _repo.update(s.copyWith(enabled: v));
    await LxMusicApi.instance.reload();
    await _refreshSources();
    showAppSnack(v ? '已启用「${s.name}」' : '已停用「${s.name}」');
  }

  Future<void> _toggleAutoUpdate(LxSource s, bool v) async {
    await _repo.update(s.copyWith(autoUpdate: v));
    await _refreshSources();
  }

  void _openUpdateUrl(LxSource s) {
    _editing = s;
    _updateUrlController.text = s.updateUrl;
    setState(() => _showUpdateUrlDialog = true);
  }

  Future<void> _saveUpdateUrl() async {
    final s = _editing;
    if (s == null) return;
    await _repo.update(s.copyWith(updateUrl: _updateUrlController.text.trim()));
    setState(() => _showUpdateUrlDialog = false);
    await _refreshSources();
    showAppSnack('已保存「${s.name}」的更新地址');
  }

  void _confirmDelete(LxSource s) {
    _deleting = s;
    setState(() => _showDeleteDialog = true);
  }

  Future<void> _delete() async {
    final s = _deleting;
    if (s == null) return;
    await _repo.remove(s.id);
    await LxMusicApi.instance.reload();
    setState(() => _showDeleteDialog = false);
    await _refreshSources();
    showAppSnack('已删除「${s.name}」');
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '洛雪音源',
      snackbarHost: appSnackbarHostState,
      bottomBar: _buildDialogs(),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.zero,
              children: [
                _buildIntro(),
                const SizedBox(height: 18),
                _buildActions(),
                const SizedBox(height: 18),
                const SectionHeader(title: '自动更新与切换', icon: Icons.sync_rounded),
                GlassCard(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: [
                      MiuixSwitchPreference(
                        title: '自动更新洛雪音源',
                        summary: '检测到新版本后自动下载替换并重载（也可单源单独开启）',
                        startAction: Icon(Icons.system_update_alt_rounded,
                            color: AppColors.accent, size: 22),
                        value: _globalAuto,
                        onChanged: (v) async {
                          await _repo.setGlobalAutoUpdate(v);
                          if (!mounted) return;
                          setState(() => _globalAuto = v);
                        },
                      ),
                      const MiuixHorizontalDivider(),
                      MiuixSwitchPreference(
                        title: '取链失败自动切换音源',
                        summary: '原生接口取链失败时自动改用洛雪音源补链'
                            '（未登录也能播放；纯洛雪模式下不生效）',
                        startAction: Icon(Icons.swap_horiz_rounded,
                            color: AppColors.accentAlt, size: 22),
                        value: _fallbackEnabled,
                        onChanged: (v) async {
                          await SourceFallback.setEnabled(v);
                          if (!mounted) return;
                          setState(() => _fallbackEnabled = v);
                        },
                      ),
                      const MiuixHorizontalDivider(),
                      MiuixArrowPreference(
                        title: '音源测试',
                        summary: '按单个音源 / 音质 / 子源 / 曲目平台测试洛雪取流',
                        startAction: Icon(Icons.network_check_rounded,
                            color: AppColors.cyan, size: 22),
                        onClick: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const SourceTestPage()),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                SectionHeader(
                    title: '已导入音源（${_sources.length}）',
                    icon: Icons.extension_rounded),
                if (_sources.isEmpty)
                  _buildEmpty()
                else
                  for (final s in _sources) _buildSourceCard(s),
                const SizedBox(height: 20),
              ],
            ),
    );
  }

  Widget _buildIntro() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        '洛雪音源是用户自行导入的 JS 取流插件，App 不内置、不分发任何音源。'
        '未登录平台账号时也可用它取流播放；返回的 mflac/mgg + ekey 走本地流式解密。'
        'URL 导入时更新地址默认就是导入链接，可随时在下方修改。',
        style: TextStyle(
            fontSize: 11.5, height: 1.6, color: AppColors.textTertiary),
      ),
    );
  }

  Widget _buildActions() {
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          MiuixTextButton(
            _checking ? '检测中…' : '检测更新',
            onPressed: _checking ? null : () => _runCheck(showDialog: true),
          ),
          MiuixTextButton('从文件导入', onPressed: _importFiles),
          MiuixTextButton(
            '从链接导入',
            onPressed: () {
              _urlController.clear();
              setState(() => _showUrlDialog = true);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return GlassCard(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
        child: Column(
          children: [
            Icon(Icons.extension_off_rounded,
                size: 44, color: AppColors.textTertiary),
            const SizedBox(height: 12),
            Text(
              '还没有导入任何洛雪音源\n点上方「从文件导入」或「从链接导入」添加',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceCard(LxSource s) {
    final hasUpdate = s.latestVersion.isNotEmpty;
    return GlassCard(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: s.enabled
                        ? AppColors.textPrimary
                        : AppColors.textTertiary,
                  ),
                ),
              ),
              if (hasUpdate)
                TagBadge('v${s.version} → v${s.latestVersion}',
                    color: AppColors.danger)
              else
                TagBadge(s.version.isEmpty ? '未知版本' : 'v${s.version}'),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            [
              if (s.author.isNotEmpty) '作者 ${s.author}',
              if (s.homepage.isNotEmpty) s.homepage,
              s.canCheckUpdate ? '更新地址已设置' : '未设置更新地址',
            ].join('  ·  '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('启用', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              Switch(
                value: s.enabled,
                onChanged: (v) => _toggleEnabled(s, v),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 8),
              Text('自动更新',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              Switch(
                value: s.autoUpdate,
                onChanged: (v) => _toggleAutoUpdate(s, v),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
          Wrap(
            spacing: 4,
            children: [
              MiuixTextButton('检测更新',
                  onPressed: () async {
                    final o = await _checker.checkOne(
                      s,
                      autoApply: _globalAuto || s.autoUpdate,
                    );
                    await LxMusicApi.instance.reload();
                    await _refreshSources();
                    if (!mounted) return;
                    setState(() {
                      _outcomes = [o];
                      _showResultDialog = true;
                    });
                  }),
              MiuixTextButton('更新地址',
                  onPressed: () => _openUpdateUrl(s)),
              MiuixTextButton('删除',
                  onPressed: () => _confirmDelete(s),
                  textStyle: TextStyle(color: AppColors.danger, fontSize: 13)),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------- 弹层 ----------------

  Widget _buildDialogs() {
    return Stack(
      children: [
        MiuixOverlayDialog(
          show: _showUrlDialog,
          title: '从链接导入音源',
          summary: '粘贴洛雪音源的在线 JS 地址；导入后该链接同时作为检测更新地址',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () => setState(() => _showUrlDialog = false),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppTextField(
                controller: _urlController,
                autofocus: true,
                label: 'https://…/script.js',
                singleLine: true,
                keyboardType: TextInputType.url,
                leadingIcon: Icon(Icons.link_rounded,
                    size: 18, color: AppColors.textTertiary),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MiuixTextButton('取消',
                      onPressed: () => setState(() => _showUrlDialog = false)),
                  const SizedBox(width: 8),
                  MiuixTextButton('导入', onPressed: _importUrl),
                ],
              ),
            ],
          ),
        ),
        MiuixOverlayDialog(
          show: _showUpdateUrlDialog,
          title: '编辑更新地址',
          summary: '文件导入的音源可在此填写 raw 链接（github / gitee 等）以启用检测更新',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () =>
              setState(() => _showUpdateUrlDialog = false),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppTextField(
                controller: _updateUrlController,
                autofocus: true,
                label: '更新地址（留空 = 不检测）',
                singleLine: true,
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MiuixTextButton('取消',
                      onPressed: () =>
                          setState(() => _showUpdateUrlDialog = false)),
                  const SizedBox(width: 8),
                  MiuixTextButton('保存', onPressed: _saveUpdateUrl),
                ],
              ),
            ],
          ),
        ),
        MiuixOverlayDialog(
          show: _showDeleteDialog,
          title: '删除音源？',
          summary: '「${_deleting?.name ?? ''}」的脚本文件与元数据将被移除，不可撤销。',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () => setState(() => _showDeleteDialog = false),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              MiuixTextButton('取消',
                  onPressed: () => setState(() => _showDeleteDialog = false)),
              const SizedBox(width: 8),
              MiuixTextButton('删除',
                  onPressed: _delete,
                  textStyle: TextStyle(color: AppColors.danger, fontSize: 13)),
            ],
          ),
        ),
        MiuixOverlayDialog(
          show: _showResultDialog,
          title: '检测更新结果',
          summary: '共 ${_outcomes?.length ?? 0} 个音源',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () => setState(() => _showResultDialog = false),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final o in _outcomes ?? const <LxUpdateOutcome>[])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        o.isError
                            ? Icons.error_outline_rounded
                            : (o.hasUpdate
                                ? Icons.new_releases_rounded
                                : Icons.check_circle_outline_rounded),
                        size: 16,
                        color: o.isError
                            ? AppColors.danger
                            : (o.hasUpdate
                                ? AppColors.accent
                                : AppColors.textTertiary),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${o.name}：${o.summary}',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: MiuixTextButton('知道了',
                    onPressed: () =>
                        setState(() => _showResultDialog = false)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
