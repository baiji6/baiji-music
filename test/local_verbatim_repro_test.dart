// fix4：本地音乐 FATAL 崩溃复现（用户日志：播放本地 FLAC 后空指针）。
// 覆盖 Lyrico 写入音频标签的 VERBATIM 逐字格式 + 歌词页全交互。
import 'dart:io';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/core/theme_controller.dart';
import 'package:baiji_music/core/ui_settings.dart';
import 'package:baiji_music/local/local_scanner.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/lyric_api.dart';
import 'package:baiji_music/player/player_controller.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/ui/pages/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/audio_samples.dart';

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

Song _localSong(String path, {String mid = 'local:moonhalo'}) => Song(
      mid: mid,
      songId: 0,
      name: 'Moon Halo',
      singer: '茶理理子',
      album: '',
      albumMid: '',
      duration: 30000,
      cover: '',
      source: Source.local,
      localPath: path,
    );

/// Lyrico 写入 FLAC 的 VERBATIM 逐字歌词（实测格式）。
const _verbatimLrc = '[ti:Moon Halo]\n'
    '[ar:茶理理子]\n'
    '[00:01.00]Moon[00:01.50]Halo[00:02.00]崩[00:02.50]坏[00:03.00]\n'
    '[00:04.00]3[00:04.50]《[00:05.00]薪[00:05.50]炎[00:06.00]永[00:06.50]燃[00:07.00]\n'
    '[00:08.00]on[00:08.50]this[00:09.00]planet[00:09.50]were[00:10.00]oceans[00:10.50]once[00:11.00]\n'
    '[00:12.00]Somewhere[00:13.00]shrouded[00:14.00]by[00:15.00]the[00:16.00]night[00:17.00]\n';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PathProviderPlatform.instance = FakePathProvider('/tmp');
    await KvStore.ensureInit();
    await LyricSettings.instance.load();
    await ThemeController.instance.load();
    await UiSettings.instance.load();
    await AppLog.instance.initFileSink();
    MediaKit.ensureInitialized();
  });

  test('VERBATIM 内嵌歌词链：FLAC 内嵌逐字歌词必须解析出词级时间轴', () async {
    final dir = Directory.systemTemp.createTempSync('baiji_verbatim');
    final flac = File('${dir.path}/Moon Halo.flac');
    flac.writeAsBytesSync(buildFlac(lyric: _verbatimLrc, withComment: true));

    final ly = await LyricApi.of(_localSong(flac.path));
    expect(ly.hasWordTiming, isTrue,
        reason: 'Lyrico 写入的 VERBATIM 格式必须解析出词级时间轴');
    expect(ly.lines.where((l) => l.isWordLevel).length, greaterThanOrEqualTo(4));
    // 第一行必须是 "MoonHalo崩坏" 而不是拆成 5 个单字行
    expect(ly.lines.first.text, 'MoonHalo崩坏');
    dir.deleteSync(recursive: true);
  });

  testWidgets('本地 FLAC + VERBATIM 内嵌歌词：播放页渲染 + 全交互不崩溃',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('baiji_verbatim');
    final flac = File('${dir.path}/Moon Halo.flac');
    flac.writeAsBytesSync(buildFlac(lyric: _verbatimLrc, withComment: true));

    final song = _localSong(flac.path);
    await tester.runAsync(() async {
      await PlayerController.instance.play(song, LocalScanner.playUri(song));
      await PlayerController.instance.seek(const Duration(milliseconds: 1500));
      await Future.delayed(const Duration(milliseconds: 200));
    });

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const PlayerPage()));
    await tester.pump();
    await tester.runAsync(() async {
      await Future.delayed(const Duration(milliseconds: 600));
    });
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 左滑进入歌词页
    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() async {
      await Future.delayed(const Duration(milliseconds: 300));
    });
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 逐字行必须走 KaraokePainter（每视觉行独立遮罩，AMLL 语义，CustomPaint）
    final karaokePaints = find.byType(CustomPaint).evaluate().where((el) {
      final w = el.widget as CustomPaint;
      return w.painter != null &&
          w.painter.runtimeType.toString() == 'KaraokePainter';
    }).toList();
    expect(karaokePaints, isNotEmpty,
        reason: 'VERBATIM 内嵌歌词必须走卡拉 OK 染色渲染');

    // 拖动歌词列表（触发 _onUserScroll / 自动回定位）
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 点击某一行跳转
    await tester.tap(find.byType(MiuixPressable).first);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 切到无歌词的歌（FutureBuilder → 暂无歌词 → _LyricView 卸载）
    final plain = File('${dir.path}/plain.flac');
    plain.writeAsBytesSync(buildFlac());
    await tester.runAsync(() async {
      await PlayerController.instance.play(
          _localSong(plain.path, mid: 'local:plain'),
          LocalScanner.playUri(_localSong(plain.path, mid: 'local:plain')));
      await Future.delayed(const Duration(milliseconds: 400));
    });
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 再切回有歌词的歌
    await tester.runAsync(() async {
      await PlayerController.instance.play(song, LocalScanner.playUri(song));
      await Future.delayed(const Duration(milliseconds: 400));
    });
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
