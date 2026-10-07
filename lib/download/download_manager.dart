import 'dart:io';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:baiji_music/player/player_controller.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// 下载管理器：支持自定义下载位置与音质选择（对应原生 `download/DownloadManager.kt`）。
///
/// 通过 [MusicApi.playUrlInfo] 取直链，所选音质不可用时沿平台降级链自动往下试，
/// 落盘扩展名跟随**实际**音质；用 dio 流式写盘避免整曲驻留内存；
/// 下载目录与下载音质偏好持久化保存。
class DownloadManager {
  DownloadManager._();

  static final DownloadManager instance = DownloadManager._();

  static const String _prefs = 'download_prefs';
  static const String _keyPath = 'download_path';
  static const String _keyQq = 'download_qq_quality';
  static const String _keyNe = 'download_ne_quality';

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

  // ===== 下载音质偏好（与播放音质分开记忆） =====

  /// 上次选择的 QQ 下载音质；未选过则跟随播放器当前音质。
  Quality get qqQuality => Quality.fromCode(
          KvStore.instance.getString('$_prefs:$_keyQq')) ??
      PlayerController.instance.currentQuality;

  /// 上次选择的网易云下载音质；未选过则跟随播放器当前音质。
  NeteaseQuality get neQuality => NeteaseQuality.fromLevel(
          KvStore.instance.getString('$_prefs:$_keyNe')) ??
      PlayerController.instance.currentNeteaseQuality;

  Future<void> saveQqQuality(Quality q) =>
      KvStore.instance.setString('$_prefs:$_keyQq', q.code);

  Future<void> saveNeQuality(NeteaseQuality q) =>
      KvStore.instance.setString('$_prefs:$_keyNe', q.level);

  /// 尝试为指定歌曲获取可用直链；当前音质不可用时沿降级链自动往下试。
  ///
  /// 返回直链 + 服务端**实际**音质；全部失败返回 [PlayUrlResult.empty]。
  Future<PlayUrlResult> resolveUrl(
      Song song, Quality qqQuality, NeteaseQuality neQuality) async {
    if (song.isNetease) {
      for (final q in MusicApi.neteaseDowngradeChain(neQuality)) {
        final r = await _try(song, qqQuality, q);
        if (r.isNotEmpty) return r;
        AppLog.i('DownloadManager', '网易云音质 ${q.label} 无直链，继续降级');
      }
      return PlayUrlResult.empty;
    }
    for (final q in MusicApi.qqDowngradeChain(qqQuality)) {
      final r = await _try(song, q, neQuality);
      if (r.isNotEmpty) return r;
      AppLog.i('DownloadManager', 'QQ 音质 ${q.label} 无直链，继续降级');
    }
    return PlayUrlResult.empty;
  }

  Future<PlayUrlResult> _try(Song song, Quality qq, NeteaseQuality ne) async {
    try {
      return await MusicApi.playUrlInfo(song, qq, ne);
    } catch (e) {
      AppLog.w('DownloadManager', '获取直链失败 ${qq.label}/${ne.label}: $e');
      return PlayUrlResult.empty;
    }
  }

  /// 下载单曲，返回保存位置；失败返回 null。
  ///
  /// [onProgress] 回调 (已下载字节, 总字节)；总字节为 -1 表示服务端未给出长度。
  Future<String?> download(
    Song song, {
    required Quality qqQuality,
    required NeteaseQuality neQuality,
    void Function(int downloaded, int total)? onProgress,
  }) async {
    try {
      final resolved = await resolveUrl(song, qqQuality, neQuality);
      if (resolved.isEmpty) {
        AppLog.e('DownloadManager', '无可用直链: ${song.name}');
        return null;
      }
      // 扩展名必须跟随"实际"音质：请求 FLAC 但服务端只给 MP3 时，
      // 若仍按请求值写 .flac，落盘文件会头不对尾、播放器无法识别。
      final ext = resolved.ext;
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
          '下载完成: ${target.path} (${resolved.label}) size=${total ?? downloaded}');
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