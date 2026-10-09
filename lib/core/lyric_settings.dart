import 'package:flutter/material.dart';

import 'kv_store.dart';

/// 歌词显示偏好：字号 + 对齐方式。
///
/// 用 [ChangeNotifier] 暴露，播放页的歌词视图监听它，
/// 拖动滑杆后无需重启即可实时看到字号 / 对齐变化。
class LyricSettings extends ChangeNotifier {
  LyricSettings._();

  static final LyricSettings instance = LyricSettings._();

  static const double minFontSize = 12.0;
  static const double maxFontSize = 30.0;
  static const double defaultFontSize = 17.0;

  static const String _prefs = 'lyric_view';
  static const String _kFont = 'font_size';
  static const String _kAlign = 'align';

  double _fontSize = defaultFontSize;
  bool _alignLeft = false;

  /// 歌词字号（逻辑像素）。
  double get fontSize => _fontSize;

  /// 是否左对齐；false 表示居中。
  bool get alignLeft => _alignLeft;

  /// 交给 [Text.textAlign] 的值。
  TextAlign get textAlign => _alignLeft ? TextAlign.left : TextAlign.center;

  /// 应用启动时调用一次，从本地存储恢复设置。
  Future<void> load() async {
    final f = KvStore.instance.getString('$_prefs:$_kFont');
    final a = KvStore.instance.getString('$_prefs:$_kAlign');
    _fontSize = (double.tryParse(f ?? '') ?? defaultFontSize)
        .clamp(minFontSize, maxFontSize);
    _alignLeft = a == 'left';
    if (f == null && a == null) return; // 无需通知，还没有监听者
    notifyListeners();
  }

  Future<void> setFontSize(double v) async {
    final next = v.clamp(minFontSize, maxFontSize);
    if (next == _fontSize) return;
    _fontSize = next;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kFont', next.toStringAsFixed(1));
  }

  Future<void> setAlignLeft(bool v) async {
    if (v == _alignLeft) return;
    _alignLeft = v;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kAlign', v ? 'left' : 'center');
  }
}
