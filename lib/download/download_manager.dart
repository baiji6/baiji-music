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
  static const String _keyKuwo = 'download_kuwo_quality';

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

  /// 上次选择的酷我下载音质（v2.4.0）；未选过则跟随播放器当前音质。
  KuwoQuality get kuwoQuality => KuwoQuality.fromId(
          KvStore.instance.getString('$_prefs:$_keyKuwo')) ??
      PlayerController.instance.currentKuwoQuality;

  Future<void> saveKuwoQuality(KuwoQuality q) =>
      KvStore.instance.setString('$_prefs:$_keyKuwo', q.id);

  /// 尝试为指定歌曲获取可用直链；当前音质不可用时沿降级链自动往下试。
  ///
  /// 返回直链 + 服务端**实际**音质；全部失败返回 [PlayUrlResult.empty]。
  Future<PlayUrlResult> resolveUrl(
      Song song, Quality qqQuality, NeteaseQuality neQuality,
      {KuwoQuality? kuwoQuality}) async {
    if (song.isKuwo) {
      try {
        final r = await MusicApi.playUrlInfo(song, qqQuality, neQuality,
            kuwoQuality: kuwoQuality ?? this.kuwoQuality);
        if (r.isNotEmpty) return r;
      } catch (e) {
        AppLog.w('DownloadManager', '酷我取直链失败: $e');
      }
      return PlayUrlResult.empty;
    }
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
  ///
  /// **临时文件与续传**：先写 `目标.part`，全部收完才改名成正式文件——
  /// 下载失败/取消不会在下载目录留下打不开的残品。传 [partPath]
  /// （暂停任务留下的 `.part`）时走 HTTP Range 续传：服务端返回 206
  /// 就从断点追加，返回 200（不支持 Range）则截断重下，返回 416
  /// （残片已完整）直接收尾。
  ///
  /// [cancelToken] 取消时抛 [DioException]（[CancelToken.isCancel]），
  /// 由调用方区分「暂停」（保留 .part）与「取消」（删 .part）。
  /// [onPart] 在 `.part` 路径确定后回调一次，供暂停时记录断点。
  Future<String?> download(
    Song song, {
    required Quality qqQuality,
    required NeteaseQuality neQuality,
    KuwoQuality? kuwoQuality,
    void Function(int downloaded, int total)? onProgress,
    CancelToken? cancelToken,
    String? partPath,
    void Function(String partPath)? onPart,
  }) async {
    try {
      final resolved =
          await resolveUrl(song, qqQuality, neQuality, kuwoQuality: kuwoQuality);
      if (resolved.isEmpty) {
        AppLog.e('DownloadManager', '无可用直链: ${song.name}');
        return null;
      }
      // 扩展名必须跟随"实际"音质：请求 FLAC 但服务端只给 MP3 时，
      // 若仍按请求值写 .flac，落盘文件会头不对尾、播放器无法识别。
      final dir = await getDownloadDir();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final baseName =
          '${sanitize(song.singer)} - ${sanitize(song.name)}';
      // 同名歌曲重复下载必须另起文件名：直接覆盖会把上一次下载的
      // 文件（连它内嵌的歌词/封面/元数据）一起冲掉。
      final target = uniqueTarget(dir, baseName, resolved.ext);

      final path = await saveToDir(
        url: resolved.url,
        dir: dir,
        baseName: baseName,
        ext: resolved.ext,
        target: target,
        onProgress: onProgress,
        cancelToken: cancelToken,
        partPath: partPath,
        onPart: onPart,
      );
      if (path != null) {
        AppLog.d('DownloadManager',
            '下载完成: $path (${resolved.label})');
      }
      return path;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow; // 暂停/取消交给上层分流
      AppLog.e('DownloadManager', '下载失败: $e');
      return null;
    } catch (e) {
      AppLog.e('DownloadManager', '下载失败: $e');
      return null;
    }
  }

  /// 把 [url] 流式落盘的传输核心：`.part` 中转 + Range 续传 + 长度校验。
  ///
  /// 从 [download] 抽出来单独公开，一是让「取直链」与「传字节」两个
  /// 失败域分开处理，二是单测可以直接指向本地 HTTP 服务器跑完整
  /// 下载/暂停/续传链路，不必打真网络。
  ///
  /// [target] 为最终文件路径（调用方已做好 ` (1)` 去重）；
  /// 传输过程写在 `target.path + '.part'`（或传入的 [partPath]）。
  /// 取消时抛 [DioException]；其余失败返回 null（`.part` 保留）。
  Future<String?> saveToDir({
    required String url,
    required Directory dir,
    required String baseName,
    required String ext,
    required File target,
    void Function(int downloaded, int total)? onProgress,
    CancelToken? cancelToken,
    String? partPath,
    void Function(String partPath)? onPart,
  }) async {
    // ===== .part 临时文件：失败/暂停不留残品，可断点续传 =====
    final part = File(partPath ?? '${target.path}.part');
    onPart?.call(part.path);
    var resumeFrom = 0;
    if (part.existsSync()) {
      resumeFrom = part.lengthSync();
    }

    final resp = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: <String, String>{
          if (resumeFrom > 0) 'Range': 'bytes=$resumeFrom-',
        },
      ),
      cancelToken: cancelToken,
    );

    final body = resp.data;
    if (body == null) {
      AppLog.e('DownloadManager', '响应无数据流: $url');
      return null;
    }
    final status = body.statusCode;

    // 服务端可能忽略 Range 返回 200（全量），或残片已满返回 416
    if (resumeFrom > 0 && status == 416) {
      // 残片已经是完整文件，直接收尾
      part.renameSync(target.path);
      AppLog.d('DownloadManager', '残片已完整，直接收尾: ${target.path}');
      return target.path;
    }
    var appendFrom = 0;
    if (resumeFrom > 0) {
      if (status == 206) {
        appendFrom = resumeFrom;
      } else {
        // 200 等：不支持续传，截断重下（resumeFrom 作废）
        if (part.existsSync()) part.deleteSync();
      }
    }

    final bodyLen = body.contentLength; // 本次响应体长度，-1 表示未知
    final total = bodyLen > 0 ? appendFrom + bodyLen : -1;

    // 流式写盘：边收边写，避免整曲驻留内存
    RandomAccessFile? raf;
    try {
      raf = part.openSync(
          mode: appendFrom > 0 ? FileMode.append : FileMode.write);
      int sessionReceived = 0;
      await for (final chunk in body.stream) {
        if (chunk.isEmpty) continue;
        raf.writeFromSync(chunk);
        sessionReceived += chunk.length;
        onProgress?.call(appendFrom + sessionReceived, total);
      }
    } finally {
      await raf?.close();
    }

    // 长度校验：服务端给了 content-length 就必须对得上，
    // 对不上说明连接被截断，此时 .part 保留供续传/重试。
    if (bodyLen > 0) {
      final got = part.lengthSync();
      if (got != appendFrom + bodyLen) {
        AppLog.e('DownloadManager',
            '下载长度不符: 期望 ${appendFrom + bodyLen} 实际 $got');
        return null;
      }
    }
    final finalSize = part.lengthSync();
    part.renameSync(target.path);

    AppLog.d('DownloadManager', '保存完成: ${target.path} size=$finalSize');
    return target.path;
  }

  /// 清理文件名非法字符（对应 Kotlin sanitize）。
  static String sanitize(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? '无名' : cleaned;
  }

  /// 在 [dir] 下为 `baseName + ext` 找一个**不存在**的文件路径：
  /// 已存在时依次尝试 ` (1)` / ` (2)` …，绝不覆盖已有文件。
  ///
  /// 歌词独立下载（[DownloadExtras.downloadLyricOnly]）与音频下载共用，
  /// 保证重复下载同一首歌时新旧文件都在。
  static File uniqueTarget(Directory dir, String baseName, String ext) {
    var f = File('${dir.path}${Platform.pathSeparator}$baseName$ext');
    var n = 1;
    while (f.existsSync()) {
      f = File('${dir.path}${Platform.pathSeparator}$baseName ($n)$ext');
      n++;
    }
    return f;
  }
}