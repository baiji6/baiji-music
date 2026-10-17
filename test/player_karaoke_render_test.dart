// 播放页逐字歌词渲染回归：当前行走 KaraokeFill 分支（ShaderMask 染色）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/core/theme_controller.dart';
import 'package:baiji_music/core/ui_settings.dart';
import 'package:baiji_music/crypto/qq_crypto.dart';
import 'package:baiji_music/network/lyric_api.dart';
import 'package:baiji_music/lyrics/lyric_parser.dart';
import 'package:baiji_music/lyrics/lyric_serializer.dart';
import 'package:baiji_music/metadata/audio_tagger.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/player/player_controller.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/ui/pages/player_page.dart';
import 'package:flutter/material.dart';
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

/// 30 秒静音 wav（null sink 下解码即播，position 可 seek 驱动）。
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

  testWidgets('播放页逐字歌词渲染诊断', (tester) async {
    // 1) 真实 QRC → 逐字 LRC → 内嵌进 wav 容器换成 mp3 名（tagger 按扩展名分派）
    final full =
        jsonDecode(File('test/fixtures/lyrics/qq_qrc_186016.json').readAsStringSync());
    final dec = qrcDecrypt((full['lyric'] as String).trim());
    final lyrics = LyricParser.parse(dec);
    final wordLrc = LyricSerializer.toLrc(lyrics, wordLevel: true);

    final dir = Directory.systemTemp.createTempSync('baiji_player_diag');
    final mp3 = File('${dir.path}/其实.mp3');
    // 用 ID3v2.3 空标签 + 伪音频数据，AudioTagger 会重写标签
    final head = <int>[
      0x49, 0x44, 0x33, 0x03, 0x00, 0x00, // ID3 v2.3
      0x00, 0x00, 0x00, 0x0A, // size 10（syncsafe）
    ];
    mp3.writeAsBytesSync([
      ...head,
      ...List<int>.filled(10, 0),
      ..._buildWav(30),
    ]);

    // 真实文件 I/O + media_kit 必须在 runAsync 里跑：testWidgets 的
    // fakeAsync 不处理真实 I/O 完成事件，直接 await 会永久挂起。
    await tester.runAsync(() async {
      final embed = await AudioTagger.embed(
        file: mp3,
        lyrics: wordLrc,
        cover: null,
        title: '其实',
        artist: '薛之谦',
        album: '意外',
      );
      expect(embed.error, isNull,
          reason: '逐字 LRC 内嵌伪 MP3 容器必须成功');
    });

    final song = Song(
      mid: '003ouHMP12glVD',
      songId: 104775877,
      name: '其实',
      singer: '薛之谦',
      album: '意外',
      albumMid: '000MkM1i0bwxdi',
      duration: 253000,
      cover: '',
      source: Source.local,
      localPath: mp3.path,
    );

    await tester.runAsync(() async {
      await PlayerController.instance.play(song, mp3.path);
      // seek 到第 5 行「不需要借口」(18880ms) 中间
      await PlayerController.instance.seek(const Duration(milliseconds: 19500));
      await Future.delayed(const Duration(milliseconds: 200));
    });

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    // 先直接验证歌词读取：内嵌逐字 LRC 必须被解析回 word-level
    await tester.runAsync(() async {
      final ly = await LyricApi.of(song);
      var wl = 0;
      for (final l in ly.lines) {
        if (l.isWordLevel) wl++;
      }
      expect(ly.hasWordTiming, isTrue,
          reason: '内嵌逐字 LRC 必须解析出词级时间轴');
      expect(wl, greaterThan(0),
          reason: '至少应有若干行是词级歌词');
    });

    await tester.pumpWidget(_wrap(const PlayerPage()));
    await tester.pump();
    // 歌词是真实文件 I/O（AudioReader 走 isolate），必须在 runAsync 里等完成
    await tester.runAsync(() async {
      await Future.delayed(const Duration(milliseconds: 800));
    });
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 左滑进入歌词页（pumpAndSettle 会被常驻 Ticker 卡死，用定时 pump）
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

    // 当前行（active）应该走逐字渲染分支：fix5 起为 CustomPaint +
    // 每视觉行独立 dstIn 遮罩（AMLL 同款，换行安全），不再是整行 ShaderMask
    final paints = find.byType(CustomPaint);
    expect(paints.evaluate(), isNotEmpty,
        reason: '逐字渲染必须走 CustomPaint（KaraokeFill 遮罩）分支');
    // CustomPaint 的 painter 应该有真实的排版缓存（说明量字成功）
    final hasKaraoke = paints.evaluate().any((el) {
      final w = el.widget as CustomPaint;
      return w.painter != null && w.painter.runtimeType.toString() == 'KaraokePainter';
    });
    expect(hasKaraoke, isTrue,
        reason: '词级行必须由 KaraokePainter 绘制（逐字染色）');
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
