// v2.5.8-fix1：本地特殊格式扫描与播放前转码回归测试。
//
// 全部离线：只验证扩展名收录、格式识别、缓存 key 与「哪些格式需要转码」，
// 不调用自研解码器（它们只在 Android arm64 可用，CI runner 是 Linux）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:baiji_music/core/audio_transcoder.dart';
import 'package:baiji_music/local/local_scanner.dart';
import 'package:baiji_music/local/local_special_player.dart';
import 'package:baiji_music/models/models.dart';

Song _localSong(String path) => Song(
      mid: path,
      songId: path.hashCode & 0x7FFFFFFF,
      name: '测试',
      singer: '',
      album: '',
      albumMid: '',
      duration: 0,
      cover: '',
      source: Source.local,
      localPath: path,
    );

void main() {
  group('本地扫描扩展名（v2.5.8-fix1）', () {
    test('收录 NAC / DTS:X / 360RA / 杜比 / AV3A 容器', () {
      for (final ext in <String>[
        'nac',
        'dts',
        'dtshd',
        'dtsx',
        'mha1',
        'mhm1',
        'ac3',
        'eac3',
        'ec3',
        'av3a',
      ]) {
        expect(kAudioExtensions.contains(ext), isTrue,
            reason: '本地扫描漏了 .$ext');
      }
    });

    test('通用格式仍全部收录', () {
      for (final ext in <String>['mp3', 'flac', 'm4a', 'mp4', 'wav', 'ogg']) {
        expect(kAudioExtensions.contains(ext), isTrue);
      }
    });
  });

  group('detectSpecialFormat 对本地特殊格式的识别', () {
    test('按扩展名映射到需要自研解码器的档位', () {
      expect(detectSpecialFormat('/music/a.nac'), SpecialFormat.nac);
      expect(detectSpecialFormat('/music/a.dtsx'), SpecialFormat.dts);
      expect(detectSpecialFormat('/music/a.dtshd'), SpecialFormat.dts);
      expect(detectSpecialFormat('/music/a.mha1'), SpecialFormat.ra360);
      expect(detectSpecialFormat('/music/a.mhm1'), SpecialFormat.ra360);
    });

    test('杜比 AC-3 / E-AC-3 可交给 media_kit 直解', () {
      expect(detectSpecialFormat('/music/a.ac3'), SpecialFormat.ac3);
      expect(detectSpecialFormat('/music/a.eac3'), SpecialFormat.eac3);
      expect(detectSpecialFormat('/music/a.ec3'), SpecialFormat.eac3);
    });

    test('MP4 里的 dtsx / mha1 / ec-3 靠 fourcc 识别', () {
      // 'mha1' 出现在 ftyp 兼容品牌区
      final head = '....ftypM4A mha1isom'.codeUnits;
      expect(detectSpecialFormat('/music/a.mp4', head: head),
          SpecialFormat.ra360);
    });
  });

  group('LocalSpecialPlayer', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('local_special_'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('缓存 key 由路径+大小+mtime 决定且可复现', () {
      final f = File('${dir.path}${Platform.pathSeparator}song.nac');
      f.writeAsBytesSync(List<int>.filled(128, 1));
      expect(LocalSpecialPlayer.cacheKey(f),
          LocalSpecialPlayer.cacheKey(f));
      expect(LocalSpecialPlayer.cacheKey(f).length, 64);
    });

    test('普通 mp3 不需要转码（返回 null）', () async {
      final f = File('${dir.path}${Platform.pathSeparator}song.mp3');
      f.writeAsBytesSync(List<int>.filled(128, 0));
      expect(await LocalSpecialPlayer.ensurePlayable(_localSong(f.path)),
          isNull);
    });

    test('杜比 AC-3 直接播放（返回 null，不做无谓转码）', () async {
      final f = File('${dir.path}${Platform.pathSeparator}song.ac3');
      f.writeAsBytesSync(<int>[0x0B, 0x77, 1, 2, 3]);
      expect(await LocalSpecialPlayer.ensurePlayable(_localSong(f.path)),
          isNull);
    });

    test('NAC / DTS:X / 360RA 在无内置解码器的平台返回空串', () async {
      // CI runner 非 Android：三个解码器 isSupported 均为 false，
      // ensurePlayable 应返回 ''（由播放器提示用工具箱转码），而不是抛异常
      // 或把原始 .nac 直接丢给 media_kit。
      if (Platform.isAndroid) return; // 真机上跳过本例
      for (final ext in <String>['nac', 'dtsx', 'mha1']) {
        final f = File('${dir.path}${Platform.pathSeparator}song.$ext');
        f.writeAsBytesSync(List<int>.filled(64, 0));
        final notices = <String>[];
        final out = await LocalSpecialPlayer.ensurePlayable(
          _localSong(f.path),
          onNotice: notices.add,
        );
        expect(out, '', reason: '.$ext 在无解码器平台应明确返回不可转码');
        expect(notices, isEmpty);
      }
    });
  });
}
