import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_logger.dart';
import '../../core/cache_manager.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';

/// 日志与调试页：展示应用运行日志，支持六级分级过滤 + 关键词搜索 +
/// 崩溃转储折叠 + 单条复制 + 导出。
///
/// v2.2.8 重构：
/// 1. 脚手架切到 [PageScaffold]——修掉子页面透出黑色窗口、大标题压内容
///    两个老毛病（与设置/关于等页同一套骨架）；
/// 2. 日志模型升级为结构化 [LogEntry]（`AppLog.snapshot` 负责过滤），
///    不再每次重建都对全量文本跑正则；
/// 3. 新增关键词搜索框与「隐藏纯转储」开关——release 下 VM isolate dump
///    动辄几百行 `#NN abs`，默认折叠成摘要，不再刷屏；
/// 4. 单条复制——报 bug 时可以直接贴出某一行。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  bool _exporting = false;
  String _filterLevel = AppLog.info;
  final List<String> _levels = [
    AppLog.trace,
    AppLog.debug,
    AppLog.info,
    AppLog.warn,
    AppLog.error,
    AppLog.fatal,
  ];

  /// 关键词搜索（对 tag / 消息做不区分大小写子串匹配）。
  final _searchController = TextEditingController();
  String _keyword = '';

  /// 隐藏「整条都是崩溃转储」的条目（有正文的条目保留，转储由卡片折叠）。
  bool _hideNoise = false;

  /// 单条日志超过这个长度就把尾部折叠起来。
  static const int _collapseAt = 140;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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
      // 这里 await 过了，context 可能已经失效——和 finally 一样要先判 mounted
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

  @override
  Widget build(BuildContext context) {
    final all = AppLog.instance.snapshot(
      minLevel: AppLog.trace,
      hideNoise: false,
    );
    final logs = AppLog.instance.snapshot(
      minLevel: _filterLevel,
      keyword: _keyword,
      hideNoise: _hideNoise,
    );

    return PageScaffold(
      title: '运行日志',
      snackbarHost: appSnackbarHostState,
      // 内部各栏自带水平留白，脚手架只补顶栏高度
      contentPadding: EdgeInsets.zero,
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
        if (all.isNotEmpty)
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
      child: Column(
        children: [
          // 关键词搜索
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: AppTextField(
              controller: _searchController,
              label: '搜索 tag 或消息内容',
              useLabelAsPlaceholder: true,
              singleLine: true,
              textInputAction: TextInputAction.search,
              leadingIcon: Icon(
                Icons.search_rounded,
                size: 18,
                color: AppColors.textTertiary,
              ),
              trailingIcon: _keyword.isEmpty
                  ? null
                  : MiuixIconButton(
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _keyword = '');
                      },
                      child: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: AppColors.textTertiary,
                      ),
                    ),
              onChanged: (v) => setState(() => _keyword = v),
            ),
          ),
          // 级别过滤栏
          SizedBox(
            height: 40,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: active
                            ? _levelColor(level).withValues(alpha: 0.2)
                            : AppColors.surfaceGlass,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: active
                              ? _levelColor(level)
                              : AppColors.strokeGlass,
                        ),
                      ),
                      child: Text(
                        level,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: active
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: active
                              ? _levelColor(level)
                              : AppColors.textTertiary,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // 统计 + 转储隐藏开关
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
            child: Row(
              children: [
                Text(
                  '显示 ${logs.length} / 共 ${all.length} 条',
                  style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
                const Spacer(),
                MiuixTextButton(
                  _hideNoise ? '显示转储' : '隐藏转储',
                  onPressed: () => setState(() => _hideNoise = !_hideNoise),
                  textStyle: TextStyle(
                    fontSize: 11,
                    color: _hideNoise
                        ? AppColors.accent
                        : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          // 落盘说明：日志按天保存在本地（保留 7 天），重启不丢失
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              children: [
                Icon(
                  Icons.save_rounded,
                  size: 12,
                  color: AppColors.textTertiary.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '日志按天保存在本地（保留 7 天），重启不会丢失；'
                    '发生闪退后重新打开此页即可查看崩前记录',
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.4,
                      color: AppColors.textTertiary.withValues(alpha: 0.7),
                    ),
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
                      _keyword.isEmpty ? '该级别暂无日志' : '没有匹配「$_keyword」的日志',
                      style: TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 13,
                      ),
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
                        color: _levelColor(entry.level),
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

/// 单条日志卡片：级别色条 + 时间/徽章/tag + 消息正文 + 转储折叠 + 复制。
///
/// release 下 VM isolate dump 极长（`*** *** ***` + 几百个 `#NN abs …`）：
/// 含转储的条目默认把噪声行折叠成一行摘要，点「展开转储」才看全文——
/// 否则一屏全是十六进制地址。点击复制图标把整条 raw 写进剪贴板。
class _LogEntryCard extends StatefulWidget {
  const _LogEntryCard({
    required this.entry,
    required this.color,
    required this.collapseAt,
  });

  final LogEntry entry;
  final Color color;
  final int collapseAt;

  @override
  State<_LogEntryCard> createState() => _LogEntryCardState();
}

class _LogEntryCardState extends State<_LogEntryCard> {
  bool _expanded = false;

  /// 折叠视图：去掉崩溃转储噪声行后的正文（首几行 + 摘要）。
  ({String text, bool truncated}) get _shown {
    final msg = widget.entry.message;
    if (widget.entry.hasNoise && !_expanded) {
      final lines = msg.split('\n');
      final body = lines
          .where((l) => l.trim().isNotEmpty && !AppLog.isNoiseLine(l))
          .toList();
      final head = body.take(3).join('\n');
      final hidden = lines.length - body.length;
      return (
        text: hidden > 0 ? '$head\n……（已折叠 $hidden 行系统转储，点「展开转储」查看）' : head,
        truncated: hidden > 0,
      );
    }
    final long = msg.length > widget.collapseAt;
    if (long && !_expanded) {
      return (
        text: '${msg.substring(0, widget.collapseAt).trimRight()}…',
        truncated: true,
      );
    }
    return (text: msg, truncated: false);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.entry.raw));
    if (!mounted) return;
    showAppSnack('已复制该条日志');
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final shown = _shown;
    final isSevere = entry.level == AppLog.error || entry.level == AppLog.fatal;
    final time = entry.time;

    String two(int v) => v.toString().padLeft(2, '0');
    final timeText =
        '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';

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
        // 用 Stack + Positioned 画级别色条，而不是 Row 的 stretch：
        // stretch 在垂直方向无界约束（嵌套滚动/无界高列表）下会炸
        // "BoxConstraints forces an infinite height"，且 IntrinsicHeight
        // 包一层在长日志列表里每条都要跑一遍 intrinsic，太贵。
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(11),
                  ),
                ),
              ),
            ),
                       // 内容：宽度撑满 Stack（Stack 宽度由父容器确定、有界）
            SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 8, 12, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          timeText,
                          style: TextStyle(
                              fontSize: 10,
                              color: AppColors.textTertiary,
                              fontFamily: 'monospace',
                            ),
                        ),
                        const SizedBox(width: 6),
                        // 级别徽章
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: widget.color.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            entry.level,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: widget.color,
                            ),
                          ),
                        ),
                        if (entry.tag.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              entry.tag,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                        const Spacer(),
                        // 复制按钮
                        GestureDetector(
                          onTap: _copy,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.copy_rounded,
                              size: 13,
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      shown.text,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.45,
                        color: isSevere
                            ? widget.color
                            : AppColors.textSecondary,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (shown.truncated)
                      GestureDetector(
                        onTap: () => setState(() => _expanded = !_expanded),
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _expanded ? '收起' : '展开转储',
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
