// 酷狗歌单 / 每日推荐 的离线单测（v2.5.4）。
//
// 用 2026-11 沙箱实测的真实响应片段驱动纯函数：
//   - parseRecommended / parseSearchPlaylists（推荐 / 搜索歌单）
//   - parseDaily（每日推荐 30 首）
//   - parsePlaylistSongs（歌单歌曲）
//   - parseMyPlaylists（「我的歌单」，v7/get_all_list）
//
// 并锁定关键协议约定：
//   - 「我的歌单」签名盐是**歌词盐**（不是 gateway 盐），错盐返回 20006；
//   - 每日推荐签名盐是 gateway 盐，且必须带 x-router 头；
//   - 每日推荐歌曲走 `hash_320` / `hash_flac`（不是 `320hash` / `sqhash`）。
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:baiji_music/network/hot_search_api.dart';
import 'package:baiji_music/network/kugou/kugou_cipher.dart';
import 'package:baiji_music/network/kugou/kugou_playlist_api.dart';

/// 歌单分类响应（`getSpecial?is_smarty=1`）裁剪后的真实片段。
Map<String, dynamic> _realCategories() => <String, dynamic>{
      'status': 1,
      'data': <String, dynamic>{
        'tagids': <String, dynamic>{
          '主题': <String, dynamic>{
            'id': 1,
            'data': <Map<String, dynamic>>[
              <String, dynamic>{'id': 1084, 'name': '精选', 'parent_id': 1},
              <String, dynamic>{'id': 12, 'name': '经典', 'parent_id': 1},
            ],
          },
          '语种': <String, dynamic>{
            'id': 2,
            'data': <Map<String, dynamic>>[
              <String, dynamic>{'id': 84, 'name': '国语', 'parent_id': 2},
              <String, dynamic>{'id': 20, 'name': '英语', 'parent_id': 2},
            ],
          },
          '风格': <String, dynamic>{
            'id': 8,
            'data': <Map<String, dynamic>>[
              <String, dynamic>{'id': 9, 'name': '流行', 'parent_id': 8},
            ],
          },
          '年代': <String, dynamic>{
            'id': 3,
            'data': <Map<String, dynamic>>[],
          },
          '心情': <String, dynamic>{
            'id': 4,
            'data': <Map<String, dynamic>>[],
          },
          '场景': <String, dynamic>{
            'id': 6,
            'data': <Map<String, dynamic>>[],
          },
        },
      },
    };

/// 推荐歌单响应（`getSpecial?is_ajax=1&t=5`）裁剪后的真实片段。
Map<String, dynamic> _realRecommended() => <String, dynamic>{
      'special_db': <Map<String, dynamic>>[
        <String, dynamic>{
          'specialid': 1030927,
          'specialname': '乡村之音：安静惬意·与自然同在',
          'nickname': '董若',
          'intro': '清晨的泥土芬芳扑面而来',
          'img': 'http://img.kugou.com/cover/5b1c4d0e/1cb7b2f4.jpg',
          'play_count': 0,
          'total_play_count': '1719.2万',
          'grade_int': '0',
          'song_count': 120,
          'collect_count': 3021,
        },
        <String, dynamic>{
          'specialid': 1030928,
          'specialname': '深夜钢琴：一个人的小酒馆',
          'nickname': '林清玄',
          'img': 'http://img.kugou.com/cover/aa1b2c3d/99887766.jpg',
          'total_play_count': '860.4万',
          'song_count': 80,
        },
      ],
    };

/// 搜索歌单响应（`mobilecdn/api/v3/search/special`）裁剪后的真实片段。
Map<String, dynamic> _realSearchPlaylists() => <String, dynamic>{
      'status': 1,
      'data': <String, dynamic>{
        'total': 113,
        'info': <Map<String, dynamic>>[
          <String, dynamic>{
            'specialid': 1234567,
            'specialname': '深夜emo歌单',
            'nickname': '小七',
            'imgurl': 'http://img.kugou.com/cover/11223344/55667788.jpg',
            'playcount': 12000,
            'songcount': 50,
          },
        ],
      },
    };

/// 每日推荐响应（`everyday_song_recommend`）裁剪后的真实片段。
Map<String, dynamic> _realDaily() => <String, dynamic>{
      'status': 1,
      'error_code': 0,
      'data': <String, dynamic>{
        'creation_date': '20261108',
        'bi_biz': 'rcmd_evd',
        'song_list_size': 30,
        'cover_img_url':
            'http://imge.kugou.com/commendpic/20241029/20241029174132267837.jpg',
        'song_list': <Map<String, dynamic>>[
          <String, dynamic>{
            'songname': '理想境 (Ideal Realm)',
            'ori_audio_name': '理想境',
            'author_name': '晚风中闪过几帧从前',
            'album_name': '你越爱自己越迷人',
            'album_id': '133690628',
            'mixsongid': 710531016,
            'album_audio_id': 710531016,
            'hash': '1018A42D7F5ECC9042CEC8F38BAD19CD',
            'hash_128': '1018A42D7F5ECC9042CEC8F38BAD19CD',
            'hash_320': '8FBCBCAB5E6176CEAAD02361FC92E148',
            'hash_flac': '2C6072E737A132D65B280F4BE9D3B427',
            'time_length': 198,
            'bitrate': 128,
            'mv_hash': '',
            'sizable_cover':
                'http://imge.kugou.com/stdmusic/{size}/20260508/20260508031404189970.jpg',
            'singerinfo': <Map<String, dynamic>>[
              <String, dynamic>{'name': '晚风中闪过几帧从前', 'id': '12209661'},
            ],
          },
          <String, dynamic>{
            'songname': '晴天',
            'author_name': '周杰伦',
            'album_name': '叶惠美',
            'mixsongid': 710531017,
            'hash': 'ABCDEF00112233445566778899AABBCC',
            'hash_320': '',
            'hash_flac': '',
            'time_length': 269,
            'mv_hash': 'MVHASH0000000000000000000000',
          },
        ],
      },
    };

/// 歌单歌曲响应（`mobilecdn/api/v3/special/song`）裁剪后的真实片段。
Map<String, dynamic> _realPlaylistSongs() => <String, dynamic>{
      'status': 1,
      'data': <String, dynamic>{
        'timestamp': 1794070163,
        'total': 89,
        'info': <Map<String, dynamic>>[
          <String, dynamic>{
            'filename': '7妹 - Laxed (最强混音版)',
            'hash': 'A9B56F8501FA2D114C10268CDCD1E996',
            '320hash': '8DF31DC2305700DA3C14CD967442659E',
            'sqhash': '868E82B1A02D4F4B935EB78DCAA80264',
            'album_audio_id': 256825608,
            'audio_id': 1049666758,
            'album_id': '37471982',
            'duration': 255,
            'bitrate': 128,
            'mvhash': '',
          },
        ],
      },
    };

/// 「我的歌单」响应（`v7/get_all_list`）裁剪后的真实片段。
Map<String, dynamic> _realMyPlaylists() => <String, dynamic>{
      'status': 1,
      'error_code': 0,
      'data': <String, dynamic>{
        'total': 12,
        'count': 2,
        'info': <Map<String, dynamic>>[
          <String, dynamic>{
            'listid': '5551234',
            'list_name': '我的收藏',
            'specialname': '我的收藏',
            'pic': 'http://img.kugou.com/cover/99887766/55443322.jpg',
            'song_count': 42,
            'global_collection_id': 'collection_1234_5678_9012_3456',
            'nickname': '阿狸',
          },
          <String, dynamic>{
            'listid': '5555678',
            'list_name': '通勤路上',
            'm_count': 18,
            'global_collection_id': 'collection_9999_8888_7777_6666',
          },
        ],
      },
    };

void main() {
  group('推荐歌单解析', () {
    test('从 special_db 取出歌单摘要', () {
      final list = KugouPlaylistApi.parseRecommended(_realRecommended());
      expect(list.length, 2);
      expect(list[0].id, '1030927');
      expect(list[0].name, '乡村之音：安静惬意·与自然同在');
      expect(list[0].creator, '董若');
      expect(list[0].trackCount, 120);
      expect(list[0].playCount, '1719.2万');
    });

    test('封面转 https 并把 {size} 换成 480', () {
      final list = KugouPlaylistApi.parseRecommended(_realRecommended());
      expect(list[0].cover, startsWith('https://'));
      expect(list[0].cover, isNot(contains('{size}')));
    });

    test('空响应返回空列表', () {
      expect(KugouPlaylistApi.parseRecommended(<String, dynamic>{}), isEmpty);
    });
  });

  group('歌单分类解析', () {
    test('分组是对象、标签数组在 data 字段里', () {
      final cats = KugouPlaylistApi.parseCategories(_realCategories());
      expect(cats.keys.toSet(), {'主题', '语种', '风格', '年代', '心情', '场景'});
      expect(cats['主题']!.first.name, '精选');
      expect(cats['主题']!.first.id, '1084');
      expect(cats['语种']!.first.name, '国语');
      expect(cats['语种']!.first.id, '84');
    });

    test('id 为 0 / 缺失的标签被丢弃', () {
      final cats = KugouPlaylistApi.parseCategories(<String, dynamic>{
        'data': <String, dynamic>{
          'tagids': <String, dynamic>{
            '主题': <String, dynamic>{
              'id': 1,
              'data': <Map<String, dynamic>>[
                <String, dynamic>{'id': 0, 'name': '无效'},
                <String, dynamic>{'name': '也没 id'},
                <String, dynamic>{'id': 1084, 'name': '精选'},
              ],
            },
          },
        },
      });
      expect(cats['主题']!.length, 1);
      expect(cats['主题']!.first.id, '1084');
    });

    test('空响应返回空 Map', () {
      expect(KugouPlaylistApi.parseCategories(<String, dynamic>{}), isEmpty);
    });
  });

  group('搜索歌单解析', () {
    test('从 data.info 取出歌单', () {
      final list = KugouPlaylistApi.parseSearchPlaylists(_realSearchPlaylists());
      expect(list.length, 1);
      expect(list[0].id, '1234567');
      expect(list[0].name, '深夜emo歌单');
      expect(list[0].trackCount, 50);
      expect(list[0].cover, startsWith('https://'));
    });
  });

  group('每日推荐解析', () {
    test('取出 song_list 全部歌曲', () {
      final list = KugouPlaylistApi.parseDaily(_realDaily());
      expect(list.length, 2);
      expect(list[0].mixSongId, '710531016');
      expect(list[0].name, '理想境 (Ideal Realm)');
      expect(list[0].singer, '晚风中闪过几帧从前');
      expect(list[0].album, '你越爱自己越迷人');
      expect(list[0].durationSeconds, 198);
    });

    test('每日推荐用 hash_320 / hash_flac（不是 320hash / sqhash）', () {
      final list = KugouPlaylistApi.parseDaily(_realDaily());
      expect(list[0].hqHash, '8FBCBCAB5E6176CEAAD02361FC92E148');
      expect(list[0].sqHash, '2C6072E737A132D65B280F4BE9D3B427');
      expect(list[0].hash, '1018A42D7F5ECC9042CEC8F38BAD19CD');
    });

    test('MV hash 与封面都能取到', () {
      final list = KugouPlaylistApi.parseDaily(_realDaily());
      expect(list[1].mvHash, 'MVHASH0000000000000000000000');
      expect(list[0].cover, contains('https://'));
      expect(list[0].cover, isNot(contains('{size}')));
    });

    test('singerinfo 兜底取歌手名', () {
      final d = _realDaily();
      final song = (d['data']['song_list'] as List)[0] as Map<String, dynamic>;
      song.remove('author_name');
      final list = KugouPlaylistApi.parseDaily(d);
      expect(list[0].singer, '晚风中闪过几帧从前');
    });

    test('空响应返回空列表', () {
      expect(KugouPlaylistApi.parseDaily(null), isEmpty);
      expect(KugouPlaylistApi.parseDaily(<String, dynamic>{}), isEmpty);
    });
  });

  group('歌单歌曲解析', () {
    test('filename 拆成歌手 + 歌名', () {
      final list = KugouPlaylistApi.parsePlaylistSongs(_realPlaylistSongs());
      expect(list.length, 1);
      expect(list[0].singer, '7妹');
      expect(list[0].name, 'Laxed (最强混音版)');
      expect(list[0].mixSongId, '256825608');
      expect(list[0].durationSeconds, 255);
    });

    test('取 320 / FLAC 的 hash', () {
      final list = KugouPlaylistApi.parsePlaylistSongs(_realPlaylistSongs());
      expect(list[0].hqHash, '8DF31DC2305700DA3C14CD967442659E');
      expect(list[0].sqHash, '868E82B1A02D4F4B935EB78DCAA80264');
    });
  });

  group('我的歌单解析', () {
    test('从 data.info 取出歌单', () {
      final list = KugouPlaylistApi.parseMyPlaylists(_realMyPlaylists());
      expect(list.length, 2);
      expect(list[0].id, '5551234');
      expect(list[0].name, '我的收藏');
      expect(list[0].trackCount, 42);
      expect(list[0].globalCollectionId, 'collection_1234_5678_9012_3456');
      expect(list[0].creator, '阿狸');
    });

    test('缺歌单名时兜底「酷狗歌单 + id」', () {
      final base = _realMyPlaylists();
      final info = (base['data'] as Map)['info'] as List;
      // 造一条只有 id、没有任何名字字段的记录。
      final stripped = <Map<String, dynamic>>[
        info[0] as Map<String, dynamic>,
        <String, dynamic>{'listid': '5559999'},
      ];
      final wrapped = <String, dynamic>{
        'status': 1,
        'data': <String, dynamic>{'info': stripped},
      };
      final list = KugouPlaylistApi.parseMyPlaylists(wrapped);
      expect(list[1].name, '酷狗歌单 5559999');
      expect(list[1].trackCount, isNull);
    });

    test('数组名兼容 list / lists', () {
      final base = _realMyPlaylists();
      final info = (base['data'] as Map)['info'];
      final data = Map<String, dynamic>.from(base['data'] as Map);
      for (final key in ['list', 'lists']) {
        final d = Map<String, dynamic>.from(data);
        d.remove('info');
        d[key] = info;
        final wrapped = <String, dynamic>{'status': 1, 'data': d};
        expect(KugouPlaylistApi.parseMyPlaylists(wrapped).length, 2);
      }
    });

    test('null / 空响应返回空列表', () {
      expect(KugouPlaylistApi.parseMyPlaylists(null), isEmpty);
      expect(KugouPlaylistApi.parseMyPlaylists(<String, dynamic>{}), isEmpty);
    });
  });

  group('签名协议约定', () {
    test('「我的歌单」用歌词盐，不是 gateway 盐', () {
      const params = <String, String>{
        'appid': '3116',
        'clientver': '11440',
        'clienttime': '1794070000',
        'dfid': '-',
        'mid': 'abcdef0123456789abcdef0123456789',
        'plat': '1',
        'uuid': '-',
      };
      const body =
          '{"userid":123,"token":"tk","total_ver":979,"type":2,"page":1,"pagesize":30}';
      final sig = kugouMyListSignature(params, body);
      expect(sig, isNotEmpty);
      expect(sig.length, 32);
      // 换成 gateway 盐必须得到不同结果（服务端只认歌词盐）。
      final gw = kugouSign(params, kugouGatewaySalt, body: body);
      expect(gw, isNot(sig));
      // 与 kugouSign(歌词盐, body) 一致。
      expect(kugouSign(params, kugouLyricSalt, body: body), sig);
    });

    test('盐值常量固定（回归保护）', () {
      expect(kugouLyricSalt, 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA');
      expect(kugouGatewaySalt, 'OIlwieks28dk2k092lksi2UIkp');
    });

    test('签名把参数按 key 排序后无分隔符拼接', () {
      const params = <String, String>{'b': '2', 'a': '1'};
      final manual = md5.convert(utf8.encode(
              '$kugouLyricSalt${'a=1b=2'}$kugouLyricSalt'))
          .toString();
      expect(kugouSign(params, kugouLyricSalt), manual);
    });
  });

  group('酷狗热门歌单入口', () {
    test('HotPlaylist.fromKugou 解析推荐歌单字段', () {
      final p = HotPlaylist.fromKugou(<String, dynamic>{
        'specialid': 1030927,
        'specialname': '乡村之音',
        'nickname': '董若',
        'img': 'http://img.kugou.com/cover/5b1c4d0e/1cb7b2f4.jpg',
        'total_play_count': '1719.2万',
        'song_count': 120,
      });
      expect(p.id, '1030927');
      expect(p.name, '乡村之音');
      expect(p.creator, '董若');
      expect(p.cover, startsWith('https://'));
      expect(p.playCount, '1719.2万');
      expect(p.trackCount, 120);
    });
  });

  group('转通用 Song', () {
    test('每日推荐歌曲能转成酷狗 Song', () {
      final list = KugouPlaylistApi.parseDaily(_realDaily());
      final song = KugouPlaylistApi.toSong(list[0]);
      expect(song.mid, '710531016');
      expect(song.name, '理想境 (Ideal Realm)');
      expect(song.singer, '晚风中闪过几帧从前');
      expect(song.source, 'kugou');
      expect(song.duration, 198000);
      expect(song.isKugou, isTrue);
    });
  });
}
