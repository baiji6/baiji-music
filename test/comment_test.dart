// QQ / 网易云歌曲评论：解析层单测（样本为真实抓包，非手编）。
//
// QQ 样本：歌曲 108478《失踪》musicu globalComment 模块（GetHotCommentList /
// GetCmCount，2025-10 沙箱实抓）。
// 网易云样本：歌曲 657666《起风了》api/v1/resource/comments（2025-10 实抓）。
import 'package:baiji_music/network/netease_comment_api.dart';
import 'package:baiji_music/network/qq_comment_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ==================== QQ ====================

  group('QqCommentApi.parseCommentList（真实热评样本）', () {
    // 真实 GetHotCommentList 响应 data 部分（歌曲 108478）
    final data = {
  "CommentList": {
    "Comments": [
      {
        "CmId": "1!LODwuV7VZRpoiuSWWb51FhfeEcUJJeZr1sxwJ6CrC8b2hE587aGopPnId2tGAuKl",
        "Nick": "1973",
        "Avatar": "http://thirdqq.qlogo.cn/g?b=sdk&k=PH30IaudqA7W15moyr7tbA&kti=aCdLkBHyHcI&s=140&t=1557004046",
        "Content": "喜欢sandy来签到了，太喜欢太喜欢了，听她的歌根本停不下来。😃😃😃😃😃😃😃😃",
        "PubTime": 1553659472,
        "PraiseNum": 15,
        "IsPraised": 0,
        "ReplyCnt": 0,
        "HotScore": "15",
        "IsHot": null,
        "SubComments": []
      },
      {
        "CmId": "1!rXmQKAp-5NVUqnsVtE3DNS8G6lRLrzJt6ZgGRsu42i8BSqgZzjF7RNmjKV5akD0M",
        "Nick": "就是爱音乐",
        "Avatar": "http://thirdqq.qlogo.cn/g?b=sdk&k=1GrriaUjbDicBJX4EroHsQEQ&s=140&t=1556365421",
        "Content": "这是属于越听越有味道的歌",
        "PubTime": 1570672794,
        "PraiseNum": 10,
        "IsPraised": 0,
        "ReplyCnt": 0,
        "HotScore": "10",
        "IsHot": null,
        "SubComments": []
      },
      {
        "CmId": "1!xHmC2fen8Ksspk1g2QiSifyouMlC4bBWyb.EoP8dkbd8QrX9WCsR2Y8ec1HhJWSM",
        "Nick": "阿利松",
        "Avatar": "http://thirdqq.qlogo.cn/g?b=sdk&k=6PvF5RUTRBFQJdQomEBeibg&s=140&t=1557291618",
        "Content": "商台俞铮作词，俞铮是林忆莲刚进电台给她起艺名六一一那个人，也是比较欣赏忆莲的。",
        "PubTime": 1585759598,
        "PraiseNum": 5,
        "IsPraised": 0,
        "ReplyCnt": 1,
        "HotScore": "5",
        "IsHot": null,
        "SubComments": [
          {
            "EncryptUin": "oKoqoK4k7KvkNn**",
            "Content": "她真有眼光，那今年美高梅的商演大概也是俞牵线搭桥了",
            "Nick": "GAlA",
            "CmId": "1!xHmC2fen8Ksspk1g2QiSifyouMlC4bBWyb.EoP8dkbcHr5KJ1nBwpG5NAebPFmun0.iIZVqqCPqP-TZuwIIlHQ**",
            "AuthorPraise": 0,
            "ParentComment": {
              "EncryptUin": "",
              "Content": "",
              "Nick": "",
              "CmId": "",
              "RplCnt": 0,
              "AuthorPraise": 0,
              "GodState": 0,
              "RvLabel": 0,
              "IsBlocked": 0,
              "Pic": "",
              "PicSize": "",
              "AuInvite": 0,
              "SongTsElems": [],
              "EmoPic": "",
              "EmoPkgID": 0,
              "Audio": {
                "URL": "",
                "Dur": 0,
                "Txt": "",
                "Lang": "",
                "OriginalInternalURL": "",
                "TranscodeURL": "",
                "TranscodeStatus": "",
                "AttributeStatus": "",
                "Attribute": "",
                "SpeechToTextStatus": "",
                "Language": "",
                "SongRecognitionStatus": "",
                "Timbre": "",
                "RecognizedSongId": "",
                "SongName": "",
                "TimbreRecognitionStatus": "",
                "MP3URL": "",
                "TranscodeMP3Status": "",
                "VoiceType": 0,
                "MelodyID": "",
                "TimbreID": "",
                "MelodyName": "",
                "VenusUgcID": "",
                "RecognizeType": 0
              }
            },
            "Avatar": "",
            "PubTime": 0,
            "IsPraised": 0,
            "PraiseNum": 0,
            "VipIcon": "",
            "CommitState": 2,
            "UserType": "",
            "Permission": 0,
            "RankScore": "",
            "SeqNo": "",
            "IdentityPic": "",
            "IdentityType": 0,
            "PdStaticPic": "",
            "PdDynamicPic": "",
            "GodState": 0,
            "RvLabel": 0,
            "IsBlocked": 0,
            "Pic": "",
            "PicSize": "",
            "AuInvite": 0,
            "SongTsElems": [],
            "EmoPic": "",
            "EmoPkgID": 0
          }
        ]
      }
    ],
    "HasMore": 1,
    "Total": 5
  }
};

    test('解析出全部评论并映射字段', () {
      final page = QqCommentApi.parseCommentList(data);
      expect(page.latest.length, 3);
      expect(page.total, 5);
      expect(page.hasMore, true);

      final c = page.latest.first;
      expect(c.id, '1!LODwuV7VZRpoiuSWWb51FhfeEcUJJeZr1sxwJ6CrC8b2hE587aGopPnId2tGAuKl');
      expect(c.nickname, '1973');
      expect(c.content, startsWith('喜欢sandy来签到了'));
      // PubTime 是秒 → 毫秒
      expect(c.timeMs, 1553659472000);
      expect(c.likeCount, 15);
      expect(c.liked, false);
      expect(c.replyCount, 0);
      // HotScore 服务端给的是字符串 "15" → int 15
      expect(c.isHot, true);
    });

    test('SubComments 子评论递归解析（PubTime=0 → timeMs=0）', () {
      final page = QqCommentApi.parseCommentList(data);
      final parent = page.latest[2];
      expect(parent.nickname, '阿利松');
      expect(parent.replyCount, 1);
      expect(parent.hasReplies, true);
      final sub = parent.replies.single;
      expect(sub.nickname, 'GAlA');
      expect(sub.content, startsWith('她真有眼光'));
      expect(sub.timeMs, 0);
      expect(sub.likeCount, 0);
      expect(sub.liked, false);
    });

    test('CommentList 缺失 / Comments 非列表 → 空页不抛异常', () {
      expect(QqCommentApi.parseCommentList(const {}).isEmpty, true);
      expect(
          QqCommentApi.parseCommentList(const {'CommentList': 'x'}).isEmpty,
          true);
      expect(
          QqCommentApi.parseCommentList(const {
            'CommentList': {'Comments': 'not-a-list', 'Total': 9, 'HasMore': 1}
          }).isEmpty,
          true);
    });

    test('Comments 里的畸形项被跳过', () {
      final page = QqCommentApi.parseCommentList(const {
        'CommentList': {
          'Comments': ['junk', 42, null],
          'Total': 0,
          'HasMore': 0,
        }
      });
      expect(page.latest, isEmpty);
      expect(page.total, 0);
      expect(page.hasMore, false);
    });
  });

  group('QqCommentApi.parseCommentCount（真实样本）', () {
    test('取 data.response.count', () {
      // 真实 GetCmCount 响应 data 部分
      expect(QqCommentApi.parseCommentCount({
  "response": {
    "biz_type": 1,
    "biz_id": "108478",
    "biz_sub_type": 2,
    "count": 33,
    "count_ver": "1792228837587858506",
    "count_view": "33",
    "related_id": "",
    "tip": "",
    "icon_list": null
  },
  "cmTabType": 0
}), 33);
    });

    test('response 缺失 → 0', () {
      expect(QqCommentApi.parseCommentCount(const {}), 0);
      expect(QqCommentApi.parseCommentCount(const {'response': 'x'}), 0);
    });
  });

  // ==================== req_0 外层兼容（防漏剥 data 层） ====================

  group('QqCommentApi 完整 req_0 形状（live 回归 2026-10-18）', () {
    // executeRaw 返回完整 req_0：{code, msg, data: {CommentList: ...}}。
    // 曾因漏剥 data 层导致《晴天》code=0 但评论解析为空（total=0）。
    test('parseCommentList 自动剥 data 层', () {
      final req0 = <String, dynamic>{
        'code': 0,
        'msg': '',
        'data': <String, dynamic>{
          'AllowComment': 1,
          'CommentList': <String, dynamic>{
            'Comments': <dynamic>[
              <String, dynamic>{
                'CmId': 'c1',
                'Nick': '测试',
                'Content': '内容',
                'PubTime': 1792300087,
                'PraiseNum': 3,
              }
            ],
            'Total': 333059,
            'HasMore': 1,
          }
        }
      };
      final page = QqCommentApi.parseCommentList(req0);
      expect(page.latest.length, 1);
      expect(page.latest.single.content, '内容');
      expect(page.total, 333059);
      expect(page.hasMore, true);
    });

    test('parseCommentCount 自动剥 data 层', () {
      final req0 = <String, dynamic>{
        'code': 0,
        'data': <String, dynamic>{
          'response': <String, dynamic>{'count': 33}
        }
      };
      expect(QqCommentApi.parseCommentCount(req0), 33);
    });

    test('业务层无 CommentList/response 时不误剥', () {
      // 空业务层（无 data 内层）→ 空页，不抛异常
      expect(QqCommentApi.parseCommentList(const {'code': 0, 'data': 'x'}).isEmpty,
          true);
      expect(QqCommentApi.parseCommentCount(const {'code': 0, 'data': 1}), 0);
    });
  });

  // ==================== 网易云 ====================

  group('NeteaseCommentApi.threadId', () {
    test('R_SO_4_ 前缀', () {
      expect(NeteaseCommentApi.threadId('657666'), 'R_SO_4_657666');
    });
  });

  group('NeteaseCommentApi.parseComments（真实样本）', () {
    // 真实 /api/v1/resource/comments/R_SO_4_657666 响应（歌曲 657666）
    final data = {
  "code": 200,
  "total": 62191,
  "more": true,
  "userId": -1,
  "isMusician": false,
  "hotComments": [
    {
      "commentId": 4693601,
      "content": "小学二年级看的，看到初号机生吃使徒，血流了一条河，午饭没吃完",
      "time": 1412493171422,
      "timeStr": "2014-10-05",
      "likedCount": 94550,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 16065892,
        "nickname": "Vir凌",
        "avatarUrl": "http://p2.music.126.net/wRtgF157vbWYq9zt2hReVA==/3243559304854960.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 24842185,
      "content": "这首诞生于1995年由高桥洋子演唱的主题曲作为卡拉OK的必点曲目占据排行榜长达19年，压倒性的人气也让这首歌成为了动漫歌曲的代表。由于这首歌和所配的片头动画与整部动画相符合，再加上新世纪福音战士的巨大影响力和此歌曲所配片头动画的巨大视觉冲击力，使得这首歌成为最经典的动漫歌曲之一。",
      "time": 1435926866187,
      "timeStr": "2015-07-03",
      "likedCount": 62147,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 30115128,
        "nickname": "御坂美琴",
        "avatarUrl": "http://p2.music.126.net/uQkCcHycawYHB-c6Ee_Knw==/109951167485103121.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 71159014,
      "content": "《新世纪福音战士》经典OP曲《残酷天使的行动纲领》词作者及川眠子在推特上爆料：“这工作是经纪人偶然敲定的。开了30分钟短会后匆匆浏览了一下企划书，快进播放了两集左右的录像。好，随便写点自己喜欢的东西吧！于是，大约两小时就写完了。破坏了大家的梦想，对不起。”",
      "time": 1455621895148,
      "timeStr": "2016-02-16",
      "likedCount": 46077,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 96383677,
        "nickname": "啊啊啊啊啊啊啊啊啊啊啊星",
        "avatarUrl": "http://p2.music.126.net/N7fC4JdTkszZa8Mmd1G1ZQ==/109951166070803923.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 146698963,
      "content": "说实话EVA真心不适合小孩子看，他并不是纯粹的燃，热血类机甲动漫。其中。穿插着N多哲理思想，社会现实，人性丑恶。尤其最后两集，即使成年人都不是说人人都能看懂的。",
      "time": 1461735325550,
      "timeStr": "2016-04-27",
      "likedCount": 27115,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 41823767,
        "nickname": "扬州市民亚里士缺德",
        "avatarUrl": "http://p2.music.126.net/yjNaSWNRcQO5PGHxNkd48g==/109951168276282772.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 5230148354,
      "content": "EVA的毒太深了，今天在厕所看着我家紫绿配色的拖把楞了半天，想这玩意是不是初号机联名款",
      "time": 1612526069034,
      "timeStr": "2021-02-05",
      "likedCount": 24883,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 1552914404,
        "nickname": "wingman_octane",
        "avatarUrl": "http://p2.music.126.net/hOqEU1ZDwYJOM9Rfpzvf2g==/109951168459146286.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 3338162714,
      "content": "OPPO联名我买了，买的初号机款然后没电了，差点把我给杀了",
      "time": 1591645309605,
      "timeStr": "2020-06-09",
      "likedCount": 23785,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 485555833,
        "nickname": "呕精精",
        "avatarUrl": "http://p2.music.126.net/6oDom0d821MfWuI9URx45g==/109951165124646167.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 5838056692,
      "content": "我是碇真嗣，我被我爸pua他让我开eva不开就滚蛋，但是驾驶eva让我感到痛苦，于是我离开了nerv。现在我打算卷土重来，v我50，我开初号机创死我爹",
      "time": 1674104805865,
      "timeStr": "2023-01-19",
      "likedCount": 23408,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 7982282755,
        "nickname": "月下姬妲",
        "avatarUrl": "http://p2.music.126.net/YSKy6jpZEgCb7IQYaOi1rA==/109951169275412111.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 13733950,
      "content": "最早教会我们“暴走”这个词的不是王尼玛，是初号机",
      "time": 1427555085599,
      "timeStr": "2015-03-28",
      "likedCount": 17526,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 58439299,
        "nickname": "Sternengseang",
        "avatarUrl": "http://p2.music.126.net/ylOUq71G5vYxaIAwvnNEZw==/3412884110791567.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 34488072,
      "content": "上周打刀塔对面一蓝胖的ID就叫：今日凌波明日香[大哭] 然后我说我喜欢凌波丽他说他喜欢香香，满场追着我干[大哭]",
      "time": 1441288097079,
      "timeStr": "2015-09-03",
      "likedCount": 17262,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 30329656,
        "nickname": "EAMOO",
        "avatarUrl": "http://p2.music.126.net/_yRYnrygNFumnrshg9_4Og==/1424967081310403.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 7300003,
      "content": "国语不是鞠萍姐姐唱的",
      "time": 1418916250021,
      "timeStr": "2014-12-18",
      "likedCount": 16092,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 42747914,
        "nickname": "强力去油",
        "avatarUrl": "http://p2.music.126.net/--z7hSu9D_zSJlXy4AhltQ==/109951166070514939.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 3290790297,
      "content": "其实少年不想成为神话，少年只想要爱与被爱",
      "time": 1588299992862,
      "timeStr": "2020-05-01",
      "likedCount": 13605,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 574040026,
        "nickname": "天绫赛高",
        "avatarUrl": "http://p2.music.126.net/eQzx_2kKgtIH57BJ2O0mHg==/109951163074952206.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 5598283786,
      "content": "今天作业和人类只能补完一个",
      "time": 1645663496309,
      "timeStr": "2022-02-24",
      "likedCount": 13029,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 2113146893,
        "nickname": "絵梨_",
        "avatarUrl": "http://p2.music.126.net/8I7_ztFom649S7xhjbWv1A==/109951172981654990.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 24702431,
      "content": "然而6月22日过去了，使徒并未来袭。(╥﹏╥)",
      "time": 1435848770381,
      "timeStr": "2015-07-02",
      "likedCount": 12593,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 63146399,
        "nickname": "敦敦我是你的月下兽啊",
        "avatarUrl": "http://p2.music.126.net/DbubZ0hN77ZMHvT9mu9ohg==/109951165612867764.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 125760781,
      "content": "等到了使徒入侵的那一天，却错过了登上eva的年龄。",
      "time": 1457013443413,
      "timeStr": "2016-03-03",
      "likedCount": 12347,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 60696069,
        "nickname": "酸素抹茶",
        "avatarUrl": "http://p2.music.126.net/_iX8ea_ll2OWP6RyrYRzgQ==/109951163267316774.jpg"
      },
      "beReplied": []
    },
    {
      "commentId": 5397813174,
      "content": "我来科普一下《EVA》。                                   90年代初期，日本泡沫经济告别最后的辉煌，随后而来的阪神大地震，东京地铁沙林毒气事件等灾难让人们失去了对生活的信念感，“末日论”再次兴起，就在失业的年轻人面对无望的未来，精神世界陷入虚无之时，《EVA》播出。",
      "time": 1629440208703,
      "timeStr": "2021-08-20",
      "likedCount": 11891,
      "liked": false,
      "parentCommentId": 0,
      "user": {
        "userId": 3300710395,
        "nickname": "一生无暇只听古典",
        "avatarUrl": "http://p2.music.126.net/6naC9aLf8ZccfbGpXvBfIg==/109951170333610176.jpg"
      },
      "beReplied": []
    }
  ],
  "topComments": [],
  "comments": [
    {
      "commentId": 9666943552,
      "content": "差评，我的爱人是纸片",
      "time": 1792221458947,
      "timeStr": "15:17",
      "likedCount": 1,
      "liked": false,
      "parentCommentId": 9665533410,
      "user": {
        "userId": 17315657237,
        "nickname": "柴fssu_",
        "avatarUrl": "http://p1.music.126.net/K7gllztB51s108fIdT_vrw==/109951172891010840.jpg"
      },
      "beReplied": [
        {
          "beRepliedCommentId": 9665533410,
          "content": "亲，我是地球online的客服，请问您对这次人生的体验满意度怎么样？",
          "status": 0,
          "user": {
            "userId": 510009699,
            "nickname": "晚鳯stars",
            "avatarUrl": "http://p2.music.126.net/_1qd2WCFzVyi599oI7w9cQ==/109951170046265524.jpg"
          }
        }
      ]
    },
    {
      "commentId": 9666883617,
      "content": "这也太便宜他们了应该给他们做成串串香的",
      "time": 1792217226952,
      "timeStr": "14:07",
      "likedCount": 0,
      "liked": false,
      "parentCommentId": 5808926216,
      "user": {
        "userId": 17878211632,
        "nickname": "渚薰-EVA01",
        "avatarUrl": "http://p1.music.126.net/PYlNaXdjVgPRHcpKXO67Ag==/109951173831658453.jpg"
      },
      "beReplied": [
        {
          "beRepliedCommentId": 9634252108,
          "content": "（正在驾驶13号机准备开启加夫之门惩罚和平那群小鬼）",
          "status": 0,
          "user": {
            "userId": 3809372589,
            "nickname": "用户3809372589",
            "avatarUrl": "http://p2.music.126.net/MwHEklBdXmUav8fJs5WYxg==/109951171183380461.jpg"
          }
        }
      ]
    },
    {
      "commentId": 9666844039,
      "content": "是人我吃",
      "time": 1792217143000,
      "timeStr": "14:05",
      "likedCount": 0,
      "liked": false,
      "parentCommentId": 5808926216,
      "user": {
        "userId": 17878211632,
        "nickname": "渚薰-EVA01",
        "avatarUrl": "http://p1.music.126.net/PYlNaXdjVgPRHcpKXO67Ag==/109951173831658453.jpg"
      },
      "beReplied": [
        {
          "beRepliedCommentId": 9403611670,
          "content": "我同学他弟弟说六号机是蓝色大螳螂[怒][怒]",
          "status": 0,
          "user": {
            "userId": 8842902248,
            "nickname": "太阳系的卡兹",
            "avatarUrl": "http://p2.music.126.net/YoYesQ5__63NfrlcPcxd0Q==/109951172245755233.jpg"
          }
        }
      ]
    }
  ]
};

    test('热评 / 最新分桶 + total + more', () {
      final page = NeteaseCommentApi.parseComments(data);
      expect(page.hot.length, 15);
      expect(page.latest.length, 3);
      expect(page.total, 62191);
      expect(page.hasMore, true);
      expect(page.isEmpty, false);
    });

    test('topComments 并入热评桶', () {
      final page = NeteaseCommentApi.parseComments(const {
        'topComments': [
          {'commentId': 1, 'content': '置顶', 'user': {'nickname': '官方'}}
        ],
        'comments': [
          {'commentId': 2, 'content': '普通', 'user': {'nickname': '路人'}}
        ],
      });
      expect(page.hot.single.id, '1');
      expect(page.hot.single.isHot, true);
      expect(page.latest.single.id, '2');
      expect(page.latest.single.isHot, false);
    });

    test('字段映射：毫秒时间直接用 + liked/likedCount + user', () {
      final page = NeteaseCommentApi.parseComments(data);
      final c = page.hot.first;
      expect(c.id, '4693601');
      expect(c.nickname, 'Vir凌');
      expect(c.avatarUrl, startsWith('http://p2.music.126.net/'));
      expect(c.content, startsWith('小学二年级看的'));
      // time 是毫秒，不再 ×1000
      expect(c.timeMs, 1412493171422);
      expect(c.likeCount, 94550);
      expect(c.liked, false);
      expect(c.isHot, true);
    });

    test('beReplied 回复解析（无 time → timeMs=0）', () {
      final page = NeteaseCommentApi.parseComments(data);
      // 真实样本里带回复的评论在最新桶（hot 全是无回复的热评）
      final withReply = [...page.hot, ...page.latest]
          .firstWhere((c) => c.hasReplies);
      expect(withReply.replyCount, greaterThan(0));
      final r = withReply.replies.first;
      expect(r.nickname, isNotEmpty);
      expect(r.content, isNotEmpty);
      expect(r.timeMs, 0);
    });

    test('缺字段 / 空响应不抛异常', () {
      expect(NeteaseCommentApi.parseComments(const {}).isEmpty, true);
      final page = NeteaseCommentApi.parseComments(const {
        'hotComments': [<String, dynamic>{}],
        'comments': ['junk'],
      });
      expect(page.hot.single.id, '');
      expect(page.hot.single.nickname, '');
      expect(page.hot.single.content, '');
      expect(page.hot.single.timeMs, 0);
      expect(page.latest, isEmpty);
    });
  });

  group('NeteaseCommentApi.csrfFromCookie', () {
    test('取 __csrf 值', () {
      expect(
        NeteaseCommentApi.csrfFromCookie(
            'MUSIC_U=abc123; __csrf=deadbeef; os=pc'),
        'deadbeef',
      );
    });

    test('无 __csrf → 空串', () {
      expect(NeteaseCommentApi.csrfFromCookie('MUSIC_U=abc123'), '');
      expect(NeteaseCommentApi.csrfFromCookie(''), '');
    });
  });
}
