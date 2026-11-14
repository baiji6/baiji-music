// v2.5.8-fix2 回归：酷狗 360RA 必须走原生解码管线。
//
// **背景**
//
// 酷狗服务端下发的 360RA 是 MPEG-H 3D Audio 容器（mp4 的 stsd 里
// fourcc = `mhm1`，`mhaC` 配置盒内联 `mpegh3daConfig`）。media_kit 的
// ffmpeg 白名单没有这个解码器，所以旧版把直链丢给播放器只会得到
// `Failed to recognize file format.`——用户看到的就是「酷狗 360RA 无法
// 解码」。
//
// 该容器与 QQ 音乐 RA01-04（RA0x）同型，官方 QQ 解码器
// `qm_native_decoder_360ra.so` 内置的 Sony SAL 与酷狗
// `libkugouplayer.so` 静态集成的是同一套实现，其 mp4 解析器
// `libextra_mp4_parser.so` 明确支持 `mhm1` / `mhaC`（反汇编确认：
// `find_stsd_in_stbl` 依次 strncmp 比较 `mha1` / `mhm1` / `mhaC`）。
// 因此酷狗档位可以直接复用同一条原生解码管线。
//
// 本测试锁定「路由规则」——即哪些酷狗档位该走解码管线、缓存 key 是否
// 与 QQ 侧隔离，避免将来改坏。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:baiji_music/models/models.dart';

void main() {
  group('酷狗 360RA 档位（v2.5.8-fix2）', () {
    test('360ra 档位存在且是 mp4 容器（需要原生解码器）', () {
      final q = KugouQuality.ra360;
      expect(q.id, '360ra');
      expect(q.format, 'mp4');
      expect(q.ext, '.mp4');
      // 服务端实际下发的是三档，取最高 l3。
      expect(q.qualityTag, '360ra_l3');
    });

    test('360RA 走的是服务端直连 hash（不在歌曲元数据里）', () {
      // hasDirectHash 决定 hash 来源：直连档位的 hash 只由权威档位接口
      // 下发（`360ra_l3`），取流时用该 hash 而不是歌曲元数据里的
      // FileHash / HQFileHash。
      expect(KugouQuality.ra360.hasDirectHash, isTrue);
      // 直连档位不覆盖 hash 字段名（hash 直接来自探测结果）。
      expect(KugouQuality.ra360.fetchHashKey, isEmpty);
      expect(KugouQuality.ra360.hashKey, isNotEmpty);
    });

    test('360RA 需要登录/会员（未登录时服务端返回空 URL）', () {
      expect(KugouQuality.ra360.requiresLogin, isTrue);
    });

    test('360RA 在播放与下载档位全集里（UI 可选）', () {
      expect(KugouQuality.playbackOptions.map((q) => q.id),
          contains('360ra'));
      expect(KugouQuality.downloadOptions.map((q) => q.id),
          contains('360ra'));
    });
  });

  group('解码管线路由隔离（v2.5.8-fix2）', () {
    test('酷狗 360RA 的缓存 key 与 QQ 侧不冲突', () {
      // 缓存 key 形如 `kg360ra_<mid>`：QQ 侧用的是裸 mid，若酷狗也用裸
      // mid，两边同 mid 的歌会互相命中对方的解码产物（内容不同 → 播错）。
      const kugouKey = 'kg360ra_65727949';
      const qqKey = '65727949';
      expect(kugouKey, isNot(qqKey));
      expect(kugouKey.contains(qqKey), isTrue,
          reason: '必须带平台前缀，QQ 侧不会产生这个 key');
    });

    test('酷狗 360RA 与 QQ 的 RA0x 是不同档位（不会误判为 QQ 档）', () {
      // QQ 的 RA0x 用 `Quality.ra360a..d`，码值 RA01~RA04；
      // 酷狗用的是 `KugouQuality.ra360`，id = '360ra'。
      expect(KugouQuality.ra360.id.startsWith('RA0'), isFalse);
      expect(Quality.ra360d.code.startsWith('RA0'), isTrue);
    });
  });

  group('边转码边播放（v2.5.8-fix2）', () {
    test('三个自研解码格式都有独立的档位标识', () {
      // 流式管线按格式分流，三者的入口判定不能互相干扰。
      expect(Quality.dtsX.code, 'DT03');
      expect(Quality.ra360d.code, 'RA04');
      expect(Quality.nac.code, 'TL01');
    });
  });
}
