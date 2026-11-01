// MV（Music Video）播放源模型与画质档位 —— 三平台通用。
//
// 接口逆向自聆澜脚本（酷我/网易/QQ 三个 .js）的 `getMvSource`：
//   - QQ    gosrf.Stream.MvUrlProxy / GetMvUrls（musicu.fcg，vid 请求）
//   - 酷我  kuwo.cn/api/v1/www/music/playUrl?mid=<rid>&type=mv（无 vid 兜底）
//           + anymatch.kuwo.cn/mobi.s?type=get_url_by_vid（有 vid 时高画质）
//   - 网易  /weapi/song/enhance/play/mv/url（weapi 加密，r=分辨率）
//
// v2.4.3 实测（2026-11）：
//   - QQ filetype 10/20/30/40/50 → 360p/480p/720p/1080p/4k；code==0 且
//     freeflow_url 非空才可用；URL 是 http:// 需要升 https。
//   - 酷我 legacy 接口对无 MV 的歌也可能返回 URL（关联 MV），播放前不做
//     mvflag 预判；anymatch 响应是 key=value 行文本。
//   - 网易 data 可能是数组或对象（历史接口两种形态都见过），取第一个有
//     url 的条目；免费 MV 无需登录，VIP MV 登录后可取。
library;

/// MV 画质档位（从低到高）。
enum MvQuality {
  q240p('240p', 240),
  q360p('360p', 360),
  q480p('480p', 480),
  q720p('720p', 720),
  q1080p('1080p', 1080),
  q4k('4k', 2160);

  const MvQuality(this.key, this.height);

  /// 展示 key（'720p' / '1080p' / '4k'）。
  final String key;

  /// 目标高度（px）。
  final int height;

  static MvQuality fromKey(String? key) {
    final k = (key ?? '').trim().toLowerCase();
    for (final q in values) {
      if (q.key == k) return q;
    }
    // 容错：'1080P' / '2160p' / 'uhd' 等
    if (k == 'uhd' || k == '2160p') return MvQuality.q4k;
    final h = int.tryParse(k.replaceAll(RegExp(r'[^0-9]'), ''));
    if (h != null) {
      for (final q in values) {
        if (q.height == h) return q;
      }
    }
    return MvQuality.q1080p;
  }
}

/// 一个可播放的 MV 源。
class MvSource {
  /// 播放地址（http/https）。
  final String url;

  /// 请求该地址需要带的头（Referer / User-Agent）——CDN 防盗链用。
  /// 本地代理会原样注入；WebView 不直接加载 [url]。
  final Map<String, String> headers;

  /// 服务端实际返回的画质 key（如 '1080p'；请求 1080p 实给 720p 时会变）。
  final String videoQuality;

  /// MIME（'video/mp4'）。
  final String mimeType;

  /// 文件字节数（未知为 0）。
  final int size;

  /// 视频宽度/高度（未知为 0）。
  final int width;
  final int height;

  /// 码率（bps；未知为 0）。
  final int bitrate;

  /// 备用地址（QQ 多 CDN 场景）。
  final List<String> backupUrls;

  /// 链接过期时间（秒，相对值；0 表示未知）。QQ expire=86400、网易 expi=3600。
  final int expiresInSeconds;

  const MvSource({
    required this.url,
    this.headers = const {},
    required this.videoQuality,
    this.mimeType = 'video/mp4',
    this.size = 0,
    this.width = 0,
    this.height = 0,
    this.bitrate = 0,
    this.backupUrls = const [],
    this.expiresInSeconds = 0,
  });

  bool get isUsable => url.startsWith('http');

  /// 画质低于请求时 UI 提示用（'请求 1080p，实际 720p'）。
  String get qualityLabel => videoQuality.toUpperCase();
}

/// 「该歌曲没有 MV」与网络失败的统一异常，UI 捕获后提示。
class MvUnavailable implements Exception {
  const MvUnavailable(this.reason);

  final String reason;

  @override
  String toString() => reason;
}
