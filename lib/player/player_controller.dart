import 'dart:async';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:media_kit/media_kit.dart';

/// 基于 media_kit (libmpv/ffmpeg) 的全局播放控制器。
///
/// media_kit 底层使用 libmpv + ffmpeg 软解，支持几乎所有音频格式：
/// MP3, AAC, FLAC, OGG, OPUS, WAV, ALAC, DTS, Dolby Atmos 等。
/// 支持网络流（HTTP/HTTPS/HLS/DASH）和跨平台：Android / iOS / macOS / Windows / Linux。
///
/// 在 main.dart 中初始化：
/// ```dart
/// void main() {
///   WidgetsFlutterBinding.ensureInitialized();
///   MediaKit.ensureInitialized();
///   runApp(MyApp());
/// }
/// ```
class PlayerController {
  PlayerController._();

  static final PlayerController instance = PlayerController._();

  static const String _defaultQualityKey = 'default_quality';
  static const String _neteaseQualityKey = 'default_netease_quality';

  Player? _player;
  Song? _currentSong;
  final List<Song> _queue = [];
  int _queueIndex = -1;

  Quality currentQuality = Quality.playbackDefault;
  NeteaseQuality currentNeteaseQuality = NeteaseQuality.playbackDefault;

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

  // ===== 初始化 =====

  void _ensurePlayer() {
    if (_player != null) return;
    _player = Player();

    // 播放状态监听
    _player!.stream.playing.listen((playing) {
      _playState.add(playing);
    });

    // 播放完成监听
    _player!.stream.completed.listen((completed) {
      if (completed) {
        _onTrackCompleted();
      }
    });

    // 播放进度
    _player!.stream.position.listen((position) {
      _positionStream.add(position);
    });

    // 总时长
    _player!.stream.duration.listen((duration) {
      _durationStream.add(duration);
    });

    // 错误监听
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
    _queueIndex = startIndex;
    final first = _queue[_queueIndex];
    _currentSong = first;
    _songStream.add(first);

    final url = await _resolveUrl(first);
    if (url.isEmpty) {
      _onTrackCompleted();
      return;
    }
    await play(first, url);
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;
    final n = (_queueIndex + 1) % _queue.length;
    _queueIndex = n;
    final song = _queue[n];
    _currentSong = song;
    _songStream.add(song);
    final url = await _resolveUrl(song);
    if (url.isEmpty) {
      _onTrackCompleted();
      return;
    }
    await play(song, url);
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    final n = (_queueIndex - 1 + _queue.length) % _queue.length;
    _queueIndex = n;
    final song = _queue[n];
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

  // ===== 内部 =====

  Future<String> _resolveUrl(Song song) =>
      MusicApi.playUrl(song, currentQuality, currentNeteaseQuality);

  void _onTrackCompleted() {
    if (_queue.isNotEmpty && _queueIndex < _queue.length - 1) {
      _queueIndex++;
      final song = _queue[_queueIndex];
      _currentSong = song;
      _songStream.add(song);
      _resolveUrl(song).then((url) async {
        if (url.isNotEmpty) {
          await play(song, url);
        }
      });
    } else {
      _completedStream.add(null);
    }
  }

  // ===== 音质偏好 =====

  void loadDefaultQuality() {
    final saved = KvStore.instance.getString(_defaultQualityKey);
    currentQuality = Quality.fromCode(saved) ?? Quality.playbackDefault;
    final savedNe = KvStore.instance.getString(_neteaseQualityKey);
    currentNeteaseQuality = NeteaseQuality.fromLevel(savedNe) ?? NeteaseQuality.playbackDefault;
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
