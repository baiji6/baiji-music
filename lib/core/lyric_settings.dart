import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'kv_store.dart';

/// 歌词显示偏好：字号 / 对齐 / 当前行放大 / 字重 / 卡片圆角 / 三色。
///
/// 用 [ChangeNotifier] 暴露，播放页的歌词视图监听它，
/// 拖动滑杆后无需重启即可实时看到变化。
class LyricSettings extends ChangeNotifier {
  LyricSettings._();

  static final LyricSettings instance = LyricSettings._();

  static const double minFontSize = 12.0;
  static const double maxFontSize = 30.0;

  /// 默认字号。v2.3.0-fix5 起对齐参考视频（AMLL 风格）：视频里一行歌词
  /// 几乎占满屏宽，对应 26~30px 量级；17px 在参考视频的尺度下小得看不清。
  /// 仍可在 12~30 范围调节。
  static const double defaultFontSize = 26.0;

  /// 当前行放大倍率的可调范围。1.0 表示不放大。
  static const double minActiveScale = 1.0;
  static const double maxActiveScale = 2.0;

  /// 默认只做**轻微**放大。
  ///
  /// 之前是 1.45（当前行明显大一号），但用户给的参考视频里所有行字号一致，
  /// 视觉层次几乎全靠颜色（当前行逐字填满、其余暗灰）建立。1.45 让当前行比相邻行
  /// 大出一大截，行距被撑开、整屏可见行数骤减，观感与参考不符。
  /// 1.12 保留一点点层次感，又不会喧宾夺主。
  static const double defaultActiveScale = 1.12;

  /// 字重可调范围。视频里当前行是粗体（约 w800），非当前行轻一档。
  static const int minWeight = 300;
  static const int maxWeight = 900;
  static const int defaultWeight = 800;

  /// 歌词卡片圆角可调范围（逻辑像素）。0 = 直角，铺满整屏。
  ///
  /// v2.3.0-fix5 起默认 0：歌词区换成 AMLL 风格的全幅模糊封面底，
  /// 参考视频里歌词直接铺在暗底上没有卡片边界。
  static const double minCorner = 0.0;
  static const double maxCorner = 40.0;
  static const double defaultCorner = 0.0;

  // 默认三色（深色主题下的取值；浅色主题由 AppPalette.light 提供，
  // 见 AppColors.karaoke / lyricUnsung / lyricInactive）：
  // 已唱 = 白色填充（AMLL 参考视频实测：逐字填充为纯白），
  // 当前行未唱 = 60% 白（灰），非当前行 = 40% 白。
  // 三者都可在设置里自定义，自定义后不再跟随主题。
  static const Color defaultSungColor = Color(0xFFFFFFFF);
  static const Color defaultUnsungColor = Color(0x99FFFFFF);
  static const Color defaultInactiveColor = Color(0x66FFFFFF);

  /// 是否左对齐默认值。参考视频（AMLL / QQ 音乐）均为左对齐，
  /// v2.3.0-fix5 起默认左对齐；用户仍可在样式面板切居中。
  static const bool defaultAlignLeft = true;

  /// 歌词画布底色（v2.3.0-fix6）。
  ///
  /// 歌词区是**恒暗画布**：不论 app 亮暗主题，歌词永远压在封面模糊 +
  /// 深色幕布上（参考视频与 AMLL / Apple Music 的标准形态）。三色的
  /// 默认值与可读性解析都按这块暗底走，与系统主题解耦。
  /// 取值与 AppPalette.dark.bg1 一致（const 上下文不能引用实例属性）。
  static const Color lyricCanvasBg = Color(0xFF0A0F1E);

  static const String _prefs = 'lyric_view';
  static const String _kFont = 'font_size';
  static const String _kAlign = 'align';
  static const String _kScale = 'active_scale';
  static const String _kWeight = 'weight';
  static const String _kCorner = 'corner';
  static const String _kSung = 'sung_color';
  static const String _kUnsung = 'unsung_color';
  static const String _kInactive = 'inactive_color';

  double _fontSize = defaultFontSize;
  bool _alignLeft = defaultAlignLeft;
  double _activeScale = defaultActiveScale;
  int _weight = defaultWeight;
  double _corner = defaultCorner;

  /// 用户自定义三色。null = 未自定义，跟随当前主题的默认色
  /// （[AppColors.karaoke] / [AppColors.lyricUnsung] / [AppColors.lyricInactive]）。
  Color? _sungCustom;
  Color? _unsungCustom;
  Color? _inactiveCustom;

  /// 歌词字号（逻辑像素）。
  double get fontSize => _fontSize;

  /// 当前行的放大倍率。主流行播放器都是「当前行明显更大」的观感，
  /// 1.0 等于不放大，2.0 会大到一屏放不下几行。
  double get activeScale => _activeScale;

  /// 是否左对齐；false 表示居中。
  bool get alignLeft => _alignLeft;

  /// 交给 [Text.textAlign] 的值。
  TextAlign get textAlign => _alignLeft ? TextAlign.left : TextAlign.center;

  /// 当前行字重（100 的整数倍，300~900）。
  int get weight => _weight;

  /// 非当前行字重：始终比当前行轻一档，形成层次但不过界。
  FontWeight get inactiveWeight {
    final w = (_weight - 300).clamp(300, 600);
    return FontWeight.values[(w / 100).round() - 1];
  }

  /// 当前行字重对应的 [FontWeight]。
  FontWeight get activeWeight =>
      FontWeight.values[(_weight / 100).round() - 1];

  /// 歌词卡片圆角半径（逻辑像素）。
  double get corner => _corner;

  /// 已唱色（逐字填充的目标色）。未自定义时恒取深色板
  /// （歌词区是恒暗画布，见 [lyricCanvasBg]，与 app 主题明暗无关）。
  Color get sungColor => _sungCustom ?? AppPalette.dark.karaoke;

  /// 当前行未唱色。未自定义时恒取深色板。
  Color get unsungColor => _unsungCustom ?? AppPalette.dark.lyricUnsung;

  /// 非当前行颜色。未自定义时恒取深色板。
  Color get inactiveColor => _inactiveCustom ?? AppPalette.dark.lyricInactive;

  // ===== 可读性保障（#80 逐行歌词高亮隐身回归 / v2.2.9-fix1 逐字染色回归） =====

  /// 深底上的亮字（内置纸色）。
  static const Color textOnDark = Color(0xFFF2F5FF);

  /// 浅底上的墨字（内置墨色）。
  static const Color inkOnLight = Color(0xFF12233F);

  /// 大号粗体文本的可读下限（WCAG 大字号下限）。
  static const double minReadableContrast = 3.0;

  /// [fg] 与 [bg] 的 WCAG 对比度。
  static double contrastOf(Color fg, Color bg) {
    final lf = fg.computeLuminance();
    final lb = bg.computeLuminance();
    return (math.max(lf, lb) + 0.05) / (math.min(lf, lb) + 0.05);
  }

  /// 确保 [fg] 在歌词背景 [AppColors.bg1] 上看得见；对比度不足时回退到
  /// 与背景明暗相对的内置墨色 / 纸色。
  ///
  /// 背景：三色是「深色主题下调的」就跟着深底走，可一旦切到浅色主题，
  /// 自定义的浅色字（典型：当前行白字）对比度会跌到约 1.5:1——
  /// **逐行歌词的当前行整个颜色就是未唱色**，直接隐身
  /// （用户视频实测：浅底上当前行 #D1D0D3 vs 背景 #FCFBFE）。
  /// 纯函数，便于单测。
  static Color ensureReadable(Color fg, Color bg) {
    final lb = bg.computeLuminance();
    return contrastOf(fg, bg) >= minReadableContrast
        ? fg
        : (lb > 0.5 ? inkOnLight : textOnDark);
  }

  /// 可读色解析（分主题三色统一入口）：
  ///
  /// 1. 自定义色可读 → 原样保留；
  /// 2. 不可读 → 回退**当前主题的默认色**（已唱=绿 / 未唱=墨或纸，
  ///    彼此天生不同色）；
  /// 3. 主题默认也不可读（莫奈取色产出怪色等）→ 墨/纸兜底。
  ///
  /// v2.2.9 首发的实现把不可读的三色**全部**兜到同一个墨/纸色——
  /// 逐字歌词的填充渐变两端（已唱/未唱）随之同色，卡拉 OK 染色整个
  /// 隐形（用户反馈：逐行好了逐字又没了）。分层回退保证已唱/未唱
  /// 永远拉开色差。
  static Color _resolveReadable(Color custom, Color themedFallback,
      {Color? bg}) {
    final b = bg ?? AppColors.bg1;
    if (contrastOf(custom, b) >= minReadableContrast) return custom;
    if (contrastOf(themedFallback, b) >= minReadableContrast) {
      return themedFallback;
    }
    return b.computeLuminance() > 0.5 ? inkOnLight : textOnDark;
  }

  /// [_resolveReadable] 的测试入口（注入背景色，绕过全局色板）。
  @visibleForTesting
  static Color resolveReadableForTest(
          Color custom, Color themedFallback, Color bg) =>
      _resolveReadable(custom, themedFallback, bg: bg);

  /// 当前行未唱色的可读版本（歌词区是恒暗画布，按 [lyricCanvasBg] 解析）。
  Color get readableUnsungColor =>
      _resolveReadable(unsungColor, AppPalette.dark.lyricUnsung,
          bg: lyricCanvasBg);

  /// 非当前行颜色的可读版本。
  Color get readableInactiveColor =>
      _resolveReadable(inactiveColor, AppPalette.dark.lyricInactive,
          bg: lyricCanvasBg);

  /// 已唱色的可读版本。
  ///
  /// 额外保证与解析后的未唱色**不同色**：两者相同时填充渐变两端一致，
  /// 逐字染色完全隐形。碰撞时强制用强调色（与任何白灰墨都不同色相）
  /// 拉开。
  /// v2.3.0-fix5：主题已唱色的默认值本身变成了白（AMLL 参考视频就是
  /// 白色填充），兜不住白/灰碰撞，因此逃逸目标从 karaoke 换成 accent。
  /// v2.3.0-fix6：按恒暗画布解析，逃逸色取深色板强调色（画布一致性）。
  Color get readableSungColor {
    final s = _resolveReadable(sungColor, AppPalette.dark.karaoke,
        bg: lyricCanvasBg);
    if (s == readableUnsungColor) {
      final escape = AppPalette.dark.accent;
      if (escape != s) return escape;
    }
    return s;
  }

  /// 应用启动时调用一次，从本地存储恢复设置。
  Future<void> load() async {
    await _migrateIfNeeded();
    final f = KvStore.instance.getString('$_prefs:$_kFont');
    final a = KvStore.instance.getString('$_prefs:$_kAlign');
    final sc = KvStore.instance.getString('$_prefs:$_kScale');
    final w = KvStore.instance.getString('$_prefs:$_kWeight');
    final c = KvStore.instance.getString('$_prefs:$_kCorner');
    final sung = KvStore.instance.getString('$_prefs:$_kSung');
    final unsung = KvStore.instance.getString('$_prefs:$_kUnsung');
    final inactive = KvStore.instance.getString('$_prefs:$_kInactive');
    _fontSize = (double.tryParse(f ?? '') ?? defaultFontSize)
        .clamp(minFontSize, maxFontSize);
    // v2.3.0-fix5 默认从居中改为左对齐：键不存在（从未设置过）时必须
    // 取新默认值，不能像旧代码那样把 null 等同于 'center'（旧默认）——
    // 否则老用户永远拿不到新默认的左对齐。
    _alignLeft = a == null ? defaultAlignLeft : (a == 'left');
    _activeScale = (double.tryParse(sc ?? '') ?? defaultActiveScale)
        .clamp(minActiveScale, maxActiveScale);
    _weight = (int.tryParse(w ?? '') ?? defaultWeight)
        .clamp(minWeight, maxWeight);
    _corner = (double.tryParse(c ?? '') ?? defaultCorner)
        .clamp(minCorner, maxCorner);
    _sungCustom = _parseColor(sung);
    _unsungCustom = _parseColor(unsung);
    _inactiveCustom = _parseColor(inactive);
    if (f == null &&
        a == null &&
        sc == null &&
        w == null &&
        c == null &&
        sung == null &&
        unsung == null &&
        inactive == null) {
      return; // 无需通知，还没有监听者
    }
    notifyListeners();
  }

  /// 设置结构版本。v2.3.0-fix6 起：fix5 对默认样式做过一次大改（字号
  /// 17→26、圆角 24→0、居中→左对齐、三色改 AMLL 白/灰），但老用户
  /// 本地持久化过**旧默认值**（用户曾碰过样式面板的任意控件就会把当时
  /// 的值写进存储），这些值会被误当成个人偏好，把新默认值全部压住——
  /// 表现为「升级后歌词还是旧样式」。迁移只处理与旧默认**完全相等**的
  /// 项（真正改过的保留），然后写版本号，永不再跑。
  static const String _kVersion = 'settings_version';
  static const int currentSettingsVersion = 1;

  /// fix4 及以前的默认值（迁移判定基准）。
  static const String _legacyFont = '17.0';
  static const String _legacyCorner = '24.0';
  static const String _legacyAlign = 'center';
  static const List<(String, String)> _legacyColors = [
    ('$_prefs:$_kSung', '#A8F685'), // 已唱 = 荧光黄绿
    ('$_prefs:$_kUnsung', '#F2F5FF'), // 未唱 = 亮白
    ('$_prefs:$_kInactive', '#5A6686'), // 非当前行 = 暗灰
  ];

  Future<void> _migrateIfNeeded() async {
    final ver = KvStore.instance.getInt('$_prefs:$_kVersion', def: 0);
    if (ver >= currentSettingsVersion) return;
    if (KvStore.instance.getString('$_prefs:$_kFont') == _legacyFont) {
      await KvStore.instance.remove('$_prefs:$_kFont');
    }
    if (KvStore.instance.getString('$_prefs:$_kCorner') == _legacyCorner) {
      await KvStore.instance.remove('$_prefs:$_kCorner');
    }
    if (KvStore.instance.getString('$_prefs:$_kAlign') == _legacyAlign) {
      await KvStore.instance.remove('$_prefs:$_kAlign');
    }
    for (final (key, legacy) in _legacyColors) {
      if (KvStore.instance.getString(key) == legacy) {
        await KvStore.instance.remove(key);
      }
    }
    await KvStore.instance.setInt('$_prefs:$_kVersion', currentSettingsVersion);
  }

  Future<void> setFontSize(double v) async {
    final next = v.clamp(minFontSize, maxFontSize);
    if (next == _fontSize) return;
    _fontSize = next;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kFont', next.toStringAsFixed(1));
  }

  Future<void> setActiveScale(double v) async {
    final next = v.clamp(minActiveScale, maxActiveScale);
    if (next == _activeScale) return;
    _activeScale = next;
    notifyListeners();
    await KvStore.instance
        .setString('$_prefs:$_kScale', next.toStringAsFixed(2));
  }

  Future<void> setAlignLeft(bool v) async {
    if (v == _alignLeft) return;
    _alignLeft = v;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kAlign', v ? 'left' : 'center');
  }

  Future<void> setWeight(int v) async {
    final next = v.clamp(minWeight, maxWeight);
    if (next == _weight) return;
    _weight = next;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kWeight', '$next');
  }

  Future<void> setCorner(double v) async {
    final next = v.clamp(minCorner, maxCorner);
    if (next == _corner) return;
    _corner = next;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kCorner', next.toStringAsFixed(1));
  }

  Future<void> setSungColor(Color c) async {
    if (c == sungColor) return;
    _sungCustom = c;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kSung', _colorToString(c));
  }

  Future<void> setUnsungColor(Color c) async {
    if (c == unsungColor) return;
    _unsungCustom = c;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kUnsung', _colorToString(c));
  }

  Future<void> setInactiveColor(Color c) async {
    if (c == inactiveColor) return;
    _inactiveCustom = c;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kInactive', _colorToString(c));
  }

  /// 三色一起恢复默认（设置面板的「恢复默认颜色」用）。
  ///
  /// 恢复的是「跟随主题」而不是写死深色三色——清掉自定义后，
  /// 浅色主题下歌词自动换成白底可读的深色系。
  Future<void> resetColors() async {
    _sungCustom = null;
    _unsungCustom = null;
    _inactiveCustom = null;
    notifyListeners();
    await KvStore.instance.remove('$_prefs:$_kSung');
    await KvStore.instance.remove('$_prefs:$_kUnsung');
    await KvStore.instance.remove('$_prefs:$_kInactive');
  }

  /// 测试专用：直接覆写已唱 / 未唱色，不走持久化（KvStore 在单测里
  /// 未必初始化）。逐字渲染的像素级测试用它固定红/蓝对比色。
  @visibleForTesting
  void setColorsForTest({Color? sung, Color? unsung}) {
    _sungCustom = sung;
    _unsungCustom = unsung;
    notifyListeners();
  }

  /// 系统明暗切换时由根组件调用：三色默认值已与主题解耦（恒暗画布），
  /// 通知只为让监听方（播放页歌词视图）在主题切换时统一重排一次。
  void notifyThemeChanged() => notifyListeners();

  /// `#RRGGBB` 十六进制串 → Color；非法输入返回 null（交给调用方用默认值）。
  static Color? _parseColor(String? hex) {
    if (hex == null) return null;
    final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(hex.trim());
    if (m == null) return null;
    return Color(int.parse(m.group(1)!, radix: 16) | 0xFF000000);
  }

  static String _colorToString(Color c) {
    final argb = c.toARGB32();
    final rgb = argb & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}
