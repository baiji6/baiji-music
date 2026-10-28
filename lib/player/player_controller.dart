import 'dart:async';
import 'dart:math';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/telemetry.dart';
import 'package:baiji_music/local/local_scanner.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/kuwo/kuwo_link.dart';
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
  static const String _kuwoQualityKey = 'default_kuwo_quality';
  static const String _playModeKey = 'play_mode';
  static const String _rateKey = 'play_rate';

  Player? _player;
  Song? _currentSong;
  final List<Song> _queue = [];
  int _queueIndex = -1;

  Quality currentQuality = Quality.playbackDefault;
  NeteaseQuality currentNeteaseQuality = NeteaseQuality.playbackDefault;

  /// 酷我当前音质（v2.4.0）。
  KuwoQuality currentKuwoQuality = KuwoQuality.playbackDefault;

  // ===== 临时音质（v2.4.2 #141）=====
  //
  // 从**播放页**切音质只作用于当前这一首，不写偏好、不影响下一首；
  // 只有设置页才写偏好（saveXxxQuality）。之前 switchXxxQuality 直接落
  // preference，用户在播放页试听一档就把默认音质改掉了——这就是
  // 「播放页调音质污染默认偏好」。
  //
  // [_tempSong] 记录临时音质归属的曲目：换歌（play() 收到别的 song）
  // 时清空，同一首重取（切音质后的 _reResolve）则保留。
  Song? _tempSong;
  Quality? _tempQuality;
  NeteaseQuality? _tempNeteaseQuality;
  KuwoQuality? _tempKuwoQuality;

  /// 取流真正使用的 QQ 音质（临时覆盖优先于偏好）。
  Quality get effectiveQuality => _tempQuality ?? currentQuality;

  /// 取流真正使用的网易云音质。
  NeteaseQuality get effectiveNeteaseQuality =>
      _tempNeteaseQuality ?? currentNeteaseQuality;

  /// 取流真正使用的酷我音质。
  KuwoQuality get effectiveKuwoQuality =>
      _tempKuwoQuality ?? currentKuwoQuality;

  void _clearTempQuality() {
    _tempSong = null;
    _tempQuality = null;
    _tempNeteaseQuality = null;
    _tempKuwoQuality = null;
  }

  /// 当前曲目实际生效的 QQ 音质（可能与请求音质不同：服务端降级或本地自动降级）。
  Quality? _actualQqQuality;

  Quality? get actualQqQuality => _actualQqQuality;

  /// 当前曲目实际生效的网易云音质。
  NeteaseQuality? _actualNeQuality;

  NeteaseQuality? get actualNeteaseQuality => _actualNeQuality;

  /// 当前曲目实际生效的酷我音质。
  KuwoQuality? _actualKuwoQuality;

  KuwoQuality? get actualKuwoQuality => _actualKuwoQuality;

  PlayMode _playMode = PlayMode.sequential;
  PlayMode get playMode => _playMode;

  // ===== 倍速播放（0.01x ~ 50x 无级） =====

  /// 倍速下限。libmpv 的 speed 属性原生支持 0.01~100，
  /// 上限取用户要求的 50（再高已无听感意义且容易触发解码噪声）。
  static const double minRate = 0.01;
  static const double maxRate = 50.0;

  double _rate = 1.0;

  /// 当前倍速（记忆持久化，跨歌曲与重启生效）。
  double get rate => _rate;

  /// 倍率 → 滑杆位置 0~1（对数刻度）。
  ///
  /// 线性刻度下 1.0x 只占全程约 2% 行程，滑杆没法用；对数刻度让
  /// 1.0x 落在约 46% 处，低/高倍速两端都有足够的可调行程。
  static double rateToPos(double rate) {
    final r = rate.clamp(minRate, maxRate);
    return log(r / minRate) / log(maxRate / minRate);
  }

  /// 滑杆位置 0~1 → 倍率（对数刻度，[rateToPos] 的逆映射）。
  static double posToRate(double pos) =>
      minRate * pow(maxRate / minRate, pos.clamp(0.0, 1.0));

  final StreamController<double> _rateStream = StreamController.broadcast();

  /// 倍速变化（拖动滑杆 / 点预设时连续推送）。
  Stream<double> get onRateChanged => _rateStream.stream;

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

  /// 非致命提示流（v2.4.2）：自动降级、AC-4 跳过等 informational 通知。
  ///
  /// 与 [onError] 的分工：error 是「这条播放失败了」，notice 是
  /// 「我们替你换了一档，歌还在放」。UI 对 notice 用轻量 snackbar，
  /// 对 error 用错误样式。
  final StreamController<String> _noticeStream = StreamController.broadcast();
  Stream<String> get onNotice => _noticeStream.stream;

  // ===== AC-4 运行时防护（v2.4.2） =====

  /// 单曲 AC-4 自动降级次数预算。
  ///
  /// 取流层已按「已知 AC-4 档位」过滤（QQ D004、酷我 dolby_ac4），
  /// 这里是兜底：服务端 mislabel（请求可解码档却回 AC-4 文件）时，
  /// 靠 libmpv 轨道信息当场发现并重取。给 2 次是防服务端顽固——
  /// 第 3 次还拿到 AC-4 就认命报错，不死循环。
  static const int _maxAc4Retries = 2;

  /// 运行时探测结果：本机播放内核有 ac4 解码器（v2.4.2-pre4）。
  /// true 时 tracks 监听的 AC-4 兜底防护短路（正常播放不当异常）。
  bool _supportsAc4 = false;

  /// 本机是否编入了 baka Rust 版 AC-4 解码器（ac4_baka，v2.4.2-pre5）。
  /// true 时 jellyfin 版报错会先试切 `ad=ac4_baka` 重放，再走音质降级。
  bool _supportsAc4Baka = false;

  /// 本机是否编入了 AV3A（AVS3-P3 / 臻音全景声）解码器（v2.4.2-pre7）。
  /// 网易云 vivid 档（MP4 封装的 av3a 流）靠它解码；仅作链路诊断展示，
  /// 不参与降级逻辑（网易云没有针对 av3a 的不可解码硬编码）。
  bool _supportsAv3a = false;

  /// 供诊断面板 / 调试页展示解码器能力。
  bool get supportsAc4Baka => _supportsAc4Baka;
  bool get supportsAv3a => _supportsAv3a;

  /// 链路日志去重指纹（track id/codec/decoder 变了才打一条）。
  String _lastChainFingerprint = '';

  /// 本曲是否已试过 baka 解码器（每曲重置，与 _ac4Budget 同步）。
  bool _ac4BakaTried = false;

  int _ac4Budget = _maxAc4Retries;

  /// 上次 AC-4 降级的时间（tracks 与 error 两条信号可能同时触发，做去重）。
  DateTime? _lastAc4Retry;
  static const _ac4RetryCooldown = Duration(seconds: 3);

  /// QQ 音质实际生效值变化（供播放页显示"实际音质/已降级"）。
  final StreamController<Quality?> _qualityStream = StreamController.broadcast();
  Stream<Quality?> get onQualityChanged => _qualityStream.stream;

  /// 网易云音质实际生效值变化。
  final StreamController<NeteaseQuality?> _neQualityStream =
      StreamController.broadcast();
  Stream<NeteaseQuality?> get onNeteaseQualityChanged => _neQualityStream.stream;

  /// 酷我音质实际生效值变化（v2.4.0）。
  final StreamController<KuwoQuality?> _kuwoQualityStream =
      StreamController.broadcast();
  Stream<KuwoQuality?> get onKuwoQualityChanged => _kuwoQualityStream.stream;

  /// 播放模式变化。
  final StreamController<PlayMode> _modeStream = StreamController.broadcast();
  Stream<PlayMode> get onPlayModeChanged => _modeStream.stream;

  // ===== 初始化 =====

  void _ensurePlayer() {
    if (_player != null) return;
    _player = Player();

    // v2.4.2-pre4：运行时探测 AC-4 解码能力。
    //
    // v2.4.1 用的官方库里 ffmpeg 没编 ac4 解码器，当时把酷我 dolby_ac4 /
    // QQ D004 硬编码为「不可解码」做自动降级；v2.4.2 换了自编译库后
    // AC-4 是可解的，但硬编码集合还在——表现就是「杜比全景声永远放不出
    // 来（被自动切到别的音质）」。这里启动后查 mpv 的 decoder-list，
    // 探测到 ac4 就把硬编码集合清掉；探测失败保持保守（继续降级）。
    unawaited(Future(() async {
      try {
        final platform = _player!.platform;
        final raw = platform is NativePlayer
            ? await platform.getProperty('decoder-list')
            : '';
        final supportsAc4 = raw.contains('"ac4"') || raw.contains("'ac4'");
        final supportsBaka =
            raw.contains('ac4_baka') || raw.contains('Baka');
        final supportsAv3a =
            raw.contains('"av3a"') || raw.contains("'av3a'");
        AppLog.i('PlayerController',
            '运行时探测 AC-4 解码器: jellyfin=$supportsAc4 baka=$supportsBaka av3a=$supportsAv3a');
        if (supportsAc4) {
          Quality.undecodableCodes.clear();
          KuwoLink.undecodableIds.clear();
          _supportsAc4 = true;
        }
        _supportsAc4Baka = supportsBaka;
        _supportsAv3a = supportsAv3a;
      } catch (e) {
        AppLog.w('PlayerController', 'AC-4 解码器探测失败（保持保守降级）: $e');
      }
    }));

    // v2.2.9-fix2：显式配置变速音频滤镜。
    //
    // libmpv 0.38+ 变速走 scaletempo2 滤镜，其默认 **max-speed=4**——
    // 超过 4 倍速时音频直接静音（用户反馈「选择倍速播放后没有声音」，
    // 点 5.0x 预设必现）。放宽到 0.01 ~ 50 全区间；旧版 mpv 没有
    // scaletempo2 滤镜时这条 setProperty 失败被吞掉，回落默认行为
    // （自动 scaletempo，本身不限速，同样不出问题）。
    //
    // media_kit 的 setRate（pitch 配置关闭时）只写 `speed` 属性、
    // 不覆盖 `af`，这里的配置对整个播放周期有效。
    unawaited(Future(() async {
      try {
        final p = _player!.platform;
        if (p is NativePlayer) {
          await p.setProperty(
              'af', 'scaletempo2=min-speed=0.01:max-speed=50');
          AppLog.i('PlayerController', 'scaletempo2 变速滤镜已配置（0.01~50x）');
        }
      } catch (e) {
        AppLog.w('PlayerController', '配置变速滤镜失败（回落默认）: $e');
      }
    }));

    // native 边界回调统一包 try-catch：media_kit 在 release 下回调里抛出的
    // 异常（典型为 null check）会冒泡成 FATAL 闪退，这里降级为 ERROR 日志。
    _player!.stream.playing.listen((playing) {
      try {
        _playState.add(playing);
      } catch (e, s) {
        AppLog.e('PlayerController', 'playing 回调异常: $e\n$s');
      }
    });

    _player!.stream.completed.listen((completed) {
      try {
        if (completed) {
          _onTrackCompleted();
        }
      } catch (e, s) {
        AppLog.e('PlayerController', 'completed 回调异常: $e\n$s');
      }
    });

    _player!.stream.position.listen((position) {
      try {
        _positionStream.add(position);
      } catch (e, s) {
        AppLog.e('PlayerController', 'position 回调异常: $e\n$s');
      }
    });

    _player!.stream.duration.listen((duration) {
      try {
        _durationStream.add(duration);
      } catch (e, s) {
        AppLog.e('PlayerController', 'duration 回调异常: $e\n$s');
      }
    });

    _player!.stream.error.listen((error) {
      try {
        AppLog.e('PlayerController', 'media_kit 错误: $error');
        // AC-4 第二信号：部分容器/旧 mpv 下轨道信息不全，直接报解码器
        // 缺失，消息里会带 codec 名。命中则走降级，不再向 UI 抛错误。
        if (error.toLowerCase().contains('ac4')) {
          // 注意：这里不做 _supportsAc4 短路——探测成功后若仍出现
          // 含 ac4 的 error（如特定 profile 初始化失败），是真故障信号，
          // 降级兜底仍然正确。
          _onAc4Detected('error: $error');
          return;
        }
        _errorStream.add('播放错误: $error');
        _playState.add(false);
      } catch (e, s) {
        AppLog.e('PlayerController', 'error 回调异常: $e\n$s');
      }
    });

    // v2.4.2：libmpv 轨道列表回调——AC-4 兜底检测的第一信号。
    // avformat 在解容器阶段就能报出 codec，即使没有解码器，
    // track-list 里依然带着 codec=ac4，比等 error 更早也更可靠。
    _player!.stream.tracks.listen((tracks) {
      try {
        // v2.4.2-pre5：完整播放链路日志——用的什么解码器一目了然。
        // （track.decoder 是 mpv 的 decoder-desc：如 jellyfin 移植版是
        // 「AC-4 (ATSC 3.0)」、baka Rust 版是「AC-4 (Baka Rust decoder)」。）
        final t = tracks.audio.isNotEmpty ? tracks.audio.first : null;
        if (t != null) {
          final fp = '${t.id}|${t.codec}|${t.decoder}|${t.channelscount}';
          if (fp != _lastChainFingerprint) {
            _lastChainFingerprint = fp;
            final ap = _player?.state.audioParams;
            AppLog.i('PlayerController',
                '播放链路: codec=${t.codec ?? '?'} 解码器=${t.decoder ?? '?'} '
                '${t.samplerate ?? ap?.sampleRate ?? '?'}Hz '
                '${t.channelscount ?? '?'}ch(${t.channels ?? '?'})');
            unawaited(Future(() async {
              try {
                final platform = _player?.platform;
                if (platform is NativePlayer) {
                  final ao = await platform.getProperty('current-ao');
                  AppLog.i('PlayerController', '播放链路: 音频输出 AO=$ao');
                }
              } catch (_) {}
            }));
          }
        }
        if (_supportsAc4) {
          // v2.4.2-pre4：运行时探测已确认本机有 ac4 解码器——track 里
          // 出现 codec=ac4 是**正常播放**，不是异常信号，直接放行。
          // （pre4 首版实测：探测成功后这里仍把正常 AC-4 播放降级，
          // 表现为「杜比全景声每次都被自动切换到别的音质」。）
          return;
        }
        final hasAc4 = tracks.audio
            .any((t) => (t.codec ?? '').toLowerCase().contains('ac4'));
        if (hasAc4) _onAc4Detected('tracks codec=ac4');
      } catch (e, s) {
        AppLog.e('PlayerController', 'tracks 回调异常: $e\n$s');
      }
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
    if (url.trim().isEmpty) {
      AppLog.w('PlayerController', '播放链接为空，已跳过 open');
      _errorStream.add('播放链接为空');
      _playState.add(false);
      return;
    }
    try {
      await _player!.open(Media(url));
      await _player!.play();
      // open() 会把 libmpv 的 speed 重置回 1.0（media_kit 默认参数），
      // 每次开播后必须重放记忆倍速，否则切歌后倍速悄悄丢掉。
      if (_rate != 1.0) {
        try {
          await _player!.setRate(_rate);
        } catch (e) {
          AppLog.w('PlayerController', '恢复倍速失败: $e');
        }
      }
      AppLog.i('PlayerController', '播放: $url');
    } catch (e) {
      AppLog.e('PlayerController', '播放失败: $e');
      _errorStream.add('播放失败: $e');
      _playState.add(false);
    }
  }

  Future<void> play(Song song, String url) async {
    // 每次开播重置 AC-4 降级预算（v2.4.2）。play() 是所有曲目启动的
    // 唯一入口（playQueue/_playAt/切歌/单曲循环重播都汇到这里），在
    // 这里重置最稳；内部降级重试走 _playUrlInternal，不经过这里，
    // 不会把预算半路刷满。注意不能拿 _currentSong 做 identical 判断——
    // 调用方都是先赋 _currentSong 再进 play()，那样恒真、永不重置。
    _ac4Budget = _maxAc4Retries;
    _ac4BakaTried = false;
    _lastAc4Retry = null;
    // 换了别的曲目 → 播放页临时音质作废（只影响同一首，见 _tempSong 注释）。
    // 注意：不能拿 _currentSong 比较——调用方都是先赋 _currentSong 再进
    // play()，那样恒真、永不清空。
    //
    // 注意用的是「不等于归属曲目就清」而不是「归属为空才保留」：
    // _tempSong 为 null（切音质时还没有当前曲目）时，临时档同样不该
    // 带到下一首。
    if (!identical(_tempSong, song)) {
      _clearTempQuality();
    }
    _currentSong = song;
    _songStream.add(song);
    await _playUrlInternal(url);
  }

  /// AC-4 兜底命中（v2.4.2）：预算内则换一档可解码音质重取，保留播放位置。
  ///
  /// 触发源有两个：tracks 里的 codec=ac4（主信号，解容器即知），
  /// mpv 报解码器缺失的 error 消息（备信号）。两条可能同时到达，
  /// 用冷却时间去重；预算耗尽则报错放弃，不死循环。
  void _onAc4Detected(String source) {
    final now = DateTime.now();
    if (_lastAc4Retry != null &&
        now.difference(_lastAc4Retry!) < _ac4RetryCooldown) {
      return;
    }
    final song = _currentSong;
    if (song == null) return;

    // v2.4.2-pre5：双解码器共存——jellyfin 版（ac4）解不了的流，先试
    // baka Rust 版（ac4_baka）换解码器重放，都失败才降音质。
    if (source.startsWith('error:') &&
        _supportsAc4Baka &&
        !_ac4BakaTried) {
      _ac4BakaTried = true;
      AppLog.w('PlayerController',
          'AC-4 解码报错（$source），切换到 baka Rust 解码器重试');
      if (!_noticeStream.isClosed) {
        _noticeStream.add('AC-4 解码失败，已切换备用解码器重试');
      }
      unawaited(Future(() async {
        try {
          final platform = _player?.platform;
          if (platform is NativePlayer) {
            await platform.setProperty('ad', 'ac4_baka,ac4');
          }
          final song2 = _currentSong;
          if (song2 != null) {
            final url = await _resolveUrl(song2);
            if (url.isNotEmpty) await _playUrlInternal(url);
          }
        } catch (e) {
          AppLog.w('PlayerController', 'baka 解码器重试失败: $e');
        }
      }));
      return;
    }

    if (_ac4Budget <= 0) {
      AppLog.e('PlayerController', 'AC-4 降级预算已用完（$source），放弃重试');
      _errorStream.add('该曲目的杜比全景声(AC-4)本机暂不支持播放');
      _playState.add(false);
      return;
    }
    _ac4Budget--;
    _lastAc4Retry = now;
    AppLog.w('PlayerController',
        '检测到 AC-4 音轨（$source），自动降级重试（剩余 $_ac4Budget 次）');
    if (!_noticeStream.isClosed) {
      _noticeStream.add('「杜比全景声(AC-4)」本机暂不支持，已自动切换到可播放音质');
    }
    _downgradeAndReplay(song);
  }

  /// 跳过当前这档，沿降级链重取并续播（保留位置，v2.4.2）。
  ///
  /// 只改本次播放链路，**不写偏好**——用户的默认音质选择不受影响
  /// （与 #141「播放页调音质不污染默认偏好」同一原则）。
  Future<void> _downgradeAndReplay(Song song) async {
    final pos = position;
    final url = await _resolveUrl(song, skipCurrent: true);
    if (url.isEmpty) {
      _errorStream.add('该歌曲没有可用的备用音质');
      _playState.add(false);
      return;
    }
    await _playUrlInternal(url);
    if (pos > Duration.zero) await seek(pos);
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
    // 暂停时 libmpv 不会持续推送 position，靠 seek 事件补一次主动广播，
    // 否则「暂停时点击歌词跳转」后进度条 / 歌词视图停在旧位置不动。
    // 播放时底层自己也会推，重复推送对订阅方是幂等的（只更新基准）。
    _positionStream.add(_player!.state.position);
  }

  void notifyState() {
    if (_player != null) {
      _playState.add(_player!.state.playing);
    }
  }

  // ===== 倍速控制 =====

  /// 设置播放倍速（0.01~50 无级），持久化并广播。
  ///
  /// 播放器未创建时只记值——[_playUrlInternal] 开播后会重放记忆倍速。
  Future<void> setRate(double r) async {
    final clamped = r.clamp(minRate, maxRate);
    if (clamped == _rate && _player == null) return;
    _rate = clamped;
    KvStore.instance.setString(_rateKey, clamped.toStringAsFixed(4));
    if (!_rateStream.isClosed) _rateStream.add(clamped);
    final p = _player;
    if (p != null) {
      try {
        await p.setRate(clamped);
      } catch (e) {
        AppLog.w('PlayerController', '设置倍速失败: $e');
      }
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
  ///
  /// [skipCurrent]（v2.4.2 AC-4 兜底）：从**当前实际生效档的下一档**开始，
  /// 避免运行时发现 AC-4 后又拿到同一条链接。仅由 [_downgradeAndReplay]
  /// 使用，正常取流不走这条路。
  Future<String> _resolveUrl(Song song, {bool skipCurrent = false}) async {
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

    // 酷我（v2.4.0）：音质降级链在 [KuwoApi.playUrlWithFallback] 内部处理，
    // 这里只需要带当前选中的酷我音质即可。
    if (song.isKuwo) {
      var q = effectiveKuwoQuality;
      if (skipCurrent) {
        q = _actualKuwoQuality ?? q;
        // 沿规则表往下找第一档可解码的（跳过刚放不出的那档）
        KuwoQuality? next;
        for (final r in KuwoLink.downgradeRules(q.id).skip(1)) {
          final id = r[2] as String;
          if (KuwoLink.undecodableIds.contains(id)) continue;
          next = KuwoQuality.fromId(id);
          if (next != null) break;
        }
        if (next == null) {
          AppLog.w('PlayerController', '酷我 AC-4 降级：没有更低的可用档');
          _clearActual();
          return '';
        }
        q = next;
      }
      final r = await _fetch(song, effectiveQuality, effectiveNeteaseQuality,
          kuwo: q);
      if (r.isNotEmpty) {
        _applyActual(r);
        _reportPlay(song, r);
        return r.url;
      }
      _clearActual();
      return '';
    }

    // AC-4 兜底重取时以「实际生效档」为起点；正常取流以偏好为起点
    // （避免某首歌的服务端降级黏到下首歌）。
    final startQq =
        skipCurrent ? (_actualQqQuality ?? effectiveQuality) : effectiveQuality;
    final startNe = skipCurrent
        ? (_actualNeQuality ?? effectiveNeteaseQuality)
        : effectiveNeteaseQuality;

    final chain = song.isNetease
        ? MusicApi.neteaseDowngradeChain(startNe)
            .map((q) => _FetchPlan(qq: startQq, ne: q))
            .toList()
        : MusicApi.qqDowngradeChain(startQq)
            .map((q) => _FetchPlan(qq: q, ne: startNe))
            .toList();
    // 跳过当前档（AC-4 兜底）：链首即刚放不出的那一档
    if (skipCurrent && chain.length > 1) chain.removeAt(0);

    for (var i = 0; i < chain.length; i++) {
      final plan = chain[i];
      final r = await _fetch(song, plan.qq, plan.ne);
      if (r.isNotEmpty) {
        if (i > 0) {
          AppLog.i('PlayerController', '降级成功 -> ${r.label}');
        }
        _applyActual(r);
        _reportPlay(song, r);
        return r.url;
      }
      AppLog.w('PlayerController',
          '${song.name} 的 ${song.isNetease ? plan.ne.label : plan.qq.label} 不可用，尝试降级');
    }

    _clearActual();
    return '';
  }

  /// 单次取流，异常统一吞掉（降级链需要继续往下走）。
  Future<PlayUrlResult> _fetch(Song song, Quality qq, NeteaseQuality ne,
      {KuwoQuality? kuwo}) async {
    try {
      return await MusicApi.playUrlInfo(song, qq, ne, kuwoQuality: kuwo);
    } catch (e) {
      AppLog.w('PlayerController', '取流异常: $e');
      return PlayUrlResult.empty;
    }
  }

  /// 上报播放行为（GUID / 平台 / 歌曲 / 音质 / 播放链接，v2.4.0）。
  ///
  /// 只上报网络音源；本地文件不上报（不涉及任何平台信息）。
  void _reportPlay(Song song, PlayUrlResult r) {
    if (song.isLocal) return;
    Telemetry.instance.playSong(song, quality: r.label, playUrl: r.url);
  }

  /// 记录实际生效音质并广播。
  void _applyActual(PlayUrlResult r) {
    _actualQqQuality = r.qq;
    _actualNeQuality = r.ne;
    _actualKuwoQuality = r.kuwo;
    if (!_qualityStream.isClosed) _qualityStream.add(_actualQqQuality);
    if (!_neQualityStream.isClosed) _neQualityStream.add(_actualNeQuality);
    if (!_kuwoQualityStream.isClosed) _kuwoQualityStream.add(_actualKuwoQuality);
  }

  void _clearActual() {
    _actualQqQuality = null;
    _actualNeQuality = null;
    _actualKuwoQuality = null;
    if (!_qualityStream.isClosed) _qualityStream.add(null);
    if (!_neQualityStream.isClosed) _neQualityStream.add(null);
    if (!_kuwoQualityStream.isClosed) _kuwoQualityStream.add(null);
  }

  // ===== 播放页切音质（v2.4.2 #141：只作用于当前曲目，不写偏好）=====
  //
  // 与 [saveDefaultQuality] / [saveNeteaseQuality] / [saveKuwoQuality] 的
  // 区别：那三个是设置页入口，落 preference；这三个只设临时覆盖，
  // 换歌即失效。

  /// 播放页切换 QQ 音质并重新取流（保留播放位置）。
  Future<void> switchQuality(Quality q) async {
    _tempSong = _currentSong;
    _tempQuality = q;
    await _reResolve(q.label);
  }

  /// 播放页切换网易云音质并重新取流（保留播放位置）。
  Future<void> switchNeteaseQuality(NeteaseQuality q) async {
    _tempSong = _currentSong;
    _tempNeteaseQuality = q;
    await _reResolve(q.label);
  }

  /// 播放页切换酷我音质并重新取流（保留播放位置，v2.4.0）。
  Future<void> switchKuwoQuality(KuwoQuality q) async {
    _tempSong = _currentSong;
    _tempKuwoQuality = q;
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
    final savedKuwo = KvStore.instance.getString(_kuwoQualityKey);
    currentKuwoQuality =
        KuwoQuality.fromId(savedKuwo) ?? KuwoQuality.playbackDefault;

    final savedMode = KvStore.instance.getString(_playModeKey);
    if (savedMode != null) {
      _playMode = PlayMode.values.firstWhere(
        (m) => m.name == savedMode,
        orElse: () => PlayMode.sequential,
      );
    }

    final savedRate = KvStore.instance.getString(_rateKey);
    if (savedRate != null) {
      final r = double.tryParse(savedRate);
      if (r != null) _rate = r.clamp(minRate, maxRate);
    }
  }

  /// 设置页保存 QQ 默认音质偏好。
  ///
  /// 同时清掉播放页的临时覆盖——否则用户在设置页改了默认，当前这首
  /// 仍按旧临时档走，看起来「改了没生效」。
  void saveDefaultQuality(Quality quality) {
    currentQuality = quality;
    _tempQuality = null;
    KvStore.instance.setString(_defaultQualityKey, quality.code);
  }

  /// 设置页保存网易云默认音质偏好。
  void saveNeteaseQuality(NeteaseQuality quality) {
    currentNeteaseQuality = quality;
    _tempNeteaseQuality = null;
    KvStore.instance.setString(_neteaseQualityKey, quality.level);
  }

  /// 设置页保存酷我默认音质偏好（v2.4.0，v2.4.2 起设置页可选）。
  void saveKuwoQuality(KuwoQuality quality) {
    currentKuwoQuality = quality;
    _tempKuwoQuality = null;
    KvStore.instance.setString(_kuwoQualityKey, quality.id);
  }
}

/// 一次取流尝试的音质组合（QQ/网易云二选一生效，另一个传当前偏好占位）。
class _FetchPlan {
  const _FetchPlan({required this.qq, required this.ne});

  final Quality qq;
  final NeteaseQuality ne;
}
