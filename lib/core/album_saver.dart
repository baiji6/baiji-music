import 'dart:typed_data';

import 'package:gal/gal.dart';

import '../download/download_extras.dart';
import '../local/local_scanner.dart';
import '../models/models.dart';

/// 保存封面到系统相册的结果。
enum CoverSaveState {
  /// 已保存。
  ok,

  /// 这首歌没有可用封面（网络封面下载失败，或本地文件没内嵌封面）。
  noCover,

  /// 用户拒绝了相册权限。
  denied,

  /// 保存过程出错，消息见 [CoverSaveResult.message]。
  failed,
}

class CoverSaveResult {
  const CoverSaveResult(this.state, [this.message = '']);

  final CoverSaveState state;
  final String message;

  bool get isOk => state == CoverSaveState.ok;
}

/// 把歌曲封面存进系统相册。
///
/// 封面来源分两种：
/// - 网络歌曲：按最大分辨率重新下载（[DownloadExtras.fetchCover]），
///   而不是拿列表里那张可能只有 200px 的缩略图；
/// - 本地歌曲：直接读音频文件内嵌的封面（[LocalScanner.readCover]）。
class AlbumSaver {
  AlbumSaver._();

  /// 相册里统一归到这个「相簿」名下，方便以后在系统相册里找。
  static const String albumName = '白姬音乐';

  /// 取歌曲封面的原始字节；没有封面时返回 null。
  static Future<Uint8List?> coverBytes(Song song) async {
    try {
      if (song.isLocal) return await LocalScanner.readCover(song);
      return await DownloadExtras.fetchCover(song);
    } catch (e) {
      return null;
    }
  }

  /// 保存封面到相册。
  ///
  /// iOS 首次会弹相册授权；用户拒绝后不再反复弹，直接返回 [CoverSaveState.denied]
  /// 让调用方提示去系统设置里开。
  static Future<CoverSaveResult> saveCover(Song song) async {
    try {
      if (!await Gal.hasAccess(toAlbum: true)) {
        if (!await Gal.requestAccess(toAlbum: true)) {
          return const CoverSaveResult(
            CoverSaveState.denied,
            '没有相册权限，请在系统设置里允许访问相册',
          );
        }
      }

      final bytes = await coverBytes(song);
      if (bytes == null || bytes.isEmpty) {
        return const CoverSaveResult(CoverSaveState.noCover, '这首歌没有封面');
      }

      await Gal.putImageBytes(bytes, album: albumName, name: fileStem(song));
      return const CoverSaveResult(CoverSaveState.ok);
    } catch (e) {
      return CoverSaveResult(CoverSaveState.failed, '保存失败: $e');
    }
  }

  /// 相册里显示的文件名主干：`<歌手> - <歌名>`，去掉文件系统不允许的字符。
  ///
  /// **不要带扩展名**：`gal` 的原生实现会自己拼 `.jpg`（Android 的
  /// `getUniqueFileUri` 是 `name + extension`），带上了就会存成
  /// `歌手 - 歌名.jpg.jpeg`。
  static String fileStem(Song song) {
    String clean(String s) => s
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n]'), '_')
        .trim();
    final artist = clean(song.singer.isEmpty ? '未知歌手' : song.singer);
    final title = clean(song.name.isEmpty ? '未知歌曲' : song.name);
    final stem = '$artist - $title';
    // 文件名过长时部分系统会直接保存失败，这里主动收窄
    return stem.length > 120 ? stem.substring(0, 120) : stem;
  }
}