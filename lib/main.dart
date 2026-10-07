import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'core/capture_trust.dart';
import 'core/kv_store.dart';
import 'core/update_checker.dart';
import 'theme/app_theme.dart';
import 'ui/pages/discover_home.dart';
import 'ui/pages/library_home.dart';
import 'ui/pages/search_home.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await KvStore.ensureInit();
  // 抓包支持：必须在任何 HttpClient 创建之前安装（release 构建同样生效）
  await CaptureTrust.load();
  HttpOverrides.global = CaptureHttpOverrides();
  runApp(const BaijiMusicApp());
}

class BaijiMusicApp extends StatefulWidget {
  const BaijiMusicApp({super.key});

  @override
  State<BaijiMusicApp> createState() => _BaijiMusicAppState();
}

class _BaijiMusicAppState extends State<BaijiMusicApp> {
  @override
  void initState() {
    super.initState();
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    await Future.delayed(const Duration(seconds: 2)); // 延迟检查，避免启动时卡顿
    final info = await UpdateChecker.instance.check();
    if (info != null && mounted) {
      _showUpdateDialog(info);
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
    return MaterialApp(
      title: '白姬音乐',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
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