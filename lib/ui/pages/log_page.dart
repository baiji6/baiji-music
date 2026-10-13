import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_logger.dart';
import '../../core/cache_manager.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';

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
        showAppSnack('暂无日志可导出');
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
      showAppSnack('导出失败: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Color _levelColor(String level) {
    switch (level) {
      case AppLog.trace:
        return AppColors.textTertiary.withValues(alpha: 0.6);
      case AppLog.debug:
        return AppColors.textTertiary;
      case AppLog.info:
        return AppColors.accent;
      case AppLog.warn:
        return AppColors.warning;
      case AppLog.error:
        return AppColors.danger;
      case AppLog.fatal:
        return AppColors.accentAlt;
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

    return MiuixScaffold(
      containerColor: Colors.transparent,
      snackbarHost: MiuixSnackbarHost(state: appSnackbarHostState),
      topBar: MiuixTopAppBar(
        title: '日志与调试',
        titleColor: AppColors.skyBlue,
        color: Colors.transparent,
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary, size: 20),
        ),
        actions: [
          MiuixTextButton(
            '清空',
            onPressed: () {
              AppLog.instance.clear();
              showAppSnack('日志已清空（含当天落盘文件）');
              setState(() {});
            },
            textStyle: TextStyle(color: AppColors.danger, fontSize: 13),
          ),
          if (allLogs.isNotEmpty)
            if (_exporting)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                child: MiuixCircularProgressIndicator(size: 16, strokeWidth: 2),
              )
            else
              MiuixTextButton(
                '导出',
                onPressed: _exportLogs,
                textStyle: TextStyle(color: AppColors.accent, fontSize: 13),
              ),
        ],
      ),
      content: (padding) => Column(
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
                  child: MiuixPressable(
                    onPressed: () => setState(() => _filterLevel = level),
                    borderRadius: BorderRadius.circular(16),
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
                  style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
                const Spacer(),
                Text(
                  '当前过滤: ≥ $_filterLevel',
                  style: TextStyle(fontSize: 11, color: _levelColor(_filterLevel)),
                ),
              ],
            ),
          ),
          // 落盘说明：日志按天保存在本地（保留 7 天），重启不丢失
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              children: [
                Icon(Icons.save_rounded,
                    size: 12, color: AppColors.textTertiary.withValues(alpha: 0.7)),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '日志按天保存在本地（保留 7 天），重启不会丢失；'
                    '发生闪退后重新打开此页即可查看崩前记录',
                    style: TextStyle(
                        fontSize: 10,
                        height: 1.4,
                        color: AppColors.textTertiary.withValues(alpha: 0.7)),
                  ),
                ),
              ],
            ),
          ),
          MiuixHorizontalDivider(thickness: 1, color: AppColors.strokeGlass),
          // 日志列表
          Expanded(
            child: logs.isEmpty
                ? Center(
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
