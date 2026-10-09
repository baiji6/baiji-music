/// 音频元数据写入（纯 Dart，六端通用）。
///
/// 参考实现 Lyrico 的 `lyrico-audiotag` 走 JNI + TagLib
/// （`AudioTagWriter.savePropertyMap` / `savePictures`），
/// 但本工程是 Flutter 六端（含 HarmonyOS），引入 native 标签库会破坏
/// "纯 Dart + 单一代码库"的前提，因此这里用纯 Dart 直接操作容器：
///
/// | 容器 | 歌词标签 | 封面标签 |
/// |---|---|---|
/// | `.mp3` | ID3v2.3 `USLT` | ID3v2.3 `APIC` |
/// | `.flac` | Vorbis Comment `LYRICS` | 原生 `PICTURE` 元数据块 |
/// | `.m4a/.mp4` | `ilst` → `©lyr` | `ilst` → `covr` |
/// | `.ogg/.opus` | Vorbis Comment `LYRICS` | `METADATA_BLOCK_PICTURE` |
///
/// **安全策略**（写坏音频文件不可接受）：
/// 1. 永不原地修改——先写 `*.tagtmp` 临时文件，全部成功后才替换原文件；
/// 2. 只重写标签区，音频数据按块原样拷贝；
/// 3. 任何一步异常都直接放弃，**保留原文件不动**，只在返回值里说明原因；
/// 4. 未识别 / 不支持的容器返回 error，由调用方退回"外挂 .lrc / .jpg"。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 待嵌入的封面图。
class EmbeddedCover {
  const EmbeddedCover({required this.data, required this.mime});

  final Uint8List data;
  final String mime;
}

/// 元数据写入结果。
class TagWriteResult {
  const TagWriteResult({
    this.lyricsEmbedded = false,
    this.coverEmbedded = false,
    this.sidecars = const <String>[],
    this.error,
  });

  /// 歌词是否已写入文件内部标签。
  final bool lyricsEmbedded;

  /// 封面是否已写入文件内部标签。
  final bool coverEmbedded;

  /// 额外写出的外挂文件（.lrc / .jpg）。
  final List<String> sidecars;

  /// 失败原因；null 表示成功（含"部分成功"）。
  final String? error;

  bool get ok => error == null;
}

/// 音频标签写入入口。
class AudioTagger {
  AudioTagger._();

  /// 把歌词 / 封面写入音频文件内部标签。
  ///
  /// [lyrics] 为完整 LRC 文本（见 `LyricSerializer`）；为空则不写歌词。
  /// [cover] 为封面包；为空则不写封面。
  /// [title]/[artist]/[album] 可选，用于补齐基础标签。
  static Future<TagWriteResult> embed({
    required File file,
    String? lyrics,
    EmbeddedCover? cover,
    String? title,
    String? artist,
    String? album,
  }) async {
    final text = lyrics?.trim() ?? '';
    if (text.isEmpty && cover == null) return const TagWriteResult();
    if (!file.existsSync()) {
      return const TagWriteResult(error: '音频文件不存在');
    }

    final tags = <String, String>{
      if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
      if (artist != null && artist.trim().isNotEmpty) 'artist': artist.trim(),
      if (album != null && album.trim().isNotEmpty) 'album': album.trim(),
    };

    RandomAccessFile? raf;
    try {
      raf = file.openSync(mode: FileMode.read);
      final lower = file.path.toLowerCase();
      // 必须 await：finally 里会关闭 raf，不等待的话子流程会拿到已关闭的句柄。
      if (lower.endsWith('.mp3')) {
        return await _writeMp3(file, raf, text, cover, tags);
      }
      if (lower.endsWith('.flac')) {
        return await _writeFlac(file, raf, text, cover, tags);
      }
      if (lower.endsWith('.m4a') ||
          lower.endsWith('.mp4') ||
          lower.endsWith('.m4b') ||
          lower.endsWith('.m4p')) {
        return await _writeMp4(file, raf, text, cover, tags);
      }
      if (lower.endsWith('.ogg') ||
          lower.endsWith('.oga') ||
          lower.endsWith('.opus')) {
        return await _writeOgg(file, raf, text, cover, tags);
      }
      final ext = lower.contains('.') ? lower.split('.').last : lower;
      return TagWriteResult(error: '暂不支持写入 .$ext 的内部标签，已改用外挂文件');
    } catch (e) {
      return TagWriteResult(error: '写入元数据失败: $e');
    } finally {
      await _safeClose(raf);
    }
  }

  /// 由图片字节猜测 MIME，猜测失败时按 JPEG 处理（兼容性最好）。
  static String guessMime(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  // ==================== 通用写盘 ====================

  /// 把 [header] 写入临时文件，再把 [raf] 自 [audioStart] 起的音频数据按块拷入，
  /// 最后替换原文件。任一步失败原文件都保持不变。
  static Future<void> _rewrite(
    File file,
    RandomAccessFile raf,
    int audioStart,
    List<int> header,
  ) async {
    final tmp = File('${file.path}.tagtmp');
    RandomAccessFile? w;
    try {
      if (tmp.existsSync()) tmp.deleteSync();
      w = tmp.openSync(mode: FileMode.write);
      w.writeFromSync(header);

      raf.setPositionSync(audioStart);
      while (true) {
        final buf = raf.readSync(512 * 1024);
        if (buf.isEmpty) break;
        w.writeFromSync(buf);
      }
      await w.flush();
      await _safeClose(w);
      w = null;

      // 基本校验：新文件必须包含完整音频数据，否则宁可不替换
      if (tmp.lengthSync() <= header.length) {
        throw StateError('写入结果异常（未包含音频数据）');
      }
      if (file.existsSync()) file.deleteSync();
      await tmp.rename(file.path);
    } finally {
      if (w != null) await _safeClose(w);
    }
  }

  static Future<void> _safeClose(RandomAccessFile? f) async {
    if (f == null) return;
    try {
      await f.close();
    } catch (_) {
      // 关闭失败不影响主流程
    }
  }

  // ==================== 字节序辅助 ====================

  static void _addU8(BytesBuilder b, int v) => b.addByte(v & 0xFF);

  static void _addU16BE(BytesBuilder b, int v) {
    b.addByte((v >> 8) & 0xFF);
    b.addByte(v & 0xFF);
  }

  static void _addU32BE(BytesBuilder b, int v) {
    b.addByte((v >> 24) & 0xFF);
    b.addByte((v >> 16) & 0xFF);
    b.addByte((v >> 8) & 0xFF);
    b.addByte(v & 0xFF);
  }

  static void _addU32LE(BytesBuilder b, int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
    b.addByte((v >> 16) & 0xFF);
    b.addByte((v >> 24) & 0xFF);
  }

  static int _readU32BE(Uint8List d, int off) =>
      (d[off] << 24) | (d[off + 1] << 16) | (d[off + 2] << 8) | d[off + 3];

  static void _writeU32BE(Uint8List d, int off, int v) {
    d[off] = (v >> 24) & 0xFF;
    d[off + 1] = (v >> 16) & 0xFF;
    d[off + 2] = (v >> 8) & 0xFF;
    d[off + 3] = v & 0xFF;
  }

  /// ID3 同步安全整数：4 字节、每字节只用低 7 位。
  static void _addSyncsafe(BytesBuilder b, int v) {
    b.addByte((v >> 21) & 0x7F);
    b.addByte((v >> 14) & 0x7F);
    b.addByte((v >> 7) & 0x7F);
    b.addByte(v & 0x7F);
  }

  static int _le32(List<int> d, int off) =>
      d[off] | (d[off + 1] << 8) | (d[off + 2] << 16) | (d[off + 3] << 24);

  static bool _eq(List<int> d, int off, String s) {
    final e = utf8.encode(s);
    if (off + e.length > d.length) return false;
    for (var i = 0; i < e.length; i++) {
      if (d[off + i] != e[i]) return false;
    }
    return true;
  }

  // ==================== MP3 / ID3v2.3 ====================

  /// 一个 ID3 帧（保留原始负载，不解释内容）。

  static Future<TagWriteResult> _writeMp3(
    File file,
    RandomAccessFile raf,
    String lyrics,
    EmbeddedCover? cover,
    Map<String, String> tags,
  ) async {
    final head = raf.readSync(10);
    var audioStart = 0;
    var major = 3;
    final preserved = <_Id3Frame>[];

    final isId3 = head.length >= 10 &&
        head[0] == 0x49 &&
        head[1] == 0x44 &&
        head[2] == 0x33; // 'ID3'

    if (isId3) {
      major = head[3];
      final syncsafe = ((head[6] & 0x7F) << 21) |
          ((head[7] & 0x7F) << 14) |
          ((head[8] & 0x7F) << 7) |
          (head[9] & 0x7F);
      final footer = (head[5] & 0x10) != 0; // v2.4 footer present
      final total = 10 + syncsafe + (footer ? 10 : 0);
      if (syncsafe > 0 && syncsafe < 64 * 1024 * 1024 && total <= raf.lengthSync()) {
        audioStart = total;
        raf.setPositionSync(10);
        final body = raf.readSync(syncsafe);
        final unsynced = major <= 3 && (head[5] & 0x80) != 0;
        preserved.addAll(_parseId3Frames(body, major, unsynced));
      }
    }

    // 只去掉我们要重写的帧，其余（TXXX / PRIV / COMM 等）原样保留
    const drop = <String>{'USLT', 'APIC', 'TIT2', 'TPE1', 'TALB'};
    final frames = <_Id3Frame>[
      for (final f in preserved)
        if (!drop.contains(f.id)) f,
    ];

    await _rewrite(
      file,
      raf,
      audioStart,
      _buildId3(frames, lyrics: lyrics, cover: cover, tags: tags),
    );
    return TagWriteResult(
      lyricsEmbedded: lyrics.isNotEmpty,
      coverEmbedded: cover != null,
    );
  }

  static List<_Id3Frame> _parseId3Frames(
      Uint8List body, int major, bool unsynced) {
    final out = <_Id3Frame>[];
    // ID3v2.2 是 3 字节帧 ID + 6 字节头，格式差异大；
    // 与其冒险误解析，不如丢弃旧标签、按现有元数据重建。
    if (major < 3) return out;

    final syncsafe = major >= 4;
    var pos = 0;
    while (pos + 10 <= body.length) {
      final id = String.fromCharCodes(body.sublist(pos, pos + 4));
      // 进入 padding 区（全 0 或非法字符）即结束
      if (!RegExp(r'^[A-Z0-9]{4}$').hasMatch(id)) break;

      final size = syncsafe
          ? (((body[pos + 4] & 0x7F) << 21) |
              ((body[pos + 5] & 0x7F) << 14) |
              ((body[pos + 6] & 0x7F) << 7) |
              (body[pos + 7] & 0x7F))
          : _readU32BE(body, pos + 4);
      final flags2 = body[pos + 9];

      // 压缩 / 加密 / 分组的帧无法安全透传，停止解析
      final badV3 = major == 3 && (flags2 & 0xE0) != 0;
      final badV4 = major >= 4 && (flags2 & 0x4C) != 0;
      if (badV3 || badV4) break;
      if (size <= 0 || pos + 10 + size > body.length) break;

      var dataStart = pos + 10;
      // ID3v2.4 的 data length indicator（可选 4 字节同步安全整数）
      if (major >= 4 && (flags2 & 0x01) != 0) dataStart += 4;
      if (dataStart >= pos + 10 + size) break;

      var data = Uint8List.sublistView(body, dataStart, pos + 10 + size);
      // 旧标签若整体做过反同步，需还原成原始字节，再按"无反同步"写回
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

  /// 组装完整 ID3v2.3 标签（头 + 帧 + padding）。
  ///
  /// 写 v2.3 而非 v2.4：帧大小非同步安全、Windows 资源管理器与
  /// 绝大多数车载 / 播放器识别度最好。
  static Uint8List _buildId3(
    List<_Id3Frame> preserved, {
    required String lyrics,
    required EmbeddedCover? cover,
    required Map<String, String> tags,
  }) {
    final frames = <_Id3Frame>[...preserved];
    if (lyrics.isNotEmpty) {
      frames.add(_Id3Frame('USLT', _usltPayload(lyrics)));
    }
    if (cover != null) {
      frames.add(_Id3Frame('APIC', _apicPayload(cover)));
    }
    final title = tags['title'];
    final artist = tags['artist'];
    final album = tags['album'];
    if (title != null && title.isNotEmpty) {
      frames.add(_Id3Frame('TIT2', _textPayload(title)));
    }
    if (artist != null && artist.isNotEmpty) {
      frames.add(_Id3Frame('TPE1', _textPayload(artist)));
    }
    if (album != null && album.isNotEmpty) {
      frames.add(_Id3Frame('TALB', _textPayload(album)));
    }

    final body = BytesBuilder(copy: false);
    for (final f in frames) {
      body.add(ascii.encode(f.id));
      _addU32BE(body, f.data.length);
      _addU16BE(body, 0); // flags
      body.add(f.data);
    }
    final bodyBytes = body.takeBytes();

    // 预留 padding：将来再编辑时若变小可原地复用，不必整体重写文件
    const padding = 2048;
    final out = BytesBuilder(copy: false);
    out.add(ascii.encode('ID3'));
    out.addByte(3); // major = 3
    out.addByte(0); // minor = 0
    out.addByte(0); // flags：无 unsync / extended header / experimental
    _addSyncsafe(out, bodyBytes.length + padding);
    out.add(bodyBytes);
    out.add(Uint8List(padding));
    return out.takeBytes();
  }

  /// `USLT`：编码(1) + 语言(3) + 描述符(以 \0 结尾) + 正文。
  static Uint8List _usltPayload(String text) {
    final b = BytesBuilder(copy: false);
    _addU8(b, 0x03); // UTF-8
    b.add(ascii.encode('chi'));
    b.addByte(0x00); // 空描述符
    b.add(utf8.encode(text));
    return b.takeBytes();
  }

  /// 文本帧：编码(1) + UTF-8 正文。
  static Uint8List _textPayload(String value) {
    final b = BytesBuilder(copy: false);
    _addU8(b, 0x03); // UTF-8
    b.add(utf8.encode(value));
    return b.takeBytes();
  }

  /// `APIC`：编码(1) + MIME(\0 结尾) + 图片类型(1) + 描述(\0 结尾) + 图片数据。
  static Uint8List _apicPayload(EmbeddedCover cover) {
    final b = BytesBuilder(copy: false);
    _addU8(b, 0x03); // UTF-8
    b.add(ascii.encode(cover.mime));
    b.addByte(0x00);
    b.addByte(0x03); // 0x03 = 封面（front cover）
    b.addByte(0x00); // 空描述
    b.add(cover.data);
    return b.takeBytes();
  }

  // ==================== FLAC ====================

  static Future<TagWriteResult> _writeFlac(
    File file,
    RandomAccessFile raf,
    String lyrics,
    EmbeddedCover? cover,
    Map<String, String> tags,
  ) async {
    final magic = raf.readSync(4);
    if (magic.length < 4 ||
        magic[0] != 0x66 ||
        magic[1] != 0x4C ||
        magic[2] != 0x61 ||
        magic[3] != 0x43) {
      return const TagWriteResult(error: '不是有效的 FLAC 文件');
    }

    final blocks = <_FlacBlock>[];
    var last = false;
    while (!last) {
      final h = raf.readSync(4);
      if (h.length < 4) return const TagWriteResult(error: 'FLAC 元数据块头损坏');
      last = (h[0] & 0x80) != 0;
      final type = h[0] & 0x7F;
      final len = (h[1] << 16) | (h[2] << 8) | h[3];
      final data = len > 0 ? raf.readSync(len) : Uint8List(0);
      if (data.length < len) {
        return const TagWriteResult(error: 'FLAC 元数据块数据不完整');
      }
      blocks.add(_FlacBlock(type, data));
    }
    final audioStart = raf.positionSync();

    // 合并已有 Vorbis Comment：保留未知键，去掉我们要重写的键
    var vendor = 'baiji-music';
    final kept = <String>[];
    for (final b in blocks) {
      if (b.type != 4) continue; // 4 = VORBIS_COMMENT
      for (final c in _parseVorbisComment(b.data, (v) => vendor = v)) {
        final key = c.split('=').first.trim().toLowerCase();
      if (key == 'lyrics' || key == 'unsyncedlyrics') continue;
      if (tags.containsKey(key)) continue; // 由本次写入覆盖
      kept.add(c);
      }
    }
    if (lyrics.isNotEmpty) kept.add('LYRICS=$lyrics');
    for (final e in tags.entries) {
      kept.add('${e.key.toUpperCase()}=${e.value}');
    }

    final newBlocks = <_FlacBlock>[
      // STREAMINFO 必须第一个，原样透传
      for (final b in blocks)
        if (b.type == 0) b,
      _FlacBlock(4, _buildVorbisComment(vendor, kept)),
      if (cover != null) _FlacBlock(6, _buildPictureBlock(cover)),
      // 其余块原样透传（跳过旧的注释 / 图片 / padding）
      for (final b in blocks)
        if (b.type != 0 && b.type != 4 && b.type != 6 && b.type != 1) b,
    ];

    await _rewrite(file, raf, audioStart, _buildFlacStream(newBlocks));
    return TagWriteResult(
      lyricsEmbedded: lyrics.isNotEmpty,
      coverEmbedded: cover != null,
    );
  }

  static Uint8List _buildFlacStream(List<_FlacBlock> blocks) {
    final out = BytesBuilder(copy: false);
    out.add(ascii.encode('fLaC'));
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final flag = i == blocks.length - 1 ? 0x80 : 0x00;
      out.addByte(flag | (b.type & 0x7F));
      final len = b.data.length;
      out.addByte((len >> 16) & 0xFF);
      out.addByte((len >> 8) & 0xFF);
      out.addByte(len & 0xFF);
      out.add(b.data);
    }
    return out.takeBytes();
  }

  /// FLAC `PICTURE` / OGG `METADATA_BLOCK_PICTURE` 共用体。
  static Uint8List _buildPictureBlock(EmbeddedCover cover) {
    final b = BytesBuilder(copy: false);
    _addU32BE(b, 3); // 3 = Front cover
    final mime = ascii.encode(cover.mime);
    _addU32BE(b, mime.length);
    b.add(mime);
    _addU32BE(b, 0); // 空描述
    _addU32BE(b, 0); // width（未知）
    _addU32BE(b, 0); // height
    _addU32BE(b, 0); // 色深
    _addU32BE(b, 0); // 调色板颜色数
    _addU32BE(b, cover.data.length);
    b.add(cover.data);
    return b.takeBytes();
  }

  // ==================== Vorbis Comment ====================

  /// 解析 Vorbis Comment：`vendorLen(LE32) + vendor + count(LE32) + [...]`
  static List<String> _parseVorbisComment(
      Uint8List d, void Function(String vendor) onVendor) {
    final out = <String>[];
    if (d.length < 8) return out;
    var pos = 0;

    int le32() {
      if (pos + 4 > d.length) return 0;
      final v =
          d[pos] | (d[pos + 1] << 8) | (d[pos + 2] << 16) | (d[pos + 3] << 24);
      pos += 4;
      return v;
    }

    final vendorLen = le32();
    if (vendorLen >= 0 && pos + vendorLen <= d.length) {
      onVendor(utf8.decode(d.sublist(pos, pos + vendorLen),
          allowMalformed: true));
      pos += vendorLen;
    }
    final count = le32();
    for (var i = 0; i < count && pos + 4 <= d.length; i++) {
      final len = le32();
      if (len < 0 || pos + len > d.length) break;
      out.add(utf8.decode(d.sublist(pos, pos + len), allowMalformed: true));
      pos += len;
    }
    return out;
  }

  static Uint8List _buildVorbisComment(
      String vendor, List<String> comments) {
    final v = utf8.encode(vendor);
    final b = BytesBuilder(copy: false);
    _addU32LE(b, v.length);
    b.add(v);
    _addU32LE(b, comments.length);
    for (final c in comments) {
      final e = utf8.encode(c);
      _addU32LE(b, e.length);
      b.add(e);
    }
    return b.takeBytes();
  }

  // ==================== MP4 / M4A ====================

  /// 需要递归下钻的容器盒。
  static const Set<String> _containerBoxes = <String>{
    'moov', 'trak', 'mdia', 'minf', 'stbl', 'udta', 'edts',
  };

  static List<_Box> _parseBoxes(Uint8List d, int start, int end) {
    final out = <_Box>[];
    var pos = start;
    while (pos + 8 <= end) {
      var size = _readU32BE(d, pos);
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
        // size == 0 表示延伸到文件末尾
        size = end - pos;
      }
      if (size < header || pos + size > end) break;
      out.add(_Box(start: pos, header: header, size: size, type: type));
      pos += size;
    }
    return out;
  }

  /// 递归收集 `stco` / `co64` 盒子（记录相对 [base] 的偏移）。
  static void _collectChunkTables(
      Uint8List buf, int from, int to, int base, List<_Box> out) {
    for (final b in _parseBoxes(buf, from, to)) {
      if (b.type == 'stco' || b.type == 'co64') {
        out.add(_Box(
          start: b.start + base,
          header: b.header,
          size: b.size,
          type: b.type,
        ));
        continue;
      }
      if (_containerBoxes.contains(b.type)) {
        // full box（meta）前 4 字节是 version/flags，需跳过
        final skip = b.type == 'meta' ? 4 : 0;
        _collectChunkTables(buf, b.payloadStart + skip, b.payloadEnd,
            base, out);
      }
    }
  }

  static Future<TagWriteResult> _writeMp4(
    File file,
    RandomAccessFile raf,
    String lyrics,
    EmbeddedCover? cover,
    Map<String, String> tags,
  ) async {
    final len = raf.lengthSync();
    final roots = <_Box>[];
    var pos = 0;
    while (pos + 8 <= len) {
      raf.setPositionSync(pos);
      final head = raf.readSync(8);
      var size = _readU32BE(head, 0);
      final type = String.fromCharCodes(head.sublist(4, 8));
      var header = 8;
      if (size == 1) {
        final ext = raf.readSync(8);
        var big = 0;
        for (var i = 0; i < 8; i++) {
          big = (big << 8) | ext[i];
        }
        size = big;
        header = 16;
      } else if (size == 0) {
        size = len - pos;
      }
      if (size < header || pos + size > len) break;
      roots.add(_Box(start: pos, header: header, size: size, type: type));
      pos += size;
    }

    _Box? moov;
    for (final b in roots) {
      if (b.type == 'moov') {
        moov = b;
        break;
      }
    }
    if (moov == null) {
      return const TagWriteResult(error: 'MP4 文件缺少 moov 盒子，无法写入标签');
    }

    raf.setPositionSync(moov.start);
    final moovBytes = raf.readSync(moov.size);

    // 定位 udta → meta → ilst，并保留 udta / meta 的其它子盒
    final keptUdta = <Uint8List>[];
    final keptMeta = <Uint8List>[];
    final keptIlst = <Uint8List>[];
    final topBoxes = _parseBoxes(moovBytes, moov.header, moov.size);
    for (final b in topBoxes) {
      if (b.type != 'udta') continue;
      for (final c in _parseBoxes(moovBytes, b.payloadStart, b.payloadEnd)) {
        if (c.type == 'meta') {
          final inner =
              _parseBoxes(moovBytes, c.payloadStart + 4, c.payloadEnd);
          for (final d in inner) {
            if (d.type == 'ilst') {
              for (final e
                  in _parseBoxes(moovBytes, d.payloadStart, d.payloadEnd)) {
                if (e.type == '©lyr' || e.type == 'covr') continue;
                if (e.type == '©nam' && tags.containsKey('title')) continue;
                if (e.type == '©ART' && tags.containsKey('artist')) continue;
                if (e.type == '©alb' && tags.containsKey('album')) continue;
                keptIlst.add(
                    Uint8List.sublistView(moovBytes, e.start, e.payloadEnd));
              }
            } else {
              keptMeta.add(
                  Uint8List.sublistView(moovBytes, c.start, c.payloadEnd));
            }
          }
        } else {
          keptUdta
              .add(Uint8List.sublistView(moovBytes, b.start, b.payloadEnd));
        }
      }
    }

    if (lyrics.isNotEmpty) keptIlst.add(_ilstText('©lyr', lyrics));
    if (cover != null) keptIlst.add(_ilstCover(cover));
    final t = tags['title'];
    final a = tags['artist'];
    final al = tags['album'];
    if (t != null && t.isNotEmpty) keptIlst.add(_ilstText('©nam', t));
    if (a != null && a.isNotEmpty) keptIlst.add(_ilstText('©ART', a));
    if (al != null && al.isNotEmpty) keptIlst.add(_ilstText('©alb', al));

    final ilstBytes = _box('ilst', keptIlst);
    final metaBytes = _fullBox(
      'meta',
      0,
      <Uint8List>[_hdlrMdir(), ilstBytes],
    );
    final udtaBytes = _box('udta', <Uint8List>[...keptUdta, metaBytes]);

    // 重建 moov：去掉旧 udta，末尾追加新 udta（保证 trak 等在前面位置不变）
    final kept = <Uint8List>[
      for (final b in topBoxes)
        if (b.type != 'udta')
          Uint8List.sublistView(moovBytes, b.start, b.payloadEnd),
      udtaBytes,
    ];
    final newMoov = _box('moov', kept);
    final delta = newMoov.length - moovBytes.length;

    // moov 变长会让其后的 mdat 整体后移，必须修正 stco / co64 中的绝对偏移。
    //
    // 关键：chunk 表要在**重建后的 moovBytes** 上重新解析。
    // 旧 udta 被摘掉、新 udta 追加到末尾后，moov 内部盒子的相对位置会变，
    // 沿用旧的 relStart 会改到错误的字节上。
    if (delta != 0) {
      final chunkTables = <_Box>[];
      _collectChunkTables(newMoov, 8, newMoov.length, 0, chunkTables);
      // 判据只有一条：偏移落在旧 moov 之后的数据（mdat 等）才需要整体后移。
      final moovEndInFile = moov.payloadEnd;
      for (final t in chunkTables) {
        final relStart = t.payloadStart; // 相对 newMoov
        if (relStart + 8 > newMoov.length) continue;
        final count = _readU32BE(newMoov, relStart + 4);
        final wide = t.type == 'co64';
        final entrySize = wide ? 8 : 4;
        if (count <= 0 || relStart + 8 + count * entrySize > newMoov.length) {
          continue;
        }
        for (var i = 0; i < count; i++) {
          final off = relStart + 8 + i * entrySize;
          if (wide) {
            var v = 0;
            for (var k = 0; k < 8; k++) {
              v = (v << 8) | newMoov[off + k];
            }
            if (v >= moovEndInFile) {
              v += delta;
              for (var k = 0; k < 8; k++) {
                newMoov[off + k] = (v >> (56 - 8 * k)) & 0xFF;
              }
            }
          } else {
            final v0 = _readU32BE(newMoov, off);
            if (v0 >= moovEndInFile) _writeU32BE(newMoov, off, v0 + delta);
          }
        }
      }
    }

    final tmp = File('${file.path}.tagtmp');
    RandomAccessFile? w;
    try {
      if (tmp.existsSync()) tmp.deleteSync();
      w = tmp.openSync(mode: FileMode.write);
      for (final b in roots) {
        if (b.type == 'moov') {
          w.writeFromSync(newMoov);
          continue;
        }
        raf.setPositionSync(b.start);
        var remain = b.size;
        while (remain > 0) {
          final n = remain > 512 * 1024 ? 512 * 1024 : remain;
          final buf = raf.readSync(n);
          if (buf.isEmpty) break;
          w.writeFromSync(buf);
          remain -= buf.length;
        }
      }
      await w.flush();
      await _safeClose(w);
      w = null;
      if (file.existsSync()) file.deleteSync();
      await tmp.rename(file.path);
    } finally {
      if (w != null) await _safeClose(w);
    }

    return TagWriteResult(
      lyricsEmbedded: lyrics.isNotEmpty,
      coverEmbedded: cover != null,
    );
  }

  /// `ilst` 文本条目（`©nam` / `©ART` / `©alb` / `©lyr`）。
  static Uint8List _ilstText(String type, String value) {
    final data = BytesBuilder(copy: false);
    _addU32BE(data, 1); // type indicator = 1 → UTF-8
    _addU32BE(data, 0); // locale
    data.add(utf8.encode(value));
    return _box(type, <Uint8List>[_rawBox(utf8.encode('data'), data.takeBytes())]);
  }

  /// `ilst` 封面条目（`covr`）。
  static Uint8List _ilstCover(EmbeddedCover cover) {
    final indicator = cover.mime == 'image/png' ? 14 : 13; // 13=JPEG, 14=PNG
    final data = BytesBuilder(copy: false);
    _addU32BE(data, indicator);
    _addU32BE(data, 0);
    data.add(cover.data);
    return _box('covr', <Uint8List>[_rawBox(utf8.encode('data'), data.takeBytes())]);
  }

  /// `hdlr` 盒子（handler_type = 'mdir'，iTunes metadata 必需）。
  static Uint8List _hdlrMdir() {
    final b = BytesBuilder(copy: false);
    _addU32BE(b, 0); // version + flags
    _addU32BE(b, 0); // pre_defined
    b.add(utf8.encode('mdir'));
    b.add(Uint8List(12)); // reserved
    b.addByte(0x00); // 空名称
    return _rawBox(utf8.encode('hdlr'), b.takeBytes());
  }

  static Uint8List _box(String type, List<Uint8List> children) {
    final payload = BytesBuilder(copy: false);
    for (final c in children) {
      payload.add(c);
    }
    return _rawBox(_typeBytes(type), payload.takeBytes());
  }

  /// 带 version + flags 前缀的 box（`meta` / `hdlr` 等 FullBox）。
  static Uint8List _fullBox(
      String type, int versionAndFlags, List<Uint8List> children) {
    final payload = BytesBuilder(copy: false);
    _addU32BE(payload, versionAndFlags);
    for (final c in children) {
      payload.add(c);
    }
    return _rawBox(_typeBytes(type), payload.takeBytes());
  }

  /// MP4 原子类型固定 4 字节，且必须用 Latin-1 编码：
  /// `©lyr` / `©nam` / `©ART` / `©alb` 里的 © 在 Latin-1 中是单字节 0xA9，
  /// 用 UTF-8 会编码成 2 字节（C2 A9），写进文件后类型串被截断成 "©ly"。
  static Uint8List _typeBytes(String type) {
    final raw = latin1.encode(type);
    if (raw.length >= 4) return Uint8List.fromList(raw.sublist(0, 4));
    final out = Uint8List(4);
    out.setRange(0, raw.length, raw);
    return out;
  }

  /// 组装一个 box：size(4) + type(4) + payload。
  static Uint8List _rawBox(List<int> type, Uint8List payload) {
    final b = BytesBuilder(copy: false);
    _addU32BE(b, 8 + payload.length);
    b.add(type.length >= 4 ? type.sublist(0, 4) : type);
    b.add(payload);
    return b.takeBytes();
  }

  // ==================== OGG（Vorbis / Opus） ====================

  /// 读取一页 Ogg；到 EOF 或格式异常返回 null。
  static _OggPage? _readOggPage(RandomAccessFile raf) {
    final start = raf.positionSync();
    final head = raf.readSync(27);
    if (head.length < 27) return null;
    if (!(head[0] == 0x4F &&
        head[1] == 0x67 &&
        head[2] == 0x67 &&
        head[3] == 0x53)) {
      return null; // 'OggS'
    }
    final headerType = head[5] & 0xFF;
    final granule = head.sublist(6, 14);
    final serial = head.sublist(14, 18);
    final seq = head[18] |
        (head[19] << 8) |
        (head[20] << 16) |
        (head[21] << 24);
    final segCount = head[26] & 0xFF;
    final segTable = raf.readSync(segCount);
    if (segTable.length < segCount) return null;
    var payloadLen = 0;
    for (final s in segTable) {
      payloadLen += s;
    }
    final payload =
        payloadLen > 0 ? raf.readSync(payloadLen) : Uint8List(0);
    if (payload.length < payloadLen) return null;
    return _OggPage(
      start: start,
      rawLength: 27 + segCount + payloadLen,
      headerType: headerType,
      granule: granule,
      serial: serial,
      seq: seq,
      payload: payload,
    );
  }

  static Future<TagWriteResult> _writeOgg(
    File file,
    RandomAccessFile raf,
    String lyrics,
    EmbeddedCover? cover,
    Map<String, String> tags,
  ) async {
    final p1 = _readOggPage(raf);
    if (p1 == null) return const TagWriteResult(error: '不是有效的 OGG 文件');
    final p2 = _readOggPage(raf);
    if (p2 == null) return const TagWriteResult(error: 'OGG 缺少注释头');

    // 注释包：Vorbis = 0x03 'vorbis'；Opus = 'OpusTags'
    final pl = p2.payload;
    int headLen;
    if (pl.length >= 7 && pl[0] == 0x03 && _eq(pl, 1, 'vorbis')) {
      headLen = 7;
    } else if (pl.length >= 8 && _eq(pl, 0, 'OpusTags')) {
      headLen = 8;
    } else {
      return const TagWriteResult(error: '无法识别的 OGG 注释头');
    }

    var pos = headLen;
    if (pos + 8 > pl.length) {
      return const TagWriteResult(error: 'OGG 注释头损坏');
    }
    final vLen = _le32(pl, pos);
    pos += 4;
    var vendor = 'baiji-music';
    if (vLen > 0 && pos + vLen <= pl.length) {
      vendor = utf8.decode(pl.sublist(pos, pos + vLen), allowMalformed: true);
      pos += vLen;
    }
    final count = _le32(pl, pos);
    pos += 4;

    final kept = <String>[];
    for (var i = 0; i < count && pos + 4 <= pl.length; i++) {
      final len = _le32(pl, pos);
      pos += 4;
      if (len < 0 || pos + len > pl.length) break;
      final c = utf8.decode(pl.sublist(pos, pos + len), allowMalformed: true);
      pos += len;
      final key = c.split('=').first.trim().toLowerCase();
      if (key == 'lyrics' || key == 'unsyncedlyrics') continue;
      if (tags.containsKey(key)) continue; // 由本次写入覆盖
      kept.add(c);
    }
    if (lyrics.isNotEmpty) kept.add('LYRICS=$lyrics');
    for (final e in tags.entries) {
      kept.add('${e.key.toUpperCase()}=${e.value}');
    }
    if (cover != null) {
      kept.add('METADATA_BLOCK_PICTURE=${base64.encode(_buildPictureBlock(cover))}');
    }

    final packet = BytesBuilder(copy: false);
    if (pl.length >= 8 && _eq(pl, 0, 'OpusTags')) {
      packet.add(utf8.encode('OpusTags'));
    } else {
      packet.addByte(0x03);
      packet.add(utf8.encode('vorbis'));
    }
    final vend = utf8.encode(vendor);
    _addU32LE(packet, vend.length);
    packet.add(vend);
    _addU32LE(packet, kept.length);
    for (final c in kept) {
      final e = utf8.encode(c);
      _addU32LE(packet, e.length);
      packet.add(e);
    }

    final page = _buildOggPage(
      headerType: p2.headerType,
      granule: p2.granule,
      serial: p2.serial,
      seq: p2.seq,
      packet: packet.takeBytes(),
    );

    final tmp = File('${file.path}.tagtmp');
    RandomAccessFile? w;
    try {
      if (tmp.existsSync()) tmp.deleteSync();
      w = tmp.openSync(mode: FileMode.write);
      // 第 1 页原样写回
      raf.setPositionSync(p1.start);
      w.writeFromSync(raf.readSync(p1.rawLength));
      // 第 2 页用新注释替换
      w.writeFromSync(page);
      // 其余内容按块拷贝
      raf.setPositionSync(p2.start + p2.rawLength);
      while (true) {
        final buf = raf.readSync(512 * 1024);
        if (buf.isEmpty) break;
        w.writeFromSync(buf);
      }
      await w.flush();
      await _safeClose(w);
      w = null;
      if (file.existsSync()) file.deleteSync();
      await tmp.rename(file.path);
    } finally {
      if (w != null) await _safeClose(w);
    }

    return TagWriteResult(
      lyricsEmbedded: lyrics.isNotEmpty,
      coverEmbedded: cover != null,
    );
  }

  /// 组装 OGG 页（含 CRC32 与 255 字节分段表）。
  static Uint8List _buildOggPage({
    required int headerType,
    required List<int> granule,
    required List<int> serial,
    required int seq,
    required Uint8List packet,
  }) {
    // 分段表：若干满 255 的段 + 一个结尾段（余数，可为 0）
    final segs = <int>[];
    var remain = packet.length;
    while (remain >= 255) {
      segs.add(255);
      remain -= 255;
    }
    segs.add(remain);

    final b = BytesBuilder(copy: false);
    b.add(utf8.encode('OggS'));
    b.addByte(0); // version
    b.addByte(headerType & 0xFF);
    b.add(granule);
    b.add(serial);
    for (var i = 0; i < 4; i++) {
      b.addByte((seq >> (8 * i)) & 0xFF);
    }
    b.add(const <int>[0, 0, 0, 0]); // CRC 占位
    b.addByte(segs.length & 0xFF);
    b.add(segs);
    b.add(packet);

    final bytes = b.takeBytes();
    final crc = _oggCrc32(bytes);
    for (var i = 0; i < 4; i++) {
      bytes[22 + i] = (crc >> (8 * i)) & 0xFF;
    }
    return bytes;
  }

  static final List<int> _crcTable = _makeCrcTable();

  static List<int> _makeCrcTable() {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var r = i << 24;
      for (var j = 0; j < 8; j++) {
        if ((r & 0x80000000) != 0) {
          r = ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF;
        } else {
          r = (r << 1) & 0xFFFFFFFF;
      }
      }
      table[i] = r;
    }
    return table;
  }

  /// Ogg 使用的 CRC-32：poly 0x04C11DB7，初值 0，无反射、无末异或。
  static int _oggCrc32(Uint8List data) {
    var crc = 0;
    for (var i = 0; i < data.length; i++) {
      final idx = (((crc >> 24) & 0xFF) ^ data[i]) & 0xFF;
      crc = (((crc << 8) & 0xFFFFFFFF) ^ _crcTable[idx]) & 0xFFFFFFFF;
    }
    return crc & 0xFFFFFFFF;
  }
}

class _Id3Frame {
  const _Id3Frame(this.id, this.data);

  final String id;
  final Uint8List data;
}

class _FlacBlock {
  const _FlacBlock(this.type, this.data);

  final int type;
  final Uint8List data;
}

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

  int get payloadStart => start + header;
  int get payloadEnd => start + size;
}

class _OggPage {
  const _OggPage({
    required this.start,
    required this.rawLength,
    required this.headerType,
    required this.granule,
    required this.serial,
    required this.seq,
    required this.payload,
  });

  final int start;
  final int rawLength;
  final int headerType;
  final List<int> granule;
  final List<int> serial;
  final int seq;
  final Uint8List payload;
}
