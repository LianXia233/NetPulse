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

  // src/sites/quark/link.ts
  var QUARK_HOST = "pan.quark.cn";
  var SITE_ID = "quark";
  var FID_RE = /^[A-Za-z0-9]{1,64}$/;
  var SHARE_PATH_RE = /^\/s\/([A-Za-z0-9]{6,40})\/?$/;
  var MAX_PASSWORD_CHARS = 32;
  function isFid(fid) {
    return FID_RE.test(fid);
  }
  function parseSharePage(href) {
    const url = parseUrl(href);
    if (!url || url.host !== QUARK_HOST) return null;
    const m = SHARE_PATH_RE.exec(url.path);
    if (!m) return null;
    const password = (parseQuery(url.query).pwd ?? "").trim();
    return { key: m[1], password: password.length <= MAX_PASSWORD_CHARS ? password : "", dir: dirFromFragment(url.fragment) };
  }
  function dirFromFragment(fragment) {
    const parts = fragment.split("/").filter((p) => p !== "");
    const at = parts.indexOf("share");
    if (parts[0] !== "list" || at !== 1) return "";
    const last = parts[parts.length - 1];
    if (last === "share") return "";
    const fid = last.split("-")[0];
    return isFid(fid) ? fid : "";
  }
  function sharePageTaskUrl(page) {
    const params = { key: page.key };
    if (page.password) params.pwd = page.password;
    if (page.dir && page.dir !== "0") params.dir = page.dir;
    return taskUrl(QUARK_HOST, SITE_ID, params);
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

  // src/page/quark.ts
  function savedPassword(key) {
    try {
      const cache = JSON.parse(localStorage.getItem("share_code_cache") ?? "null");
      if (!Array.isArray(cache)) return "";
      const hit = cache.find((e) => typeof e === "object" && e !== null && Reflect.get(e, "key") === key);
      const code = typeof hit === "object" && hit !== null ? Reflect.get(hit, "code") : null;
      return typeof code === "string" ? code.trim() : "";
    } catch {
      return "";
    }
  }
  var button = floatingButton("\u76F4\u94FE\u4E0B\u8F7D", "\u7528\u5DF2\u767B\u5F55\u7684\u8D26\u53F7\u89E3\u6790\u5E76\u4E0B\u8F7D\u8FD9\u4E2A\u5206\u4EAB", async () => {
    const page = parseSharePage(location.href);
    if (!page) throw new Error("\u5F53\u524D\u9875\u9762\u4E0D\u662F\u5938\u514B\u7F51\u76D8\u5206\u4EAB\u9875");
    const password = page.password || savedPassword(page.key);
    await sendTask(sharePageTaskUrl({ ...page, password }));
    return page.dir ? "\u5DF2\u53D1\u9001\u5F53\u524D\u6587\u4EF6\u5939\uFF0C\u8BF7\u5728\u4E0B\u8F7D\u5668\u91CC\u9009\u62E9\u6587\u4EF6" : "\u5DF2\u53D1\u9001\uFF0C\u8BF7\u5728\u4E0B\u8F7D\u5668\u91CC\u9009\u62E9\u6587\u4EF6";
  });
  onUrlChange((href) => button.setVisible(parseSharePage(href) !== null));
})();
