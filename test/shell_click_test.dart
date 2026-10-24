// v2.2.4 回归复现：Miuix 根域（MiuixPopupScope + MiuixPopupHost）下
// shell 是否能正常渲染、settle 并响应点击。
//
// 背景：用户真机反馈「页面完全无法操作，根本点不动」+「文字下面黄色双线」。
// 本测试用与 main.dart 完全一致的根域结构泵入 AppShell，验证：
// 1) 树能 settle（不卡死/不无限重建）；
// 2) 底部导航可点击切页；
// 3) 最近播放列表项可点击；
// 4) 迷你播放条可点击进入播放页；
// 5) 文本不继承 MaterialApp 兜底 _errorTextStyle 的黄色双下划线。
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/data/history_store.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/ui/pages/discover_home.dart';
import 'package:baiji_music/ui/pages/library_home.dart';
import 'package:baiji_music/ui/pages/player_page.dart';
import 'package:baiji_music/ui/pages/search_home.dart';
import 'package:baiji_music/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await KvStore.ensureInit();
    HistoryStore.writePlay([_song('后来的我们'), _song('晴天')]);
  });

  /// 与 main.dart 修复后的根域结构保持一致：
  /// MiuixTheme > MiuixPopupScope(establishRoot) >
  /// Directionality > Stack[MaterialApp(builder: Material transparency), PopupHost]
  Future<void> pumpShell(WidgetTester tester) async {
    // 手机尺寸视口：默认 800x600 会把「最近播放」折到屏幕外，点不到。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MiuixTheme(
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
                  home: const AppShell(
                    titles: ['发现', '搜索', '我的'],
                    pages: [DiscoverHome(), SearchHome(), LibraryHome()],
                  ),
                ),
                const MiuixPopupHost(),
              ],
            ),
          ),
        ),
      ),
    );
    // 排空首屏拉取（发现页推荐歌单 / 搜索页热搜榜）失败重试的
    // Future.delayed 定时器：不推假时钟的话，测试结束时会报
    // 「Timer is still pending」（#143 起发现页也会发首屏请求）。
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('根域结构下 shell 能渲染并 settle（不卡死）', (tester) async {
    await pumpShell(tester);
    // 最多泵 60 帧；若始终无法 settle 说明存在无限重建/动画循环
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!tester.binding.hasScheduledFrame) break;
    }
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: 'shell 在 60 帧后仍未 settle，疑似无限重建循环');
    expect(find.text('白姬音乐'), findsOneWidget);
    expect(find.text('发现'), findsWidgets);
  });

  testWidgets('底部导航可点击切页', (tester) async {
    await pumpShell(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(find.text('搜索'), findsWidgets);
    // 搜索页的标志性元素
    expect(find.text('搜索历史') , findsAny);
  });

  testWidgets('最近播放列表项可点击', (tester) async {
    await pumpShell(tester);
    await tester.pumpAndSettle();
    expect(find.text('后来的我们'), findsOneWidget);
    await tester.tap(find.text('后来的我们'));
    await tester.pumpAndSettle();
    // 点击后进入播放（迷你播放条应显示当前歌曲）
    expect(find.text('后来的我们'), findsWidgets);
  });

  testWidgets('迷你播放条可点击进入播放页', (tester) async {
    await pumpShell(tester);
    await tester.pumpAndSettle();
    // 点一首最近播放：playQueue 会同步把曲目广播进迷你播放条
    // （测试环境取流必然失败，但 _currentSong / _songStream 已先行发出）。
    await tester.tap(find.text('后来的我们'));
    await tester.pumpAndSettle();
    // 迷你播放条此时有曲目（本文件其他用例可能已通过单例留下曲目，
    // 不对此做强断言，只验证点击歌名区域能推入完整播放页）。
    final miniTitle = find.descendant(
      of: find.byType(MiniPlayerBar),
      matching: find.byType(Text),
    );
    expect(miniTitle, findsWidgets);
    await tester.tap(miniTitle.first);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsOneWidget);
  });

  testWidgets('正文文本不继承黄色双下划线（兜底 _errorTextStyle 泄漏检测）', (tester) async {
    await pumpShell(tester);
    await tester.pumpAndSettle();
    // 「聆听未来 · 双音源无损曲库」是显式 style 的 Text，若其 effective style
    // 的 decoration 非 none，即说明泄漏了 MaterialApp 兜底样式的黄色双下划线。
    final text = tester.widget<Text>(find.text('聆听未来 · 双音源无损曲库'));
    final style = DefaultTextStyle.of(
            tester.element(find.text('聆听未来 · 双音源无损曲库')))
        .style
        .merge(text.style);
    expect(style.decoration, TextDecoration.none,
        reason: 'decoration=${style.decoration} decorationStyle=${style.decorationStyle} decorationColor=${style.decorationColor}');
    expect(style.decorationColor, isNot(const Color(0xFFFFFF00)));
  });
}
