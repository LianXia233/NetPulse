"use strict";
(() => {
  // src/core/errors.ts
  function errorMessage(e) {
    return e instanceof Error ? e.message : String(e);
  }

  // src/core/hash.ts
  var MD5_K = Array.from({ length: 64 }, (_, i) => Math.floor(Math.abs(Math.sin(i + 1)) * 2 ** 32) >>> 0);

  // src/core/json.ts
  function asObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value) ? value : null;
  }

  // src/sites/pan123/jwt.ts
  var MAX_TOKEN_CHARS = 4096;
  function normalizeToken(raw) {
    let s = raw.trim();
    if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) s = s.slice(1, -1).trim();
    return s.replace(/^bearer\s+/i, "").trim();
  }

  // src/core/site.ts
  function hostIn(host, domains) {
    return domains.some((d) => host === d || host.endsWith(`.${d}`));
  }

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

  // src/sites/pan123/link.ts
  var SITE_ID = "pan123";
  var SHARE_DOMAINS = [
    "123pan.com",
    "123pan.cn",
    "123684.com",
    "123865.com",
    "123912.com",
    "123592.com",
    "123295.com",
    "123278.com"
  ];
  var PATH_RE = /^\/(?:s|ps|123pan)\/([A-Za-z0-9]+-[A-Za-z0-9]+)(?:\.html)?(?:[/&]|$)/;
  var PWD_RE = /^[A-Za-z0-9]{1,32}$/;
  function isShareHost(host) {
    return hostIn(host, SHARE_DOMAINS);
  }
  function parseSharePage(href) {
    const url = parseUrl(href);
    if (!url || !isShareHost(url.host)) return null;
    const m = PATH_RE.exec(url.path);
    if (!m) return null;
    return { host: url.host, key: m[1], pwd: normalizePwd(parseQuery(url.query).pwd ?? "") };
  }
  function normalizePwd(raw) {
    const s = raw.trim().replace(/^"(.*)"$/, "$1").trim();
    return PWD_RE.test(s) ? s : "";
  }
  function storedPwd(raw) {
    try {
      const v = JSON.parse(raw);
      if (typeof v === "string") return normalizePwd(v);
      const inner = asObject(v)?.value;
      return typeof inner === "string" ? normalizePwd(inner) : "";
    } catch {
      return normalizePwd(raw);
    }
  }
  function shareTaskUrl(host, key, pwd) {
    return taskUrl(host, SITE_ID, pwd ? { key, pwd } : { key });
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

  // src/page/pan123.ts
  function readStorage(storage, key) {
    try {
      return storage().getItem(key) ?? "";
    } catch {
      return "";
    }
  }
  function readAuthToken() {
    const token = normalizeToken(readStorage(() => sessionStorage, "authorToken")) || normalizeToken(readStorage(() => localStorage, "authorToken"));
    return token.length <= MAX_TOKEN_CHARS ? token : "";
  }
  var button = floatingButton("\u76F4\u94FE\u4E0B\u8F7D", "\u7528\u5F53\u524D\u767B\u5F55\u7684\u8D26\u53F7\u89E3\u6790\u5E76\u4E0B\u8F7D\u6574\u4E2A\u5206\u4EAB", async () => {
    const share = parseSharePage(location.href);
    if (!share) throw new Error("\u5F53\u524D\u9875\u9762\u4E0D\u662F\u5206\u4EAB\u9875");
    const pwd = share.pwd || storedPwd(readStorage(() => localStorage, `sharePwd_${share.key}`));
    const token = readAuthToken();
    let loggedIn = false;
    let syncError = "";
    try {
      loggedIn = (await netpulse.invoke("pan123.syncToken", { token })).loggedIn;
    } catch (e) {
      syncError = errorMessage(e);
    }
    await sendTask(shareTaskUrl(location.hostname, share.key, pwd));
    if (loggedIn) return "\u5DF2\u52A0\u5165\u4E0B\u8F7D\uFF0C\u4F7F\u7528\u5F53\u524D\u767B\u5F55\u7684\u8D26\u53F7\u89E3\u6790";
    if (token !== "" && syncError !== "") return `${syncError}\uFF1B\u5DF2\u6309\u672A\u767B\u5F55\u5C1D\u8BD5\u89E3\u6790`;
    return "\u5DF2\u52A0\u5165\u4E0B\u8F7D\uFF08\u672A\u767B\u5F55\uFF0C\u4EC5\u5728\u5206\u4EAB\u8005\u5F00\u542F\u6D41\u91CF\u5305\u65F6\u53EF\u7528\uFF09";
  });
  onUrlChange((href) => button.setVisible(parseSharePage(href) !== null));
})();
