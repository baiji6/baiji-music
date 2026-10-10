import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/cover_url.dart';
import '../../local/local_scanner.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';
import 'app_widgets.dart';

/// 本地封面字节的轻量内存缓存。
///
/// 列表里每一格都要读一次文件 IO，快速滑动时同一首歌会被反复请求；
/// 这里按路径缓存，并限制条目数，避免几千首歌的封面把内存撑爆。
class LocalCoverCache {
  LocalCoverCache._();

  static const int _maxEntries = 200;
  static final Map<String, Uint8List?> _cache = <String, Uint8List?>{};

  /// 命中返回字节（含「确认无封面」的 null 也算命中），未命中返回 "未缓存" 标记。
  static (bool, Uint8List?) lookup(String path) {
    if (_cache.containsKey(path)) return (true, _cache[path]);
    return (false, null);
  }

  static void put(String path, Uint8List? bytes) {
    if (_cache.length >= _maxEntries) {
      // Dart 的 Map 保持插入顺序，淘汰最早的一半即可，
      // 比全清更平滑（不会导致整屏封面同时重新解码）
      final victims = _cache.keys.take(_maxEntries ~/ 2).toList();
      for (final k in victims) {
        _cache.remove(k);
      }
    }
    _cache[path] = bytes;
  }

  /// 仅供测试清空状态。
  static void clear() => _cache.clear();
}

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

  /// 本地歌曲的内嵌封面（异步读入）；读完前显示占位。
  Uint8List? _localBytes;

  @override
  void initState() {
    super.initState();
    _reset();
    _resolveLocal();
  }

  @override
  void didUpdateWidget(covariant CoverImage old) {
    super.didUpdateWidget(old);
    if (old.song.mid != widget.song.mid ||
        old.song.cover != widget.song.cover ||
        old.song.albumMid != widget.song.albumMid) {
      _reset();
      _localBytes = null;
      _resolveLocal();
    }
  }

  void _reset() {
    _candidates = CoverUrl.candidates(widget.song);
    _index = 0;
    _scheduled = false;
  }

  /// 本地歌曲从文件里读封面。先查缓存，未命中才真正读盘。
  Future<void> _resolveLocal() async {
    final song = widget.song;
    if (!song.isLocal) return;

    final path = song.localPath;
    final hit = LocalCoverCache.lookup(path);
    if (hit.$1) {
      if (!mounted) return;
      setState(() => _localBytes = hit.$2);
      return;
    }

    final bytes = await LocalScanner.readCover(song);
    LocalCoverCache.put(path, bytes);
    if (!mounted) return;
    setState(() => _localBytes = bytes);
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
    // 本地歌曲：用文件里解出的封面字节；读不到（或还没读完）则显示占位。
    if (widget.song.isLocal) {
      final bytes = _localBytes;
      if (bytes == null) return _placeholder();
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius ?? widget.size * 0.18),
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Image.memory(
            bytes,
            fit: widget.fit,
            filterQuality: FilterQuality.medium,
            cacheWidth: widget.memCacheWidth ?? (widget.size * 3).round(),
            gaplessPlayback: true,
            errorBuilder: (_, e, s) => _placeholder(),
          ),
        ),
      );
    }

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
