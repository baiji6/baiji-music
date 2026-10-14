import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../core/app_logger.dart';
import '../core/cover_url.dart';
import '../core/kv_store.dart';
import '../lyrics/lyric_model.dart';
import '../lyrics/lyric_serializer.dart';
import '../metadata/audio_tagger.dart';
import '../models/models.dart';
import '../network/lyric_api.dart';

/// 下载歌曲时「歌词」的处理方式。
enum LyricDownloadMode {
  /// 不下载歌词。
  off,

  /// 逐行歌词：标准 LRC（`[mm:ss.xx]文本`），所有播放器通吃。
  line,

  /// 逐字歌词：增强 LRC（行首时间 + 行内每字时间），支持卡拉 OK 染色。
  ///
  /// **自动回退**：歌曲没有逐字时间轴时（[Lyrics.hasWordTiming] 为 false），
  /// 实际落盘的是逐行 LRC——见 [DownloadExtras.resolveLyricMode]。
  /// 用户侧的表述即「默认逐字，没有逐字就逐行」。
  word,
}

extension LyricDownloadModeX on LyricDownloadMode {
  String get label => switch (this) {
        LyricDownloadMode.off => '不下载',
        LyricDownloadMode.line => '逐行歌词',
        LyricDownloadMode.word => '逐字歌词',
      };

  String get description => switch (this) {
        LyricDownloadMode.off => '只保存音频文件',
        LyricDownloadMode.line => 'LRC 时间轴，兼容性最好',
        LyricDownloadMode.word => '保留每个字的演唱时间；无逐字数据时自动存为逐行',
      };
}

/// 下载附加项设置：是否连歌词 / 封面一起保存，并写入音频文件元数据。
///
/// 写入位置（对应 Lyrico `lyrico-audiotag` 的 savePropertyMap / savePictures）：
/// - MP3 → ID3v2.3 `USLT` / `APIC`
/// - FLAC → Vorbis Comment `LYRICS` / 原生 `PICTURE` 块
/// - M4A/MP4 → `ilst` 的 `©lyr` / `covr`
/// - OGG/Opus → Vorbis Comment `LYRICS` / `METADATA_BLOCK_PICTURE`
class DownloadExtras {
  DownloadExtras._();

  static const String _prefs = 'download_extras';
  static const String _kLyric = 'lyric_mode';
  static const String _kCover = 'save_cover';

  static LyricDownloadMode get lyricMode {
    final raw = KvStore.instance.getString('$_prefs:$_kLyric');
    for (final m in LyricDownloadMode.values) {
      if (m.name == raw) return m;
    }
    // 默认逐字：信息量最大，且没有逐字数据时会自动回退逐行
    // （见 [resolveLyricMode]），不会出现"选了逐字却什么都没存到"。
    return LyricDownloadMode.word;
  }

  static Future<void> setLyricMode(LyricDownloadMode m) =>
      KvStore.instance.setString('$_prefs:$_kLyric', m.name);

  /// 把「请求的歌词模式」折算成「实际能落地的模式」。
  ///
  /// 选了逐字但服务端只给了逐行歌词（很多老歌 / 纯音乐只有 LRC），
  /// 就退而求其次存逐行——总比什么都没有强。纯函数，便于单测。
  static LyricDownloadMode resolveLyricMode(
      LyricDownloadMode requested, Lyrics lyrics) {
    if (requested == LyricDownloadMode.word && !lyrics.hasWordTiming) {
      return LyricDownloadMode.line;
    }
    return requested;
  }

  /// 是否把封面写入音频文件（外挂 .jpg 仅在内嵌不支持时兜底）。
  static bool get saveCover =>
      KvStore.instance.getBool('$_prefs:$_kCover', def: true);

  static Future<void> setSaveCover(bool v) =>
      KvStore.instance.setBool('$_prefs:$_kCover', v);

  /// 下载封面原图字节；失败返回 null。
  static Future<Uint8List?> fetchCover(Song song) async {
    final url = CoverUrl.maximize(song.coverUrl);
    if (url.isEmpty) return null;
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.bytes,
      validateStatus: (s) => s != null && s < 400,
    ));
    try {
      final resp = await dio.get<List<int>>(
        url,
        options: Options(headers: <String, String>{
          'Referer': song.isNetease ? 'https://music.163.com/' : 'https://y.qq.com/',
          'User-Agent': 'Mozilla/5.0',
        }),
      );
      final data = resp.data;
      if (data == null || data.isEmpty) return null;
      return Uint8List.fromList(data);
    } catch (e) {
      AppLog.w('DownloadExtras', '下载封面失败: $e');
      return null;
    }
  }

  /// 下载完成后补齐歌词 / 封面，并写入音频文件内部标签。
  ///
  /// 返回一行人类可读的结果（用于 Toast / SnackBar / 下载列表副标题）；
  /// 两个开关都关闭时返回空串，表示无需做任何事。
  ///
  /// [lyricMode] 为本次下载的临时选择（下载弹层里勾的），
  /// 传 null 时用全局设置 [lyricMode]。
  ///
  /// 任何一步失败都不影响已下载的音频文件——内嵌失败会退回外挂文件，
  /// 外挂文件写入失败也只是少一个附件。
  static Future<String> attach({
    required String filePath,
    required Song song,
    LyricDownloadMode? lyricMode,
  }) async {
    final requested = lyricMode ?? DownloadExtras.lyricMode;
    final wantCover = saveCover;
    if (requested == LyricDownloadMode.off && !wantCover) return '';

    String? lrc;
    // 实际落盘的歌词粒度（请求逐字但没有逐字数据时是「逐行」）。
    String? lyricOutcome;
    if (requested != LyricDownloadMode.off) {
      try {
        final lyrics = await LyricApi.of(song);
        if (lyrics.isNotEmpty) {
          final mode = resolveLyricMode(requested, lyrics);
          if (mode != requested) {
            AppLog.i('DownloadExtras',
                '${song.name} 无逐字歌词，回退为逐行 LRC');
          }
          lrc = LyricSerializer.toLrc(
              lyrics, wordLevel: mode == LyricDownloadMode.word);
          lyricOutcome = mode == LyricDownloadMode.word ? '逐字' : '逐行';
        }
      } catch (e) {
        AppLog.w('DownloadExtras', '获取歌词失败: $e');
      }
    }

    EmbeddedCover? cover;
    if (wantCover) {
      final bytes = await fetchCover(song);
      if (bytes != null) {
        cover = EmbeddedCover(data: bytes, mime: AudioTagger.guessMime(bytes));
      }
    }

    if (lrc == null && cover == null) {
      return '已下载（歌词/封面不可用）';
    }

    final result = await AudioTagger.embed(
      file: File(filePath),
      lyrics: lrc,
      cover: cover,
      title: song.name,
      artist: song.singer,
      album: song.album,
    );

    // 外挂文件与内嵌标签**同时**产出，不是二选一。
    // 只写元数据的话，很多播放器与文件管理器根本不显示内嵌封面/歌词，
    // 用户在下载目录里看不到任何东西，也没法把封面单独拿去用。
    final sidecars = await _writeSidecars(filePath, song, lrc, cover);

    // 结果文案带上实际写入的物件（如「逐字歌词 + 封面」），
    // 下载列表里能直接看出这次到底存了什么。
    final parts = <String>[
      if (lyricOutcome != null) '$lyricOutcome歌词',
      if (cover != null) '封面',
    ].join(' + ');

    if (result.error != null) {
      // 内嵌失败时全靠外挂，至少不丢歌词和封面
      final suffix = sidecars.isEmpty ? '' : '（已存为外挂文件）';
      return '已下载（$parts）$suffix · ${result.error}';
    }
    return sidecars.isEmpty
        ? '已下载（$parts已写入元数据）'
        : '已下载（$parts已内嵌 + 同名外挂文件）';
  }

  /// 写入同名 `.lrc` 与 `.jpg`。
  ///
  /// 基名直接取音频文件的实际名字（去扩展名），而不是「歌手 - 歌名」：
  /// 同名歌曲重复下载时下载管理器会给音频加 ` (1)` 之类的后缀，
  /// 用歌名拼出来的外挂文件就对不上音频了。
  static Future<List<String>> _writeSidecars(
    String filePath,
    Song song,
    String? lrc,
    EmbeddedCover? cover,
  ) async {
    final out = <String>[];
    final base = filePath.substring(0, filePath.length - _extLen(filePath));
    try {
      if (lrc != null && lrc.isNotEmpty) {
        final f = File('$base.lrc');
        await f.writeAsString(lrc, flush: true);
        out.add(f.path);
      }
    } catch (e) {
      AppLog.w('DownloadExtras', '写入外挂歌词失败: $e');
    }
    try {
      if (cover != null) {
        // 按真实格式给扩展名：GIF / WebP 存成 .jpg 的话播放器渲不出来
        const extOf = {
          'image/png': '.png',
          'image/gif': '.gif',
          'image/webp': '.webp',
        };
        final ext = extOf[cover.mime] ?? '.jpg';
        final f = File('$base$ext');
        await f.writeAsBytes(cover.data, flush: true);
        out.add(f.path);
      }
    } catch (e) {
      AppLog.w('DownloadExtras', '写入外挂封面失败: $e');
    }
    return out;
  }

  static int _extLen(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final i = name.lastIndexOf('.');
    return i <= 0 ? 0 : name.length - i;
  }
}
