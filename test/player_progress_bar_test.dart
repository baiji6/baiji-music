// 播放页进度条回归（v2.3.0-fix3 用户反馈「进度条不见了」）。
//
// 根因：MiuixSlider 内部是 `LayoutBuilder + SizedBox(height) + CustomPaint`，
// CustomPaint 无子节点时按内容尺寸（0 宽）测量；在 Column 的宽松横向约束下
// 会塌缩成轨道高度的一小截，视觉上等于进度条消失。
//
// v2.3.0-fix5 起进度条换成自绘的 [ThinProgressBar]（QQ 音乐式细轨+竖条
// 游标，对齐参考视频2），塌缩陷阱随之消失，但「必须撑满剩余宽度」这条
// 不变量仍然要锁死：细轨只有 3px，宽度一塌缩就真的看不见了。
// 这里直接测生产组件 [PlayerProgressSection]，并保留一个 MiuixSlider
// 「不撑满就塌缩」的对照用例，记录这个约束陷阱的来历。
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
  const padding = 16.0 * 2; // PlayerProgressSection 的左右内边距
  const gap = 10.0 * 2; // 时间与轨道之间的间距

  testWidgets('细进度条撑满「去掉边距与两端时间」后的剩余宽度', (tester) async {
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

    final bar = find.byType(ThinProgressBar);
    expect(bar, findsOneWidget);
    // 两端时间（00:00）也要真实占位，扣掉才是轨道的应得宽度
    final timeWidth = tester.getSize(find.text('00:00').first).width;
    final expected = screen - padding - timeWidth * 2 - gap;
    expect(tester.getSize(bar).width, closeTo(expected, 1.0),
        reason: '细轨必须撑满剩余宽度（实际 ${tester.getSize(bar).width}，'
            '应得 $expected）');
  });

  testWidgets('点击进度条回调 seek（按比例映射）', (tester) async {
    tester.view.physicalSize = const Size(screen, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Duration? sought;
    await tester.pumpWidget(_wrap(SizedBox(
      width: screen,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlayerProgressSection(onSeek: (d) async => sought = d),
        ],
      ),
    )));
    await tester.pump();

    final barSize = tester.getSize(find.byType(ThinProgressBar));
    await tester.tapAt(tester.getTopLeft(find.byType(ThinProgressBar)) +
        Offset(barSize.width / 2, 8));
    await tester.pump();
    expect(sought, isNotNull);
  });

  testWidgets('对照：MiuixSlider 不撑满宽度时会塌缩（记录约束陷阱）',
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
