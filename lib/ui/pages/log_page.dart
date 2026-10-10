import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_logger.dart';
import '../../core/cache_manager.dart';
import '../../theme/app_theme.dart';

/// 日志与调试页：展示应用运行日志，支持六级分级过滤与导出。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  bool _exporting = false;
  String _filterLevel = AppLog.info;
  final List<String> _levels = [AppLog.trace, AppLog.debug, AppLog.info, AppLog.warn, AppLog.error, AppLog.fatal];

  Future<void> _exportLogs() async {
    setState(() => _exporting = true);
    try {
      final logs = AppLog.instance.dump();
      if (logs.isEmpty) {
        _showSnack('暂无日志可导出');
        return;
      }
      final text = logs.join('\n');
      // 放进可管理的缓存目录，这样「设置 → 清理缓存」能把导出残留一并清掉
      final file = await CacheManager.cacheFile('baiji_music_logs.txt');
      await file.writeAsString(text, encoding: utf8);
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path)],
        text: '白姬音乐运行日志',
        subject: 'baiji_music_logs.txt',
      );
    } catch (e) {
      // 这里 await 过了，context 可能已经失效——和 finally 一样要先判mounted
      if (!mounted) return;
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

  Color _levelColor(String level) {
    switch (level) {
      case AppLog.trace:
        return AppColors.textTertiary.withValues(alpha: 0.6);
      case AppLog.debug:
        return AppColors.textTertiary;
      case AppLog.info:
        return AppColors.cyan;
      case AppLog.warn:
        return AppColors.warning;
      case AppLog.error:
        return AppColors.danger;
      case AppLog.fatal:
        return AppColors.magenta;
      default:
        return AppColors.textSecondary;
    }
  }

  /// 从日志行文本中提取级别，格式: "MM-DD HH:MM:SS.mmm LEVEL/tag ..."
  String _extractLevel(String line) {
    final match = RegExp(r'\d{2}:\d{2}:\d{2}\.\d{3}\s+([A-Z]+)/').firstMatch(line);
    return match?.group(1) ?? AppLog.info;
  }

  int _levelIndex(String level) => _levels.indexOf(level);

  @override
  Widget build(BuildContext context) {
    final allLogs = AppLog.instance.dump();
    final filterIdx = _levelIndex(_filterLevel);
    final logs = allLogs.where((e) {
      final level = _extractLevel(e);
      return _levelIndex(level) >= filterIdx;
    }).toList();

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
          if (allLogs.isNotEmpty)
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
      body: Column(
        children: [
          // 级别过滤栏
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _levels.length,
              itemBuilder: (ctx, i) {
                final level = _levels[i];
                final active = level == _filterLevel;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => _filterLevel = level),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: active ? _levelColor(level).withValues(alpha: 0.2) : AppColors.surfaceGlass,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: active ? _levelColor(level) : AppColors.strokeGlass,
                        ),
                      ),
                      child: Text(
                        level,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                          color: active ? _levelColor(level) : AppColors.textTertiary,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // 统计条
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text(
                  '显示 ${logs.length} / 共 ${allLogs.length} 条',
                  style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
                const Spacer(),
                Text(
                  '当前过滤: ≥ $_filterLevel',
                  style: TextStyle(fontSize: 11, color: _levelColor(_filterLevel)),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.strokeGlass),
          // 日志列表
          Expanded(
            child: logs.isEmpty
                ? const Center(
                    child: Text(
                      '该级别暂无日志',
                      style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    reverse: true,
                    itemCount: logs.length,
                    itemBuilder: (ctx, i) {
                      final entry = logs[logs.length - 1 - i];
                      final color = _levelColor(_extractLevel(entry));
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: SelectableText(
                          entry,
                          style: TextStyle(fontSize: 11, color: color, fontFamily: 'monospace', height: 1.4),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
