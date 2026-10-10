import 'dart:io';

import 'package:flutter/material.dart';
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
    final ctx = _dialogContext;
    if (ctx == null || !ctx.mounted) return;
    if (outcome.state == UpdateState.available && outcome.info != null) {
      _showUpdateDialog(ctx, outcome.info!);
    }
  }

  void _showUpdateDialog(BuildContext context, UpdateInfo info) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('发现新版本', style: TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                info.name.isNotEmpty ? '${info.name}（${info.tag}）' : info.tag,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600),
              ),
              if (info.body.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  info.summary(200),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textTertiary),
                ),
              ],
            ],
          ),
        ),
        actions: [
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
    return MaterialApp(
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
  }
}