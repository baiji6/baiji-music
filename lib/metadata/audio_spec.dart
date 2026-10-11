/// 音频规格：采样率 / 比特率 / 声道数 / 容器与编码。
///
/// 两条来源，按可用性择优：
/// 1. **本地文件**——用 [AudioReader] 直接读文件头。离线、稳定，
///    并且在播放前就能拿到（打开规格面板不用等）；
/// 2. **在线流**——本地没有这个文件，只能问解码器。media_kit 基于 libmpv，
///    [media_kit.Player.state] 的 `track.audio` 里带 `samplerate` /
///    `channelscount` / `codec`，`audioBitrate` 单独给码率。
///
/// 拿不到就留空——**绝不编造**。显示「未知」比显示错的值诚实。
library;

import '../core/app_logger.dart';
import 'audio_reader.dart';
import '../player/player_controller.dart';

/// 一条可展示的规格项。
class AudioSpecItem {
  const AudioSpecItem(this.label, this.value);

  final String label;
  final String value;
}

/// 规格数据。字段为空表示**没解析出来**，不要用 0 或默认值糊弄。
class AudioSpec {
  const AudioSpec({
    this.sampleRate,
    this.bitrateKbps,
    this.channels,
    this.container = '',
    this.codec = '',
    this.qualityLabel = '',
  });

  /// 采样率（Hz）。
  final int? sampleRate;

  /// 比特率（kbps）。
  final int? bitrateKbps;

  /// 声道数。1 单声道 / 2 立体声 / 6 5.1…
  final int? channels;

  /// 容器格式：mp3 / flac / m4a / ogg / wav。
  final String container;

  /// 编码名：mp3 / flac / aac / alac / opus / vorbis / pcm。
  final String codec;

  /// 在线音质档的原始描述（如「SQ 无损」「极高 320k」）。
  final String qualityLabel;

  bool get isEmpty =>
      sampleRate == null &&
      bitrateKbps == null &&
      channels == null &&
      container.isEmpty &&
      codec.isEmpty &&
      qualityLabel.isEmpty;

  /// 采样率 → "44.1 kHz"（去掉无意义的 ".0"）。
  String get sampleRateText {
    final sr = sampleRate;
    if (sr == null || sr <= 0) return '未知';
    final khz = sr / 1000.0;
    final s = khz == khz.roundToDouble()
        ? khz.toStringAsFixed(0)
        : khz.toStringAsFixed(1);
    return '$s kHz';
  }

  String get bitrateText {
    final br = bitrateKbps;
    if (br == null || br <= 0) return '未知';
    return '$br kbps';
  }

  /// 声道 → "立体声" / "单声道" / "5.1"；非标准值直接报数字。
  String get channelsText {
    final ch = channels;
    if (ch == null || ch <= 0) return '未知';
    return switch (ch) {
      1 => '单声道',
      2 => '立体声',
      6 => '5.1 环绕',
      8 => '7.1 环绕',
      _ => '$ch 声道',
    };
  }

  String get containerText => container.isEmpty ? '未知' : container.toUpperCase();

  String get codecText => codec.isEmpty ? '未知' : codec.toUpperCase();

  /// 展示成规格面板里的条目列表；没解析到的项**不出现**。
  List<AudioSpecItem> get items => [
        AudioSpecItem('采样率', sampleRateText),
        AudioSpecItem('比特率', bitrateText),
        AudioSpecItem('声道', channelsText),
        if (container.isNotEmpty) AudioSpecItem('容器格式', containerText),
        if (codec.isNotEmpty) AudioSpecItem('编码', codecText),
        if (qualityLabel.isNotEmpty)
          AudioSpecItem('音质档', qualityLabel),
      ];
}

/// 规格解析入口。
class AudioSpecService {
  AudioSpecService._();

  /// 本地文件路径的解析结果缓存。
  ///
  /// 同一首歌被反复打开规格面板时不必每次重读文件头——
  /// 这些值不会变，缓存起来省掉一次文件 IO。
  static final Map<String, AudioSpec> _fileCache = {};

  /// 取当前播放歌曲的规格。
  static Future<AudioSpec> ofCurrent() async {
    final player = PlayerController.instance;
    final song = player.currentSong;
    if (song == null) return const AudioSpec();

    // 本地歌曲：直接读文件，最准也最省。
    if (song.isLocal) {
      final local = await _fromLocalFile(song.localPath);
      return local.isEmpty ? _fromPlayer(player) : _merge(local, _fromPlayer(player));
    }

    // 在线流：文件读不到，只能问解码器；音质档标签我们自己是知道的。
    return _merge(_fromPlayer(player), _qualityOnly(player));
  }

  /// 本地文件的规格（带缓存）。
  static Future<AudioSpec> _fromLocalFile(String path) async {
    if (path.isEmpty) return const AudioSpec();
    final hit = _fileCache[path];
    if (hit != null) return hit;
    try {
      final m = await AudioReader.read(path, withCover: false);
      final spec = AudioSpec(
        sampleRate: m.sampleRate > 0 ? m.sampleRate : null,
        bitrateKbps: m.bitrate > 0 ? m.bitrate : null,
        channels: m.channels > 0 ? m.channels : null,
        container: m.format,
        codec: m.codec,
      );
      // 限制缓存规模，避免长时间播放把内存吃掉
      if (_fileCache.length > 64) _fileCache.clear();
      _fileCache[path] = spec;
      return spec;
    } catch (e) {
      AppLog.w('AudioSpec', '读取本地音频规格失败: $e');
      return const AudioSpec();
    }
  }

  /// 从解码器（libmpv）取规格。在线流的唯一可靠来源。
  static AudioSpec _fromPlayer(PlayerController ctl) {
    try {
      final p = ctl.player;
      if (p == null) return const AudioSpec();

      final audio = p.state.track.audio;
      // audioBitrate 是 double 且单位 kbps；没解复用出来时为 null。
      final br = p.state.audioBitrate;
      return AudioSpec(
        sampleRate: audio.samplerate,
        bitrateKbps: (br != null && br > 0) ? br.round() : null,
        channels: audio.channelscount,
        // libmpv 给的 codec 形如 "aac" / "flac" / "mp3" / "opus"
        codec: (audio.codec ?? '').trim(),
      );
    } catch (e) {
      AppLog.w('AudioSpec', '读取解码器音频规格失败: $e');
      return const AudioSpec();
    }
  }

  /// 在线歌曲的音质档描述。
  ///
  /// 用的是**实际生效**的音质（`actualQqQuality`），不是请求的那个——
  /// 服务端降级或本地自动降级之后，两者可能不一样，展示后者会误导人。
  static AudioSpec _qualityOnly(PlayerController ctl) {
    final song = ctl.currentSong;
    if (song == null || song.isLocal) return const AudioSpec();
    final label = song.isNetease
        ? (ctl.actualNeteaseQuality?.label ?? '')
        : (ctl.actualQqQuality?.label ?? '');
    if (label.isEmpty) return const AudioSpec();
    return AudioSpec(qualityLabel: label);
  }

  /// 两个来源合并：base 为主，缺失的字段用 fallback 补。
  static AudioSpec _merge(AudioSpec base, AudioSpec fallback) {
    if (fallback.isEmpty) return base;
    return AudioSpec(
      sampleRate: base.sampleRate ?? fallback.sampleRate,
      bitrateKbps: base.bitrateKbps ?? fallback.bitrateKbps,
      channels: base.channels ?? fallback.channels,
      container: base.container.isNotEmpty ? base.container : fallback.container,
      codec: base.codec.isNotEmpty ? base.codec : fallback.codec,
      qualityLabel: base.qualityLabel.isNotEmpty
          ? base.qualityLabel
          : fallback.qualityLabel,
    );
  }
}
