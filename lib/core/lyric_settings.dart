import 'package:flutter/material.dart';

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
  static const double defaultFontSize = 17.0;

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
  static const double minCorner = 0.0;
  static const double maxCorner = 40.0;
  static const double defaultCorner = 24.0;

  // 默认三色：已唱 = 荧光黄绿（参考视频实测色值），当前行未唱 = 亮白，
  // 非当前行 = 暗灰。三者都可在设置里自定义。
  static const Color defaultSungColor = Color(0xFFA8F685);
  static const Color defaultUnsungColor = Color(0xFFF2F5FF);
  static const Color defaultInactiveColor = Color(0xFF5A6686);

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
  bool _alignLeft = false;
  double _activeScale = defaultActiveScale;
  int _weight = defaultWeight;
  double _corner = defaultCorner;
  Color _sungColor = defaultSungColor;
  Color _unsungColor = defaultUnsungColor;
  Color _inactiveColor = defaultInactiveColor;

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

  /// 已唱色（逐字填充的目标色）。
  Color get sungColor => _sungColor;

  /// 当前行未唱色。
  Color get unsungColor => _unsungColor;

  /// 非当前行颜色。
  Color get inactiveColor => _inactiveColor;

  /// 应用启动时调用一次，从本地存储恢复设置。
  Future<void> load() async {
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
    _alignLeft = a == 'left';
    _activeScale = (double.tryParse(sc ?? '') ?? defaultActiveScale)
        .clamp(minActiveScale, maxActiveScale);
    _weight = (int.tryParse(w ?? '') ?? defaultWeight)
        .clamp(minWeight, maxWeight);
    _corner = (double.tryParse(c ?? '') ?? defaultCorner)
        .clamp(minCorner, maxCorner);
    _sungColor = _parseColor(sung) ?? defaultSungColor;
    _unsungColor = _parseColor(unsung) ?? defaultUnsungColor;
    _inactiveColor = _parseColor(inactive) ?? defaultInactiveColor;
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
    if (c == _sungColor) return;
    _sungColor = c;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kSung', _colorToString(c));
  }

  Future<void> setUnsungColor(Color c) async {
    if (c == _unsungColor) return;
    _unsungColor = c;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kUnsung', _colorToString(c));
  }

  Future<void> setInactiveColor(Color c) async {
    if (c == _inactiveColor) return;
    _inactiveColor = c;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kInactive', _colorToString(c));
  }

  /// 三色一起恢复默认（设置面板的「恢复默认颜色」用）。
  Future<void> resetColors() async {
    await setSungColor(defaultSungColor);
    await setUnsungColor(defaultUnsungColor);
    await setInactiveColor(defaultInactiveColor);
  }

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
