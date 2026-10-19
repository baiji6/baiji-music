// 播放统计页（v2.3.1）：今日时长 / 7 日柱状图 / 7 日最爱 / 次数与时长榜。
// 数据全部来自本地 PlayStatsService（见 core/play_stats.dart），无网络。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/play_stats.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// 播放统计页：完全本地的听歌数据。
class PlayStatsPage extends StatefulWidget {
  const PlayStatsPage({super.key});

  @override
  State<PlayStatsPage> createState() => _PlayStatsPageState();
}

class _PlayStatsPageState extends State<PlayStatsPage> {
  late StatsOverview _overview;
  bool _byTime = true; // 榜单排序：true = 按时长，false = 按次数

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() => _overview = PlayStatsService.instance.overview(days: 7));
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '播放统计',
      actions: [
        MiuixIconButton(
          onPressed: _reload,
          child: Icon(Icons.refresh_rounded,
              size: 20, color: AppColors.textSecondary),
        ),
      ],
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: _overview.windowPlays == 0 && _overview.windowMs == 0
          ? const _Empty()
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _todayCard(),
                  const SizedBox(height: 24),
                  const SectionHeader(
                      title: '近 7 日', icon: Icons.timeline_rounded),
                  _weekCard(),
                  const SizedBox(height: 24),
                  const SectionHeader(
                      title: '7 日最爱', icon: Icons.favorite_rounded),
                  _favoriteCard(),
                  const SizedBox(height: 24),
                  const SectionHeader(
                      title: '歌曲排行（近 7 日）',
                      icon: Icons.leaderboard_rounded),
                  _rankingCard(),
                ],
              ),
            ),
    );
  }

  // ================= 今日卡 =================

  Widget _todayCard() {
    final o = _overview;
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('今日听歌',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          Text(
            PlayStatsService.formatDuration(o.todayMs),
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w900,
              color: AppColors.textPrimary,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _chip(Icons.play_circle_outline_rounded, '播放 ${o.todayPlays} 次'),
              const SizedBox(width: 10),
              _chip(Icons.repeat_one_rounded, '单曲循环 ${o.todayLoopPlays} 次'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.strokeGlass),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: AppColors.accent),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
          ],
        ),
      );

  // ================= 7 日柱状图 =================

  Widget _weekCard() {
    final o = _overview;
    final maxMs =
        o.perDay.fold<int>(1, (m, d) => d.listenedMs > m ? d.listenedMs : m);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                PlayStatsService.formatDuration(o.windowMs),
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('共 ${o.windowPlays} 次',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 110,
            width: double.infinity,
            child: CustomPaint(
              painter: _BarsPainter(
                values: [for (final d in o.perDay) d.listenedMs.toDouble()],
                maxMs: maxMs.toDouble(),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final d in o.perDay)
                Expanded(
                  child: Text(
                    d.day == o.today ? '今天' : d.day.substring(5),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 10, color: AppColors.textTertiary),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ================= 7 日最爱 =================

  Widget _favoriteCard() {
    final top = _overview.topSongs.isEmpty ? null : _overview.topSongs.first;
    if (top == null || top.listenedMs <= 0) {
      return GlassCard(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
        child: Text('还没有足够的数据',
            style: TextStyle(
                fontSize: 13, color: AppColors.textTertiary)),
      );
    }
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: AppColors.playGradient),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.favorite_rounded,
                color: Colors.white, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(top.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 3),
                Text(top.singer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(PlayStatsService.formatDuration(top.listenedMs),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.accent)),
              const SizedBox(height: 3),
              Text('播放 ${top.plays} 次',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.textTertiary)),
            ],
          ),
        ],
      ),
    );
  }

  // ================= 排行榜 =================

  Widget _rankingCard() {
    final list = _overview.topSongs.toList()
      ..sort((a, b) => _byTime
          ? b.listenedMs.compareTo(a.listenedMs)
          : b.plays.compareTo(a.plays));
    final shown = list.take(20).toList();
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: Row(
              children: [
                _segment('按时长', _byTime, () => setState(() => _byTime = true)),
                const SizedBox(width: 8),
                _segment('按次数', !_byTime, () => setState(() => _byTime = false)),
              ],
            ),
          ),
          for (var i = 0; i < shown.length; i++) ...[
            if (i > 0)
              MiuixHorizontalDivider(thickness: 1, color: AppColors.strokeGlass),
            _rankRow(i + 1, shown[i]),
          ],
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text('近 7 日没有播放记录',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textTertiary)),
            ),
        ],
      ),
    );
  }

  Widget _segment(String label, bool active, VoidCallback onTap) =>
      MiuixPressable(
        onPressed: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? AppColors.accent.withValues(alpha: 0.15)
                : AppColors.surfaceGlass,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: active ? AppColors.accent : AppColors.strokeGlass),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? AppColors.accent : AppColors.textSecondary)),
        ),
      );

  Widget _rankRow(int rank, SongStat s) {
    final rankColor = rank <= 3 ? AppColors.accent : AppColors.textTertiary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text('$rank',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: rankColor)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  s.singer +
                      (s.loopPlays > 0 ? ' · 单曲循环 ${s.loopPlays} 次' : ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _byTime
                    ? PlayStatsService.formatDuration(s.listenedMs)
                    : '${s.plays} 次',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.accent),
              ),
              if (_byTime)
                Text('播放 ${s.plays} 次',
                    style: TextStyle(
                        fontSize: 10, color: AppColors.textTertiary)),
            ],
          ),
        ],
      ),
    );
  }
}

/// 7 日柱状图：柱高按当日时长归一化，空数据画一条底线。
class _BarsPainter extends CustomPainter {
  const _BarsPainter({required this.values, required this.maxMs});

  final List<double> values;
  final double maxMs;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final n = values.length;
    final slot = size.width / n;
    final barW = (slot * 0.46).clamp(6.0, 26.0);
    final chartH = size.height;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          AppColors.accent,
          AppColors.violet.withValues(alpha: 0.55),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, chartH));

    for (var i = 0; i < n; i++) {
      final h = values[i] <= 0
          ? 2.0
          : (values[i] / (maxMs <= 0 ? 1 : maxMs) * (chartH - 6)).clamp(2.0, chartH);
      final cx = slot * i + slot / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - barW / 2, chartH - h, barW, h),
        Radius.circular(barW / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) =>
      old.values != values || old.maxMs != maxMs;
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bar_chart_rounded,
              size: 52, color: AppColors.textTertiary),
          const SizedBox(height: 12),
          Text('还没有播放记录\n去听几首歌吧，数据只存在本机',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textTertiary)),
        ],
      ),
    );
  }
}
