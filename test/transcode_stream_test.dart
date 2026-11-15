// 转码流式播放服务回归测试（v2.5.8-fix3）。
//
// **为什么不用真实 HTTP 客户端**
//
// `flutter_test` 会把 `HttpClient` 换成 mock（`AutomatedTestWidgetsFlutterBinding`
// 的 `HttpOverrides`），任何发往 127.0.0.1 的请求都不会真正建立连接——
// 所以「起 HttpServer + 客户端连上去」这种端到端写法在单测里必然超时。
// 真机上（Android/iOS/桌面）没有这层 mock，链路是通的。
//
// 因此这里改为**直接验证服务内部的核心机制**：[TranscodeStreamServer.streamFileToSink]
// 抽出后即可单测，逐块喂数据，验证：
//   1. 文件还没出现时（播放器先连上来、原生还在下载源）能等它出现再读；
//   2. 文件增长过程中就能读到已写入的部分（首帧不必等写完）；
//   3. 分多次追加的数据按顺序、无重复、无遗漏地全部读出；
//   4. 文件写完（done）后能读到全部内容并正常收尾；
//   5. 文件始终不出现且解码已结束时不崩溃、不发送空响应（避免 mpv 报
//      "Failed to recognize file format."）。
//
// 这五点正是「边转码边播放」成立的前提：原生解码器边解边写文件，上层边
// 读边推，播放器首帧到达即出声。（第 1/5 点对应 fix3 修复的 open 竞态。）
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/core/transcode_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('baiji_tx_test');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('文件尚未出现时等待其出现，再读出全部内容（open 竞态回归）', () async {
    final file = File('${dir.path}/late.wav');
    final session = TxSession(file);
    final collected = <int>[];

    // 启动流式读取（不阻塞地等待文件出现）。
    final pump = TranscodeStreamServer.streamFileToSink(
      session,
      (c) async => collected.addAll(c),
      maxWaitMs: 3000,
    );

    // 模拟：原生解码器稍后才创建并写入文件（播放器已先连上来）。
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final sink = file.openWrite();
    sink.add(_wavHeader());
    await sink.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    sink.add(List<int>.filled(2048, 0xCD));
    await sink.flush();
    await sink.close();
    if (!session.done.isCompleted) session.done.complete();

    await pump;

    final expected = await file.readAsBytes();
    expect(collected.length, expected.length);
    expect(collected, expected, reason: '应与原文件逐字节一致');
    expect(_ascii(collected, 0, 4), 'RIFF');
    expect(_ascii(collected, 8, 4), 'WAVE');
  });

  test('文件增长过程中即可读到已写入的部分（首帧不必等写完）', () async {
    final file = File('${dir.path}/stream.wav');
    // 预创建空文件（与线上 _streamTranscode 的预创建一致）。
    await file.create();
    final sink = file.openWrite();
    sink.add(_wavHeader());
    await sink.flush();

    final session = TxSession(file);
    final collected = <int>[];
    final pump = TranscodeStreamServer.streamFileToSink(
      session,
      (c) async => collected.addAll(c),
    );

    // 第一轮：只有 WAV 头，此时「解码」远未结束。
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final firstLen = collected.length;
    expect(firstLen, greaterThanOrEqualTo(44));
    expect(_ascii(collected, 0, 4), 'RIFF');
    expect(_ascii(collected, 8, 4), 'WAVE');

    // 第二轮：追加一段 PCM 后应能立即读到（不等文件写完）。
    const chunk = 4096;
    sink.add(List<int>.filled(chunk, 0xAB));
    await sink.flush();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(collected.length, greaterThanOrEqualTo(44 + chunk));

    await sink.close();
    if (!session.done.isCompleted) session.done.complete();
    await pump;

    final expected = await file.readAsBytes();
    expect(collected.length, expected.length);
    expect(collected, expected);
  });

  test('分多次追加的数据按顺序完整读出，无重复无遗漏', () async {
    final file = File('${dir.path}/full.wav');
    await file.create();
    final sink = file.openWrite();
    sink.add(_wavHeader());
    await sink.flush();

    final session = TxSession(file);
    final collected = <int>[];
    final pump = TranscodeStreamServer.streamFileToSink(
      session,
      (c) async => collected.addAll(c),
    );

    // 先等流式读取消费掉已存在的 44 字节 WAV 头：此后 [collected] 的长度
    // 才纯粹反映「已推送的 PCM 量」，后续按累计值断言才不会被首轮把头算进
    // 增量（否则首轮增量会是 44+chunk，误判）。
    final headerSw = Stopwatch()..start();
    while (collected.length < 44 &&
        headerSw.elapsed < const Duration(seconds: 2)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(collected.length, greaterThanOrEqualTo(44),
        reason: '流式读取应已消费 WAV 头');

    const rounds = 5;
    const chunk = 1024;
    for (var i = 0; i < rounds; i++) {
      final payload = List<int>.filled(chunk, i & 0xFF);
      sink.add(payload);
      await sink.flush();
      // 等这一轮的 PCM 被流式读取——累计量应达到 44 + (i+1)*chunk。
      // 用「累计 >= 目标」而不是「单轮增量 == chunk」：读取时机由事件循环
      // 调度，头与首轮 PCM 可能同一拍被读走，单轮精确增量不可靠，但累计量
      // 必然单调且最终精确（末尾再逐字节比对）。
      final target = 44 + (i + 1) * chunk;
      final sw = Stopwatch()..start();
      while (collected.length < target &&
          sw.elapsed < const Duration(seconds: 2)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(collected.length, greaterThanOrEqualTo(target),
          reason: '第 $i 轮 PCM 应已被完整读出');
    }
    await sink.close();
    if (!session.done.isCompleted) session.done.complete();
    await pump;

    final expected = await file.readAsBytes();
    expect(collected.length, expected.length);
    expect(collected, expected, reason: '全部字节应与文件内容逐字节一致（无重复无遗漏）');
  });

  test('写入完成后一次性读到剩余全部数据并收尾', () async {
    final file = File('${dir.path}/done.wav');
    final payload = List<int>.generate(5000, (i) => i & 0xFF);
    await file.writeAsBytes([..._wavHeader(), ...payload]);

    final session = TxSession(file);
    if (!session.done.isCompleted) session.done.complete();

    final collected = <int>[];
    await TranscodeStreamServer.streamFileToSink(
      session,
      (c) async => collected.addAll(c),
    );
    expect(collected.length, 44 + payload.length);
    expect(collected.sublist(0, 44), _wavHeader());
    expect(collected.sublist(44), payload);
  });

  test('文件始终不出现且解码已结束：不崩溃、不发送空响应', () async {
    final file = File('${dir.path}/never.wav');
    final session = TxSession(file);
    final collected = <int>[];
    if (!session.done.isCompleted) session.done.complete();

    // 不应抛异常；线上对应：onDecodeFailed 兜底触发整曲解码重播，
    // 而不是把空响应交给 mpv 触发 "Failed to recognize file format."。
    await expectLater(
      () => TranscodeStreamServer.streamFileToSink(
        session,
        (c) async => collected.addAll(c),
        maxWaitMs: 300,
      ),
      returnsNormally,
    );
    expect(collected, isEmpty);
  });

  test('WAV 头使用未知长度标记（0xFFFFFFFF），流式播放器才能边收边解', () {
    final h = _wavHeader();
    final b = ByteData.sublistView(Uint8List.fromList(h));
    // RIFF 长度占位为未知总长。
    expect(b.getUint32(4, Endian.little), 0xFFFFFFFF);
    // data 长度同样占位为未知总长。
    expect(b.getUint32(40, Endian.little), 0xFFFFFFFF);
    // fmt 段：PCM / 立体声 / 48kHz / 16bit。
    expect(b.getUint16(20, Endian.little), 1);
    expect(b.getUint16(22, Endian.little), 2);
    expect(b.getUint32(24, Endian.little), 48000);
    expect(b.getUint16(34, Endian.little), 16);
  });
}

/// 构造一个「未知长度」的 WAV 头（RIFF / data 长度 = 0xFFFFFFFF）。
///
/// 与原生解码器写出的流式头一致（见 ra360_glue.cpp / dts_glue.c /
/// nac_glue.cpp）。
List<int> _wavHeader() {
  final b = ByteData(44);
  void ascii(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 0xFFFFFFFF, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 2, Endian.little); // 立体声
  b.setUint32(24, 48000, Endian.little);
  b.setUint32(28, 48000 * 4, Endian.little);
  b.setUint16(32, 4, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, 0xFFFFFFFF, Endian.little);
  return b.buffer.asUint8List();
}

String _ascii(List<int> b, int off, int len) =>
    String.fromCharCodes(b.sublist(off, off + len));
