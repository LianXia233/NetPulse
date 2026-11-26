/*
 * LinkSwift 在内置浏览器中的 Greasemonkey 兼容层。
 *
 * 页面脚本没有 GM_* 环境，这里用最小实现补齐：跨域请求走 NpPage 桥接
 * 到宿主网络栈（复用下载器的 DNS / 代理 / 重定向逻辑），键值存储落在
 * 当前站点自己的 localStorage 上，其余命令类 API 做安全降级。
 *
 * 只导出 window.__npGM，不污染页面全局。
 */
(function () {
  'use strict';
  if (window.__npGM) return;

  // 依赖库是按页面全局挂载的，这里取到引用后立刻还原，
  // 免得覆盖掉页面自己的 jQuery（123 云盘、百度网盘都自带一套）。
  var jq = window.jQuery;
  var prev = window.__npPrev || {};
  if (jq && typeof jq.noConflict === 'function') {
    var freed = jq.noConflict(true);
    if (freed) jq = freed;
  } else {
    window.$ = prev.dollar;
    window.jQuery = prev.jq;
  }
  var vendor = {
    jQuery: jq,
    Swal: window.Swal,
    md5: window.md5,
    sha256: window.sha256,
  };
  window.Swal = prev.Swal;
  window.md5 = prev.md5;
  window.sha256 = prev.sha256;
  window.__npVendor = vendor;
  window.__npPrev = null;

  var STORE_KEY = '__npGmStore';
  var mem = null;

  function store() {
    if (mem) return mem;
    mem = {};
    try {
      var raw = localStorage.getItem(STORE_KEY);
      if (raw) {
        var obj = JSON.parse(raw);
        if (obj && typeof obj === 'object') mem = obj;
      }
    } catch (e) {}
    return mem;
  }

  function persist() {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify(store()));
    } catch (e) {}
  }

  function getValue(name, fallback) {
    var key = String(name);
    var s = store();
    if (Object.prototype.hasOwnProperty.call(s, key)) {
      var v = s[key];
      if (typeof v === 'string') {
        try {
          return JSON.parse(v);
        } catch (e) {
          return v;
        }
      }
      return v;
    }
    return fallback === undefined ? undefined : fallback;
  }

  function setValue(name, value) {
    store()[String(name)] = value;
    persist();
  }

  function deleteValue(name) {
    delete store()[String(name)];
    persist();
  }

  function toHeaders(input) {
    var out = {};
    if (!input) return out;
    if (typeof input === 'string') {
      input.split(/\r?\n/).forEach(function (line) {
        var i = line.indexOf(':');
        if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
      });
      return out;
    }
    if (Array.isArray(input)) {
      input.forEach(function (kv) {
        if (kv && kv.name) out[String(kv.name)] = String(kv.value == null ? '' : kv.value);
      });
      return out;
    }
    for (var k in input) {
      if (!Object.prototype.hasOwnProperty.call(input, k)) continue;
      if (input[k] == null) continue;
      out[k] = String(input[k]);
    }
    return out;
  }

  function hasHeader(headers, name) {
    var lower = name.toLowerCase();
    for (var k in headers) {
      if (k.toLowerCase() === lower) return true;
    }
    return false;
  }

  function bodyToString(data) {
    if (data == null) return '';
    if (typeof data === 'string') return data;
    if (typeof URLSearchParams !== 'undefined' && data instanceof URLSearchParams) {
      return data.toString();
    }
    if (typeof FormData !== 'undefined' && data instanceof FormData) {
      // 桥接只传文本，表单按 urlencoded 展开。
      var parts = [];
      data.forEach(function (v, k) {
        parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(v)));
      });
      return parts.join('&');
    }
    if (typeof ArrayBuffer !== 'undefined' && data instanceof ArrayBuffer) {
      return '';
    }
    if (typeof data === 'object') {
      try {
        return JSON.stringify(data);
      } catch (e) {
        return String(data);
      }
    }
    return String(data);
  }

  var seq = 0;

  // 复用页面脚本注入器建立的 bridge（__npPagePending / __npPageReply）。
  function ensureBridge() {
    if (typeof window.__npPageReply === 'function' && window.__npPagePending) return;
    window.__npPagePending = window.__npPagePending || {};
    window.__npPageReply = function (id, ok, payload) {
      var p = window.__npPagePending[id];
      if (!p) return;
      delete window.__npPagePending[id];
      var value = null;
      try {
        value = JSON.parse(payload || 'null');
      } catch (e) {
        value = null;
      }
      if (ok) p.resolve(value);
      else p.reject(new Error(String(payload || '请求失败')));
    };
  }

  function bridgeCall(op, data) {
    ensureBridge();
    return new Promise(function (resolve, reject) {
      var id = 'g' + ++seq + '_' + Date.now();
      window.__npPagePending[id] = { resolve: resolve, reject: reject };
      NpPage.postMessage(JSON.stringify({ id: id, op: op, data: data || {} }));
    });
  }

  function headerLines(obj) {
    var lines = [];
    for (var k in obj) lines.push(k + ': ' + obj[k]);
    return lines.join('\r\n');
  }

  function xmlHttpRequest(details) {
    var opts = details || {};
    var url = String(opts.url || '');
    var method = String(opts.method || 'GET').toUpperCase();
    var headers = toHeaders(opts.headers);
    // 脚本本身只在部分网盘显式塞 Cookie，其余请求用当前站点登录态兜底。
    if (!hasHeader(headers, 'cookie') && document.cookie) {
      headers['Cookie'] = document.cookie;
    }
    var body = bodyToString(opts.data);
    var timeoutMs = typeof opts.timeout === 'number' && opts.timeout > 0 ? opts.timeout : 30000;
    var settled = false;
    var aborted = false;

    var handle = {
      abort: function () {
        aborted = true;
      },
      getAllResponseHeaders: function () {
        return handle.__headers || '';
      },
    };

    function emit(name, payload) {
      var fn = opts[name];
      if (typeof fn === 'function') {
        try {
          fn(payload);
        } catch (e) {}
      }
    }

    emit('onloadstart', { readyState: 3, status: 0, finalUrl: url });

    var timer = setTimeout(function () {
      if (settled) return;
      settled = true;
      emit('ontimeout', { status: 0, statusText: 'timeout', error: '请求超时', finalUrl: url });
    }, timeoutMs);

    bridgeCall('fetch', {
      url: url,
      method: method,
      headers: headers,
      body: body,
      timeoutMs: timeoutMs,
      maxBytes: 16 * 1024 * 1024,
    })
      .then(function (res) {
        if (settled || aborted) return;
        settled = true;
        clearTimeout(timer);
        var data = res || {};
        var text = typeof data.body === 'string' ? data.body : '';
        var hdrs = data.headers && typeof data.headers === 'object' ? data.headers : {};
        handle.__headers = headerLines(hdrs);
        var payload = {
          readyState: 4,
          status: Number(data.status || 0),
          statusText: String(data.status || ''),
          responseText: text,
          response: text,
          responseHeaders: hdrs,
          finalUrl: data.finalUrl || url,
          truncated: !!data.truncated,
        };
        emit('onload', payload);
        emit('onloadend', payload);
      })
      .catch(function (e) {
        if (settled || aborted) return;
        settled = true;
        clearTimeout(timer);
        emit('onerror', {
          status: 0,
          statusText: String((e && e.message) || e),
          error: String((e && e.message) || e),
          finalUrl: url,
        });
        emit('onloadend', { status: 0, responseText: '', finalUrl: url });
      });

    return handle;
  }

  var menus = [];

  var gm = {
    GM_info: {
      script: {
        name: 'LinkSwift',
        version: '1.1.3',
        author: 'Hmjz100、油小猴',
        description: '网盘文件下载地址获取工具',
      },
      scriptHandler: 'NetPulse',
      version: '1.0',
    },
    GM: { xmlHttpRequest: xmlHttpRequest },
    GM_xmlhttpRequest: xmlHttpRequest,
    GM_getValue: getValue,
    GM_setValue: setValue,
    GM_deleteValue: deleteValue,
    GM_getResourceText: function (name) {
      var res = window.__npResources || {};
      return typeof res[name] === 'string' ? res[name] : '';
    },
    GM_registerMenuCommand: function (name, fn) {
      menus.push({ name: String(name), fn: fn });
      window.__npLinkSwiftMenus = menus;
      return menus.length;
    },
    GM_openInTab: function (url) {
      try {
        window.open(String(url), '_blank');
      } catch (e) {}
      return { close: function () {} };
    },
    GM_setClipboard: function (text) {
      var value = String(text == null ? '' : text);
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(value);
          return;
        }
      } catch (e) {}
      try {
        var ta = document.createElement('textarea');
        ta.value = value;
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        document.execCommand('copy');
        document.body.removeChild(ta);
      } catch (e) {}
    },
  };

  window.__npGM = gm;
})();
