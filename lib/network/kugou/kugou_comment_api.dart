// 酷狗音乐歌曲评论（读 + 发）。
//
// 协议从「倾听 5.6.14」APK 反编译得出（`LiooIi.iili` / `LiooIi.ilii`），
// 并于 2026-11 在沙箱实测打通。链路分两套，**读与写的盐值不同**：
//
// **① 读（免登录）** —— `http://m.comment.service.kugou.com/r/v1/rank/{newest|topliked}`
//   - 签名：`signature = md5(SALT + sorted('k=v' 拼接) + '' + SALT)`，
//     SALT 用 gateway 盐 `OIlwieks28dk2k092lksi2UIkp`（服务端强校验，
//     盐错 → `err_code 20006 参数验证失败`）。
//   - 必须先经 `POST gateway.kugou.com/v3/album_audio/audio` 拿
//     `data[0][0].classification[0].res_id` 当 `mixsongid`。
//   - `count` 字段是评论总数；`list[]` 一页 19~20 条。
//
// **② 写（需登录）** —— `https://gateway.kugou.com/m.comment.service/p/v1/commentsv3/{add|reply}`
//   - 两套客户端身份：标准版 appid=1005 / clientver=11440 /
//     盐 = gateway 盐；概念版(lite) appid=3116 / clientver=10659 /
//     盐 = 歌词盐 `LnT6xpN3khm36zse0QzvmgTZ3waWdRSA`。
//     概念版在标准版被判「未登录」时作为兜底重试。
//   - body 是 JSON：`{"data":{"content":…,"contentFormatted":…,
//     "album_audio_id":…,"hash":…}}`。
//   - 签名要**两层**：
//       key       = md5(appid + salt + clientver + clienttime + mid + body)
//       signature = md5(salt + sorted('k=v' 拼接) + body + salt)
//     `key` 是 query 参数之一，且参与 `signature` 的拼接（key 算完才
//     put 进 TreeMap，再对整棵 TreeMap 排序签名）。
//   - 成功判据：`err_code == 0`。未登录 → `10000 请登录后发送`；
//     签名错 → `20006 参数验证失败`；内容太短 → `10003 发送字数不够`。
//     （实测：未登录时 add 返回 10000、reply 返回 10003 —— 说明两层
//     签名都已通过，请求确实走到了内容校验阶段。）
//   - 回复（reply）额外带 `tid` = 父评论 id。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../models/models.dart';
import 'kugou_auth.dart';
import 'kugou_cipher.dart';

/// 酷狗评论的两套客户端身份。
///
/// 标准版（std）用 appid=1005 + clientver=11440 + gateway 盐；
/// 概念版（lite）用 appid=3116 + clientver=10659 + 歌词盐。
/// 倾听 APK 会在标准身份被判未登录时切到概念版重试，这里同样照做。
enum KugouCommentPlatform {
  std(
    appid: '1005',
    clientver: '11440',
    salt: kugouGatewaySalt,
    ua: 'Android810-AndroidPhone-11440-14-0-COMMENT-wifi',
  ),
  lite(
    appid: '3116',
    clientver: '10659',
    salt: kugouLyricSalt,
    ua: 'Android810-AndroidPhone-10659-14-0-COMMENT-wifi',
  );

  const KugouCommentPlatform({
    required this.appid,
    required this.clientver,
    required this.salt,
    required this.ua,
  });

  final String appid;
  final String clientver;
  final String salt;
  final String ua;
}

/// 评论排序方式。
enum KugouCommentSort {
  /// 最新（`r/v1/rank/newest`）。
  newest,

  /// 最热（`r/v1/rank/topliked`）。
  topliked,
}

/// 酷狗评论接口。
abstract final class KugouCommentApi {
  /// 读评论域名（http，非 https —— https 会 502）。
  static const String readHost = 'http://m.comment.service.kugou.com';

  /// 写评论域名。
  static const String writeHost =
      'https://gateway.kugou.com/m.comment.service/p/v1/commentsv3';

  /// 歌曲元信息域名（取 res_id 用）。
  static const String audioUrl =
      'https://gateway.kugou.com/v3/album_audio/audio';

  /// 免登录读接口用的固定 mid（仅用于读评论 / 取 res_id，这些接口不校验
  /// token 与 mid 的绑定关系，用固定值即可）。**写接口（发表评论）绝不能
  /// 用这个值**——写接口要求 mid 与登录 token 绑定的设备 mid 一致，否则
  /// 网关会把 token 判为无效 → err_code 10000「未登录」。写接口改用
  /// `KugouAuth.device().mid`。
  static const String commentMid = '16249512204336365674023395779019';

  /// 评论接口固定 code。
  static const String commentCode = 'fc4be23b4e972707f36b8a828a93ba8a';

  /// 读评论时用的 clientver。
  static const String readClientver = '11409';

  /// 每页条数（服务端上限 20）。
  static const int pageSize = 20;

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.plain,
  ));

  static const Map<String, String> _readHeaders = {
    'accept': 'application/json',
    'User-Agent':
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/107.0.0.0 Safari/537.36 Edg/107.0.1418.24',
  };

  static const Map<String, String> _audioHeaders = {
    'KG-THash': '13a3164',
    'KG-RC': '1',
    'KG-Fake': '0',
    'KG-RF': '00869891',
    'User-Agent':
        'Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi',
    'x-router': 'kmr.service.kugou.com',
    'Content-Type': 'application/json',
  };

  // ==================== 读 ====================

  /// 读一页评论（免登录）。
  ///
  /// [hash] 是歌曲的 FileHash；[sort] 决定最新还是最热；
  /// [page] 从 1 开始。返回的 [CommentPage.latest] 装本页评论，
  /// [CommentPage.total] 是服务端给出的评论总数。
  static Future<CommentPage> getComments(
    String hash, {
    KugouCommentSort sort = KugouCommentSort.newest,
    int page = 1,
  }) async {
    final resId = await getResId(hash);
    final rank = switch (sort) {
      KugouCommentSort.newest => 'newest',
      KugouCommentSort.topliked => 'topliked',
    };
    final params = <String, String>{
      'appid': '1005',
      'clienttime': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      'clienttoken': '0',
      'clientver': readClientver,
      'code': commentCode,
      'dfid': '0',
      'extdata': hash,
      'kugouid': '0',
      'mid': commentMid,
      'mixsongid': resId,
      'p': '$page',
      'pagesize': '$pageSize',
      'uuid': '0',
      'ver': '10',
    };
    // 读接口的签名：按 key 字母序把 'k=v' 拼起来（无分隔符）。
    final joined = (params.keys.toList()..sort())
        .map((k) => '$k=${params[k]}')
        .join('');
    final signature =
        md5.convert(utf8.encode('$kugouGatewaySalt$joined$kugouGatewaySalt'))
            .toString();
    final q = (params.keys.toList()..sort())
        .map((k) =>
            '${Uri.encodeComponent(k)}=${Uri.encodeComponent(params[k] ?? '')}')
        .join('&');
    final url = '$readHost/r/v1/rank/$rank?$q&signature=$signature';
    final resp =
        await _dio.get<String>(url, options: Options(headers: _readHeaders));
    final body = resp.data ?? '';
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw KugouCommentException('酷狗评论返回格式不正确');
    }
    final m = Map<String, dynamic>.from(decoded);
    final err = _toInt(m['err_code']);
    if (err != 0 && err != 20006) {
      throw KugouCommentException(
          '酷狗评论读取失败（$err）${_msg(m)}');
    }
    final page0 = parseCommentPage(m);
    AppLog.i('KugouCommentApi',
        '酷狗评论 hash=$hash $rank 第 $page 页：${page0.latest.length} 条 / 共 ${page0.total}');
    return page0;
  }

  /// 取歌曲的 `res_id`（评论接口的 mixsongid）。
  ///
  /// 走 `POST gateway.kugou.com/v3/album_audio/audio`，body 里 `key` 填
  /// gateway 盐、`fields` 要带 `classification`。
  static Future<String> getResId(String hash) async {
    final info = await getSongCommentInfo(hash);
    return info.resId;
  }

  /// 一次请求同时取回发评论所需的两个 id。
  ///
  /// - [resId] = `classification[0].res_id`，评论读接口的 `mixsongid`、
  ///   写接口的 `album_audio_id`；
  /// - [childrenId] = `audio_info.audio_id`，写接口的 `childrenid`
  ///   （填错会返回 `10013 歌曲不存在`）。
  static Future<KugouSongCommentIds> getSongCommentInfo(String hash) async {
    if (hash.isEmpty) throw KugouCommentException('缺少歌曲 hash');
    final payload = <String, dynamic>{
      'area_code': '1',
      'show_privilege': 1,
      'show_album_info': '1',
      'is_publish': '',
      'appid': 1005,
      'clientver': 11451,
      'mid': '1',
      'dfid': '-',
      'clienttime': DateTime.now().millisecondsSinceEpoch,
      'key': kugouGatewaySalt,
      'fields':
          'album_info,author_name,audio_info,ori_audio_name,base,songname,classification',
      'data': [
        {'hash': hash}
      ],
    };
    final resp = await _dio.post<String>(audioUrl,
        data: jsonEncode(payload),
        options: Options(headers: _audioHeaders));
    final body = resp.data ?? '';
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw KugouCommentException('酷狗歌曲信息返回格式不正确');
    }
    final m = Map<String, dynamic>.from(decoded);
    final resId = extractResId(m);
    if (resId.isEmpty) {
      throw KugouCommentException('未能取得歌曲评论标识（res_id）');
    }
    return KugouSongCommentIds(resId: resId, childrenId: extractAudioId(m));
  }

  /// 从 `album_audio/audio` 响应里抽 `classification[0].res_id`（纯函数）。
  static String extractResId(Map<String, dynamic> json) {
    final data = json['data'];
    dynamic inner = data;
    if (inner is List && inner.isNotEmpty) {
      inner = inner.first;
      if (inner is List && inner.isNotEmpty) inner = inner.first;
    }
    if (inner is! Map) return '';
    final cls = inner['classification'];
    if (cls is! List || cls.isEmpty) return '';
    final first = cls.first;
    if (first is! Map) return '';
    return (first['res_id'] ?? '').toString();
  }

  /// 从 `album_audio/audio` 响应里抽 `audio_info.audio_id`（纯函数）。
  ///
  /// 这是写评论的 `childrenid`；`audio_info` 可能是 Map 也可能是 JSON 串。
  static String extractAudioId(Map<String, dynamic> json) {
    final data = json['data'];
    dynamic inner = data;
    if (inner is List && inner.isNotEmpty) {
      inner = inner.first;
      if (inner is List && inner.isNotEmpty) inner = inner.first;
    }
    if (inner is! Map) return '';
    var info = inner['audio_info'];
    if (info is String && info.isNotEmpty) {
      try {
        info = jsonDecode(info);
      } catch (_) {
        return '';
      }
    }
    if (info is! Map) return '';
    return (info['audio_id'] ?? '').toString();
  }

  // ==================== 写 ====================

  /// 发表一条评论（需登录）。
  ///
  /// [hash] 歌曲 FileHash；[content] 评论正文；[resId] 歌曲的
  /// album_audio_id（不传则内部按 hash 查）；[parentId] 非空时视为
  /// 回复（走 `reply` 路径并带 `tid` = 父评论 id）。
  ///
  /// 标准身份被判未登录时自动切概念版重试一次。
  static Future<void> postComment(
    String hash,
    String content, {
    String? resId,
    String? parentId,
  }) async {
    final text = content.trim();
    final err = validateCommentContent(text);
    if (err != null) throw KugouCommentException(err);
    KugouSongCommentIds ids;
    if (resId != null && resId.isNotEmpty) {
      ids = KugouSongCommentIds(resId: resId, childrenId: '');
    } else {
      ids = await getSongCommentInfo(hash);
    }
    final session = KugouAuth.session;
    if (session == null || !session.isValid) {
      throw KugouCommentException('请先登录酷狗音乐账号后再发表评论');
    }
    // 设备 mid 必须与登录 token 绑定的是同一个（KugouAuth.device().mid），
    // 否则网关会把 token 判为无效 → err_code 10000「未登录」。
    final dev = await KugouAuth.device();
    KugouCommentException? last;
    for (final platform in KugouCommentPlatform.values) {
      try {
        await _postOnce(
          platform: platform,
          hash: hash,
          content: text,
          resId: ids.resId,
          childrenId: ids.childrenId,
          parentId: parentId,
          userid: session.userid,
          token: session.token,
          mid: dev.mid,
        );
        AppLog.i('KugouCommentApi',
            '酷狗评论已发表 platform=${platform.name} hash=$hash');
        return;
      } on KugouCommentException catch (e) {
        last = e;
        // 只有「未登录」才换身份重试；其他错误（内容太短等）直接抛。
        if (!e.isLoginRequired) rethrow;
      }
    }
    throw last ??
        KugouCommentException('酷狗评论发表失败（两套身份均被拒绝）');
  }

  /// 单次发表请求（不重试）。
  static Future<void> _postOnce({
    required KugouCommentPlatform platform,
    required String hash,
    required String content,
    required String resId,
    required String childrenId,
    required String? parentId,
    required String userid,
    required String token,
    required String mid,
  }) async {
    final clienttime = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final body = buildPostBody(
      content: content,
      albumAudioId: resId,
      hash: hash,
    );
    // key = md5(appid + salt + clientver + clienttime + mid + body)
    // 这里的 mid 必须与登录 token 绑定的设备 mid 一致（KugouAuth.device().mid），
    // 用固定常量会触发服务端把 token 判为无效 → err_code 10000「未登录」。
    final key = buildWriteKey(
      platform: platform,
      clienttime: clienttime,
      mid: mid,
      body: body,
    );
    final params = <String, String>{
      'code': commentCode,
      'childrenid': childrenId.isEmpty ? '0' : childrenId,
      'album_audio_id': resId,
      'kugouid': userid,
      'ver': '10',
      'clienttoken': '0',
      'appid': platform.appid,
      'clientver': platform.clientver,
      'mid': mid,
      'clienttime': clienttime,
      'key': key,
      'uuid': '0',
      'dfid': '0',
      'userid': userid,
      'token': token,
      'gid': '0',
      'is_t': '0',
      'pid': '0',
      if (parentId != null && parentId.isNotEmpty) 'tid': parentId,
    };
    // signature = md5(salt + sorted('k=v') + body + salt)
    final signature = buildWriteSignature(
      platform: platform,
      params: params,
      body: body,
    );
    final q = (params.keys.toList()..sort())
        .map((k) =>
            '${Uri.encodeComponent(k)}=${Uri.encodeComponent(params[k] ?? '')}')
        .join('&');
    final path = (parentId != null && parentId.isNotEmpty) ? 'reply' : 'add';
    final url = '$writeHost/$path?$q&signature=$signature';
    final headers = <String, String>{
      'accept': 'application/json',
      'User-Agent': platform.ua,
      'Content-Type': 'application/json;charset=utf-8',
      'Cookie': 'kg_userid=$userid; kg_token=$token',
    };
    final resp = await _dio.post<String>(url,
        data: body,
        options: Options(headers: headers));
    final raw = resp.data ?? '';
    Map<String, dynamic> m;
    try {
      final decoded = jsonDecode(raw);
      m = decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
    } catch (_) {
      throw KugouCommentException('酷狗评论发表返回格式不正确');
    }
    final err = _toInt(m['err_code']);
    if (err == 0) return;
    final msg = _msg(m);
    if (err == 10000) {
      throw KugouCommentException('酷狗账号未登录或登录已失效$msg',
          isLoginRequired: true);
    }
    // `60045` 是服务端对账号 / 设备级反垃圾（风控）的笼统拒绝码，与正文
    // 内容无关——正常中文也会被拒。逆向倾听 5.6.14 确认：它对 60045 无任何
    // 特殊处理（不弹验证、不重试），只把服务端 `message` 透传为「操作失败」。
    // 官方酷狗 App 也只是在账号触发风控时弹滑块验证，验证通过后该码即消失。
    // 客户端无法绕过，只能如实告知用户。
    if (err == 60045) {
      throw KugouCommentException(
          '酷狗评论被服务端风控拦截（60045）：当前账号或设备触发了反垃圾策略'
          '，请稍后重试，或换一个酷狗账号登录后发表'
          '${msg.isNotEmpty ? '（$msg）' : ''}');
    }
    throw KugouCommentException('酷狗评论发表失败（$err）$msg');
  }

  /// 客户端轻量预校验评论正文（纯函数，可单测）。
  ///
  /// 返回 `null` 表示通过；否则返回错误提示文案。这里只拦明显无效的输入
  /// （空 / 纯数字 / 含空白），避免把无效请求发到服务端。注意这**不是**
  /// 60045 的解法——60045 是服务端对账号 / 设备的风控，正常中文也会被拒，
  /// 客户端无法绕过。
  static String? validateCommentContent(String text) {
    if (text.isEmpty) return '评论内容不能为空';
    if (RegExp(r'^\d+$').hasMatch(text)) {
      return '评论内容不能是纯数字，请换个字词再发';
    }
    if (text.contains(RegExp(r'\s'))) {
      return '评论内容不能包含空格或换行';
    }
    return null;
  }

  /// 写接口第一层签名 key（纯函数，可单测）。
  ///
  /// `key = md5(appid + salt + clientver + clienttime + mid + body)`。
  /// 注意 [mid] 必须与登录 token 绑定的设备 mid 一致
  /// （`KugouAuth.device().mid`），传固定常量会让服务端把 token 判为无效
  /// → `err_code 10000`「未登录」。
  static String buildWriteKey({
    required KugouCommentPlatform platform,
    required String clienttime,
    required String mid,
    required String body,
  }) =>
      md5
          .convert(utf8.encode('${platform.appid}${platform.salt}'
              '${platform.clientver}$clienttime$mid$body'))
          .toString();

  /// 写接口第二层签名 signature（纯函数，可单测）。
  ///
  /// `signature = md5(salt + 排序('k=v' 拼接) + body + salt)`。
  static String buildWriteSignature({
    required KugouCommentPlatform platform,
    required Map<String, String> params,
    required String body,
  }) {
    final joined = (params.keys.toList()..sort())
        .map((k) => '$k=${params[k]}')
        .join('');
    return md5
        .convert(utf8.encode('${platform.salt}$joined$body${platform.salt}'))
        .toString();
  }

  /// 构造发表评论的 body JSON（纯函数，可单测）。
  ///
  /// 字段顺序与倾听一致：content / contentFormatted / album_audio_id / hash，
  /// 外层再包一层 `data`。
  static String buildPostBody({
    required String content,
    required String albumAudioId,
    required String hash,
  }) {
    final inner = <String, dynamic>{
      'content': content,
      'contentFormatted': content,
      'album_audio_id': albumAudioId,
      'hash': hash,
    };
    return jsonEncode(<String, dynamic>{'data': inner});
  }

  // ==================== 解析（纯函数） ====================

  /// 解析一页评论响应（纯函数）。
  ///
  /// 服务端把评论放在 `list[]`，总数在 `count`。
  static CommentPage parseCommentPage(Map<String, dynamic> json) {
    final list = json['list'];
    final out = <Comment>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map) {
          out.add(parseComment(Map<String, dynamic>.from(item)));
        }
      }
    }
    final total = _toInt(json['count']);
    return CommentPage(
      hot: const [],
      latest: out,
      total: total,
      hasMore: out.length >= pageSize && total > out.length,
    );
  }

  /// 解析单条评论（纯函数）。
  static Comment parseComment(Map<String, dynamic> json) {
    final like = json['like'];
    final likeMap = like is Map ? Map<String, dynamic>.from(like) : const {};
    return Comment(
      id: (json['id'] ?? '').toString(),
      nickname: (json['user_name'] ?? '').toString(),
      avatarUrl: (json['user_pic'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      timeMs: parseCommentTime(json['addtime']),
      likeCount: _toInt(likeMap['likenum']),
      liked: likeMap['haslike'] == true,
      replyCount: _toInt(json['reply_num']),
      isHot: false,
      replies: const [],
    );
  }

  /// 解析 `addtime` → 毫秒时间戳（纯函数）。
  ///
  /// 形如 `"2026-11-07 20:24:30"`（服务器本地时间，无时区标注），
  /// 按本地时区解析；格式非法或越界返回 0。
  static int parseCommentTime(dynamic raw) {
    final s = raw?.toString().trim() ?? '';
    if (s.isEmpty) return 0;
    final m =
        RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
            .firstMatch(s);
    if (m == null) return 0;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    final h = int.parse(m.group(4)!);
    final mi = int.parse(m.group(5)!);
    final se = int.parse(m.group(6)!);
    // 越界校验：DateTime 会把 13 月/99 日静默进位成别的日期。
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return 0;
    if (h > 23 || mi > 59 || se > 59) return 0;
    final dt = DateTime(y, mo, d, h, mi, se);
    // DateTime 会把 2 月 31 日进位到 3 月，这里反向校验。
    if (dt.month != mo || dt.day != d) return 0;
    return dt.millisecondsSinceEpoch;
  }

  /// 从评论条目里取歌曲的 `special_child_id`（纯函数）。
  ///
  /// 这是**歌曲**级的 id（同首歌的评论全都一样，实测 332453），
  /// 正好等于 `audio_info.audio_id`，不是父评论 id。
  /// 回复时酷狗要的 `tid` 则是父评论的 `id`（形如 `1263415871`）。
  static String extractChildId(Map<String, dynamic> json) {
    final v = (json['special_child_id'] ?? '').toString();
    return v;
  }

  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? 0;
  }

  static String _msg(Map<String, dynamic> m) {
    final raw = (m['message'] ?? m['msg'] ?? '').toString();
    return raw.isEmpty ? '' : '：$raw';
  }
}

/// 发评论所需的两个歌曲级 id。
class KugouSongCommentIds {
  const KugouSongCommentIds({required this.resId, required this.childrenId});

  /// `classification[0].res_id` —— 评论读接口的 mixsongid、
  /// 写接口的 `album_audio_id`。
  final String resId;

  /// `audio_info.audio_id` —— 写接口的 `childrenid`。
  final String childrenId;
}

/// 酷狗评论错误。
class KugouCommentException implements Exception {
  KugouCommentException(this.message, {this.isLoginRequired = false});

  final String message;

  /// 是否属于「需要登录 / 登录失效」，调用方可据此换身份重试。
  final bool isLoginRequired;

  @override
  String toString() => message;
}
