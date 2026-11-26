/*
 * GreasyFork 页面增强。
 *
 * 1) 详情页 / 列表页各加一个「安装到 NetPulse」按钮；
 * 2) 官方「安装此脚本」按钮也接管：点击后不再跳到 .user.js 源码页，
 *    直接交给宿主安装（导航层还有一层兜底）；
 * 3) 右下角常驻「我的脚本」入口，跳到 App 内的脚本管理器。
 *
 * 只做 UI 注入，真正的抓取与存储都在宿主侧完成。
 */
(function () {
  'use strict';
  if (window.__npGreasyFork) return;
  window.__npGreasyFork = true;

  var host = location.hostname;
  if (host !== 'greasyfork.org' && host.slice(-16) !== '.greasyfork.org') return;

  var STYLE_ID = 'np-gf-style';
  var ACCENT = '#2f6fed';
  var LINK_SEL = 'a[href*=".user.js"]';

  function log(msg) {
    try {
      console.log('[GreasyFork·NetPulse] ' + msg);
    } catch (e) {}
  }

  function abs(href) {
    try {
      return new URL(href, location.href).href;
    } catch (e) {
      return href || '';
    }
  }

  /** 详情页 /code 页统一成详情页地址，便于宿主记录来源与判断已安装。 */
  function pageUrlOf(href) {
    return abs(href || location.href)
      .split('#')[0]
      .split('?')[0]
      .replace(/\/code\/?$/, '');
  }

  function isUserScript(href) {
    return /\.user\.js($|[?#&])/i.test(href || '');
  }

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    var el = document.createElement('style');
    el.id = STYLE_ID;
    el.textContent =
      '.np-gf-btn{display:inline-flex;align-items:center;gap:6px;height:34px;padding:0 14px;' +
      'border:0;border-radius:8px;background:' + ACCENT + ';color:#fff;font-size:13px;font-weight:600;' +
      'cursor:pointer;box-shadow:0 2px 8px rgba(47,111,237,.28);}' +
      '.np-gf-btn:disabled{opacity:.6;cursor:default;}' +
      '.np-gf-btn.installed{background:#1f9d55;box-shadow:0 2px 8px rgba(31,157,85,.28);}' +
      '.np-gf-btn.small{height:28px;padding:0 10px;font-size:12px;}' +
      '.np-gf-row{display:flex;align-items:center;gap:8px;margin:8px 0;flex-wrap:wrap;}' +
      '.np-gf-fab{position:fixed;right:16px;bottom:22px;z-index:2147483000;display:flex;align-items:center;' +
      'gap:8px;height:42px;padding:0 16px;border:0;border-radius:21px;background:' + ACCENT + ';color:#fff;' +
      'font:600 13px/1 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;cursor:pointer;' +
      'box-shadow:0 8px 24px rgba(47,111,237,.38);}' +
      '.np-gf-toast{position:fixed;left:50%;bottom:80px;transform:translateX(-50%);z-index:2147483001;' +
      'max-width:80vw;padding:10px 16px;border-radius:12px;color:#fff;background:rgba(20,20,22,.94);' +
      'font:13px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;' +
      'box-shadow:0 8px 28px rgba(0,0,0,.35);}';
    (document.head || document.documentElement).appendChild(el);
  }

  function toast(text, ms) {
    var old = document.querySelector('.np-gf-toast');
    if (old && old.parentNode) old.parentNode.removeChild(old);
    var el = document.createElement('div');
    el.className = 'np-gf-toast';
    el.textContent = text;
    document.body.appendChild(el);
    setTimeout(function () {
      if (el.parentNode) el.parentNode.removeChild(el);
    }, ms || 2400);
  }

  function invoke(name, args) {
    if (!window.netpulse || typeof window.netpulse.invoke !== 'function') {
      return Promise.reject(new Error('NetPulse 通道未就绪，请重新打开页面'));
    }
    return window.netpulse.invoke(name, args || {});
  }

  /**
   * codeUrl 是 .user.js 直链；pageUrl 是脚本详情页，用来记录安装来源。
   * btn 为空表示从官方按钮触发，不需要改它的文案。
   */
  function install(codeUrl, btn, pageUrl) {
    if (btn) {
      btn.disabled = true;
      btn.textContent = '安装中…';
    }
    invoke('installScript', {
      url: codeUrl,
      pageUrl: pageUrl || pageUrlOf(),
    })
      .then(function (res) {
        var data = res || {};
        var label = data.name || '脚本';
        var ver = data.version ? ' v' + data.version : '';
        toast('已安装 ' + label + ver + '，可在「我的脚本」里管理');
        if (btn) {
          btn.disabled = false;
          btn.textContent = data.existed ? '已更新' : '已安装';
          btn.classList.add('installed');
        }
        refreshDetail();
      })
      .catch(function (e) {
        toast('安装失败：' + ((e && e.message) || e));
        if (btn) {
          btn.disabled = false;
          btn.textContent = '安装到 NetPulse';
        }
      });
  }

  function makeButton(label, small, onClick) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'np-gf-btn' + (small ? ' small' : '');
    btn.textContent = label;
    btn.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      onClick(btn);
    });
    return btn;
  }

  function findInstallLink() {
    return (
      document.querySelector('#install-area a.install-link') ||
      document.querySelector('a.install-link[href*=".user.js"]') ||
      document.querySelector('#install-area a[href*=".user.js"]') ||
      document.querySelector('a[href*="/scripts/"][href*=".user.js"]')
    );
  }

  /** 详情页：安装区旁边加按钮。 */
  function enhanceDetail() {
    var installLink = findInstallLink();
    if (!installLink) return;
    var area =
      installLink.closest('#install-area') ||
      installLink.closest('.script-show-download') ||
      installLink.parentNode;
    if (!area) return;
    if (area.querySelector('.np-gf-btn')) {
      // 已经注入过，只更新「已安装」标记。
      refreshDetail();
      return;
    }
    var url = abs(installLink.getAttribute('href'));
    if (!isUserScript(url)) return;
    var page = pageUrlOf(installLink.getAttribute('href'));
    var btn = makeButton('安装到 NetPulse', false, function (b) {
      install(url, b, page);
    });
    var row = document.createElement('div');
    row.className = 'np-gf-row';
    row.appendChild(btn);
    area.appendChild(row);
    log('详情页已注入安装入口');
    refreshDetail();
  }

  /** 已装过的脚本直接标出来，避免重复点击。 */
  function refreshDetail() {
    var btn = document.querySelector('.np-gf-row .np-gf-btn');
    if (!btn || btn.disabled) return;
    var link = findInstallLink();
    invoke('scriptStatus', {
      pageUrl: pageUrlOf(),
      codeUrl: link ? abs(link.getAttribute('href')) : '',
    })
      .then(function (res) {
        var data = res || {};
        if (!data.installed) return;
        btn.textContent =
          '已安装' + (data.version ? ' v' + data.version : '') + ' · 重新安装';
        btn.classList.add('installed');
      })
      .catch(function () {});
  }

  /**
   * 接管官方安装按钮。GreasyFork 的按钮是普通 a[href]，
   * 在捕获阶段拦下就不会离开当前页面。
   */
  function hookInstallLinks() {
    var links = document.querySelectorAll(LINK_SEL);
    for (var i = 0; i < links.length; i++) {
      var a = links[i];
      if (a.dataset.npGfHooked === '1') continue;
      var href = abs(a.getAttribute('href'));
      if (!isUserScript(href)) continue;
      a.dataset.npGfHooked = '1';
      a.addEventListener(
        'click',
        function (e) {
          var target = abs(this.getAttribute('href'));
          if (!isUserScript(target)) return;
          e.preventDefault();
          e.stopImmediatePropagation();
          install(target, null, pageUrlOf());
        },
        true
      );
    }
  }

  /** 列表 / 搜索结果：每条加一个小的安装按钮。 */
  function enhanceList() {
    var items = document.querySelectorAll(
      'article.script-list-item, li.script-list-item, .script-list-item'
    );
    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      if (item.querySelector('.np-gf-inline')) continue;
      var link =
        item.querySelector('a.script-link[href*="/scripts/"]') ||
        item.querySelector('h2 a[href*="/scripts/"]') ||
        item.querySelector('a[href*="/zh-CN/scripts/"]');
      if (!link) continue;
      var page = pageUrlOf(link.getAttribute('href'));
      var holder = item.querySelector('.script-list-item-meta, .script-list-description') || item;
      var btn = makeButton('装到 NetPulse', true, function (b) {
        b.disabled = true;
        b.textContent = '解析中…';
        invoke('installScript', { pageUrl: page })
          .then(function (res) {
            var data = res || {};
            b.textContent = data.existed ? '已更新' : '已安装';
            toast('已安装 ' + (data.name || '脚本') + (data.version ? ' v' + data.version : ''));
          })
          .catch(function (e) {
            b.disabled = false;
            b.textContent = '装到 NetPulse';
            toast('安装失败：' + ((e && e.message) || e));
          });
      });
      btn.classList.add('np-gf-inline');
      btn.style.marginLeft = '8px';
      btn.style.verticalAlign = 'middle';
      holder.appendChild(btn);
    }
  }

  /** 右下角入口：打开 App 内的脚本管理器。 */
  function addFab() {
    if (document.querySelector('.np-gf-fab')) return;
    var fab = document.createElement('button');
    fab.type = 'button';
    fab.className = 'np-gf-fab';
    fab.textContent = '我的脚本';
    fab.addEventListener('click', function () {
      invoke('openUserScripts', {}).catch(function () {});
    });
    document.body.appendChild(fab);
  }

  function run() {
    ensureStyle();
    try {
      hookInstallLinks();
    } catch (e) {}
    try {
      enhanceDetail();
    } catch (e) {}
    try {
      enhanceList();
    } catch (e) {}
    try {
      addFab();
    } catch (e) {}
  }

  // 宿主安装完成后调用，刷新「已安装」标记。
  window.__npGreasyRefresh = run;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', run);
  } else {
    run();
  }
  // GreasyFork 的部分列表是异步加载的，低频补一次。
  setTimeout(run, 1200);
  setTimeout(run, 3000);
})();
