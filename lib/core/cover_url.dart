import '../models/models.dart';

/// 封面 URL 解析：按「最大优先 + 降级链」给出候选列表。
///
/// 两个音源的取图规则与实测上限：
///
/// **QQ 音乐** — `https://y.qq.com/music/photo_new/T002R{size}x{size}M000{albumMid}.jpg`
/// - 可用档位：150 / 300 / 500 / 800 / **1500**
/// - 1500 是上限：请求 2000 / 3000 会直接返回 **404**
/// - 服务端按请求值精确缩放，请求 1500 就得到 1500×1500
/// - 因此默认取 1500，失败（404 或网络错误）时降级 800 → 500 → 300
///
/// **网易云** — `https://p3.music.126.net/{enc}/{picId}.jpg?param={size}y{size}`
/// - `param` 由 CDN 决定实际输出，最大可取 **3000**
/// - 超出原图分辨率时 CDN 会**自动截断**到原图上限（实测某专辑原图 1024，
///   请求 2000 / 3000 / 4000 均返回 1024×1024，且不会报错）
/// - 因此默认取 3000（等价于「原图」），失败时降级 1000 → 500 → 300
///
/// 降级不是猜的，而是由 [CoverImage] 在真实加载失败时逐级尝试，
/// 所以既拿得到最大图，又不会出现空白封面。
class CoverUrl {
  CoverUrl._();

  /// QQ 专辑图降级档位（高 → 低）。
  static const List<int> qqSizes = <int>[1500, 800, 500, 300];

  /// 网易云封面降级档位（高 → 低）。
  static const List<int> neteaseSizes = <int>[3000, 1000, 500, 300];

  /// QQ 专辑图模板：把任意已存在的尺寸（宽×高）整体替换为目标尺寸。
  ///
  /// 分组 1 = `T002R`，分组 2 = `M000` 及之后的部分；
  /// 中间的 `\d+x\d+` 不捕获，避免只替换宽度留下旧高度（如 `R1500x300`）。
  static final RegExp _qqSizePattern =
      RegExp(r'(T002R)\d+x\d+(M000)', caseSensitive: false);

  /// 默认展示用 URL（= 最大档位）。
  ///
  /// 保留同步 getter 以兼容历史持久化数据与所有只需要一个 URL 的场景；
  /// 真正需要降级的 UI 请走 [candidates] + [CoverImage]。
  static String primary(Song song) => candidates(song).first;

  /// 封面候选 URL，按「最大 → 最小」排列；无可用封面时返回空列表。
  static List<String> candidates(Song song) {
    return song.isNetease ? _netease(song) : _qq(song);
  }

  // ==================== QQ 音乐 ====================

  static List<String> _qq(Song song) {
    final raw = song.cover;

    // 1) 已经是 photo_new 专辑图：只替换尺寸段，其余（含 CDN 前缀）原样保留
    if (_qqSizePattern.hasMatch(raw)) {
      return <String>[
        for (final s in qqSizes)
          raw.replaceFirstMapped(
              _qqSizePattern, (m) => '${m.group(1)}${s}x$s${m.group(2)}'),
      ];
    }

    // 2) 有 albumMid：按标准模板从最大档开始拼
    if (song.albumMid.isNotEmpty) {
      return <String>[for (final s in qqSizes) qqAlbumCoverUrl(song.albumMid, size: s)];
    }

    // 3) 只有裸 cover（历史数据）：至少把它作为唯一候选
    if (raw.isNotEmpty) return <String>[raw];
    return const <String>[];
  }

  // ==================== 网易云 ====================

  static List<String> _netease(Song song) {
    final raw = song.cover;
    if (raw.isEmpty) return const <String>[];

    final qIndex = raw.indexOf('?');
    final base = qIndex >= 0 ? raw.substring(0, qIndex) : raw;
    final query = qIndex >= 0 ? raw.substring(qIndex + 1) : '';

    // 保留 param 之外的查询参数（例如有的地址带 imageView / 鉴权串），
    // 只重写 param 这一段。
    final others = _otherParams(query);

    final out = <String>[];
    for (final s in neteaseSizes) {
      final segs = <String>['param=${s}y$s', ...others];
      out.add('$base?${segs.join('&')}');
    }
    return out;
  }

  /// 把任意封面 URL 提升到最大档（用于下载封面时取原图）。
  ///
  /// 无法识别来源时原样返回。
  static String maximize(String url) {
    if (url.isEmpty) return url;
    if (_qqSizePattern.hasMatch(url)) {
      final q = qqSizes.first;
      return url.replaceFirstMapped(
          _qqSizePattern, (m) => '${m.group(1)}${q}x$q${m.group(2)}');
    }
    final qIndex = url.indexOf('?');
    final base = qIndex >= 0 ? url.substring(0, qIndex) : url;
    final query = qIndex >= 0 ? url.substring(qIndex + 1) : '';
    final others = _otherParams(query);
    final hasParam = query.split('&').any((p) => p.startsWith('param='));
    // 网易云的 param 有上限截断语义，直接拉到 3000 即可取到原图
    if (hasParam || base.contains('music.126.net')) {
      final n = neteaseSizes.first;
      return '$base?${<String>['param=${n}y$n', ...others].join('&')}';
    }
    return url;
  }

  /// 挑出 `param=` 之外的查询参数（imageView / 鉴权串等需要原样带走）。
  static List<String> _otherParams(String query) {
    final out = <String>[];
    if (query.isEmpty) return out;
    for (final part in query.split('&')) {
      if (part.isEmpty || part.startsWith('param=')) continue;
      out.add(part);
    }
    return out;
  }
}
