/// 本地升频页与工具箱入口的 build 冒烟（v2.5.2）。
library;

import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/ui/pages/toolbox_page.dart';
import 'package:baiji_music/ui/pages/viper_upscale_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePath extends PathProviderPlatform {
  _FakePath(this.root);
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

void main() {
  setUpAll(() {
    PathProviderPlatform.instance = _FakePath('/tmp');
  });

  testWidgets('本地升频页 build 冒烟', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(const ViperUpscalePage()));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    expect(find.textContaining('本地升频'), findsWidgets);
  });

  testWidgets('工具箱含新入口 build 冒烟', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(const ToolboxPage()));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    expect(find.textContaining('本地升频'), findsWidgets);
  });

  testWidgets('升频页显示「保存位置」入口', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(const ViperUpscalePage()));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    // 自定义保存位置入口存在。
    expect(find.text('保存位置'), findsOneWidget);
    // 默认未自定义时不应出现「恢复默认」入口。
    expect(find.text('恢复默认保存位置'), findsNothing);
  });
}
