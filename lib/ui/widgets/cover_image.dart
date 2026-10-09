import 'package:flutter/material.dart';

import '../../core/cover_url.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';
import 'app_widgets.dart';

/// 智能封面：按「最大分辨率优先」逐级降级加载。
///
/// 两个音源的封面都支持按参数取不同尺寸，但**上限不同**：
/// - QQ：`T002R1500x1500…` 是最大档，请求 2000 / 3000 会 404；
/// - 网易云：`?param=3000y3000` 是最大档，CDN 会在原图分辨率处自动截断。
///
/// 因此这里一次性取 [CoverUrl.candidates]（最大 → 最小），
/// 用 `errorBuilder` 在**真正加载失败**时才往下试一级。
/// 好处是：能拿到原图就拿原图，拿不到也不会留白（末级仍失败则显示渐变占位）。
class CoverImage extends StatefulWidget {
  const CoverImage({
    super.key,
    required this.song,
    required this.size,
    this.radius,
    this.fit = BoxFit.cover,
    this.memCacheWidth,
  });

  final Song song;
  final double size;

  /// 圆角；为空时按 `size * 0.18` 自适应（与 [GradientCover] 一致）。
  final double? radius;
  final BoxFit fit;

  /// 解码缓存宽度（像素）。大封面（如 1500）在列表里按 2~3 倍屏宽解码即可，
  /// 避免整张原图进内存。
  final int? memCacheWidth;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  List<String> _candidates = const <String>[];
  int _index = 0;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(covariant CoverImage old) {
    super.didUpdateWidget(old);
    if (old.song.mid != widget.song.mid ||
        old.song.cover != widget.song.cover ||
        old.song.albumMid != widget.song.albumMid) {
      _reset();
    }
  }

  void _reset() {
    _candidates = CoverUrl.candidates(widget.song);
    _index = 0;
    _scheduled = false;
  }

  /// 加载失败：切到下一档。必须延到帧后再 setState（errorBuilder 处于 build 阶段）。
  void _fallback() {
    if (_scheduled) return;
    if (_index + 1 >= _candidates.length) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      setState(() => _index++);
    });
  }

  Widget _placeholder() => GradientCover(
        size: widget.size,
        gradient: widget.song.isNetease
            ? const <Color>[AppColors.magenta, AppColors.violet]
            : AppColors.accentGradient,
      );

  @override
  Widget build(BuildContext context) {
    if (_candidates.isEmpty) return _placeholder();
    final url = _candidates[_index];
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius ?? widget.size * 0.18),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Image.network(
          url,
          fit: widget.fit,
          filterQuality: FilterQuality.medium,
          // 封面按最大档（QQ 1500 / 网易云 3000）取原图，直接解码整张会吃掉
          // 十几 MB 内存；这里按「显示尺寸 × 3 倍」降采样解码，
          // 视觉无损但内存只有几十分之一。
          cacheWidth: widget.memCacheWidth ?? (widget.size * 3).round(),
          errorBuilder: (_, error, stackTrace) {
            _fallback();
            return _placeholder();
          },
        ),
      ),
    );
  }
}
