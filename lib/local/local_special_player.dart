// 本地特殊格式（NAC / DTS:X / 360RA / 杜比）播放前转码（v2.5.8-fix1）。
//
// 本地音乐扫描过去只认 mp3/flac/m4a/wav 等通用容器，NAC(.nac)、
// DTS:X(.dtsx/.dtshd)、360RA(.mha1/.mhm1) 与杜比(.ac3/.eac3/.ec3) 根本
// 不进曲库；即使手工放进去，media_kit 的 ffmpeg 也没有 MHA1 / DTS UHD /
// NAC 解码器，直接播会报 `Failed to recognize file format.`。
//
// 这里在播放器取流之前按 `detectSpecialFormat` 分流：
// - NAC / DTS:X / 360RA → 复用三个自研解码器的 `decodeLocalToWav`，
//   转成标准 PCM WAV 后播放（带按「路径+大小+mtime」的缓存，只解一次）；
// - AC-3 / E-AC-3（杜比全景声）/ 普通 MP4 → media_kit 内置 ffmpeg 有
//   ac3/eac3 解码器，直接播放原文件即可，不做无谓转码。
//
// 自研解码器仅 Android arm64 可用（见各自 `isSupported`），其它平台返回
// 空串，由播放器给出提示并尝试原文件。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';
import '../core/audio_transcoder.dart' show SpecialFormat, detectSpecialFormat;
import '../core/wav_cache.dart';
import '../dts/dts_decoder.dart';
import '../models/models.dart';
import '../nac/nac_decoder.dart';
import '../ra360/ra360_decoder.dart';

abstract final class LocalSpecialPlayer {
  static const String _tag = 'LocalSpecialPlayer';

  /// 返回可直接交给 media_kit 的 URI。
  ///
  /// - `null`：不需要转码（普通格式 / ffmpeg 可直解），调用方播原文件；
  /// - 空串：需要转码但当前平台不支持或解码失败；
  /// - 非空：转码后的 WAV 的 `file://` URI。
  static Future<String?> ensurePlayable(
    Song song, {
    void Function(String notice)? onNotice,
  }) async {
    final path = song.localPath;
    if (path.isEmpty) return null;
    final src = File(path);
    if (!src.existsSync()) return null;

    // mp4 里的 dtsx / mha1 / ec-3 需要读文件头 fourcc 才能认出来。
    Uint8List? head;
    try {
      final len = src.lengthSync();
      final raf = src.openSync(mode: FileMode.read);
      try {
        final n = len < 4096 ? len : 4096;
        head = Uint8List.fromList(raf.readSync(n));
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      // 读不到头就只按扩展名判断。
    }

    final sp = detectSpecialFormat(path, head: head);
    if (sp == null) return null;

    switch (sp) {
      case SpecialFormat.nac:
        if (!NacMusic.isSupported) return '';
        onNotice?.call('本地 NAC 神经解码中，首次播放约需 1 分钟…');
        return _decode(src, NacMusic.decodeLocalToWav, label: 'NAC');
      case SpecialFormat.dts:
        if (!DtsMusic.isSupported) return '';
        onNotice?.call('本地 DTS:X 转码中…');
        return _decode(src, DtsMusic.decodeLocalToWav, label: 'DTS:X');
      case SpecialFormat.ra360:
        if (!Ra360Music.isSupported) return '';
        onNotice?.call('本地 360RA 转码中…');
        return _decode(src, Ra360Music.decodeLocalToWav, label: '360RA');
      case SpecialFormat.ac3:
      case SpecialFormat.eac3:
      case SpecialFormat.av3a:
      case SpecialFormat.mp4:
        // AC-3 / E-AC-3（杜比全景声）由 media_kit 的 ffmpeg 直接解码；
        // AV3A / 普通 MP4 也先交给播放器，解不了会明确报错而不是静默。
        return null;
    }
  }

  /// 生成稳定的缓存 key：路径 + 大小 + 修改时间，文件被替换后自动重新解码。
  static String cacheKey(File f) {
    final st = f.statSync();
    return sha256
        .convert(utf8.encode(
            '${f.path}|${st.size}|${st.modified.millisecondsSinceEpoch}'))
        .toString();
  }

  static Future<String?> _decode(
    File src,
    Future<String?> Function(String src, String wav) decoder, {
    required String label,
  }) async {
    try {
      final cacheDir = await getApplicationCacheDirectory();
      final root = Directory(
          '${cacheDir.path}${Platform.pathSeparator}local_wav');
      if (!root.existsSync()) root.createSync(recursive: true);
      final wavPath =
          '${root.path}${Platform.pathSeparator}local_${cacheKey(src)}.wav';

      // 完整缓存直接回放（半成品会被清理并重新解码）。
      if (await WavCache.isValidCache(File(wavPath), tag: _tag)) {
        return Uri.file(wavPath).toString();
      }

      // decodeLocalToWav 内部写 .part，校验完整后原子落盘到 wavPath。
      final out = await decoder(src.path, wavPath);
      if (out == null) {
        AppLog.w(_tag, '$label 本地转码失败: ${src.path}');
        return '';
      }
      AppLog.i(_tag, '$label 本地转码完成 -> $wavPath');
      return Uri.file(wavPath).toString();
    } catch (e) {
      AppLog.w(_tag, '$label 本地转码异常: $e');
      return '';
    }
  }
}
