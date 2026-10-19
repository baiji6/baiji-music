// 本地播放统计（v2.3.1）的契约测试：聚合查询 / 纯函数 / 过期清理。
//
// 采集链路（onSongChanged / onPositionChanged → 累积器 → 落盘）依赖
// 真实播放器事件流，测试环境不推事件；这里直接**种子日 blob** 驱动
// 查询层，并验证 songKey / 时长格式化 / 保留窗口清理这三个纯边界。
import 'dart:convert';

import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/play_stats.dart';
import 'package:baiji_music/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await KvStore.ensureInit();
    await KvStore.instance.clear();
    // 单例的日 blob 内存缓存会跨用例残留，必须一并清掉
    PlayStatsService.instance.resetForTest();
  });

  String dayKey(String day) => 'play_stats:$day';

  /// 种子一天的 blob：songKey → {n,s,p,l,m}
  Future<void> seedDay(String day, Map<String, Object?> songs) async {
    await KvStore.instance.setString(dayKey(day), jsonEncode(songs));
  }

  test('songKeyOf：网络歌用 songId，本地歌用 mid，且带音源前缀', () {
    final ne = Song(
      mid: 'ne-mid',
      songId: 422104138,
      name: '后来的我们',
      singer: '五月天',
      album: '',
      albumMid: '',
      duration: 0,
      cover: '',
      source: 'netease',
      localPath: '',
    );
    final local = Song(
      mid: 'local:abc',
      songId: 0,
      name: 'Moon Halo',
      singer: '茶理理子',
      album: '',
      albumMid: '',
      duration: 0,
      cover: '',
      source: 'local',
      localPath: '/tmp/x.flac',
    );
    expect(PlayStatsService.songKeyOf(ne), 'netease:422104138');
    expect(PlayStatsService.songKeyOf(local), 'local:local:abc');
  });

  test('formatDuration：秒 / 分 / 时 的分界', () {
    expect(PlayStatsService.formatDuration(0), '0 分钟');
    expect(PlayStatsService.formatDuration(59 * 1000), '59 秒');
    expect(PlayStatsService.formatDuration(61 * 1000), '1 分 1 秒');
    expect(PlayStatsService.formatDuration(3660 * 1000), '1 小时 1 分');
  });

  test('overview：跨日聚合、同曲跨日合并、循环次数与每日柱数据', () {
    final now = DateTime.now();
    String d(int ago) {
      final t = now.subtract(Duration(days: ago));
      return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    }

    seedDay(d(0), {
      'netease:1': {'n': '后来', 's': '五月天', 'p': 3, 'l': 2, 'm': 600000},
      'netease:2': {'n': '耀斑', 's': '张韶涵', 'p': 1, 'l': 0, 'm': 120000},
    });
    seedDay(d(1), {
      'netease:1': {'n': '后来', 's': '五月天', 'p': 1, 'l': 0, 'm': 300000},
    });
    // 窗口外的旧数据不计入 7 日
    seedDay(d(8), {
      'netease:9': {'n': '窗外', 's': 'x', 'p': 5, 'l': 0, 'm': 999999},
    });

    final o = PlayStatsService.instance.overview(days: 7);
    // 窗口合计 = (600+120+300) 秒
    expect(o.windowMs, 1020000);
    expect(o.windowPlays, 5);
    // 今日
    expect(o.todayMs, 720000);
    expect(o.todayPlays, 4);
    expect(o.todayLoopPlays, 2);
    // 每日柱：7 个点、旧→新
    expect(o.perDay.length, 7);
    expect(o.perDay.last.listenedMs, 720000);
    expect(o.perDay[o.perDay.length - 2].listenedMs, 300000);
    expect(o.perDay.first.listenedMs, 0);
    // 同曲跨日合并：后来 = 900000ms / 4 次 / 循环 2
    final top = o.topSongs.first;
    expect(top.key, 'netease:1');
    expect(top.name, '后来');
    expect(top.listenedMs, 900000);
    expect(top.plays, 4);
    expect(top.loopPlays, 2);
    // 窗口外的「窗外」不进榜
    expect(o.topSongs.any((s) => s.key == 'netease:9'), isFalse);
  });

  test('榜单排序语义由调用方决定（时长 vs 次数）', () {
    final now = DateTime.now();
    final today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    seedDay(today, {
      'a:1': {'n': '长听', 's': 'x', 'p': 2, 'l': 0, 'm': 1000000},
      'a:2': {'n': '常点', 's': 'y', 'p': 9, 'l': 5, 'm': 200000},
    });
    final o = PlayStatsService.instance.overview(days: 7);
    // 默认按时长：长听第一
    expect(o.topSongs.first.key, 'a:1');
    // 按次数：常点第一
    final byPlays = o.topSongs.toList()
      ..sort((a, b) => b.plays.compareTo(a.plays));
    expect(byPlays.first.key, 'a:2');
    expect(byPlays.first.loopPlays, 5);
  });

  test('损坏的日 blob 不炸查询（回退为空）', () {
    final now = DateTime.now();
    final today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    KvStore.instance.setString(dayKey(today), '{not json');
    final o = PlayStatsService.instance.overview(days: 7);
    expect(o.windowMs, 0);
    expect(o.windowPlays, 0);
    expect(o.topSongs, isEmpty);
  });

  test('保留窗口清理：过期的日 blob 被删，当日保留', () async {
    await KvStore.instance
        .setString(dayKey('2020-01-01'), jsonEncode({'a:1': {'p': 1}}));
    await KvStore.instance.setString(
        dayKey('2099-01-01'), jsonEncode({'a:2': {'p': 1}}));
    final svc = PlayStatsService.instance;
    svc.start();
    await svc.stop();
    expect(KvStore.instance.getString(dayKey('2020-01-01')), isNull);
    expect(KvStore.instance.getString(dayKey('2099-01-01')), isNotNull);
  });
}
