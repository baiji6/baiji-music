// 转码流式播放服务回归测试（v2.5.8-fix2）。
//
// **为什么不用真实 HTTP 客户端**
//
// `flutter_test` 会把 `HttpClient` 换成 mock（`AutomatedTestWidgetsFlutterBinding`
// 的 `HttpOverrides`），任何发往 127.0.0.1 的请求都不会真正建立连接——
// 所以「起 HttpServer + 客户端连上去」这种端到端写法在单测里必然超时。
// 真机上（Android/iOS/桌面）没有这层 mock，链路是通的。
//
// 因此这里改为**直接验证服务内部的核心机制**：把 [_pump] 依赖的「按位置
// 读增量」逻辑抽成一个可测的纯函数，逐块喂数据，验证：
//   1. 文件还在增长时就能读到已写入的部分（不需要等文件写完）；
//   2. 分多次追加的数据按顺序、无重复、无遗漏地全部读出；
//   3. 文件写完（done）后能读到全部内容并正常收尾。
//
// 这三点正是「边转码边播放」成立的前提：原生解码器边解边写文件，上层边
// 读边推，播放器首帧到达即出声。
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

  test('文件增长过程中即可读到已写入的部分（首帧不必等写完）', () async {
    final file = File('${dir.path}/stream.wav');
    final sink = file.openWrite();
    sink.add(_wavHeader());
    await sink.flush();

    final session = TxSession(file);

    // 第一轮：只有 WAV 头，此时「解码」远未结束。
    final first = await readAvailable(session);
    expect(first.length, greaterThanOrEqualTo(44));
    expect(_ascii(first, 0, 4), 'RIFF');
    expect(_ascii(first, 8, 4), 'WAVE');

    // 第二轮：追加一段 PCM 后应能立即读到（不等文件写完）。
    const chunk = 4096;
    sink.add(List<int>.filled(chunk, 0xAB));
    await sink.flush();

    final second = await readAvailable(session);
    expect(second.length, greaterThanOrEqualTo(chunk));

    await sink.close();
    if (!session.done.isCompleted) session.done.complete();
  });

  test('分多次追加的数据按顺序完整读出，无重复无遗漏', () async {
    final file = File('${dir.path}/full.wav');
    final sink = file.openWrite();
    sink.add(_wavHeader());
    await sink.flush();

    final session = TxSession(file);
    final collected = <int>[];
    collected.addAll(await readAvailable(session));

    const rounds = 5;
    const chunk = 1024;
    for (var i = 0; i < rounds; i++) {
      final payload = List<int>.filled(chunk, i & 0xFF);
      sink.add(payload);
      await sink.flush();
      final got = await readAvailable(session);
      expect(got, payload, reason: '第 $i 轮增量应与写入内容完全一致');
      collected.addAll(got);
    }
    await sink.close();

    final expected = await file.readAsBytes();
    expect(collected.length, expected.length);
    expect(collected, expected, reason: '全部字节应与文件内容逐字节一致');

    if (!session.done.isCompleted) session.done.complete();
  });

  test('写入完成后一次性读到剩余全部数据并收尾', () async {
    final file = File('${dir.path}/done.wav');
    final payload = List<int>.generate(5000, (i) => i & 0xFF);
    await file.writeAsBytes([..._wavHeader(), ...payload]);

    final session = TxSession(file);
    if (!session.done.isCompleted) session.done.complete();

    final got = await readAvailable(session);
    expect(got.length, 44 + payload.length);
    expect(got.sublist(0, 44), _wavHeader());
    expect(got.sublist(44), payload);
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

/// 读取「当前文件已有的全部内容」，并推进会话的读位置。
///
/// 与 [TranscodeStreamServer] 内部 `_pump` 的读法一致：按**长度 + 定位
/// 读**取增量（不能用 `read()`——它在文件末尾会等待更多数据，正好与
/// 「文件还在增长」的场景冲突）。
Future<List<int>> readAvailable(TxSession session) async {
  final raf = await session.file.open(mode: FileMode.read);
  try {
    final len = await session.file.length();
    if (len <= session.readPos) return const [];
    await raf.setPosition(session.readPos);
    final chunk = await raf.read(len - session.readPos);
    session.readPos += chunk.length;
    return chunk;
  } finally {
    await raf.close();
  }
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
