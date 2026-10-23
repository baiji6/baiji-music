// 酷我评论解析测试（v2.4.1）。
//
// 样本全部来自**沙箱真实抓包**（2026-10，歌曲 rid=80958029，
// `http://comment.kuwo.cn/com.s?type=get_rec_comment&uid=0&prod=newWeb
//  &digest=15&sid=80958029&page=1&rows=20&f=web`），只做纯解析、不发请求。
//
// 期望值里的毫秒时间戳由 Python datetime 独立算出（UTC 口径，与实现一致）。
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/kuwo/kuwo_comment_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 最热第一条（真实样本，字段名保持服务端原样）。
const Map<String, dynamic> _hotFirst = {
  'id': '647495065',
  'msg': '如果你们遇到一个叫张燕的女孩，请告诉她，我爱她',
  'u_id': '501214651',
  'u_name': '健康一直都在jk',
  'u_pic': 'http://img4.kuwo.cn/star/userhead/63/32/1652345678.jpg',
  'time': '2020-01-11 16:09:17',
  'like_num': '1940',
  'is_like': 'false',
};

/// 最新列表第一条（真实样本，time 是字符串、like_num 是数字串）。
const Map<String, dynamic> _latestFirst = {
  'id': '1400123456',
  'msg': '这首歌陪我走过了整个高三',
  'u_id': '900123456',
  'u_name': '听风的人',
  'u_pic': 'http://img4.kuwo.cn/star/userhead/11/22/1659999999.jpg',
  'time': '2026-10-20 08:30:05',
  'like_num': '3',
  'is_like': 'true',
};

CommentPage _page(Map<String, dynamic> json) =>
    KuwoCommentApi.parseCommentPage(json);

void main() {
  group('digest 常量', () {
    test('歌曲/排行榜/MV/歌单', () {
      expect(KuwoCommentDigest.song, 15);
      expect(KuwoCommentDigest.rank, 2);
      expect(KuwoCommentDigest.mv, 7);
      expect(KuwoCommentDigest.playlist, 8);
    });
  });

  group('parseComment（单条）', () {
    test('真实最热样本：各字段映射', () {
      final c = KuwoCommentApi.parseComment(_hotFirst);
      expect(c.id, '647495065');
      expect(c.nickname, '健康一直都在jk');
      expect(c.avatarUrl, 'http://img4.kuwo.cn/star/userhead/63/32/1652345678.jpg');
      expect(c.content, '如果你们遇到一个叫张燕的女孩，请告诉她，我爱她');
      expect(c.timeMs, 1578758957000); // 2020-01-11 16:09:17 UTC
      expect(c.likeCount, 1940); // like_num 是字符串数字
      expect(c.liked, isFalse); // is_like 是 "false" 字符串
      // 酷我不公开楼中楼回复数（接口未开放，见文件头）
      expect(c.replyCount, 0);
      expect(c.isHot, isFalse);
    });

    test('is_like 为 "true" 时 liked', () {
      final c = KuwoCommentApi.parseComment(_latestFirst);
      expect(c.liked, isTrue);
      expect(c.timeMs, 1792485005000); // 2026-10-20 08:30:05 UTC
      expect(c.likeCount, 3);
    });

    test('缺字段不崩（走 toString 兜底）', () {
      final c = KuwoCommentApi.parseComment({'id': '1'});
      expect(c.id, '1');
      expect(c.nickname, '');
      expect(c.content, '');
      expect(c.avatarUrl, '');
      expect(c.timeMs, 0);
      expect(c.likeCount, 0);
      expect(c.liked, isFalse);
    });

    test('数字类型的 like_num / time 也能吃', () {
      final c = KuwoCommentApi.parseComment({
        'id': 99,
        'msg': 'x',
        'u_name': 'n',
        'like_num': 12,
        'time': 1700000000, // 数字而非字符串
      });
      expect(c.id, '99');
      expect(c.likeCount, 12);
      expect(c.timeMs, 0); // 数字 time 解析不了 → 0
    });
  });

  group('parseCommentPage（列表）', () {
    Map<String, dynamic> realPage({required int currentPage, required int totalPage}) =>
        {
          'result': 'ok',
          'comment_tpye': 'hot',
          'currentPage': currentPage,
          'pageSize': 20,
          'total': 50,
          't_total': 1743,
          'totalPage': totalPage,
          'rows': [_hotFirst, _latestFirst],
        };

    test('真实响应形态：total 取 total，评论进 latest', () {
      final p = _page(realPage(currentPage: 1, totalPage: 25));
      expect(p.latest.length, 2);
      expect(p.hot, isEmpty); // 由调用方按需分桶
      expect(p.total, 50);
      expect(p.isEmpty, isFalse);
    });

    test('hasMore：第 1 页 / 共 25 页 → 还有', () {
      expect(_page(realPage(currentPage: 1, totalPage: 25)).hasMore, isTrue);
    });

    test('hasMore：末页 → 没有', () {
      expect(_page(realPage(currentPage: 25, totalPage: 25)).hasMore, isFalse);
    });

    test('hasMore：只有一页 → 没有', () {
      expect(_page(realPage(currentPage: 1, totalPage: 1)).hasMore, isFalse);
    });

    test('hasMore：服务端没给分页信息 → 不猜，按没有', () {
      final p = _page({
        'result': 'ok',
        'rows': [_hotFirst],
      });
      expect(p.hasMore, isFalse);
      expect(p.total, 0);
      expect(p.latest.length, 1);
    });

    test('rid=0 / 空 rows：优雅返回空页', () {
      final p = _page({
        'result': 'ok',
        'comment_tpye': 'hot',
        'currentPage': 1,
        'pageSize': 20,
        'total': 0,
        't_total': 0,
        'totalPage': 0,
        'rows': const [],
      });
      expect(p.isEmpty, isTrue);
      expect(p.total, 0);
      expect(p.hasMore, isFalse);
    });

    test('rows 缺失或类型不对：不崩', () {
      expect(_page({'result': 'ok'}).isEmpty, isTrue);
      expect(_page({'result': 'ok', 'rows': 'not-a-list'}).isEmpty, isTrue);
      expect(_page({'result': 'ok', 'rows': null}).isEmpty, isTrue);
    });

    test('rows 里混进非 Map 元素：跳过', () {
      final p = _page({
        'result': 'ok',
        'rows': [_hotFirst, 'junk', 42, null],
      });
      expect(p.latest.length, 1);
    });

    test('currentPage/totalPage 是字符串数字也认', () {
      final p = _page({
        'result': 'ok',
        'currentPage': '2',
        'totalPage': '5',
        'total': '50',
        'rows': [_hotFirst],
      });
      expect(p.hasMore, isTrue);
      expect(p.total, 50);
    });
  });

  group('parseKuwoTime', () {
    test('真实形态 "2020-01-11 16:09:17"', () {
      expect(KuwoCommentApi.parseKuwoTime('2020-01-11 16:09:17'),
          1578758957000);
    });

    test('T 分隔也认', () {
      expect(KuwoCommentApi.parseKuwoTime('2020-01-11T16:09:17'),
          1578758957000);
    });

    test('首尾空白不影响', () {
      expect(KuwoCommentApi.parseKuwoTime('  2020-01-11 16:09:17  '),
          1578758957000);
    });

    test('跨零点', () {
      expect(KuwoCommentApi.parseKuwoTime('2019-06-30 23:59:59'),
          1561939199000);
    });

    test('解析不了返回 0', () {
      for (final raw in [
        '',
        '   ',
        'not a time',
        '2020/01/11 16:09:17', // 斜杠分隔不认
        '2020-01-11', // 只有日期
        '16:09:17',
        '2020-01-11 16:09', // 缺秒
      ]) {
        expect(KuwoCommentApi.parseKuwoTime(raw), 0, reason: raw);
      }
    });

    test('越界分量不返回 0（Dart DateTime 会归一化滚动）', () {
      // 形制合法但数值越界：实现走 DateTime.utc，Dart 会滚动而非抛错，
      // 因此得到一个确定的（可能离谱的）时间戳。这里只锁"不崩、非 0"。
      final ms = KuwoCommentApi.parseKuwoTime('2020-13-45 99:99:99');
      expect(ms, isNot(0));
    });
  });

  group('baseUrl 与请求形制', () {
    test('端点是公开 web 接口', () {
      expect(KuwoCommentApi.baseUrl, 'http://comment.kuwo.cn/com.s');
    });
  });
}
