// 本地音乐页的 UI 契约测试：
// 1) 空库时给出引导（而不是空白屏）；
// 2) 有歌时列表渲染出标题/艺术家/时长/格式；
// 3) 目录管理面板可展开收起。
//
// 这里不触碰真实扫描与播放：Isolate 与 media_kit 都不适合在组件测试里跑，
// 那些逻辑分别由 local_music_test 与 audio_reader_test 覆盖。
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/data/local_music_store.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/ui/pages/local_music_page.dart';
import 'package:baiji_music/ui/widgets/cover_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song({
  required String name,
  String singer = '',
  int durationMs = 0,
  String format = 'mp3',
}) =>
    Song(
      mid: '/music/$name.mp3',
      songId: name.hashCode,
      name: name,
      singer: singer,
      album: '',
      albumMid: '',
      duration: durationMs,
      cover: '',
      source: Source.local,
      localPath: '/music/$name.mp3',
      localSize: 1024,
      localMtime: 1700000000000,
      format: format,
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await KvStore.ensureInit();
    LocalCoverCache.clear();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const LocalMusicPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('本地音乐页能正常渲染', (tester) async {
    await pump(tester);
    expect(find.text('本地音乐'), findsWidgets);
  });

  testWidgets('空库时显示引导而不是白屏', (tester) async {
    // 标记为已扫描过，避免 initState 触发真实扫描（需要 Isolate）
    await LocalMusicStore.markScanned();

    await pump(tester);

    expect(find.text('还没有本地音乐'), findsOneWidget);
    expect(find.byIcon(Icons.library_music_outlined), findsWidgets);
    expect(find.text('选择文件夹'), findsOneWidget);
  });

  testWidgets('有歌时列表渲染标题、艺术家、时长与格式', (tester) async {
    await LocalMusicStore.writeSongs(<Song>[
      _song(name: '富士山下', singer: '陈奕迅', durationMs: 254000, format: 'flac'),
      _song(name: '晴天', singer: '周杰伦', durationMs: 269000, format: 'mp3'),
    ]);
    await LocalMusicStore.markScanned();

    await pump(tester);

    expect(find.text('富士山下'), findsOneWidget);
    expect(find.text('陈奕迅'), findsOneWidget);
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('周杰伦'), findsOneWidget);

    // 时长：254 秒 → 04:14；269 秒 → 04:29
    expect(find.text('04:14'), findsOneWidget);
    expect(find.text('04:29'), findsOneWidget);

    // 格式标签
    expect(find.text('FLAC'), findsOneWidget);
    expect(find.text('MP3'), findsOneWidget);
  });

  testWidgets('未知艺术家显示为「未知艺术家」占位', (tester) async {
    await LocalMusicStore.writeSongs(<Song>[_song(name: '无名师', durationMs: 60000)]);
    await LocalMusicStore.markScanned();

    await pump(tester);
    expect(find.text('未知艺术家'), findsOneWidget);
  });

  testWidgets('时长为 0 时显示 --:--', (tester) async {
    await LocalMusicStore.writeSongs(<Song>[_song(name: '无时长', singer: '某人')]);
    await LocalMusicStore.markScanned();

    await pump(tester);
    expect(find.text('--:--'), findsOneWidget);
  });

  testWidgets('目录管理面板可展开与收起', (tester) async {
    await LocalMusicStore.markScanned();
    await pump(tester);

    // 初始不显示
    expect(find.text('扫描目录'), findsNothing);

    // 从溢出菜单里打开
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示目录管理'));
    await tester.pumpAndSettle();
    expect(find.text('扫描目录'), findsOneWidget);

    // 再点一次收起
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('隐藏目录管理'));
    await tester.pumpAndSettle();
    expect(find.text('扫描目录'), findsNothing);
  });

  testWidgets('自定义目录会显示在管理面板里', (tester) async {
    await LocalMusicStore.addCustomDir('/my/music');
    await LocalMusicStore.markScanned();
    await pump(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示目录管理'));
    await tester.pumpAndSettle();

    expect(find.text('/my/music'), findsOneWidget);
  });

  testWidgets('列表项能点击（不抛异常）', (tester) async {
    await LocalMusicStore.writeSongs(<Song>[
      _song(name: '可点击', singer: '测试', durationMs: 60000),
    ]);
    await LocalMusicStore.markScanned();

    await pump(tester);
    await tester.tap(find.text('可点击'));
    await tester.pumpAndSettle();
    // 走到这里说明点击链路没抛异常
  });

  testWidgets('刷新按钮存在且可点', (tester) async {
    await LocalMusicStore.markScanned();
    await pump(tester);

    expect(find.byIcon(Icons.refresh_rounded), findsWidgets);
  });
}
