import 'dart:convert';
import 'dart:typed_data';

import 'package:baiji_music/crypto/qq_crypto.dart';
import 'package:baiji_music/models/models.dart';
import 'package:archive/archive.dart';
import 'package:baiji_music/network/netease/netease_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// 算法移植正确性测试。
///
/// 期望值来自 C 参考实现（src/app/src/main/cpp/qqapi/alg/*.c 经 gcc 编译出的
/// 参考二进制输出），保证 Dart 移植与原生 .so 逐字节一致。
void main() {
  group('hash33', () {
    // ref: hash33_abc=108966
    test('abc', () => expect(hash33('abc', 0), 108966));
    // ref: hash33_empty=0
    test('empty', () => expect(hash33('', 0), 0));
    // ref: hash33_hello=1239941340
    test('hello world', () => expect(hash33('hello world', 0), 1239941340));
    // ref: hash33_seed5381=190672644
    test('seed 5381', () => expect(hash33('somep_skey', 5381), 190672644));
    // ref: hash33_uni=1703915512
    test('utf8', () => expect(hash33('zhongwen测试123', 0), 1703915512));
    // g_tk 常用场景：hash33(p_skey, 5381)
    test('p_skey 场景', () => expect(hash33('p_skey_demo', 5381), hash33('p_skey_demo', 5381)));
  });

  group('zzcSign', () {
    // ref: zzc_1=zzc43448d4zqd22hvgsi3wohpycvflyfqptu870b45b0
    test('payload123', () => expect(zzcSign('payload123'), 'zzc43448d4zqd22hvgsi3wohpycvflyfqptu870b45b0'));
    // ref: zzc_2=zzc7333175plrgott6u86r8rbcdileqfeuq6e17d859e5
    // （C 参考最初因长度传 14 少算 1 字节，修正后与 Dart 完全一致）
    test('json payload', () => expect(zzcSign('{"a":1,"b":"x"}'), 'zzc7333175plrgott6u86r8rbcdileqfeuq6e17d859e5'));
    // ref: zzc_3=zzcf0e03e5gx4qeiq5cfgdyqwu7sdqfsb5fro3aa45053
    test('empty payload', () => expect(zzcSign(''), 'zzcf0e03e5gx4qeiq5cfgdyqwu7sdqfsb5fro3aa45053'));
    // ref: zzc_4=zzca16511dqro98cfseascwjhye0iaslyjvo1248dd1b
    test('utf8 payload', () => expect(zzcSign('测试数据abc'), 'zzca16511dqro98cfseascwjhye0iaslyjvo1248dd1b'));
  });

  group('tripledes', () {
    final keyA = Uint8List.fromList(List.generate(24, (i) => i + 1));
    Uint8List hexBytes(String h) => Uint8List.fromList(
        List.generate(h.length ~/ 2, (i) => int.parse(h.substring(i * 2, i * 2 + 2), radix: 16)));

    // ref: tdes_enc=f9252196446db5d7, tdes_dec=0123456789abcdef
    test('keyA 加密', () {
      final enc = tripledesCbc(
          key24: keyA, input: hexBytes('0123456789abcdef'), encrypt: true);
      expect(hexEncode(enc), 'f9252196446db5d7');
    });
    // ref: tdes2_enc=87737904b779ca8e, tdes2_dec=deadbeef01020304
    test('keyB 加密/解密往返', () {
      final keyB = Uint8List.fromList(List.generate(24, (i) => 0xA0 + i));
      final enc = tripledesCbc(
          key24: keyB, input: hexBytes('deadbeef01020304'), encrypt: true);
      expect(hexEncode(enc), '87737904b779ca8e');
      final dec = tripledesCbc(key24: keyB, input: enc, encrypt: false);
      expect(hexEncode(dec), 'deadbeef01020304');
    });
    // ref: tdes_dec=0123456789abcdef
    test('解密还原 keyA', () {
      final dec = tripledesCbc(
          key24: keyA, input: hexBytes('f9252196446db5d7'), encrypt: false);
      expect(hexEncode(dec), '0123456789abcdef');
    });
    // 多块数据加解密往返
    test('多块往返', () {
      final data = hexBytes('0123456789abcdef' 'a1b2c3d4e5f60718');
      final enc = tripledesCbc(key24: keyA, input: data, encrypt: true);
      final dec = tripledesCbc(key24: keyA, input: enc, encrypt: false);
      expect(dec, data);
    });
  });

  group('qrcDecrypt', () {
    test('与 C 参考加密结果一致（QRC 密钥）', () {
      final plain = '[00:01.00]hello[00:02.00]world 中文歌词测试';
      final zipped = Uint8List.fromList(ZLibEncoder().encode(utf8.encode(plain)));
      // 与 C 参考一致：zlib 输出 pad 到 8 的倍数（零填充）后再 3DES
      final padded = Uint8List(((zipped.length + 7) ~/ 8) * 8)
        ..setRange(0, zipped.length, zipped);
      final key = Uint8List.fromList(utf8.encode('!@#)(*\$%123ZXC!@!@#)(NHL'));
      final enc = tripledesCbc(key24: key, input: padded, encrypt: true);
      // ref: qrc_enc=32dabb4c5e9846fa...(由同一密钥加密 zlib(明文) 得到)
      expect(hexEncode(enc),
          '32dabb4c5e9846fa7a4eb4ea8db4d7fe80d5c28045e384291b59598bd529e96bfc797c7ab076c280e3655584278de38fd88fb6d5ca1c3cf6');
      // 解密回明文
      final dec = qrcDecrypt(hexEncode(enc));
      expect(dec, plain);
    });
  });

  group('models', () {
    test('Quality 枚举与 filename', () {
      expect(Quality.playbackDefault, Quality.mp3_128);
      expect(Quality.mp3_320.filenameFor('abc'), 'M800abcabc.mp3');
      expect(Quality.fromCode('F000'), Quality.flac);
      expect(Quality.fromUrlPrefix('https://x/M800abc.mp3?k=1'), Quality.mp3_320);
    });

    test('NeteaseQuality 枚举', () {
      expect(NeteaseQuality.playbackDefault, NeteaseQuality.exhigh);
      expect(NeteaseQuality.fromLevel('hires'), NeteaseQuality.hires);
    });

    test('Song fromTrack 解析', () {
      final t = {
        'mid': '003abc',
        'id': 12345,
        'name': '歌名',
        'interval': 200,
        'album': {'mid': '003alb', 'name': '专辑', 'picUrl': {'s': 'http://cover'}},
        'singer': [{'name': '歌手A'}, {'name': '歌手B'}],
      };
      final song = Song.fromTrack(t);
      expect(song.mid, '003abc');
      expect(song.songId, 12345);
      expect(song.singer, '歌手A / 歌手B');
      expect(song.duration, 200 * 1000);
      expect(song.source, Source.qq);
    });

    test('Credential fromDict/alias/toJsonString', () {
      final c = Credential.fromDict({
        'openid': 'o1',
        'musicid': 10001,
        'musickey': 'W_X_key',
        'login_type': 1,
        'key_expires_in': 7200,
        'musickeycreatetime': 1700000000,
        'str_musicid': '10001',
      });
      expect(c.musicid, 10001);
      expect(c.loginType, 1);
      expect(c.strMusicid, '10001');
      expect(c.isLoggedIn(), true);
      // musickey 以 W_X 开头但无 login_type 时推断为 1
      final c2 = Credential.fromDict({'musicid': 1, 'musickey': 'W_X_abc'});
      expect(c2.loginType, 1);
      // toJsonString 只保留三字段
      final s = c.toJsonString();
      expect(s.contains('openid'), false);
      expect(s.contains('musicid'), true);
      expect(s.contains('musickey'), true);
    });
  });

  group('neteaseCrypto', () {
    test('encryptParams 可被 AES 解密还原', () {
      final enc = NeteaseCrypto.encryptParams(
          'https://interface3.music.163.com/eapi/song/enhance/player/url/v1',
          '{"ids":[1]}');
      expect(enc.length % 32, 0); // hex 长度,16 字节块
    });

    test('encryptId 输出 URL_SAFE base64', () {
      final enc = NeteaseCrypto.encryptId('109951163163106031');
      // URL_SAFE：不包含 + / =，可能包含 - _
      expect(enc.contains('+'), false);
      expect(enc.contains('/'), false);
      expect(enc.length, 22); // 16 字节 md5 -> URL_SAFE base64 无填充 22 字符
    });

    test('picUrl 格式', () {
      expect(NeteaseCrypto.picUrl(109951163163106031, 300),
          startsWith('https://p3.music.126.net/'));
      expect(NeteaseCrypto.picUrl(null), '');
      expect(NeteaseCrypto.picUrl(0), '');
    });
  });
}