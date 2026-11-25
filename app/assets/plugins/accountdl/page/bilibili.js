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

  // src/sites/bilibili/link.ts
  var BILI_HOSTS = ["www.bilibili.com", "bilibili.com", "m.bilibili.com"];
  var VIDEO_PATH = /^\/video\/(?:(BV[0-9A-Za-z]{10})|av(\d{1,19}))\/?$/i;
  var BANGUMI_PATH = /^\/bangumi\/play\/(?:ep(\d{1,12})|ss(\d{1,12}))\/?$/i;
  function parseBilibiliLink(url) {
    if (!BILI_HOSTS.includes(url.host)) return null;
    const video = VIDEO_PATH.exec(url.path);
    if (video) {
      const page = parsePage(parseQuery(url.query)["p"]);
      if (video[1]) return { kind: "video", idKey: "bvid", id: `BV${video[1].slice(2)}`, page };
      return { kind: "video", idKey: "aid", id: video[2], page };
    }
    const bangumi = BANGUMI_PATH.exec(url.path);
    if (bangumi) {
      if (bangumi[1]) return { kind: "episode", id: bangumi[1] };
      return { kind: "season", id: bangumi[2] };
    }
    return null;
  }
  function parsePage(value) {
    if (value === void 0 || !/^\d{1,4}$/.test(value)) return null;
    const n = Number(value);
    return n >= 1 ? n : null;
  }
  function canonicalUrl(target, page = target.kind === "video" ? target.page : null) {
    switch (target.kind) {
      case "video": {
        const path = target.idKey === "bvid" ? target.id : `av${target.id}`;
        return `https://www.bilibili.com/video/${path}${page !== null ? `?p=${page}` : ""}`;
      }
      case "episode":
        return `https://www.bilibili.com/bangumi/play/ep${target.id}`;
      case "season":
        return `https://www.bilibili.com/bangumi/play/ss${target.id}`;
    }
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

  // src/page/bilibili.ts
  function currentTaskUrl() {
    const parsed = parseUrl(location.href);
    const target = parsed ? parseBilibiliLink(parsed) : null;
    if (!target) return null;
    return target.kind === "video" ? canonicalUrl(target, target.page ?? 1) : canonicalUrl(target);
  }
  var button = floatingButton("\u76F4\u94FE\u4E0B\u8F7D", "\u7528\u5F53\u524D\u767B\u5F55\u8D26\u53F7\u89E3\u6790\u5E76\u4E0B\u8F7D\u672C\u9875\u89C6\u9891", async () => {
    const url = currentTaskUrl();
    if (!url) throw new Error("\u5F53\u524D\u9875\u9762\u4E0D\u662F\u89C6\u9891\u9875");
    await sendTask(url);
    return "\u5DF2\u53D1\u9001\u5230\u4E0B\u8F7D\u5668";
  });
  onUrlChange(() => button.setVisible(currentTaskUrl() !== null));
})();
