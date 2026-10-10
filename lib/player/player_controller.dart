import 'dart:async';
import 'dart:math';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/local/local_scanner.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

/// 播放模式。
enum PlayMode {
  /// 顺序播放：播到队尾停止。
  sequential('顺序播放', Icons.repeat_rounded),

  /// 单曲循环：播完重复当前曲目。
  singleLoop('单曲循环', Icons.repeat_one_rounded),

  /// 随机播放：随机跳到任意其它曲目。
  shuffle('随机播放', Icons.shuffle_rounded);

  const PlayMode(this.label, this.icon);

  final String label;

  /// UI 图标（因此本文件需要 import flutter/material.dart）。
  final IconData icon;
}

/// 基于 media_kit (libmpv/ffmpeg) 的全局播放控制器。
///
/// media_kit 底层使用 libmpv + ffmpeg 软解，支持几乎所有音频格式：
/// MP3, AAC, FLAC, OGG, OPUS, WAV, ALAC, DTS, Dolby Atmos 等。
/// 支持网络流（HTTP/HTTPS/HLS/DASH）和跨平台：Android / iOS / macOS / Windows / Linux。
class PlayerController {
  PlayerController._();

  static final PlayerController instance = PlayerController._();

  static const String _defaultQualityKey = 'default_quality';
  static const String _neteaseQualityKey = 'default_netease_quality';
  static const String _playModeKey = 'play_mode';

  Player? _player;
  Song? _currentSong;
  final List<Song> _queue = [];
  int _queueIndex = -1;

  Quality currentQuality = Quality.playbackDefault;
  NeteaseQuality currentNeteaseQuality = NeteaseQuality.playbackDefault;

  /// 当前曲目实际生效的 QQ 音质（可能与请求音质不同：服务端降级或本地自动降级）。
  Quality? _actualQqQuality;

  Quality? get actualQqQuality => _actualQqQuality;

  /// 当前曲目实际生效的网易云音质。
  NeteaseQuality? _actualNeQuality;

  NeteaseQuality? get actualNeteaseQuality => _actualNeQuality;

  PlayMode _playMode = PlayMode.sequential;
  PlayMode get playMode => _playMode;

  final _rng = Random();

  // ===== 状态流 =====

  final StreamController<bool> _playState = StreamController.broadcast();
  Stream<bool> get onPlayStateChanged => _playState.stream;

  final StreamController<Song?> _songStream = StreamController.broadcast();
  Stream<Song?> get onSongChanged => _songStream.stream;

  final StreamController<Duration> _positionStream = StreamController.broadcast();
  Stream<Duration> get onPositionChanged => _positionStream.stream;

  final StreamController<Duration> _durationStream = StreamController.broadcast();
  Stream<Duration> get onDurationChanged => _durationStream.stream;

  final StreamController<void> _completedStream = StreamController.broadcast();
  Stream<void> get onCompleted => _completedStream.stream;

  final StreamController<String> _errorStream = StreamController.broadcast();
  Stream<String> get onError => _errorStream.stream;

  /// QQ 音质实际生效值变化（供播放页显示"实际音质/已降级"）。
  final StreamController<Quality?> _qualityStream = StreamController.broadcast();
  Stream<Quality?> get onQualityChanged => _qualityStream.stream;

  /// 网易云音质实际生效值变化。
  final StreamController<NeteaseQuality?> _neQualityStream =
      StreamController.broadcast();
  Stream<NeteaseQuality?> get onNeteaseQualityChanged => _neQualityStream.stream;

  /// 播放模式变化。
  final StreamController<PlayMode> _modeStream = StreamController.broadcast();
  Stream<PlayMode> get onPlayModeChanged => _modeStream.stream;

  // ===== 初始化 =====

  void _ensurePlayer() {
    if (_player != null) return;
    _player = Player();

    _player!.stream.playing.listen((playing) {
      _playState.add(playing);
    });

    _player!.stream.completed.listen((completed) {
      if (completed) {
        _onTrackCompleted();
      }
    });

    _player!.stream.position.listen((position) {
      _positionStream.add(position);
    });

    _player!.stream.duration.listen((duration) {
      _durationStream.add(duration);
    });

    _player!.stream.error.listen((error) {
      AppLog.e('PlayerController', 'media_kit 错误: $error');
      _errorStream.add('播放错误: $error');
      _playState.add(false);
    });
  }

  // ===== 属性 =====

  Song? get currentSong => _currentSong;
  bool get isPlaying => _player?.state.playing ?? false;
  List<Song> get queue => List.unmodifiable(_queue);
  int get queueIndex => _queueIndex;

  Duration get position => _player?.state.position ?? Duration.zero;
  Duration get duration => _player?.state.duration ?? Duration.zero;

  /// 公开底层 Player 实例（供 UI 直接监听 durationStream 等）。
  /// 注意：不要在外部调用 dispose()。
  Player? get player => _player;

  // ===== 播放控制 =====

  Future<void> _playUrlInternal(String url) async {
    _ensurePlayer();
    try {
      await _player!.open(Media(url));
      await _player!.play();
      AppLog.i('PlayerController', '播放: $url');
    } catch (e) {
      AppLog.e('PlayerController', '播放失败: $e');
      _errorStream.add('播放失败: $e');
      _playState.add(false);
    }
  }

  Future<void> play(Song song, String url) async {
    _currentSong = song;
    _songStream.add(song);
    await _playUrlInternal(url);
  }

  Future<void> playQueue(List<Song> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) return;
    _queue
      ..clear()
      ..addAll(songs);
    _queueIndex = startIndex.clamp(0, songs.length - 1);
    final first = _queue[_queueIndex];
    _currentSong = first;
    _songStream.add(first);

    final url = await _resolveUrl(first);
    if (url.isEmpty) {
      _errorStream.add('无法获取播放链接');
      _onTrackCompleted();
      return;
    }
    await play(first, url);
  }

  /// 手动下一首：顺序/单曲循环都 +1（到尾回到头部），随机则随机取。
  Future<void> next() async {
    if (_queue.isEmpty) return;
    _queueIndex = _nextManualIndex();
    await _playAt(_queueIndex);
  }

  /// 手动上一首：顺序/单曲循环都 -1，随机则随机取。
  Future<void> previous() async {
    if (_queue.isEmpty) return;
    _queueIndex = _playMode == PlayMode.shuffle
        ? _randomIndex()
        : (_queueIndex - 1 + _queue.length) % _queue.length;
    await _playAt(_queueIndex);
  }

  Future<void> _playAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final song = _queue[index];
    _currentSong = song;
    _songStream.add(song);
    final url = await _resolveUrl(song);
    if (url.isEmpty) {
      _onTrackCompleted();
      return;
    }
    await play(song, url);
  }

  void toggle() {
    _ensurePlayer();
    if (_player!.state.playing) {
      _player!.pause();
    } else {
      _player!.play();
    }
  }

  Future<void> seek(Duration position) async {
    _ensurePlayer();
    await _player!.seek(position);
  }

  void notifyState() {
    if (_player != null) {
      _playState.add(_player!.state.playing);
    }
  }

  void release() {
    _player?.dispose();
    _player = null;
  }

  // ===== 取流：音质自动降级 =====

  /// 按当前偏好取流；若该音质不可用（无可用链接），沿降级链自动往下试。
  ///
  /// 服务端还可能"请求成功但返回更低音质"（未登录/无版权/未开通会员），
  /// 这种情况由 [MusicApi.playUrlInfo] 反查真实音质并同步给 UI。
  Future<String> _resolveUrl(Song song) async {
    // 本地文件不需要联网取流：直接把路径转成 media_kit 认得的 file:// URI。
    if (song.isLocal) {
      final local = LocalScanner.playUri(song);
      if (local.isEmpty) {
        AppLog.w('PlayerController', '本地文件不可读: ${song.localPath}');
        _clearActual();
        return '';
      }
      return local;
    }

    final chain = song.isNetease
        ? MusicApi.neteaseDowngradeChain(currentNeteaseQuality)
            .map((q) => _FetchPlan(qq: currentQuality, ne: q))
            .toList()
        : MusicApi.qqDowngradeChain(currentQuality)
            .map((q) => _FetchPlan(qq: q, ne: currentNeteaseQuality))
            .toList();

    for (var i = 0; i < chain.length; i++) {
      final plan = chain[i];
      final r = await _fetch(song, plan.qq, plan.ne);
      if (r.isNotEmpty) {
        if (i > 0) {
          AppLog.i('PlayerController', '降级成功 -> ${r.label}');
        }
        _applyActual(r);
        return r.url;
      }
      AppLog.w('PlayerController',
          '${song.name} 的 ${song.isNetease ? plan.ne.label : plan.qq.label} 不可用，尝试降级');
    }

    _clearActual();
    return '';
  }

  /// 单次取流，异常统一吞掉（降级链需要继续往下走）。
  Future<PlayUrlResult> _fetch(Song song, Quality qq, NeteaseQuality ne) async {
    try {
      return await MusicApi.playUrlInfo(song, qq, ne);
    } catch (e) {
      AppLog.w('PlayerController', '取流异常: $e');
      return PlayUrlResult.empty;
    }
  }

  /// 记录实际生效音质并广播。
  void _applyActual(PlayUrlResult r) {
    _actualQqQuality = r.qq;
    _actualNeQuality = r.ne;
    if (!_qualityStream.isClosed) _qualityStream.add(_actualQqQuality);
    if (!_neQualityStream.isClosed) _neQualityStream.add(_actualNeQuality);
  }

  void _clearActual() {
    _actualQqQuality = null;
    _actualNeQuality = null;
    if (!_qualityStream.isClosed) _qualityStream.add(null);
    if (!_neQualityStream.isClosed) _neQualityStream.add(null);
  }

  /// 切换 QQ 音质并重新取流（保留播放位置）。
  Future<void> switchQuality(Quality q) async {
    saveDefaultQuality(q);
    await _reResolve(q.label);
  }

  /// 切换网易云音质并重新取流（保留播放位置）。
  Future<void> switchNeteaseQuality(NeteaseQuality q) async {
    saveNeteaseQuality(q);
    await _reResolve(q.label);
  }

  Future<void> _reResolve(String failLabel) async {
    final song = _currentSong;
    if (song == null) return;
    final pos = position;
    final url = await _resolveUrl(song);
    if (url.isEmpty) {
      _errorStream.add('该歌曲没有可用的$failLabel音质');
      return;
    }
    await _playUrlInternal(url);
    if (pos > Duration.zero) await seek(pos);
  }

  // ===== 播放模式 =====

  /// 手动下一首的下标：顺序/单曲循环 +1 循环，随机取随机。
  int _nextManualIndex() {
    if (_queue.isEmpty) return -1;
    if (_playMode == PlayMode.shuffle) return _randomIndex();
    return (_queueIndex + 1) % _queue.length;
  }

  int _randomIndex() {
    if (_queue.length == 1) return 0;
    var n = _rng.nextInt(_queue.length);
    if (n == _queueIndex) n = (n + 1) % _queue.length;
    return n;
  }

  Future<void> setPlayMode(PlayMode mode) async {
    _playMode = mode;
    KvStore.instance.setString(_playModeKey, mode.name);
    if (!_modeStream.isClosed) _modeStream.add(mode);
  }

  /// 循环切换：顺序 → 单曲循环 → 随机 → 顺序。
  Future<void> cyclePlayMode() async {
    final nextMode = PlayMode.values[
        (PlayMode.values.indexOf(_playMode) + 1) % PlayMode.values.length];
    await setPlayMode(nextMode);
  }

  void _onTrackCompleted() {
    if (_queue.isEmpty) {
      _completedStream.add(null);
      return;
    }

    // 单曲循环：重播当前曲目
    if (_playMode == PlayMode.singleLoop) {
      _resolveUrl(_queue[_queueIndex]).then((url) async {
        if (url.isNotEmpty) await play(_queue[_queueIndex], url);
      });
      return;
    }

    // 随机：一直随机
    if (_playMode == PlayMode.shuffle) {
      _queueIndex = _randomIndex();
      final song = _queue[_queueIndex];
      _currentSong = song;
      _songStream.add(song);
      _resolveUrl(song).then((url) async {
        if (url.isNotEmpty) await play(song, url);
      });
      return;
    }

    // 顺序播放：到队尾即停止
    if (_queueIndex < _queue.length - 1) {
      _queueIndex++;
      final song = _queue[_queueIndex];
      _currentSong = song;
      _songStream.add(song);
      _resolveUrl(song).then((url) async {
        if (url.isNotEmpty) await play(song, url);
      });
    } else {
      _completedStream.add(null);
    }
  }

  // ===== 偏好持久化 =====

  void loadDefaultQuality() {
    final saved = KvStore.instance.getString(_defaultQualityKey);
    currentQuality = Quality.fromCode(saved) ?? Quality.playbackDefault;
    final savedNe = KvStore.instance.getString(_neteaseQualityKey);
    currentNeteaseQuality =
        NeteaseQuality.fromLevel(savedNe) ?? NeteaseQuality.playbackDefault;

    final savedMode = KvStore.instance.getString(_playModeKey);
    if (savedMode != null) {
      _playMode = PlayMode.values.firstWhere(
        (m) => m.name == savedMode,
        orElse: () => PlayMode.sequential,
      );
    }
  }

  void saveDefaultQuality(Quality quality) {
    currentQuality = quality;
    KvStore.instance.setString(_defaultQualityKey, quality.code);
  }

  void saveNeteaseQuality(NeteaseQuality quality) {
    currentNeteaseQuality = quality;
    KvStore.instance.setString(_neteaseQualityKey, quality.level);
  }
}

/// 一次取流尝试的音质组合（QQ/网易云二选一生效，另一个传当前偏好占位）。
class _FetchPlan {
  const _FetchPlan({required this.qq, required this.ne});

  final Quality qq;
  final NeteaseQuality ne;
}
