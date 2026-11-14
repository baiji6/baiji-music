// v2.5.4 酷狗权威档位探测回归测试。
//
// 全部离线：用**真实接口响应片段**驱动解析，不联网、不依赖平台通道。
//
// 背景：v2.5.2 的音质推导靠猜搜索响应里的 hash 字段，而搜索接口根本不
// 返回 `trans_param`，于是「支持 360RA 的歌曲里看不到 360RA 选项」。
// 服务端真正决定档位的是 `goodsmstore/v1/get_res_privilege`，本测试
// 锁定它的解析与「档位 → UI 档位」映射。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/kugou/kugou_api.dart';
import 'package:baiji_music/network/kugou/kugou_privilege.dart';

/// 真实响应片段（2026-11-07 实测，周杰伦《稻香》hash=8909E180…）。
/// 服务端对 `viper_atmos` / `viper_tape` / `viper_clear` / `viper_hifi`
/// 等高级档**不给 extname**，但给 filesize；`extname` 为空的条目照样有效。
const Map<String, dynamic> _realPrivilegeItem = <String, dynamic>{
  'type': 'audio',
  'id': 332453,
  'album_id': '960399',
  'album_audio_id': 32042828,
  'hash': '8909E1809908CD8E3BF6CF85D98B93F0',
  'name': '周杰伦 - 稻香',
  'singername': '周杰伦',
  'relate_goods': <Map<String, dynamic>>[
    <String, dynamic>{
      'type': 'audio',
      'hash': '8909E1809908CD8E3BF6CF85D98B93F0',
      'quality': '128',
      'level': 2,
      'info': <String, dynamic>{'filesize': 3576668, 'extname': 'mp3'},
    },
    <String, dynamic>{
      'type': 'audio',
      'hash': '21AC928E1D68EC3632EF2CAE68718201',
      'quality': '320',
      'level': 4,
      'info': <String, dynamic>{'filesize': 8940938, 'extname': 'mp3'},
    },
    <String, dynamic>{
      'type': 'audio',
      'hash': '36AB2C542AF54578EFD376A4E2C57C1F',
      'quality': 'flac',
      'level': 5,
      'info': <String, dynamic>{'filesize': 26012257, 'extname': 'flac'},
    },
    <String, dynamic>{
      'type': 'audio',
      'hash': 'D987462A7FD98151845DB245FE214267',
      'quality': 'high',
      'level': 6,
      'info': <String, dynamic>{'filesize': 88706509, 'extname': 'flac'},
    },
    <String, dynamic>{
      'type': 'audio',
      'hash': '44CC94A3AA62AEC24923EDB609445C47',
      'quality': 'viper_atmos',
      'level': 0,
      'info': <String, dynamic>{'filesize': 56980489, 'extname': ''},
    },
    <String, dynamic>{
      'type': 'audio',
      'hash': '21AC928E1D68EC3632EF2CAE68718201',
      'quality': 'viper_tape',
      'level': 0,
      'info': <String, dynamic>{'filesize': 8940938, 'extname': ''},
    },
    <String, dynamic>{
      'type': 'audio',
      'hash': '98515CB85E5FACC3F48962015B07CB02',
      'quality': 'viper_clear',
      'level': 0,
      'info': <String, dynamic>{'filesize': 99849591, 'extname': ''},
    },
    <String, dynamic>{
      'type': 'audio',
      'hash': 'D362BA9D069CB675BF3771D4D6860A5D',
      'quality': 'viper_hifi',
      'level': 0,
      'info': <String, dynamic>{'filesize': 26403336, 'extname': ''},
    },
  ],
};

/// 只带 128k 的歌（实测「稻香 (2018 CCTV-15…现场)」就是这种）。
const Map<String, dynamic> _only128Item = <String, dynamic>{
  'hash': 'AAAA1111BBBB2222CCCC3333DDDD4444',
  'relate_goods': <Map<String, dynamic>>[
    <String, dynamic>{
      'hash': 'AAAA1111BBBB2222CCCC3333DDDD4444',
      'quality': '128',
      'level': 2,
      'info': <String, dynamic>{'filesize': 3179554, 'extname': 'mp3'},
    },
  ],
};

/// 含 360RA / 杜比双码率的歌（实测「晴天 (Live)-周杰伦」带 dolby2_*）。
const Map<String, dynamic> _with360raItem = <String, dynamic>{
  'hash': 'FFFF1111GGGG2222HHHH3333IIII4444',
  'relate_goods': <Map<String, dynamic>>[
    <String, dynamic>{
      'hash': 'FFFF1111GGGG2222HHHH3333IIII4444',
      'quality': '128',
      'level': 2,
      'info': <String, dynamic>{'filesize': 4790884, 'extname': 'mp3'},
    },
    <String, dynamic>{
      'hash': '360RAL3HASH000000000000000000000',
      'quality': '360ra_l3',
      'level': 0,
      'info': <String, dynamic>{'filesize': 33554432, 'extname': 'mp4'},
    },
    <String, dynamic>{
      'hash': 'DOLBY448HASH0000000000000000000000',
      'quality': 'dolby2_448k',
      'level': 0,
      'info': <String, dynamic>{'filesize': 14028904, 'extname': 'mp4'},
    },
    <String, dynamic>{
      'hash': 'DOLBY1500HASH000000000000000000000',
      'quality': 'dolby2_1500k',
      'level': 0,
      'info': <String, dynamic>{'filesize': 46890410, 'extname': 'mp4'},
    },
    <String, dynamic>{
      'hash': 'DOLBYHASH00000000000000000000000000',
      'quality': 'dolby',
      'level': 0,
      'info': <String, dynamic>{'filesize': 8026443, 'extname': 'mp4'},
    },
  ],
};

/// 真实响应片段（2026-11-14 实测，杨丞琳《雨爱》
/// hash=2592FFA57A2D8B1A16F18D991B7098CD）。
///
/// 关键：**三档 360RA 的 `info.filesize` 全是 0、`extname` 为空**，但 hash
/// 都是真实且互不相同的 32 位 hex。用 `360ra_l3` 的 hash 请求 /v5/url 返回
/// `status=2`（需会员/登录），证明档位真实存在。v2.5.4 的解析把
/// `filesize<=0` 当作「服务端占位」，把这三条整批丢掉 —— 这正是「有的歌
/// 有 360RA，音质列表里却没有」的根因。
const Map<String, dynamic> _yuaPrivilegeItem = <String, dynamic>{
  'type': 'audio',
  'album_audio_id': 65727949,
  'hash': '2592FFA57A2D8B1A16F18D991B7098CD',
  'name': '杨丞琳 - 雨爱',
  'relate_goods': <Map<String, dynamic>>[
    <String, dynamic>{
      'hash': '2592FFA57A2D8B1A16F18D991B7098CD',
      'quality': '128',
      'level': 2,
      'info': <String, dynamic>{'filesize': 4168946, 'extname': 'mp3'},
    },
    <String, dynamic>{
      'hash': 'E72D5EEC94706BEF1BB6DCA4DE1CF09F',
      'quality': '320',
      'level': 4,
      'info': <String, dynamic>{'filesize': 10421564, 'extname': 'mp3'},
    },
    <String, dynamic>{
      'hash': 'F9ED36771CE6A071C2A4C210E4E68F56',
      'quality': 'flac',
      'level': 5,
      'info': <String, dynamic>{'filesize': 33618441, 'extname': 'flac'},
    },
    <String, dynamic>{
      'hash': '3E483896EA485A57E390A7717E615486',
      'quality': 'high',
      'level': 6,
      'info': <String, dynamic>{'filesize': 34229336, 'extname': 'flac'},
    },
    <String, dynamic>{
      'hash': 'AC0FFF1D8EBD01C80F49922993DC3FF1',
      'quality': 'viper_atmos',
      'level': 0,
      'info': <String, dynamic>{'filesize': 75074328, 'extname': ''},
    },
    <String, dynamic>{
      'hash': '121E484D7B2272F7C484433FD0778680',
      'quality': 'viper_hifi',
      'level': 0,
      'info': <String, dynamic>{'filesize': 34229336, 'extname': ''},
    },
    <String, dynamic>{
      'hash': '5972211B55D476AFB185B4FE18B0D7B7',
      'quality': '360ra_l1',
      'level': 0,
      'info': <String, dynamic>{'filesize': 0, 'extname': ''},
    },
    <String, dynamic>{
      'hash': '26C4656B1372635A50102C1BD69B84A6',
      'quality': '360ra_l2',
      'level': 0,
      'info': <String, dynamic>{'filesize': 0, 'extname': ''},
    },
    <String, dynamic>{
      'hash': 'FA13C7044B6F80D593088787DDB12145',
      'quality': '360ra_l3',
      'level': 0,
      'info': <String, dynamic>{'filesize': 0, 'extname': ''},
    },
  ],
};

void main() {
  group('KugouPrivilegeApi.parseQualities', () {
    test('解析 relate_goods → quality → option', () {
      final opts = KugouPrivilegeApi.parseQualities(_realPrivilegeItem);
      expect(opts.length, 8);
      expect(opts['flac']!.hash, '36AB2C542AF54578EFD376A4E2C57C1F');
      expect(opts['flac']!.filesize, 26012257);
      expect(opts['flac']!.extname, 'flac');
      expect(opts['flac']!.level, 5);
      expect(opts['128']!.filesize, 3576668);
    });

    test('高级档 extname 为空也算有效（只看 filesize）', () {
      final opts = KugouPrivilegeApi.parseQualities(_realPrivilegeItem);
      expect(opts.containsKey('viper_hifi'), isTrue);
      expect(opts['viper_hifi']!.filesize, 26403336);
      expect(opts['viper_hifi']!.extname, '');
      expect(opts['viper_atmos']!.hash, '44CC94A3AA62AEC24923EDB609445C47');
    });

    test('filesize=0 但 hash 有效仍保留（v2.5.8-fix1，360RA 实测）', () {
      // 服务端对 360RA 三档一律不下发 filesize，旧逻辑据此整批丢弃，
      // 导致所有带 360RA 的歌曲都看不到该档位。
      final opts = KugouPrivilegeApi.parseQualities(_yuaPrivilegeItem);
      expect(opts.containsKey('360ra_l1'), isTrue);
      expect(opts.containsKey('360ra_l2'), isTrue);
      expect(opts.containsKey('360ra_l3'), isTrue);
      expect(opts['360ra_l3']!.hash, 'FA13C7044B6F80D593088787DDB12145');
      expect(opts['360ra_l3']!.filesize, 0,
          reason: '0 只表示服务端没给大小，不是档位无效');
    });

    test('hash 为空的占位条目才被跳过', () {
      final opts = KugouPrivilegeApi.parseQualities(<String, dynamic>{
        'relate_goods': <Map<String, dynamic>>[
          <String, dynamic>{
            'hash': '',
            'quality': '360ra_l3',
            'level': 0,
            'info': <String, dynamic>{'filesize': 0},
          },
          <String, dynamic>{
            'hash': 'REALHASH000000000000000000000000',
            'quality': 'flac',
            'level': 5,
            'info': <String, dynamic>{'filesize': 1024},
          },
        ],
      });
      expect(opts.containsKey('360ra_l3'), isFalse);
      expect(opts.containsKey('flac'), isTrue);
    });

    test('非 Map / 缺 relate_goods 时返回空', () {
      expect(KugouPrivilegeApi.parseQualities(null), isEmpty);
      expect(KugouPrivilegeApi.parseQualities('x'), isEmpty);
      expect(KugouPrivilegeApi.parseQualities(<String, dynamic>{}), isEmpty);
    });
  });

  group('探测用 quality 全集', () {
    test('不含服务端不认得的代号（否则整批 20010）', () {
      // 实测：混入 `360ra` / `master` / `mha1` 会让整个请求返回 20010。
      for (final bad in <String>['360ra', 'master', 'mha1', 'sony360ra']) {
        expect(KugouPrivilegeApi.qualityCatalog.contains(bad), isFalse,
            reason: '$bad 是服务端不认得的代号，混入会让整批探测失败');
      }
    });

    test('包含实测确认可用的全部代号', () {
      for (final good in <String>[
        '128',
        '320',
        'flac',
        'high',
        'dolby',
        'viper_atmos',
        'viper_tape',
        'viper_clear',
        'viper_hifi',
        '360ra_l1',
        '360ra_l2',
        '360ra_l3',
        'dolby2_448k',
        'dolby2_1500k',
        'super',
      ]) {
        expect(KugouPrivilegeApi.qualityCatalog.contains(good), isTrue,
            reason: '$good 是服务端认得的代号');
      }
    });
  });

  group('KugouApi.tiersFromPrivilege', () {
    test('按探测结果推导真实档位（含 v2.5.4 新增的三档）', () {
      final opts = KugouPrivilegeApi.parseQualities(_realPrivilegeItem);
      final tiers = KugouApi.tiersFromPrivilege(opts, has320: true, hasFlac: true);
      final ids = tiers.map((q) => q.id).toSet();
      expect(ids.contains('viper_hifi'), isTrue,
          reason: 'v2.5.2 的注释里列了 viper_hifi 但代码没建枚举，v2.5.4 补上');
      expect(ids.contains('128kmp3'), isTrue);
      expect(ids.contains('320kmp3'), isTrue);
      expect(ids.contains('flac'), isTrue);
      expect(ids.contains('hires'), isTrue);
      expect(ids.contains('viper_atmos'), isTrue);
      expect(ids.contains('viper_clear'), isTrue);
      expect(ids.contains('viper_tape'), isTrue,
          reason: '本地升频档：有 320k 源文件就能本地重建');
    });

    test('360RA 三档只保留一档（映射到最高 l3）', () {
      final opts = KugouPrivilegeApi.parseQualities(_with360raItem);
      final tiers = KugouApi.tiersFromPrivilege(opts);
      final ids = tiers.map((q) => q.id).toSet();
      expect(ids.contains('360ra'), isTrue);
      expect(tiers.where((q) => q.id == '360ra').length, 1);
      expect(ids.contains('dolby2_448k'), isTrue);
      expect(ids.contains('dolby2_1500k'), isTrue);
      expect(ids.contains('dolby'), isTrue);
    });

    test('输出按 playbackOptions 的高→低顺序', () {
      final opts = KugouPrivilegeApi.parseQualities(_with360raItem);
      final tiers = KugouApi.tiersFromPrivilege(opts);
      for (var i = 1; i < tiers.length; i++) {
        expect(tiers[i - 1].bitrate >= tiers[i].bitrate, isTrue,
            reason: '音质列表必须按码率降序');
      }
    });

    test('探测结果为空时返回空列表（调用方降级到启发式）', () {
      expect(KugouApi.tiersFromPrivilege(const {}), isEmpty);
    });

    test('只有 128k 的歌：不会凭空出现高规格档', () {
      final opts = KugouPrivilegeApi.parseQualities(_only128Item);
      final tiers = KugouApi.tiersFromPrivilege(opts);
      final ids = tiers.map((q) => q.id).toSet();
      expect(ids, <String>{'128kmp3'});
      expect(ids.contains('viper_tape'), isFalse,
          reason: '没有 320k 源文件，本地升频也做不了');
    });
  });

  group('KugouSong.hashFor（直连档位）', () {
    test('360RA / 蝰蛇 HiFi 等直连档取探测下发的 hash', () {
      final opts = KugouPrivilegeApi.parseQualities(_with360raItem);
      final song = KugouApi.parseSong(<String, dynamic>{
        'MixSongID': '999',
        'SongName': '测试',
        'SingerName': '歌手',
        'FileHash': 'FFFF1111GGGG2222HHHH3333IIII4444',
        'HQFileHash': '',
        'SQFileHash': '',
        'ResFileHash': '',
      })!.copyWith(qualityOptions: opts);

      expect(song.hashFor(KugouQuality.ra360), '360RAL3HASH000000000000000000000');
      expect(song.hashFor(KugouQuality.dolby448),
          'DOLBY448HASH0000000000000000000000');
      expect(song.hashFor(KugouQuality.dolby1500),
          'DOLBY1500HASH000000000000000000000');
    });

    test('常规档位仍走元数据里的 hash 字段', () {
      final song = KugouApi.parseSong(<String, dynamic>{
        'MixSongID': '999',
        'SongName': '测试',
        'SingerName': '歌手',
        'FileHash': 'HASH128',
        'HQFileHash': 'HASH320',
        'SQFileHash': 'HASHFLAC',
        'ResFileHash': 'HASHRES',
      })!;
      expect(song.hashFor(KugouQuality.k128), 'HASH128');
      expect(song.hashFor(KugouQuality.k320), 'HASH320');
      expect(song.hashFor(KugouQuality.flac), 'HASHFLAC');
      expect(song.hashFor(KugouQuality.hires), 'HASHRES');
    });
  });

  group('v2.5.8-fix1 回归：雨爱的 360RA 必须出现在音质列表', () {
    test('解析 → 档位推导含 360ra（只出现一次）', () {
      final opts = KugouPrivilegeApi.parseQualities(_yuaPrivilegeItem);
      final tiers = KugouApi.tiersFromPrivilege(opts,
          has320: true, hasFlac: true);
      final ids = tiers.map((q) => q.id).toList();
      expect(ids, contains('360ra'),
          reason: '《雨爱》服务端确实下发 360ra_l1/l2/l3，UI 必须展示');
      expect(ids.where((id) => id == '360ra').length, 1,
          reason: '三档映射到同一 UI 档位，需去重');
    });

    test('qualityCodes 含 360ra → filterQualityOptions 不会把它过滤掉', () {
      final opts = KugouPrivilegeApi.parseQualities(_yuaPrivilegeItem);
      final tiers = KugouApi.tiersFromPrivilege(opts,
          has320: true, hasFlac: true);
      final codes = tiers.map((q) => q.id).toSet();
      final visible = filterQualityOptions(
          codes, KugouQuality.playbackOptions, (q) => q.id);
      expect(visible.map((q) => q.id), contains('360ra'));
    });

    test('取流能拿到服务端下发的 360ra_l3 hash', () {
      final opts = KugouPrivilegeApi.parseQualities(_yuaPrivilegeItem);
      final song = KugouApi.parseSong(<String, dynamic>{
        'MixSongID': '65727949',
        'SongName': '雨爱',
        'SingerName': '杨丞琳',
        'FileHash': '2592FFA57A2D8B1A16F18D991B7098CD',
      })!.copyWith(qualityOptions: opts);
      expect(song.hashFor(KugouQuality.ra360),
          'FA13C7044B6F80D593088787DDB12145');
    });
  });

  group('KugouQuality 枚举（v2.5.4）', () {
    test('新增三档可由 id 反查，且 qualityTag 是服务端认得的代号', () {
      expect(KugouQuality.fromId('viper_hifi'), isNotNull);
      expect(KugouQuality.fromId('viper_hifi')!.qualityTag, 'viper_hifi');
      expect(KugouQuality.fromId('dolby2_448k'), isNotNull);
      expect(KugouQuality.fromId('dolby2_448k')!.qualityTag, 'dolby2_448k');
      expect(KugouQuality.fromId('dolby2_1500k'), isNotNull);
      expect(KugouQuality.fromId('dolby2_1500k')!.qualityTag, 'dolby2_1500k');
    });

    test('直连档位标记为 hasDirectHash（hash 只来自探测接口）', () {
      expect(KugouQuality.ra360.hasDirectHash, isTrue);
      expect(KugouQuality.viperHifi.hasDirectHash, isTrue);
      expect(KugouQuality.dolby448.hasDirectHash, isTrue);
      expect(KugouQuality.dolby1500.hasDirectHash, isTrue);
      expect(KugouQuality.flac.hasDirectHash, isFalse);
    });

    test('下载档位已扩容（不再只有 4 档）', () {
      expect(KugouQuality.downloadOptions.length, greaterThan(4),
          reason: 'v2.5.2 只有 4 档，用户反馈「音质不全」');
      expect(KugouQuality.downloadOptions.contains(KugouQuality.viperHifi),
          isTrue);
      expect(KugouQuality.downloadOptions.contains(KugouQuality.ra360), isTrue);
      expect(KugouQuality.downloadOptions.contains(KugouQuality.dolby), isTrue);
    });

    test('下载档位不含本地升频档（不能拿 320k 冒充 192k 母带）', () {
      expect(
          KugouQuality.downloadOptions.any((q) => q.isLocalUpscale), isFalse);
      expect(KugouQuality.downloadOptions.contains(KugouQuality.viperTape),
          isFalse);
    });

    test('播放档位按码率降序且含新增档', () {
      final opts = KugouQuality.playbackOptions;
      for (var i = 1; i < opts.length; i++) {
        expect(opts[i - 1].bitrate >= opts[i].bitrate, isTrue);
      }
      expect(opts.first, KugouQuality.viperTape);
      expect(opts.contains(KugouQuality.viperHifi), isTrue);
      expect(opts.contains(KugouQuality.dolby1500), isTrue);
    });

    test('高规格档标记 requiresLogin（未登录时 UI 置灰）', () {
      expect(KugouQuality.viperHifi.requiresLogin, isTrue);
      expect(KugouQuality.ra360.requiresLogin, isTrue);
      expect(KugouQuality.dolby448.requiresLogin, isTrue);
      expect(KugouQuality.k128.requiresLogin, isFalse);
      expect(KugouQuality.flac.requiresLogin, isFalse);
    });
  });
}
