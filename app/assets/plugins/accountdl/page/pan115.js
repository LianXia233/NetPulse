"use strict";
(() => {
  // src/core/url.ts
  var URL_RE = /^(https?):\/\/([^/?#@\s]+@)?([^/?#:\s]+)(?::\d+)?([^?#\s]*)(?:\?([^#\s]*))?(?:#(\S*))?$/i;
  function parseUrl(url) {
    const m = URL_RE.exec(url.trim());
    if (!m) return null;
    return {
      scheme: m[1].toLowerCase(),
      host: m[3].toLowerCase(),
      path: m[4] || "/",
      query: m[5] ?? "",
      fragment: m[6] ?? ""
    };
  }
  function safeDecode(s) {
    try {
      return decodeURIComponent(s.replace(/\+/g, " "));
    } catch {
      return s;
    }
  }
  function parseQuery(query) {
    const out = {};
    for (const part of query.split("&")) {
      if (part === "") continue;
      const eq = part.indexOf("=");
      const name = safeDecode(eq < 0 ? part : part.slice(0, eq));
      if (name in out) continue;
      out[name] = eq < 0 ? "" : safeDecode(part.slice(eq + 1));
    }
    return out;
  }
  function encodeQuery(params) {
    return Object.entries(params).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
  }

  // src/core/task.ts
  var TASK_PREFIX = "/__accountdl/";
  function taskUrl(host, siteId, params) {
    const query = encodeQuery(params);
    return `https://${host}${TASK_PREFIX}${siteId}${query ? `?${query}` : ""}`;
  }

  // src/sites/pan115/link.ts
  var SITE_ID = "pan115";
  var TASK_HOST = "115.com";
  var SHARE_HOSTS = ["115.com", "115cdn.com", "anxia.com"];
  var SHARE_PATH_RE = /^\/s\/([A-Za-z0-9]{4,32})\/?$/;
  var RECEIVE_CODE_RE = /^[A-Za-z0-9]{0,16}$/;
  function parseSharePage(url) {
    if (!SHARE_HOSTS.includes(url.host)) return null;
    const m = SHARE_PATH_RE.exec(url.path);
    if (!m) return null;
    const query = parseQuery(url.query);
    const code = query.password ?? query.pwd ?? "";
    return { shareCode: m[1], receiveCode: RECEIVE_CODE_RE.test(code) ? code : "" };
  }
  function makeTaskUrl(task) {
    const params = { s: task.shareCode };
    if (task.receiveCode) params.p = task.receiveCode;
    if (task.dir) params.d = task.dir;
    return taskUrl(TASK_HOST, SITE_ID, params);
  }

  // src/page/kit.ts
  var STYLE = `
:host { all: initial; }
.fab { position: fixed; right: 24px; bottom: 24px; z-index: 2147482000; display: flex; flex-direction: column; align-items: flex-end; gap: 8px; }
button { all: unset; box-sizing: border-box; cursor: pointer; display: inline-flex; align-items: center; gap: 6px; height: 40px;
  padding: 0 16px; border-radius: 20px; background: #2563eb; color: #fff; box-shadow: 0 8px 24px rgba(15, 23, 42, .18);
  font: 500 14px/1 -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; white-space: nowrap; }
button:hover { background: #1d4ed8; }
button[disabled] { opacity: .6; cursor: progress; }
.toast { max-width: 360px; padding: 10px 14px; border-radius: 8px; background: #0f172a; color: #fff; box-shadow: 0 8px 24px rgba(15, 23, 42, .18);
  font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; word-break: break-all; }
.toast.error { background: #b91c1c; }
`;
  function floatingButton(label, title, onClick) {
    const host = document.createElement("div");
    const root = host.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent = STYLE;
    const wrap = document.createElement("div");
    wrap.className = "fab";
    const button2 = document.createElement("button");
    button2.type = "button";
    button2.title = title;
    button2.textContent = label;
    wrap.append(button2);
    root.append(style, wrap);
    const toast = (text, kind = "info") => {
      const el = document.createElement("div");
      el.className = kind === "error" ? "toast error" : "toast";
      el.textContent = text;
      wrap.insertBefore(el, button2);
      window.setTimeout(() => el.remove(), kind === "error" ? 8e3 : 4e3);
    };
    button2.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (button2.disabled) return;
      button2.disabled = true;
      onClick().then((msg) => {
        if (msg) toast(msg);
      }).catch((e) => toast(e instanceof Error ? e.message : String(e), "error")).finally(() => {
        button2.disabled = false;
      });
    });
    const mount = () => {
      if (!host.isConnected) document.documentElement.append(host);
    };
    new MutationObserver(() => {
      if (host.style.display !== "none") mount();
    }).observe(document.documentElement, { childList: true });
    mount();
    return {
      setVisible(visible) {
        host.style.display = visible ? "" : "none";
      },
      toast
    };
  }
  async function sendTask(url, filename) {
    const res = await netpulse.download({ url, referrer: location.href, ...filename ? { filename } : {} });
    if (!res.ok) throw new Error(res.message || "\u53D1\u9001\u5230\u4E0B\u8F7D\u5668\u5931\u8D25");
  }
  function onUrlChange(callback) {
    let last = location.href;
    callback(last);
    window.setInterval(() => {
      if (location.href === last) return;
      last = location.href;
      callback(last);
    }, 500);
  }

  // src/page/pan115.ts
  var RECEIVE_CODE_RE2 = /^[A-Za-z0-9]{1,16}$/;
  function currentShare() {
    const url = parseUrl(location.href);
    return url ? parseSharePage(url) : null;
  }
  var button = floatingButton("\u76F4\u94FE\u4E0B\u8F7D", "\u89E3\u6790\u5F53\u524D\u5206\u4EAB\uFF08\u5168\u90E8\u6587\u4EF6\uFF09\u5E76\u4EA4\u7ED9\u4E0B\u8F7D\u5668", async () => {
    const share = currentShare();
    if (!share) throw new Error("\u5F53\u524D\u9875\u9762\u4E0D\u662F\u5206\u4EAB\u9875");
    let receiveCode = share.receiveCode;
    if (receiveCode === "") {
      receiveCode = (window.prompt("\u8BF7\u8F93\u5165\u8FD9\u4E2A\u5206\u4EAB\u7684\u63D0\u53D6\u7801\uFF08\u8BBF\u95EE\u7801\uFF09") ?? "").trim();
      if (!RECEIVE_CODE_RE2.test(receiveCode)) throw new Error("\u6CA1\u6709\u6709\u6548\u7684\u63D0\u53D6\u7801");
    }
    await sendTask(makeTaskUrl({ shareCode: share.shareCode, receiveCode }));
    return "\u5DF2\u52A0\u5165\u4E0B\u8F7D\u961F\u5217\uFF0C\u8BF7\u5728\u4E0B\u8F7D\u5668\u91CC\u67E5\u770B\u6587\u4EF6\u6E05\u5355";
  });
  onUrlChange(() => button.setVisible(currentShare() !== null));
})();
