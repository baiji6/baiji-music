/// 极简 PCM WAV 读写，供本地升频管线输入输出。
///
/// 读：支持 8/16/24/32-bit 整型 PCM 与 32/64-bit IEEE float，单/多声道，
///     WAVE_FORMAT_EXTENSIBLE 也按 SubFormat 识别；统一转成 [-1,1] 的分声道
///     [Float64List]（**绝不编造规格**，解析不了就抛异常）。
/// 写：24-bit little-endian PCM WAV（蝰蛇母带目标规格 96k/192k 24bit），
///     带峰值归一与 TPDF 抖动，抖动用确定性 PRNG 以便测试可复现。
library;

import 'dart:io';
import 'dart:math' as math;
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

/// 读取 [b] 在 [off] 处的 4 字节 ASCII 标签（如 `RIFF` / `data`）。
String _wavTag(Uint8List b, int off) {
  if (off + 4 > b.length) return '';
  return String.fromCharCodes([b[off], b[off + 1], b[off + 2], b[off + 3]]);
}

/// xorshift32 确定性 PRNG（用于 TPDF 抖动，测试可复现）。
int _wavNext(int x) {
  var v = x & 0xFFFFFFFF;
  v ^= v << 13;
  v &= 0xFFFFFFFF;
  v ^= v >>> 17;
  v ^= v << 5;
  return v & 0xFFFFFFFF;
}

/// WAV 文件头信息（只读头，不加载音频数据）。
///
/// [dataLength] 是 `data` 块声明的长度；流式写入的 WAV 常常声明一个
/// 虚高值（0xFFFFFFFF），实际可用长度由文件大小决定，见
/// [ViperPcmStreamReader]。
class ViperWavHeader {
  const ViperWavHeader({
    required this.audioFormat,
    required this.channels,
    required this.sampleRate,
    required this.bits,
    required this.dataOffset,
    required this.dataLength,
  });

  /// 1 = PCM 整型，3 = IEEE float。
  final int audioFormat;
  final int channels;
  final int sampleRate;
  final int bits;

  /// 音频数据在文件中的起始偏移。
  final int dataOffset;

  /// `data` 块声明的字节数。
  final int dataLength;

  int get bytesPerSample => (bits + 7) >> 3;

  int get blockAlign => channels * bytesPerSample;
}

/// 流式 PCM 读取器：按块从 WAV 文件读取样本，内存占用与文件长度无关。
///
/// 用于「ffmpeg 解码成 48 kHz WAV → 纯 Dart 升频」这条链路：解码产物
/// 直接以块的形式喂进升频引擎，不再整段读进内存。
class ViperPcmStreamReader {
  ViperPcmStreamReader._(this._file, this.header, this._availableBytes);

  final RandomAccessFile _file;
  final ViperWavHeader header;

  /// 实际可读的数据字节数（已按文件大小校正）。
  final int _availableBytes;

  int _pos = 0;

  /// 已读取的帧数。
  int get framesRead => _pos ~/ header.blockAlign;

  /// 总帧数（按实际可读字节计算）。
  int get frames =>
      header.blockAlign == 0 ? 0 : _availableBytes ~/ header.blockAlign;

  /// 打开 [path] 并解析文件头；文件不是合法 WAV 时抛 [FormatException]。
  static ViperPcmStreamReader open(String path) {
    final f = File(path).openSync();
    try {
      final head = f.readSync(12);
      if (head.length < 12) {
        throw const FormatException('文件太短，不是合法 WAV');
      }
      if (_wavTag(head, 0) != 'RIFF' || _wavTag(head, 8) != 'WAVE') {
        throw const FormatException('缺少 RIFF/WAVE 文件头');
      }

      var audioFormat = 1;
      var channels = 0;
      var sampleRate = 0;
      var bits = 0;
      var dataOffset = -1;
      var dataLength = 0;
      var haveFmt = false;

      var off = 12;
      while (true) {
        final ch = f.readSync(8);
        if (ch.length < 8) break;
        final id = _wavTag(ch, 0);
        final size = ByteData.sublistView(ch).getUint32(4, Endian.little);
        final start = off + 8;

        if (id == 'fmt ') {
          final body = f.readSync(size);
          if (body.length < 16) {
            throw const FormatException('WAV fmt 块过短');
          }
          final bd = ByteData.sublistView(body);
          audioFormat = bd.getUint16(0, Endian.little);
          channels = bd.getUint16(2, Endian.little);
          sampleRate = bd.getUint32(4, Endian.little);
          bits = bd.getUint16(14, Endian.little);
          if (audioFormat == 0xFFFE && body.length >= 40) {
            audioFormat = bd.getUint16(24, Endian.little);
          }
          haveFmt = true;
        } else if (id == 'data') {
          dataOffset = start;
          dataLength = size;
          break;
        }

        final next = start + size + (size.isOdd ? 1 : 0);
        if (next <= off) break;
        off = next;
        f.setPositionSync(off);
      }

      if (!haveFmt || dataOffset < 0 || channels <= 0 || sampleRate <= 0) {
        throw const FormatException('WAV 缺少 fmt/data 块或字段非法');
      }

      final fileLen = f.lengthSync();
      final available = (dataLength == 0 || dataLength > fileLen - dataOffset)
          ? (fileLen - dataOffset)
          : dataLength;
      final headerInfo = ViperWavHeader(
        audioFormat: audioFormat,
        channels: channels,
        sampleRate: sampleRate,
        bits: bits,
        dataOffset: dataOffset,
        dataLength: available,
      );
      f.setPositionSync(dataOffset);
      return ViperPcmStreamReader._(f, headerInfo, available);
    } catch (_) {
      f.closeSync();
      rethrow;
    }
  }

  /// 读取最多 [maxFrames] 帧到交错的 [dst]（长度需 ≥ maxFrames×声道数）。
  ///
  /// 返回实际读取的帧数；0 表示读完了。
  int read(Float64List dst, int maxFrames) {
    final ch = header.channels;
    final ba = header.blockAlign;
    if (ba <= 0 || _pos >= _availableBytes || maxFrames <= 0) return 0;

    final want = math.min(maxFrames * ba, _availableBytes - _pos);
    final raw = _file.readSync(want);
    if (raw.isEmpty) return 0;

    final bps = header.bytesPerSample;
    final frames = raw.length ~/ ba;
    final bd = ByteData.sublistView(raw);
    final fmt = header.audioFormat;

    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < ch; c++) {
        final p = i * ba + c * bps;
        double v;
        if (fmt == 3) {
          v = header.bits == 32
              ? bd.getFloat32(p, Endian.little).toDouble()
              : bd.getFloat64(p, Endian.little);
        } else {
          switch (header.bits) {
            case 8:
              v = (raw[p] - 128) / 128.0;
              break;
            case 16:
              v = bd.getInt16(p, Endian.little) / 32768.0;
              break;
            case 24:
              var x = raw[p] | (raw[p + 1] << 8) | (raw[p + 2] << 16);
              if (x >= 0x800000) x -= 0x1000000;
              v = x / 8388608.0;
              break;
            case 32:
              v = bd.getInt32(p, Endian.little) / 2147483648.0;
              break;
            default:
              throw FormatException('不支持的 PCM 位深: ${header.bits}');
          }
        }
        dst[i * ch + c] = v;
      }
    }
    _pos += frames * ba;
    return frames;
  }

  void close() {
    try {
      _file.closeSync();
    } catch (_) {}
  }
}

/// 24-bit PCM WAV 流式写入器。
///
/// 与 [ViperWav.encode24] 的区别：**不一次性分配整段缓冲**，按块写入磁盘。
/// 写一整首 192 kHz/24bit 歌曲（4 分钟 ≈ 264 MB）时，内存占用只有几十 KB。
class ViperWav24Writer {
  ViperWav24Writer._(this._file, this.sampleRate, this.channels, this.dither);

  final RandomAccessFile _file;
  final int sampleRate;
  final int channels;

  /// 是否加 TPDF 抖动（1 LSB 峰峰值）。关闭后往返误差只剩量化误差。
  final bool dither;

  int _frames = 0;
  int _rng = 0x9E3779B9;
  Uint8List _buf = Uint8List(0);

  /// 已写入的帧数。
  int get frames => _frames;

  /// 已写入的字节数（含 44 字节文件头）。
  int get bytes => 44 + _frames * channels * 3;

  /// 在 [path] 创建写入器（会覆盖已有文件）。
  static ViperWav24Writer create(
    String path, {
    required int sampleRate,
    required int channels,
    bool dither = true,
  }) {
    final f = File(path).openSync(mode: FileMode.write);
    final w = ViperWav24Writer._(f, sampleRate, channels, dither);
    w._writeHeader(0);
    return w;
  }

  /// 写入 [frames] 帧交错 PCM（[interleaved] 长度 ≥ frames×声道数）。
  void write(Float64List interleaved, int frames) {
    if (frames <= 0) return;
    final need = frames * channels * 3;
    if (_buf.length < need) _buf = Uint8List(need);
    const scale = 8388607.0; // 2^23-1
    var p = 0;
    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < channels; c++) {
        var x = interleaved[i * channels + c];
        if (dither) {
          // 两个均匀随机数相减 → 三角分布（TPDF），幅度 1 LSB。
          _rng = _wavNext(_rng);
          final r1 = (_rng & 0xFFFFFF) / 0xFFFFFF;
          _rng = _wavNext(_rng);
          final r2 = (_rng & 0xFFFFFF) / 0xFFFFFF;
          x += (r1 - r2) / scale;
        }
        var q = (x * scale).round();
        if (q > 8388607) q = 8388607;
        if (q < -8388608) q = -8388608;
        final u = q < 0 ? q + 0x1000000 : q;
        _buf[p] = u & 0xFF;
        _buf[p + 1] = (u >> 8) & 0xFF;
        _buf[p + 2] = (u >> 16) & 0xFF;
        p += 3;
      }
    }
    _file.writeFromSync(_buf, 0, need);
    _frames += frames;
  }

  /// 收尾：把文件裁剪/补齐到恰好 [totalFrames] 帧并回填文件头。
  ///
  /// 流式升频在冲刷尾部帧时可能多产出少量「补零幻听」样本（尾部窗口延伸
  /// 到了输入末尾之外），这里统一截断，保证输出时长与输入严格一致。
  void finish(int totalFrames) {
    final dataBytes = totalFrames * channels * 3;
    final target = 44 + dataBytes;
    final current = _file.lengthSync();
    if (current > target) {
      _file.truncateSync(target);
    } else if (current < target) {
      var left = target - current;
      final zeros = Uint8List(left > 65536 ? 65536 : left);
      while (left > 0) {
        final n = left > zeros.length ? zeros.length : left;
        _file.writeFromSync(zeros, 0, n);
        left -= n;
      }
    }
    _file.setPositionSync(0);
    _writeHeader(dataBytes);
    _file.flushSync();
  }

  void close() {
    try {
      _file.closeSync();
    } catch (_) {}
  }

  void _writeHeader(int dataBytes) {
    final b = Uint8List(44);
    final bd = ByteData.sublistView(b);
    void tag(int off, String s) {
      for (var i = 0; i < 4; i++) {
        b[off + i] = s.codeUnitAt(i);
      }
    }

    tag(0, 'RIFF');
    bd.setUint32(4, 36 + dataBytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little); // PCM
    bd.setUint16(22, channels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, sampleRate * channels * 3, Endian.little);
    bd.setUint16(32, channels * 3, Endian.little);
    bd.setUint16(34, 24, Endian.little);
    tag(36, 'data');
    bd.setUint32(40, dataBytes, Endian.little);
    _file.writeFromSync(b, 0, 44);
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
          rng = _wavNext(rng);
          final r1 = (rng & 0xFFFFFF) / 0xFFFFFF;
          rng = _wavNext(rng);
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
