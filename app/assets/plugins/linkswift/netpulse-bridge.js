/*
 * LinkSwift ↔ NetPulse 桥接层。
 *
 * LinkSwift 只负责把网盘分享页里的文件解析成直链，推送目标原本是
 * IDM / Aria2 / 比特彗星这类外部程序。内置浏览器里没有这些客户端，
 * 所以这里把它的直链结果接到 NetPulse 下载引擎上：
 *
 *  - 在 LinkSwift 的下载弹窗里注入「NetPulse 下载」入口；
 *  - 按网盘补齐 Referer / User-Agent / Cookie，避免直链 403；
 *  - 多文件时用自己的选择面板，确认后一次性入队。
 */
(function () {
  'use strict';
  if (window.__npLSBridge) return;
  window.__npLSBridge = true;

  var QUARK_UA =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
    'quark-cloud-drive/3.20.0 Chrome/112.0.5615.165 Electron/24.1.3.8 Safari/537.36 Channel/pckk_other_ch';
  var UC_UA =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
    'uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';

  var BAR_CLASS = 'np-ls-bar';
  var PANEL_ID = 'np-ls-panel';

  function log(msg) {
    try {
      console.log('[LinkSwift·NetPulse] ' + msg);
    } catch (e) {}
  }

  /** 各网盘直链对请求头的要求不一样，代理 UA / Referer 按站点覆盖。 */
  function headersFor() {
    var host = location.hostname;
    var h = {
      Referer: location.origin + '/',
      'User-Agent': navigator.userAgent,
    };
    if (/(^|\.)baidu\.com$/.test(host)) {
      h['User-Agent'] = 'pan.baidu.com';
      h.Referer = 'https://pan.baidu.com/';
    } else if (/(^|\.)quark\.cn$/.test(host)) {
      h['User-Agent'] = QUARK_UA;
      h.Referer = 'https://pan.quark.cn/';
    } else if (/(^|\.)uc\.cn$/.test(host)) {
      h['User-Agent'] = UC_UA;
      h.Referer = 'https://drive.uc.cn/';
    } else if (/(^|\.)139\.com$/.test(host)) {
      h.Referer = 'https://yun.139.com/';
    } else if (/(^|\.)189\.cn$/.test(host)) {
      h.Referer = 'https://cloud.189.cn/';
    } else if (/(^|\.)xunlei\.com$/.test(host)) {
      h.Referer = 'https://pan.xunlei.com/';
    } else if (/(^|\.)alipan\.com$/.test(host) || /(^|\.)aliyundrive\.com$/.test(host)) {
      h.Referer = 'https://www.alipan.com/';
    }
    if (document.cookie) h.Cookie = document.cookie;
    return h;
  }

  function absLink(link) {
    try {
      return new URL(link, location.href).href;
    } catch (e) {
      return link;
    }
  }

  /**
   * 回收 LinkSwift 渲染出来的直链。
   *
   * 每个文件是一个 `.pl-item`，容器上带 `data-link` / `data-name` / `data-size`；
   * 但 aria2、比特彗星等模式只有按钮上带 `data-link` + `data-filename`，
   * 所以先按条目取，再按按钮兜底，最后按 (名称, 链接) 去重。
   */
  function collectFrom(root) {
    var out = [];
    var seen = {};
    function push(link, name, size) {
      if (!link || !name) return;
      if (!/^(https?:|data:)/i.test(link) && link.indexOf('//') !== 0) return;
      var abs = absLink(link);
      var key = name + '\u0000' + abs;
      if (seen[key]) return;
      seen[key] = 1;
      out.push({ name: name, url: abs, size: size || 0 });
    }

    var rows = root.querySelectorAll('.pl-item');
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      var link = row.getAttribute('data-link') || '';
      var name = row.getAttribute('data-name') || '';
      var size = parseInt(row.getAttribute('data-size') || '0', 10) || 0;
      if (!size) {
        var holder = row.querySelector('[data-size]');
        if (holder) size = parseInt(holder.getAttribute('data-size') || '0', 10) || 0;
      }
      var btn = row.querySelector('[data-link][data-filename]');
      if (btn) {
        if (!link) link = btn.getAttribute('data-link') || '';
        if (!name) name = btn.getAttribute('data-filename') || '';
        if (!size) size = parseInt(btn.getAttribute('data-filesize') || '0', 10) || 0;
      }
      push(link, name, size);
    }

    // 没有 .pl-item 包裹的模式（或结构变动）兜底扫按钮。
    if (!out.length) {
      var nodes = root.querySelectorAll('[data-link][data-filename]');
      for (var j = 0; j < nodes.length; j++) {
        var el = nodes[j];
        push(
          el.getAttribute('data-link') || '',
          el.getAttribute('data-filename') || '',
          parseInt(el.getAttribute('data-filesize') || '0', 10) || 0
        );
      }
    }
    return out;
  }

  function send(items) {
    if (!items.length) return;
    if (!window.netpulse || typeof window.netpulse.direct !== 'function') {
      alert('NetPulse 下载通道未就绪，请重新打开页面再试。');
      return;
    }
    var payload = {
      items: items,
      headers: headersFor(),
      referrer: location.href,
    };
    log('送入下载器：' + items.length + ' 个文件');
    window.netpulse.direct(payload).catch(function (e) {
      log('送入失败：' + ((e && e.message) || e));
    });
  }

  // ---------- 文件选择面板 ----------

  function fmtSize(n) {
    if (!n || n < 1024) return n ? n + ' B' : '';
    var u = ['KB', 'MB', 'GB', 'TB'];
    var i = -1;
    do {
      n /= 1024;
      i++;
    } while (n >= 1024 && i < u.length - 1);
    return n.toFixed(n >= 100 ? 0 : 1) + ' ' + u[i];
  }

  function closePanel() {
    var el = document.getElementById(PANEL_ID);
    if (el && el.parentNode) el.parentNode.removeChild(el);
  }

  function openPanel(items) {
    closePanel();
    var dark = true;
    try {
      dark = !window.matchMedia('(prefers-color-scheme: light)').matches;
    } catch (e) {}
    var bg = dark ? '#1c1c1e' : '#ffffff';
    var fg = dark ? '#e8e8ea' : '#1a1a1c';
    var muted = dark ? '#8b8b93' : '#6b6b73';
    var line = dark ? 'rgba(255,255,255,.10)' : 'rgba(0,0,0,.08)';
    var accent = '#5b8cff';

    var wrap = document.createElement('div');
    wrap.id = PANEL_ID;
    wrap.style.cssText =
      'position:fixed;inset:0;z-index:2147483000;background:rgba(0,0,0,.55);' +
      'display:flex;align-items:flex-end;justify-content:center;font:14px/1.5 -apple-system,' +
      'BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;';

    var card = document.createElement('div');
    card.style.cssText =
      'width:100%;max-width:560px;max-height:78vh;display:flex;flex-direction:column;' +
      'background:' + bg + ';color:' + fg + ';border-radius:16px 16px 0 0;overflow:hidden;' +
      'box-shadow:0 -8px 40px rgba(0,0,0,.35);';

    var head = document.createElement('div');
    head.style.cssText =
      'padding:14px 16px 10px;border-bottom:1px solid ' + line + ';display:flex;' +
      'align-items:center;justify-content:space-between;gap:12px;';
    head.innerHTML =
      '<div style="min-width:0"><div style="font-size:15px;font-weight:600">选择要下载的文件</div>' +
      '<div style="font-size:12px;color:' + muted + ';margin-top:2px">共 ' + items.length + ' 项 · 使用 NetPulse 多线程下载</div></div>';
    var allBtn = document.createElement('button');
    allBtn.textContent = '全选';
    allBtn.style.cssText =
      'flex:0 0 auto;border:0;background:transparent;color:' + accent + ';font-size:13px;padding:6px 2px;cursor:pointer;';
    head.appendChild(allBtn);

    var list = document.createElement('div');
    list.style.cssText = 'overflow:auto;padding:6px 8px;flex:1;-webkit-overflow-scrolling:touch;';

    var boxes = [];
    items.forEach(function (it, idx) {
      var row = document.createElement('label');
      row.style.cssText =
        'display:flex;align-items:center;gap:10px;padding:10px 8px;border-radius:10px;cursor:pointer;';
      var cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = true;
      cb.dataset.idx = String(idx);
      cb.style.cssText = 'width:18px;height:18px;flex:0 0 auto;accent-color:' + accent + ';';
      boxes.push(cb);
      var text = document.createElement('div');
      text.style.cssText = 'min-width:0;flex:1;';
      var nm = document.createElement('div');
      nm.textContent = it.name;
      nm.style.cssText =
        'font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
      text.appendChild(nm);
      var meta = document.createElement('div');
      meta.textContent = it.size > 0 ? fmtSize(it.size) : it.url.replace(/^https?:\/\//, '').split('?')[0].slice(0, 60);
      meta.style.cssText =
        'font-size:11px;color:' + muted + ';overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-top:2px;';
      text.appendChild(meta);
      row.appendChild(cb);
      row.appendChild(text);
      list.appendChild(row);
    });

    var foot = document.createElement('div');
    foot.style.cssText =
      'padding:12px 16px calc(12px + env(safe-area-inset-bottom));border-top:1px solid ' + line +
      ';display:flex;gap:10px;';
    var cancel = document.createElement('button');
    cancel.textContent = '取消';
    cancel.style.cssText =
      'flex:1;height:42px;border-radius:10px;border:1px solid ' + line + ';background:transparent;' +
      'color:' + fg + ';font-size:14px;cursor:pointer;';
    var ok = document.createElement('button');
    ok.textContent = '开始下载';
    ok.style.cssText =
      'flex:2;height:42px;border-radius:10px;border:0;background:' + accent + ';color:#fff;' +
      'font-size:14px;font-weight:600;cursor:pointer;';
    foot.appendChild(cancel);
    foot.appendChild(ok);

    card.appendChild(head);
    card.appendChild(list);
    card.appendChild(foot);
    wrap.appendChild(card);
    document.body.appendChild(wrap);

    var allOn = true;
    allBtn.addEventListener('click', function () {
      allOn = !allOn;
      boxes.forEach(function (b) {
        b.checked = allOn;
      });
      allBtn.textContent = allOn ? '全选' : '全不选';
    });
    cancel.addEventListener('click', closePanel);
    wrap.addEventListener('click', function (e) {
      if (e.target === wrap) closePanel();
    });
    ok.addEventListener('click', function () {
      var picked = items.filter(function (_, i) {
        return boxes[i] && boxes[i].checked;
      });
      closePanel();
      if (!picked.length) return;
      send(picked);
    });
  }

  // ---------- 入口注入 ----------

  function entryButton(count) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'np-ls-open';
    btn.textContent = 'NetPulse 下载' + (count > 1 ? '（' + count + '）' : '');
    btn.style.cssText =
      'display:block;width:100%;margin:10px 0 2px;height:40px;border:0;border-radius:8px;' +
      'background:linear-gradient(135deg,#5b8cff,#7a5cff);color:#fff;font-size:14px;' +
      'font-weight:600;cursor:pointer;letter-spacing:.2px;';
    return btn;
  }

  function attach() {
    // LinkSwift 的下载弹窗都渲染在 Swal 容器里。这里只认最外层容器，
    // 避免 .pl-main 被当成第二个宿主重复注入。
    var host = document.querySelector('.swal2-html-container .pl-main');
    if (!host) host = document.querySelector('.swal2-html-container');
    if (!host) return;
    var scope = host.closest('.swal2-html-container') || host;
    if (scope.querySelector('.' + BAR_CLASS)) return;
    var items = collectFrom(scope);
    if (!items.length) return;
    var bar = document.createElement('div');
    bar.className = BAR_CLASS;
    var btn = entryButton(items.length);
    (function (snapshot) {
      btn.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        if (snapshot.length === 1) send(snapshot);
        else openPanel(snapshot);
      });
    })(items);
    bar.appendChild(btn);
    // 优先贴在 LinkSwift 自己的按钮区后面，保持视觉连续。
    var extra = scope.querySelector('.pl-extra');
    if (extra && extra.parentNode) extra.parentNode.insertBefore(bar, extra.nextSibling);
    else scope.appendChild(bar);
    log('已注入下载入口：' + items.length + ' 个文件');
  }

  var pending = null;
  var observer = new MutationObserver(function () {
    if (pending) return;
    pending = setTimeout(function () {
      pending = null;
      try {
        attach();
      } catch (e) {}
    }, 180);
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', attach);
  } else {
    attach();
  }
})();
