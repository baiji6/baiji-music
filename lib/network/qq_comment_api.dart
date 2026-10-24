// QQ 音乐歌曲评论（musicu.fcg globalComment 模块族）。
//
// 端点全部经沙箱实测（2025-10，歌曲 108478《失踪》）：
//
// - 读热评：music.globalComment.CommentRead/GetHotCommentList（免登录）
// - 读最新：music.globalComment.CommentRead/GetNewCommentList（免登录）
// - 评论数：music.globalComment.CommentCountSrv/GetCmCount（免登录）
// - 发评：music.globalComment.CommentWriteServer/AddComment（需登录，
//   未登录返回 code=1000）
// - 点赞：music.globalComment.CommentWrite/PraiseComment（需登录，
//   未登录返回 code=1000）
//
// **BizId 必须传数字 songid，不能传 mid**（2026-10-18 复现用户反馈）：
// 传 mid 时 GetHotCommentList/GetNewCommentList 返回 code=10000
// （AllowComment=0），登录与否都一样；传数字 songid 才正常返回。
// 沙箱首次实测用的就是数字 id，所以没暴露；真机从播放页进来时
// Song.mid 被当成 BizId，遂 10000。
//
// 与 H5 接口（c.y.qq.com fcg_global_comment_h5.fcg）二选一，这里走
// musicu：复用现成的 QQMusicClient.executeRaw，不额外引入 HTTP 客户端，
// 且响应里的 SubComments 直接带回复结构。
import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:baiji_music/network/qq_music_client.dart';

/// 评论业务类型（对应 CommentBizType，歌曲 = 1）。
abstract final class QqCommentBizType {
  static const int song = 1;
  static const int album = 2;
  static const int playlist = 3;
  static const int mv = 4;
}

/// 发表评论被风控拦截（code=10009）。
///
/// 2026-10-25 真机 cookie 实测：这个码**不是普通失败**——响应里带着
/// `AddedCmId`（评论已记录，但不展示，State=0）、`HitType/HitReason`
/// 和一个 `VerifyUrl`（安全验证页）。完成一次验证后账号解除拦截，
/// 后续发表恢复正常。
///
/// 所以 UI 层拿到它应该弹「去验证」，而不是当失败报错。
class QqCommentVerifyRequired implements Exception {
  QqCommentVerifyRequired(this.verifyUrl);

  /// 安全验证页（滑块/验证码），用外部浏览器打开。
  final String verifyUrl;

  @override
  String toString() => '评论需要安全验证';
}

/// QQ 音乐评论。
abstract final class QqCommentApi {
  // ================= 纯函数（可单测，样本为真实抓包） =================

  /// 解析 GetHotCommentList / GetNewCommentList 响应。
  ///
  /// 响应结构（实测）：
  /// `data.CommentList.Comments[]` + `data.CommentList.{HasMore,Total}`，
  /// 单条字段 `CmId/Nick/Avatar/Content/PubTime(秒)/PraiseNum/IsPraised/
  /// ReplyCnt/SubComments[]`。
  ///
  /// 兼容两种入参形状：业务 data 层（`{CommentList: ...}`，单测样本即此）
  /// 或 `executeRaw` 返回的完整 req_0（`{code, msg, data: {CommentList}}`）——
  /// 后者会自动剥一层，防止网络层漏剥导致评论静默变空
  /// （2026-10-18 live 实测复现：code=0 但 total=0）。
  ///
  /// 返回的评论统一放在 [CommentPage.latest]；调用方按读取的是热评还是
  /// 最新评放入对应分桶（见 [getHotComments] / [getNewComments]）。
  static CommentPage parseCommentList(Map<String, dynamic> data) {
    final biz = _bizLayer(data);
    final list = biz['CommentList'];
    if (list is! Map<String, dynamic>) {
      return const CommentPage();
    }
    final raw = list['Comments'];
    final items = raw is List ? raw : const [];
    final comments = <Comment>[];
    for (final item in items) {
      if (item is Map<String, dynamic>) {
        comments.add(parseComment(item));
      }
    }
    return CommentPage(
      latest: comments,
      total: _toInt(list['Total']),
      hasMore: _toInt(list['HasMore']) == 1,
    );
  }

  /// 取出业务 data 层：已是业务层则原样返回；若是完整 req_0
  /// （`{code, msg, data}`）则剥出 `data`。
  static Map<String, dynamic> _bizLayer(Map<String, dynamic> data) {
    final inner = data['data'];
    if (inner is Map<String, dynamic> &&
        (inner.containsKey('CommentList') || inner.containsKey('response'))) {
      return inner;
    }
    return data;
  }

  /// 解析单条评论（含 SubComments 子评论）。
  static Comment parseComment(Map<String, dynamic> json) {
    final subs = <Comment>[];
    final rawSubs = json['SubComments'];
    if (rawSubs is List) {
      for (final s in rawSubs) {
        if (s is Map<String, dynamic>) {
          subs.add(Comment(
            id: s['CmId']?.toString() ?? '',
            nickname: s['Nick']?.toString() ?? '',
            avatarUrl: s['Avatar']?.toString() ?? '',
            content: s['Content']?.toString() ?? '',
            // 子评论没有 PubTime 时退化为 0，UI 不显示时间
            timeMs: _toInt(s['PubTime']) * 1000,
            likeCount: _toInt(s['PraiseNum']),
            liked: _toInt(s['IsPraised']) == 1,
          ));
        }
      }
    }
    return Comment(
      id: json['CmId']?.toString() ?? '',
      nickname: json['Nick']?.toString() ?? '',
      avatarUrl: json['Avatar']?.toString() ?? '',
      content: json['Content']?.toString() ?? '',
      timeMs: _toInt(json['PubTime']) * 1000,
      likeCount: _toInt(json['PraiseNum']),
      liked: _toInt(json['IsPraised']) == 1,
      replyCount: _toInt(json['ReplyCnt']),
      isHot: _toInt(json['HotScore']) > 0 || _toInt(json['IsHot']) == 1,
      replies: subs,
    );
  }

  /// 解析 GetCmCount 响应：`data.response.count`。
  static int parseCommentCount(Map<String, dynamic> data) {
    final resp = _bizLayer(data)['response'];
    if (resp is Map<String, dynamic>) {
      return _toInt(resp['count']);
    }
    return 0;
  }

  // ================= 网络 =================

  /// 读取歌曲热评（免登录）。
  ///
  /// [songId] 必须是**数字 songid**（不是 mid，见文件头说明）。
  static Future<CommentPage> getHotComments(
    String songId, {
    int page = 0,
    int pageSize = 15,
  }) async {
    final req0 = await AppServices.instance.qq.executeRaw(
      BizRequest(
        module: 'music.globalComment.CommentRead',
        method: 'GetHotCommentList',
        param: {
          'BizType': QqCommentBizType.song,
          'BizId': songId,
          'LastCommentSeqNo': '',
          'PageSize': pageSize,
          'PageNum': page,
          'HotType': 1,
          'WithAirborne': 0,
          'PicEnable': 1,
        },
      ),
    );
    final parsed = parseCommentList(req0);
    return CommentPage(
      hot: parsed.latest,
      total: parsed.total,
      hasMore: parsed.hasMore,
    );
  }

  /// 读取歌曲最新评论（免登录）。
  ///
  /// [songId] 必须是**数字 songid**（不是 mid，见文件头说明）。
  static Future<CommentPage> getNewComments(
    String songId, {
    int page = 0,
    int pageSize = 15,
  }) async {
    final req0 = await AppServices.instance.qq.executeRaw(
      BizRequest(
        module: 'music.globalComment.CommentRead',
        method: 'GetNewCommentList',
        param: {
          'PageSize': pageSize,
          'PageNum': page,
          'HashTagID': '',
          'BizType': QqCommentBizType.song,
          'PicEnable': 1,
          'LastCommentSeqNo': '',
          'SelfSeeEnable': 1,
          'BizId': songId,
          'AudioEnable': 1,
        },
      ),
    );
    return parseCommentList(req0);
  }

  /// 歌曲评论总数（免登录）。
  static Future<int> getCommentCount(String songId) async {
    final req0 = await AppServices.instance.qq.executeRaw(
      BizRequest(
        module: 'music.globalComment.CommentCountSrv',
        method: 'GetCmCount',
        param: {
          'request': {
            'biz_id': songId,
            'biz_type': QqCommentBizType.song,
            'biz_sub_type': 2,
          },
        },
      ),
    );
    return parseCommentCount(req0);
  }

  /// 发表评论（需登录）。
  ///
  /// [songId] 必须是**数字 songid**（不是 mid，见文件头说明）。
  /// [replyTo] 非空时为回复某条评论（填被回复评论的 CmId）。
  static Future<void> addComment(
    String songId,
    String content, {
    String? replyTo,
  }) async {
    final param = <String, dynamic>{
      'Content': content,
      'BizType': QqCommentBizType.song,
      'BizId': songId,
      'BizSubType': 2,
    };
    if (replyTo != null && replyTo.isNotEmpty) {
      param['RepliedCmId'] = replyTo;
    }
    final req0 = await AppServices.instance.qq.executeRaw(
      BizRequest(
        module: 'music.globalComment.CommentWriteServer',
        method: 'AddComment',
        param: param,
        allowErrorCodes: true,
      ),
    );
    // 业务码可能出现在 CGI 层（req0.code）或 data 层（data.code），都查。
    final biz = _bizLayer(req0);
    final code = _toInt(req0['code']) != 0
        ? _toInt(req0['code'])
        : _toInt(biz['code']);
    if (code != 0) {
      // 10009 = 风控拦截：评论已记录但需过一次安全验证才展示。
      // 响应里的 VerifyUrl 是验证页，交给 UI 引导用户去验证。
      if (code == 10009) {
        // VerifyUrl 在 data 层（_bizLayer 对 AddComment 形状不会剥层，
        // 这里两层都取，稳）。
        final dataLayer =
            biz['data'] is Map<String, dynamic> ? biz['data'] as Map<String, dynamic> : const <String, dynamic>{};
        final verifyUrl =
            ((biz['VerifyUrl'] ?? dataLayer['VerifyUrl']) ?? '').toString();
        if (verifyUrl.isNotEmpty) {
          AppLog.w('QqCommentApi',
              '发表被风控拦截（HitType=${biz['HitType']} HitReason=${biz['HitReason']}），需完成安全验证');
          throw QqCommentVerifyRequired(verifyUrl);
        }
      }
      final serverMsg = (biz['Msg'] ?? '').toString();
      throw Exception(
          '发表评论失败（$code${serverMsg.isEmpty ? '' : '：$serverMsg'}）');
    }
    AppLog.i('QqCommentApi', '发表评论成功 song=$songId');
  }

  /// 点赞 / 取消点赞（需登录）。
  ///
  /// [like] 为 true 点赞、false 取消；`new_` 字段即开关（实测形制）。
  static Future<void> praiseComment(String cmtId, {required bool like}) async {
    final req0 = await AppServices.instance.qq.executeRaw(
      BizRequest(
        module: 'music.globalComment.CommentWrite',
        method: 'PraiseComment',
        param: {
          'new_': like ? 1 : 0,
          'CmId': cmtId,
          'Type': 1,
          'IMEI': '',
          'Ext': '',
        },
        allowErrorCodes: true,
      ),
    );
    final biz = _bizLayer(req0);
    final code = _toInt(req0['code']) != 0
        ? _toInt(req0['code'])
        : _toInt(biz['code']);
    if (code != 0) {
      throw Exception('点赞失败（$code）');
    }
    AppLog.i('QqCommentApi', '${like ? "点赞" : "取消点赞"}成功 cmt=$cmtId');
  }

  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}
