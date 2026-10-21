/// 数据上传客户端（v2.4.0）。
///
/// 把用户的**行为数据**上报到自建服务器 `http://molan.guoyue2010.cn/upload.php`：
/// - 用户 GUID（设备唯一标识，见 [DeviceGuid]）；
/// - 当前使用的平台（qq / netease / kuwo）；
/// - 搜索过的关键词；
/// - 播放过的歌曲（歌名 / 歌手 / 专辑 / 音质）；
/// - 实际拿到的播放链接。
///
/// 设计要点：
/// - **绝不阻塞主流程**：所有上报都是 fire-and-forget，失败只记日志；
/// - **本地队列 + 批量发送**：每条事件先进内存队列，攒够或超过 30 秒
///   发一次，减少请求数；
/// - **失败重试**：网络异常时保留队列，下一轮再发；
/// - **可关闭**：设置里提供开关（通过 [Telemetry.enabled] 读 KvStore）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/models.dart';
import 'app_logger.dart';
import 'device_guid.dart';
import 'kv_store.dart';

/// 一条待上报的事件。
class TelemetryEvent {
  /// 事件类型：`search` / `play` / `app_start` / `platform_switch`。
  final String type;

  /// 事件负载（JSON 可序列化）。
  final Map<String, dynamic> payload;

  /// 本地产生时间（毫秒时间戳）。
  final int timeMs;

  const TelemetryEvent(this.type, this.payload, this.timeMs);

  factory TelemetryEvent.create(String type, Map<String, dynamic> payload) =>
      TelemetryEvent(
          type, payload, DateTime.now().millisecondsSinceEpoch);

  Map<String, dynamic> toJson() => {
        'type': type,
        'time': timeMs,
        ...payload,
      };
}

/// 上报服务。
class Telemetry {
  Telemetry._();

  static final Telemetry instance = Telemetry._();

  /// 服务器地址（用户自建）。
  static const String endpoint = 'http://molan.guoyue2010.cn/upload.php';

  static const String _enabledKey = 'telemetry_enabled';

  /// 攒批阈值：达到条数立刻发。
  static const int _batchSize = 10;

  /// 攒批时间阈值（秒）。
  static const int _flushIntervalSec = 30;

  /// 队列上限：超出丢最旧的，防止内存无限涨。
  static const int _maxQueue = 200;

  final List<TelemetryEvent> _queue = [];
  Timer? _timer;
  bool _flushing = false;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 12),
    headers: {'Content-Type': 'application/json; charset=utf-8'},
  ));

  /// 是否开启上报（默认开启，可在设置里关）。
  bool get enabled {
    try {
      return KvStore.instance.getBool(_enabledKey, def: true);
    } catch (_) {
      return true;
    }
  }

  Future<void> setEnabled(bool v) =>
      KvStore.instance.setBool(_enabledKey, v);

  /// 启动定时刷队列（App 启动时调用一次）。
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: _flushIntervalSec),
      (_) => flush(),
    );
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  // ==================== 事件入口 ====================

  /// App 启动。
  void appStart(String version) {
    _enqueue(TelemetryEvent.create('app_start', {
      'version': version,
      'platform_os': DeviceGuid.platformName,
    }));
  }

  /// 平台切换。
  void platformSwitch(String from, String to) {
    _enqueue(TelemetryEvent.create('platform_switch', {
      'from': from,
      'to': to,
    }));
  }

  /// 搜索。
  void search(String platform, String keyword, int resultCount) {
    _enqueue(TelemetryEvent.create('search', {
      'platform': platform,
      'keyword': keyword,
      'result_count': resultCount,
    }));
  }

  /// 播放（含音质与播放链接）。
  void play({
    required String platform,
    required String songId,
    required String songName,
    required String singer,
    required String album,
    required String quality,
    String? playUrl,
  }) {
    _enqueue(TelemetryEvent.create('play', {
      'platform': platform,
      'song_id': songId,
      'song_name': songName,
      'singer': singer,
      'album': album,
      'quality': quality,
      'play_url': playUrl ?? '',
    }));
  }

  /// 播放歌曲（便捷方法，从 [Song] 取字段）。
  void playSong(Song song, {String quality = '', String? playUrl}) {
    play(
      platform: song.source,
      songId: song.mid,
      songName: song.name,
      singer: song.singer,
      album: song.album,
      quality: quality,
      playUrl: playUrl,
    );
  }

  // ==================== 内部 ====================

  void _enqueue(TelemetryEvent e) {
    if (!enabled) return;
    _queue.add(e);
    if (_queue.length > _maxQueue) {
      _queue.removeRange(0, _queue.length - _maxQueue);
    }
    if (_queue.length >= _batchSize) {
      unawaited(flush());
    }
  }

  /// 立即发送队列中的全部事件。
  Future<void> flush() async {
    if (_flushing) return;
    if (_queue.isEmpty) return;
    _flushing = true;
    final batch = List<TelemetryEvent>.from(_queue);
    try {
      final guid = await DeviceGuid.ensure();
      final payload = {
        'guid': guid,
        'os': DeviceGuid.platformName,
        'app': 'baiji_music',
        'events': batch.map((e) => e.toJson()).toList(),
      };
      final resp = await _dio.post(
        endpoint,
        data: jsonEncode(payload),
        options: Options(validateStatus: (_) => true),
      );
      final code = resp.statusCode ?? 0;
      if (code >= 200 && code < 300) {
        _queue.removeRange(0, batch.length);
        AppLog.d('Telemetry', '已上报 ${batch.length} 条事件');
      } else {
        AppLog.w('Telemetry', '上报失败 HTTP $code（保留队列重试）');
      }
    } catch (e) {
      AppLog.w('Telemetry', '上报异常: $e（保留队列重试）');
    } finally {
      _flushing = false;
    }
  }

  /// 供 UI 展示的本地统计（不依赖网络）。
  int get pendingCount => _queue.length;
}
