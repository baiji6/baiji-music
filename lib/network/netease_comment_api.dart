// 网易云歌曲评论。
//
// 端点全部经沙箱实测（2025-10，歌曲 657666《起风了》），与倾听 5.4.14
// dex 里的端点一致（`/api/resource/comments/add|reply`、`/api/v1/comment/
// like|unlike`）：
//
// - 读评论（免登录）：
//   GET https://music.163.com/api/v1/resource/comments/R_SO_4_{songId}
//       ?limit=15&offset=0
//   响应 code:200 + total/more/hotComments[]/comments[]/topComments[]；
//   单条字段 commentId/content/time(毫秒)/likedCount/liked/
//   user.{userId,nickname,avatarUrl}/beReplied[]。
// - 发评（需登录）：
//   POST https://music.163.com/api/resource/comments/add
//   表单 {threadId, content, csrf_token}（注意是表单编码，不是 JSON：
//   JSON body 会 400 参数错误）。
// - 回复（需登录）：
//   POST https://music.163.com/api/resource/comments/reply
//   表单 {threadId, content, commentId, csrf_token}。
//   （缺 commentId → 400 参数错误；齐全 → 301 需登录，形制正确。）
// - 点赞 / 取消（需登录）：
//   GET https://music.163.com/api/v1/comment/like?threadId=&commentId=&csrf_token=
//   GET https://music.163.com/api/v1/comment/unlike?...
//   （无参 → 400、带参 → 301；不存在路径 → 404，路由确认。）
//
// **写接口 250 = 网易云账号级风控**（2026-10-18 复现用户反馈）：
// 用户真机首次发评即 250（登录态为扫码登录的最小 Cookie）。沙箱对照
// 实验：完整浏览器 Cookie（24 字段）→ 200；但连续发评十余条后，
// 完整 Cookie 的点赞/发评也全部 250——即 250 一旦触发就是账号级
// 写限流，与 Cookie 完整性弱相关，需等待冷却。app 侧缓解：
// - 扫码登录后 [NeteaseClient.enrichCookie] 补 NMTID 等会话字段；
// - 250 文案引导「稍后再试」而非裸错误码；
// - 设置页支持手动粘贴完整浏览器 Cookie 登录（逃生门）。
import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:baiji_music/network/netease/netease_client.dart';

/// 网易云歌曲评论。
abstract final class NeteaseCommentApi {
  // ================= 纯函数（可单测，样本为真实抓包） =================

  /// 歌曲评论 threadId（`R_SO_4_` 前缀 = 歌曲）。
  static String threadId(String songId) => 'R_SO_4_$songId';

  /// 解析 `/api/v1/resource/comments/R_SO_4_{songId}` 响应。
  ///
  /// 热评放 [CommentPage.hot]（置顶评 topComments 并入），最新评放
  /// [CommentPage.latest]；[CommentPage.hasMore] 取自响应的 `more`。
  static CommentPage parseComments(Map<String, dynamic> json) {
    final hot = <Comment>[];
    final latest = <Comment>[];
    for (final item in _list(json['hotComments'])) {
      hot.add(parseComment(item, isHot: true));
    }
    // 置顶评与热评同属"热门"区，并入 hot 桶
    for (final item in _list(json['topComments'])) {
      hot.add(parseComment(item, isHot: true));
    }
    for (final item in _list(json['comments'])) {
      latest.add(parseComment(item));
    }
    return CommentPage(
      hot: hot,
      latest: latest,
      total: _toInt(json['total']),
      hasMore: json['more'] == true,
    );
  }

  /// 解析单条评论（含 beReplied 回复）。
  static Comment parseComment(Map<String, dynamic> json, {bool isHot = false}) {
    final user = json['user'];
    final replies = <Comment>[];
    for (final r in _list(json['beReplied'])) {
      final ru = r['user'];
      replies.add(Comment(
        // beReplied 里没有 commentId，只有 beRepliedCommentId（UI 不展示 id）
        id: r['beRepliedCommentId']?.toString() ?? '',
        nickname: ru is Map ? (ru['nickname']?.toString() ?? '') : '',
        avatarUrl: ru is Map ? (ru['avatarUrl']?.toString() ?? '') : '',
        content: r['content']?.toString() ?? '',
        timeMs: 0, // 回复项没有 time，UI 不显示时间
      ));
    }
    return Comment(
      id: json['commentId']?.toString() ?? '',
      nickname: user is Map ? (user['nickname']?.toString() ?? '') : '',
      avatarUrl: user is Map ? (user['avatarUrl']?.toString() ?? '') : '',
      content: json['content']?.toString() ?? '',
      // time 是毫秒时间戳，直接用（QQ 那边是秒，解析时已 ×1000）
      timeMs: _toInt(json['time']),
      likeCount: _toInt(json['likedCount']),
      liked: json['liked'] == true,
      // v1 接口没有单独回复计数字段，用 beReplied 长度
      replyCount: replies.length,
      isHot: isHot,
      replies: replies,
    );
  }

  /// 从 Cookie 串取 `__csrf`（写接口的 csrf_token 表单值）。
  ///
  /// 登录态 Cookie 由扫码/手动登录保存，`__csrf` 是网易云登录时下发的。
  static String csrfFromCookie(String cookie) {
    final map = <String, String>{};
    NeteaseClient.parseCookie(cookie, map);
    return map['__csrf'] ?? '';
  }

  // ================= 网络 =================

  /// 读取歌曲评论（免登录）。[offset] 按 [limit] 步进翻页。
  static Future<CommentPage> getComments(
    String songId, {
    int limit = 15,
    int offset = 0,
  }) async {
    final url = '${NeteaseClient.apiBase}/v1/resource/comments/'
        '${threadId(songId)}?limit=$limit&offset=$offset';
    final data = await AppServices.instance.netease.getApi(url);
    final code = _toInt(data['code']);
    if (code != 200) {
      throw Exception('获取评论失败（$code）');
    }
    return parseComments(data);
  }

  /// 发表评论（需登录）。
  static Future<void> addComment(String songId, String content,
      {String? replyTo}) async {
    final client = AppServices.instance.netease;
    if (!client.isLoggedIn()) {
      throw Exception('登录后可发表评论');
    }
    // 回复走专用端点（commentId = 被回复评论 id），顶层评论走 add
    final isReply = replyTo != null && replyTo.isNotEmpty;
    final form = <String, String>{
      'threadId': threadId(songId),
      'content': content,
      'csrf_token': csrfFromCookie(client.cookie),
    };
    final String url;
    if (isReply) {
      form['commentId'] = replyTo;
      url = 'https://music.163.com/api/resource/comments/reply';
    } else {
      url = 'https://music.163.com/api/resource/comments/add';
    }
    final data = await client.postApi(url, form);
    final code = _toInt(data['code']);
    if (code == 250) {
      // 250 = 网易云风控（频率/会话异常）。完整浏览器 Cookie 下偶发，
      // 频繁发送必中；文案引导用户稍后再试，避免裸错误码。
      throw Exception('发送过于频繁或被网易云风控，请稍后再试');
    }
    if (code != 200) {
      throw Exception('发表评论失败（$code）');
    }
    AppLog.i('NeteaseCommentApi', '发表评论成功 song=$songId');
  }

  /// 点赞 / 取消点赞（需登录）。
  static Future<void> likeComment(String songId, String commentId,
      {required bool like}) async {
    final client = AppServices.instance.netease;
    if (!client.isLoggedIn()) {
      throw Exception('登录后可点赞');
    }
    final csrf = csrfFromCookie(client.cookie);
    final url = 'https://music.163.com/api/v1/comment/'
        '${like ? 'like' : 'unlike'}'
        '?threadId=${threadId(songId)}&commentId=$commentId&csrf_token=$csrf';
    final data = await client.getApi(url);
    final code = _toInt(data['code']);
    if (code == 250) {
      throw Exception('操作过于频繁或被网易云风控，请稍后再试');
    }
    if (code != 200) {
      throw Exception('${like ? "点赞" : "取消点赞"}失败（$code）');
    }
    AppLog.i('NeteaseCommentApi', '${like ? "点赞" : "取消点赞"}成功 cmt=$commentId');
  }

  static List<Map<String, dynamic>> _list(dynamic v) {
    if (v is! List) return const [];
    return v.whereType<Map<String, dynamic>>().toList();
  }

  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}
