import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_logger.dart';
import '../../core/cache_manager.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';

/// 日志与调试页：展示应用运行日志，支持六级分级过滤与导出。
///
/// v2.2.7 重新设计：每条日志一张「条目卡」（级别色条 + 时间 + 徽章 + tag +
/// 消息），长 stack dump 默认折叠，错误不再刷屏；视觉与设置页统一。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  bool _exporting = false;
  String _filterLevel = AppLog.info;
  final List<String> _levels = [AppLog.trace, AppLog.debug, AppLog.info, AppLog.warn, AppLog.error, AppLog.fatal];

  /// 单条日志超过这个长度就把 stack dump 折叠起来（release 下 VM dump 极长）。
  static const int _collapseAt = 140;

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

  /// 从日志行提取时间部分 "MM-DD HH:MM:SS.mmm"（截到秒，卡片上好读）。
  String _extractTime(String line) {
    final match = RegExp(r'(\d{2}-\d{2} \d{2}:\d{2}:\d{2})').firstMatch(line);
    return match?.group(1) ?? '';
  }

  /// 从日志行提取 tag（LEVEL/ 之后、空格之前）。
  String _extractTag(String line) {
    final match = RegExp(r'\d{2}:\d{2}:\d{2}\.\d{3}\s+[A-Z]+/(\S+)').firstMatch(line);
    return match?.group(1) ?? '';
  }

  /// 消息正文（去掉时间戳与 LEVEL/tag 前缀）。
  String _extractMessage(String line) {
    final match = RegExp(r'^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\s+[A-Z]+/\S+\s*').firstMatch(line);
    return match == null ? line : line.substring(match.end);
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
        title: '运行日志',
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
          // 日志列表（条目卡）
          Expanded(
            child: logs.isEmpty
                ? Center(
                    child: Text(
                      '该级别暂无日志',
                      style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    reverse: true,
                    itemCount: logs.length,
                    itemBuilder: (ctx, i) {
                      final entry = logs[logs.length - 1 - i];
                      return _LogEntryCard(
                        entry: entry,
                        level: _extractLevel(entry),
                        time: _extractTime(entry),
                        tag: _extractTag(entry),
                        message: _extractMessage(entry),
                        color: _levelColor(_extractLevel(entry)),
                        collapseAt: _collapseAt,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 单条日志卡片：左侧级别色条 + 时间/徽章行 + 消息正文。
///
/// release 下 VM isolate dump 极长（`*** *** ***` + 几百个 `#NN abs …`），
/// 默认折叠，点「展开」才看全文——否则一屏全是十六进制地址。
class _LogEntryCard extends StatefulWidget {
  const _LogEntryCard({
    required this.entry,
    required this.level,
    required this.time,
    required this.tag,
    required this.message,
    required this.color,
    required this.collapseAt,
  });

  final String entry;
  final String level;
  final String time;
  final String tag;
  final String message;
  final Color color;
  final int collapseAt;

  @override
  State<_LogEntryCard> createState() => _LogEntryCardState();
}

class _LogEntryCardState extends State<_LogEntryCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final long = widget.message.length > widget.collapseAt;
    final shown = (long && !_expanded)
        ? '${widget.message.substring(0, widget.collapseAt).trimRight()}…'
        : widget.message;
    final isSevere = widget.level == AppLog.error || widget.level == AppLog.fatal;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSevere
                ? widget.color.withValues(alpha: 0.45)
                : AppColors.strokeGlass,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 级别色条
            Container(
              width: 3,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(11)),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 12, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (widget.time.isNotEmpty)
                          Text(
                            widget.time,
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.textTertiary,
                              fontFamily: 'monospace',
                            ),
                          ),
                        const SizedBox(width: 6),
                        // 级别徽章
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: widget.color.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            widget.level,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: widget.color,
                            ),
                          ),
                        ),
                        if (widget.tag.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              widget.tag,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      shown,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.45,
                        color: isSevere ? widget.color : AppColors.textSecondary,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (long)
                      GestureDetector(
                        onTap: () => setState(() => _expanded = !_expanded),
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _expanded ? '收起' : '展开全文',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: AppColors.accent,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
