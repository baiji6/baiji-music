// MQTT 5.0 over WebSocket 客户端单测。
//
// 两个层次：
// 1. wire format 纯函数测试——含与 paho 参考实现抓包的**逐字节金样本**对比；
// 2. 本地假 MQTT 服务端集成测试——覆盖 CONNECT/SUBSCRIBE/PUBLISH 交互、
//    0x9D 重定向、DISCONNECT 收尾，不碰外网。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/network/mqtt_ws.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MqttWire 编解码', () {
    test('varint round-trip（含 1/2/3/4 字节边界）', () {
      for (final v in const [0, 1, 127, 128, 16383, 16384, 2097151, 2097152, 268435455]) {
        final encoded = MqttWire.encodeVarint(v);
        final decoded = MqttWire.decodeVarint(Uint8List.fromList(encoded), 0);
        expect(decoded.value, v, reason: 'value=$v bytes=${encoded.map((b) => b.toRadixString(16))}');
        expect(decoded.end, encoded.length);
      }
    });

    test('varint 畸形输入返回 end=-1', () {
      // 5 个字节全带续位：超过 MQTT 5.0 的 4 字节上限
      final bad = Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0x7F]);
      expect(MqttWire.decodeVarint(bad, 0).end, -1);
      // 越界截断
      expect(MqttWire.decodeVarint(Uint8List.fromList([0x80]), 0).end, -1);
    });

    test('CONNECT 报文与 paho 抓包金样本逐字节一致', () {
      // 金样本：沙箱内用 paho-mqtt 2.1.0 按 QQ 音乐扫码登录的相同参数
      // （AUTH_METHOD=pass + 5 个 UserProperty）实际发出、抓包所得的字节。
      // 意义：证明手写编码与成熟参考实现完全一致，避免"看起来对"的协议 bug。
      final packet = MqttWire.buildConnect(
        clientId: '1234567890123456',
        keepAliveSecs: 45,
        userProperties: const {
          'tmeAppID': 'qqmusic',
          'business': 'management',
          'hashTag': 'QRID',
          'clientTag': 'management.user',
          'userID': 'QRID',
        },
      );
      final golden = '108b0100044d5154540502002d6e15000470617373260008746d65417070494400'
          '0771716d75736963260008627573696e657373000a6d616e6167656d656e7426000768617368'
          '546167000451524944260009636c69656e74546167000f6d616e6167656d656e742e75736572'
          '260006757365724944000451524944001031323334353637383930313233343536';
      expect(packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), golden);
    });

    test('parseConnack：成功 + ServerKeepAlive', () {
      // CONNACK: flags=0 reason=0 props={ServerKeepAlive=30}
      final packet = Uint8List.fromList([
        0x20, 0x06, // 固定头 + 剩余长度（flags+reason+proplen+3 字节属性）
        0x00, 0x00, // flags, reason
        0x03, // 属性长度
        0x13, 0x00, 0x1E, // ServerKeepAlive = 30
      ]);
      final c = MqttWire.parseConnack(packet);
      expect(c.reason, 0);
      expect(c.serverKeepAlive, 30);
      expect(c.serverReference, isNull);
    });

    test('parseConnack：0x9D 重定向带 ServerReference（真实结构）', () {
      // 线上实测结构：reason=0x9D，UserProperty server/channelID +
      // 标准属性 ServerReference(0x1C)="11.168.20.221:29001"
      final props = <int>[
        0x26, ..._str('server'), ..._str('11.168.20.221_29001'),
        0x26, ..._str('channelID'), ..._str('2111348302565724160'),
        0x1C, ..._str('11.168.20.221:29001'),
      ];
      final body = <int>[
        0x00, 0x9D, // flags, reason = Server moved
        ...MqttWire.encodeVarint(props.length),
        ...props,
      ];
      final packet = Uint8List.fromList([0x20, ...MqttWire.encodeVarint(body.length), ...body]);
      final c = MqttWire.parseConnack(packet);
      expect(c.reason, 0x9D);
      expect(c.serverReference, '11.168.20.221:29001');
    });

    test('parseSuback：成功与被拒绝', () {
      final ok = Uint8List.fromList([0x90, 0x03, 0x00, 0x01, 0x00, 0x00]);
      final s = MqttWire.parseSuback(ok);
      expect(s.packetId, 1);
      expect(s.reason, 0);
      // 0x87 = 未授权（扫码登录订阅被拒时服务端会返回）
      final denied = Uint8List.fromList([0x90, 0x03, 0x00, 0x01, 0x00, 0x87]);
      expect(MqttWire.parseSuback(denied).reason, 0x87);
      // 非 SUBACK
      expect(MqttWire.parseSuback(Uint8List.fromList([0x20, 0x02, 0x00, 0x00])).packetId, -1);
    });

    test('parsePublish：UserProperty + JSON 载荷', () {
      // 线上消息结构：type 在 PUBLISH 的 UserProperty 上，载荷是 JSON
      const topic = 'management.qrcode_login/QRID';
      const payload =
          '{"cookies":{"qqmusic_uin":{"value":"123"},"qqmusic_key":{"value":"KEY"}}}';
      final props = <int>[
        0x26, ..._str('type'), ..._str('cookies'),
      ];
      final body = <int>[
        ..._str(topic),
        ...MqttWire.encodeVarint(props.length),
        ...props,
        ...utf8.encode(payload),
      ];
      final packet = Uint8List.fromList([0x30, ...MqttWire.encodeVarint(body.length), ...body]);
      final p = MqttWire.parsePublish(packet);
      expect(p.topic, topic);
      expect(p.qos, 0);
      expect(p.userProperties['type'], 'cookies');
      final json = jsonDecode(utf8.decode(p.payload)) as Map<String, dynamic>;
      expect((json['cookies'] as Map)['qqmusic_key']['value'], 'KEY');
    });

    test('parsePublish：畸形包返回空 topic', () {
      expect(MqttWire.parsePublish(Uint8List.fromList([0x30, 0x05, 0x00])).topic, '');
      expect(MqttWire.parsePublish(Uint8List.fromList([0x20, 0x02, 0x00, 0x00])).topic, '');
    });

    test('redirectUrl：ServerReference 拼到路径后', () {
      expect(
        MqttWire.redirectUrl('wss://mu.y.qq.com/ws/handshake', '11.168.20.221:29001'),
        'wss://mu.y.qq.com/ws/handshake/11.168.20.221:29001',
      );
      // 末段已含冒号时整段替换（参考实现的规则）
      expect(
        MqttWire.redirectUrl('wss://mu.y.qq.com/ws/handshake/1.1.1.1:1', '2.2.2.2:2'),
        'wss://mu.y.qq.com/ws/handshake/2.2.2.2:2',
      );
    });
  });

  group('MqttWsClient 本地假服务端集成', () {
    late HttpServer server;
    late String wsUrl;
    late _FakeMqttServer fake;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      fake = _FakeMqttServer();
      server.listen((req) async {
        final socket = await WebSocketTransformer.upgrade(req);
        fake.attach(socket, req.uri.path);
      });
      wsUrl = 'ws://${server.address.host}:${server.port}/ws/handshake';
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('完整握手 + 订阅 + 收 PUBLISH + DISCONNECT', () async {
      fake.rejectReason = -1;
      final client = await MqttWsClient.connect(
        url: wsUrl,
        clientId: 'test-client',
        userProperties: const {'tmeAppID': 'qqmusic', 'hashTag': 'QRID'},
      );
      addTearDown(client.disconnect);

      // 服务端应收到带全部 UserProperty 的 CONNECT
      expect(fake.connectUserProps['tmeAppID'], 'qqmusic');
      expect(fake.connectUserProps['hashTag'], 'QRID');
      // AUTH_METHOD=pass 必须在 CONNECT 属性里（0x15 + 长度 + 明文）
      expect(fake.connectAuthMethod, 'pass');

      await client.subscribe(
        'management.qrcode_login/QRID',
        userProperties: const {'authorization': 'tmelogin', 'pubsub': 'unicast'},
      );
      expect(fake.subscribedTopic, 'management.qrcode_login/QRID');
      expect(fake.subscribeUserProps['authorization'], 'tmelogin');

      // 服务端推送 scanned / cookies 两条事件
      fake.publish('management.qrcode_login/QRID', const {'type': 'scanned'}, '{}');
      fake.publish('management.qrcode_login/QRID', const {'type': 'cookies'},
          '{"cookies":{"qqmusic_uin":{"value":"123"},"qqmusic_key":{"value":"KEY"}}}');

      final events = <MqttMessage>[];
      await for (final m in client.messages.timeout(const Duration(seconds: 5))) {
        events.add(m);
        if (events.length == 2) break;
      }
      expect(events.map((e) => e.userProperties['type']), ['scanned', 'cookies']);
      expect(events[1].payloadText, contains('qqmusic_key'));

      await client.disconnect();
      await fake.disconnectSeen.future.timeout(const Duration(seconds: 5));
      await client.done;
    });

    test('0x9D 重定向：按 ServerReference 追加重连后握手成功', () async {
      fake.redirectFrom = '/ws/handshake';
      fake.redirectTo = '10.0.0.9:1234';

      final client = await MqttWsClient.connect(url: wsUrl, clientId: 'test-client');
      addTearDown(client.disconnect);

      expect(fake.connectAttempts, 2, reason: '首连 0x9D + 追加重连各一次');
      expect(fake.lastConnectPath, '/ws/handshake/10.0.0.9:1234');
      await client.subscribe('t/x');
      expect(fake.subscribedTopic, 't/x');
    });

    test('重定向超过上限报错', () async {
      fake.redirectFrom = '/ws/handshake';
      fake.redirectTo = '10.0.0.9:1234';
      // 追连目标也返回 0x9D → 追满 maxRedirects 后放弃
      fake.alwaysRedirect = true;

      await expectLater(
        MqttWsClient.connect(url: wsUrl, clientId: 'c', maxRedirects: 2),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg', contains('0x9d'))),
      );
      expect(fake.connectAttempts, 3);
    });

    test('CONNACK 拒绝（reason=0x05 未授权）直接抛错', () async {
      fake.rejectReason = 0x05;
      await expectLater(
        MqttWsClient.connect(url: wsUrl, clientId: 'c'),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg', contains('0x5'))),
      );
    });

    test('服务端主动断开时 done 完成', () async {
      fake.rejectReason = -1;
      final client = await MqttWsClient.connect(url: wsUrl, clientId: 'c');
      addTearDown(client.disconnect);
      fake.closeServer();
      await client.done.timeout(const Duration(seconds: 5));
    });
  });
}

/// UTF-8 字符串 + 2 字节长度前缀（测试辅助）。
List<int> _str(String s) {
  final b = utf8.encode(s);
  return [(b.length >> 8) & 0xFF, b.length & 0xFF, ...b];
}

/// 本地假 MQTT 服务端：只实现扫码登录用到的最小子集。
class _FakeMqttServer {
  WebSocket? _socket;
  String _path = '';

  /// 首连该路径时返回 0x9D，要求客户端切到 [redirectTo]。
  String redirectFrom = '';
  String redirectTo = '';
  /// 任何连接都返回 0x9D（测试重定向上限）。
  bool alwaysRedirect = false;
  /// >= 0 时 CONNACK 直接返回该错误码。
  int rejectReason = -1;

  final Map<String, String> connectUserProps = {};
  String connectAuthMethod = '';
  String? subscribedTopic;
  final Map<String, String> subscribeUserProps = {};
  final Completer<void> disconnectSeen = Completer<void>();
  int connectAttempts = 0;
  String lastConnectPath = '';

  void attach(WebSocket socket, String path) {
    _socket = socket;
    _path = path;
    socket.listen(_onData, onDone: () {});
  }

  void _onData(dynamic raw) {
    final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw as List<int>);
    switch (bytes[0] >> 4) {
      case MqttWire.typeConnect:
        connectAttempts++;
        lastConnectPath = _path;
        _parseConnect(bytes);
        _sendConnack();
      case 8: // SUBSCRIBE（8=SUBSCRIBE，9=SUBACK，别搞混）
        _parseSubscribe(bytes);
      case MqttWire.typeDisconnect:
        if (!disconnectSeen.isCompleted) disconnectSeen.complete();
      case MqttWire.typePingReq:
        _send(Uint8List.fromList([0xD0, 0x00]));
    }
  }

  void _parseConnect(Uint8List bytes) {
    // body = 协议名(6) + 版本(1) + 标志(1) + keepalive(2) + 属性 + clientId
    final bodyStart = MqttWire.decodeVarint(bytes, 1).end;
    final props = MqttWire.parseProperties(bytes, bodyStart + 10);
    connectUserProps
      ..clear()
      ..addAll(props.props.userProperties);
    // AUTH_METHOD(0x15) 是属性块第一项：0x15 + 2 字节长度 + 4 字节 "pass"
    final idx = _indexOf(bytes, [0x15, 0x00, 0x04, ...utf8.encode('pass')]);
    connectAuthMethod = idx >= 0 ? 'pass' : '';
  }

  void _parseSubscribe(Uint8List bytes) {
    // body = packetId(2) + 属性 + topic(2+N) + options(1)
    final props = MqttWire.parseProperties(bytes, 4);
    subscribeUserProps
      ..clear()
      ..addAll(props.props.userProperties);
    var p = props.end;
    final l = (bytes[p] << 8) | bytes[p + 1];
    p += 2;
    subscribedTopic = utf8.decode(bytes.sublist(p, p + l));
    // SUBACK：packet id 原样返回 + reason 0
    final pid = (bytes[2] << 8) | bytes[3];
    _send(Uint8List.fromList([0x90, 0x03, pid >> 8, pid & 0xFF, 0x00, 0x00]));
  }

  void _sendConnack() {
    if (rejectReason >= 0) {
      _connack(rejectReason, null);
      return;
    }
    final moved = alwaysRedirect || _path == redirectFrom;
    _connack(moved ? 0x9D : 0, moved ? redirectTo : null);
  }

  void _connack(int reason, String? serverReference) {
    final props = <int>[];
    if (serverReference != null) {
      props.add(0x1C);
      props.addAll(_str(serverReference));
    }
    final body = <int>[
      0x00,
      reason,
      ...MqttWire.encodeVarint(props.length),
      ...props,
    ];
    _send(Uint8List.fromList([0x20, ...MqttWire.encodeVarint(body.length), ...body]));
  }

  void publish(String topic, Map<String, String> userProps, String payload) {
    final props = <int>[];
    userProps.forEach((k, v) {
      props.add(0x26);
      props.addAll(_str(k));
      props.addAll(_str(v));
    });
    final body = <int>[
      ..._str(topic),
      ...MqttWire.encodeVarint(props.length),
      ...props,
      ...utf8.encode(payload),
    ];
    _send(Uint8List.fromList([0x30, ...MqttWire.encodeVarint(body.length), ...body]));
  }

  void closeServer() => _socket?.close();

  void _send(Uint8List data) => _socket?.add(data);
}

int _indexOf(Uint8List haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}
