"use strict";
(() => {
  // src/core/site.ts
  function hostIn(host2, domains) {
    return domains.some((d) => host2 === d || host2.endsWith(`.${d}`));
  }

  // src/core/names.ts
  var MAX_PATH_CHARS = 180;
  function safeFileName(name, maxChars = MAX_PATH_CHARS) {
    let s = name.replace(/[\u0000-\u001f\u007f/\\]/g, "_").replace(/\.{2,}/g, ".").trim();
    if (s === "" || s === ".") s = "\u672A\u547D\u540D";
    const chars = Array.from(s);
    if (chars.length <= maxChars) return s;
    const dot = s.lastIndexOf(".");
    const ext = dot > 0 && s.length - dot <= 16 ? s.slice(dot) : "";
    return Array.from(s.slice(0, s.length - ext.length)).slice(0, maxChars - Array.from(ext).length).join("") + ext;
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

  // src/sites/cnki/link.ts
  var FORMATS = {
    pdf: { label: "PDF", ext: "pdf" },
    caj: { label: "CAJ", ext: "caj" }
  };
  var CNKI_DOMAINS = ["cnki.net"];
  function isDetailPage(url) {
    const parsed = parseUrl(url);
    if (!parsed || !hostIn(parsed.host, CNKI_DOMAINS)) return false;
    const path = parsed.path.toLowerCase();
    return /^\/kcms2\/article\/abstract\/?$/.test(path) || path.startsWith("/kcms/detail/");
  }
  function downloadLink(href) {
    const parsed = parseUrl(href);
    if (!parsed || !hostIn(parsed.host, CNKI_DOMAINS)) return null;
    const path = parsed.path.toLowerCase();
    const query = parseQuery(parsed.query);
    if (/^\/bar(new)?\/download\/order$/.test(path)) return query.id ? href.trim() : null;
    if (/^\/(kcms|kns8?)\/download\.aspx$/.test(path)) return query.filename ? href.trim() : null;
    return null;
  }
  function formatOf(anchor) {
    if (anchor.id === "pdfDown" || /(^|\s)btn-dlpdf(\s|$)/.test(anchor.container) || /^PDF\s*下载$/i.test(anchor.text)) return "pdf";
    if (anchor.id === "cajDown" || /(^|\s)btn-dlcaj(\s|$)/.test(anchor.container) || /^CAJ\s*下载$/i.test(anchor.text)) return "caj";
    return null;
  }
  function pickDownloads(anchors) {
    const found = {};
    for (const anchor of anchors) {
      const format = formatOf(anchor);
      if (!format || found[format]) continue;
      const link = downloadLink(anchor.href);
      if (link) found[format] = link;
    }
    return found;
  }
  function cleanTitle(raw) {
    let title = raw.replace(/\s+/g, " ").trim();
    title = title.replace(/\s*[-–—_|]\s*中国知网$/, "");
    for (; ; ) {
      const next = title.replace(/\s*(网络首发|附视频)$/, "");
      if (next === title) break;
      title = next;
    }
    return title.trim();
  }
  function downloadFileName(title, format) {
    const clean = cleanTitle(title);
    return clean === "" ? void 0 : safeFileName(`${clean}.${FORMATS[format].ext}`);
  }

  // src/page/kit.ts
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

  // src/page/cnki.ts
  var STYLE = `
:host { all: initial; }
.fab { position: fixed; right: 24px; bottom: 24px; z-index: 2147482000; display: flex; flex-direction: column; align-items: flex-end; gap: 8px; }
button { all: unset; box-sizing: border-box; cursor: pointer; display: inline-flex; align-items: center; height: 40px; padding: 0 16px;
  border-radius: 20px; background: #2563eb; color: #fff; box-shadow: 0 8px 24px rgba(15, 23, 42, .18);
  font: 500 14px/1 -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; white-space: nowrap; }
button:hover { background: #1d4ed8; }
button.caj { background: #fff; color: #2563eb; border: 1px solid #2563eb; }
button.caj:hover { background: #eff6ff; }
button[disabled] { opacity: .6; cursor: progress; }
.toast { max-width: 360px; padding: 10px 14px; border-radius: 8px; background: #0f172a; color: #fff; box-shadow: 0 8px 24px rgba(15, 23, 42, .18);
  font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; word-break: break-all; }
.toast.error { background: #b91c1c; }
`;
  function collectAnchors() {
    return Array.from(document.querySelectorAll("a[href]"), (a) => ({
      id: a.id,
      container: a.closest("li")?.className ?? "",
      text: (a.textContent ?? "").trim(),
      href: a.href
    }));
  }
  function readTitle() {
    const h1 = document.querySelector(".brief h1, .wx-tit h1");
    if (h1) {
      const copy = h1.cloneNode(true);
      copy.querySelectorAll("span").forEach((span) => span.remove());
      const title = cleanTitle(copy.textContent ?? "");
      if (title) return title;
    }
    return cleanTitle(document.title);
  }
  function captchaShowing() {
    const el = document.querySelector("#tcaptcha_transform_dy");
    return el !== null && el.getBoundingClientRect().top >= 0;
  }
  async function download(format) {
    const label = FORMATS[format].label;
    if (captchaShowing()) throw new Error("\u77E5\u7F51\u6B63\u5728\u8981\u6C42\u5B89\u5168\u9A8C\u8BC1\uFF0C\u8BF7\u5148\u5728\u9875\u9762\u4E0A\u5B8C\u6210\u9A8C\u8BC1\u518D\u4E0B\u8F7D");
    const link = pickDownloads(collectAnchors())[format];
    if (!link) throw new Error(`\u9875\u9762\u4E0A\u6CA1\u6709 ${label} \u4E0B\u8F7D\u5165\u53E3\uFF08\u8BE5\u6587\u732E\u53EF\u80FD\u4E0D\u63D0\u4F9B\uFF0C\u6216\u9875\u9762\u8FD8\u6CA1\u52A0\u8F7D\u5B8C\uFF09`);
    await sendTask(link, downloadFileName(readTitle(), format));
    return `\u5DF2\u53D1\u9001 ${label} \u4E0B\u8F7D\u4EFB\u52A1\uFF08\u9700\u8981\u8D26\u53F7 / \u673A\u6784\u7684\u4E0B\u8F7D\u6743\u9650\uFF09`;
  }
  var host = document.createElement("div");
  var root = host.attachShadow({ mode: "closed" });
  var style = document.createElement("style");
  style.textContent = STYLE;
  var wrap = document.createElement("div");
  wrap.className = "fab";
  root.append(style, wrap);
  var buttons = { pdf: document.createElement("button"), caj: document.createElement("button") };
  for (const format of ["caj", "pdf"]) {
    const button = buttons[format];
    button.type = "button";
    button.className = format;
    button.textContent = `\u76F4\u94FE\u4E0B\u8F7D ${FORMATS[format].label}`;
    button.title = `\u628A\u672C\u6587\u7684 ${FORMATS[format].label} \u5168\u6587\u4EA4\u7ED9\u4E0B\u8F7D\u5668`;
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (button.disabled) return;
      button.disabled = true;
      download(format).then((msg) => toast(msg)).catch((e) => toast(e instanceof Error ? e.message : String(e), "error")).finally(() => {
        button.disabled = false;
      });
    });
    wrap.append(button);
  }
  function toast(text, kind = "info") {
    const el = document.createElement("div");
    el.className = kind === "error" ? "toast error" : "toast";
    el.textContent = text;
    wrap.insertBefore(el, wrap.firstChild);
    window.setTimeout(() => el.remove(), kind === "error" ? 8e3 : 4e3);
  }
  function refresh() {
    const available = isDetailPage(location.href) ? pickDownloads(collectAnchors()) : {};
    for (const format of ["pdf", "caj"]) buttons[format].style.display = available[format] ? "" : "none";
    host.style.display = available.pdf || available.caj ? "" : "none";
    if (!host.isConnected) document.documentElement.append(host);
  }
  var scheduled = false;
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    window.requestAnimationFrame(() => {
      scheduled = false;
      refresh();
    });
  }
  new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
  onUrlChange(schedule);
})();
