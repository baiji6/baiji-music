// 网易云歌曲评论。
//
// 端点全部经沙箱实测（2025-10，歌曲 657666《起风了》；2026-10-19 weapi 化
// 改造后复测），与倾听 5.4.14 dex 里的端点路径一致：
//
// - 读评论（免登录，明文 GET 仍有效）：
//   GET https://music.163.com/api/v1/resource/comments/R_SO_4_{songId}
//       ?limit=15&offset=0
//   响应 code:200 + total/more/hotComments[]/comments[]/topComments[]；
//   单条字段 commentId/content/time(毫秒)/likedCount/liked/
//   user.{userId,nickname,avatarUrl}/beReplied[]。
// - 发评 / 回复 / 点赞 / 删除（需登录，**必须 weapi**）：
//   POST https://music.163.com/weapi/resource/comments/add?csrf_token=X
//   POST https://music.163.com/weapi/resource/comments/reply?csrf_token=X
//   POST https://music.163.com/weapi/v1/comment/like?csrf_token=X
//   POST https://music.163.com/weapi/v1/comment/unlike?csrf_token=X
//   表单 {params, encSecKey}（AES 双层 + RSA，见 netease/netease_weapi.dart）。
//
// **「250 风控」是误判（v2.3.0-fix5 纠正）**：用户反馈「网易云能打开不能
// 发评论」，v2.3.0-fix3 按 250 归因为账号级风控。复测发现真正的失败码是
// **400「参数错误」**——明文 `/api/resource/comments/add` 这个写接口形态
// 已被网易云废弃，带完整浏览器 Cookie 也一样 400，与账号/频率无关。
// 换成网页版同款 `/weapi` + 加密体后，同一账号同一 Cookie 立即 code=200
// （已实测：Dart 加密发评→删评、点赞→取消点赞均 200，测试评论已删除）。
// 250 仍然保留为兜底文案：weapi 形态下频繁操作依然可能触发真风控。
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

  /// 从 Cookie 串取 csrf（写接口的 csrf_token 表单值）。
  ///
  /// 浏览器粘贴的 Cookie 字段名是 `__csrf`；扫码登录 Set-Cookie 下发的
  /// 字段名是 `__csrf_token`（v2.3.0-fix6 起两者都认，扫码用户不再空 csrf）。
  static String csrfFromCookie(String cookie) {
    final map = <String, String>{};
    NeteaseClient.parseCookie(cookie, map);
    return map['__csrf'] ?? map['__csrf_token'] ?? '';
  }

  /// 写操作前把会话补齐到浏览器形态（v2.3.0-fix6，250 风控缓解）。
  ///
  /// 粘贴 Cookie 登录不会跑 [NeteaseClient.enrichCookie]（只有扫码登录
  /// 会跑），若用户只粘了 MUSIC_U 等登录字段，会话缺 NMTID/_ntes_nuid
  /// 等浏览器字段——服务端风控对「带登录态却毫无会话痕迹」的写请求
  /// 评分很高（表现即 code=250）。已含 NMTID 说明是完整浏览器会话，
  /// 直接跳过；补齐限时 3 秒，失败不阻塞发送。
  static Future<void> _ensureSession() async {
    final client = AppServices.instance.netease;
    if (client.cookie.contains('NMTID=')) return;
    try {
      await client.enrichCookie().timeout(const Duration(seconds: 3));
    } catch (_) {
      // 补齐失败不阻塞发送
    }
  }

  /// 从响应里提取服务端消息（250 等失败码的原文，便于远程诊断）。
  static String? _serverMessage(Map<String, dynamic> data) {
    for (final k in const ['message', 'msg', 'debugInfo']) {
      final v = data[k];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString();
    }
    return null;
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

  /// 发表评论（需登录）。[replyTo] 非空 = 回复某条评论。
  ///
  /// 走 weapi 加密通道（明文 /api 写接口已废弃，恒定 400，见文件头）。
  /// [NeteaseClient.postWeapi] 负责 AES 双层加密；csrf_token 同时出现在
  /// URL query 与 payload 里（网页端两个位置都带，少任何一个都 400）。
  static Future<void> addComment(String songId, String content,
      {String? replyTo}) async {
    final client = AppServices.instance.netease;
    if (!client.isLoggedIn()) {
      throw Exception('登录后可发表评论');
    }
    await _ensureSession();
    final csrf = csrfFromCookie(client.cookie);
    // 回复走专用端点（commentId = 被回复评论 id），顶层评论走 add
    final isReply = replyTo != null && replyTo.isNotEmpty;
    final payload = <String, dynamic>{
      'threadId': threadId(songId),
      'content': content,
      'csrf_token': csrf,
      if (isReply) 'commentId': replyTo,
    };
    final url = 'https://music.163.com/weapi/resource/comments/'
        '${isReply ? 'reply' : 'add'}';
    final data = await client.postWeapi(url, payload, csrf: csrf);
    final code = _toInt(data['code']);
    final serverMsg = _serverMessage(data);
    if (code == 250) {
      // weapi 形态下仍可能触发真风控（账号/设备指纹/频率评分）。
      // v2.3.0-fix6 起请求指纹已对齐真浏览器并发送前补齐会话字段，
      // 仍 250 多为账号近期被反复失败请求拉高了风控分，等待后会回落。
      throw Exception(
          '网易云风控拦截（250${serverMsg == null ? '' : '：$serverMsg'}）：'
          '请过几分钟再试；若持续出现，请到登录页重新粘贴完整的浏览器 '
          'Cookie（F12 → 网络 → 任意 music.163.com 请求 → 复制整段 Cookie）');
    }
    if (code != 200) {
      throw Exception(
          '发表评论失败（$code${serverMsg == null ? '' : '：$serverMsg'}）');
    }
    AppLog.i('NeteaseCommentApi', '发表评论成功 song=$songId');
  }

  /// 点赞 / 取消点赞（需登录）。weapi POST，与网页版一致。
  static Future<void> likeComment(String songId, String commentId,
      {required bool like}) async {
    final client = AppServices.instance.netease;
    if (!client.isLoggedIn()) {
      throw Exception('登录后可点赞');
    }
    await _ensureSession();
    final csrf = csrfFromCookie(client.cookie);
    final url = 'https://music.163.com/weapi/v1/comment/'
        '${like ? 'like' : 'unlike'}';
    final data = await client.postWeapi(url, {
      'threadId': threadId(songId),
      'commentId': commentId,
      'csrf_token': csrf,
    }, csrf: csrf);
    final code = _toInt(data['code']);
    final serverMsg = _serverMessage(data);
    if (code == 250) {
      throw Exception(
          '网易云风控拦截（250${serverMsg == null ? '' : '：$serverMsg'}）：'
          '请过几分钟再试');
    }
    if (code != 200) {
      throw Exception(
          '${like ? "点赞" : "取消点赞"}失败'
          '（$code${serverMsg == null ? '' : '：$serverMsg'}）');
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
