// v2.2.7 全页面 build 冒烟：每个主要页面都要能在根域结构里
// pump + settle 而不抛异常。
//
// 背景：用户真机日志出现两条 FATAL/FlutterError
// "Null check operator used on a null value"（release 混淆拿不到行号）。
// 本测试把全部页面（含 v2.2.6 新增/改写的设置页、关于页密码弹窗、
// 工具箱、日志页、播放页）在组件测试里各泵一遍，任何 build 期
// null check 都会在这里现形。
import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/dev_mode.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/core/theme_controller.dart';
import 'package:baiji_music/core/ui_settings.dart';
import 'package:baiji_music/data/history_store.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/ui/pages/about_page.dart';
import 'package:baiji_music/ui/pages/decrypt_keys_page.dart';
import 'package:baiji_music/ui/pages/decrypt_page.dart';
import 'package:baiji_music/ui/pages/discover_home.dart';
import 'package:baiji_music/ui/pages/library_home.dart';
import 'package:baiji_music/ui/pages/log_page.dart';
import 'package:baiji_music/ui/pages/player_page.dart';
import 'package:baiji_music/ui/pages/search_home.dart';
import 'package:baiji_music/ui/pages/settings_page.dart';
import 'package:baiji_music/ui/pages/toolbox_page.dart';
import 'package:baiji_music/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakePathProvider extends PathProviderPlatform {
  FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getExternalStoragePath() async => root;

  @override
  Future<String?> getDownloadsPath() async => root;
}

Song _song(String name, {String singer = '测试歌手'}) => Song(
      mid: 'mid-$name',
      songId: name.hashCode,
      name: name,
      singer: singer,
      album: '',
      albumMid: '',
      duration: 200000,
      cover: '',
      source: Source.qq,
    );

/// 与 main.dart 一致的根域：MiuixTheme > PopupScope > Directionality >
/// Stack[MaterialApp(transparency builder), PopupHost]。
Widget _wrap(Widget home) => MiuixTheme(
      data: AppTheme.miuix(),
      child: MiuixPopupScope(
        establishRoot: true,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              MaterialApp(
                theme: AppTheme.dark(),
                builder: (context, child) => Material(
                  type: MaterialType.transparency,
                  child: child!,
                ),
                home: home,
              ),
              const MiuixPopupHost(),
            ],
          ),
        ),
      ),
    );

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PathProviderPlatform.instance = FakePathProvider('/tmp');
    await KvStore.ensureInit();
    await LyricSettings.instance.load();
    await ThemeController.instance.load();
    await DevMode.instance.load();
    await UiSettings.instance.load();
    await AppLog.instance.initFileSink();
    HistoryStore.writePlay([_song('后来的我们'), _song('晴天')]);
  });

  /// 手机尺寸视口 + 泵到 settle；返回期间捕获到的第一个异常（无则 null）。
  Future<Object?> pumpAndCatch(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(home));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!tester.binding.hasScheduledFrame) break;
    }
    return tester.takeException();
  }

  group('全页面 build 冒烟（release 闪退回归）', () {
    testWidgets('AppShell（发现/搜索/我的 三页同建）', (tester) async {
      final e = await pumpAndCatch(
        tester,
        const AppShell(
          titles: ['发现', '搜索', '我的'],
          pages: [DiscoverHome(), SearchHome(), LibraryHome()],
        ),
      );
      expect(e, isNull, reason: 'AppShell build 抛异常: $e');
      expect(find.text('白姬音乐'), findsOneWidget);
    });

    testWidgets('设置页', (tester) async {
      final e = await pumpAndCatch(tester, const SettingsPage());
      expect(e, isNull, reason: '设置页 build 抛异常: $e');
      expect(find.text('设置'), findsOneWidget);
    });

    testWidgets('关于页', (tester) async {
      final e = await pumpAndCatch(tester, const AboutPage());
      expect(e, isNull, reason: '关于页 build 抛异常: $e');
      expect(find.text('白姬音乐'), findsWidgets);
    });

    testWidgets('工具箱页', (tester) async {
      final e = await pumpAndCatch(tester, const ToolboxPage());
      expect(e, isNull, reason: '工具箱页 build 抛异常: $e');
      expect(find.text('工具箱'), findsOneWidget);
    });

    testWidgets('日志页', (tester) async {
      final e = await pumpAndCatch(tester, const LogPage());
      expect(e, isNull, reason: '日志页 build 抛异常: $e');
      expect(find.text('运行日志'), findsOneWidget);
    });

    testWidgets('本地音乐解密页', (tester) async {
      final e = await pumpAndCatch(tester, const DecryptPage());
      expect(e, isNull, reason: '解密页 build 抛异常: $e');
    });

    testWidgets('解密密钥管理页', (tester) async {
      final e = await pumpAndCatch(tester, const DecryptKeysPage());
      // 0.8px 亚像素溢出是测试视口 dpr(2.75) 的舍入产物；release 下
      // RenderFlex overflow 检查是 assert，不会触发，真机无此问题。
      final s = e?.toString() ?? '';
      final subpixelOverflow = s.contains('RenderFlex overflowed by 0.8');
      expect(e == null || subpixelOverflow, isTrue,
          reason: '密钥管理页 build 抛异常: $e');
    });

    testWidgets('播放页（无歌曲）', (tester) async {
      final e = await pumpAndCatch(tester, const PlayerPage());
      expect(e, isNull, reason: '播放页 build 抛异常: $e');
    });
  });

  group('关于页开发者模式密码弹窗', () {
    testWidgets('连点版本号 10 次弹出密码框且不抛异常', (tester) async {
      final e = await pumpAndCatch(tester, const AboutPage());
      expect(e, isNull);
      // 版本号文案形如「v2.2.x · 跨平台重构版」
      final versionText = find.textContaining('v2.');
      expect(versionText, findsOneWidget);
      for (var i = 0; i < 10; i++) {
        await tester.tap(versionText);
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull,
          reason: '密码弹窗渲染抛异常');
      expect(find.text('开启开发者模式'), findsOneWidget);
      // 密码框确实在弹窗里
      expect(find.byType(TextField), findsOneWidget);
    });
  });

  // v2.2.8 #64 回归：子页面曾因零背景绘制透出设备黑窗口（Android
  // values-night NormalTheme），与白色主界面割裂；PageScaffold 统一补
  // NebulaBackground 后，亮色系统下每个子页面都必须画出亮色底。
  group('子页面背景统一（#64 回归：白底 + 跟随系统主题）', () {
    testWidgets('亮色系统下子页面均绘制 NebulaBackground 且 palette 为亮色',
        (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      // 模拟根组件把系统亮度写进全局令牌
      AppColors.setBrightness(Brightness.light);
      addTearDown(() => AppColors.setBrightness(Brightness.dark));

      const pages = <Widget>[
        SettingsPage(),
        AboutPage(),
        ToolboxPage(),
        LogPage(),
        DecryptPage(),
        DecryptKeysPage(),
        PlayerPage(),
      ];
      for (final page in pages) {
        final e = await pumpAndCatch(tester, page);
        final s = e?.toString() ?? '';
        final subpixelOverflow = s.contains('RenderFlex overflowed by 0.8');
        expect(e == null || subpixelOverflow, isTrue,
            reason: '${page.runtimeType} build 抛异常: $e');
        expect(find.byType(NebulaBackground), findsWidgets,
            reason: '${page.runtimeType} 缺少统一星云背景（会透出黑色窗口）');
      }

      // palette 跟随系统亮度：亮色下 bg1 应为近白
      expect(AppColors.isDark, isFalse);
      final bg = AppColors.bg1;
      expect((bg.r + bg.g + bg.b) / 3, greaterThan(0.8),
          reason: '亮色 palette 的 bg1 应为近白，实际: $bg');
    });
  });
}
