/// 音频元数据读取（纯 Dart，六端通用）。
///
/// 与 `audio_tagger.dart`（写入端）对称，但**刻意不共用私有实现**：
/// 写入端有 60 个测试保护，读取端需要的多是新能力（时长解析、payload 解码），
/// 强行抽共享层要改写入端 20 余处调用，收益不抵回归风险。
///
/// 支持的容器与取值来源：
///
/// | 容器 | 标签 | 时长 |
/// |---|---|---|
/// | MP3 | ID3v2.3/2.4（TIT2/TPE1/TALB/USLT/APIC），回退 ID3v1 | Xing/Info/VBRI 精确值，否则 CBR 估算 |
/// | FLAC | Vorbis Comment + PICTURE 块 | STREAMINFO 的 totalSamples/sampleRate（精确） |
/// | M4A/MP4 | `moov/udta/meta/ilst` 的 ©nam/©ART/©alb/©lyr/covr | `mvhd` 的 duration/timescale |
/// | OGG/Opus | Vorbis Comment + METADATA_BLOCK_PICTURE | 末页 granulePosition / sampleRate |
/// | WAV | `LIST/INFO` 的 INAM/IART/IPRD | `fmt ` 的 byteRate → dataSize/byteRate |
///
/// **健壮性优先**：任何异常都吞掉并返回已解析到的部分（或空对象），
/// 扫描几千个文件时，一个坏文件不该让整个流程失败。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 从音频文件读出的元数据。
class AudioMetadata {
  const AudioMetadata({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.lyric = '',
    this.format = '',
    this.coverMime = '',
    this.durationMs = 0,
    this.bitrate = 0,
    this.sampleRate = 0,
    this.coverBytes,
  });

  final String title;
  final String artist;
  final String album;

  /// 内嵌歌词（标准 LRC 或增强逐字 LRC 文本）。
  final String lyric;

  /// 容器格式：mp3 / flac / m4a / ogg / wav。
  final String format;

  final String coverMime;
  final int durationMs;

  /// 码率（kbps）。
  final int bitrate;

  final int sampleRate;

  /// 内嵌封面原始字节；无封面为 null。
  final Uint8List? coverBytes;

  /// 是否读到了任何有效标签（用于决定要不要走文件名兜底）。
  bool get hasTags => title.isNotEmpty || artist.isNotEmpty || album.isNotEmpty;

  bool get hasCover => coverBytes != null && coverBytes!.isNotEmpty;

  AudioMetadata copyWith({
    String? title,
    String? artist,
    String? album,
    String? lyric,
    String? format,
    String? coverMime,
    int? durationMs,
    int? bitrate,
    int? sampleRate,
    Uint8List? coverBytes,
  }) {
    return AudioMetadata(
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      lyric: lyric ?? this.lyric,
      format: format ?? this.format,
      coverMime: coverMime ?? this.coverMime,
      durationMs: durationMs ?? this.durationMs,
      bitrate: bitrate ?? this.bitrate,
      sampleRate: sampleRate ?? this.sampleRate,
      coverBytes: coverBytes ?? this.coverBytes,
    );
  }
}

/// 音频元数据读取入口。
class AudioReader {
  AudioReader._();

  /// 头部预读大小：ID3v2、FLAC 头、M4A 部分结构都在文件开头。
  static const int _headBytes = 64 * 1024;

  /// 尾部预读大小：ID3v1 在末尾，OGG 末页、M4A 的 moov 也常在尾部。
  static const int _tailBytes = 512 * 1024;

  /// 封面上限，超过则丢弃（避免把超大图读进内存）。
  static const int _maxCoverBytes = 2 * 1024 * 1024;

  /// 读取一个文件的元数据（异步包装，内部只做同步 IO）。
  ///
  /// 失败时返回空的 [AudioMetadata]，不抛异常。
  /// 在 Isolate 里批量扫描时请用 [readSync]。
  static Future<AudioMetadata> read(
    String path, {
    bool withCover = true,
    bool withLyric = true,
  }) async =>
      readSync(path, withCover: withCover, withLyric: withLyric);

  /// 同步读取元数据。批量扫描首选（通常跑在后台 Isolate 里）。
  ///
  /// 失败时返回空的 [AudioMetadata]，不抛异常。
  static AudioMetadata readSync(
    String path, {
    bool withCover = true,
    bool withLyric = true,
  }) {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return const AudioMetadata();

      final len = file.lengthSync();
      if (len <= 0) return const AudioMetadata();

      raf = file.openSync(mode: FileMode.read);
      final head = _readAt(raf, 0, len < _headBytes ? len : _headBytes);
      final format = _detectFormat(path, head);
      if (format.isEmpty) return const AudioMetadata();

      final tailLen = len < _tailBytes ? len : _tailBytes;
      final tail = _readAt(raf, len - tailLen, tailLen);

      final meta = switch (format) {
        'mp3' => _readMp3(raf, head, tail, len),
        'flac' => _readFlac(raf, head, len),
        'm4a' => _readMp4(raf, head, tail, len),
        'ogg' => _readOgg(raf, head, tail, len),
        'wav' => _readWav(head, len),
        _ => const AudioMetadata(),
      };

      // 这里不用 copyWith：它的 `??` 语义无法把已有字段清成 null / 空串，
      // 而 withCover / withLyric 为 false 时正是要清掉。
      if (withCover && withLyric) return meta.copyWith(format: format);
      return AudioMetadata(
        title: meta.title,
        artist: meta.artist,
        album: meta.album,
        lyric: withLyric ? meta.lyric : '',
        format: format,
        coverMime: withCover ? meta.coverMime : '',
        durationMs: meta.durationMs,
        bitrate: meta.bitrate,
        sampleRate: meta.sampleRate,
        coverBytes: withCover ? meta.coverBytes : null,
      );
    } catch (e) {
      // 坏文件不该让扫描中断
      return const AudioMetadata();
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {
        // 关闭失败可忽略
      }
    }
  }

  // ==================== 格式识别 ====================

  /// 先用魔数判断，再回退到扩展名（扩展名可能写错或缺失）。
  static String _detectFormat(String path, Uint8List head) {
    if (head.length >= 4) {
      if (_eq(head, 0, 'ID3')) return 'mp3';
      if (_eq(head, 0, 'fLaC')) return 'flac';
      if (_eq(head, 0, 'OggS')) return 'ogg';
      if (_eq(head, 0, 'RIFF') && head.length >= 12 && _eq(head, 8, 'WAVE')) {
        return 'wav';
      }
      // ftyp 盒：M4A / MP4 / M4B 等
      if (head.length >= 12 && _eq(head, 4, 'ftyp')) return 'm4a';
    }
    // MPEG 裸帧（无 ID3 的 MP3）
    if (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) {
      return 'mp3';
    }

    final ext = _extOf(path);
    return switch (ext) {
      'mp3' => 'mp3',
      'flac' => 'flac',
      'm4a' || 'mp4' || 'm4b' || 'aac' => 'm4a',
      'ogg' || 'opus' || 'oga' => 'ogg',
      'wav' || 'wave' => 'wav',
      _ => '',
    };
  }

  // ==================== MP3 / ID3 ====================

  static AudioMetadata _readMp3(
      RandomAccessFile raf, Uint8List head, Uint8List tail, int fileLen) {
    String title = '', artist = '', album = '', lyric = '';
    Uint8List? cover;
    String coverMime = '';

    // ---- ID3v2（文件头）----
    var audioStart = 0;
    if (_eq(head, 0, 'ID3') && head.length >= 10) {
      final major = head[3];
      final syncsafe = ((head[6] & 0x7F) << 21) |
          ((head[7] & 0x7F) << 14) |
          ((head[8] & 0x7F) << 7) |
          (head[9] & 0x7F);
      final footer = (head[5] & 0x10) != 0;
      final total = 10 + syncsafe + (footer ? 10 : 0);
      if (syncsafe > 0 && syncsafe < 64 * 1024 * 1024 && total <= fileLen) {
        audioStart = total;
        final body = _readAt(raf, 10, syncsafe);
        final unsynced = major <= 3 && (head[5] & 0x80) != 0;
        for (final f in _parseId3Frames(body, major, unsynced)) {
          switch (f.id) {
            case 'TIT2':
              title = _decodeId3Text(f.data);
            case 'TPE1':
              artist = _decodeId3Text(f.data);
            case 'TALB':
              album = _decodeId3Text(f.data);
            case 'USLT':
              lyric = _decodeUslt(f.data);
            case 'APIC':
              if (cover == null) {
                final pic = _decodeApic(f.data);
                if (pic != null) {
                  cover = pic.$2;
                  coverMime = pic.$1;
                }
              }
          }
        }
      }
    }

    // ---- ID3v1（文件尾，仅当 v2 没给出内容时兜底）----
    if (title.isEmpty && artist.isEmpty && tail.length >= 128) {
      final t = tail.sublist(tail.length - 128);
      if (_eq(t, 0, 'TAG')) {
        title = _trimNul(latin1.decode(t.sublist(3, 33), allowInvalid: true));
        artist = _trimNul(latin1.decode(t.sublist(33, 63), allowInvalid: true));
        album = _trimNul(latin1.decode(t.sublist(63, 93), allowInvalid: true));
      }
    }

    // ---- 时长 ----
    final dur = _mp3Duration(raf, audioStart, fileLen, tail);

    return AudioMetadata(
      title: title,
      artist: artist,
      album: album,
      lyric: lyric,
      coverMime: coverMime,
      durationMs: dur.$1,
      bitrate: dur.$2,
      sampleRate: dur.$3,
      coverBytes: cover,
    );
  }

  /// 返回 (durationMs, bitrateKbps, sampleRate)。
  static (int, int, int) _mp3Duration(
      RandomAccessFile raf, int audioStart, int fileLen, Uint8List tail) {
    try {
      final probeLen = fileLen - audioStart;
      if (probeLen <= 0) return (0, 0, 0);
      final probe = _readAt(
          raf, audioStart, probeLen < 4096 ? probeLen : 4096);

      // 先找第一个 MPEG 帧头，拿到 sampleRate
      var frameOff = -1;
      var sampleRate = 0;
      for (var i = 0; i + 4 <= probe.length; i++) {
        final h = _parseMpegFrameHeader(probe, i);
        if (h != null) {
          frameOff = i;
          sampleRate = h.$2;
          break;
        }
      }
      if (frameOff < 0) return (0, 0, 0);

      final bitrateKbps = _parseMpegFrameHeader(probe, frameOff)!.$1;

      // Xing / Info 头：位于帧头 + 侧信息之后
      final sideInfo = _mpegSideInfoSize(probe, frameOff);
      final xingOff = frameOff + 4 + sideInfo;
      if (xingOff + 12 <= probe.length) {
        final tag = String.fromCharCodes(probe.sublist(xingOff, xingOff + 4));
        if (tag == 'Xing' || tag == 'Info') {
          var p = xingOff + 4;
          final flags = _be32(probe, p);
          p += 4;
          if (flags & 0x1 != 0 && p + 4 <= probe.length) {
            final frames = _be32(probe, p);
            if (frames > 0 && sampleRate > 0) {
              final ms = (frames * _samplesPerFrame(probe, frameOff) * 1000) ~/
                  sampleRate;
              return (ms, bitrateKbps, sampleRate);
            }
          }
        }
      }

      // VBRI：固定位于帧头后 32 字节
      final vbriOff = frameOff + 36;
      if (vbriOff + 26 <= probe.length &&
          _eq(probe, vbriOff, 'VBRI')) {
        final frames = _be32(probe, vbriOff + 14);
        if (frames > 0 && sampleRate > 0) {
          final ms =
              (frames * _samplesPerFrame(probe, frameOff) * 1000) ~/ sampleRate;
          return (ms, bitrateKbps, sampleRate);
        }
      }

      // 兜底：CBR 估算。需要扣掉尾部的 ID3v1 / APE 等附加数据
      if (bitrateKbps > 0) {
        var audioBytes = fileLen - audioStart;
        if (tail.length >= 128 && _eq(tail, tail.length - 128, 'TAG')) {
          audioBytes -= 128;
        }
        if (audioBytes > 0) {
          // 毫秒 = 字节数 * 8 / 码率(kbps)。先除再乘 1000 会整除成 0，
          // 所以这里一步到位：kbps 的 1000 与毫秒的 1000 正好约掉。
          final ms = (audioBytes * 8) ~/ bitrateKbps;
          return (ms, bitrateKbps, sampleRate);
        }
      }
      return (0, bitrateKbps, sampleRate);
    } catch (_) {
      return (0, 0, 0);
    }
  }

  /// 解析 MPEG 帧头，返回 (bitrateKbps, sampleRate)；非法返回 null。
  ///
  /// 帧头布局：`AAAAAAAA AAABBCCD EEEEFFGH IIJJKLMM`
  static (int, int)? _parseMpegFrameHeader(Uint8List d, int off) {
    if (off + 4 > d.length) return null;
    if (d[off] != 0xFF || (d[off + 1] & 0xE0) != 0xE0) return null;

    final versionBits = (d[off + 1] >> 3) & 0x03; // 00=2.5 10=2 11=1
    final layerBits = (d[off + 1] >> 1) & 0x03; // 01=Layer3
    if (layerBits == 0) return null;
    final bitrateIndex = (d[off + 2] >> 4) & 0x0F;
    final srIndex = (d[off + 2] >> 2) & 0x03;
    if (bitrateIndex == 0 || bitrateIndex == 15 || srIndex == 3) return null;

    const sampleRates = <int>[44100, 48000, 32000];
    int sampleRate;
    List<int> bitrates;
    switch (versionBits) {
      case 3: // MPEG1
        sampleRate = sampleRates[srIndex];
        bitrates = switch (layerBits) {
          // 三张表索引含义不同，切勿混用：Layer3 最高只到 320kbps，
          // 而 Layer1 在相同索引上是 288/416/448 这类值。
          3 => const [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0],
          2 => const [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0],
          _ => const [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0],
        };
      case 2: // MPEG2
        sampleRate = const [22050, 24000, 16000][srIndex];
        bitrates = const [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];
      case 0: // MPEG2.5
        sampleRate = const [11025, 12000, 8000][srIndex];
        bitrates = const [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];
      default:
        return null; // 01 = reserved
    }
    return (bitrates[bitrateIndex], sampleRate);
  }

  /// Layer3 每帧样本数：MPEG1 为 1152，MPEG2 / MPEG2.5 为 576。
  ///
  /// 判断依据是帧头里的版本位（`bit4-3`），不能拿第二字节的 `0x08` 当标志——
  /// MPEG1 的版本位恰为 `11`，`0xFB & 0x08` 恒为真，会把所有 MPEG1
  /// 文件误判成 576 样本，时长正好减半。
  static int _samplesPerFrame(Uint8List d, int frameOff) {
    final versionBits = (d[frameOff + 1] >> 3) & 0x03;
    return versionBits == 3 ? 1152 : 576;
  }

  /// MPEG 侧信息长度：MPEG1 立体声 32、单声道 17；MPEG2/2.5 分别 17 / 9。
  static int _mpegSideInfoSize(Uint8List d, int frameOff) {
    final versionBits = (d[frameOff + 1] >> 3) & 0x03;
    final mono = (d[frameOff + 3] >> 6) & 0x03 == 3;
    if (versionBits == 3) return mono ? 17 : 32;
    return mono ? 9 : 17;
  }

  /// 解析 ID3v2 帧（保留原始负载）。
  static List<_Id3Frame> _parseId3Frames(
      Uint8List body, int major, bool unsynced) {
    final out = <_Id3Frame>[];
    if (major < 3) return out; // v2.2 帧头格式不同，不冒险解析

    final syncsafe = major >= 4;
    var pos = 0;
    while (pos + 10 <= body.length) {
      final id = String.fromCharCodes(body.sublist(pos, pos + 4));
      if (!RegExp(r'^[A-Z0-9]{4}$').hasMatch(id)) break;

      final size = syncsafe
          ? (((body[pos + 4] & 0x7F) << 21) |
              ((body[pos + 5] & 0x7F) << 14) |
              ((body[pos + 6] & 0x7F) << 7) |
              (body[pos + 7] & 0x7F))
          : _be32(body, pos + 4);
      final flags2 = body[pos + 9];

      // 压缩 / 加密 / 分组的帧无法安全解析
      final badV3 = major == 3 && (flags2 & 0xE0) != 0;
      final badV4 = major >= 4 && (flags2 & 0x4C) != 0;
      if (badV3 || badV4) break;
      if (size <= 0 || pos + 10 + size > body.length) break;

      var dataStart = pos + 10;
      // ID3v2.4 的可选 data length indicator
      if (major >= 4 && (flags2 & 0x01) != 0) dataStart += 4;
      if (dataStart >= pos + 10 + size) break;

      var data = Uint8List.sublistView(body, dataStart, pos + 10 + size);
      if (unsynced) data = _resync(data);
      out.add(_Id3Frame(id, data));
      pos += 10 + size;
    }
    return out;
  }

  /// 反同步还原：去掉紧跟在 0xFF 之后的填充 0x00。
  static Uint8List _resync(Uint8List src) {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < src.length; i++) {
      final b = src[i];
      out.addByte(b);
      if (b == 0xFF && i + 1 < src.length && src[i + 1] == 0x00) i++;
    }
    return out.takeBytes();
  }

  /// ID3 文本帧：`encoding(1) + 文本`，按编码字节解码。
  static String _decodeId3Text(Uint8List data) {
    if (data.isEmpty) return '';
    final enc = data[0];
    final body = data.sublist(1);
    return _decodeWithEncoding(enc, body);
  }

  /// USLT：`encoding(1) + language(3) + 描述符(终止符) + 歌词正文`。
  static String _decodeUslt(Uint8List data) {
    if (data.length < 5) return '';
    final enc = data[0];
    var pos = 4; // 跳过 language(3)，data[0] 是 encoding
    final termLen = (enc == 0x01 || enc == 0x02) ? 2 : 1;
    // 跳到描述符的终止符之后
    while (pos + termLen <= data.length) {
      final isTerm = termLen == 2
          ? (data[pos] == 0x00 && data[pos + 1] == 0x00)
          : data[pos] == 0x00;
      if (isTerm) {
        pos += termLen;
        break;
      }
      pos += termLen;
    }
    if (pos >= data.length) return '';
    return _decodeWithEncoding(enc, data.sublist(pos));
  }

  /// APIC：`encoding(1) + mime(以 0x00 结尾) + picType(1) + 描述(终止符) + 图片数据`。
  static (String, Uint8List)? _decodeApic(Uint8List data) {
    if (data.length < 4) return null;
    final enc = data[0];
    var pos = 1;

    // mime 总是 Latin-1 且以单字节 0 结尾（即使文本编码是 UTF-16）
    final mimeEnd = data.indexOf(0x00, pos);
    if (mimeEnd < 0) return null;
    final mime = latin1.decode(data.sublist(pos, mimeEnd), allowInvalid: true);
    pos = mimeEnd + 1;
    if (pos >= data.length) return null;

    pos += 1; // picture type
    final termLen = (enc == 0x01 || enc == 0x02) ? 2 : 1;
    while (pos + termLen <= data.length) {
      final isTerm = termLen == 2
          ? (data[pos] == 0x00 && data[pos + 1] == 0x00)
          : data[pos] == 0x00;
      if (isTerm) {
        pos += termLen;
        break;
      }
      pos += termLen;
    }
    if (pos >= data.length) return null;

    final bytes = Uint8List.sublistView(data, pos);
    if (bytes.length > _maxCoverBytes) return null;
    return (mime, bytes);
  }

  /// 按 ID3 编码字节解码文本，失败回退 Latin-1。
  static String _decodeWithEncoding(int enc, Uint8List body) {
    try {
      switch (enc) {
        case 0x00: // ISO-8859-1
          return _stripTerminator(latin1.decode(body, allowInvalid: true), 1);
        case 0x01: // UTF-16 with BOM
          return _decodeUtf16(body);
        case 0x02: // UTF-16BE 无 BOM
          return _stripTerminator(_utf16(body, bigEndian: true), 2);
        case 0x03: // UTF-8
          return _stripTerminator(utf8.decode(body, allowMalformed: true), 1);
        default:
          return _stripTerminator(latin1.decode(body, allowInvalid: true), 1);
      }
    } catch (_) {
      return _stripTerminator(latin1.decode(body, allowInvalid: true), 1);
    }
  }

  static String _decodeUtf16(Uint8List body) {
    if (body.length >= 2) {
      final bom = (body[0] << 8) | body[1];
      if (bom == 0xFEFF) {
        return _stripTerminator(
            _utf16(body.sublist(2), bigEndian: true), 2);
      }
      if (bom == 0xFFFE) {
        return _stripTerminator(
            _utf16(body.sublist(2), bigEndian: false), 2);
      }
    }
    // 无 BOM 按 BE
    return _stripTerminator(_utf16(body, bigEndian: true), 2);
  }

  /// 手写 UTF-16 解码（dart:convert 无 Utf16Codec）。
  ///
  /// 逐两个字节拼成 UTF-16 code unit，代理对交给 `String.fromCharCodes`
  /// 组装；孤立代理也能容纳，不会抛异常。
  static String _utf16(Uint8List bytes, {required bool bigEndian}) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(bigEndian
          ? (bytes[i] << 8) | bytes[i + 1]
          : (bytes[i + 1] << 8) | bytes[i]);
    }
    return String.fromCharCodes(units);
  }

  // ==================== FLAC ====================

  static AudioMetadata _readFlac(RandomAccessFile raf, Uint8List head, int len) {
    if (!_eq(head, 0, 'fLaC')) return const AudioMetadata(format: 'flac');

    String title = '', artist = '', album = '', lyric = '';
    Uint8List? cover;
    String coverMime = '';
    var durationMs = 0;
    var sampleRate = 0;

    var pos = 4;
    var guard = 0;
    while (pos + 4 <= head.length && guard++ < 64) {
      final last = (head[pos] & 0x80) != 0;
      final type = head[pos] & 0x7F;
      final blockLen = (head[pos + 1] << 16) |
          (head[pos + 2] << 8) |
          head[pos + 3];
      final payloadStart = pos + 4;
      if (blockLen <= 0 || payloadStart + blockLen > head.length) break;
      final payload =
          Uint8List.sublistView(head, payloadStart, payloadStart + blockLen);

      switch (type) {
        case 0: // STREAMINFO
          if (blockLen >= 18) {
            sampleRate = (payload[10] << 12) | (payload[11] << 4) | (payload[12] >> 4);
            final totalSamples = ((payload[13] & 0x0F) << 32) |
                (payload[14] << 24) |
                (payload[15] << 16) |
                (payload[16] << 8) |
                payload[17];
            if (sampleRate > 0 && totalSamples > 0) {
              durationMs = (totalSamples * 1000) ~/ sampleRate;
            }
          }
        case 4: // VORBIS_COMMENT
          for (final c in _parseVorbisComment(payload)) {
            final kv = _splitComment(c);
            switch (kv.$1) {
              case 'TITLE':
                title = kv.$2;
              case 'ARTIST':
                artist = kv.$2;
              case 'ALBUM':
                album = kv.$2;
              case 'LYRICS':
                lyric = kv.$2;
            }
          }
        case 6: // PICTURE
          if (cover == null) {
            final pic = _decodeFlacPicture(payload);
            if (pic != null) {
              cover = pic.$2;
              coverMime = pic.$1;
            }
          }
      }

      if (last) break;
      pos = payloadStart + blockLen;
    }

    return AudioMetadata(
      title: title,
      artist: artist,
      album: album,
      lyric: lyric,
      format: 'flac',
      coverMime: coverMime,
      durationMs: durationMs,
      sampleRate: sampleRate,
      coverBytes: cover,
    );
  }

  /// 解析 Vorbis Comment：`vendorLen(LE32) + vendor + count(LE32) + 条目…`
  static List<String> _parseVorbisComment(Uint8List d) {
    final out = <String>[];
    if (d.length < 8) return out;
    var pos = 0;

    int le32() {
      if (pos + 4 > d.length) return 0;
      final v = d[pos] |
          (d[pos + 1] << 8) |
          (d[pos + 2] << 16) |
          (d[pos + 3] << 24);
      pos += 4;
      return v;
    }

    final vendorLen = le32();
    if (vendorLen > 0 && pos + vendorLen <= d.length) {
      pos += vendorLen;
    }
    final count = le32();
    for (var i = 0; i < count && pos + 4 <= d.length; i++) {
      final itemLen = le32();
      if (itemLen <= 0 || pos + itemLen > d.length) break;
      out.add(utf8.decode(d.sublist(pos, pos + itemLen), allowMalformed: true));
      pos += itemLen;
    }
    return out;
  }

  /// FLAC PICTURE 块：`type(4) + mimeLen(4) + mime + descLen(4) + desc +
  /// w(4) + h(4) + depth(4) + colors(4) + dataLen(4) + data`
  static (String, Uint8List)? _decodeFlacPicture(Uint8List d) {
    if (d.length < 32) return null;
    var pos = 4; // picture type
    final mimeLen = _be32(d, pos);
    pos += 4;
    if (mimeLen <= 0 || pos + mimeLen > d.length) return null;
    final mime = latin1.decode(d.sublist(pos, pos + mimeLen), allowInvalid: true);
    pos += mimeLen;

    final descLen = _be32(d, pos);
    pos += 4;
    if (descLen < 0 || pos + descLen > d.length) return null;
    pos += descLen;

    pos += 16; // 宽 / 高 / 色深 / 颜色数
    if (pos + 4 > d.length) return null;
    final dataLen = _be32(d, pos);
    pos += 4;
    if (dataLen <= 0 || pos + dataLen > d.length) return null;
    final bytes = Uint8List.sublistView(d, pos, pos + dataLen);
    if (bytes.length > _maxCoverBytes) return null;
    return (mime, bytes);
  }

  // ==================== MP4 / M4A ====================

  static AudioMetadata _readMp4(
      RandomAccessFile raf, Uint8List head, Uint8List tail, int len) {
    // moov 可能在头部也可能在尾部（多数编码器放头部，部分放尾部）
    var buf = head;
    if (!_findBox(buf, 'moov').exists) {
      // 尾部 buf 里再找一次
      final t = _findBox(tail, 'moov');
      if (t.exists) buf = tail;
    }

    final moov = _findBox(buf, 'moov');
    if (!moov.exists) return const AudioMetadata(format: 'm4a');

    var durationMs = 0;
    var timescale = 0;
    final mvhd = _findBoxWithin(buf, moov.start, moov.end, 'mvhd');
    if (mvhd.exists) {
      timescale = mvhd.timescale;
      if (timescale > 0 && mvhd.duration > 0) {
        durationMs = (mvhd.duration * 1000) ~/ timescale;
      }
    }

    String title = '', artist = '', album = '', lyric = '';
    Uint8List? cover;
    String coverMime = '';

    final ilst = _findIlst(buf, moov.start, moov.end);
    if (ilst.exists) {
      for (final b in _parseBoxes(buf, ilst.start, ilst.end)) {
        final payloadStart = b.start + b.header;
        if (payloadStart >= b.end) continue;
        // ilst 条目下是若干 data 盒
        for (final d in _parseBoxes(buf, payloadStart, b.end)) {
          if (d.type != 'data') continue;
          final p = d.start + d.header;
          if (p + 8 > d.end) continue;
          // data 盒：version+flags(4) + locale(4) + 内容
          final content = Uint8List.sublistView(buf, p + 8, d.end);
          switch (b.type) {
            case '©nam':
              title = utf8.decode(content, allowMalformed: true);
            case '©ART':
              artist = utf8.decode(content, allowMalformed: true);
            case '©alb':
              album = utf8.decode(content, allowMalformed: true);
            case '©lyr':
              lyric = utf8.decode(content, allowMalformed: true);
            case 'covr':
              if (cover == null && content.isNotEmpty) {
                cover = content;
                coverMime = _mimeFromImageBytes(content);
              }
          }
        }
      }
    }

    return AudioMetadata(
      title: title,
      artist: artist,
      album: album,
      lyric: lyric,
      format: 'm4a',
      coverMime: coverMime,
      durationMs: durationMs,
      sampleRate: timescale,
      coverBytes: cover,
    );
  }

  /// 在 [buf] 的 [start,end) 范围内按路径查找盒子（如 udta → meta → ilst）。
  static _BoxRange _findIlst(Uint8List buf, int start, int end) {
    final udta = _findBoxWithin(buf, start, end, 'udta');
    if (!udta.exists) return const _BoxRange.none();
    final meta = _findBoxWithin(buf, udta.start, udta.end, 'meta');
    // _findBoxWithin 返回的 start 已是 payload 起点；meta 是 FullBox，
    // 真正的子盒还要再跳过 4 字节的 version + flags。
    final from = meta.exists ? meta.start + 4 : udta.start;
    final to = meta.exists ? meta.end : udta.end;
    final ilst = _findBoxWithin(buf, from, to, 'ilst');
    if (ilst.exists) return ilst;
    // 直接在 udta 下找（少数文件没有 meta 层）
    return _findBoxWithin(buf, udta.start, udta.end, 'ilst');
  }

  // ==================== OGG ====================

  static AudioMetadata _readOgg(
      RandomAccessFile raf, Uint8List head, Uint8List tail, int len) {
    String title = '', artist = '', album = '', lyric = '';
    Uint8List? cover;
    String coverMime = '';
    var sampleRate = 0;

    // 首页的 identification header 给出采样率
    if (_eq(head, 0, 'OggS') && head.length >= 30) {
      final segCount = head[26];
      var segStart = 27;
      var payloadLen = 0;
      for (var i = 0; i < segCount && segStart + i < head.length; i++) {
        payloadLen += head[segStart + i];
      }
      final payloadStart = segStart + segCount;
      if (payloadStart + payloadLen <= head.length) {
        final p = Uint8List.sublistView(head, payloadStart, payloadStart + payloadLen);
        if (p.length > 10 && _eq(p, 1, 'vorbis')) {
          // Vorbis identification header：
          // 0 包类型 / 1-6 'vorbis' / 7-10 版本 / 11 声道 / 12-15 采样率
          if (p.length >= 16) {
            sampleRate = _le32(p, 12);
          }
        } else if (p.length > 8 && _eq(p, 0, 'OpusHead')) {
          sampleRate = 48000; // Opus 恒为 48k
        }
      }
    }

    // 注释头在第二页；METADATA_BLOCK_PICTURE 也在注释里（base64）
    final comments = _oggComments(raf, len);
    for (final c in comments) {
      final kv = _splitComment(c);
      switch (kv.$1) {
        case 'TITLE':
          title = kv.$2;
        case 'ARTIST':
          artist = kv.$2;
        case 'ALBUM':
          album = kv.$2;
        case 'LYRICS':
          lyric = kv.$2;
        case 'METADATA_BLOCK_PICTURE':
          if (cover == null) {
            final pic = _decodeBase64Picture(kv.$2);
            if (pic != null) {
              cover = pic.$2;
              coverMime = pic.$1;
            }
          }
      }
    }

    // 时长：末页的 granulePosition / sampleRate
    var durationMs = 0;
    if (sampleRate > 0) {
      final granule = _lastOggGranule(tail);
      if (granule > 0) {
        durationMs = (granule * 1000) ~/ sampleRate;
      }
    }

    return AudioMetadata(
      title: title,
      artist: artist,
      album: album,
      lyric: lyric,
      format: 'ogg',
      coverMime: coverMime,
      durationMs: durationMs,
      sampleRate: sampleRate,
      coverBytes: cover,
    );
  }

  /// 读取 OGG 前几页，拼出注释头内容。
  static List<String> _oggComments(RandomAccessFile raf, int len) {
    try {
      var pos = 0;
      var pageIdx = 0;
      var payload = <int>[];
      // 注释头通常在第 2 页，多读几页以防中间夹了别的流
      while (pos < len && pageIdx < 6) {
        raf.setPositionSync(pos);
        final pageHead = raf.readSync(27);
        if (pageHead.length < 27 || !_eq(pageHead, 0, 'OggS')) break;
        final segCount = pageHead[26];
        final segTable = raf.readSync(segCount);
        var payloadLen = 0;
        for (final s in segTable) {
          payloadLen += s;
        }
        final body = raf.readSync(payloadLen);
        payload = body;
        if (pageIdx >= 1 && body.isNotEmpty) {
          // Vorbis 注释包以 0x03 + 'vorbis' 开头；Opus 以 'OpusTags' 开头
          if ((body[0] == 0x03 && _eq(body, 1, 'vorbis')) ||
              _eq(body, 0, 'OpusTags')) {
            final skip = body[0] == 0x03 ? 7 : 8;
            if (body.length > skip) {
              return _parseVorbisComment(
                  Uint8List.sublistView(body, skip, body.length));
            }
          }
        }
        pos += 27 + segCount + payloadLen;
        pageIdx++;
      }
      // 兜底：某些文件注释在首页之后的位置有偏移，再试一次直接解析最后读到的包
      if (payload.isNotEmpty) {
        final b = Uint8List.fromList(payload);
        if (b.length > 8 && _eq(b, 0, 'OpusTags')) {
          return _parseVorbisComment(
              Uint8List.sublistView(b, 8, b.length));
        }
      }
      return const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  /// 从尾部缓冲里找最后一页的 granulePosition。
  static int _lastOggGranule(Uint8List tail) {
    // 从后往前找 'OggS'
    for (var i = tail.length - 4; i >= 0; i--) {
      if (_eq(tail, i, 'OggS')) {
        if (i + 14 <= tail.length) {
          var g = 0;
          for (var k = 0; k < 8; k++) {
            g |= tail[i + 6 + k] << (8 * k);
          }
          return g;
        }
      }
    }
    return 0;
  }

  /// METADATA_BLOCK_PICTURE 是 base64 编码的 FLAC PICTURE 块。
  static (String, Uint8List)? _decodeBase64Picture(String b64) {
    try {
      final bytes = base64Decode(b64.replaceAll(RegExp(r'\s'), ''));
      return _decodeFlacPicture(Uint8List.fromList(bytes));
    } catch (_) {
      return null;
    }
  }

  // ==================== WAV ====================

  /// WAV 的 INFO 字段没有统一编码约定：老工具写本地代码页，ffmpeg 等写 UTF-8。
  ///
  /// 先用 UTF-8 严格解码（中文因此能正常显示），失败再退回 Latin-1。
  static String _decodeInfoValue(Uint8List bytes) {
    try {
      return _trimNul(utf8.decode(bytes));
    } catch (_) {
      return _trimNul(latin1.decode(bytes, allowInvalid: true));
    }
  }

  static AudioMetadata _readWav(Uint8List head, int len) {
    if (!_eq(head, 0, 'RIFF') || !_eq(head, 8, 'WAVE')) {
      return const AudioMetadata(format: 'wav');
    }

    var byteRate = 0;
    var dataSize = 0;
    var sampleRate = 0;
    String title = '', artist = '', album = '';

    var pos = 12;
    while (pos + 8 <= head.length) {
      final id = String.fromCharCodes(head.sublist(pos, pos + 4));
      final size = _le32(head, pos + 4);
      final payloadStart = pos + 8;
      if (size < 0 || payloadStart > head.length) break;

      if (id == 'fmt ' && payloadStart + 16 <= head.length) {
        // 标准 16 字节 PCM fmt：
        // 0-1 格式 / 2-3 声道 / 4-7 采样率 / 8-11 字节率 / 12-13 块对齐 / 14-15 位深
        sampleRate = _le32(head, payloadStart + 4);
        byteRate = _le32(head, payloadStart + 8);
      } else if (id == 'data') {
        dataSize = size;
      } else if (id == 'LIST' && payloadStart + 4 <= head.length) {
        // LIST/INFO 里的 INAM / IART / IPRD
        var p = payloadStart + 4;
        while (p + 8 <= payloadStart + size && p + 8 <= head.length) {
          final subId = String.fromCharCodes(head.sublist(p, p + 4));
          final subSize = _le32(head, p + 4);
          final vStart = p + 8;
          if (subSize < 0 || vStart + subSize > head.length) break;
          final v = _decodeInfoValue(
              Uint8List.sublistView(head, vStart, vStart + subSize));
          switch (subId) {
            case 'INAM':
              title = v;
            case 'IART':
              artist = v;
            case 'IPRD':
              album = v;
          }
          // LIST 内部按偶数字节对齐
          p = vStart + subSize + (subSize % 2);
        }
      }

      pos = payloadStart + size + (size % 2); // chunk 按偶数字节对齐
    }

    var durationMs = 0;
    if (byteRate > 0 && dataSize > 0) {
      durationMs = (dataSize * 1000) ~/ byteRate;
    }
    final bitrate = byteRate > 0 ? (byteRate * 8) ~/ 1000 : 0;

    return AudioMetadata(
      title: title,
      artist: artist,
      album: album,
      format: 'wav',
      durationMs: durationMs,
      bitrate: bitrate,
      sampleRate: sampleRate,
    );
  }

  // ==================== 盒（box）遍历 ====================

  static const Set<String> _containerBoxes = <String>{
    'moov', 'trak', 'mdia', 'minf', 'stbl', 'udta', 'edts',
  };

  static List<_Box> _parseBoxes(Uint8List d, int start, int end) {
    final out = <_Box>[];
    var pos = start;
    while (pos + 8 <= end) {
      var size = _be32(d, pos);
      final type = String.fromCharCodes(d.sublist(pos + 4, pos + 8));
      var header = 8;
      if (size == 1) {
        if (pos + 16 > end) break;
        var big = 0;
        for (var i = 0; i < 8; i++) {
          big = (big << 8) | d[pos + 8 + i];
        }
        size = big;
        header = 16;
      } else if (size == 0) {
        size = end - pos;
      }
      if (size < header || pos + size > end) break;
      out.add(_Box(start: pos, header: header, size: size, type: type));
      pos += size;
    }
    return out;
  }

  static _BoxRange _findBox(Uint8List buf, String type) =>
      _findBoxWithin(buf, 0, buf.length, type);

  /// 在范围内递归查找盒子，返回其 payload 区间；mvhd 额外解析 timescale/duration。
  static _BoxRange _findBoxWithin(Uint8List buf, int start, int end, String type) {
    for (final b in _parseBoxes(buf, start, end)) {
      if (b.type == type) {
        var timescale = 0;
        var duration = 0;
        if (type == 'mvhd') {
          final p = b.start + b.header;
          if (p + 4 <= b.end) {
            final version = buf[p];
            if (version == 1) {
              if (p + 32 <= b.end) {
                timescale = _be32(buf, p + 20);
                var d = 0;
                for (var i = 0; i < 8; i++) {
                  d = (d << 8) | buf[p + 24 + i];
                }
                duration = d;
              }
            } else if (p + 20 <= b.end) {
              timescale = _be32(buf, p + 12);
              duration = _be32(buf, p + 16);
            }
          }
        }
        return _BoxRange(true, b.start + b.header, b.end, timescale, duration);
      }
      if (_containerBoxes.contains(b.type)) {
        final r = _findBoxWithin(buf, b.start + b.header, b.end, type);
        if (r.exists) return r;
      }
    }
    return const _BoxRange.none();
  }

  // ==================== 文件名兜底 ====================

  /// 从「歌手 - 歌名.ext」这类文件名推断标题与艺术家。
  ///
  /// 只在文件没有内嵌标签时使用。
  static (String, String) parseFileName(String path) {
    // 同时兼容 `/` 与 `\`：本机扫描只会遇到当前平台的分隔符，
    // 但路径也可能来自历史数据或跨平台同步。
    final name = path.split(RegExp(r'[\\/]')).last;
    final base = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
    final trimmed = base.trim();
    if (trimmed.isEmpty) return (name, '');

    for (final sep in const [' - ', ' – ', ' — ']) {
      final idx = trimmed.indexOf(sep);
      if (idx > 0 && idx < trimmed.length - sep.length) {
        final left = trimmed.substring(0, idx).trim();
        final right = trimmed.substring(idx + sep.length).trim();
        if (left.isNotEmpty && right.isNotEmpty) {
          // 常见命名有两种：「歌手 - 歌名」与「歌名 - 歌手」，
          // 无法可靠区分，统一按前者（更主流）。
          return (right, left);
        }
      }
    }
    return (trimmed, '');
  }

  // ==================== 字节工具 ====================

  static Uint8List _readAt(RandomAccessFile raf, int pos, int len) {
    if (len <= 0) return Uint8List(0);
    raf.setPositionSync(pos);
    return raf.readSync(len);
  }

  static int _be32(Uint8List d, int off) {
    if (off + 4 > d.length) return 0;
    return (d[off] << 24) | (d[off + 1] << 16) | (d[off + 2] << 8) | d[off + 3];
  }

  static int _le32(Uint8List d, int off) {
    if (off + 4 > d.length) return 0;
    return d[off] | (d[off + 1] << 8) | (d[off + 2] << 16) | (d[off + 3] << 24);
  }

  static bool _eq(Uint8List d, int off, String s) {
    final e = utf8.encode(s);
    if (off < 0 || off + e.length > d.length) return false;
    for (var i = 0; i < e.length; i++) {
      if (d[off + i] != e[i]) return false;
    }
    return true;
  }

  static String _extOf(String path) {
    final name = path.split(Platform.pathSeparator).last.toLowerCase();
    final i = name.lastIndexOf('.');
    if (i < 0) return '';
    return name.substring(i + 1);
  }

  /// 去掉字符串尾部的 NUL（Latin-1 为 1 字节，UTF-16 为 2 字节）。
  static String _stripTerminator(String s, int termLen) {
    var out = s;
    while (out.isNotEmpty && out.codeUnitAt(out.length - 1) == 0) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  static String _trimNul(String s) => _stripTerminator(s, 1);

  /// 拆分 `KEY=value`，键统一大写。
  static (String, String) _splitComment(String c) {
    final i = c.indexOf('=');
    if (i <= 0) return ('', '');
    return (c.substring(0, i).toUpperCase(), c.substring(i + 1));
  }

  static String _mimeFromImageBytes(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (b.length >= 8 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return 'image/png';
    }
    return 'image/jpeg'; // 兜底：绝大多数内嵌封面是 JPEG
  }
}

/// 一个 ID3 帧（保留原始负载）。
class _Id3Frame {
  const _Id3Frame(this.id, this.data);

  final String id;
  final Uint8List data;
}

/// MP4 盒子。
class _Box {
  const _Box({
    required this.start,
    required this.header,
    required this.size,
    required this.type,
  });

  final int start;
  final int header;
  final int size;
  final String type;

  int get end => start + size;
}

/// 盒子 payload 区间（附带 mvhd 的 timescale / duration）。
class _BoxRange {
  const _BoxRange(this.exists, this.start, this.end,
      [this.timescale = 0, this.duration = 0]);

  const _BoxRange.none()
      : exists = false,
        start = 0,
        end = 0,
        timescale = 0,
        duration = 0;

  final bool exists;
  final int start;
  final int end;
  final int timescale;
  final int duration;
}
