import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_logger.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// 日志与调试页：展示应用运行日志，支持导出。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  bool _exporting = false;

  Future<void> _exportLogs() async {
    setState(() => _exporting = true);
    try {
      final logs = AppLog.instance.dump();
      if (logs.isEmpty) {
        _showSnack('暂无日志可导出');
        return;
      }
      final text = logs.join('\n');
      // 写入临时文件
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/baiji_music_logs.txt');
      await file.writeAsString(text, encoding: utf8);
      // 分享
      await Share.shareXFiles(
        [XFile(file.path)],
        text: '白姬音乐运行日志',
        subject: 'baiji_music_logs.txt',
      );
    } catch (e) {
      _showSnack('导出失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: isError ? AppColors.danger : AppColors.cyan,
        duration: const Duration(seconds: 2),
      ),
    );
  }

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
              _showSnack('日志已清空');
              setState(() {});
            },
            child: const Text('清空', style: TextStyle(color: AppColors.danger, fontSize: 13)),
          ),
          if (logs.isNotEmpty)
            TextButton(
              onPressed: _exporting ? null : _exportLogs,
              child: _exporting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.cyan),
                    )
                  : const Text('导出', style: TextStyle(color: AppColors.cyan, fontSize: 13)),
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
