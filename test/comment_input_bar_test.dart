// 评论输入框两项回归（v2.3.0-fix3 用户反馈）：
// 1) 占位标签「写评论」压在已输入文字上（flutter_miuix 1.3.0 重建缺陷）；
// 2) 软键盘弹出后输入栏不上抬（MiuixScaffold 不吃 viewInsets）。
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/ui/widgets/app_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MiuixTheme(
      data: AppTheme.miuix(),
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  testWidgets('占位标签在输入文字后立即消失（不与输入内容重合）',
      (tester) async {
    final c = TextEditingController();
    addTearDown(c.dispose);
    await tester.pumpWidget(_wrap(SizedBox(
      width: 320,
      child: AppTextField(
        controller: c,
        label: '写评论',
        useLabelAsPlaceholder: true,
      ),
    )));
    await tester.pump();

    // 空文本：占位符必须可见
    expect(find.text('写评论'), findsOneWidget);

    c.text = '你好';
    await tester.pump();

    // 有文本：占位符必须消失，否则会与输入文字叠在一起
    expect(find.text('写评论'), findsNothing,
        reason: '有输入后占位标签必须隐藏（否则与文字重合）');
    expect(find.text('你好'), findsWidgets);

    c.text = '';
    await tester.pump();
    expect(find.text('写评论'), findsOneWidget,
        reason: '清空后占位符应回来');
  });

  testWidgets('键盘弹出时输入栏底部按 viewInsets 上抬', (tester) async {
    const ime = 320.0;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: ime);
    addTearDown(tester.view.reset);

    final c = TextEditingController();
    addTearDown(c.dispose);
    await tester.pumpWidget(_wrap(SizedBox(
      width: 400,
      height: 800,
      child: Column(
        children: [
          Expanded(child: Container(color: Colors.transparent)),
          // 复刻评论页输入栏的键盘内边距写法
          _ImeAwareBar(controller: c),
        ],
      ),
    )));
    await tester.pumpAndSettle();

    final bar = find.byKey(const Key('ime-bar'));
    expect(bar, findsOneWidget);
    // 输入栏底部应停在键盘上方（屏幕高 800 - 键盘 320 = 480）
    final bottom = tester.getBottomRight(bar).dy;
    expect(bottom, closeTo(480, 2.0),
        reason: '输入栏必须被键盘顶到 480 处，实际 $bottom');
  });
}

/// 复刻评论页 `_buildInputBar` 的键盘内边距结构（生产代码同款写法）。
class _ImeAwareBar extends StatelessWidget {
  const _ImeAwareBar({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final ime = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: Duration.zero,
      padding: EdgeInsets.only(bottom: ime),
      child: Container(
        key: const Key('ime-bar'),
        height: 56,
        color: Colors.blue,
        child: AppTextField(
          controller: controller,
          label: '写评论',
          useLabelAsPlaceholder: true,
        ),
      ),
    );
  }
}
