import 'dart:io';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// 下载管理器：支持自定义下载位置与音质选择（对应原生 `download/DownloadManager.kt`）。
///
/// 通过 [MusicApi] 取直链（QQ 自动降级：请求音质 → 320 → 192 → 128），
/// 用 dio 流式写盘避免整曲驻留内存；下载目录持久化保存。
class DownloadManager {
  DownloadManager._();

  static final DownloadManager instance = DownloadManager._();

  static const String _prefs = 'download_prefs';
  static const String _keyPath = 'download_path';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 60),
    responseType: ResponseType.stream,
    validateStatus: (_) => true,
  ));

  /// 默认下载目录（各平台应用文档目录下 Music/）。
  Future<Directory> getDefaultDownloadDir() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      return Directory('${base.path}${Platform.pathSeparator}Music');
    } catch (_) {
      // 兜底到应用当前目录
      return Directory('.');
    }
  }

  /// 获取下载目录（优先用户自定义，并验证可写性）。
  Future<Directory> getDownloadDir() async {
    final path = KvStore.instance.getString('$_prefs:$_keyPath');
    if (path != null && path.isNotEmpty) {
      final f = Directory(path);
      if (await _isWritable(f)) return f;
      AppLog.w('DownloadManager', '自定义目录不可写，回退到默认: $path');
    }
    return getDefaultDownloadDir();
  }

  /// 验证目录是否可写（尝试创建测试文件）。
  Future<bool> _isWritable(Directory dir) async {
    try {
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final test = File('${dir.path}${Platform.pathSeparator}.baiji_test');
      test.writeAsStringSync('test', flush: true);
      test.deleteSync();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> setDownloadDir(String path) =>
      KvStore.instance.setString('$_prefs:$_keyPath', path);

  /// 尝试为指定歌曲获取可用直链（QQ 自动降级）。
  /// 返回 (url, 实际音质标签)；无可用直链返回 null。
  Future<({String url, String qualityNote})?> resolveUrl(
      Song song, Quality qqQuality, NeteaseQuality neQuality) async {
    if (song.isNetease) {
      final url =
          await MusicApi.playUrl(song, Quality.playbackDefault, neQuality);
      if (url.isEmpty) return null;
      return (url: url, qualityNote: neQuality.label);
    }
    // QQ：请求音质 → 320 → 192 → 128
    final fallback = [qqQuality, Quality.mp3_320, Quality.aac192, Quality.mp3_128];
    final seen = <String>{};
    for (final q in fallback) {
      if (!seen.add(q.code)) continue;
      try {
        final url =
            await MusicApi.playUrl(song, q, NeteaseQuality.playbackDefault);
        if (url.isNotEmpty) {
          return (url: url, qualityNote: q.label);
        }
        AppLog.i('DownloadManager', '音质 ${q.label} 无直链，继续降级');
      } catch (e) {
        AppLog.w('DownloadManager', '获取直链失败 ${q.label}: $e');
      }
    }
    return null;
  }

  /// 下载单曲，返回保存位置描述；失败返回 null。
  ///
  /// [onProgress] 回调 (已下载字节, 总字节)。
  Future<String?> download(
    Song song, {
    required Quality qqQuality,
    required NeteaseQuality neQuality,
    void Function(int downloaded, int total)? onProgress,
  }) async {
    try {
      final resolved = await resolveUrl(song, qqQuality, neQuality);
      if (resolved == null) {
        AppLog.e('DownloadManager', '无可用直链: ${song.name}');
        return null;
      }
      final ext =
          song.isNetease ? neQuality.ext : resolved.qualityNote.startsWith('MP3') ? '.mp3' : qqQuality.ext;
      final dir = await getDownloadDir();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final fileName =
          '${sanitize(song.singer)} - ${sanitize(song.name)}$ext';
      final target = File('${dir.path}${Platform.pathSeparator}$fileName');

      // 流式下载：边收边写，避免整曲驻留内存
      int downloaded = 0;
      int? total;
      await _dio.download(
        resolved.url,
        target.path,
        onReceiveProgress: (received, totalBytes) {
          downloaded = received;
          total = totalBytes;
          onProgress?.call(received, totalBytes);
        },
      );

      AppLog.d('DownloadManager',
          '下载完成: ${target.path} (${resolved.qualityNote}) size=${total ?? downloaded}');
      return target.path;
    } catch (e) {
      AppLog.e('DownloadManager', '下载失败: $e');
      return null;
    }
  }

  /// 清理文件名非法字符（对应 Kotlin sanitize）。
  static String sanitize(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? '无名' : cleaned;
  }
}