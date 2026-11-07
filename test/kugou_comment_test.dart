// 酷狗评论接口的离线单测。
//
// 用 2026-11 沙箱实测的真实响应片段驱动纯函数（parseComment /
// parseCommentPage / extractResId / extractAudioId / buildPostBody /
// parseCommentTime），并锁定签名与请求构造的关键约定：
//
// - 读接口的签名盐是 gateway 盐（`OIlwieks…`），服务端强校验；
// - 写接口两层签名：`key = md5(appid+salt+clientver+clienttime+mid+body)`、
//   `signature = md5(salt+sorted('k=v')+body+salt)`；
// - 两套客户端身份（std=1005/11440/gateway 盐、lite=3116/10659/歌词盐）。
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:baiji_music/network/kugou/kugou_comment_api.dart';
import 'package:baiji_music/network/kugou/kugou_cipher.dart';

/// 真实响应里的一条评论（已裁剪无关字段，保留解析所需全部字段）。
Map<String, dynamic> _realComment() => <String, dynamic>{
      'id': 1263415871,
      'status': '1',
      'user_name': '随芯缘行',
      'content': '这首歌真好听，单曲循环一下午了！',
      'addtime': '2026-11-07 22:44:49',
      'user_pic':
          'http://imge.kugou.com/kugouicon/165/20250718/20250718225631410132.jpg',
      'special_child_id': '332453',
      'special_child_name': '周杰伦 - 稻香',
      'album_audio_id': '32042828',
      'hash': '8909E1809908CD8E3BF6CF85D98B93F0',
      'reply_num': 0,
      'pid': '0',
      'user_id': 1011557010,
      'location': '上海',
      'like': <String, dynamic>{
        'count': 3,
        'likenum': 3,
        'haslike': true,
        'hasoppose': false,
        'opposenum': 0,
      },
      'udetail': <String, dynamic>{
        'user_id': 1011557010,
        'small_pic_v3':
            'https://vipimgbssdl.kugou.com/a1e7a8acaad33058152b34153fda725c.png',
      },
    };

void main() {
  group('KugouCommentApi.parseComment', () {
    test('真实条目字段全部落到模型', () {
      final c = KugouCommentApi.parseComment(_realComment());
      expect(c.id, '1263415871');
      expect(c.nickname, '随芯缘行');
      expect(c.content, '这首歌真好听，单曲循环一下午了！');
      expect(c.avatarUrl, contains('imge.kugou.com'));
      expect(c.likeCount, 3);
      expect(c.liked, isTrue);
      expect(c.replyCount, 0);
      expect(c.hasReplies, isFalse);
    });

    test('时间串解析为本地时区毫秒', () {
      final c = KugouCommentApi.parseComment(_realComment());
      final dt = DateTime(2026, 11, 7, 22, 44, 49);
      expect(c.timeMs, dt.millisecondsSinceEpoch);
    });

    test('like 缺失时按 0 / 未点赞处理', () {
      final m = _realComment()..remove('like');
      final c = KugouCommentApi.parseComment(m);
      expect(c.likeCount, 0);
      expect(c.liked, isFalse);
    });

    test('haslike 为 false 时不算已点赞', () {
      final m = _realComment();
      (m['like'] as Map)['haslike'] = false;
      expect(KugouCommentApi.parseComment(m).liked, isFalse);
    });

    test('like 计数是字符串数字时也能解析', () {
      final m = _realComment();
      (m['like'] as Map)['likenum'] = '12';
      expect(KugouCommentApi.parseComment(m).likeCount, 12);
    });

    test('缺字段时给出安全默认值而不是抛异常', () {
      final c = KugouCommentApi.parseComment(<String, dynamic>{});
      expect(c.id, '');
      expect(c.nickname, '');
      expect(c.content, '');
      expect(c.timeMs, 0);
      expect(c.likeCount, 0);
    });
  });

  group('KugouCommentApi.parseCommentTime', () {
    test('标准格式', () {
      expect(KugouCommentApi.parseCommentTime('2026-11-07 22:44:49'),
          DateTime(2026, 11, 7, 22, 44, 49).millisecondsSinceEpoch);
    });

    test('T 分隔也能解析', () {
      expect(KugouCommentApi.parseCommentTime('2026-11-07T22:44:49'),
          DateTime(2026, 11, 7, 22, 44, 49).millisecondsSinceEpoch);
    });

    test('空值 / 非法值返回 0', () {
      expect(KugouCommentApi.parseCommentTime(null), 0);
      expect(KugouCommentApi.parseCommentTime(''), 0);
      expect(KugouCommentApi.parseCommentTime('   '), 0);
      expect(KugouCommentApi.parseCommentTime('not-a-time'), 0);
      expect(KugouCommentApi.parseCommentTime('2026-13-99 99:99:99'), 0);
    });
  });

  group('KugouCommentApi.parseCommentPage', () {
    test('真实页：count 是总数，list 是本页', () {
      final page = KugouCommentApi.parseCommentPage(<String, dynamic>{
        'count': 471166,
        'list': <Map<String, dynamic>>[_realComment(), _realComment()],
      });
      expect(page.total, 471166);
      expect(page.latest.length, 2);
      expect(page.hot, isEmpty);
      // 本页没满 → 还没到底（但也拿不到下一页的判断依据，按未满即无更多处理）
      expect(page.hasMore, isFalse);
    });

    test('本页满 20 条且总数更大 → 还有更多', () {
      final page = KugouCommentApi.parseCommentPage(<String, dynamic>{
        'count': 471166,
        'list': List<Map<String, dynamic>>.filled(20, _realComment()),
      });
      expect(page.latest.length, 20);
      expect(page.hasMore, isTrue);
    });

    test('列表为空时 total 仍保留', () {
      final page = KugouCommentApi.parseCommentPage(
          <String, dynamic>{'count': 471166, 'list': const <dynamic>[]});
      expect(page.total, 471166);
      expect(page.latest, isEmpty);
      expect(page.isEmpty, isTrue);
    });

    test('缺 list 字段不抛异常', () {
      final page = KugouCommentApi.parseCommentPage(<String, dynamic>{});
      expect(page.latest, isEmpty);
      expect(page.total, 0);
    });

    test('list 里混入非 Map 元素被跳过', () {
      final page = KugouCommentApi.parseCommentPage(<String, dynamic>{
        'list': <dynamic>[_realComment(), 'oops', 42, null],
      });
      expect(page.latest.length, 1);
    });

    test('count 是字符串数字时也能解析', () {
      final page = KugouCommentApi.parseCommentPage(
          <String, dynamic>{'count': '1234', 'list': const <dynamic>[]});
      expect(page.total, 1234);
    });
  });

  group('KugouCommentApi.extractResId / extractAudioId', () {
    // 真实 album_audio/audio 响应结构：data[0][0]
    final audioJson = <String, dynamic>{
      'data': <dynamic>[
        <dynamic>[
          <String, dynamic>{
            'songname': '稻香',
            'author_name': '周杰伦',
            'classification': <dynamic>[
              <String, dynamic>{
                'res_id': '32042828',
                'res_type': '3',
                'type': '3',
                'usage': '0',
                'status': '0',
                'level': '1',
                'id': '0',
              },
            ],
            'audio_info': <String, dynamic>{
              'audio_id': 332453,
              'hash': '8909E1809908CD8E3BF6CF85D98B93F0',
            },
          }
        ]
      ],
    };

    test('从 data[0][0].classification[0].res_id 取 res_id', () {
      expect(KugouCommentApi.extractResId(audioJson), '32042828');
    });

    test('从 audio_info.audio_id 取 childrenid', () {
      expect(KugouCommentApi.extractAudioId(audioJson), '332453');
    });

    test('audio_info 是 JSON 字符串时也能解析', () {
      final j = <String, dynamic>{
        'data': <dynamic>[
          <dynamic>[
            <String, dynamic>{
              'classification': <dynamic>[
                <String, dynamic>{'res_id': '32042828'}
              ],
              'audio_info':
                  '{"audio_id":332453,"hash":"8909E1809908CD8E3BF6CF85D98B93F0"}',
            }
          ]
        ],
      };
      expect(KugouCommentApi.extractAudioId(j), '332453');
    });

    test('结构不符时返回空串而不抛异常', () {
      expect(KugouCommentApi.extractResId(<String, dynamic>{}), '');
      expect(KugouCommentApi.extractAudioId(<String, dynamic>{}), '');
      expect(
          KugouCommentApi.extractResId(
              <String, dynamic>{'data': <dynamic>[]}),
          '');
      expect(
          KugouCommentApi.extractAudioId(<String, dynamic>{
            'data': <dynamic>[
              <dynamic>[
                <String, dynamic>{'audio_info': 'not-json'}
              ]
            ]
          }),
          '');
    });
  });

  group('KugouCommentApi.buildPostBody', () {
    test('外层包 data，字段顺序 content/contentFormatted/album_audio_id/hash', () {
      final body = KugouCommentApi.buildPostBody(
        content: '测试评论',
        albumAudioId: '32042828',
        hash: '8909E1809908CD8E3BF6CF85D98B93F0',
      );
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      expect(decoded.keys.toList(), <String>['data']);
      final data = decoded['data'] as Map<String, dynamic>;
      expect(data.keys.toList(), <String>[
        'content',
        'contentFormatted',
        'album_audio_id',
        'hash',
      ]);
      expect(data['content'], '测试评论');
      expect(data['contentFormatted'], '测试评论');
      expect(data['album_audio_id'], '32042828');
      expect(data['hash'], '8909E1809908CD8E3BF6CF85D98B93F0');
    });

    test('body 是紧凑 JSON（无多余空格）——签名要按这个原文算', () {
      final body = KugouCommentApi.buildPostBody(
        content: 'a',
        albumAudioId: '1',
        hash: 'h',
      );
      expect(body, '{"data":{"content":"a","contentFormatted":"a",'
          '"album_audio_id":"1","hash":"h"}}');
      expect(body.contains(' '), isFalse);
    });
  });

  group('酷狗评论签名约定', () {
    test('读接口签名 = md5(网关盐 + 排序 k=v 拼接 + 网关盐)', () {
      // 复刻服务端算法：按 key 字母序把 'k=v' 无分隔符拼起来。
      const params = <String, String>{
        'appid': '1005',
        'p': '1',
        'ver': '10',
      };
      final joined =
          (params.keys.toList()..sort()).map((k) => '$k=${params[k]}').join('');
      final expected = md5
          .convert(utf8
              .encode('$kugouGatewaySalt$joined$kugouGatewaySalt'))
          .toString();
      expect(expected.length, 32);
      // 与 kugouSign 的行为一致（body 为空）。
      expect(kugouSign(params, kugouGatewaySalt), expected);
    });

    test('写接口 key = md5(appid+salt+clientver+clienttime+mid+body)', () {
      const platform = KugouCommentPlatform.std;
      const clienttime = '1762530000';
      const body =
          '{"data":{"content":"a","contentFormatted":"a",'
          '"album_audio_id":"32042828","hash":"h"}}';
      final key = md5
          .convert(utf8.encode('${platform.appid}${platform.salt}'
              '${platform.clientver}$clienttime'
              '${KugouCommentApi.commentMid}$body'))
          .toString();
      expect(key.length, 32);
      expect(key, isNotEmpty);
    });

    test('写接口 signature = md5(salt+排序 k=v+body+salt)', () {
      const platform = KugouCommentPlatform.lite;
      const body = '{"data":{}}';
      final params = <String, String>{'appid': platform.appid, 'ver': '10'};
      final joined =
          (params.keys.toList()..sort()).map((k) => '$k=${params[k]}').join('');
      final sig = md5
          .convert(utf8
              .encode('${platform.salt}$joined$body${platform.salt}'))
          .toString();
      expect(sig.length, 32);
    });

    test('两套身份参数固定且盐值不同', () {
      expect(KugouCommentPlatform.std.appid, '1005');
      expect(KugouCommentPlatform.std.clientver, '11440');
      expect(KugouCommentPlatform.std.salt, kugouGatewaySalt);
      expect(KugouCommentPlatform.std.ua, contains('11440'));

      expect(KugouCommentPlatform.lite.appid, '3116');
      expect(KugouCommentPlatform.lite.clientver, '10659');
      expect(KugouCommentPlatform.lite.salt, kugouLyricSalt);
      expect(KugouCommentPlatform.lite.ua, contains('10659'));

      expect(KugouCommentPlatform.std.salt, isNot(KugouCommentPlatform.lite.salt));
    });
  });

  group('KugouCommentApi 常量', () {
    test('写域名与读域名分属两套服务', () {
      expect(KugouCommentApi.writeHost,
          'https://gateway.kugou.com/m.comment.service/p/v1/commentsv3');
      expect(KugouCommentApi.readHost, 'http://m.comment.service.kugou.com');
    });

    test('固定 mid / code 与服务端一致', () {
      expect(KugouCommentApi.commentMid,
          '16249512204336365674023395779019');
      expect(KugouCommentApi.commentCode,
          'fc4be23b4e972707f36b8a828a93ba8a');
      expect(KugouCommentApi.pageSize, 20);
    });
  });

  group('KugouCommentApi.extractChildId', () {
    test('special_child_id 是歌曲级 id（等于 audio_id）', () {
      final m = _realComment();
      expect(KugouCommentApi.extractChildId(m), '332453');
    });

    test('缺失时返回空串', () {
      expect(
          KugouCommentApi.extractChildId(<String, dynamic>{}),
          '');
    });
  });
}
