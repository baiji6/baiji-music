import 'package:flutter/material.dart';

import '../../core/app_logger.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// 日志与调试页：展示应用运行日志。
class LogPage extends StatelessWidget {
  const LogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final logs = AppLog.instance.dump();
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('日志与调试'),
        actions: [
          TextButton(
            onPressed: () {
              AppLog.instance.clear();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('日志已清空')),
              );
              // 触发重建
              (context as Element).markNeedsBuild();
            },
            child: const Text('清空', style: TextStyle(color: AppColors.danger, fontSize: 13)),
          ),
        ],
      ),
      body: logs.isEmpty
          ? const Center(
              child: Text(
                '暂无日志',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              reverse: true,
              itemCount: logs.length,
              itemBuilder: (ctx, i) {
                final line = logs[logs.length - 1 - i];
                final color = line.contains('ERROR') || line.contains('FATAL')
                    ? AppColors.danger
                    : line.contains('WARN')
                        ? AppColors.warning
                        : line.contains('DEBUG')
                            ? AppColors.textTertiary
                            : AppColors.textSecondary;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: SelectableText(
                    line,
                    style: TextStyle(fontSize: 11, color: color, fontFamily: 'monospace'),
                  ),
                );
              },
            ),
    );
  }
}
