// 协议同意状态的持久化契约：
// - 首次启动（无记录）必须弹窗，accepted 为 false；
// - 同意后 accepted 为 true，重启（重新读同一存储）仍是 true；
// - 修订号提升时老记录失效，用户需要重新确认。
import 'package:baiji_music/core/agreement_store.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/ui/widgets/agreement_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 重置单例，保证每个用例从干净存储开始
    await KvStore.ensureInit();
    await AgreementStore.reset();
  });

  test('首次启动：未同意，需要弹窗', () {
    expect(AgreementStore.accepted, isFalse);
  });

  test('同意后标记持久化，再次读取仍为已同意', () async {
    await AgreementStore.accept();
    expect(AgreementStore.accepted, isTrue);

    // 模拟重启：读同一个底层存储
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getInt('agreement:accepted_revision');
    expect(raw, AgreementStore.revision,
        reason: '应把当前修订号写入本地存储');
  });

  test('重置后回到未同意状态（调试入口用）', () async {
    await AgreementStore.accept();
    expect(AgreementStore.accepted, isTrue);
    await AgreementStore.reset();
    expect(AgreementStore.accepted, isFalse);
  });

  test('修订号大于已存记录时，旧同意失效', () async {
    // 构造一个"更旧版本"的同意记录
    await KvStore.instance
        .setInt('agreement:accepted_revision', AgreementStore.revision - 1);
    expect(AgreementStore.accepted, isFalse,
        reason: '老版本同意不应覆盖新修订');

    await KvStore.instance
        .setInt('agreement:accepted_revision', AgreementStore.revision + 1);
    expect(AgreementStore.accepted, isTrue,
        reason: '更高版本号视为已同意，可用于未来兼容');
  });

  testWidgets('弹窗点同意后，标记自动落盘', (tester) async {
    expect(AgreementStore.accepted, isFalse);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showAgreementDialog(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 逐份勾选
    await tester.tap(find.text('我已完整阅读并同意《免责声明》'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用协议'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已完整阅读并同意《使用协议》'));
    await tester.pumpAndSettle();

    // 点「同意并继续」
    await tester.tap(find.text('同意并继续'));
    await tester.pumpAndSettle();

    expect(find.text('同意并继续'), findsNothing, reason: '弹窗应已关闭');
    expect(AgreementStore.accepted, isTrue, reason: '同意状态必须落盘');
  });

  testWidgets('弹窗点「不同意并退出」会先二次确认', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showAgreementDialog(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('不同意并退出'));
    await tester.pumpAndSettle();

    expect(find.text('退出确认'), findsOneWidget);
    // 点「返回」应当留在弹窗里，不退出
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('同意并继续'), findsOneWidget);
    expect(AgreementStore.accepted, isFalse);
  });
}
