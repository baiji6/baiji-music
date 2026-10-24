// 酷我音乐歌曲评论。
//
// 三条链路，全部**沙箱真机验证**（2026-10，歌曲 rid=80958029，
// 登录账号 uid=616474112「白姬」）：
//
// **① Web 公开读**（v2.4.1，`http://comment.kuwo.cn/com.s?f=web`）：
//   免登录读最热/最新。`time` 是 `"2020-01-11 16:09:17"` 形态字符串、
//   `like_num` 是数字串、`is_like` 是 "true"/"false" 串。分页 page/rows。
//
// **② App 富读**（`http://ncomment.kuwo.cn/com.s?f=web`，倾听同款）：
//   免登录（kw_token cookie / reqId 均非必需）。`hot_comments[]` /
//   `comments[]` 内嵌 `child_comments[]`（楼中楼首页）与
//   `child_comment_count`；`time` 是秒级时间戳（数字或数字串），
//   `is_like` 是 bool。分页 start/count offset 式，总数在
//   `hot_comments_counts` / `comments_counts`。
//
// **③ App 私有写**（`ncomment*.kuwo.cn` + `f=ar` DES 密封，v2.4.2）：
//   - 查询串 `q = base64(DES-ECB(query, "kwks&@69"))`，响应
//     `base64(DES-ECB(json, sx))`，sx = 当前毫秒前 8 位
//     （复用 [KuwoCipher]，与登录/短信协议同一把钥匙）；
//   - 发表 / 回复：POST `http://ncommentw.kuwo.cn/com.s`，body = msg
//     的 UTF-8 裸字节（`Content-Type: application/octet-stream`，UA =
//     Dalvik），msg 里的 `&` 先替换为全角 `＆`；成功判据 `code == "200"`，
//     响应 `comments[0]` 就是新评论；
//   - 点赞 / 取消：GET `http://ncomment.kuwo.cn/com.s`，
//     `type=click_like|cancel_like`，响应 `like` 字段是新赞数；
//   - 楼中楼：GET 同主机，`type=get_child_comment`，`result == "ok"`，
//     `comments[]` 为回复列表，`main_comment` 为父评论。
//   - 写接口都要登录态（[KuwoAuth.session] 的 uid + sesID = sid）。
//   真机实测：发表 code=200 并返回新评论对象；点赞 `like:"1"`、
//   取消 `like:"0"`；带 reply+pcid 的回复发出后楼中楼立即可见。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../models/models.dart';
import 'kuwo_api.dart';
import 'kuwo_auth.dart';
import 'kuwo_cipher.dart';

/// 酷我评论业务类型（digest）。
abstract final class KuwoCommentDigest {
  static const int song = 15;
  static const int rank = 2;
  static const int mv = 7;
  static const int playlist = 8;
}

/// 酷我评论接口。
abstract final class KuwoCommentApi {
  static const String baseUrl = 'http://comment.kuwo.cn/com.s';

  static final Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.bytes,
  ));

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 15; V2453A Build/AP3A.240905.015.A2_V000L1) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.7390.5 Mobile Safari/537.36',
    'Referer': 'http://www.kuwo.cn/',
  };

  /// 读一页评论。
  ///
  /// [hot] 为 true 取最热（get_rec_comment），false 取最新（get_comment）。
  /// [page] 从 1 开始。返回的 [CommentPage.latest] 装本页评论，
  /// [CommentPage.hot] 恒为空（调用方按需分桶）。
  static Future<CommentPage> getComments(
    String rid, {
    bool hot = false,
    int page = 1,
    int rows = 20,
  }) async {
    final url = '$baseUrl?type=${hot ? 'get_rec_comment' : 'get_comment'}'
        '&uid=0&prod=newWeb&digest=${KuwoCommentDigest.song}'
        '&sid=$rid&page=$page&rows=$rows&f=web';
    final resp = await dio.get<List<int>>(url,
        options: Options(responseType: ResponseType.bytes, headers: _headers));
    final body = _decode(resp.data ?? const []);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('酷我评论返回格式不正确');
    }
    final page0 = parseCommentPage(decoded);
    AppLog.i('KuwoCommentApi',
        '酷我评论 rid=$rid ${hot ? "最热" : "最新"} 第 $page 页：${page0.latest.length} 条');
    return page0;
  }

  /// 最热评论（免登录）。
  static Future<CommentPage> getHotComments(String rid,
          {int page = 1, int rows = 20}) =>
      getComments(rid, hot: true, page: page, rows: rows);

  /// 最新评论（免登录）。
  static Future<CommentPage> getLatestComments(String rid,
          {int page = 1, int rows = 20}) =>
      getComments(rid, hot: false, page: page, rows: rows);

  // ==================== App 富读（ncomment f=web，内嵌楼中楼） ====================

  /// App 私有主列表（免登录）：`ncomment.kuwo.cn/com.s?f=web`。
  ///
  /// 与 [getComments] 的差别：
  ///   - 评论条目内嵌 `child_comments[]`（楼中楼首页）与
  ///     `child_comment_count`，解析后填进 [Comment.replies] /
  ///     [Comment.replyCount]；
  ///   - `time` 是秒级时间戳（数字或数字串）；
  ///   - 分页是 offset 式（[start]/[count]），不是 page/rows。
  ///
  /// [hot] 为 true 取最热桶（`get_rec_comment`），false 取最新桶
  /// （`get_comment`）——两个桶各需一次请求，与 [getComments] 同。
  static Future<CommentPage> getFeed(
    String rid, {
    bool hot = false,
    int start = 0,
    int count = 20,
  }) async {
    final url = 'http://ncomment.kuwo.cn/com.s?f=web'
        '&type=${hot ? 'get_rec_comment' : 'get_comment'}'
        '&aapiver=1&prod=kwplayer_ar_10.5.2.0&digest=${KuwoCommentDigest.song}'
        '&sid=$rid&start=$start&msgflag=1&count=$count&newver=3&uid=0';
    final resp = await dio.get<List<int>>(url,
        options: Options(responseType: ResponseType.bytes, headers: _headers));
    final body = _decode(resp.data ?? const []);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('酷我评论返回格式不正确');
    }
    final page0 = parseFeedPage(decoded, hot: hot, start: start, count: count);
    AppLog.i('KuwoCommentApi',
        '酷我评论（富） rid=$rid ${hot ? "最热" : "最新"} start=$start：'
        '${page0.latest.length + page0.hot.length} 条');
    return page0;
  }

  /// 解析 App 富读响应。
  ///
  /// 真实样本（get_rec_comment）：
  /// ```json
  /// {"code":"200","result":"ok","comments":[],"comments_counts":1260,
  ///  "hot_comments":[{…,"child_comment_count":169,
  ///    "child_comments":[{…},{…}],"time":1578730157,"is_like":false}],
  ///  "hot_comments_counts":20,"top_comments":[],"collapsed_counts":2}
  /// ```
  static CommentPage parseFeedPage(
    Map<String, dynamic> json, {
    bool hot = false,
    int start = 0,
    int count = 20,
  }) {
    final bucket = hot ? 'hot_comments' : 'comments';
    final raw = json[bucket];
    final items = raw is List ? raw : const [];
    final comments = <Comment>[];
    for (final item in items) {
      if (item is Map) {
        comments.add(parseComment(Map<String, dynamic>.from(item)));
      }
    }
    // top_comments（置顶）并入最热桶，按 id 去重
    if (hot) {
      final top = json['top_comments'];
      if (top is List) {
        final seen = comments.map((c) => c.id).toSet();
        for (final item in top) {
          if (item is! Map) continue;
          final c = parseComment(Map<String, dynamic>.from(item));
          if (seen.add(c.id)) comments.insert(0, c);
        }
      }
    }
    // 总数：最热桶用 hot_comments_counts，最新桶用 comments_counts
    final total = _toInt(json['${hot ? 'hot_comments' : 'comments'}_counts']);
    var hasMore = comments.length >= count;
    if (total > 0) hasMore = start + comments.length < total;
    return CommentPage(
      hot: hot ? comments : const [],
      latest: hot ? const [] : comments,
      total: total > 0 ? total : comments.length,
      hasMore: hasMore,
    );
  }

  // ==================== 纯函数（可单测，样本为真实抓包） ====================

  /// 解析评论列表响应。
  ///
  /// 响应形如：
  /// ```json
  /// {"result":"ok","comment_tpye":"hot","currentPage":1,"pageSize":20,
  ///  "total":50,"t_total":1743,"totalPage":25,"rows":[ … ]}
  /// ```
  static CommentPage parseCommentPage(Map<String, dynamic> json) {
    final raw = json['rows'];
    final items = raw is List ? raw : const [];
    final comments = <Comment>[];
    for (final item in items) {
      if (item is Map) {
        comments.add(parseComment(Map<String, dynamic>.from(item)));
      }
    }
    final current = _toInt(json['currentPage']);
    final totalPage = _toInt(json['totalPage']);
    return CommentPage(
      latest: comments,
      // 热评列表用 total，歌曲总评论数用 t_total
      total: _toInt(json['total']),
      hasMore: current > 0 && totalPage > 0 && current < totalPage,
    );
  }

  /// 解析单条评论（Web 读与 App 富读两种形态通吃）。
  ///
  /// 真实样本（Web 最热第一条）：
  /// ```json
  /// {"id":"647495065","msg":"如果你们遇到一个叫张燕的女孩…",
  ///  "u_id":"501214651","u_name":"健康一直都在jk",
  ///  "u_pic":"http://img4.kuwo.cn/star/userhead/…",
  ///  "time":"2020-01-11 16:09:17","like_num":"1940","is_like":"false"}
  /// ```
  /// App 富读形态（`time` 秒级时间戳、`is_like` bool）额外带：
  /// ```json
  /// "child_comment_count":169,"child_comments":[{…},{…}]
  /// ```
  static Comment parseComment(Map<String, dynamic> json) {
    final children = <Comment>[];
    final rawChildren = json['child_comments'];
    if (rawChildren is List) {
      for (final item in rawChildren) {
        if (item is Map) {
          children.add(parseComment(Map<String, dynamic>.from(item)));
        }
      }
    }
    return Comment(
      id: (json['id'] ?? '').toString(),
      nickname: (json['u_name'] ?? '').toString(),
      avatarUrl: (json['u_pic'] ?? '').toString(),
      content: (json['msg'] ?? '').toString(),
      timeMs: parseKuwoTime(json['time']),
      likeCount: _toInt(json['like_num']),
      liked: (json['is_like'] ?? '').toString() == 'true',
      replyCount: _toInt(json['child_comment_count']),
      isHot: false,
      replies: children,
    );
  }

  /// 解析酷我的时间字段 → 毫秒时间戳。
  ///
  /// 三种形态都见过（真实抓包）：
  ///   - Web 读：`"2020-01-11 16:09:17"` 字符串；
  ///   - App 富读：`1578730157` 数字（秒）；
  ///   - App 写接口回显：`"1792855316"` 数字串（秒）。
  /// 解析不了返回 0（UI 不显示时间）。
  static int parseKuwoTime(dynamic raw) {
    if (raw is num) return raw.toInt() * 1000;
    final s = raw?.toString().trim() ?? '';
    if (s.isEmpty) return 0;
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
        .firstMatch(s);
    if (m != null) {
      final dt = DateTime.utc(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
        int.parse(m.group(6)!),
      );
      return dt.millisecondsSinceEpoch;
    }
    // 秒级时间戳（数字串）
    final secs = int.tryParse(s);
    return secs == null ? 0 : secs * 1000;
  }

  // ==================== 工具 ====================

  /// 响应体解码：优先 UTF-8，失败退 GBK（酷我部分接口仍是 GBK，
  /// 与 [kuwo_api.dart] 的搜索接口同一套处理）。
  static String _decode(List<int> bytes) => decodeMaybeGbk(bytes);

  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

/// 酷我评论写接口（发表 / 回复 / 点赞 / 楼中楼），App 私有 `f=ar` 协议。
///
/// 全部需要登录态（[KuwoAuth.session]）；协议形制见文件头「③」。
abstract final class KuwoCommentWriteApi {
  /// 发表主机（POST）。
  static const String postHost = 'http://ncommentw.kuwo.cn/com.s';

  /// 点赞 / 楼中楼主机（GET）。
  static const String likeHost = 'http://ncomment.kuwo.cn/com.s';

  /// 与倾听 5.5.0.2 逆向一致的客户端标识（评论协议专用，
  /// 与登录协议的 clientVersion 是两套，勿混用）。
  static const String _prod = 'kwplayer_ar_12.1.8.2';
  static const String _source = '${_prod}_hw.apk';
  static const String _dalvikUa =
      'Dalvik/2.1.0 (Linux; U; Android 10; HLK-AL00a Build/HONORHLK-AL00a)';
  static const String _chromeUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.plain,
  ));

  /// 测试注入点：整体替换 [dio]（离线单测用，见
  /// test/kuwo_comment_write_test.dart；正式代码勿动）。

  /// 发表评论（或回复）。
  ///
  /// [replyId] 非空 = 回复某条评论（楼中楼），此时 [parentId] 应传该
  /// 评论所在楼层的根评论 id（一级回复时两者相同）。
  /// 成功返回服务端回显信息；失败抛 [Exception]（消息取自服务端 msg）。
  static Future<String> postComment({
    required String rid,
    required String content,
    String? replyId,
    String? parentId,
  }) async {
    final session = KuwoAuth.session;
    if (session == null || !session.isValid) {
      throw Exception('请先登录酷我音乐账号');
    }
    final text = content.trim();
    if (text.isEmpty) throw Exception('评论内容不能为空');
    final dev = await KuwoAuth.device();
    final sx = KuwoCipher.newResponseKey();
    final q = StringBuffer('type=post_comment')
      ..write('&prod=$_prod&deviceId=${dev.deviceUser}&source=$_source')
      ..write('&sesID=${session.sid}&uid=${session.uid}')
      ..write('&digest=${KuwoCommentDigest.song}&sx=$sx&sid=$rid&msgflag=1');
    if (replyId != null && replyId.isNotEmpty) q.write('&reply=$replyId');
    if (parentId != null && parentId.isNotEmpty) q.write('&pcid=$parentId');
    q.write('&aapiver=1&newver=3');
    // msg 走 body（UTF-8 裸字节），`&` 先换全角，避免被当成参数分隔
    final body = utf8.encode(text.replaceAll('&', '＆'));
    final resp = await dio.post<String>(
      '$postHost?f=ar&q=${KuwoCipher.sealQuery(q.toString())}',
      data: body,
      options: Options(
        contentType: 'application/octet-stream',
        headers: {'User-Agent': _dalvikUa},
      ),
    );
    final json = _openJson(resp.data ?? '', sx);
    final code = (json['code'] ?? '').toString();
    if (code != '200') {
      final msg = (json['msg'] ?? '').toString();
      throw Exception(msg.isEmpty ? '评论发表失败（code=$code）' : msg);
    }
    final msg = (json['msg'] ?? '').toString();
    AppLog.i('KuwoCommentWriteApi', '酷我评论发表成功 rid=$rid');
    return msg.isEmpty ? '评论发表成功' : msg;
  }

  /// 点赞 / 取消点赞。返回服务端回显的新赞数。
  static Future<int> likeComment({
    required String rid,
    required String commentId,
    String? parentId,
    required bool like,
  }) async {
    final session = KuwoAuth.session;
    if (session == null || !session.isValid) {
      throw Exception('请先登录酷我音乐账号');
    }
    final dev = await KuwoAuth.device();
    final sx = KuwoCipher.newResponseKey();
    final q = StringBuffer('type=${like ? 'click_like' : 'cancel_like'}')
      ..write('&prod=$_prod&deviceId=${dev.deviceUser}&source=$_source')
      ..write('&sesID=${session.sid}&sid=$rid')
      ..write('&digest=${KuwoCommentDigest.song}&sx=$sx&uid=${session.uid}')
      ..write('&cid=$commentId&msgflag=1&aapiver=1');
    if (parentId != null && parentId.isNotEmpty) q.write('&pcid=$parentId');
    q.write('&newver=3');
    final resp = await dio.get<String>(
      '$likeHost?f=ar&q=${KuwoCipher.sealQuery(q.toString())}',
      options: Options(headers: {'User-Agent': _dalvikUa}),
    );
    final json = _openJson(resp.data ?? '', sx);
    if (!json.containsKey('like')) {
      final msg = (json['msg'] ?? '').toString();
      throw Exception(msg.isEmpty ? '点赞失败' : msg);
    }
    return KuwoCommentApi._toInt(json['like']);
  }

  /// 读楼中楼（免登录）。
  ///
  /// [page] 从 1 起，[pageSize] 默认 20。返回回复列表（不含父评论，
  /// 父评论信息在响应的 `main_comment` 里，调用方一般不需要）。
  static Future<List<Comment>> getChildComments({
    required String rid,
    required String parentId,
    int page = 1,
    int pageSize = 20,
  }) async {
    final dev = await KuwoAuth.device();
    final sx = KuwoCipher.newResponseKey();
    final start = (page - 1) * pageSize;
    final q = 'type=get_child_comment&prod=$_prod'
        '&deviceId=${dev.deviceUser}&source=$_source&sesID=&uid=0'
        '&sx=$sx&digest=${KuwoCommentDigest.song}&sid=$rid'
        '&start=$start&msgflag=1&count=$pageSize'
        '&aapiver=1&pcid=$parentId&newver=3';
    final resp = await dio.get<String>(
      '$likeHost?f=ar&q=${KuwoCipher.sealQuery(q)}',
      options: Options(headers: {'User-Agent': _chromeUa}),
    );
    final json = _openJson(resp.data ?? '', sx);
    final ok = (json['result'] ?? '').toString() == 'ok' ||
        (json['code'] ?? '').toString() == '200';
    if (!ok) return const [];
    final raw = json['comments'];
    final items = raw is List ? raw : const [];
    final comments = <Comment>[];
    for (final item in items) {
      if (item is Map) {
        comments.add(KuwoCommentApi.parseComment(
            Map<String, dynamic>.from(item)));
      }
    }
    return comments;
  }

  /// 解密 `f=ar` 响应体 → JSON。失败抛 [FormatException]。
  static Map<String, dynamic> _openJson(String body, String sx) {
    final text = KuwoCipher.openResponse(body, sx);
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('酷我评论响应格式不正确');
    }
    return decoded;
  }
}
