import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:media_kit/media_kit.dart';

import 'core/agreement_store.dart';
import 'core/cache_manager.dart';
import 'core/capture_trust.dart';
import 'core/kv_store.dart';
import 'core/lyric_settings.dart';
import 'core/update_checker.dart';
import 'theme/app_theme.dart';
import 'ui/pages/discover_home.dart';
import 'ui/pages/library_home.dart';
import 'ui/pages/search_home.dart';
import 'ui/shell.dart';
import 'ui/widgets/agreement_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await KvStore.ensureInit();
  // 抓包支持：必须在任何 HttpClient 创建之前安装（release 构建同样生效）
  await CaptureTrust.load();
  HttpOverrides.global = CaptureHttpOverrides();
  // 歌词显示偏好走 ChangeNotifier，这里先恢复一次，播放页首帧就是正确字号
  await LyricSettings.instance.load();
  // 内存图片缓存上限走KvStore，每次启动都要重新应用一次（进程级设置）
  CacheManager.applyMemoryLimit();
  runApp(const BaijiMusicApp());
}

class BaijiMusicApp extends StatefulWidget {
  const BaijiMusicApp({super.key});

  @override
  State<BaijiMusicApp> createState() => _BaijiMusicAppState();
}

class _BaijiMusicAppState extends State<BaijiMusicApp> {
  /// 全局 Navigator 钥匙。
  ///
  /// 弹出「更新提示 / 首次协议」这类**需要覆盖整个 App** 的对话框时，
  /// 不能用本 State 的 [context]：它是 [MaterialApp] 自己的元素，
  /// 之上没有 Navigator 和 MaterialLocalizations，调 showDialog 会直接抛异常
  /// ——这正是"检查更新点了没反应"的根因。
  final _navigatorKey = GlobalKey<NavigatorState>();

  /// 待展示的更新信息（MiuixOverlayDialog 是声明式组件，靠这个字段驱动）。
  UpdateInfo? _pendingUpdate;

  @override
  void initState() {
    super.initState();
    // 首帧渲染完成后再弹协议 / 查更新：此刻 Navigator 已挂载，启动也不会白屏。
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  /// 对话框用的 context（Navigator 自身的 context，Material 环境齐全）。
  BuildContext? get _dialogContext => _navigatorKey.currentContext;

  /// 启动流程：先确认协议（仅首次），再检查更新。
  Future<void> _bootstrap() async {
    final ctx = _dialogContext;
    if (ctx == null || !ctx.mounted) return;
    if (!AgreementStore.accepted) {
      final agreed = await showAgreementDialog(ctx);
      if (!agreed) return;
    }
    await _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    await Future.delayed(const Duration(seconds: 2)); // 延迟检查，避免启动时卡顿
    final outcome = await UpdateChecker.instance.check();
    if (!mounted) return;
    if (outcome.state == UpdateState.available && outcome.info != null) {
      setState(() => _pendingUpdate = outcome.info);
    }
  }

  /// 更新弹窗的「忽略」：写入忽略列表并关闭。
  Future<void> _ignoreUpdate(UpdateInfo info) async {
    await UpdateChecker.instance.ignore(info.tag);
    if (!mounted) return;
    setState(() => _pendingUpdate = null);
  }

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp(
      title: '白姬音乐',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      navigatorKey: _navigatorKey,
      home: AppShell(
        titles: const ['发现', '搜索', '我的'],
        pages: const [
          DiscoverHome(),
          SearchHome(),
          LibraryHome(),
        ],
      ),
    );

    // Miuix 主题骨架：种子色取品牌紫，整套 Miuix 组件（导航栏 / 偏好项 /
    // 滑块 / 开关 / 对话框）直接长在 App 的霓虹视觉体系上。
    // MiuixPopupScope + MiuixPopupHost：在 MaterialApp 之外自建弹窗根域，
    // 让全局更新提示（MiuixOverlayDialog）有地方渲染——各页面内的
    // MiuixScaffold 也会复用这个 root，不会出现第二套遮罩层。
    return MiuixTheme(
      data: AppTheme.miuix(),
      child: MiuixPopupScope(
        establishRoot: true,
        child: Stack(
          children: [
            app,
            MiuixOverlayDialog(
              show: _pendingUpdate != null,
              title: '发现新版本',
              summary: _pendingUpdate?.tag ?? '',
              backgroundColor: AppColors.bg2,
              onDismissRequest: () {
                if (mounted) setState(() => _pendingUpdate = null);
              },
              content: _buildUpdateDialogContent(),
            ),
            const MiuixPopupHost(),
          ],
        ),
      ),
    );
  }

  Widget _buildUpdateDialogContent() {
    final info = _pendingUpdate;
    if (info == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info.name.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              info.name,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        if (info.body.trim().isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              child: Text(
                info.summary(200),
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            MiuixTextButton('忽略此版本', onPressed: () => _ignoreUpdate(info)),
            const SizedBox(width: 8),
            MiuixTextButton('稍后', onPressed: () {
              if (mounted) setState(() => _pendingUpdate = null);
            }),
            const SizedBox(width: 8),
            MiuixTextButton('前往更新', onPressed: () {
              if (mounted) setState(() => _pendingUpdate = null);
              UpdateChecker.instance.openRelease(info.url);
            }),
          ],
        ),
      ],
    );
  }
}