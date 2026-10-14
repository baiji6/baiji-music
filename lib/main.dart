import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:media_kit/media_kit.dart';

import 'core/agreement_store.dart';
import 'core/app_logger.dart';
import 'core/cache_manager.dart';
import 'core/capture_trust.dart';
import 'core/dev_mode.dart';
import 'core/kv_store.dart';
import 'core/lyric_settings.dart';
import 'core/signature_guard.dart';
import 'core/theme_controller.dart';
import 'core/ui_settings.dart';
import 'core/update_checker.dart';
import 'player/player_controller.dart';
import 'theme/app_theme.dart';
import 'ui/pages/discover_home.dart';
import 'ui/pages/library_home.dart';
import 'ui/pages/search_home.dart';
import 'ui/pages/tamper_block_page.dart';
import 'ui/shell.dart';
import 'ui/widgets/agreement_dialog.dart';
import 'ui/widgets/app_snackbar.dart';
import 'ui/widgets/app_widgets.dart' show changelogSheet;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await KvStore.ensureInit();
  // 抓包支持：必须在任何 HttpClient 创建之前安装（release 构建同样生效）
  await CaptureTrust.load();
  HttpOverrides.global = CaptureHttpOverrides();
  // 歌词显示偏好走 ChangeNotifier，这里先恢复一次，播放页首帧就是正确字号
  await LyricSettings.instance.load();
  // 主题偏好（莫奈取色开关 + 壁纸种子）也要在首帧前就位
  await ThemeController.instance.load();
  // 开发者模式偏好：决定设置页是否显示「开发者模式」分区
  await DevMode.instance.load();
  // 全局界面偏好（圆角等）：卡片在首帧就要用上正确圆角
  await UiSettings.instance.load();
  // 内存图片缓存上限走KvStore，每次启动都要重新应用一次（进程级设置）
  CacheManager.applyMemoryLimit();
  // 日志落盘 + 回读当天历史：v2.2.6 起日志不再"每次打开软件就清空"，
  // 闪退后打开日志页能看到崩之前发生了什么。
  await AppLog.instance.initFileSink();
  AppLog.i('App', '白姬音乐启动');
  _installCrashGuards();
  // #78 签名校验：release 构建先验签再进正常 UI。
  // Android 比对构建期锚定的证书指纹；桌面端验签文件完整性清单；
  // 失败 = 安装包被篡改，只给拦截页，不执行任何业务代码。
  final signature = await SignatureGuard.check();
  if (signature.tampered) {
    AppLog.f('SignatureGuard', '签名校验失败：${signature.detail}');
    AppLog.instance.flushSync();
    runZonedGuarded(() {
      runApp(TamperBlockApp(result: signature));
    }, _onUncaughtZoneError);
    return;
  }
  AppLog.i('SignatureGuard', signature.detail);
  // 异步未捕获异常的最后一层兜底：zone 内 runApp，崩前同步刷盘。
  runZonedGuarded(() {
    runApp(const BaijiMusicApp());
  }, _onUncaughtZoneError);
}

/// 框架错误 / 平台错误 → 写 FATAL 日志并同步刷盘，再交还原有处理。
void _installCrashGuards() {
  final originalOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLog.f('FlutterError', details.exceptionAsString(), details.stack);
    AppLog.instance.flushSync();
    originalOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.f('Platform', '未捕获的平台错误', error);
    AppLog.instance.flushSync();
    return true;
  };
}

/// zone 级未捕获异常（Future / 微任务里漏掉的错误）。
void _onUncaughtZoneError(Object error, StackTrace stack) {
  AppLog.f('Uncaught', '未捕获异常', error);
  AppLog.instance.flushSync();
}

class BaijiMusicApp extends StatefulWidget {
  const BaijiMusicApp({super.key});

  @override
  State<BaijiMusicApp> createState() => _BaijiMusicAppState();
}

class _BaijiMusicAppState extends State<BaijiMusicApp> with WidgetsBindingObserver {
  /// 全局 Navigator 钥匙。
  ///
  /// 弹出「更新提示 / 首次协议」这类**需要覆盖整个 App** 的对话框时，
  /// 不能用本 State 的 [context]：它是 [MaterialApp] 自己的 element，
  /// 之上没有 Navigator 和 MaterialLocalizations，调 showDialog 会直接抛异常
  /// ——这正是"检查更新点了没反应"的根因。
  final _navigatorKey = GlobalKey<NavigatorState>();

  /// 待展示的更新信息（MiuixOverlayDialog 是声明式组件，靠这个字段驱动）。
  UpdateInfo? _pendingUpdate;

  /// 当前生效的系统亮度。v2.2.5 起 App 整体跟随系统切换深/浅色，
  /// 全局令牌（AppColors）与歌词默认色都要按它刷新。
  Brightness _brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;

  @override
  void initState() {
    super.initState();
    // 首帧前先把令牌对齐当前亮度，避免浅色系统下第一帧闪深色。
    AppColors.setBrightness(_brightness);
    WidgetsBinding.instance.addObserver(this);
    ThemeController.instance.addListener(_onThemeChanged);
    // 播放取流失败（未登录 / 无版权 / 网络异常）以前只写进错误流，而
    // PlayerController.onError 没有任何 UI 消费方——用户点歌后肉眼
    // 「什么都没发生」。这里统一转成全局 snackbar，失败必须可见。
    PlayerController.instance.onError.listen((msg) {
      if (mounted) showAppSnack(msg);
    });
    // 首帧渲染完成后再弹协议 / 查更新：此刻 Navigator 已挂载，启动也不会白屏。
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ThemeController.instance.removeListener(_onThemeChanged);
    super.dispose();
  }

  /// 系统深浅色切换：MaterialApp / Miuix 主题各自跟随，但全局令牌
  /// （AppColors）与歌词默认色是「进程级静态量」，必须在这里手动对齐，
  /// 否则 NebulaBackground、GlassCard 这些直接读令牌的地方会停在旧主题。
  @override
  void didChangePlatformBrightness() {
    final b = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (b == _brightness) return;
    _brightness = b;
    AppColors.setBrightness(b);
    // 歌词三色在用户没自定义时跟随主题，推一次让播放页重取默认色。
    LyricSettings.instance.notifyThemeChanged();
    if (mounted) setState(() {});
  }

  /// 莫奈开关 / 壁纸种子就绪 → 用新种子重建主题。
  void _onThemeChanged() {
    if (mounted) setState(() {});
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
    // 双保险：观察者漏拍时（如测试里直接改 platformBrightnessTestValue），
    // 构建时也以当前系统亮度为准。幂等，不会触发多余重建。
    final sysBrightness = MediaQuery.platformBrightnessOf(context);
    if (sysBrightness != _brightness) {
      _brightness = sysBrightness;
      AppColors.setBrightness(sysBrightness);
    }
    final theme = ThemeController.instance;
    // 莫奈开启时用壁纸种子取色；解析中/不支持时为 null，回退品牌紫。
    final seed = theme.monet ? theme.seed : null;

    final app = MaterialApp(
      title: '白姬音乐',
      debugShowCheckedModeBanner: false,
      // 明暗双主题 + 跟随系统：MaterialApp 自己监听平台亮度切换，
      // 不需要在这里手动判断。
      theme: AppTheme.light(seed: seed),
      darkTheme: AppTheme.dark(seed: seed),
      themeMode: ThemeMode.system,
      navigatorKey: _navigatorKey,
      // 全局 Material 祖先。v2.2.4 全量 Miuix 化后页面里已无任何 Material
      // 组件，带来两个连带缺陷：
      // 1) 所有 Text 回落到 MaterialApp 的兜底 _errorTextStyle（红色等宽
      //    48px + 黄色双下划线）。显式样式只覆盖颜色/字号/字重，未指定的
      //    decoration 字段被 merge 继承——就是「每条文字下面一条黄色双线」；
      // 2) MiuixTextField 内部的 Material TextField 找不到 Material 祖先，
      //    debug 下直接断言崩溃，搜索页整页布局连带溢出近 10 万像素。
      // 用 transparency 类型的 Material 包一层：向下提供
      // AnimatedDefaultTextStyle（正常正文字体）与 ink 承载，不引入背景色、
      // 不拦截命中测试，视觉零变化。
      builder: (context, child) => Material(
        type: MaterialType.transparency,
        child: child!,
      ),
      home: AppShell(
        titles: const ['发现', '搜索', '我的'],
        pages: const [
          DiscoverHome(),
          SearchHome(),
          LibraryHome(),
        ],
      ),
    );

    // Miuix 主题骨架：light/dark 两套品牌配色交给 MiuixThemeController，
    // 由它按系统亮度挑一套（它自己读 MediaQuery，明暗切换自动生效）。
    // 种子色取品牌紫（或莫奈壁纸种子），整套 Miuix 组件（导航栏 / 偏好项 /
    // 滑块 / 开关 / 对话框）直接长在 App 的霓虹视觉体系上。
    // MiuixPopupScope + MiuixPopupHost：在 MaterialApp 之外自建弹窗根域，
    // 让全局更新提示（MiuixOverlayDialog）有地方渲染——各页面内的
    // MiuixScaffold 也会复用这个 root，不会出现第二套遮罩层。
    // 根 Stack 位于 MaterialApp 之外、没有 Directionality 祖先：debug 下
    // Stack 解析 alignment 的断言会直接崩溃（release 断言被编译掉才侥幸
    // 跑起来），这里显式补一层。
    return MiuixThemeController(
      colorSchemeMode: MiuixColorSchemeMode.system,
      lightColors: AppTheme.miuixColors(brightness: Brightness.light, seed: seed),
      darkColors: AppTheme.miuixColors(brightness: Brightness.dark, seed: seed),
      child: MiuixPopupScope(
        establishRoot: true,
        child: Directionality(
          textDirection: TextDirection.ltr,
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
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        if (info.body.trim().isNotEmpty)
          // 更新日志按 Markdown 渲染（标题/列表/代码块/链接），与设置页的
          // 「更新日志」卡片同一份排版样式，不再把 `**加粗**`、`-` 列表
          // 这些原始符号直接怼到 Text 上。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: SingleChildScrollView(
              child: MarkdownBody(
                data: info.body,
                selectable: true,
                styleSheet: changelogSheet,
                // 更新日志里的图片多是 badge，加载不出来时别把布局撑破。
                imageBuilder: (uri, title, alt) => ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Image.network(
                    uri.toString(),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) => Text(
                      alt?.isNotEmpty == true ? alt! : '[图片]',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textTertiary),
                    ),
                  ),
                ),
              ),
            ),
          )
        else
          Text(
            '该版本没有提供更新说明。',
            style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
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
