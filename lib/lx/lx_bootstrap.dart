/// 洛雪（LX Music）音源宿主引导脚本（v2.5.7-pre3）。
///
/// **契约基准：LX-X 的 `android/app/src/main/assets/script/user-api-preload.js`**
/// （`globalThis.lx` / `EVENT_NAMES` / `on` / `send` / `request` / `utils` /
/// `currentScriptInfo` / `env` / `version` / `setTimeout`）。之前的实现只
/// 围绕用户导入的 4 个音源打补丁，导致「换一个音源就取不了流」。这里按
/// LX-X 的完整宿主环境重建，并在不改变标准语义的前提下保留若干超集
/// （sha1/sha256/hmac、aesDecrypt、更多 console 方法、更多 EVENT_NAMES），
/// 让符合 LX-X 环境的任意音源都能加载、注册、取流。
///
/// 与 LX-X 的差异仅在「原生桥接方式」：LX-X 用 `_nativeCall` 调 Android
/// 原生模块，这里用 flutter_js 的同步 `sendMessage` 把请求/定时器/初始化
/// 交给 Dart（见 lx_runtime.dart），异步结果再由 Dart `evaluate` 回写。
/// 脚本可见的 `lx` 对象、回调签名、请求/响应形状与 LX-X 保持一致。
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
    if (input && input.length !== undefined && typeof input !== 'function') {
      var out = [];
      for (var i = 0; i < input.length; i++) out.push(input[i] & 0xff);
      return out;
    }
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
  function b64ToBytes(input) {
    var lookup = {}, bc = _b64c, k;
    for (k = 0; k < bc.length; k++) lookup[bc[k]] = k;
    var clean = String(input).replace(/[^A-Za-z0-9+/]/g, ''), out = [];
    for (var m = 0; m < clean.length; m += 4) {
      var n = (lookup[clean[m]] << 18) | (lookup[clean[m + 1]] << 12) |
              ((lookup[clean[m + 2]] || 0) << 6) | (lookup[clean[m + 3]] || 0);
      out.push((n >> 16) & 255, (n >> 8) & 255, n & 255);
    }
    var pad = clean.length % 4;
    if (pad === 2) out.length -= 2; else if (pad === 3) out.length -= 1;
    return out;
  }

  // ===================== 同步加密桥（委托 Dart）=====================
  // 源脚本同步调用 utils.crypto.* 并立即使用结果（拼签名 URL），不能走
  // 异步桥；纯手写 JS 哈希易错，复用 Dart crypto / pointycastle 保证正确。
  function _callCrypto(spec) {
    return sendMessage('lx_crypto', JSON.stringify(spec));
  }
  // 返回 Uint8Array（LX-X 语义），同时挂上 Node Buffer 风格 toString，
  // 兼容「直接当字节数组用」与「buffer.bufToString(buf,'hex')」两类音源。
  function _typedBuf(bytes) {
    var u = new Uint8Array(bytes);
    u.toString = function (enc) { return BufferLike.from(bytes).toString(enc); };
    u.toJSON = function () { return Array.from(bytes); };
    return u;
  }
  function _cryptoBuf(spec) {
    return _typedBuf(b64ToBytes(_callCrypto(spec)));
  }

  // ===================== Buffer 兼容 =====================
  function BufferLike(bytes) {
    this._bytes = bytes;
    this.length = bytes.length;
    for (var i = 0; i < bytes.length; i++) this[i] = bytes[i];
  }
  BufferLike.from = function (input, enc) {
    if (input instanceof BufferLike) return new BufferLike(input._bytes.slice());
    if (input instanceof Uint8Array || Array.isArray(input)) return new BufferLike(Array.from(input));
    if (typeof input === 'string') {
      if (enc === 'hex') { var b = []; for (var i = 0; i < input.length; i += 2) b.push(parseInt(input.substr(i, 2), 16)); return new BufferLike(b); }
      if (enc === 'base64') return new BufferLike(b64ToBytes(input));
      if (enc === 'binary') return new BufferLike(utf8Bytes(input));
      return new BufferLike(utf8Bytes(input));
    }
    if (input && input.length !== undefined) return new BufferLike(toBytes(input));
    throw new Error('Buffer.from unsupported');
  };
  BufferLike.alloc = function (n, fill) { var b = []; for (var i = 0; i < n; i++) b.push(fill || 0); return new BufferLike(b); };
  BufferLike.prototype.toString = function (enc) {
    if (enc === 'hex') return hexOf(this._bytes);
    if (enc === 'base64') return bytesToB64(this._bytes);
    if (!enc || enc === 'utf8' || enc === 'utf-8') {
      return new TextDecoder().decode(this._bytes);
    }
    var s = ''; for (var i = 0; i < this._bytes.length; i++) s += String.fromCharCode(this._bytes[i]); return s;
  };
  BufferLike.prototype.toJSON = function () { return this._bytes.slice(); };
  BufferLike.prototype.slice = function (a, b) { return new BufferLike(this._bytes.slice(a, b)); };

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

  // ===================== console polyfill =====================
  // flutter_js 只注入 log / warn / error；LX-X 宿主环境提供完整 console。
  // 混淆音源大量使用 group/table/time，缺失会直接 TypeError 打断取链。
  var _console = (typeof globalThis.console !== 'undefined' && globalThis.console)
      ? globalThis.console : {};
  globalThis.console = _console;
  var _noop = function () {};
  ['debug', 'info', 'dir', 'table', 'trace', 'assert', 'count', 'countReset',
   'clear', 'group', 'groupCollapsed', 'groupEnd', 'time', 'timeLog', 'timeEnd',
   'profile', 'profileEnd'].forEach(function (k) {
    if (typeof _console[k] !== 'function') _console[k] = _noop;
  });
  ['log', 'warn', 'error'].forEach(function (level) {
    var original = typeof _console[level] === 'function' ? _console[level] : _noop;
    _console[level] = function () {
      try {
        var args = Array.prototype.slice.call(arguments).map(function (a) {
          if (typeof a === 'string') return a;
          try { return JSON.stringify(a); } catch (e) { return String(a); }
        });
        sendMessage('lx_console', JSON.stringify({ level: level, args: args }));
      } catch (e) {}
      try { return original.apply(_console, arguments); } catch (e) { return undefined; }
    };
  });

  // ===================== 定时器桥（LX-X 提供）=====================
  // LX-X 的 preload 用原生 setTimeout 驱动脚本；QuickJS 默认没有定时器。
  // 混淆音源常靠 setTimeout 做节流/重试，缺失即 "not a function"。
  var timerCallbacks = {};
  var timerSeq = 0;
  globalThis.setTimeout = function (callback, timeout) {
    if (typeof callback !== 'function') throw new Error('callback required a function');
    var ms = (typeof timeout === 'number' && timeout >= 0) ? timeout : 0;
    var id = ++timerSeq;
    var params = Array.prototype.slice.call(arguments, 2);
    // 函数参数不可 JSON 序列化，只透传可序列化的基本类型。
    var safe = params.map(function (p) {
      var t = typeof p;
      return (t === 'string' || t === 'number' || t === 'boolean' || p === null) ? p : null;
    });
    timerCallbacks[id] = { callback: callback, params: safe };
    sendMessage('lx_set_timeout', JSON.stringify({ id: id, ms: ms }));
    return id;
  };
  globalThis.clearTimeout = function (id) {
    if (id == null) return;
    delete timerCallbacks[id];
    sendMessage('lx_clear_timeout', JSON.stringify({ id: id }));
  };
  globalThis.__lxFireTimeout = function (id) {
    var t = timerCallbacks[id];
    if (!t) return;
    delete timerCallbacks[id];
    try { t.callback.apply(globalThis, t.params); } catch (e) {
      try { sendMessage('lx_console', JSON.stringify({ level: 'error', args: ['setTimeout callback: ' + String((e && e.message) || e)] })); } catch (_) {}
    }
  };

  var intervalCallbacks = {};
  globalThis.setInterval = function (callback, timeout) {
    if (typeof callback !== 'function') throw new Error('callback required a function');
    var ms = (typeof timeout === 'number' && timeout >= 0) ? timeout : 0;
    var id = ++timerSeq;
    intervalCallbacks[id] = callback;
    sendMessage('lx_set_interval', JSON.stringify({ id: id, ms: ms }));
    return id;
  };
  globalThis.clearInterval = function (id) {
    if (id == null) return;
    delete intervalCallbacks[id];
    sendMessage('lx_clear_interval', JSON.stringify({ id: id }));
  };
  globalThis.__lxFireInterval = function (id) {
    var cb = intervalCallbacks[id];
    if (!cb) return;
    try { cb.call(globalThis); } catch (e) {
      try { sendMessage('lx_console', JSON.stringify({ level: 'error', args: ['setInterval callback: ' + String((e && e.message) || e)] })); } catch (_) {}
    }
  };
  globalThis.setImmediate = function (callback) {
    return globalThis.setTimeout(callback, 0);
  };
  globalThis.clearImmediate = function (id) { globalThis.clearTimeout(id); };
  globalThis.queueMicrotask = function (callback) {
    return Promise.resolve().then(callback);
  };

  // ===================== 全局环境 polyfill（LX-X 契约超集）=====================
  // LX-X 原生层只注入 `lx` 与 setTimeout；但不少第三方音源会顺手用
  // atob/btoa、global、process、require 判断环境或做编码。缺一个就
  // "TypeError: not a function"，整份脚本加载失败且过去被静默吞掉。
  // 这些都是无害超集，不改变 LX-X 规定的 lx 契约。
  if (typeof globalThis.global === 'undefined') globalThis.global = globalThis;
  if (typeof globalThis.atob === 'undefined') {
    globalThis.atob = function (s) {
      var bytes = b64ToBytes(String(s)), out = '';
      for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
      return out;
    };
  }
  if (typeof globalThis.btoa === 'undefined') {
    globalThis.btoa = function (s) {
      var str = String(s), bytes = [];
      for (var i = 0; i < str.length; i++) {
        var c = str.charCodeAt(i);
        if (c > 255) throw new Error('InvalidCharacterError');
        bytes.push(c);
      }
      return bytesToB64(bytes);
    };
  }
  if (typeof globalThis.process === 'undefined') {
    globalThis.process = {
      env: {}, platform: 'android', version: '', versions: {},
      nextTick: function (cb) { return globalThis.setTimeout(cb, 0); }
    };
  }
  if (typeof globalThis.require === 'undefined') {
    globalThis.require = function () { return {}; };
  }
  if (typeof globalThis.crypto === 'undefined') {
    globalThis.crypto = {
      getRandomValues: function (arr) {
        var n = arr.length || 0;
        var bytes = b64ToBytes(_callCrypto({ algo: 'random', n: n }));
        for (var i = 0; i < n; i++) arr[i] = bytes[i] || 0;
        return arr;
      }
    };
  }
  if (typeof globalThis.performance === 'undefined') {
    globalThis.performance = { now: function () { return Date.now(); } };
  }
  // fetch 映射到 lx.request：让习惯用 fetch 的音源仍能走受控的 Dart HTTP 桥
  // （带超时 / 非 2xx 响应体），而不是绕过宿主直连网络。
  if (typeof globalThis.fetch === 'undefined') {
    globalThis.fetch = function (url, options) {
      options = options || {};
      var headers = {};
      var raw = options.headers;
      if (raw && typeof raw.forEach === 'function' && !Array.isArray(raw)) {
        try { raw.forEach(function (v, k) { headers[k] = v; }); } catch (_) {}
      } else if (raw && typeof raw === 'object') {
        for (var hk in raw) if (Object.prototype.hasOwnProperty.call(raw, hk)) headers[hk] = raw[hk];
      }
      return new Promise(function (resolve, reject) {
        globalThis.lx.request(String(url), {
          method: options.method || 'GET',
          headers: headers,
          body: options.body,
          timeout: options.timeout
        }, function (err, resp) {
          if (err) return reject(err);
          var b = resp.body;
          resolve({
            ok: resp.statusCode >= 200 && resp.statusCode < 300,
            status: resp.statusCode,
            statusText: resp.statusMessage || '',
            url: String(url),
            headers: {
              get: function (k) {
                return resp.headers[k] || resp.headers[String(k).toLowerCase()] || null;
              }
            },
            text: function () {
              return Promise.resolve(typeof b === 'string' ? b : JSON.stringify(b));
            },
            json: function () {
              return Promise.resolve(typeof b === 'string' ? JSON.parse(b) : b);
            },
            arrayBuffer: function () {
              var arr = (b && b.length !== undefined) ? Array.from(b) : [];
              return Promise.resolve(new Uint8Array(arr).buffer);
            }
          });
        });
      });
    };
  }

  // ===================== 响应体归一 =====================
  // 洛雪各版本 / 各音源对 resp.body 的期望不一致：
  //   - baimusic 用 parseBody 兼容「字符串」与「对象」；
  //   - ikun 直接读 body.code / body.url，要求已经是对象。
  // 只对「看起来是 JSON」的文本尝试解析；刻意不用 new String + Object.assign
  // 包装（typeof 变 object 会破坏 parseBody 的字符串分支）。
  function __lxBody(body) {
    if (typeof body !== 'string') return body;
    var t = body.trim();
    if (t.length === 0 || (t.charAt(0) !== '{' && t.charAt(0) !== '[')) return body;
    try {
      var v = JSON.parse(body);
      return (v !== null && typeof v === 'object') ? v : body;
    } catch (e) { return body; }
  }

  // ===================== LX 契约（对齐 LX-X preload）=====================
  var EVENT_NAMES = {
    request: 'request',
    inited: 'inited',
    updateAlert: 'updateAlert',
    // 超集：部分桌面版音源会读这些名字，LX-X 没有但不影响标准契约。
    updateLog: 'updateLog',
    log: 'log',
    error: 'error'
  };
  var allSources = ['kw', 'kg', 'tx', 'wy', 'mg', 'git', 'local'];
  var supportQualitys = {
    kw: ['128k', '320k', 'flac', 'hires', 'atmos', 'atmos_plus', 'master'],
    kg: ['128k', '320k', 'flac', 'hires', 'atmos', 'master'],
    tx: ['128k', '320k', 'flac', 'hires', 'atmos', 'atmos_plus', 'master'],
    wy: ['128k', '320k', 'flac', 'hires', 'atmos', 'master'],
    mg: ['128k', '320k', 'flac', 'hires'],
    git: ['128k', '320k', 'flac'],
    local: []
  };
  var supportActions = {
    kw: ['musicUrl'],
    kg: ['musicUrl'],
    tx: ['musicUrl'],
    wy: ['musicUrl'],
    mg: ['musicUrl'],
    git: ['musicUrl'],
    local: ['musicUrl', 'lyric', 'pic']
  };

  var requestCallbacks = {};
  var reqIdSeq = 0;
  var eventHandlers = {};
  var isInitedApi = false;
  var isShowedUpdateAlert = false;

  // LX-X handleInit：把音源声明按宿主支持范围规范化。这里对缺 `type`
  // 的音源宽容处理（默认 music），因为部分第三方源省略该字段。
  function normalizeInited(data) {
    var out = { status: true, openDevTools: false, sources: {} };
    var raw = (data && data.sources) || {};
    out.status = !!(data && data.status !== false);
    out.openDevTools = !!(data && data.openDevTools);
    for (var i = 0; i < allSources.length; i++) {
      var sub = allSources[i];
      var e = raw[sub];
      if (!e || typeof e !== 'object') continue;
      if (e.type && e.type !== 'music') continue;
      var declaredQ = Array.isArray(e.qualitys) ? e.qualitys : [];
      var declaredA = Array.isArray(e.actions) ? e.actions : [];
      var qualitys = [], actions = [], n;
      for (n = 0; n < declaredQ.length; n++) {
        if (supportQualitys[sub].indexOf(declaredQ[n]) >= 0) qualitys.push(declaredQ[n]);
      }
      for (n = 0; n < declaredA.length; n++) {
        if (supportActions[sub].indexOf(declaredA[n]) >= 0) actions.push(declaredA[n]);
      }
      out.sources[sub] = {
        type: 'music',
        name: (typeof e.name === 'string' && e.name) ? e.name : sub,
        actions: actions,
        qualitys: qualitys
      };
    }
    return out;
  }

  function unsupported(event) {
    return Promise.reject(new Error('The event is not supported: ' + event));
  }

  globalThis.lx = {
    EVENT_NAMES: EVENT_NAMES,
    // LX-X 是移动端宿主；按 env 分支的音源在 desktop 下会走错逻辑。
    env: 'mobile',
    version: '2.0.0',
    // 由 Dart 在加载脚本前用 __lxSetScriptInfo 注入（含 rawScript getter）。
    currentScriptInfo: {
      name: '', description: '', version: '', author: '', homepage: '', rawScript: ''
    },

    on: function (eventName, handler) {
      if (eventName !== EVENT_NAMES.request) return unsupported(eventName);
      eventHandlers[eventName] = handler;
      return Promise.resolve();
    },

    send: function (eventName, data) {
      switch (eventName) {
        case EVENT_NAMES.inited:
          if (isInitedApi) return Promise.reject(new Error('Script is inited'));
          isInitedApi = true;
          sendMessage('lx_inited', JSON.stringify({ data: normalizeInited(data) }));
          return Promise.resolve();
        case EVENT_NAMES.updateAlert:
          if (isShowedUpdateAlert) {
            return Promise.reject(new Error('The update alert can only be called once.'));
          }
          isShowedUpdateAlert = true;
          sendMessage('lx_update_alert', JSON.stringify({ data: data || {} }));
          return Promise.resolve();
        default:
          // 未知事件（log / error / updateLog 等）只记日志，不打断脚本。
          sendMessage('lx_send', JSON.stringify({ event: eventName, data: data }));
          return Promise.resolve();
      }
    },

    // LX-X：request(url, { method, timeout, headers, body, form, formData,
    // binary }, cb)，回调 (err, resp, body)，返回一个 abort 函数。
    request: function (url, options, callback) {
      var id = ++reqIdSeq;
      requestCallbacks[id] = callback;
      sendMessage('lx_request', JSON.stringify({
        reqId: id, url: String(url), opts: options || {}
      }));
      return function () {
        sendMessage('lx_abort_request', JSON.stringify({ reqId: id }));
      };
    },

    utils: {
      crypto: {
        // LX-X：md5(encodeURIComponent(str))。非字符串入参保留旧「原始字节」
        // 行为作超集，兼容把 Buffer 直接传进来的桌面版音源。
        md5: function (d) {
          if (typeof d === 'string') {
            return _callCrypto({ algo: 'md5', d: bytesToB64(utf8Bytes(encodeURIComponent(d))) });
          }
          return _callCrypto({ algo: 'md5', d: bytesToB64(toBytes(d)) });
        },
        sha1: function (d) { return _callCrypto({ algo: 'sha1', d: bytesToB64(toBytes(d)) }); },
        sha256: function (d) { return _callCrypto({ algo: 'sha256', d: bytesToB64(toBytes(d)) }); },
        hmacSha1: function (d, k) { return _callCrypto({ algo: 'hmacsha1', d: bytesToB64(toBytes(d)), k: bytesToB64(toBytes(k)) }); },
        hmacSha256: function (d, k) { return _callCrypto({ algo: 'hmacsha256', d: bytesToB64(toBytes(d)), k: bytesToB64(toBytes(k)) }); },
        randomBytes: function (n) { return _cryptoBuf({ algo: 'random', n: n }); },
        // 双签名兼容：
        //   LX-X   aesEncrypt(buffer, 'aes-128-cbc'|'aes-128-ecb', key, iv)
        //   桌面版 aesEncrypt(data, key, { mode:'cbc'|'ecb', iv })
        aesEncrypt: function (a, b, c, d) {
          var data, key, mode, iv;
          if (typeof b === 'string' && b.indexOf('aes-') === 0) {
            data = a; mode = b.indexOf('cbc') >= 0 ? 'cbc' : 'ecb'; key = c; iv = d;
          } else {
            data = a; key = b; c = c || {};
            mode = c.mode === 'cbc' ? 'cbc' : 'ecb'; iv = c.iv;
          }
          return _cryptoBuf({
            algo: 'aesenc',
            data: bytesToB64(toBytes(data)),
            key: bytesToB64(toBytes(key)),
            mode: mode,
            iv: iv ? bytesToB64(toBytes(iv)) : ''
          });
        },
        aesDecrypt: function (a, b, c) {
          c = c || {};
          return _cryptoBuf({
            algo: 'aesdec',
            data: bytesToB64(toBytes(a)),
            key: bytesToB64(toBytes(b)),
            mode: c.mode === 'cbc' ? 'cbc' : 'ecb',
            iv: c.iv ? bytesToB64(toBytes(c.iv)) : ''
          });
        },
        // LX-X 提供 rsaEncrypt(buffer, publicKey)（RSA/ECB/NoPadding）。
        // Dart 侧 pointycastle 实现；密钥头尾按 LX-X 语义剥离。
        rsaEncrypt: function (buffer, key) {
          if (typeof key !== 'string') throw new Error('Invalid RSA key');
          key = key.replace('-----BEGIN PUBLIC KEY-----', '')
                   .replace('-----END PUBLIC KEY-----', '');
          return _cryptoBuf({
            algo: 'rsaenc',
            data: bytesToB64(toBytes(buffer)),
            key: key,
            mode: 'nopadding'
          });
        }
      },
      buffer: {
        from: function (d, enc) { return BufferLike.from(d, enc); },
        bufToString: function (b, enc) { return BufferLike.from(b).toString(enc || 'utf8'); }
      }
    }
  };

  // 由 Dart 在 loadScript 前注入音源元信息；rawScript 用同步 getter 取回，
  // 避免把几十 KB 的脚本文本拼进 evaluate 表达式。
  globalThis.__lxSetScriptInfo = function (input) {
    // Dart 既可能传 JSON 字符串，也可能直接传对象字面量（evaluate 参数）。
    var info = (typeof input === 'string') ? JSON.parse(input) : (input || {});
    var target = globalThis.lx.currentScriptInfo;
    for (var k in info) {
      if (Object.prototype.hasOwnProperty.call(info, k) && k !== 'rawScript') {
        target[k] = info[k];
      }
    }
    Object.defineProperty(target, 'rawScript', {
      enumerable: true,
      configurable: true,
      // flutter_js 的通道对 sendMessage 的第二个参数做 jsonDecode(message)，
      // 传空串会抛 FormatException 打断脚本；这里必须传一段合法 JSON，
      // Dart 侧 handler 忽略入参、直接返回脚本文本。
      get: function () { return sendMessage('lx_raw_script', '{}'); }
    });
  };

  // Dart 侧派发事件：同步登记 Promise，立即返回，结果经 lx_result 回传。
  // LX-X 用 events.request.call(globalThis.lx, {source, action, info})。
  globalThis.__lxDispatch = function (id, payload) {
    var handler = eventHandlers[payload.event];
    if (!handler) {
      sendMessage('lx_result', JSON.stringify({ id: id, error: 'no handler for ' + payload.event }));
      return undefined;
    }
    try {
      var p = handler.call(globalThis.lx, payload.data);
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

  // LX-X 回调签名：(err, resp, body)。body 与 resp.body 同值；binary 响应
  // 由 Dart 传 base64，这里还原成 Uint8Array。
  globalThis.__lxResolveRequest = function (reqId, statusCode, statusMessage, body, isError, headers, isBinary) {
    var cb = requestCallbacks[reqId];
    if (!cb) return;
    delete requestCallbacks[reqId];
    if (isError) {
      cb(new Error(body), null, null);
      return;
    }
    var b = isBinary ? _typedBuf(b64ToBytes(body)) : __lxBody(body);
    var resp = {
      statusCode: statusCode,
      statusMessage: statusMessage || '',
      headers: headers || {},
      body: b
    };
    cb(null, resp, b);
  };
})();
''';
