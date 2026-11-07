/// 极简 PCM WAV 读写，供本地升频管线输入输出。
///
/// 读：支持 8/16/24/32-bit 整型 PCM 与 32/64-bit IEEE float，单/多声道，
///     WAVE_FORMAT_EXTENSIBLE 也按 SubFormat 识别；统一转成 [-1,1] 的分声道
///     [Float64List]（**绝不编造规格**，解析不了就抛异常）。
/// 写：24-bit little-endian PCM WAV（蝰蛇母带目标规格 96k/192k 24bit），
///     带峰值归一与 TPDF 抖动，抖动用确定性 PRNG 以便测试可复现。
library;

import 'dart:io';
import 'dart:typed_data';

/// 解码后的多声道 PCM（归一化到 [-1,1]）。
class ViperAudio {
  const ViperAudio(this.sampleRate, this.channels, this.data);

  final int sampleRate;
  final int channels;

  /// 每个声道一条 [Float64List]，长度一致。
  final List<Float64List> data;

  int get frames => data.isEmpty ? 0 : data[0].length;

  /// 峰值绝对值（用于归一化）。
  double peak() {
    var p = 0.0;
    for (final ch in data) {
      for (final v in ch) {
        final a = v.abs();
        if (a > p) p = a;
      }
    }
    return p;
  }
}

class ViperWav {
  const ViperWav._();

  static ViperAudio readFile(String path) =>
      readBytes(File(path).readAsBytesSync());

  /// 解析 WAV 字节。
  static ViperAudio readBytes(Uint8List b) {
    if (b.length < 44) {
      throw const FormatException('文件太短，不是合法 WAV');
    }
    final bd = ByteData.sublistView(b);
    if (_tag(bd, 0) != 'RIFF' || _tag(bd, 8) != 'WAVE') {
      throw const FormatException('缺少 RIFF/WAVE 文件头');
    }

    int audioFormat = 1;
    int channels = 0;
    int sampleRate = 0;
    int bits = 0;
    Uint8List? pcm;
    var off = 12;
    while (off + 8 <= b.length) {
      final id = _tag(bd, off);
      final size = bd.getUint32(off + 4, Endian.little);
      final start = off + 8;
      if (start + size > b.length) break;
      if (id == 'fmt ') {
        audioFormat = bd.getUint16(start, Endian.little);
        channels = bd.getUint16(start + 2, Endian.little);
        sampleRate = bd.getUint32(start + 4, Endian.little);
        bits = bd.getUint16(start + 14, Endian.little);
        if (audioFormat == 0xFFFE && size >= 40) {
          // WAVE_FORMAT_EXTENSIBLE：SubFormat 的前两个字节才是真正的格式。
          audioFormat = bd.getUint16(start + 24, Endian.little);
        }
      } else if (id == 'data') {
        pcm = Uint8List.sublistView(b, start, start + size);
      }
      off = start + size + (size.isOdd ? 1 : 0);
      if (id == 'data') break;
    }
    if (pcm == null || channels <= 0 || sampleRate <= 0 || bits <= 0) {
      throw const FormatException('WAV 缺少 fmt/data 块或字段非法');
    }

    final bytesPerSample = (bits + 7) ~/ 8;
    final blockAlign = channels * bytesPerSample;
    if (blockAlign == 0) throw const FormatException('WAV 位深非法');
    final frames = pcm.length ~/ blockAlign;
    final out = List<Float64List>.generate(
        channels, (_) => Float64List(frames), growable: false);
    final view = ByteData.sublistView(pcm);

    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < channels; c++) {
        final p = i * blockAlign + c * bytesPerSample;
        double v;
        switch (audioFormat) {
          case 1: // PCM
            switch (bits) {
              case 8:
                v = (pcm[p] - 128) / 128.0;
                break;
              case 16:
                v = view.getInt16(p, Endian.little) / 32768.0;
                break;
              case 24:
                var raw = pcm[p] |
                    (pcm[p + 1] << 8) |
                    (pcm[p + 2] << 16);
                if (raw >= 0x800000) raw -= 0x1000000;
                v = raw / 8388608.0;
                break;
              case 32:
                v = view.getInt32(p, Endian.little) / 2147483648.0;
                break;
              default:
                throw FormatException('不支持的 PCM 位深: $bits');
            }
            break;
          case 3: // IEEE float
            if (bits == 32) {
              v = view.getFloat32(p, Endian.little).toDouble();
            } else if (bits == 64) {
              v = view.getFloat64(p, Endian.little);
            } else {
              throw FormatException('不支持的 float 位深: $bits');
            }
            break;
          default:
            throw FormatException('不支持的 WAV 编码格式: $audioFormat');
        }
        out[c][i] = v;
      }
    }
    return ViperAudio(sampleRate, channels, out);
  }

  /// 把 [audio] 编码成 24-bit PCM WAV 字节。
  ///
  /// [peakNormalize] 为真时先把峰值缩放到 [headroom]，避免升频后削波；
  /// [dither] 为真时加 1 LSB 峰峰值的 TPDF 抖动（确定性，测试可复现）。
  static Uint8List encode24(
    ViperAudio audio, {
    bool peakNormalize = true,
    bool dither = true,
    double headroom = 0.94,
  }) {
    final frames = audio.frames;
    final ch = audio.channels;
    final dataLen = frames * ch * 3;
    final total = 44 + dataLen;
    final out = Uint8List(total);
    final bd = ByteData.sublistView(out);

    _writeTag(bd, 0, 'RIFF');
    bd.setUint32(4, total - 8, Endian.little);
    _writeTag(bd, 8, 'WAVE');
    _writeTag(bd, 12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little); // PCM
    bd.setUint16(22, ch, Endian.little);
    bd.setUint32(24, audio.sampleRate, Endian.little);
    bd.setUint32(28, audio.sampleRate * ch * 3, Endian.little);
    bd.setUint16(32, ch * 3, Endian.little);
    bd.setUint16(34, 24, Endian.little);
    _writeTag(bd, 36, 'data');
    bd.setUint32(40, dataLen, Endian.little);

    final peak = audio.peak();
    final gain = peakNormalize && peak > headroom ? headroom / peak : 1.0;
    const scale = 8388607.0; // 2^23-1
    var rng = 0x9E3779B9 ^ (frames * 2654435761);

    var p = 44;
    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < ch; c++) {
        var x = audio.data[c][i] * gain;
        if (dither) {
          // 两个均匀随机数相减 → 三角分布（TPDF），幅度 1 LSB。
          rng = _next(rng);
          final r1 = (rng & 0xFFFFFF) / 0xFFFFFF;
          rng = _next(rng);
          final r2 = (rng & 0xFFFFFF) / 0xFFFFFF;
          x += (r1 - r2) / scale;
        }
        var q = (x * scale).round();
        if (q > 8388607) q = 8388607;
        if (q < -8388608) q = -8388608;
        final u = q < 0 ? q + 0x1000000 : q;
        out[p] = u & 0xFF;
        out[p + 1] = (u >> 8) & 0xFF;
        out[p + 2] = (u >> 16) & 0xFF;
        p += 3;
      }
    }
    return out;
  }

  static Future<void> write24(String path, ViperAudio audio,
      {bool dither = true}) async {
    await File(path).writeAsBytes(encode24(audio, dither: dither),
        flush: true);
  }

  static int _next(int x) {
    var v = x & 0xFFFFFFFF;
    v ^= v << 13;
    v &= 0xFFFFFFFF;
    v ^= v >>> 17;
    v ^= v << 5;
    return v & 0xFFFFFFFF;
  }

  static String _tag(ByteData bd, int off) {
    if (off + 4 > bd.lengthInBytes) return '';
    return String.fromCharCodes([
      bd.getUint8(off),
      bd.getUint8(off + 1),
      bd.getUint8(off + 2),
      bd.getUint8(off + 3),
    ]);
  }

  static void _writeTag(ByteData bd, int off, String s) {
    for (var i = 0; i < 4; i++) {
      bd.setUint8(off + i, s.codeUnitAt(i));
    }
  }
}
