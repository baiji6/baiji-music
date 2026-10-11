import '../models/models.dart';

/// 本地歌曲列表的排序方式。
enum LocalSortKey {
  title('标题', 'title'),
  singer('歌手', 'singer'),
  album('专辑', 'album'),
  duration('时长', 'duration'),
  date('修改时间', 'date'),
  size('文件大小', 'size'),
  format('格式', 'format');

  const LocalSortKey(this.label, this.id);

  /// 下拉菜单展示名。
  final String label;

  /// 持久化用的稳定标识（不能用 enum 索引，改名会丢用户偏好）。
  final String id;

  static LocalSortKey fromId(String? id) {
    for (final k in LocalSortKey.values) {
      if (k.id == id) return k;
    }
    return LocalSortKey.title;
  }
}

/// 本地歌曲列表的搜索 / 排序纯逻辑。
///
/// 抽成独立单元是为了能脱离 Widget 做单测：过滤规则和比较规则最容易出
/// 边界问题（比如中文标题的 `compareTo`、时长为 0、空关键词）。
class LocalSongQuery {
  const LocalSongQuery._();

  /// 关键词过滤：命中歌名 / 歌手 / 专辑 / 文件名（不含路径）任一即可。
  ///
  /// 关键词为空或全空白时返回原列表（同引用，方便调用方直接判断是否需要重算）。
  static List<Song> filter(List<Song> songs, String rawQuery) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return songs;
    final terms = q.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (terms.isEmpty) return songs;
    return songs.where((s) {
      final haystack = [
        s.name,
        s.singer,
        s.album,
        _fileNameOf(s.localPath),
      ].join(' ').toLowerCase();
      return terms.every(haystack.contains);
    }).toList();
  }

  /// 排序。中文用 `compareTo` 的 Unicode 序，够稳定且无需额外依赖。
  ///
  /// [desc] 为 true 时取反。稳定性：比较结果为 0 时退回原始下标，
  /// 保证同样输入永远得到同样顺序。
  static List<Song> sort(
    List<Song> songs,
    LocalSortKey key, {
    bool desc = false,
  }) {
    final out = List<Song>.of(songs);
    out.sort((a, b) {
      final c = _compare(a, b, key);
      return c != 0 ? c : a.localPath.compareTo(b.localPath);
    });
    if (!desc) return out;
    // 降序不能简单 reverse：_compare 里「未知时长/未知大小沉底」是有意为之的
    // 分区规则，整体翻转会把它们甩到最前面。所以倒序时重排为
    // 「有值的降序 → 无值的（沉底）」。
    final known = out.where((s) => _hasValue(s, key)).toList();
    final unknown = out.where((s) => !_hasValue(s, key)).toList();
    // 不用 List.reverse：本机 SDK 的 core List 未暴露它，reversed 迭代更稳。
    return [...known.reversed, ...unknown];
  }

  /// 该排序键下这个字段是否有有效值（时长 0 / 大小 0 视为无值）。
  static bool _hasValue(Song s, LocalSortKey key) => switch (key) {
        LocalSortKey.duration => s.duration > 0,
        LocalSortKey.size => s.localSize > 0,
        LocalSortKey.date => s.localMtime > 0,
        _ => true,
      };

  /// 过滤 + 排序一步到位，列表渲染只调这一个。
  static List<Song> apply(
    List<Song> songs, {
    String query = '',
    LocalSortKey key = LocalSortKey.title,
    bool desc = false,
  }) =>
      sort(filter(songs, query), key, desc: desc);

  static int _compare(Song a, Song b, LocalSortKey key) {
    switch (key) {
      case LocalSortKey.title:
        return _cmpText(a.name, b.name);
      case LocalSortKey.singer:
        // 同一歌手的歌排在一起，组内再按标题。
        final s = _cmpText(a.singer, b.singer);
        return s != 0 ? s : _cmpText(a.name, b.name);
      case LocalSortKey.album:
        final s = _cmpText(a.album, b.album);
        return s != 0 ? s : _cmpText(a.name, b.name);
      case LocalSortKey.duration:
        // 时长为 0（读不到时长）统一沉到最后，不参与大小比较。
        final az = a.duration <= 0;
        final bz = b.duration <= 0;
        if (az || bz) return az == bz ? 0 : (az ? 1 : -1);
        return a.duration.compareTo(b.duration);
      case LocalSortKey.date:
        return a.localMtime.compareTo(b.localMtime);
      case LocalSortKey.size:
        return a.localSize.compareTo(b.localSize);
      case LocalSortKey.format:
        final s = _cmpText(a.format, b.format);
        return s != 0 ? s : _cmpText(a.name, b.name);
    }
  }

  static int _cmpText(String a, String b) {
    final la = a.toLowerCase();
    final lb = b.toLowerCase();
    return la.compareTo(lb);
  }

  static String _fileNameOf(String path) {
    if (path.isEmpty) return '';
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }
}