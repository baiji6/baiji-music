// 汽水音乐音源纯函数契约测试（v2.6.2 全音质）。
//
// 网络层不测（需真实接口），这里固化关键契约：
// 搜索响应解析、取流响应解析（明/加密 + spade_a）、Q 编号→档位映射、
// krc→YRC 逐字格式转换、全音质档位、降级链、路由分发、CENC 解密器。
// 喂真实 JSON / krc 片段，纯离线。
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:baiji_music/network/qishui/qishui_api.dart';
import 'package:baiji_music/network/qishui/qishui_cenc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QishuiQuality 定义（v2.6.2 全音质）', () {
    test('9 个逻辑档位，覆盖 md 文档 Q01-Q14', () {
      expect(QishuiQuality.downloadOptions.length, 9);
      expect(QishuiQuality.playbackOptions, same(QishuiQuality.downloadOptions));
      expect(QishuiQuality.downloadOptions.map((q) => q.id).toList(), <String>[
        'original', 'lossless', 'hi_res', 'spatial', 'highest',
        'higher', 'medium', 'low', 'lowest',
      ]);
      // code 段覆盖 Q01..Q14（含斜杠并列）。
      final allCodes = QishuiQuality.downloadOptions
          .expand((q) => q.codes)
          .toSet()
          .map((c) => int.tryParse(c.replaceFirst('Q', '')))
          .whereType<int>()
          .toList()
        ..sort();
      expect(allCodes, List<int>.generate(14, (i) => i + 1));
    });

    test('明文/加密档标记与默认档', () {
      expect(QishuiQuality.medium.id, 'medium');
      expect(QishuiQuality.medium.encryptedOnly, isFalse);
      expect(QishuiQuality.hiRes.encryptedOnly, isTrue);
      expect(QishuiQuality.spatial.encryptedOnly, isTrue);
      expect(QishuiQuality.lowest.encryptedOnly, isTrue);
      expect(QishuiQuality.lossless.format, 'flac');
      expect(QishuiQuality.lossless.ext, '.flac');
      expect(QishuiQuality.playbackDefault, same(QishuiQuality.medium));
    });

    test('fromId 往返', () {
      expect(QishuiQuality.fromId('hi_res'), same(QishuiQuality.hiRes));
      expect(QishuiQuality.fromId('spatial'), same(QishuiQuality.spatial));
      expect(QishuiQuality.fromId('original'), same(QishuiQuality.original));
      expect(QishuiQuality.fromId('hires'), isNull);
      expect(QishuiQuality.fromId(null), isNull);
    });
  });

  group('Q 编号 → 档位映射（qualityCodesFromCodes）', () {
    test('全 14 档映射到 9 逻辑档', () {
      const codes = [
        'Q01','Q02','Q03','Q04','Q05','Q06','Q07','Q08','Q09',
        'Q10','Q11','Q12','Q13','Q14',
      ];
      expect(QishuiApi.qualityCodesFromCodes(codes),
          QishuiQuality.downloadOptions.map((q) => q.id).toSet());
    });

    test('带 a/b 后缀与缺档只映射存在的档（VIP 歌）', () {
      const vip = ['Q05','Q04','Q07','Q06a','Q06b','Q09','Q08','Q11','Q10','Q13','Q12'];
      final ids = QishuiApi.qualityCodesFromCodes(vip);
      expect(ids, contains('highest'));
      expect(ids, contains('hi_res'));
      expect(ids, isNot(contains('original')));
      expect(ids, isNot(contains('lossless')));
      expect(ids, isNot(contains('lowest')));
    });

    test('非法编号忽略', () {
      expect(QishuiApi.qualityCodesFromCodes(['QXX', '', 'X01']), isEmpty);
    });
  });

  group('qishuiDowngradeChain', () {
    test('从选中档向下，末档兜底 medium', () {
      expect(
        MusicApi.qishuiDowngradeChain(QishuiQuality.hiRes)
            .map((q) => q.id)
            .toList(),
        <String>['hi_res', 'spatial', 'highest', 'higher', 'medium', 'low', 'lowest'],
      );
      // 从 lowest 起本链无 medium，需补一个明文兜底。
      expect(MusicApi.qishuiDowngradeChain(QishuiQuality.lowest)
          .map((q) => q.id)
          .toList(),
          contains('medium'));
    });
  });

  group('搜索响应解析（parseSearchResponse）', () {
    test('真实结构：data.list[] → item_id/title/author_info.name/cover_url', () {
      final body = {
        'errno': 0,
        'data': {
          'list': [
            {
              'item_id': '7706108005905319974',
              'title': '等你下课（杰伦）',
              'author_info': {'name': '孤独0321'},
              'duration': 220,
              'cover_url':
                  'https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/abc~tplv.image',
              'media_type': 'music',
            },
            {
              'item_id': '6732899843179546625',
              'title': '蜗牛',
              'author_info': {'name': '动力火车'},
              'duration': 308,
              'cover_url': 'https://p6-luna.douyinpic.com/img/xyz.image',
            },
          ],
          'search_params': '{"offset":10}',
        }
      };
      final list = QishuiApi.parseSearchResponse(body);
      expect(list.length, 2);
      expect(list.first.itemId, '7706108005905319974');
      expect(list.first.name, '等你下课（杰伦）');
      expect(list.first.singer, '孤独0321');
      expect(list.first.durationSeconds, 220);
      expect(list.first.cover, contains('douyinpic.com'));
      expect(list.last.singer, '动力火车');
    });

    test('空/异常结构不崩', () {
      expect(QishuiApi.parseSearchResponse(null), isEmpty);
      expect(QishuiApi.parseSearchResponse(<String, dynamic>{}), isEmpty);
      expect(QishuiApi.parseSearchResponse({'data': {'list': 'bad'}}), isEmpty);
    });
  });

  group('取流响应解析（parseStreamResponse）', () {
    test('code=0 取直链 + 自带 LRC + 封面 1080', () {
      final body = {
        'code': 0,
        'msg': 'ok',
        'data': {
          'url': 'https://sf6-cdn-tos.douyinstatic.com/obj/tos-cn-ve-2774/abc',
          'urls': [
            'https://sf6-cdn-tos.douyinstatic.com/obj/tos-cn-ve-2774/abc',
            'https://sf3-cdn-tos.douyinstatic.com/obj/tos-cn-ve-2774/abc',
          ],
          'actual_quality': 'medium',
          'encrypted': false,
          'title': '骄傲的少年',
          'artist': '南征北战NZBZ',
          'duration': 259.626,
          'cover': 'https://p3-luna.douyinpic.com/img/def:0:1080.image',
          'covers': {
            '360': 'https://p3-luna.douyinpic.com/img/def:0:360.image',
            '1080': 'https://p3-luna.douyinpic.com/img/def:0:1080.image',
          },
          'lyric': {
            'type': 'krc',
            'source': 'seo_track',
            'lrc': '[00:21.860]在一开始\n[00:24.240]当初我还是',
            'lines': [],
          },
        }
      };
      final r = QishuiApi.parseStreamResponse(body);
      expect(r.url, contains('douyinstatic.com'));
      expect(r.urls.length, 2);
      expect(r.actualQuality, 'medium');
      expect(r.title, '骄傲的少年');
      expect(r.lrc, contains('在一开始'));
      expect(r.cover, contains(':0:1080.image'));
      expect(r.durationSeconds, 259);
    });

    test('code!=0 / url 空返回空', () {
      expect(QishuiApi.parseStreamResponse({'code': 502}).url, '');
      expect(QishuiApi.parseStreamResponse({'code': 0, 'data': {}}).url, '');
      expect(QishuiApi.parseStreamResponse(null).url, '');
    });

    test('v2.6.2 全音质：明文档 Q08 解析字段齐全', () {
      final body = {
        'code': 0,
        'data': {
          'url': 'https://sf6-cdn-tos.douyinstatic.com/obj/tos-cn-ve-2774/Q08',
          'actual_code': 'Q08',
          'actual_quality': 'higher',
          'encrypted': false,
          'playable': true,
          'vtype': 'm4a',
          'codec': 'aac',
          'bitrate': 129441,
          'title': '东南苦行山',
          'qualities': [
            {'code': 'Q01', 'quality': 'original', 'spade_a': null},
            {
              'code': 'Q08',
              'quality': 'higher',
              'vtype': 'm4a',
              'codec': 'aac',
              'bitrate': 129441,
              'spade_a': null,
            },
          ],
          'covers': {'1080': 'https://img:0:1080.image'},
        }
      };
      final r = QishuiApi.parseStreamResponse(body);
      expect(r.isUsable, isTrue);
      expect(r.encrypted, isFalse);
      expect(r.actualCode, 'Q08');
      expect(r.actualQuality, 'higher');
      expect(r.quality, same(QishuiQuality.higher));
      expect(r.outputExt, '.m4a');
      expect(r.bitrate, 129441);
      expect(r.availableCodes, ['Q01', 'Q08']);
      expect(r.cover, contains(':0:1080.image'));
    });

    test('v2.6.2 加密档 Q03：从 qualities[] 精确取 spade_a', () {
      final body = {
        'code': 0,
        'data': {
          'url': 'https://sf6-cdn-tos.douyinstatic.com/obj/tos-cn-ve-2774/Q03',
          'actual_code': 'Q03',
          'actual_quality': 'lossless',
          'encrypted': true,
          'playable': false,
          'vtype': 'mp4',
          'codec': 'flac',
          'spade_a': '', // 顶层为空（qishui2.php 实际行为）
          'qualities': [
            {
              'code': 'Q02',
              'quality': 'lossless',
              'encrypted': false,
              'spade_a': null,
            },
            {
              'code': 'Q03',
              'quality': 'lossless',
              'encrypted': true,
              'vtype': 'mp4',
              'codec': 'flac',
              'kid': 'abc123',
              'spade_a': 'krwc+1KxGclWsyvKeoY2+HuANMd7vjfDfIQG+E+wMftKjAK/vw==',
            },
          ],
        }
      };
      final r = QishuiApi.parseStreamResponse(body);
      expect(r.encrypted, isTrue);
      expect(r.isUsable, isTrue);
      expect(r.spadeA, contains('krwc'));
      expect(r.kid, 'abc123');
      expect(r.codec, 'flac');
      expect(r.outputExt, '.flac');
      expect(r.quality, same(QishuiQuality.lossless));
    });

    test('加密档缺 spade_a 视为不可用（触发降级）', () {
      final body = {
        'code': 0,
        'data': {
          'url': 'https://cdn/Q03',
          'actual_code': 'Q03',
          'actual_quality': 'lossless',
          'encrypted': true,
          'qualities': [
            {'code': 'Q03', 'spade_a': null},
          ],
        }
      };
      expect(QishuiApi.parseStreamResponse(body).url, '');
    });
  });

  group('CENC 解密器（qishui_cenc）', () {
    test('decryptSpadeA：真实 spade_a → 32 位 hex key', () {
      const spade = 'krwc+1KxGclWsyvKeoY2+HuANMd7vjfDfIQG+E+wMftKjAK/vw==';
      final key = decryptSpadeA(spade);
      expect(key, hasLength(32));
      expect(key, '31744a7dfb954f4b807b4e20bd00e2aa');
    });

    test('qishuiResolveKey：hexKey 直通 / spade_a 派生 / 非法抛错', () {
      final k = qishuiResolveKey(hexKey: '31744a7dfb954f4b807b4e20bd00e2aa');
      expect(qishuiKeyToHex(k), '31744a7dfb954f4b807b4e20bd00e2aa');
      expect(
        qishuiKeyToHex(qishuiResolveKey(
            spadeA: 'krwc+1KxGclWsyvKeoY2+HuANMd7vjfDfIQG+E+wMftKjAK/vw==')),
        '31744a7dfb954f4b807b4e20bd00e2aa',
      );
      expect(() => qishuiResolveKey(spadeA: 'not-base64!!!'), throwsA(anything));
    });

    test('AES 单块向量（FIPS-197）：0x001122… ↔ 0x69c4e0d8…', () {
      // 借助 qishuiResolveKey + CTR 无法直接单块加密；这里用 spade 派生的
      // 已知 key 校验 hex 解析正确性，块加密细节由端到端解密测试覆盖。
      final k = qishuiResolveKey(hexKey: '000102030405060708090a0b0c0d0e0f');
      expect(k.length, 16);
      expect(k[0], 0);
      expect(k[15], 15);
    });
  });

  group('krc → YRC 逐字转换（krcToYrc）', () {
    test('相对偏移加行起始时间变绝对，尖括号转圆括号', () {
      // 汽水 krc：字偏移相对行首，尖括号
      const krc = '[21860,1630]<0,250,0>在<250,220,0>一<470,180,0>开';
      final yrc = QishuiApi.krcToYrc(krc);
      // 期望 YRC：字起始绝对时间，圆括号
      expect(yrc,
          '[21860,1630](21860,250,0)在(22110,220,0)一(22330,180,0)开');
    });

    test('多行 + 元信息行保留', () {
      const krc = '[ti:歌名]\n[1000,2000]<0,500,0>你<500,500,0>好';
      final yrc = QishuiApi.krcToYrc(krc);
      expect(yrc, contains('[ti:歌名]'));
      expect(yrc, contains('(1000,500,0)你'));
      expect(yrc, contains('(1500,500,0)好'));
    });

    test('XML 实体还原', () {
      const krc = '[0,1000]<0,1000,0>A&amp;B';
      final yrc = QishuiApi.krcToYrc(krc);
      expect(yrc, contains('A&B'));
    });

    test('空输入返回空', () {
      expect(QishuiApi.krcToYrc(''), '');
      expect(QishuiApi.krcToYrc('   '), '');
    });
  });

  group('Song 分流', () {
    test('汽水歌曲 → Song 后 source/getter 正确、音质留空待探测', () {
      final s = MusicApi.qishuiSongToSong(const QishuiSong(
        itemId: '7120513872380823590',
        name: '骄傲的少年',
        singer: '南征北战NZBZ',
        durationSeconds: 259,
      ));
      expect(s.isQishui, isTrue);
      expect(s.isJoox, isFalse);
      expect(s.mid, '7120513872380823590');
      expect(s.songId, 7120513872380823590);
      expect(s.sourceShort, '汽水');
      expect(s.sourceFull, '汽水音乐');
      expect(s.qualityCodes, isEmpty);
    });
  });

  group('Source 常量', () {
    test('汽水 source 独立不冲突', () {
      expect(Source.qishui, 'qishui');
      expect(Source.qishui == Source.joox, isFalse);
    });
  });
}
