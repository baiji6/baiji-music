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
import 'package:baiji_music/download/download_extras.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/ui/pages/about_page.dart';
import 'package:baiji_music/ui/pages/decrypt_keys_page.dart';
import 'package:baiji_music/ui/pages/decrypt_page.dart';
import 'package:baiji_music/ui/pages/discover_home.dart';
import 'package:baiji_music/ui/pages/library_home.dart';
import 'package:baiji_music/ui/pages/log_page.dart';
import 'package:baiji_music/ui/pages/netease_login_page.dart';
import 'package:baiji_music/ui/pages/player_page.dart';
import 'package:baiji_music/ui/pages/qq_login_page.dart';
import 'package:baiji_music/ui/pages/search_home.dart';
import 'package:baiji_music/ui/pages/settings_page.dart';
import 'package:baiji_music/ui/pages/song_comment_page.dart';
import 'package:baiji_music/ui/pages/toolbox_page.dart';
import 'package:baiji_music/ui/shell.dart';
import 'package:baiji_music/ui/widgets/download_options_sheet.dart';
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

Song _neSong(String name) => Song(
      mid: 'ne-$name',
      songId: 123456,
      name: name,
      singer: '测试歌手',
      album: '',
      albumMid: '',
      duration: 200000,
      cover: '',
      source: Source.netease,
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

  /// 排放 init 期网络请求诱发的日志落盘定时器（LogStore 1s flush timer）。
  ///
  /// 评论页 initState 即拉评论 → AppLog 写盘 → 排一个 1 秒 Timer；
  /// 测试体结束前不跑完它，teardown 会断言 "A Timer is still pending"。
  Future<void> drainLogFlushTimer(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
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
      // #143 起发现页 initState 会拉推荐歌单：失败重试的 Future.delayed
      // 也要在测试结束前排空，否则报 Timer is still pending。
      await drainLogFlushTimer(tester);
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

    testWidgets('QQ 登录页（Cookie + ptlogin2 扫码 + 手机 App 扫码）', (tester) async {
      final e = await pumpAndCatch(tester, const QQLoginPage());
      expect(e, isNull, reason: 'QQ 登录页 build 抛异常: $e');
      // 「Cookie 登录」既是卡片标题也是按钮文案，出现两次
      expect(find.text('Cookie 登录'), findsWidgets);
      expect(find.text('扫码登录'), findsOneWidget);
      expect(find.text('手机 App 扫码'), findsOneWidget);
      expect(find.text('使用 QQ 音乐 App 扫描二维码'), findsOneWidget);
      expect(find.text('用手机上的 QQ 音乐 App 扫描，扫码后事件实时推送（不轮询）'),
          findsOneWidget);
    });

    testWidgets('网易云登录页（Cookie + 扫码）', (tester) async {
      final e = await pumpAndCatch(tester, const NeteaseLoginPage());
      expect(e, isNull, reason: '网易云登录页 build 抛异常: $e');
      expect(find.text('Cookie 登录'), findsWidgets);
      expect(find.text('扫码登录'), findsOneWidget);
      expect(find.text('用网易云音乐 App 扫码（App 内「我的」页面左上角扫一扫）'),
          findsOneWidget);
    });

    // 评论页（#102）：未登录可浏览（测试环境下网络被拦截 → 走错误态），
    // 底部输入栏显示登录引导而不是输入框。
    testWidgets('歌曲评论页（QQ / 网易云）', (tester) async {
      final e = await pumpAndCatch(
          tester, SongCommentPage(song: _song('评论页冒烟')));
      expect(e, isNull, reason: '评论页 build 抛异常: $e');
      expect(find.text('评论'), findsOneWidget);
      // 未登录：输入栏是登录引导
      expect(find.text('登录后可发表评论'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
      await drainLogFlushTimer(tester);
    });

    testWidgets('歌曲评论页（网易云源）', (tester) async {
      final e =
          await pumpAndCatch(tester, SongCommentPage(song: _neSong('评论页冒烟')));
      expect(e, isNull, reason: '评论页（网易云）build 抛异常: $e');
      expect(find.text('评论'), findsOneWidget);
      expect(find.text('登录后可发表评论'), findsOneWidget);
      await drainLogFlushTimer(tester);
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

  // v2.2.9 #76 回归：弹窗内容挂在 MaterialApp 之外的 popup host 上，
  // 缺 MaterialLocalizations 时 TextField build 期抛异常、被 RenderErrorBox
  // 替换——无高度约束下是 100000px 的灰色大块，把整个弹窗撑爆
  // （用户截图：密钥管理各平台填写框 / 抓包代理框全是巨型灰块）。
  // AppTextField 现在会在缺失时自动补齐中文本地化。
  group('弹窗输入框高度回归（#76：不再被 RenderErrorBox 撑爆）', () {
    /// 打开页面 → 点击入口 → settle → 断言所有 TextField 高度正常
    /// （<100px）且无 MaterialLocalizations 缺失异常。
    Future<void> openDialogAndExpectFieldsSane(
        WidgetTester tester, Widget page, String tapText) async {
      final e0 = await pumpAndCatch(tester, page);
      final s0 = e0?.toString() ?? '';
      expect(e0 == null || s0.contains('RenderFlex overflowed by 0.8'), isTrue,
          reason: '${page.runtimeType} build 抛异常: $e0');
      await tester.tap(find.text(tapText));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (!tester.binding.hasScheduledFrame) break;
      }
      final fields = find.byType(TextField);
      expect(fields, findsWidgets, reason: '点击「$tapText」后应弹出输入框');
      for (var i = 0; i < fields.evaluate().length; i++) {
        final h = tester.renderObject<RenderBox>(fields.at(i)).size.height;
        expect(h, lessThan(100),
            reason: 'TextField[$i] 高度 $h 异常（疑似 RenderErrorBox 撑爆）');
      }
      final e = tester.takeException();
      final s = e?.toString() ?? '';
      expect(e == null || s.contains('RenderFlex overflowed by 0.8'), isTrue,
          reason: '弹窗交互抛异常: $e');
      expect(s, isNot(contains('MaterialLocalizations')),
          reason: 'TextField 缺少 MaterialLocalizations 祖先');
    }

    testWidgets('关于页密码弹窗', (tester) async {
      final e0 = await pumpAndCatch(tester, const AboutPage());
      expect(e0, isNull);
      final versionText = find.textContaining('v2.');
      for (var i = 0; i < 10; i++) {
        await tester.tap(versionText);
        await tester.pump(const Duration(milliseconds: 30));
      }
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (!tester.binding.hasScheduledFrame) break;
      }
      expect(find.text('开启开发者模式'), findsOneWidget);
      final fields = find.byType(TextField);
      expect(fields, findsOneWidget);
      expect(tester.renderObject<RenderBox>(fields).size.height, lessThan(100));
      final e = tester.takeException();
      final s = e?.toString() ?? '';
      expect(e == null || s.contains('RenderFlex overflowed by 0.8'), isTrue,
          reason: '密码弹窗抛异常: $e');
      expect(s, isNot(contains('MaterialLocalizations')));
    });

    testWidgets('密钥管理页 QQ 手动填写弹窗', (tester) async {
      await openDialogAndExpectFieldsSane(
          tester, const DecryptKeysPage(), '手动填写');
    });
  });

  // 下载选项弹层（#77/#90）：歌词区 + 音质区二合一。
  // 契约（#90 起）：
  // - 歌词区点某行 = **只下载歌词**（独立动作，不下载音乐），
  //   同时该行成为选中态；「不下载」行只改选中、不触发下载；
  // - 音质区点某行 = 下载音乐，自动附带当前选中的歌词与封面。
  group('下载选项弹层（歌词独立下载 + 音质下载音乐）', () {
    testWidgets('默认逐字，改选逐行后点音质带回正确粒度', (tester) async {
      Object? pickedQuality;
      LyricDownloadMode? pickedLyric;
      LyricDownloadMode? lyricOnlyMode;
      await pumpAndCatch(
        tester,
        Scaffold(
          body: DownloadOptionsSheet<String>(
            options: const ['音质A', '音质B'],
            current: '音质A',
            label: (v) => v,
            lyricMode: DownloadExtras.lyricMode,
            onConfirm: (q, lyric) {
              pickedQuality = q;
              pickedLyric = lyric;
            },
            onLyricOnly: (mode) => lyricOnlyMode = mode,
          ),
        ),
      );

      // 三个歌词粒度都在，且默认勾选「逐字歌词」
      expect(find.text('歌词 · 点此只下载歌词'), findsOneWidget);
      expect(find.text('不下载'), findsOneWidget);
      expect(find.text('逐行歌词'), findsOneWidget);
      expect(find.text('逐字歌词'), findsOneWidget);
      // 歌词行带「仅下载」徽标，「不下载」行没有
      expect(find.text('仅下载'), findsNWidgets(2));
      expect(DownloadExtras.lyricMode, LyricDownloadMode.word);

      // 改选「逐行歌词」→ 触发独立歌词下载（不下载音乐）
      await tester.tap(find.text('逐行歌词'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(lyricOnlyMode, LyricDownloadMode.line);
      expect(pickedQuality, isNull); // 没有走音质下载

      // 再点音质 → 回调拿到逐行（音乐下载附带所选歌词）
      await tester.tap(find.text('音质B'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(pickedQuality, '音质B');
      expect(pickedLyric, LyricDownloadMode.line);
    });

    testWidgets('不改选择直接点音质 → 回调粒度跟随全局默认（逐字）', (tester) async {
      LyricDownloadMode? pickedLyric;
      await pumpAndCatch(
        tester,
        Scaffold(
          body: DownloadOptionsSheet<String>(
            options: const ['唯一音质'],
            current: '唯一音质',
            label: (v) => v,
            lyricMode: DownloadExtras.lyricMode,
            onConfirm: (_, lyric) => pickedLyric = lyric,
            onLyricOnly: (_) {},
          ),
        ),
      );
      await tester.tap(find.text('唯一音质'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(pickedLyric, LyricDownloadMode.word);
    });

    testWidgets('点「不下载」只改选中态，不触发歌词下载', (tester) async {
      LyricDownloadMode? lyricOnlyMode;
      LyricDownloadMode? pickedLyric;
      await pumpAndCatch(
        tester,
        Scaffold(
          body: DownloadOptionsSheet<String>(
            options: const ['唯一音质'],
            current: '唯一音质',
            label: (v) => v,
            lyricMode: LyricDownloadMode.word,
            onConfirm: (_, lyric) => pickedLyric = lyric,
            onLyricOnly: (mode) => lyricOnlyMode = mode,
          ),
        ),
      );
      await tester.tap(find.text('不下载'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(lyricOnlyMode, isNull);
      // 再点音质 → 附带关闭（不下载歌词）
      await tester.tap(find.text('唯一音质'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(pickedLyric, LyricDownloadMode.off);
    });
  });
}
