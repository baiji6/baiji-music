// 酷我评论写接口协议测试（v2.4.2）。
//
// 覆盖 `ncommentw.kuwo.cn`（发表/回复 POST）与 `ncomment.kuwo.cn`
// （点赞/楼中楼 GET）的 `f=ar` DES 密封协议，样本形制来自**沙箱真机
// 联调**（登录账号 uid=616474112「白姬」，歌曲 rid=80958029：
// 发表 code=200、click_like/cancel_like 的 like 字段 1/0、
// 回复 reply+pcid code=200 且楼中楼立即可见，见
// kuwo_comment_api.dart 文件头「③」）。
//
// 这里用假 Dio（HttpClientAdapter 注入）抓**请求形制**（主机/查询串/
// body/UA），响应体按请求里的 sx 现场密封后回灌，不发真请求。
import 'dart:convert';
import 'dart:typed_data';

import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/network/kuwo/kuwo_auth.dart';
import 'package:baiji_music/network/kuwo/kuwo_cipher.dart';
import 'package:baiji_music/network/kuwo/kuwo_comment_api.dart';
import 'package:baiji_music/network/kuwo/qmc_cipher.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App 富读「最热」真实样本（含内嵌楼中楼，time 秒级数字）。
const Map<String, dynamic> _feedHotFirst = {
  'id': '647495065',
  'msg': '如果你们遇到一个叫张燕的女孩，请告诉她，健康想和她在一起',
  'u_id': '501214651',
  'u_name': '健康一直都在jk',
  'u_pic': 'http://img4.kuwo.cn/star/userhead/51/25/1598692803118_501214651s.jpg',
  'time': 1578730157,
  'like_num': 1940,
  'is_like': false,
  'child_comment_count': 169,
  'child_comments': [
    {
      'id': '647781798',
      'msg': '顶你上去，兄弟，我也只能帮你这么多了',
      'u_id': '471635715',
      'u_name': '一片红叶向南飞',
      'u_pic':
          'http://img1.kuwo.cn/star/userhead/15/12/1642232126383_471635715s.jpg',
      'time': 1579056729,
      'like_num': 101,
      'is_like': false,
    },
  ],
};

/// App 富读「最新」真实样本（无楼中楼字段）。
const Map<String, dynamic> _feedLatestFirst = {
  'id': '1005703741',
  'msg': '每天通勤必听',
  'u_id': '900123456',
  'u_name': '听风的人',
  'u_pic': '',
  'time': 1789211726,
  'like_num': 0,
  'is_like': false,
};

/// 假适配器：记录最后一次请求，响应体按请求里的 sx 现场密封。
///
/// 酷我 `f=ar` 响应用**请求自己的 sx**（毫秒时间戳前 8 位）解密，
/// 所以这里必须先从请求 URL 的 q 里把 sx 解出来，再拿它密封响应，
/// 客户端的 `KuwoCipher.openResponse` 才能还原出 JSON。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter();

  /// 测试预设的响应明文（未密封的 JSON 文本）。
  ResponseBody response = ResponseBody.fromString('', 200);

  RequestOptions? lastOptions;
  Uint8List lastBody = Uint8List(0);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    lastBody = Uint8List(0);
    if (requestStream != null) {
      final b = BytesBuilder(copy: false);
      await for (final chunk in requestStream) {
        b.add(chunk);
      }
      lastBody = b.takeBytes();
    }
    final text = await _readText(response);
    final sx = _requestSx(options);
    final sealed = base64.encode(EkeyCipher.encrypt(
      Uint8List.fromList(utf8.encode(text)),
      Uint8List.fromList(utf8.encode(sx)),
    ));
    return ResponseBody.fromString(sealed, response.statusCode);
  }

  @override
  void close({bool force = false}) {}

  static Future<String> _readText(ResponseBody body) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      b.add(chunk);
    }
    return utf8.decode(b.takeBytes());
  }

  /// 从请求 URL 的 q 里解出 sx（8 位纯数字响应密钥）。
  static String _requestSx(RequestOptions options) {
    final m = RegExp(r'(?:^|&)q=([^&]*)').firstMatch(options.uri.query);
    if (m == null) fail('请求 URL 里没有 q 参数: ${options.uri.query}');
    final cipher = base64.decode(m.group(1)!);
    final dec = EkeyCipher.decrypt(
        cipher, Uint8List.fromList(utf8.encode(KuwoCipher.queryKey)));
    var end = dec.length;
    while (end > 0 && dec[end - 1] == 0) {
      end--;
    }
    final q = utf8.decode(dec.sublist(0, end));
    final sm = RegExp(r'(?:^|&)sx=(\d{8})(?:&|$)').firstMatch(q);
    if (sm == null) fail('q 里没有 sx 参数: $q');
    return sm.group(1)!;
  }
}

/// 未密封的 JSON 响应体（`fetch` 里会按请求 sx 现场密封）。
ResponseBody _jsonBody(String text) => ResponseBody.fromString(text, 200);

/// 灌入真机联调会话（uid=616474112「白姬」，sid=751317333）。
Future<void> _seedSession() async {
  await KvStore.instance.setString('kuwo_session', jsonEncode({
    'uid': '616474112',
    'sid': '751317333',
    'nickname': '白姬',
    'avatar': '',
    'username': '15149883530',
  }));
  await KuwoAuth.restore();
}

/// 解封请求 URL 里的 q 参数（base64 → DES → 明文查询串）。
String _unsealQuery(RequestOptions options) {
  final m = RegExp(r'(?:^|&)q=([^&]*)').firstMatch(options.uri.query);
  if (m == null) fail('请求 URL 里没有 q 参数: ${options.uri.query}');
  final cipher = base64.decode(m.group(1)!);
  final dec = EkeyCipher.decrypt(
      cipher, Uint8List.fromList(utf8.encode(KuwoCipher.queryKey)));
  var end = dec.length;
  while (end > 0 && dec[end - 1] == 0) {
    end--;
  }
  return utf8.decode(dec.sublist(0, end));
}

void main() {
  final adapter = _FakeAdapter();
  group('KuwoCommentWriteApi 协议形制（假 Dio，不发真请求）', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, String>{});

    setUpAll(() async {
      await KvStore.ensureInit();
    });

    setUp(() async {
      await KuwoAuth.clearAll();
      // 固定设备身份，便于断言 deviceId
      await KvStore.instance.setString(
          'kuwo_device_user', 'a1b2c3d4e5f6789012345678abcdef12');
      await KvStore.instance.setString('kuwo_device_android_id',
          '0f1e2d3c4b5a69788796a5b4c3d2e1f0');
      await KvStore.instance.setString('kuwo_device_app_uid', '9123456789');
      KuwoCommentWriteApi.dio = Dio(BaseOptions(
        responseType: ResponseType.plain,
      ))..httpClientAdapter = adapter;
    });

    tearDown(() async {
      await KuwoAuth.clearAll();
    });

    /// 从请求 URL 的原始 query 里取出 q 并解封（base64 → DES → 明文）。
    String sealedQuery(RequestOptions options) => _unsealQuery(options);

    test('未登录：postComment / likeComment 抛「请先登录」', () async {
      await KuwoAuth.restore(); // 无会话
      await expectLater(
        KuwoCommentWriteApi.postComment(rid: '80958029', content: 'x'),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'msg', contains('请先登录酷我音乐账号'))),
      );
      await expectLater(
        KuwoCommentWriteApi.likeComment(
            rid: '80958029', commentId: '1', like: true),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'msg', contains('请先登录酷我音乐账号'))),
      );
      // 楼中楼读取免登录，不受影响
      adapter.response = _jsonBody('{"result":"ok","comments":[]}');
      expect(
          await KuwoCommentWriteApi.getChildComments(
              rid: '80958029', parentId: '647495065'),
          isEmpty);
    });

    test('postComment：主机 / 查询串 / body / UA 全部对齐', () async {
      await _seedSession();
      adapter.response = _jsonBody(jsonEncode({
        'code': '200',
        'msg': '评论发表成功',
        'result': 'ok',
        'comments': [_feedLatestFirst],
      }));
      final r =
          await KuwoCommentWriteApi.postComment(rid: '80958029', content: '你好&世界');
      expect(r, '评论发表成功');

      final uri = adapter.lastOptions!.uri;
      expect(uri.host, 'ncommentw.kuwo.cn');
      expect(uri.path, '/com.s');
      expect(uri.query, startsWith('f=ar&q='));
      expect(adapter.lastOptions!.method, 'POST');
      expect(adapter.lastOptions!.headers['User-Agent'],
          contains('Dalvik/2.1.0'));
      expect(adapter.lastOptions!.contentType, 'application/octet-stream');

      final q = sealedQuery(adapter.lastOptions!);
      expect(q, startsWith('type=post_comment'));
      expect(q, contains('&prod=kwplayer_ar_12.1.8.2'));
      expect(q, contains('&deviceId=a1b2c3d4e5f6789012345678abcdef12'));
      expect(q, contains('&source=kwplayer_ar_12.1.8.2_hw.apk'));
      expect(q, contains('&sesID=751317333'));
      expect(q, contains('&uid=616474112'));
      expect(q, contains('&digest=15'));
      expect(RegExp(r'&sx=\d{8}&').hasMatch(q), isTrue);
      expect(q, contains('&sid=80958029&msgflag=1'));
      expect(q, endsWith('&aapiver=1&newver=3'));

      // body = msg 的 UTF-8 裸字节，& 先换全角 ＆
      expect(utf8.decode(adapter.lastBody), '你好＆世界');
    });

    test('postComment：回复时带 reply + pcid', () async {
      await _seedSession();
      adapter.response = _jsonBody('{"code":"200","msg":"ok"}');
      await KuwoCommentWriteApi.postComment(
        rid: '80958029',
        content: '回复测试',
        replyId: '647495065',
        parentId: '647495065',
      );
      final q = sealedQuery(adapter.lastOptions!);
      expect(q, contains('&msgflag=1&reply=647495065&pcid=647495065&'));
    });

    test('postComment：非 200 抛服务端 msg', () async {
      await _seedSession();
      adapter.response = _jsonBody('{"code":"600","msg":"评论失败"}');
      await expectLater(
        KuwoCommentWriteApi.postComment(rid: '80958029', content: 'x'),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('评论失败'))),
      );
    });

    test('postComment：空内容本地拦截', () async {
      await _seedSession();
      await expectLater(
        KuwoCommentWriteApi.postComment(rid: '80958029', content: '   '),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('评论内容不能为空'))),
      );
    });

    test('likeComment：type / cid / pcid 与 like 字段', () async {
      await _seedSession();
      adapter.response = _jsonBody('{"result":"ok","like":"1"}');
      final n = await KuwoCommentWriteApi.likeComment(
        rid: '80958029',
        commentId: '647495065',
        like: true,
      );
      expect(n, 1);
      expect(adapter.lastOptions!.uri.host, 'ncomment.kuwo.cn');
      expect(adapter.lastOptions!.method, 'GET');
      var q = sealedQuery(adapter.lastOptions!);
      expect(q, startsWith('type=click_like'));
      expect(q, contains('&cid=647495065'));
      expect(q, contains('&uid=616474112'));
      expect(q, contains('&sesID=751317333'));
      expect(q, contains('&sid=80958029'));
      expect(q, endsWith('&newver=3'));
      expect(q.contains('pcid'), isFalse); // 一级评论无 pcid

      adapter.response = _jsonBody('{"result":"ok","like":"0"}');
      final n2 = await KuwoCommentWriteApi.likeComment(
        rid: '80958029',
        commentId: '647495065',
        parentId: '647495065', // 楼中楼里的回复
        like: false,
      );
      expect(n2, 0);
      q = sealedQuery(adapter.lastOptions!);
      expect(q, startsWith('type=cancel_like'));
      expect(q, contains('&pcid=647495065'));
    });

    test('likeComment：无 like 字段抛 msg', () async {
      await _seedSession();
      adapter.response = _jsonBody('{"code":"600","msg":"点赞失败"}');
      await expectLater(
        KuwoCommentWriteApi.likeComment(
            rid: '80958029', commentId: '1', like: true),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('点赞失败'))),
      );
    });

    test('getChildComments：分页参数与 comments 解析', () async {
      adapter.response = _jsonBody(jsonEncode({
        'code': '200',
        'result': 'ok',
        'main_comment': {'id': '647495065'},
        'comments': [_feedHotFirst['child_comments'][0]],
        'comments_counts': 169,
      }));
      final list = await KuwoCommentWriteApi.getChildComments(
        rid: '80958029',
        parentId: '647495065',
        page: 2,
        pageSize: 10,
      );
      expect(list.length, 1);
      expect(list.first.id, '647781798');
      expect(adapter.lastOptions!.uri.host, 'ncomment.kuwo.cn');
      expect(adapter.lastOptions!.headers['User-Agent'], contains('Chrome'));
      final q = sealedQuery(adapter.lastOptions!);
      expect(q, startsWith('type=get_child_comment'));
      expect(q, contains('&sesID=&uid=0')); // 读接口免登录
      expect(q, contains('&start=10&msgflag=1&count=10')); // (page-1)*pageSize
      expect(q, contains('&pcid=647495065'));
      expect(q, endsWith('&newver=3'));
    });

    test('getChildComments：result 非 ok 返回空列表', () async {
      adapter.response = _jsonBody('{"code":"600","result":"fail"}');
      expect(
          await KuwoCommentWriteApi.getChildComments(
              rid: '80958029', parentId: '647495065'),
          isEmpty);
    });
  });
}
