// 播放页进度条回归（v2.3.0-fix3 用户反馈「进度条不见了」）。
//
// 根因：MiuixSlider 内部是 `LayoutBuilder + SizedBox(height) + CustomPaint`，
// CustomPaint 无子节点时按内容尺寸（0 宽）测量；在 Column 的宽松横向约束下
// 会塌缩成轨道高度的一小截，视觉上等于进度条消失。修法是显式撑满宽度。
//
// 这里直接测生产组件 [PlayerProgressSection]，并保留一个「不撑满就塌缩」的
// 对照用例，锁死这个约束陷阱。
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/ui/pages/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MiuixTheme(
      data: AppTheme.miuix(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: child),
      ),
    );

void main() {
  const screen = 390.0;
  const padding = 22.0 * 2; // _ProgressSection 的左右内边距
  const expected = screen - padding;

  testWidgets('进度条在 Column 松约束下仍撑满可用宽度', (tester) async {
    tester.view.physicalSize = const Size(screen, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(SizedBox(
      width: screen,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlayerProgressSection(onSeek: (_) async {}),
        ],
      ),
    )));
    await tester.pump();

    final slider = find.byType(MiuixSlider);
    expect(slider, findsOneWidget);
    expect(tester.getSize(slider).width, closeTo(expected, 1.0),
        reason: '进度条必须撑满父级可用宽度（实际 ${tester.getSize(slider).width}）');
  });

  testWidgets('对照：不撑满宽度时滑杆会塌缩（说明必须显式给宽）',
      (tester) async {
    tester.view.physicalSize = const Size(screen, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(SizedBox(
      width: screen,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiuixSlider(value: 0.3, max: 1.0, onValueChanged: (_) {}),
        ],
      ),
    )));
    await tester.pump();

    final size = tester.getSize(find.byType(MiuixSlider));
    expect(size.width, lessThan(60),
        reason: '未撑满时应塌缩成轨道高度的小段——这正是线上「进度条不见了」的形态');
  });
}
