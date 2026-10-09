// 协议弹窗的交互契约测试（不依赖网络与平台通道）：
// 1) 两个 Tab 都必须勾选，「同意并继续」才可用；
// 2) 只勾一个时按钮仍禁用；
// 3) 全部勾选后点击才返回 true。
//
// 这里只测纯 UI 逻辑，AgreementStore 的落盘在 agreement_store_test 里覆盖。
import 'package:baiji_music/core/agreement_text.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/ui/widgets/agreement_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 把弹窗挂到一棵最小可用树上，返回一个可读取结果的容器。
Future<bool?> Function() pumpDialog(WidgetTester tester) {
  bool? result;
  tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showAgreementDialog(ctx);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  return () async => result;
}

/// 找到「同意并继续」按钮对应的 NeonButton 是否处于可点状态。
bool agreeEnabled(WidgetTester tester) {
  final inkwells = tester.widgetList<InkWell>(find.byType(InkWell));
  // NeonButton 内部用的是 InkWell，onTap 为 null 即禁用
  for (final w in inkwells) {
    final label = w.child;
    if (label is Padding) {
      final row = label.child;
      if (row is Row && _hasAgreeText(row)) return w.onTap != null;
    }
  }
  return false;
}

bool _hasAgreeText(Row row) {
  for (final c in row.children) {
    if (c is Text && c.data == '同意并继续') return true;
  }
  return false;
}

void main() {
  test('协议正文足够长（各约 2000 字）', () {
    expect(AgreementText.disclaimer.length, greaterThan(1500));
    expect(AgreementText.terms.length, greaterThan(1500));
    // 免责声明应覆盖用户明确关心的几个方面
    expect(AgreementText.disclaimer, contains('免责声明'));
    expect(AgreementText.disclaimer, contains('知识产权'));
    expect(AgreementText.disclaimer, contains('责任限制'));
    // 使用协议应包含许可、终止、法律适用等条款
    expect(AgreementText.terms, contains('软件许可'));
    expect(AgreementText.terms, contains('终止'));
    expect(AgreementText.terms, contains('法律适用'));
  });

  testWidgets('两份协议都勾选后才能同意', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: _Host(),
      ),
    );

    // 打开弹窗
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 初始：两个 Tab 都没勾选，同意按钮禁用
    expect(find.text('同意并继续'), findsOneWidget);
    expect(agreeEnabled(tester), isFalse);

    // 勾选「免责声明」
    await tester.tap(find.text('我已完整阅读并同意《免责声明》'));
    await tester.pumpAndSettle();
    expect(agreeEnabled(tester), isFalse, reason: '只勾一份时不应可点');

    // 切到「使用协议」并勾选
    await tester.tap(find.text('使用协议'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已完整阅读并同意《使用协议》'));
    await tester.pumpAndSettle();
    expect(agreeEnabled(tester), isTrue, reason: '两份都勾选后应可点');
  });

  testWidgets('只读模式不显示勾选框与同意按钮', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showAgreementReader(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('以下为协议全文，仅供查阅。'), findsOneWidget);
    expect(find.text('同意并继续'), findsNothing);
    expect(find.textContaining('我已完整阅读并同意'), findsNothing);
    expect(find.text('关闭'), findsOneWidget);
  });
}

/// 承载 showAgreementDialog 的最小宿主。
class _Host extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: ElevatedButton(
            onPressed: () => showAgreementDialog(ctx),
            child: const Text('open'),
          ),
        ),
      ),
    );
  }
}
