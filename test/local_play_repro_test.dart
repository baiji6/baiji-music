// 本地音乐播放复现：外部 .lrc + FLAC + 播放页歌词渲染。
// 用户日志：播放带同名 .lrc 的本地 FLAC 后 FATAL（null check）。
import 'dart:io';
import 'dart:typed_data';

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
import 'package:baiji_music/ui/widgets/amll_lyrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lyric/flutter_lyric.dart' as amll;
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
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

Uint8List _buildWav(int seconds) {
  final sr = 8000;
  final n = sr * seconds;
  final data = <int>[];
  void w32(int v) =>
      data.addAll([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void w16(int v) => data.addAll([v & 0xFF, (v >> 8) & 0xFF]);
  data.addAll([0x52, 0x49, 0x46, 0x46]);
  w32(36 + n * 2);
  data.addAll([0x57, 0x41, 0x56, 0x45]);
  data.addAll([0x66, 0x6D, 0x74, 0x20]);
  w32(16);
  w16(1);
  w16(1);
  w32(sr);
  w32(sr * 2);
  w16(2);
  w16(16);
  data.addAll([0x64, 0x61, 0x74, 0x61]);
  w32(n * 2);
  for (var i = 0; i < n; i++) {
    w16(0);
  }
  return Uint8List.fromList(data);
}

/// 最小合法 FLAC：fLaC + STREAMINFO(空) + VORBIS_COMMENT(空) + 音频数据。
Uint8List _buildFlac(int seconds) {
  final out = <int>[];
  out.addAll([0x66, 0x4C, 0x61, 0x43]); // fLaC
  final si = List<int>.filled(34, 0);
  out.addAll([0x00, 0x00, 0x00, si.length]); // STREAMINFO, not last
  out.addAll(si);
  // VORBIS_COMMENT: vendor(LE32) + count(LE32)
  final vc = <int>[];
  vc.addAll([0x00, 0x00, 0x00, 0x00]); // vendor len 0
  vc.addAll([0x00, 0x00, 0x00, 0x00]); // 0 comments
  out.addAll([0x80 | 4, 0x00, 0x00, vc.length]); // type 4, last
  out.addAll(vc);
  out.addAll(_buildWav(seconds));
  return Uint8List.fromList(out);
}

Song _localSong(String path) => Song(
      mid: 'local:moonhalo',
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

  test('本地歌词链：同名外挂增强 LRC 必须解析出词级时间轴', () async {
    final dir = Directory.systemTemp.createTempSync('baiji_local_repro');
    final flac = File('${dir.path}/Moon Halo.flac');
    flac.writeAsBytesSync(_buildFlac(30));
    File('${dir.path}/Moon Halo.lrc').writeAsStringSync(
      '[ti:Moon Halo]\n'
      '[ar:茶理理子]\n'
      '[00:01.00]<00:01.00>Moon <00:01.50>Halo <00:02.00>崩\n'
      '[00:03.00]<00:03.00>坏 <00:03.50>3 <00:04.00>《\n'
      '[00:05.00]<00:05.00>薪 <00:05.50>炎 <00:06.00>永 <00:06.50>燃\n',
    );

    final ly = await LyricApi.of(_localSong(flac.path));
    expect(ly.hasWordTiming, isTrue,
        reason: '同名外挂增强 LRC 必须解析出词级时间轴');
    expect(ly.lines.where((l) => l.isWordLevel).length, greaterThan(0));
    dir.deleteSync(recursive: true);
  });

  testWidgets('本地 FLAC + 同名逐字 .lrc：播放页歌词渲染不崩溃', (tester) async {
    final dir = Directory.systemTemp.createTempSync('baiji_local_repro');
    final flac = File('${dir.path}/Moon Halo.flac');
    flac.writeAsBytesSync(_buildFlac(30));
    File('${dir.path}/Moon Halo.lrc').writeAsStringSync(
      '[ti:Moon Halo]\n'
      '[ar:茶理理子]\n'
      '[00:01.00]<00:01.00>Moon <00:01.50>Halo <00:02.00>崩\n'
      '[00:03.00]<00:03.00>坏 <00:03.50>3 <00:04.00>《\n'
      '[00:05.00]<00:05.00>薪 <00:05.50>炎 <00:06.00>永 <00:06.50>燃\n',
    );

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

    // 逐字渲染由 flutter_lyric（AMLL 风格引擎）承担
    expect(find.byType(amll.LyricView), findsOneWidget,
        reason: '逐字 .lrc 必须由 AMLL 引擎渲染');
    expect(find.byType(AmllLyricsView), findsOneWidget,
        reason: '播放页必须挂载 AmllLyricsView');

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
