// 网易云歌单详情回归测试（离线，纯逻辑）。
//
// 背景：老 /api/playlist/detail 对**用户自建歌单**只回前 10 首预览
// （trackCount 也谎报 10），导致登录账号的歌单只显示 10 首。修复后改走
// v6 拿全量 trackIds + 分批 v3 song/detail，并按 trackIds 顺序还原。
//
// 网络取数路径（postApi + songDetailSongs）在沙箱已用真实接口验证
// （trackIds 含全部 id、v3 song/detail 批量按请求顺序返回），这里只测
// 确定性的合并/排序逻辑，避免引入 flaky 网络测试。
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/playlist_api.dart';
import 'package:flutter_test/flutter_test.dart';

Song _s(int id, {String name = ''}) => Song(
      mid: 'ne$id',
      songId: id,
      name: name.isEmpty ? 'song$id' : name,
      singer: 'artist$id',
      album: 'album$id',
      albumMid: '',
      duration: 1000,
      cover: '',
      source: Source.netease,
    );

void main() {
  group('PlaylistApi.mergeNeteaseTracks（修复 10 首截断的核心合并逻辑）', () {
    test('按 trackIds 顺序还原，忽略返回次序', () {
      // 模拟：trackIds 顺序 1→2→3→4→5，但 song/detail 分批返回次序打乱
      final ids = [1, 2, 3, 4, 5];
      final fetched = [_s(3), _s(1), _s(5), _s(2), _s(4)];
      final got = PlaylistApi.mergeNeteaseTracks(ids, fetched);
      expect(got.map((s) => s.songId).toList(), [1, 2, 3, 4, 5]);
    });

    test('分批（每批 100）后跨批合并仍有序', () {
      // 250 首：第一批 100、第二批 100、第三批 50，返回均乱序
      final ids = [for (var i = 1; i <= 250; i++) i];
      final fetched = <Song>[];
      for (final i in ids) {
        fetched.insert(0, _s(i)); // 完全逆序
      }
      final got = PlaylistApi.mergeNeteaseTracks(ids, fetched);
      expect(got.length, 250);
      expect(got.first.songId, 1);
      expect(got.last.songId, 250);
      expect(got.map((s) => s.songId).toList(), ids);
    });

    test('下架/无版权曲目（详情缺失）被跳过，不报错', () {
      final ids = [1, 2, 3, 4];
      // 只拿到 1、3、4，2 缺失（模拟网易云不返回下架曲详情）
      final fetched = [_s(1), _s(4), _s(3)];
      final got = PlaylistApi.mergeNeteaseTracks(ids, fetched);
      expect(got.map((s) => s.songId).toList(), [1, 3, 4]);
    });

    test('空 trackIds → 空列表', () {
      expect(PlaylistApi.mergeNeteaseTracks(const [], const []), isEmpty);
    });

    test('修复前的行为对照：若只取前 10 预览会丢曲（用 250 首样本说明）', () {
      // 模拟老接口的「预览 10 首」：取 ids 前 10 个
      final ids = [for (var i = 1; i <= 250; i++) i];
      final preview = ids.take(10).toList();
      final got = PlaylistApi.mergeNeteaseTracks(preview, [
        for (final i in preview) _s(i),
      ]);
      // 旧实现会因此只显示 10 首；新实现用全量 ids 不会
      expect(got.length, 10);
      expect(ids.length, 250);
    });
  });
}
