// v2.2.9-fix2 排查：倍速弹层的滑杆是否真的渲染。
import 'dart:math' as math;

import 'package:baiji_music/player/player_controller.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

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
                home: home,
              ),
              const MiuixPopupHost(),
            ],
          ),
        ),
      ),
    );

void main() {
  testWidgets('MiuixOverlayBottomSheet 里的 MiuixSlider（steps=0）正常渲染', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    // 三种包裹方式并排对比：
    // A. 裸放 Column（v2.2.9 倍速弹层现状）
    // B. 歌词样式表同款：SingleChildScrollView > Column(start)
    // C. SizedBox(width: infinity) 强撑满
    Widget slider() => MiuixSlider(
          value: PlayerController.rateToPos(1.0),
          min: 0.0,
          max: 1.0,
          steps: 0,
          onValueChanged: (v) {},
        );
    await tester.pumpWidget(_wrap(
      Scaffold(
        body: MiuixOverlayBottomSheet(
          show: true,
          title: '倍速播放',
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('1.0x'),
                slider(),
                Wrap(
                  children: const [
                    Padding(padding: EdgeInsets.all(4), child: Text('0.5x')),
                    Padding(padding: EdgeInsets.all(4), child: Text('2.0x')),
                  ],
                ),
                SizedBox(width: double.infinity, child: slider()),
              ],
            ),
          ),
        ),
      ),
    ));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (!tester.binding.hasScheduledFrame) break;
    }

    final sliders = find.byType(MiuixSlider);
    expect(sliders.evaluate().length, 2, reason: '两个滑杆都应存在');
    double widthOf(int i) =>
        tester.renderObject<RenderBox>(sliders.at(i)).size.width;
    final wLoose = widthOf(0);
    final wTight = widthOf(1);
    // ignore: avoid_print
    print('滑杆宽度: 松约束=$wLoose, tight=$wTight');
    expect(tester.takeException(), isNull);
    expect(wTight, greaterThan(100), reason: 'SizedBox(infinity) 包裹后应撑满');
  });

  test('rateToPos(1.0) 不是 NaN', () {
    final p = PlayerController.rateToPos(1.0);
    expect(p.isNaN, isFalse);
    expect(p, inExclusiveRange(0.0, 1.0));
    expect(p, closeTo(math.log(100) / math.log(5000), 1e-9));
  });
}
