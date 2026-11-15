// 转码流式播放服务 —— 让自研解码器「边转码边播放」。
//
// **背景（v2.5.8-fix2）**
//
// DTS:X / 360RA / NAC 三个格式没有通用解码器，media_kit 的 ffmpeg 白名单
// 里也没有，必须走 App 自研原生管线。原来的实现是「整曲解码完 → 写 WAV
// 缓存 → 再播放」：
//
//   - NAC 一次解码要 1~2 分钟（MNN 神经推理 + ISTFT），这段时间**完全没声**；
//   - 360RA 全曲解码要数秒到数十秒；
//   - 用户中途切歌，已解的那部分全部白费。
//
// **本类的做法**
//
// 原生解码器新增 `*_decode_stream` 接口：**边解码边把 PCM 追加写到目标
// 文件**（WAV 头的 RIFF / data 长度写 0xFFFFFFFF = 未知总长，这是流式
// 场景的常规做法，ffmpeg / mpv 都能正常解码）。
//
// 本类起一个本机 HttpServer（127.0.0.1 随机端口），tail 那个文件，把新
// 追加的字节推给 HTTP 响应；播放器拿到的 URL 形如
// `http://127.0.0.1:<port>/tx/<token>`，libmpv 请求它、收到多少算多少，
// 于是**首帧到达即出声**，解码与播放并行。
//
// **为什么用「tail 文件」而不是「FFI 回调」**
//
// 原生解码跑在 isolate 里（FFI 同步阻塞，不能占 UI 线程）。若用 C 回调
// 把 PCM 直接推给 Dart，跨 isolate 传字节要额外搭一套端口协议，且回调
// 发生在原生线程上，出错处理很别扭。改成「原生写文件、Dart tail 文件」
// 后，两侧只通过**文件**这一层解耦：原生只管写、只管 fflush，Dart 只管
// 读、只管推，逻辑简单且天然可复用已有的解码器实现。
//
// **与 WAV 缓存的关系**
//
// 流式播放写的是**独立的临时文件**（`.stream`），不污染正式缓存——
// 正式缓存仍由 v2.5.8-fix1 的「.part + 校验 + 原子落盘」流程负责。
// 流式失败时上层自动回落到「整曲解码 + WAV 缓存」的旧路径，两条路互为
// 兜底。
library;

import 'dart:async';
import 'dart:io';

import 'app_logger.dart';

/// 一个流式会话：正在被写的文件 + 结束信号。
class TxSession {
  /// 正在被写入的文件（原生解码器往里追加 PCM）。
  final File file;

  /// 解码结束（成功或失败）。
  final Completer<void> done = Completer<void>();

  /// 已推送给播放器的字节数（诊断用）。
  int pushed = 0;

  /// 已读取到的文件位置（增量读的游标）。
  ///
  /// 暴露出来是为了让测试能验证「边写边读」这个核心机制：读的位置应
  /// 始终等于「已经读到哪」，而不是「文件有多长」。
  int readPos = 0;

  TxSession(this.file);
}

/// 流式转码播放服务（单例）。
///
/// 用法：
/// ```dart
/// final session = TxSession(File(path));
/// final url = await TranscodeStreamServer.instance.serve(session);
/// // 启动解码（往 session.file 追加 PCM），完成后 session.done.complete()
/// // 把 url 交给播放器即可
/// ```
class TranscodeStreamServer {
  TranscodeStreamServer._();

  static final TranscodeStreamServer instance = TranscodeStreamServer._();

  HttpServer? _server;
  final Map<String, TxSession> _sessions = {};
  int _seq = 0;

  /// 服务端口（未启动时 null）。
  int? get port => _server?.port;

  /// 启动（幂等）。
  Future<int> _ensureServer() async {
    final s = _server;
    if (s != null) return s.port;
    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false);
    _server = server;
    unawaited(_serve(server));
    AppLog.i('TxStream', '流式转码服务已启动 127.0.0.1:${server.port}');
    return server.port;
  }

  /// 停止服务并清理全部会话（幂等）。
  Future<void> stop() async {
    final s = _server;
    _server = null;
    for (final sess in _sessions.values) {
      if (!sess.done.isCompleted) sess.done.complete();
    }
    _sessions.clear();
    await s?.close(force: true);
  }

  /// 为一个会话开流，返回播放器可直接打开的 URL。
  ///
  /// 调用方负责驱动解码（往 [session.file] 追加 PCM），解码结束后调
  /// [TxSession.done] 的 complete —— 服务端据此结束 HTTP 响应。
  Future<String> serve(TxSession session) async {
    final port = await _ensureServer();
    final token = 'tx${_seq++}';
    _sessions[token] = session;
    return 'http://127.0.0.1:$port/tx/$token';
  }

  /// 把「增长中的文件」增量读出来并逐块交给 [emit]。
  ///
  /// 这是「边转码边播放」的核心读取机制，抽成静态方法以便单测直接验证
  /// （不依赖真实 socket / HttpServer）。逻辑与原 `_pump` 一致：
  ///
  /// 1. 先等文件出现——原生解码器先把源文件下载到别处，开始解码后才
  ///    创建并写入 [session.file]；播放器可能在此之前就连上来。若文件
  ///    迟迟不出现且解码已结束，说明从头到尾没产出任何数据，直接收尾
  ///    （不再向播放器发空响应——那会触发 `Failed to recognize file
  ///    format.`）。
  /// 2. 按「长度 + 定位读」取增量（不能用 `read()`，它在文件尾会等更多
  ///    数据，与「文件还在增长」冲突）。
  /// 3. 读的位置始终等于「已读到哪」，而不是「文件有多长」。
  ///
  /// [emit] 在每条增量上被调用；[poll] 为轮询间隔，[maxWaitMs] 为等待
  /// 文件出现的最大时长（单测用；生产为 null = 不限）。
  static Future<void> streamFileToSink(
    TxSession session,
    Future<void> Function(List<int>) emit, {
    Duration poll = const Duration(milliseconds: 100),
    int? maxWaitMs,
  }) async {
    // 1) 等文件出现（极端竞态兜底）。
    final deadline = maxWaitMs == null
        ? null
        : DateTime.now().add(Duration(milliseconds: maxWaitMs));
    while (!await session.file.exists()) {
      if (session.done.isCompleted) return;
      if (deadline != null && DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(poll);
    }

    // 2) 打开只读句柄（文件已存在，open 不会再因「文件不存在」抛错）。
    RandomAccessFile raf;
    try {
      raf = await session.file.open(mode: FileMode.read);
    } catch (e) {
      AppLog.w('TxStream', '流式文件打开失败，放弃推送: $e');
      return;
    }

    try {
      while (true) {
        final len = await session.file.length();
        if (len > session.readPos) {
          await raf.setPosition(session.readPos);
          final chunk = await raf.read(len - session.readPos);
          if (chunk.isNotEmpty) {
            await emit(chunk);
            session.readPos += chunk.length;
          }
          continue;
        }
        if (session.done.isCompleted) {
          // 再等一拍，确认没有残留（解码刚完成时文件长度可能还在更新）。
          await Future<void>.delayed(poll);
          final finalLen = await session.file.length();
          if (finalLen <= session.readPos) break;
          continue;
        }
        await Future<void>.delayed(poll);
      }
      AppLog.i('TxStream', '流式推送完成，共 ${session.pushed} 字节');
    } finally {
      await raf.close();
    }
  }

  Future<void> _serve(HttpServer server) async {
    try {
      await for (final req in server) {
        unawaited(_handle(req));
      }
    } catch (e) {
      AppLog.w('TxStream', 'serve 异常: $e');
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method != 'GET' || !path.startsWith('/tx/')) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final token = path.substring('/tx/'.length);
    final session = _sessions.remove(token);
    if (session == null) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }

    final res = req.response;
    res.statusCode = 200;
    res.headers.set(HttpHeaders.contentTypeHeader, 'audio/wav');
    // 长度未知 → 必须显式置 -1（HttpServer 否则会缓冲到凑满才发，或按
    // Content-Length 语义等待），这样才是真正的「边写边发」。
    res.contentLength = -1;
    try {
      await _pump(session, res);
    } catch (e) {
      // 播放器提前断开（用户切歌）属正常路径。
      AppLog.i('TxStream', '流式响应中断 $token: $e');
    } finally {
      try {
        await res.close();
      } catch (_) {}
      if (!session.done.isCompleted) session.done.complete();
    }
  }

  /// tail 文件并推给响应。
  ///
  /// 首次进入时先发 44 字节 WAV 头（原生已写入，RIFF/data 长度是
  /// 0xFFFFFFFF = 未知总长）；之后持续读新追加的 PCM 推出去。
  Future<void> _pump(TxSession session, HttpResponse res) async {
    await TranscodeStreamServer.streamFileToSink(
      session,
      (chunk) async {
        // 首个 chunk 含 44 字节 WAV 头 + 起始 PCM，头直接透传（原生写的
        // 流式头，RIFF/data 长度是 0xFFFFFFFF = 未知总长）。
        res.add(chunk);
        session.pushed += chunk.length;
        // 立刻 flush，让数据离开 Dart 缓冲区——否则「边转码边播」会退化成
        // 「攒满一缓冲才发」。res.add 接收的是 List<int>，这里统一转成
        // 不可变视图；保持与原有行为一致。
        await res.flush();
      },
    );
  }
}
