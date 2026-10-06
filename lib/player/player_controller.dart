import 'dart:async';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:just_audio/just_audio.dart';

/// 全局播放控制器（单例，对应原生 `player/PlayerController.kt`）。
///
/// 基于 just_audio 实现六端统一播放；在线播放默认 128k（QQ）/ exhigh（网易云），
/// 各自音质默认值持久化保存；支持队列与播放完成自动下一首。
/// 关键改进：增加解码错误监听与自动降级重试（QQ: 128k AAC → 128k MP3）。
class PlayerController {
  PlayerController._();

  static final PlayerController instance = PlayerController._();

  static const String _defaultQualityKey = 'default_quality';
  static const String _neteaseQualityKey = 'default_netease_quality';

  AudioPlayer? _player;
  Song? _currentSong;
  final List<Song> _queue = [];
  int _queueIndex = -1;

  Quality currentQuality = Quality.playbackDefault;
  NeteaseQuality currentNeteaseQuality = NeteaseQuality.playbackDefault;

  /// 播放状态变化（播放/暂停/错误），供 UI 刷新图标。
  final StreamController<bool> _playState = StreamController.broadcast();
  Stream<bool> get onPlayStateChanged => _playState.stream;

  /// 当前歌曲变化。
  final StreamController<Song?> _songStream = StreamController.broadcast();
  Stream<Song?> get onSongChanged => _songStream.stream;

  /// 播放进度（秒）。
  final StreamController<Duration> _positionStream = StreamController.broadcast();
  Stream<Duration> get onPositionChanged => _positionStream.stream;

  /// 播放完成事件（用于 UI 展示）。
  final StreamController<void> _completedStream = StreamController.broadcast();
  Stream<void> get onCompleted => _completedStream.stream;

  /// 播放错误事件（code, message）。
  final StreamController<(int, String)> _errorStream = StreamController.broadcast();
  Stream<(int, String)> get onError => _errorStream.stream;

  AudioPlayer get player {
    final p = _player;
    if (p != null) return p;
    final np = AudioPlayer();
    np.playerStateStream.listen((state) {
      _playState.add(state.playing);
      if (state.processingState == ProcessingState.completed) {
        _onTrackCompleted();
      }
    });
    np.positionStream.listen((pos) => _positionStream.add(pos));
    // 监听解码/网络错误
    np.playbackEventStream.listen((event) {
      if (event.processingState == ProcessingState.error) {
        AppLog.e('PlayerController',
            '播放错误: ${event.androidAudioSessionId} state=error');
        _errorStream.add((-1, '播放错误，尝试切换音质重试'));
        _playState.add(false);
      }
    }, onError: (Object e, StackTrace st) {
      AppLog.e('PlayerController', 'playbackEventStream 错误: $e');
      _errorStream.add((-2, '播放器异常: $e'));
      _playState.add(false);
    });
    _player = np;
    return np;
  }

  Song? get currentSong => _currentSong;
  bool get isPlaying => _player?.playing ?? false;
  List<Song> get queue => List.unmodifiable(_queue);
  int get queueIndex => _queueIndex;

  /// 读取并应用持久化的默认播放音质。
  void loadDefaultQuality() {
    final saved = KvStore.instance.getString(_defaultQualityKey);
    currentQuality =
        Quality.fromCode(saved) ?? Quality.playbackDefault;
    final savedNe = KvStore.instance.getString(_neteaseQualityKey);
    currentNeteaseQuality = NeteaseQuality.fromLevel(savedNe) ??
        NeteaseQuality.playbackDefault;
  }

  /// 持久化 QQ 默认播放音质。
  void saveDefaultQuality(Quality quality) {
    currentQuality = quality;
    KvStore.instance.setString(_defaultQualityKey, quality.code);
  }

  /// 持久化网易云默认播放音质。
  void saveNeteaseQuality(NeteaseQuality quality) {
    currentNeteaseQuality = quality;
    KvStore.instance.setString(_neteaseQualityKey, quality.level);
  }

  /// 取播放直链并播放（带错误降级：QQ FLAC/AAC 解码失败时自动降到 128k MP3）。
  Future<void> play(Song song, String url) async {
    _currentSong = song;
    _songStream.add(song);
    try {
      await player.setUrl(url);
      await player.play();
    } on PlayerException catch (e) {
      AppLog.e('PlayerController', '播放失败(${e.code}): ${e.message}，尝试降级');
      _playState.add(false);
      _errorStream.add((e.code, '播放失败，尝试切换音质重试'));
      // QQ 非 128k：降级到 128k MP3
      if (!song.isNetease && currentQuality != Quality.mp3_128) {
        await _tryFallback(song, Quality.mp3_128);
      }
    } catch (e) {
      AppLog.e('PlayerController', '播放异常: $e');
      _playState.add(false);
      _errorStream.add((-1, '播放异常: $e'));
    }
  }

  /// 直接播放指定 URL（不更新歌曲信息）。
  Future<void> playUrl(String url) async {
    try {
      await player.setUrl(url);
      await player.play();
    } on PlayerException catch (e) {
      AppLog.e('PlayerController', 'playUrl 失败(${e.code}): ${e.message}');
      _errorStream.add((e.code, '播放失败: ${e.message}'));
      _playState.add(false);
    } catch (e) {
      AppLog.e('PlayerController', 'playUrl 异常: $e');
      _errorStream.add((-1, '播放异常: $e'));
      _playState.add(false);
    }
  }

  /// 播放队列（设置队列并从头播放）。
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
      // 直链获取失败则跳过
      _onTrackCompleted();
      return;
    }
    await play(first, url);
  }

  /// 下一首（队列存在时）。
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

  /// 上一首。
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
    final p = player;
    if (p.playing) {
      p.pause();
    } else {
      p.play();
    }
    _playState.add(p.playing);
  }

  Future<void> seek(Duration position) => player.seek(position);

  /// 主动触发一次状态刷新。
  void notifyState() {
    final p = _player;
    if (p != null) _playState.add(p.playing);
  }

  void release() {
    _player?.dispose();
    _player = null;
  }

  // ================= 内部 =================

  Future<String> _resolveUrl(Song song) =>
      MusicApi.playUrl(song, currentQuality, currentNeteaseQuality);

  /// QQ 降级重试：使用 128k MP3 音质重新取链播放。
  Future<void> _tryFallback(Song song, Quality fallback) async {
    try {
      final fallbackUrl = await MusicApi.playUrl(song, fallback, currentNeteaseQuality);
      if (fallbackUrl.isNotEmpty) {
        AppLog.i('PlayerController', '降级到 ${fallback.label} 重试: ${song.name}');
        await player.setUrl(fallbackUrl);
        await player.play();
      } else {
        _errorStream.add((-1, '该歌曲暂无可用播放链接'));
      }
    } catch (e) {
      AppLog.e('PlayerController', '降级重试失败: $e');
      _errorStream.add((-1, '降级重试失败'));
    }
  }

  void _onTrackCompleted() {
    if (_queue.isNotEmpty && _queueIndex < _queue.length - 1) {
      // 播放完成自动下一首
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
}