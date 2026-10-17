// 最小 MQTT 5.0 over WebSocket 客户端（仅实现 QQ 音乐扫码登录所需的包类型）。
//
// 为什么不用 mqtt_client / mqtt5_client 包：
// - 本工程是纯原生六端 App（无 Web 目标），mqtt5_client 会拖入
//   csslib / universal_html 等 Web 冗余传递依赖，与工程谨慎管理依赖的
//   风格不符（参见 pubspec 里 permission_handler 的版本注释）；
// - 扫码登录只需要 CONNECT / SUBSCRIBE / PUBLISH / PINGREQ / DISCONNECT
//   五个包类型，自己实现约 300 行，行为完全可控、可单测。
//
// 协议依据：MQTT 5.0 规范 + QQ 音乐长连服务实测（沙箱内用 Python 参考
// 实现 qqmusic-api 的 paho 链路逐字节比对验证过）：
//
// - 握手：wss://mu.y.qq.com/ws/handshake，子协议 `mqtt`（服务端会回显），
//   Origin/Referer 必须为 y.qq.com；
// - CONNECT 属性：AuthenticationMethod="pass" + UserProperty
//   （tmeAppID=qqmusic / business=management / hashTag={qrcodeID} /
//   clientTag=management.user / userID={qrcodeID}）；
// - **CONNACK 可能返回 0x9D（Server moved）**：此时标准属性
//   ServerReference（0x1C，形如 `11.168.20.221:29001`）给出目标节点，
//   客户端要把该值拼到握手路径后重连（最多追 3 次）；
//   UserProperty 里的 `server`（下划线形式）只是提示，不能当重定向目标
//   （拼路径会 502，已实测）；
// - SUBSCRIBE 属性：UserProperty（authorization=tmelogin / pubsub=unicast）；
// - 心跳只用 MQTT 层 PINGREQ：**不能开 WebSocket 层 ping**，QQ 服务端
//   不响应 WS ping，开了会被服务端以 keepalive timeout 断开（已实测）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// MQTT 5.0 属性 ID（本客户端用到的子集，编号以规范为准）。
abstract final class _Prop {
  static const int payloadFormatIndicator = 0x01; // byte
  static const int messageExpiryInterval = 0x02; // 4 bytes
  static const int contentType = 0x03; // utf8
  static const int responseTopic = 0x08; // utf8
  static const int correlationData = 0x09; // binary
  static const int subscriptionIdentifier = 0x0B; // varint
  static const int sessionExpiryInterval = 0x11; // 4 bytes
  static const int assignedClientId = 0x12; // utf8
  static const int serverKeepAlive = 0x13; // 2 bytes
  static const int authenticationMethod = 0x15; // utf8
  static const int authenticationData = 0x16; // binary
  static const int requestProblemInfo = 0x17; // byte
  static const int willDelayInterval = 0x18; // 4 bytes
  static const int requestResponseInfo = 0x19; // byte
  static const int responseInfo = 0x1A; // utf8
  static const int serverReference = 0x1C; // utf8
  static const int reasonString = 0x1F; // utf8
  static const int receiveMaximum = 0x21; // 2 bytes
  static const int topicAliasMaximum = 0x22; // 2 bytes
  static const int topicAlias = 0x23; // 2 bytes
  static const int maximumQos = 0x24; // byte
  static const int retainAvailable = 0x25; // byte
  static const int userProperty = 0x26; // utf8 pair
  static const int maximumPacketSize = 0x27; // 4 bytes
  static const int wildcardSubscriptionAvailable = 0x28; // byte
  static const int subscriptionIdentifierAvailable = 0x29; // byte
  static const int sharedSubscriptionAvailable = 0x2A; // byte
}

/// 收到的一条 MQTT 消息。
class MqttMessage {
  MqttMessage(this.topic, this.userProperties, this.payload);

  final String topic;

  /// PUBLISH 属性里的 User Property（扫码事件类型就在 `type` 键上）。
  final Map<String, String> userProperties;

  final Uint8List payload;

  /// 载荷按 UTF-8 解码的文本（JSON 事件用）。
  String get payloadText => utf8.decode(payload, allowMalformed: true);
}

/// 解析出的属性（User Property 扁平表 + 关心的几个标量）。
typedef MqttParsedProps = ({
  Map<String, String> userProperties,
  int? serverKeepAlive,
  String? serverReference,
  String? reasonString,
});

/// CONNACK 解析结果。
typedef MqttConnack = ({int reason, int? serverKeepAlive, String? serverReference});

/// SUBACK 解析结果。
typedef MqttSuback = ({int packetId, int reason});

/// PUBLISH 解析结果。
typedef MqttPublish = ({
  String topic,
  int qos,
  Map<String, String> userProperties,
  Uint8List payload,
});

/// MQTT 5.0 报文编解码（纯函数，无 IO，便于单测）。
///
/// 公开是故意的：wire format 的正确性用真实抓包样本做单测，
/// 比隔着网络瞎试更快定位问题。
abstract final class MqttWire {
  /// 报文类型（固定头高 4 位）。
  static const int typeConnect = 1;
  static const int typeConnack = 2;
  static const int typePublish = 3;
  static const int typeSuback = 9;
  static const int typePingReq = 12;
  static const int typePingResp = 13;
  static const int typeDisconnect = 14;

  /// 编码 MQTT 变长整数（最多 4 字节）。
  static List<int> encodeVarint(int value) {
    if (value < 0 || value > 0x0FFFFFFF) {
      throw ArgumentError('varint 超出 MQTT 5.0 允许范围: $value');
    }
    final out = <int>[];
    var v = value;
    do {
      var b = v % 128;
      v ~/= 128;
      if (v > 0) b |= 0x80;
      out.add(b);
    } while (v > 0);
    return out;
  }

  /// 解码变长整数，返回 `(值, 结束位置)`；越界/畸形时 end = -1。
  static ({int value, int end}) decodeVarint(Uint8List bytes, int start) {
    var value = 0;
    var multiplier = 1;
    var p = start;
    for (var i = 0; i < 4; i++) {
      if (p >= bytes.length) return (value: -1, end: -1);
      final b = bytes[p++];
      value += (b & 0x7F) * multiplier;
      if ((b & 0x80) == 0) return (value: value, end: p);
      multiplier *= 128;
    }
    return (value: -1, end: -1); // 超过 4 字节仍带续位，畸形
  }

  /// 编码 UTF-8 字符串（2 字节长度前缀）。
  static List<int> encodeString(String s) {
    final b = utf8.encode(s);
    if (b.length > 0xFFFF) throw ArgumentError('字符串超长: ${b.length}');
    return [(b.length >> 8) & 0xFF, b.length & 0xFF, ...b];
  }

  /// 编码 User Property 属性块（0x26 + k + v，可重复）。
  static List<int> encodeUserProperties(Map<String, String> props) {
    final out = <int>[];
    for (final e in props.entries) {
      out.add(_Prop.userProperty);
      out.addAll(encodeString(e.key));
      out.addAll(encodeString(e.value));
    }
    return out;
  }

  /// 组装报文：固定头 + 变长剩余长度 + body。
  static Uint8List frame(int header, List<int> body) {
    return Uint8List.fromList([header, ...encodeVarint(body.length), ...body]);
  }

  /// 构造 CONNECT 报文（协议名/版本/标志/keepalive/属性/clientId）。
  static Uint8List buildConnect({
    required String clientId,
    required int keepAliveSecs,
    required Map<String, String> userProperties,
    String authMethod = 'pass',
  }) {
    final props = <int>[
      _Prop.authenticationMethod,
      ...encodeString(authMethod),
      ...encodeUserProperties(userProperties),
    ];
    final body = <int>[
      0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, // "MQTT"
      0x05, // 协议版本 5
      0x02, // Clean Start
      (keepAliveSecs >> 8) & 0xFF, keepAliveSecs & 0xFF,
      ...encodeVarint(props.length),
      ...props,
      ...encodeString(clientId),
    ];
    return frame(0x10, body);
  }

  /// 构造 SUBSCRIBE 报文（QoS 0）。
  static Uint8List buildSubscribe({
    required int packetId,
    required String topic,
    required Map<String, String> userProperties,
  }) {
    final props = encodeUserProperties(userProperties);
    final body = <int>[
      (packetId >> 8) & 0xFF, packetId & 0xFF,
      ...encodeVarint(props.length),
      ...props,
      ...encodeString(topic),
      0x00, // options：QoS 0
    ];
    return frame(0x82, body);
  }

  /// PINGREQ / DISCONNECT 报文。
  static Uint8List pingRequest() => frame(0xC0, const []);
  static Uint8List disconnect() => frame(0xE0, const [0x00]);

  /// 解析属性块（MQTT 5.0 全部属性类型的长度都已知，可安全跳过）。
  ///
  /// [start] 指向属性长度 varint 之前；返回的 `end` 为属性块结束位置。
  /// 畸形报文返回 `end = -1`。
  static ({MqttParsedProps props, int end}) parseProperties(
      Uint8List bytes, int start) {
    final len = decodeVarint(bytes, start);
    if (len.end < 0) return (props: _emptyProps(), end: -1);
    var p = len.end;
    final propsEnd = p + len.value;
    if (propsEnd > bytes.length) return (props: _emptyProps(), end: -1);
    final userProps = <String, String>{};
    int? serverKeepAlive;
    String? serverReference;
    String? reasonString;
    while (p < propsEnd) {
      final id = bytes[p++];
      switch (id) {
        case _Prop.userProperty:
          final k = _readString(bytes, p);
          if (k.end < 0) return (props: _emptyProps(), end: -1);
          final v = _readString(bytes, k.end);
          if (v.end < 0) return (props: _emptyProps(), end: -1);
          userProps[k.value] = v.value;
          p = v.end;
        case _Prop.serverKeepAlive:
          if (p + 2 > propsEnd) return (props: _emptyProps(), end: -1);
          serverKeepAlive = (bytes[p] << 8) | bytes[p + 1];
          p += 2;
        case _Prop.serverReference:
        case _Prop.reasonString:
        case _Prop.contentType:
        case _Prop.responseTopic:
        case _Prop.assignedClientId:
        case _Prop.authenticationMethod:
        case _Prop.responseInfo:
          final s = _readString(bytes, p);
          if (s.end < 0) return (props: _emptyProps(), end: -1);
          if (id == _Prop.serverReference) serverReference = s.value;
          if (id == _Prop.reasonString) reasonString = s.value;
          p = s.end;
        case _Prop.payloadFormatIndicator:
        case _Prop.requestProblemInfo:
        case _Prop.requestResponseInfo:
        case _Prop.maximumQos:
        case _Prop.retainAvailable:
        case _Prop.wildcardSubscriptionAvailable:
        case _Prop.subscriptionIdentifierAvailable:
        case _Prop.sharedSubscriptionAvailable:
          p += 1;
        case _Prop.messageExpiryInterval:
        case _Prop.sessionExpiryInterval:
        case _Prop.willDelayInterval:
        case _Prop.maximumPacketSize:
          p += 4;
        case _Prop.receiveMaximum:
        case _Prop.topicAliasMaximum:
        case _Prop.topicAlias:
          p += 2;
        case _Prop.subscriptionIdentifier:
          final v = decodeVarint(bytes, p);
          if (v.end < 0) return (props: _emptyProps(), end: -1);
          p = v.end;
        case _Prop.correlationData:
        case _Prop.authenticationData:
          final l = _readU16(bytes, p);
          if (l.end < 0) return (props: _emptyProps(), end: -1);
          p = l.end + l.value;
        default:
          // 未知属性：无法安全推断长度，放弃整包（调用方按丢弃处理）
          return (props: _emptyProps(), end: -1);
      }
    }
    return (props: (
      userProperties: userProps,
      serverKeepAlive: serverKeepAlive,
      serverReference: serverReference,
      reasonString: reasonString,
    ), end: propsEnd);
  }

  static ({int value, int end}) _readU16(Uint8List bytes, int p) {
    if (p + 2 > bytes.length) return (value: -1, end: -1);
    return (value: (bytes[p] << 8) | bytes[p + 1], end: p + 2);
  }

  static ({String value, int end}) _readString(Uint8List bytes, int p) {
    final l = _readU16(bytes, p);
    if (l.end < 0) return (value: '', end: -1);
    final end = l.end + l.value;
    if (end > bytes.length) return (value: '', end: -1);
    return (value: utf8.decode(bytes.sublist(l.end, end)), end: end);
  }

  static MqttParsedProps _emptyProps() => (
        userProperties: <String, String>{},
        serverKeepAlive: null,
        serverReference: null,
        reasonString: null,
      );

  /// 解析 CONNACK 报文；不是 CONNACK 或畸形时 reason = -1。
  static MqttConnack parseConnack(Uint8List bytes) {
    if (bytes.isEmpty || bytes[0] != 0x20) {
      return (reason: -1, serverKeepAlive: null, serverReference: null);
    }
    final len = decodeVarint(bytes, 1);
    if (len.end < 0) return (reason: -1, serverKeepAlive: null, serverReference: null);
    final bodyStart = len.end;
    if (bodyStart + 2 > bytes.length) {
      return (reason: -1, serverKeepAlive: null, serverReference: null);
    }
    final reason = bytes[bodyStart + 1];
    final props = parseProperties(bytes, bodyStart + 2);
    if (props.end < 0) {
      return (reason: -1, serverKeepAlive: null, serverReference: null);
    }
    return (
      reason: reason,
      serverKeepAlive: props.props.serverKeepAlive,
      serverReference: props.props.serverReference,
    );
  }

  /// 解析 SUBACK 报文（取最后一个 reason code，多主题订阅时逐主题返回，
  /// 扫码登录只订阅单个主题）。
  static MqttSuback parseSuback(Uint8List bytes) {
    final bad = const (packetId: -1, reason: -1);
    if (bytes.isEmpty || bytes[0] != 0x90) return bad;
    final len = decodeVarint(bytes, 1);
    if (len.end < 0) return bad;
    final bodyStart = len.end;
    if (bodyStart + 2 > bytes.length) return bad;
    final packetId = (bytes[bodyStart] << 8) | bytes[bodyStart + 1];
    final props = parseProperties(bytes, bodyStart + 2);
    if (props.end < 0) return bad;
    if (props.end >= bytes.length) return bad;
    return (packetId: packetId, reason: bytes[bytes.length - 1]);
  }

  /// 解析 PUBLISH 报文；不是 PUBLISH 或畸形时 topic 为空串。
  static MqttPublish parsePublish(Uint8List bytes) {
    final bad = (topic: '', qos: 0, userProperties: <String, String>{}, payload: Uint8List(0));
    if (bytes.isEmpty || (bytes[0] >> 4) != typePublish) return bad;
    final len = decodeVarint(bytes, 1);
    if (len.end < 0) return bad;
    final packetEnd = len.end + len.value;
    if (packetEnd > bytes.length) return bad;
    final qos = (bytes[0] >> 1) & 0x03;
    var p = len.end;
    final topic = _readString(bytes, p);
    if (topic.end < 0) return bad;
    p = topic.end;
    if (qos > 0) {
      p += 2; // packet identifier（QoS 0 不出现）
    }
    final props = parseProperties(bytes, p);
    if (props.end < 0) return bad;
    return (
      topic: topic.value,
      qos: qos,
      userProperties: props.props.userProperties,
      payload: Uint8List.sublistView(bytes, props.end, packetEnd),
    );
  }

  /// 按 ServerReference 生成重连 URL。
  ///
  /// 规则（与 Python 参考实现一致）：路径末段含 `:` 时整段替换，否则追加。
  /// 例：`wss://mu.y.qq.com/ws/handshake` + `11.168.20.221:29001`
  /// → `wss://mu.y.qq.com/ws/handshake/11.168.20.221:29001`。
  static String redirectUrl(String url, String serverReference) {
    final uri = Uri.parse(url);
    // pathSegments 返回不可变列表，必须拷贝后再改
    final segments = [...uri.pathSegments];
    if (segments.isNotEmpty && segments.last.contains(':')) {
      segments[segments.length - 1] = serverReference;
    } else {
      segments.add(serverReference);
    }
    return uri.replace(pathSegments: segments).toString();
  }
}

/// MQTT 5.0 WebSocket 客户端（最小子集）。
class MqttWsClient {
  MqttWsClient._(this._socket, this._keepAliveSecs);

  final WebSocket _socket;
  int _keepAliveSecs;

  final _messages = StreamController<MqttMessage>.broadcast();
  final _done = Completer<void>();

  /// 等待 CONNACK / SUBACK 的队列（本客户端的用法是严格串行的）。
  final _awaiters = <Completer<Uint8List>>[];

  int _packetId = 0;
  Timer? _pingTimer;
  bool _closed = false;
  StreamSubscription<dynamic>? _subscription;

  /// 消息流（订阅主题上的 PUBLISH）。
  Stream<MqttMessage> get messages => _messages.stream;

  /// 连接关闭（服务端断开或本端 disconnect）时完成。
  Future<void> get done => _done.future;

  /// 建立连接并完成 MQTT 握手（CONNECT → CONNACK，自动跟随 0x9D 重定向）。
  ///
  /// - [url]：WebSocket 地址，如 `wss://mu.y.qq.com/ws/handshake`。
  /// - [clientId]：客户端标识（服务端按它寻址，扫码场景用随机值即可）。
  /// - [userProperties]：CONNECT 属性里的 User Property，服务端用它
  ///   识别调用方身份（QQ 音乐场景：tmeAppID / business / hashTag /
  ///   clientTag / userID）。
  /// - [headers]：WebSocket 握手附加头（Origin / Referer 等）。
  /// - [timeout]：单次连接/握手的超时（重定向会重新计算）。
  static Future<MqttWsClient> connect({
    required String url,
    required String clientId,
    int keepAliveSecs = 45,
    Map<String, String> userProperties = const {},
    Map<String, String> headers = const {},
    List<String> protocols = const ['mqtt'],
    int maxRedirects = 3,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    var currentUrl = url;
    for (var attempt = 0;; attempt++) {
      final socket = await WebSocket.connect(
        currentUrl,
        headers: headers,
        protocols: protocols.isEmpty ? null : protocols,
      ).timeout(timeout);
      final client = MqttWsClient._(socket, keepAliveSecs);
      client._attach();

      try {
        socket.add(MqttWire.buildConnect(
          clientId: clientId,
          keepAliveSecs: keepAliveSecs,
          userProperties: userProperties,
        ));
        final connackRaw = await client._nextPacket().timeout(timeout);
        final connack = MqttWire.parseConnack(connackRaw);
        if (connack.reason < 0) {
          throw Exception('MQTT 握手失败：CONNACK 无法解析');
        }
        if (connack.reason == 0) {
          // 服务端可以下调 keepalive，以它为准
          if (connack.serverKeepAlive != null && connack.serverKeepAlive! > 0) {
            client._keepAliveSecs = connack.serverKeepAlive!;
          }
          client._startPing();
          return client;
        }
        final ref = connack.serverReference;
        final moved = connack.reason == 0x9C || connack.reason == 0x9D;
        if (!(moved && ref != null && ref.isNotEmpty && attempt < maxRedirects)) {
          throw Exception(
              'MQTT 连接被拒绝 reason=0x${connack.reason.toRadixString(16)}'
              '${connack.reason == 0x9D ? "（服务端要求切换节点 $ref）" : ""}');
        }
        // 0x9C/0x9D：按 ServerReference 切换节点重连
        // （上面的守卫条件 `ref != null && ref.isNotEmpty` 已完成类型收窄）
        await client._abort();
        currentUrl = MqttWire.redirectUrl(currentUrl, ref);
      } catch (_) {
        await client._abort();
        rethrow;
      }
    }
  }

  /// 订阅主题。[userProperties] 写在 SUBSCRIBE 属性里（QQ 音乐场景：
  /// authorization=tmelogin / pubsub=unicast）。
  Future<void> subscribe(
    String topic, {
    Map<String, String> userProperties = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (_closed) throw Exception('MQTT 连接已关闭');
    final id = ++_packetId;
    _socket.add(MqttWire.buildSubscribe(
      packetId: id,
      topic: topic,
      userProperties: userProperties,
    ));
    final raw = await _nextPacket().timeout(timeout);
    final suback = MqttWire.parseSuback(raw);
    if (suback.packetId != id) {
      throw Exception('MQTT SUBACK packet id 不匹配（期望 $id，实际 ${suback.packetId}）');
    }
    if (suback.reason >= 0x80) {
      throw Exception('MQTT 订阅被拒绝 reason=0x${suback.reason.toRadixString(16)}');
    }
  }

  /// 主动断开（发 DISCONNECT 后关闭 WebSocket）。
  Future<void> disconnect() async {
    if (_closed) return;
    try {
      _socket.add(MqttWire.disconnect());
      await _socket.close();
    } catch (_) {
      // 忽略关闭异常
    }
    _closeQuietly();
  }

  // ================= 内部 =================

  void _attach() {
    _subscription = _socket.listen(
      (dynamic raw) {
        final bytes = raw is Uint8List
            ? raw
            : raw is List<int>
                ? Uint8List.fromList(raw)
                : null;
        if (bytes == null || bytes.isEmpty) return;
        try {
          _onFrame(bytes);
        } catch (_) {
          // 单包解析失败不应中断连接
        }
      },
      onError: (Object e, StackTrace s) {
        _messages.addError(e, s);
        _closeQuietly();
      },
      onDone: _closeQuietly,
      cancelOnError: false,
    );
  }

  void _onFrame(Uint8List bytes) {
    final type = bytes[0] >> 4;
    switch (type) {
      case MqttWire.typePublish:
        final pub = MqttWire.parsePublish(bytes);
        if (pub.topic.isNotEmpty) {
          _messages.add(MqttMessage(pub.topic, pub.userProperties, pub.payload));
        }
      case MqttWire.typePingResp:
        break; // 心跳应答，无需处理
      case MqttWire.typeDisconnect:
        _closeQuietly(); // 服务端主动断开
      default:
        // CONNACK / SUBACK 交给 _nextPacket 的等待者
        if (_awaiters.isNotEmpty && !_awaiters.first.isCompleted) {
          _awaiters.removeAt(0).complete(bytes);
        }
    }
  }

  /// 等待下一个「非 PUBLISH」报文（CONNACK / SUBACK）。
  Future<Uint8List> _nextPacket() {
    final c = Completer<Uint8List>();
    _awaiters.add(c);
    return c.future;
  }

  void _startPing() {
    _pingTimer?.cancel();
    // keepalive 的一半，钳制在 [5, 60] 秒；只用 MQTT 层 PINGREQ
    final interval =
        Duration(seconds: (_keepAliveSecs / 2).round().clamp(5, 60));
    _pingTimer = Timer.periodic(interval, (_) {
      if (_closed) return;
      try {
        _socket.add(MqttWire.pingRequest());
      } catch (_) {
        _closeQuietly();
      }
    });
  }

  /// 握手失败时静默销毁（不发 DISCONNECT，连接本就不可用）。
  Future<void> _abort() async {
    try {
      await _subscription?.cancel();
      await _socket.close();
    } catch (_) {
      // 忽略
    }
    _closeQuietly();
  }

  void _closeQuietly() {
    if (_closed) return;
    _closed = true;
    _pingTimer?.cancel();
    _pingTimer = null;
    for (final c in _awaiters) {
      if (!c.isCompleted) c.completeError(Exception('MQTT 连接已关闭'));
    }
    _awaiters.clear();
    _subscription?.cancel();
    if (!_done.isCompleted) _done.complete();
    _messages.close();
  }
}
