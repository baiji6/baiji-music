// 酷我音乐歌曲评论（comment.kuwo.cn 公开 web 接口）。
//
// 端点与参数全部沙箱实测（2026-10，歌曲 rid=80958029）：
//
//   最热  GET http://comment.kuwo.cn/com.s?type=get_rec_comment&uid=0
//              &prod=newWeb&digest=15&sid=<rid>&page=1&rows=N&f=web
//   最新  GET 同上，type=get_comment
//
// 要点：
//   - 歌曲 id 必须放 **sid**（不是 rid），`uid=0` + `prod=newWeb` + `digest=15`
//     缺一不可（缺了返回 code=600「评论失败」）；
//   - `page` 从 1 开始；`digest` 15=歌曲 2=排行榜 7=mv 8=歌单；
//   - 响应 `rows[]` 每条含 `id/msg/u_id/u_name/u_pic/time/like_num/is_like`
//     等字段，`time` 是 `"2020-01-11 16:09:17"` 形态的字符串；
//   - `total` 是当前列表（热评/最新）的总数，`t_total` 是歌曲评论总数。
//
// **发表评论不可用**：`type=post_comment` 在该主机上 `f=web` 一律
// code=600「评论失败」、`f=ar` 一律 604（沙箱内穷举过参数名 / 主机 /
// DES 密封 / 元数据头；公开生态如 feeluown-kuwo 也只有读取实现）。
// 因此本 App 对酷我只提供评论**阅读**，UI 上明确告知用户，
// 不放假按钮。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../models/models.dart';
import 'kuwo_api.dart';

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

  static final Dio _dio = Dio(BaseOptions(
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
    final resp = await _dio.get<List<int>>(url,
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

  /// 解析单条评论。
  ///
  /// 真实样本（rid=80958029 最热第一条）：
  /// ```json
  /// {"id":"647495065","msg":"如果你们遇到一个叫张燕的女孩…",
  ///  "u_id":"501214651","u_name":"健康一直都在jk",
  ///  "u_pic":"http://img4.kuwo.cn/star/userhead/…",
  ///  "time":"2020-01-11 16:09:17","like_num":"1940","is_like":"false"}
  /// ```
  static Comment parseComment(Map<String, dynamic> json) => Comment(
        id: (json['id'] ?? '').toString(),
        nickname: (json['u_name'] ?? '').toString(),
        avatarUrl: (json['u_pic'] ?? '').toString(),
        content: (json['msg'] ?? '').toString(),
        timeMs: parseKuwoTime(json['time']?.toString() ?? ''),
        likeCount: _toInt(json['like_num']),
        liked: (json['is_like'] ?? '').toString() == 'true',
        // 酷我不公开楼中楼回复数；有回复结构的接口未开放（见文件头）
        replyCount: 0,
        isHot: false,
      );

  /// 解析酷我的 `"2020-01-11 16:09:17"` 时间串 → 毫秒时间戳。
  ///
  /// 解析不了返回 0（UI 不显示时间）。
  static int parseKuwoTime(String raw) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
        .firstMatch(raw.trim());
    if (m == null) return 0;
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
