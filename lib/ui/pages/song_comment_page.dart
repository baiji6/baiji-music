// 歌曲评论页（QQ / 网易云）。
//
// 未登录可浏览评论；登录后可发评 / 回复 / 点赞。入口：播放页操作行的
// 评论按钮。本地歌曲没有评论（服务端无此资源），进入后显示空状态。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../models/models.dart';
import '../../network/music_api.dart';
import '../../network/netease_comment_api.dart';
import '../../network/qq_comment_api.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';
import 'netease_login_page.dart';
import 'qq_login_page.dart';

/// 歌曲评论页。
class SongCommentPage extends StatefulWidget {
  const SongCommentPage({super.key, required this.song});

  final Song song;

  @override
  State<SongCommentPage> createState() => _SongCommentPageState();
}

class _SongCommentPageState extends State<SongCommentPage> {
  bool _loading = true;
  String? _error;
  CommentPage _data = const CommentPage();

  /// 回复目标（null = 直接评论歌曲）。
  Comment? _replyTo;

  final _inputController = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  bool _sending = false;

  /// 正在点赞 / 取消中的评论 id（防重复点击）。
  final _likingIds = <String>{};

  bool _loadingMore = false;

  /// 网易云分页 offset（limit 固定 15）。
  int _neOffset = 0;

  /// QQ 最新评分页页码（从 0 起，首页已拉过）。
  int _qqPage = 0;

  bool get _isLocal => widget.song.source == Source.local;

  bool get _loggedIn =>
      AppServices.instance.isLoggedIn(widget.song.source);

  /// QQ 评论的 BizId 必须是**数字 songid**，不能传 mid。
  ///
  /// 实测（2026-10-18，u.y.qq.com musicu.fcg）：BizId 传 mid 时
  /// `music.globalComment.CommentRead.GetHotCommentList` 返回
  /// `code=10000`（AllowComment=0），与用户日志「评论加载失败 业务错误
  /// 10000」完全一致；传数字 songid 才返回评论列表。
  String get _qqBizId {
    final id = widget.song.songId;
    if (id <= 0) {
      throw Exception('该歌曲缺少数字 ID（songid），无法加载 QQ 评论');
    }
    return id.toString();
  }

  @override
  void initState() {
    super.initState();
    _load();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 240) _loadMore();
  }

  // ================= 数据 =================

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final song = widget.song;
      if (_isLocal) {
        // 本地歌曲服务端没有评论资源
        if (!mounted) return;
        setState(() => _loading = false);
        return;
      }
      if (song.isNetease) {
        final page = await NeteaseCommentApi.getComments(
            song.songId.toString());
        if (!mounted) return;
        _neOffset = 15;
        setState(() {
          _data = page;
          _loading = false;
        });
      } else {
        // QQ：热评 + 最新各拉一页。总数以最新评为准（实测与 GetCmCount
        // 一致：热评 Total 只是热评桶的条数）。
        // 注意 BizId 用数字 songid（mid 会 10000，见 [_qqBizId]）。
        final bizId = _qqBizId;
        final results = await Future.wait([
          QqCommentApi.getHotComments(bizId),
          QqCommentApi.getNewComments(bizId),
        ]);
        if (!mounted) return;
        _qqPage = 1;
        setState(() {
          _data = CommentPage(
            hot: results[0].hot,
            latest: results[1].latest,
            total: results[1].total > 0 ? results[1].total : results[0].total,
            hasMore: results[1].hasMore || results[0].hasMore,
          );
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _loading || !_data.hasMore || _isLocal) return;
    setState(() => _loadingMore = true);
    try {
      final song = widget.song;
      if (song.isNetease) {
        final page = await NeteaseCommentApi.getComments(
            song.songId.toString(),
            offset: _neOffset);
        if (!mounted) return;
        setState(() {
          _data = CommentPage(
            hot: _data.hot,
            latest: [..._data.latest, ...page.latest],
            total: page.total,
            hasMore: page.hasMore,
          );
          _neOffset += 15;
        });
      } else {
        final page =
            await QqCommentApi.getNewComments(_qqBizId, page: _qqPage);
        if (!mounted) return;
        setState(() {
          _data = CommentPage(
            hot: _data.hot,
            latest: [..._data.latest, ...page.latest],
            total: page.total > 0 ? page.total : _data.total,
            hasMore: page.hasMore,
          );
          _qqPage += 1;
        });
      }
    } catch (e) {
      showAppSnack('加载更多失败：$e');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  // ================= 交互 =================

  Future<void> _onLike(Comment c) async {
    if (!_loggedIn) {
      showAppSnack('登录后可点赞');
      return;
    }
    if (_likingIds.contains(c.id)) return;
    // 乐观更新：先翻赞再请求，失败回滚
    final optimistic = _toggled(c);
    _replaceComment(c, optimistic);
    setState(() => _likingIds.add(c.id));
    try {
      final song = widget.song;
      if (song.isNetease) {
        await NeteaseCommentApi.likeComment(
            song.songId.toString(), c.id,
            like: !c.liked);
      } else {
        await QqCommentApi.praiseComment(c.id, like: !c.liked);
      }
    } catch (e) {
      _replaceComment(optimistic, c);
      showAppSnack('$e');
    } finally {
      if (mounted) setState(() => _likingIds.remove(c.id));
    }
  }

  void _onReply(Comment c) {
    if (!_loggedIn) {
      showAppSnack('登录后可回复');
      return;
    }
    setState(() => _replyTo = c);
    _inputFocus.requestFocus();
  }

  Future<void> _send() async {
    final content = _inputController.text.trim();
    if (content.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final song = widget.song;
      if (song.isNetease) {
        await NeteaseCommentApi.addComment(
          song.songId.toString(),
          content,
          replyTo: _replyTo?.id,
        );
      } else {
        await QqCommentApi.addComment(
          _qqBizId,
          content,
          replyTo: _replyTo?.id,
        );
      }
      _inputController.clear();
      setState(() => _replyTo = null);
      _inputFocus.unfocus();
      // 重新拉取，保证排序 / 计数一致（比本地插一条更接近服务端形态）
      await _load();
    } catch (e) {
      showAppSnack('$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _goLogin() {
    final popped = Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => widget.song.isNetease
          ? const NeteaseLoginPage()
          : const QQLoginPage(),
    ));
    // 登录页返回后刷新一次，让输入栏即时切到可发送态
    popped.then((_) {
      if (mounted) setState(() {});
    });
  }

  Comment _toggled(Comment c) => Comment(
        id: c.id,
        nickname: c.nickname,
        avatarUrl: c.avatarUrl,
        content: c.content,
        timeMs: c.timeMs,
        likeCount: c.likeCount + (c.liked ? -1 : 1),
        liked: !c.liked,
        replyCount: c.replyCount,
        isHot: c.isHot,
        replies: c.replies,
      );

  void _replaceComment(Comment old, Comment updated) {
    if (!mounted) return;
    List<Comment> replaceIn(List<Comment> list) {
      final i = list.indexOf(old);
      if (i < 0) return list;
      return [...list.sublist(0, i), updated, ...list.sublist(i + 1)];
    }

    setState(() {
      _data = CommentPage(
        hot: replaceIn(_data.hot),
        latest: replaceIn(_data.latest),
        total: _data.total,
        hasMore: _data.hasMore,
      );
    });
  }

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '评论',
      snackbarHost: appSnackbarHostState,
      actions: [
        MiuixIconButton(
          onPressed: _loading ? null : _load,
          child: Icon(Icons.refresh_rounded,
              size: 19, color: AppColors.textSecondary),
        ),
      ],
      bottomBar: _buildInputBar(),
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: MiuixCircularProgressIndicator(size: 28),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 40, color: AppColors.textTertiary),
            const SizedBox(height: 10),
            Text('评论加载失败',
                style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  style:
                      TextStyle(fontSize: 11, color: AppColors.textTertiary)),
            ),
            const SizedBox(height: 12),
            MiuixTextButton('重试', onPressed: _load),
          ],
        ),
      );
    }
    if (_data.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mode_comment_outlined,
                size: 40, color: AppColors.textTertiary),
            const SizedBox(height: 10),
            Text(
              _isLocal ? '本地歌曲暂无评论' : '还没有评论，来抢沙发吧',
              style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
            ),
          ],
        ),
      );
    }
      return RefreshIndicator(
        onRefresh: _load,
        color: AppColors.accent,
        backgroundColor: AppColors.bg2,
        child: ListView(
          controller: _scroll,
          // 底部多留一段，防最后一条评论被输入栏挡住
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 92),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('共 ${_data.total} 条评论',
                style:
                    TextStyle(fontSize: 11.5, color: AppColors.textTertiary)),
          ),
          if (_data.hot.isNotEmpty) ...[
            _sectionTitle('热门评论'),
            for (final c in _data.hot) _buildItem(c),
          ],
          if (_data.latest.isNotEmpty) ...[
            _sectionTitle('最新评论'),
            for (final c in _data.latest) _buildItem(c),
          ],
          if (_data.hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: _loadingMore
                    ? const MiuixCircularProgressIndicator(size: 22)
                    : MiuixTextButton('加载更多', onPressed: _loadMore),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 12,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: const LinearGradient(
                    colors: AppColors.accentGradient),
              ),
            ),
            const SizedBox(width: 6),
            Text(text,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary)),
          ],
        ),
      );

  Widget _buildItem(Comment c) => _CommentItem(
        comment: c,
        liking: _likingIds.contains(c.id),
        onLike: () => _onLike(c),
        onReply: () => _onReply(c),
      );

  /// 底部输入栏：未登录显示「去登录」引导，登录后可发评 / 回复。
  ///
  /// 输入栏必须随输入法上抬：MiuixScaffold 的 bottomBar 只吃
  /// `MediaQuery.padding`（系统栏），**不处理 viewInsets**，软键盘弹出后
  /// 输入栏与发送按钮被盖在键盘下面（用户反馈：评论框不随输入法上升，
  /// 于是「能看评论但不能发」）。这里按 viewInsets.bottom 垫一层底部内边距。
  Widget _buildInputBar() {
    final ime = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      // 与键盘动画同频，避免输入栏闪跳
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: ime),
      child: Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      decoration: BoxDecoration(
        color: AppColors.bg1,
        border: Border(
            top: BorderSide(color: AppColors.strokeGlass, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        // 键盘弹起时系统导航栏被键盘覆盖，再叠一层 SafeArea 底部内边距
        // 会让输入栏悬在键盘上方一大截，直接贴着键盘更自然。
        bottom: ime <= 0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyTo != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.reply_rounded,
                        size: 14, color: AppColors.accent),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '回复 @${_replyTo!.nickname}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.5, color: AppColors.accent),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _replyTo = null),
                      child: Icon(Icons.close_rounded,
                          size: 15, color: AppColors.textTertiary),
                    ),
                  ],
                ),
              ),
            if (_isLocal)
              // 本地歌曲服务端没有评论资源，输入栏只作说明
              Row(
                children: [
                  Icon(Icons.mode_comment_outlined,
                      size: 15, color: AppColors.textTertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('本地歌曲暂无评论',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textSecondary)),
                  ),
                ],
              )
            else if (!_loggedIn)
              Row(
                children: [
                  Icon(Icons.lock_outline_rounded,
                      size: 15, color: AppColors.textTertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('登录后可发表评论',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textSecondary)),
                  ),
                  MiuixTextButton('去登录', onPressed: _goLogin),
                ],
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: AppTextField(
                      controller: _inputController,
                      focusNode: _inputFocus,
                      label: _replyTo == null ? '写评论' : '写回复',
                      useLabelAsPlaceholder: true,
                      maxLines: 4,
                      minLines: 1,
                      textStyle: TextStyle(
                          fontSize: 14, color: AppColors.textPrimary),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _SendButton(busy: _sending, onTap: _send),
                ],
              ),
          ],
        ),
        ),
      ),
    );
  }
}

/// 发送按钮：渐变圆底 + 发送图标；发送中显示转圈。
class _SendButton extends StatelessWidget {
  const _SendButton({required this.busy, required this.onTap});

  final bool busy;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
              colors: AppColors.accentGradient,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
        ),
        child: Center(
          child: busy
              ? const MiuixCircularProgressIndicator(
                  size: 18, strokeWidth: 2)
              : const Icon(Icons.send_rounded,
                  size: 18, color: Colors.white),
        ),
      ),
    );
  }
}

/// 单条评论：头像 + 昵称/时间 + 内容 + 子回复 + 点赞列。
class _CommentItem extends StatelessWidget {
  const _CommentItem({
    required this.comment,
    required this.liking,
    required this.onLike,
    required this.onReply,
  });

  final Comment comment;
  final bool liking;
  final VoidCallback onLike;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(url: comment.avatarUrl, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.nickname.isEmpty
                            ? '网易云音乐用户'
                            : comment.nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary),
                      ),
                    ),
                    if (comment.timeMs > 0) ...[
                      const SizedBox(width: 6),
                      Text(_formatTime(comment.timeMs),
                          style: TextStyle(
                              fontSize: 11, color: AppColors.textTertiary)),
                    ],
                    if (comment.isHot) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 0.5),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('热',
                            style: TextStyle(
                                fontSize: 9.5,
                                color: AppColors.warning,
                                fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  comment.content,
                  style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: AppColors.textPrimary),
                ),
                if (comment.hasReplies) _buildReplies(comment.replies),
                GestureDetector(
                  onTap: onReply,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 5, bottom: 1),
                    child: Text('回复',
                        style: TextStyle(
                            fontSize: 11.5, color: AppColors.textTertiary)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: liking ? null : onLike,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Column(
                children: [
                  Icon(
                    comment.liked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    size: 16,
                    color: comment.liked
                        ? AppColors.magenta
                        : AppColors.textTertiary,
                  ),
                  const SizedBox(height: 2),
                  Text('${comment.likeCount}',
                      style: TextStyle(
                          fontSize: 10.5, color: AppColors.textTertiary)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReplies(List<Comment> replies) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in replies)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: AppColors.textSecondary),
                    children: [
                      TextSpan(
                        text: '${r.nickname}: ',
                        style: TextStyle(
                            color: AppColors.textTertiary,
                            fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: r.content),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 评论头像：http 统一升级 https（iOS ATS 拦明文），失败退化为占位。
class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, this.size = 36});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final https = url.replaceFirst('http://', 'https://');
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: https.isEmpty
            ? _fallback()
            : Image.network(
                https,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _fallback(),
              ),
      ),
    );
  }

  Widget _fallback() => Container(
        color: AppColors.surfaceGlass,
        child: Icon(Icons.person_rounded,
            size: size * 0.55, color: AppColors.textTertiary),
      );
}

/// 评论时间格式化：今天 HH:mm、今年 MM-dd、跨年 yyyy-MM-dd。
String _formatTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return '${two(t.hour)}:${two(t.minute)}';
  }
  if (t.year == now.year) return '${two(t.month)}-${two(t.day)}';
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}
