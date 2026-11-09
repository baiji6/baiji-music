/// 洛雪（LX Music）音源宿主引导脚本。
///
/// 在 flutter_js 的 QuickJS / JSCore 运行时里最先执行，负责：
/// 1. 定义 `globalThis.lx` 契约对象（`on` / `send` / `request` / `EVENT_NAMES` /
///    `env` / `version` / `utils.crypto` / `utils.buffer`）；
/// 2. 提供 `TextEncoder` / `TextDecoder` / `Buffer` polyfill（QuickJS 原生没有）；
/// 3. 桥接 `dispatch` / `request` 的消息闭环（异步，不阻塞 `evaluate`）；
/// 4. 把 `utils.crypto` 的哈希 / HMAC / 随机字节**同步委托给 Dart**（经
///    `sendMessage('lx_crypto', …)` 同步取回结果）——因为源脚本是**同步**调用
///    它们并立即使用结果（如拼签名 URL），不能走异步桥；而纯手写的 JS 哈希
///    易错，故复用 Dart `crypto` / `pointycastle` 保证正确性。
///
/// `sendMessage` 在 QuickJS / JSCore 下都是同步调用、并把 Dart 处理函数的
/// 返回值直接回传给 JS（见 flutter_js 的 `initChannelFunctions` 与
/// `_sendMessage`），因此这条「同步加密桥」两端都可用。
const String lxBootstrapJs = r'''
(function () {
  // ===================== 字节 / 编码工具 =====================
  function utf8Bytes(str) {
    var out = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) { out.push(0xc0 | (c >> 6), 0x80 | (c & 63)); }
      else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
        var n = 0x10000 + ((c - 0xd800) << 10) + (str.charCodeAt(++i) - 0xdc00);
        out.push(0xf0 | (n >> 18), 0x80 | ((n >> 12) & 63), 0x80 | ((n >> 6) & 63), 0x80 | (n & 63));
      } else { out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)); }
    }
    return out;
  }
  function toBytes(input) {
    if (typeof input === 'string') return utf8Bytes(input);
    if (input instanceof Uint8Array) return Array.from(input);
    if (Array.isArray(input)) return input.map(function (b) { return b & 0xff; });
    if (input && input._bytes) return input._bytes.slice();
    throw new Error('unsupported crypto input');
  }
  function hexOf(bytes) {
    var s = '', h = '0123456789abcdef';
    for (var i = 0; i < bytes.length; i++) s += h[(bytes[i] >> 4) & 15] + h[bytes[i] & 15];
    return s;
  }
  var _b64c = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function bytesToB64(bytes) {
    var out = '', i;
    for (i = 0; i + 2 < bytes.length; i += 3) {
      var n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += _b64c[(n >> 18) & 63] + _b64c[(n >> 12) & 63] + _b64c[(n >> 6) & 63] + _b64c[n & 63];
    }
    var rem = bytes.length - i;
    if (rem === 1) { var a = bytes[i]; out += _b64c[a >> 2] + _b64c[(a << 4) & 63] + '=='; }
    else if (rem === 2) { var b = (bytes[i] << 8) | bytes[i + 1]; out += _b64c[b >> 10] + _b64c[(b >> 4) & 63] + _b64c[(b << 2) & 63] + '='; }
    return out;
  }

  // ===================== 同步加密桥（委托 Dart）=====================
  // 所有哈希 / HMAC / 随机字节都同步委托给 Dart 的 crypto 等库，避免手写 JS 出错。
  function _callCrypto(spec) {
    return sendMessage('lx_crypto', JSON.stringify(spec));
  }
  // random / AES 的 Dart 结果是 base64，解成 BufferLike（等价 Node Buffer，
  // 支持 .toString('hex'|'base64'|'utf8') / .toJSON() / toBytes 输入）。
  function _cryptoBuf(spec) {
    return BufferLike.from(_callCrypto(spec), 'base64');
  }

  // ===================== Buffer 兼容 =====================
  function BufferLike(bytes) { this._bytes = bytes; }
  BufferLike.from = function (input, enc) {
    if (input instanceof Uint8Array || Array.isArray(input)) return new BufferLike(Array.from(input));
    if (typeof input === 'string') {
      if (enc === 'hex') { var b = []; for (var i = 0; i < input.length; i += 2) b.push(parseInt(input.substr(i, 2), 16)); return new BufferLike(b); }
      if (enc === 'base64') {
        var lookup = {}, bc = _b64c;
        for (var k = 0; k < bc.length; k++) lookup[bc[k]] = k;
        var clean = input.replace(/[^A-Za-z0-9+/]/g, ''), out = [], j = 0;
        for (var m = 0; m < clean.length; m += 4) {
          var n = (lookup[clean[m]] << 18) | (lookup[clean[m + 1]] << 12) | ((lookup[clean[m + 2]] || 0) << 6) | (lookup[clean[m + 3]] || 0);
          out.push((n >> 16) & 255, (n >> 8) & 255, n & 255);
        }
        var pad = clean.length % 4;
        if (pad === 2) out.length -= 2; else if (pad === 3) out.length -= 1;
        return new BufferLike(out);
      }
      return new BufferLike(utf8Bytes(input));
    }
    throw new Error('Buffer.from unsupported');
  };
  BufferLike.alloc = function (n, fill) { var b = []; for (var i = 0; i < n; i++) b.push(fill || 0); return new BufferLike(b); };
  BufferLike.prototype.toString = function (enc) {
    if (enc === 'hex') return hexOf(this._bytes);
    if (enc === 'base64') return bytesToB64(this._bytes);
    // Node Buffer.toString() 默认 utf8：多字节字符必须按 UTF-8 解码，
    // 逐字节 String.fromCharCode 会把中文变乱码（混淆源常处理中文歌名）。
    if (!enc || enc === 'utf8' || enc === 'utf-8') {
      return new TextDecoder().decode(this._bytes);
    }
    var s = ''; for (var i = 0; i < this._bytes.length; i++) s += String.fromCharCode(this._bytes[i]); return s;
  };
  BufferLike.prototype.toJSON = function () { return this._bytes.slice(); };

  // ===================== TextEncoder / TextDecoder =====================
  function TextEncoder() {}
  TextEncoder.prototype.encode = function (str) { return new Uint8Array(utf8Bytes(str)); };
  function TextDecoder() {}
  TextDecoder.prototype.decode = function (bytes) {
    var arr = (bytes instanceof Uint8Array) ? Array.from(bytes) : bytes;
    var out = '', i = 0;
    while (i < arr.length) {
      var b = arr[i];
      if (b < 0x80) { out += String.fromCharCode(b); i++; }
      else if (b < 0xe0) { out += String.fromCodePoint(((b & 0x1f) << 6) | (arr[i + 1] & 0x3f)); i += 2; }
      else if (b < 0xf0) { out += String.fromCodePoint(((b & 0x0f) << 12) | ((arr[i + 1] & 0x3f) << 6) | (arr[i + 2] & 0x3f)); i += 3; }
      else { out += String.fromCodePoint(((b & 0x07) << 18) | ((arr[i + 1] & 0x3f) << 12) | ((arr[i + 2] & 0x3f) << 6) | (arr[i + 3] & 0x3f)); i += 4; }
    }
    return out;
  };

  if (typeof globalThis.TextEncoder === 'undefined') globalThis.TextEncoder = TextEncoder;
  if (typeof globalThis.TextDecoder === 'undefined') globalThis.TextDecoder = TextDecoder;
  if (typeof globalThis.Buffer === 'undefined') globalThis.Buffer = BufferLike;

  // ===================== LX 契约 + 消息桥 =====================
  var requestCallbacks = {};
  var reqIdSeq = 0;
  var eventHandlers = {};

  globalThis.lx = {
    EVENT_NAMES: { request: 'request', inited: 'inited' },
    env: 'desktop',
    version: '1.0.0',
    on: function (event, handler) { eventHandlers[event] = handler; },
    send: function (event, data) {
      if (event === 'inited') {
        sendMessage('lx_inited', JSON.stringify({ data: data }));
      } else {
        sendMessage('lx_send', JSON.stringify({ event: event, data: data }));
      }
    },
    request: function (url, options, callback) {
      var id = ++reqIdSeq;
      requestCallbacks[id] = callback;
      sendMessage('lx_request', JSON.stringify({ reqId: id, url: url, opts: options || {} }));
    },
    utils: {
      crypto: {
        md5: function (d) { return _callCrypto({ algo: 'md5', d: bytesToB64(toBytes(d)) }); },
        sha1: function (d) { return _callCrypto({ algo: 'sha1', d: bytesToB64(toBytes(d)) }); },
        sha256: function (d) { return _callCrypto({ algo: 'sha256', d: bytesToB64(toBytes(d)) }); },
        hmacSha1: function (d, k) { return _callCrypto({ algo: 'hmacsha1', d: bytesToB64(toBytes(d)), k: bytesToB64(toBytes(k)) }); },
        hmacSha256: function (d, k) { return _callCrypto({ algo: 'hmacsha256', d: bytesToB64(toBytes(d)), k: bytesToB64(toBytes(k)) }); },
        randomBytes: function (n) { return _cryptoBuf({ algo: 'random', n: n }); },
        aesEncrypt: function (data, key, opts) {
          opts = opts || {};
          return _cryptoBuf({ algo: 'aesenc', data: bytesToB64(toBytes(data)), key: bytesToB64(toBytes(key)), mode: opts.mode === 'cbc' ? 'cbc' : 'ecb', iv: opts.iv ? bytesToB64(toBytes(opts.iv)) : '' });
        },
        aesDecrypt: function (data, key, opts) {
          opts = opts || {};
          return _cryptoBuf({ algo: 'aesdec', data: bytesToB64(toBytes(data)), key: bytesToB64(toBytes(key)), mode: opts.mode === 'cbc' ? 'cbc' : 'ecb', iv: opts.iv ? bytesToB64(toBytes(opts.iv)) : '' });
        }
      },
      buffer: {
        from: function (d, enc) { return BufferLike.from(d, enc); },
        bufToString: function (b, enc) { return BufferLike.from(b).toString(enc); }
      }
    }
  };

  // Dart 侧派发事件：同步登记 Promise，立即返回，结果经 lx_result 回传。
  globalThis.__lxDispatch = function (id, payload) {
    var handler = eventHandlers[payload.event];
    if (!handler) {
      sendMessage('lx_result', JSON.stringify({ id: id, error: 'no handler for ' + payload.event }));
      return undefined;
    }
    try {
      var p = handler(payload.data);
      Promise.resolve(p).then(function (result) {
        sendMessage('lx_result', JSON.stringify({ id: id, result: result }));
      }).catch(function (err) {
        sendMessage('lx_result', JSON.stringify({ id: id, error: String((err && err.message) || err) }));
      });
    } catch (e) {
      sendMessage('lx_result', JSON.stringify({ id: id, error: String((e && e.message) || e) }));
    }
    return undefined;
  };

  // Dart 侧回调 lx.request 的 (err, resp)
  globalThis.__lxResolveRequest = function (reqId, statusCode, body, isError) {
    var cb = requestCallbacks[reqId];
    if (!cb) return;
    delete requestCallbacks[reqId];
    if (isError) cb(body, null);
    else cb(null, { statusCode: statusCode, body: body, headers: {} });
  };
})();
''';
