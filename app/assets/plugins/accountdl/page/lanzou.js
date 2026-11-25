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

  // src/sites/lanzou/link.ts
  var SHARE_DOMAINS = [
    "lanzoub.com",
    "lanzouc.com",
    "lanzoue.com",
    "lanzouf.com",
    "lanzoug.com",
    "lanzouh.com",
    "lanzoui.com",
    "lanzouj.com",
    "lanzouk.com",
    "lanzoul.com",
    "lanzoum.com",
    "lanzouo.com",
    "lanzoup.com",
    "lanzouq.com",
    "lanzout.com",
    "lanzouu.com",
    "lanzouv.com",
    "lanzouw.com",
    "lanzoux.com",
    "lanzouy.com",
    "lanzb.com",
    "lanze.com",
    "lanzf.com",
    "lanzh.com",
    "lanzi.com",
    "lanzj.com",
    "lanzl.com",
    "lanzm.com",
    "lanzn.com",
    "lanzo.com",
    "lanzp.com",
    "lanzq.com",
    "lanzt.com",
    "lanzv.com",
    "lanzw.com",
    "lanzx.com",
    "lanzy.com",
    "lanpw.com"
  ];
  var PATH_RE = /^\/(?:tp\/)?([A-Za-z0-9]{5,32})$/;
  function isShareHost(host) {
    return SHARE_DOMAINS.some((d) => host === d || host.endsWith(`.${d}`));
  }
  function parseShareLink(url) {
    if (url.scheme !== "https" && url.scheme !== "http" || !isShareHost(url.host)) return null;
    const m = PATH_RE.exec(url.path);
    if (!m) return null;
    return { host: url.host, id: m[1], pwd: (parseQuery(url.query).pwd ?? "").trim() };
  }
  function parseShareText(href) {
    const parsed = parseUrl(href);
    return parsed ? parseShareLink(parsed) : null;
  }
  function shareUrl(host, id, pwd = "") {
    return `https://${host}/${id}${pwd ? `?pwd=${encodeURIComponent(pwd)}` : ""}`;
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
    const button = document.createElement("button");
    button.type = "button";
    button.title = title;
    button.textContent = label;
    wrap.append(button);
    root.append(style, wrap);
    const toast = (text, kind = "info") => {
      const el = document.createElement("div");
      el.className = kind === "error" ? "toast error" : "toast";
      el.textContent = text;
      wrap.insertBefore(el, button);
      window.setTimeout(() => el.remove(), kind === "error" ? 8e3 : 4e3);
    };
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (button.disabled) return;
      button.disabled = true;
      onClick().then((msg) => {
        if (msg) toast(msg);
      }).catch((e) => toast(e instanceof Error ? e.message : String(e), "error")).finally(() => {
        button.disabled = false;
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

  // src/page/lanzou.ts
  function isShown(selector) {
    const el = document.querySelector(selector);
    return el !== null && el.getClientRects().length > 0;
  }
  if (window === window.top) {
    const button = floatingButton("\u76F4\u94FE\u4E0B\u8F7D", "\u89E3\u6790\u5F53\u524D\u5206\u4EAB\u5E76\u76F4\u63A5\u4E0B\u8F7D\uFF08\u6587\u4EF6\u5939\u53EF\u52FE\u9009\u6587\u4EF6\uFF09", async () => {
      const link = parseShareText(location.href);
      if (!link) throw new Error("\u5F53\u524D\u9875\u9762\u4E0D\u662F\u5206\u4EAB\u9875");
      const typed = document.querySelector("#pwd")?.value.trim() ?? "";
      const pwd = typed || link.pwd;
      if (pwd === "" && (isShown("#passwddiv") || isShown("#pwdload"))) throw new Error("\u8BF7\u5148\u5728\u9875\u9762\u8F93\u5165\u63D0\u53D6\u7801");
      await sendTask(shareUrl(link.host, link.id, pwd));
      return "\u5DF2\u52A0\u5165\u4E0B\u8F7D";
    });
    onUrlChange((href) => button.setVisible(parseShareText(href) !== null));
  }
})();
