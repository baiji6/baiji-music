// 本地播放统计（v2.3.1）：听歌时长 / 播放次数 / 单曲循环次数。
//
// **完全本地**：数据只落在应用自己的 KvStore（SharedPreferences）里，
// 没有任何上报、任何网络请求，卸载即消失。
//
// 数据模型：按「天 × 歌曲」聚合，一天一个键：
//   play_stats:2026-10-20 → {"<songKey>": {"n":名,"s":歌手,"p":次数,"l":循环次数,"m":毫秒}}
// 只保留最近 [retainDays] 天（启动与跨天时清理过期键），7 日榜单由
// 7 个日 blob 现场聚合——不需要数据库，也不会随时间无限膨胀。
//
// 采集（两个来源互补）：
// - **播放次数**：`onSongChanged` 事件计一次。单曲循环播完重播同曲
//   也会走该事件（PlayerController._onTrackCompleted → play(同曲)），
//   因此「循环次数」= 同曲 + 当前处于单曲循环模式 的播放事件；
// - **听歌时长**：`onPositionChanged` 的**正向前进量**累加——统计的是
//   真实播放推进（暂停不计、seek 跳变不计、后台播放只要解码器还在
//   推进就照常计入），比墙钟心跳更准，也不怕后台定时器被系统节流。
//
// 落盘时机：每 10 秒 / 暂停 / 切歌 / 退后台 / App 结束，最多丢最后
// 10 秒的增量。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_logger.dart';
import 'kv_store.dart';
import '../models/models.dart';
import '../player/player_controller.dart';

/// 单曲在一段统计窗口内的聚合。
class SongStat {
  const SongStat({
    required this.key,
    required this.name,
    required this.singer,
    required this.plays,
    required this.loopPlays,
    required this.listenedMs,
  });

  final String key;
  final String name;
  final String singer;

  /// 播放次数（每次开播 +1，含单曲循环的重播）。
  final int plays;

  /// 其中处于单曲循环模式的重播次数。
  final int loopPlays;

  /// 累计听歌毫秒数（真实播放推进量）。
  final int listenedMs;

  SongStat operator +(SongStat o) => SongStat(
        key: key,
        name: name.isNotEmpty ? name : o.name,
        singer: singer.isNotEmpty ? singer : o.singer,
        plays: plays + o.plays,
        loopPlays: loopPlays + o.loopPlays,
        listenedMs: listenedMs + o.listenedMs,
      );
}

/// 一天的合计。
class DayStat {
  const DayStat({required this.day, required this.listenedMs, required this.plays});
  final String day; // yyyy-MM-dd
  final int listenedMs;
  final int plays;
}

/// 汇总（今日 + 近 N 日窗口）。
class StatsOverview {
  const StatsOverview({
    required this.today,
    required this.todayMs,
    required this.todayPlays,
    required this.todayLoopPlays,
    required this.windowMs,
    required this.windowPlays,
    required this.perDay,
    required this.topSongs,
  });

  final String today;
  final int todayMs;
  final int todayPlays;
  final int todayLoopPlays;
  final int windowMs;
  final int windowPlays;

  /// 窗口内按天的合计（旧→新，长度 = 窗口天数）。
  final List<DayStat> perDay;

  /// 窗口内按时长排序的聚合榜（默认取 7 日）。
  final List<SongStat> topSongs;
}

/// 当前内存累积器（两次落盘之间的增量）。
class _Acc {
  _Acc(this.day, this.key, this.name, this.singer)
      : plays = 0,
        loopPlays = 0,
        ms = 0;
  final String day;
  final String key;
  final String name;
  final String singer;
  int plays;
  int loopPlays;
  int ms;
}

/// 播放统计服务。应用启动时 [start] 一次；查询接口可随时调用。
class PlayStatsService with WidgetsBindingObserver {
  PlayStatsService._();

  static final PlayStatsService instance = PlayStatsService._();

  static const String _prefix = 'play_stats:';

  /// 日 blob 保留天数（7 日榜只需 7 天，留 15 天余量给跨时区/翻看）。
  static const int retainDays = 15;

  /// 两次落盘之间的最大间隔。
  static const Duration flushInterval = Duration(seconds: 10);

  /// 单个 position 跳变计入时长的上限（超过视为 seek，不计入）。
  static const int _maxPositionJumpMs = 5000;

  bool _started = false;
  StreamSubscription<Song?>? _songSub;
  StreamSubscription<Duration>? _posSub;
  Timer? _flushTimer;

  /// 当前累积器（null = 还没有播放事件）。
  _Acc? _acc;

  /// 当前曲目的上一次 position（推进量 = pos - lastPos）。
  Duration _lastPos = Duration.zero;

  /// 上一首歌的 key（单曲循环检测用）。
  String? _lastKey;

  /// 日 blob 的内存缓存（懒加载），键 = day，值 = 原始 JSON 串。
  final Map<String, String> _dayCache = {};

  /// 是否有未落盘的增量。
  bool _dirty = false;

  /// 启动采集（幂等）。必须在 KvStore.ensureInit 之后调用。
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final player = PlayerController.instance;
    _songSub = player.onSongChanged.listen(_onSongChanged);
    _posSub = player.onPositionChanged.listen(_onPositionChanged);
    _flushTimer = Timer.periodic(flushInterval, (_) => flush());
    _pruneOldDays();
    AppLog.i('PlayStats', '本地播放统计已启动');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退后台先落盘（后台播放的增量继续由 position 事件驱动，
    // 下一次 flush 兜底）；不要在这里停掉订阅。
    if (state == AppLifecycleState.paused) flush();
  }

  /// 停止采集并落盘（测试 / 极端场景用；生产环境服务常驻）。
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    await _songSub?.cancel();
    await _posSub?.cancel();
    _songSub = null;
    _posSub = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
  }

  /// 清空内存状态（仅测试用：单例的日缓存会跨用例残留）。
  @visibleForTesting
  void resetForTest() {
    _dayCache.clear();
    _acc = null;
    _lastKey = null;
    _lastPos = Duration.zero;
    _dirty = false;
  }

  /// songKey：同曲跨天/跨版本聚合的稳定标识。
  static String songKeyOf(Song s) {
    final id = s.songId > 0 ? '${s.songId}' : s.mid;
    return '${s.source}:$id';
  }

  static String _dayOf(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  static String _today() => _dayOf(DateTime.now());

  // ================= 采集 =================

  void _onSongChanged(Song? song) {
    if (song == null) {
      flush();
      _acc = null;
      _lastPos = Duration.zero;
      return;
    }
    final key = songKeyOf(song);
    final loop =
        PlayerController.instance.playMode == PlayMode.singleLoop &&
            key == _lastKey;
    _lastKey = key;
    final day = _today();
    // 同一天同曲的连续事件并入当前累积器（循环重播）；否则开新累积器。
    final acc = _acc;
    if (acc != null && acc.day == day && acc.key == key) {
      acc.plays += 1;
      if (loop) acc.loopPlays += 1;
    } else {
      flush();
      _acc = _Acc(day, key, song.name, song.singer)
        ..plays = 1
        ..loopPlays = loop ? 1 : 0;
    }
    _lastPos = Duration.zero;
  }

  void _onPositionChanged(Duration pos) {
    final acc = _acc;
    if (acc == null) {
      _lastPos = pos;
      return;
    }
    final d = pos.inMilliseconds - _lastPos.inMilliseconds;
    _lastPos = pos;
    // 只累计正向前进量；seek 跳变（>5s 或倒退）不计入
    if (d > 0 && d <= _maxPositionJumpMs) {
      acc.ms += d;
      _dirty = true;
    }
  }

  /// 把内存增量合并进当日 blob 并落盘。
  Future<void> flush() async {
    final acc = _acc;
    if (!_dirty || acc == null) return;
    _dirty = false;
    try {
      final map = _loadDay(acc.day);
      final prev = map[acc.key];
      final merged = <String, Object?>{
        ...?prev,
        'n': acc.name,
        's': acc.singer,
        'p': (prev?['p'] as int? ?? 0) + acc.plays,
        'l': (prev?['l'] as int? ?? 0) + acc.loopPlays,
        'm': (prev?['m'] as int? ?? 0) + acc.ms,
      };
      // 全 0 的条目没有统计意义（比如刚开播就切走）
      if ((merged['p'] as int) > 0 || (merged['m'] as int) > 0) {
        map[acc.key] = merged;
      }
      final json = jsonEncode(map);
      _dayCache[acc.day] = json;
      await KvStore.instance.setString('$_prefix${acc.day}', json);
    } catch (e) {
      AppLog.w('PlayStats', '落盘失败: $e');
    }
  }

  Map<String, Map<String, Object?>> _loadDay(String day) {
    final cached = _dayCache[day] ?? KvStore.instance.getString('$_prefix$day');
    if (cached == null || cached.isEmpty) return {};
    _dayCache[day] = cached;
    try {
      final raw = jsonDecode(cached) as Map<String, dynamic>;
      return raw.map((k, v) => MapEntry(k, (v as Map).cast<String, Object?>()));
    } catch (e) {
      AppLog.w('PlayStats', '日 blob 解析失败 $day: $e');
      return {};
    }
  }

  /// 清理保留窗口之外的旧键（启动 / 跨天时调用）。
  void _pruneOldDays() {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: retainDays))
        .millisecondsSinceEpoch;
    try {
      for (final key in KvStore.instance.snapshot().keys) {
        if (!key.startsWith(_prefix)) continue;
        final day = key.substring(_prefix.length);
        final t = DateTime.tryParse(day);
        if (t == null || t.millisecondsSinceEpoch < cutoff) {
          // ignore: discarded_futures
          KvStore.instance.remove(key);
          _dayCache.remove(day);
        }
      }
    } catch (e) {
      AppLog.w('PlayStats', '清理旧统计失败: $e');
    }
  }

  // ================= 查询 =================

  /// 近 [days] 天（含今日）的汇总。
  StatsOverview overview({int days = 7}) {
    final today = _today();
    final dayList = <DayStat>[];
    final merged = <String, SongStat>{};
    var windowMs = 0;
    var windowPlays = 0;

    for (var i = days - 1; i >= 0; i--) {
      final day = _dayOf(DateTime.now().subtract(Duration(days: i)));
      final map = _loadDay(day);
      var dayMs = 0;
      var dayPlays = 0;
      map.forEach((key, v) {
        final stat = _statOf(key, v);
        dayMs += stat.listenedMs;
        dayPlays += stat.plays;
        merged[key] = merged[key] == null ? stat : (merged[key]! + stat);
      });
      dayList.add(DayStat(day: day, listenedMs: dayMs, plays: dayPlays));
      windowMs += dayMs;
      windowPlays += dayPlays;
    }

    final todayMap = _loadDay(today);
    var todayMs = 0;
    var todayPlays = 0;
    var todayLoop = 0;
    todayMap.forEach((_, v) {
      todayMs += v['m'] as int? ?? 0;
      todayPlays += v['p'] as int? ?? 0;
      todayLoop += v['l'] as int? ?? 0;
    });

    final top = merged.values.toList()
      ..sort((a, b) => b.listenedMs.compareTo(a.listenedMs));

    return StatsOverview(
      today: today,
      todayMs: todayMs,
      todayPlays: todayPlays,
      todayLoopPlays: todayLoop,
      windowMs: windowMs,
      windowPlays: windowPlays,
      perDay: dayList,
      topSongs: top,
    );
  }

  SongStat _statOf(String key, Map<String, Object?> v) => SongStat(
        key: key,
        name: v['n']?.toString() ?? '',
        singer: v['s']?.toString() ?? '',
        plays: v['p'] as int? ?? 0,
        loopPlays: v['l'] as int? ?? 0,
        listenedMs: v['m'] as int? ?? 0,
      );

  /// 纯函数：毫秒 → 「x 小时 y 分 / y 分 z 秒」（页面展示用）。
  static String formatDuration(int ms) {
    if (ms <= 0) return '0 分钟';
    final totalSec = ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) return '$h 小时 $m 分';
    if (m > 0) return '$m 分 $s 秒';
    return '$s 秒';
  }
}
