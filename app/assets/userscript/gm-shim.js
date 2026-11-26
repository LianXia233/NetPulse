/*
 * NetPulse 用户脚本运行环境（Greasemonkey / Tampermonkey 兼容层）。
 *
 * 宿主在注入脚本前先设置：
 *   window.__npScript        —— 脚本元信息（id/name/version/grant…）
 *   window.__npScriptValues  —— 该脚本已保存的键值（同步读取）
 *   window.__npResources     —— @resource 文本（名称 → 内容）
 *
 * 这里补齐 GM_* API：跨域请求与下载走 NpPage 桥接到宿主，键值写回宿主
 * 私有存储（跨站点持久），其余命令类 API 做安全降级。
 */
(function () {
  'use strict';
  if (window.__npGM) return;

  var meta = window.__npScript || {};
  var values = window.__npScriptValues || {};
  var resources = window.__npUserResources || window.__npResources || {};
  var seq = 0;
  var menus = [];

  function bridgeCall(op, data) {
    return new Promise(function (resolve, reject) {
      var id = 'u' + ++seq + '_' + Date.now();
      if (!window.__npPagePending) window.__npPagePending = {};
      if (!window.__npPageReply) {
        window.__npPageReply = function (rid, ok, payload) {
          var p = window.__npPagePending[rid];
          if (!p) return;
          delete window.__npPagePending[rid];
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
      window.__npPagePending[id] = { resolve: resolve, reject: reject };
      NpPage.postMessage(JSON.stringify({ id: id, op: op, data: data || {} }));
    });
  }

  function clone(v) {
    if (v === undefined || v === null) return v;
    if (typeof v !== 'object') return v;
    try {
      return JSON.parse(JSON.stringify(v));
    } catch (e) {
      return v;
    }
  }

  // ---------- 键值存储 ----------

  function getValue(name, fallback) {
    var key = String(name);
    if (Object.prototype.hasOwnProperty.call(values, key)) {
      var raw = values[key];
      if (raw && typeof raw === 'object' && Object.prototype.hasOwnProperty.call(raw, 'value')) {
        return clone(raw.value);
      }
      return clone(raw);
    }
    return fallback === undefined ? undefined : fallback;
  }

  function setValue(name, value) {
    var key = String(name);
    values[key] = { value: clone(value) };
    bridgeCall('gm', { action: 'set', id: meta.id, name: key, value: clone(value) }).catch(
      function () {}
    );
  }

  function deleteValue(name) {
    var key = String(name);
    delete values[key];
    bridgeCall('gm', { action: 'delete', id: meta.id, name: key }).catch(function () {});
  }

  function listValues() {
    var out = [];
    for (var k in values) {
      if (Object.prototype.hasOwnProperty.call(values, k)) out.push(k);
    }
    return out;
  }

  // ---------- 网络 ----------

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
    if (Object.prototype.toString.call(input) === '[object Array]') {
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

  function bodyToString(data) {
    if (data == null) return '';
    if (typeof data === 'string') return data;
    if (typeof URLSearchParams !== 'undefined' && data instanceof URLSearchParams) {
      return data.toString();
    }
    if (typeof FormData !== 'undefined' && data instanceof FormData) {
      var parts = [];
      data.forEach(function (v, k) {
        parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(v)));
      });
      return parts.join('&');
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

  function xmlHttpRequest(details) {
    var opts = details || {};
    var url = String(opts.url || '');
    var method = String(opts.method || 'GET').toUpperCase();
    var headers = toHeaders(opts.headers);
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
      if (typeof fn !== 'function') return;
      try {
        fn(payload);
      } catch (e) {}
    }

    var timer = setTimeout(function () {
      if (settled) return;
      settled = true;
      emit('ontimeout', { status: 0, statusText: 'timeout', error: '请求超时', finalUrl: url });
      emit('onloadend', { status: 0, finalUrl: url });
    }, timeoutMs);

    bridgeCall('fetch', {
      url: url,
      method: method,
      headers: headers,
      body: bodyToString(opts.data),
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
        var lines = [];
        for (var k in hdrs) lines.push(k + ': ' + hdrs[k]);
        handle.__headers = lines.join('\r\n');
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
        var msg = String((e && e.message) || e);
        emit('onerror', { status: 0, statusText: msg, error: msg, finalUrl: url });
        emit('onloadend', { status: 0, responseText: '', finalUrl: url });
      });

    return handle;
  }

  function download(details) {
    var opts = details || {};
    var url = String(opts.url || '');
    if (!url) return { abort: function () {} };
    bridgeCall('download', {
      url: url,
      name: String(opts.name || ''),
      headers: toHeaders(opts.headers),
    }).catch(function () {});
    return { abort: function () {} };
  }

  // ---------- DOM / 命令 ----------

  function addStyle(css) {
    var el = document.createElement('style');
    el.textContent = String(css == null ? '' : css);
    (document.head || document.documentElement).appendChild(el);
    return el;
  }

  function setClipboard(text) {
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
  }

  function openInTab(url) {
    try {
      window.open(String(url), '_blank');
    } catch (e) {}
    return { close: function () {} };
  }

  function notify(details) {
    try {
      var title = typeof details === 'string' ? details : (details && details.title) || '通知';
      var text = typeof details === 'string' ? '' : (details && details.text) || '';
      var el = document.createElement('div');
      el.textContent = text ? title + ' · ' + text : title;
      el.style.cssText =
        'position:fixed;left:50%;bottom:28px;transform:translateX(-50%);z-index:2147483001;' +
        'max-width:80vw;padding:10px 16px;border-radius:12px;font:13px/1.4 -apple-system,' +
        'BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;color:#fff;background:rgba(20,20,22,.92);' +
        'box-shadow:0 8px 28px rgba(0,0,0,.35);';
      document.body.appendChild(el);
      setTimeout(function () {
        if (el.parentNode) el.parentNode.removeChild(el);
      }, 2600);
    } catch (e) {}
  }

  function registerMenu(name, fn) {
    menus.push({ name: String(name), fn: fn });
    window.__npScriptMenus = menus;
    return menus.length;
  }

  function getResourceText(name) {
    var key = String(name);
    return typeof resources[key] === 'string' ? resources[key] : '';
  }

  function getResourceUrl(name) {
    var text = getResourceText(name);
    if (!text) return '';
    try {
      return 'data:text/plain;charset=utf-8,' + encodeURIComponent(text);
    } catch (e) {
      return '';
    }
  }

  function promiseLike(fn) {
    return function () {
      var args = arguments;
      return new Promise(function (resolve, reject) {
        try {
          resolve(fn.apply(null, args));
        } catch (e) {
          reject(e);
        }
      });
    };
  }

  var gm = {
    GM_info: {
      script: {
        name: meta.name || 'userscript',
        namespace: meta.namespace || '',
        version: meta.version || '0',
        description: meta.description || '',
        author: meta.author || '',
        homepage: meta.homepage || '',
        matches: meta.match || [],
        grants: meta.grant || [],
        runAt: meta.runAt || 'document-idle',
      },
      scriptHandler: 'NetPulse',
      version: '1.0',
    },
    GM_getValue: getValue,
    GM_setValue: setValue,
    GM_deleteValue: deleteValue,
    GM_listValues: listValues,
    GM_xmlhttpRequest: xmlHttpRequest,
    GM_download: download,
    GM_addStyle: addStyle,
    GM_setClipboard: setClipboard,
    GM_openInTab: openInTab,
    GM_notification: notify,
    GM_registerMenuCommand: registerMenu,
    GM_unregisterMenuCommand: function () {},
    GM_getResourceText: getResourceText,
    GM_getResourceURL: getResourceUrl,
    GM_log: function () {
      try {
        console.log.apply(console, ['[' + (meta.name || 'userscript') + ']'].concat([].slice.call(arguments)));
      } catch (e) {}
    },
    unsafeWindow: window,
  };

  // GM.* 异步风格（Tampermonkey 4+ / Violentmonkey 同时提供同步版）。
  gm.GM = {
    info: gm.GM_info,
    getValue: promiseLike(getValue),
    setValue: promiseLike(setValue),
    deleteValue: promiseLike(deleteValue),
    listValues: promiseLike(listValues),
    xmlHttpRequest: xmlHttpRequest,
    download: download,
    addStyle: addStyle,
    setClipboard: promiseLike(setClipboard),
    openInTab: openInTab,
    notification: promiseLike(notify),
    registerMenuCommand: registerMenu,
    getResourceText: promiseLike(getResourceText),
    getResourceUrl: promiseLike(getResourceUrl),
  };

  var names = Object.keys(gm);
  for (var i = 0; i < names.length; i++) {
    window[names[i]] = gm[names[i]];
  }
  window.__npGM = gm;
})();
