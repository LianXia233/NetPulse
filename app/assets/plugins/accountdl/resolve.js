"use strict";
(() => {
  // bundled plugin-sdk runtime
  function install(name, fn) {
    Reflect.set(globalThis, name, fn);
  }
  function defineResolver(fn) {
    install("resolve", fn);
    return fn;
  }

  // src/core/errors.ts
  var SiteError = class extends Error {
    kind;
    detail;
    constructor(site, stage, detail, kind = "other") {
      super(`${site}\xB7${stage}\uFF1A${detail}`);
      this.name = "SiteError";
      this.kind = kind;
      this.detail = detail;
    }
  };
  function errorMessage(e) {
    return e instanceof Error ? e.message : String(e);
  }

  // src/core/cookies.ts
  function parseCookies(header) {
    const jar = /* @__PURE__ */ new Map();
    for (const part of header.split(";")) {
      const eq = part.indexOf("=");
      if (eq <= 0) continue;
      const name = part.slice(0, eq).trim();
      if (name === "") continue;
      jar.set(name, part.slice(eq + 1).trim());
    }
    return jar;
  }
  function formatCookies(jar) {
    return [...jar].map(([k, v]) => `${k}=${v}`).join("; ");
  }
  function pickCookies(header, names) {
    const jar = parseCookies(header);
    const out = /* @__PURE__ */ new Map();
    for (const name of names) {
      const value = jar.get(name);
      if (value !== void 0) out.set(name, value);
    }
    return formatCookies(out);
  }
  function mergeSetCookie(header, setCookie) {
    if (!setCookie) return header;
    const jar = parseCookies(header);
    for (const line of setCookie.split("\n")) {
      const [pair, ...attrs] = line.split(";");
      const eq = pair.indexOf("=");
      if (eq <= 0) continue;
      const name = pair.slice(0, eq).trim();
      const value = pair.slice(eq + 1).trim();
      const removed = value === "" || attrs.some((a) => /^\s*max-age\s*=\s*(0|-\d+)\s*$/i.test(a)) || attrs.some((a) => /^\s*expires\s*=.*\b(19[0-9]{2}|1970)\b/i.test(a));
      if (removed) jar.delete(name);
      else jar.set(name, value);
    }
    return formatCookies(jar);
  }

  // src/core/names.ts
  var MAX_DEPTH = 8;
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
  function manifestPath(dirs, fileName) {
    const segments = dirs.map((d) => safeFileName(d)).slice(0, MAX_DEPTH);
    const nameChars = Array.from(fileName).length;
    while (segments.length > 0 && Array.from(segments.join("/")).length + 1 + nameChars > MAX_PATH_CHARS) {
      segments.pop();
    }
    return segments.join("/");
  }

  // src/core/manifest.ts
  var MAX_ITEMS = 1e3;
  var MAX_ITEM_ID_CHARS = 200;
  function manifestResult(site, name, files) {
    if (files.length === 0) throw new SiteError(site, "\u751F\u6210\u6E05\u5355", "\u6CA1\u6709\u53EF\u4E0B\u8F7D\u7684\u6587\u4EF6", "notFound");
    if (files.length > MAX_ITEMS) throw new SiteError(site, "\u751F\u6210\u6E05\u5355", `\u6587\u4EF6\u8FC7\u591A\uFF08${files.length} > ${MAX_ITEMS}\uFF09\uFF0C\u8BF7\u8FDB\u5165\u5B50\u76EE\u5F55\u5206\u6279\u4E0B\u8F7D`, "limit");
    const items = files.map((f) => {
      if (f.id === "" || Array.from(f.id).length > MAX_ITEM_ID_CHARS) {
        throw new SiteError(site, "\u751F\u6210\u6E05\u5355", "\u6761\u76EE\u6807\u8BC6\u8FC7\u957F", "unsupported");
      }
      const fileName = safeFileName(f.name);
      const path = manifestPath(f.dirs ?? [], fileName);
      return {
        id: f.id,
        name: fileName,
        kind: "file",
        ...path ? { path } : {},
        ...f.size !== void 0 && f.size >= 0 ? { size: f.size } : {}
      };
    });
    return { manifest: { name: safeFileName(name), items } };
  }

  // src/core/json.ts
  function asObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value) ? value : null;
  }
  function asArray(value) {
    return Array.isArray(value) ? value : [];
  }
  function asString(value) {
    if (typeof value === "string") return value;
    if (typeof value === "number" && Number.isFinite(value)) return String(value);
    return "";
  }
  function asNumber(value) {
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) return Number(value);
    return null;
  }

  // src/core/http.ts
  async function request(site, stage, req) {
    const headers = { ...req.headers ?? {} };
    if (req.cookies) headers["Cookie"] = req.cookies;
    if (req.userAgent) headers["User-Agent"] = req.userAgent;
    if (req.referer) headers["Referer"] = req.referer;
    let res;
    try {
      res = await flux.fetch({ method: req.method ?? "GET", url: req.url, headers, body: req.body });
    } catch (e) {
      throw new SiteError(site, stage, `\u7F51\u7EDC\u8BF7\u6C42\u5931\u8D25\uFF08${e instanceof Error ? e.message : String(e)}\uFF09`, "network");
    }
    if (res.truncated) throw new SiteError(site, stage, "\u54CD\u5E94\u8FC7\u5927\u88AB\u622A\u65AD", "network");
    return { status: res.status, headers: res.headers, body: res.body };
  }
  function parseJsonObject(site, stage, body) {
    let value;
    try {
      value = JSON.parse(body);
    } catch {
      throw new SiteError(site, stage, "\u8FD4\u56DE\u7684\u4E0D\u662F JSON\uFF08\u7AD9\u70B9\u53EF\u80FD\u6539\u7248\u6216\u8981\u6C42\u9A8C\u8BC1\uFF09", "network");
    }
    const obj = asObject(value);
    if (!obj) throw new SiteError(site, stage, "\u8FD4\u56DE\u7684 JSON \u4E0D\u662F\u5BF9\u8C61", "network");
    return obj;
  }
  function formBody(params) {
    return Object.entries(params).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
  }

  // src/core/hash.ts
  function utf8Bytes(s) {
    const out = [];
    for (const ch of s) {
      let c = ch.codePointAt(0);
      if (c < 128) out.push(c);
      else if (c < 2048) out.push(192 | c >> 6, 128 | c & 63);
      else if (c < 65536) out.push(224 | c >> 12, 128 | c >> 6 & 63, 128 | c & 63);
      else out.push(240 | c >> 18, 128 | c >> 12 & 63, 128 | c >> 6 & 63, 128 | c & 63);
    }
    return Uint8Array.from(out);
  }
  function toHex(bytes) {
    let s = "";
    for (const b of bytes) s += b.toString(16).padStart(2, "0");
    return s;
  }
  var MD5_S = [
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21
  ];
  var MD5_K = Array.from({ length: 64 }, (_, i) => Math.floor(Math.abs(Math.sin(i + 1)) * 2 ** 32) >>> 0);
  function md5(input) {
    const msg = typeof input === "string" ? utf8Bytes(input) : input;
    const len = msg.length;
    const padded = new Uint8Array(len + 72 >>> 6 << 6);
    padded.set(msg);
    padded[len] = 128;
    const bits = len * 8;
    const view = new DataView(padded.buffer);
    view.setUint32(padded.length - 8, bits >>> 0, true);
    view.setUint32(padded.length - 4, Math.floor(bits / 2 ** 32), true);
    let a0 = 1732584193, b0 = 4023233417, c0 = 2562383102, d0 = 271733878;
    for (let off = 0; off < padded.length; off += 64) {
      let a = a0, b = b0, c = c0, d = d0;
      for (let i = 0; i < 64; i++) {
        let f, g;
        if (i < 16) {
          f = b & c | ~b & d;
          g = i;
        } else if (i < 32) {
          f = d & b | ~d & c;
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) % 16;
        } else {
          f = c ^ (b | ~d);
          g = 7 * i % 16;
        }
        const tmp = d;
        d = c;
        c = b;
        const x = a + f + MD5_K[i] + view.getUint32(off + g * 4, true) | 0;
        b = b + (x << MD5_S[i] | x >>> 32 - MD5_S[i]) | 0;
        a = tmp;
      }
      a0 = a0 + a | 0;
      b0 = b0 + b | 0;
      c0 = c0 + c | 0;
      d0 = d0 + d | 0;
    }
    const out = new Uint8Array(16);
    const ov = new DataView(out.buffer);
    ov.setUint32(0, a0, true);
    ov.setUint32(4, b0, true);
    ov.setUint32(8, c0, true);
    ov.setUint32(12, d0, true);
    return toHex(out);
  }
  function sha1(input) {
    const msg = typeof input === "string" ? utf8Bytes(input) : input;
    const len = msg.length;
    const padded = new Uint8Array(len + 72 >>> 6 << 6);
    padded.set(msg);
    padded[len] = 128;
    const view = new DataView(padded.buffer);
    const bits = len * 8;
    view.setUint32(padded.length - 8, Math.floor(bits / 2 ** 32), false);
    view.setUint32(padded.length - 4, bits >>> 0, false);
    let h0 = 1732584193, h1 = 4023233417, h2 = 2562383102, h3 = 271733878, h4 = 3285377520;
    const w = new Int32Array(80);
    for (let off = 0; off < padded.length; off += 64) {
      for (let i = 0; i < 16; i++) w[i] = view.getInt32(off + i * 4, false);
      for (let i = 16; i < 80; i++) {
        const x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
        w[i] = x << 1 | x >>> 31;
      }
      let a = h0, b = h1, c = h2, d = h3, e = h4;
      for (let i = 0; i < 80; i++) {
        let f, k;
        if (i < 20) {
          f = b & c | ~b & d;
          k = 1518500249;
        } else if (i < 40) {
          f = b ^ c ^ d;
          k = 1859775393;
        } else if (i < 60) {
          f = b & c | b & d | c & d;
          k = 2400959708;
        } else {
          f = b ^ c ^ d;
          k = 3395469782;
        }
        const t = (a << 5 | a >>> 27) + f + e + k + w[i] | 0;
        e = d;
        d = c;
        c = b << 30 | b >>> 2;
        b = a;
        a = t;
      }
      h0 = h0 + a | 0;
      h1 = h1 + b | 0;
      h2 = h2 + c | 0;
      h3 = h3 + d | 0;
      h4 = h4 + e | 0;
    }
    const out = new Uint8Array(20);
    const ov = new DataView(out.buffer);
    [h0, h1, h2, h3, h4].forEach((h, i) => ov.setUint32(i * 4, h >>> 0, false));
    return toHex(out);
  }
  var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  function base64Encode(bytes) {
    let out = "";
    for (let i = 0; i < bytes.length; i += 3) {
      const n = bytes[i] << 16 | (bytes[i + 1] ?? 0) << 8 | (bytes[i + 2] ?? 0);
      out += B64[n >> 18 & 63] + B64[n >> 12 & 63];
      out += i + 1 < bytes.length ? B64[n >> 6 & 63] : "=";
      out += i + 2 < bytes.length ? B64[n & 63] : "=";
    }
    return out;
  }
  function base64Decode(text) {
    const s = text.replace(/[\s=]+/g, "").replace(/-/g, "+").replace(/_/g, "/");
    if (/[^A-Za-z0-9+/]/.test(s) || s.length % 4 === 1) throw new Error("base64 \u975E\u6CD5");
    const out = [];
    for (let i = 0; i < s.length; i += 4) {
      const n = B64.indexOf(s[i]) << 18 | B64.indexOf(s[i + 1]) << 12 | (i + 2 < s.length ? B64.indexOf(s[i + 2]) : 0) << 6 | (i + 3 < s.length ? B64.indexOf(s[i + 3]) : 0);
      out.push(n >> 16 & 255);
      if (i + 2 < s.length) out.push(n >> 8 & 255);
      if (i + 3 < s.length) out.push(n & 255);
    }
    return Uint8Array.from(out);
  }
  function utf8Decode(bytes) {
    let s = "";
    for (let i = 0; i < bytes.length; ) {
      const b = bytes[i++];
      let c;
      if (b < 128) c = b;
      else if (b < 224) c = (b & 31) << 6 | bytes[i++] & 63;
      else if (b < 240) c = (b & 15) << 12 | (bytes[i++] & 63) << 6 | bytes[i++] & 63;
      else c = (b & 7) << 18 | (bytes[i++] & 63) << 12 | (bytes[i++] & 63) << 6 | bytes[i++] & 63;
      s += String.fromCodePoint(c);
    }
    return s;
  }

  // src/sites/baidu/sign.ts
  var LOCATE_MAGIC = "ebrcUYiuxaZv2XGu7KIYKxUrqfnOfpDF";
  function locateSign(uid, bduss, unix) {
    const devuid = `${md5(bduss).toUpperCase()}|0`;
    const time = String(unix);
    const rand = sha1(sha1(bduss) + uid + LOCATE_MAGIC + time + devuid);
    return { time, rand, devuid, cuid: devuid };
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
  function parseTaskUrl(url) {
    if (url.scheme !== "https" || !url.path.startsWith(TASK_PREFIX)) return null;
    const siteId = url.path.slice(TASK_PREFIX.length);
    if (!/^[a-z0-9]{1,16}$/.test(siteId)) return null;
    return { siteId, params: parseQuery(url.query) };
  }

  // src/sites/baidu/link.ts
  var SITE_ID = "baidu";
  var SITE_NAME = "\u767E\u5EA6\u7F51\u76D8";
  var SHARE_HOSTS = ["pan.baidu.com", "yun.baidu.com"];
  var KEY_RE = /^[0-9][A-Za-z0-9_-]{5,40}$/;
  var PWD_RE = /^[A-Za-z0-9]{0,32}$/;
  var MAX_DIR_CHARS = 1024;
  function validDir(dir) {
    if (!dir.startsWith("/") || Array.from(dir).length > MAX_DIR_CHARS) return false;
    for (let i = 0; i < dir.length; i++) {
      const c = dir.charCodeAt(i);
      if (c < 32 || c === 127) return false;
    }
    return true;
  }
  function readTask(url) {
    if (!SHARE_HOSTS.includes(url.host)) return null;
    const parsed = parseTaskUrl(url);
    if (!parsed || parsed.siteId !== SITE_ID) return null;
    const { s = "", pwd = "", dir = "", name = "" } = parsed.params;
    if (!KEY_RE.test(s) || !PWD_RE.test(pwd)) return null;
    if (dir !== "" && !validDir(dir)) return null;
    return { key: s, surl: s.slice(1), pwd, dir, name };
  }

  // src/sites/baidu/api.ts
  var APP_ID = "250528";
  var PAN = "https://pan.baidu.com";
  var PCS = "https://pcs.baidu.com";
  var ANDROID_UA = "netdisk;P2SP;3.0.0.8;netdisk;11.12.3;ANG-AN00;android-android;10.0;JSbridge4.4.0;jointBridge;1.1.0;";
  var BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";
  var SCRATCH_ROOT = "/accountdl-tmp";
  var PAGE_SIZE = 100;
  var TRANSFER_POLLS = 8;
  var MAX_LIST_REQUESTS = 20;
  function fail(stage, detail, kind) {
    throw new SiteError(SITE_NAME, stage, detail, kind);
  }
  function errnoOf(obj) {
    return asNumber(obj.errno) ?? 0;
  }
  function quoteBigInts(body) {
    return body.replace(/"(fs_id|share_id|uk|from_uk|task_id)"\s*:\s*(\d{15,})/g, '"$1":"$2"');
  }
  function withBdclnd(cookies, bdclnd) {
    if (bdclnd === "") return cookies;
    const jar = parseCookies(cookies);
    jar.set("BDCLND", bdclnd);
    return formatCookies(jar);
  }
  var BaiduClient = class {
    constructor(cookies, browserUA) {
      this.cookies = cookies;
      this.browserUA = browserUA;
    }
    cookies;
    browserUA;
    /** 已发出的请求数。 */
    requests = 0;
    async call(stage, method, url, o) {
      this.requests++;
      const res = await request(SITE_NAME, stage, {
        method,
        url,
        headers: o.form ? { "Content-Type": "application/x-www-form-urlencoded" } : {},
        body: o.form ? formBody(o.form) : void 0,
        cookies: o.cookie ?? this.cookies,
        userAgent: o.ua ?? ANDROID_UA,
        referer: o.referer
      });
      if (res.status < 200 || res.status >= 300) fail(stage, `HTTP ${res.status}`, "network");
      return { obj: parseJsonObject(SITE_NAME, stage, quoteBigInts(res.body)), setCookie: res.headers["set-cookie"] ?? "" };
    }
    /** 验证提取码，返回要并入 Cookie 的 BDCLND（无提取码返回 ""，沿用浏览器 Cookie 里的 BDCLND）。 */
    async verifyShare(surl, pwd) {
      if (pwd === "") return "";
      const stage = "\u9A8C\u8BC1\u63D0\u53D6\u7801";
      const q = formBody({ surl, t: String(Date.now()), channel: "chunlei", web: "1", app_id: APP_ID, clienttype: "0" });
      const { obj, setCookie } = await this.call(stage, "POST", `${PAN}/share/verify?${q}`, {
        form: { pwd, vcode: "", vcode_str: "" },
        referer: `${PAN}/share/init?surl=${surl}`,
        ua: this.browserUA
      });
      const errno = errnoOf(obj);
      switch (errno) {
        case 0: {
          const fromCookie = parseCookies(mergeSetCookie("", setCookie)).get("BDCLND");
          if (fromCookie) return fromCookie;
          const randsk = asString(obj.randsk);
          if (randsk === "") fail(stage, "\u9A8C\u8BC1\u901A\u8FC7\u4F46\u6CA1\u6709\u8FD4\u56DE\u4F1A\u8BDD\u51ED\u636E", "network");
          return safeUnescape(randsk);
        }
        case -9:
        case 200025:
          return fail(stage, "\u63D0\u53D6\u7801\u9519\u8BEF", "password");
        case -6:
          return fail(stage, "\u767E\u5EA6\u767B\u5F55\u5DF2\u5931\u6548\uFF0C\u8BF7\u5728\u6D4F\u89C8\u5668\u91CD\u65B0\u767B\u5F55\u767E\u5EA6\u7F51\u76D8", "login");
        case 105:
        case 115:
        case 117:
        case 140:
        case 145:
          return fail(stage, "\u5206\u4EAB\u94FE\u63A5\u4E0D\u5B58\u5728\u6216\u5DF2\u5931\u6548", "notFound");
        case -62:
        case -19:
          return fail(stage, "\u89E6\u53D1\u9A8C\u8BC1\u7801\uFF0C\u8BF7\u5148\u5728\u6D4F\u89C8\u5668\u91CC\u6253\u5F00\u8BE5\u5206\u4EAB\u5B8C\u6210\u9A8C\u8BC1\u540E\u91CD\u8BD5", "limit");
        default:
          return fail(stage, asString(obj.show_msg) || `\u9519\u8BEF\u7801 ${errno}`, "other");
      }
    }
    /** 列一页分享目录；`dir` 为 "" 列根目录。 */
    async listPage(surl, dir, bdclnd, page) {
      const stage = "\u8BFB\u53D6\u5206\u4EAB\u76EE\u5F55";
      if (this.requests >= MAX_LIST_REQUESTS) {
        fail(stage, "\u76EE\u5F55\u592A\u5927\uFF0C\u4E00\u6B21\u89E3\u6790\u8BF7\u6C42\u6B21\u6570\u8D85\u9650\uFF0C\u8BF7\u8FDB\u5165\u5B50\u76EE\u5F55\u5206\u6279\u4E0B\u8F7D", "limit");
      }
      const q = {
        web: "5",
        app_id: APP_ID,
        channel: "chunlei",
        clienttype: "0",
        page: String(page),
        num: String(PAGE_SIZE),
        order: "name",
        desc: "0",
        shorturl: surl
      };
      if (dir === "") q.root = "1";
      else q.dir = dir;
      const { obj } = await this.call(stage, "GET", `${PAN}/share/list?${formBody(q)}`, {
        cookie: withBdclnd(this.cookies, bdclnd),
        referer: `${PAN}/share/init?surl=${surl}`,
        ua: this.browserUA
      });
      const errno = errnoOf(obj);
      switch (errno) {
        case 0:
          break;
        case -9:
          return fail(stage, "\u6B64\u5206\u4EAB\u9700\u8981\u63D0\u53D6\u7801\uFF0C\u6216\u63D0\u53D6\u7801\u5DF2\u5931\u6548", "password");
        case 2:
          return fail(stage, "\u76EE\u5F55\u4E0D\u5B58\u5728", "notFound");
        case 105:
        case 115:
        case 117:
        case 140:
        case 145:
          return fail(stage, "\u5206\u4EAB\u94FE\u63A5\u4E0D\u5B58\u5728\u6216\u5DF2\u5931\u6548", "notFound");
        case -6:
          return fail(stage, "\u767E\u5EA6\u767B\u5F55\u5DF2\u5931\u6548\uFF0C\u8BF7\u5728\u6D4F\u89C8\u5668\u91CD\u65B0\u767B\u5F55\u767E\u5EA6\u7F51\u76D8", "login");
        case 9019:
          return fail(stage, "\u767E\u5EA6\u8981\u6C42\u5B89\u5168\u9A8C\u8BC1\uFF089019\uFF09\uFF0C\u8BF7\u5148\u5728\u6D4F\u89C8\u5668\u5B8C\u6210\u9A8C\u8BC1", "limit");
        case 8001:
        case 9013:
          return fail(stage, "\u8D26\u53F7\u88AB\u9650\u5236\uFF0C\u8BF7\u68C0\u67E5\u8D26\u53F7\u72B6\u6001", "limit");
        default:
          return fail(stage, asString(obj.show_msg) || `\u9519\u8BEF\u7801 ${errno}`, "other");
      }
      const list = asArray(obj.list);
      const entries = [];
      for (const v of list) {
        const m = asObject(v);
        const name = m ? asString(m.server_filename) : "";
        if (!m || name === "") continue;
        const isDir = asString(m.isdir) === "1";
        const path = asString(m.path);
        const fsid = asString(m.fs_id);
        if (isDir ? path === "" : !/^\d{1,20}$/.test(fsid)) continue;
        entries.push({ name, isDir, path, fsid, size: isDir ? -1 : asNumber(m.size) ?? -1 });
      }
      return { entries, shareId: asString(obj.share_id), uk: asString(obj.uk), last: list.length < PAGE_SIZE };
    }
    /** 列出目录全部条目（翻页）。 */
    async listAll(surl, dir, bdclnd) {
      const out = [];
      for (let page = 1; ; page++) {
        const res = await this.listPage(surl, dir, bdclnd, page);
        out.push(...res.entries);
        if (res.last) return out;
      }
    }
    /** 账号的 bdstoken 与 uk（locatedownload 签名的 uid）。只有这里的 -6 判定登录失效。 */
    async account() {
      const stage = "\u8BFB\u53D6\u8D26\u53F7\u4FE1\u606F";
      const { obj } = await this.call(stage, "GET", `${PAN}/api/loginStatus?clienttype=0&app_id=${APP_ID}&web=1`, {
        referer: `${PAN}/disk/home`
      });
      const errno = errnoOf(obj);
      if (errno === -6) fail(stage, "\u767E\u5EA6\u767B\u5F55\u5DF2\u5931\u6548\uFF0C\u8BF7\u5728\u6D4F\u89C8\u5668\u91CD\u65B0\u767B\u5F55\u767E\u5EA6\u7F51\u76D8", "login");
      if (errno !== 0) fail(stage, asString(obj.show_msg) || `\u9519\u8BEF\u7801 ${errno}`, "other");
      const info = asObject(obj.login_info);
      let bdstoken = info ? asString(info.bdstoken) : "";
      const uid = info ? asString(info.uk) : "";
      if (bdstoken === "") {
        const fields = formBody({ clienttype: "0", app_id: APP_ID, web: "1", fields: '["bdstoken"]' });
        const t = await this.call(stage, "GET", `${PAN}/api/gettemplatevariable?${fields}`, { referer: `${PAN}/disk/home` });
        bdstoken = asString(asObject(t.obj.result)?.bdstoken);
      }
      if (bdstoken === "" || uid === "") fail(stage, "\u672A\u8FD4\u56DE bdstoken \u6216 uk", "network");
      return { bdstoken, uid };
    }
    /** 会员等级 vip_type：0 普通 / 1 会员 / 2 SVIP；查询失败按 0（最保守）。 */
    async vipType() {
      try {
        const { obj } = await this.call("\u8BFB\u53D6\u4F1A\u5458\u7B49\u7EA7", "GET", `${PAN}/api/user/getinfo?need_selfinfo=1&clienttype=0&app_id=${APP_ID}&web=1`, {
          referer: `${PAN}/disk/home`
        });
        const rec = asObject(asArray(obj.records)[0]);
        const v = rec ? asNumber(rec.vip_type) : null;
        return v === 1 || v === 2 ? v : 0;
      } catch {
        return 0;
      }
    }
    /** 创建临时目录（含父目录）。 */
    async mkdir(bdstoken, dir) {
      const stage = "\u521B\u5EFA\u4E34\u65F6\u76EE\u5F55";
      const q = formBody({ a: "commit", clienttype: "0", app_id: APP_ID, web: "1", bdstoken });
      const { obj } = await this.call(stage, "POST", `${PAN}/api/create?${q}`, {
        form: { path: dir, isdir: "1", block_list: "[]" },
        referer: `${PAN}/disk/home`
      });
      const errno = errnoOf(obj);
      if (errno === 0 || errno === -8) return;
      if (errno === -6) fail(stage, "\u767E\u5EA6\u62D2\u7EDD\u5199\u5165\uFF08-6\uFF09\uFF0C\u8D26\u53F7\u53EF\u80FD\u9700\u8981\u5148\u5728\u6D4F\u89C8\u5668\u5B8C\u6210\u5B89\u5168\u9A8C\u8BC1", "limit");
      if (errno === -10) fail(stage, "\u7F51\u76D8\u7A7A\u95F4\u4E0D\u8DB3\uFF0C\u8BF7\u6E05\u7406\u7A7A\u95F4\u540E\u91CD\u8BD5", "limit");
      fail(stage, asString(obj.show_msg) || `\u9519\u8BEF\u7801 ${errno}`, "other");
    }
    /** 把分享文件转存进 `dir`，返回转存后的路径。 */
    async transfer(p) {
      const stage = "\u8F6C\u5B58\u6587\u4EF6";
      const cookie = withBdclnd(this.cookies, p.bdclnd);
      const referer = `${PAN}/s/${p.key}`;
      const q = formBody({
        shareid: p.shareId,
        from: p.uk,
        bdstoken: p.bdstoken,
        app_id: APP_ID,
        channel: "chunlei",
        clienttype: "0",
        web: "1"
      });
      const { obj } = await this.call(stage, "POST", `${PAN}/share/transfer?${q}`, {
        form: { fsidlist: `[${p.fsid}]`, path: p.dir },
        cookie,
        referer
      });
      const errno = errnoOf(obj);
      if (errno !== 0) transferError(stage, errno, obj);
      const direct = transferTarget(asObject(obj.extra)?.list, p.dir);
      if (direct !== "") return direct;
      const taskId = asString(obj.task_id);
      if (taskId === "" || taskId === "0") fail(stage, "\u63A5\u53E3\u672A\u8FD4\u56DE\u76EE\u6807\u8DEF\u5F84", "network");
      const tq = formBody({
        taskid: taskId,
        shareid: p.shareId,
        from: p.uk,
        bdstoken: p.bdstoken,
        app_id: APP_ID,
        channel: "chunlei",
        clienttype: "0",
        web: "1"
      });
      for (let i = 0; i < TRANSFER_POLLS; i++) {
        const t = await this.call(stage, "GET", `${PAN}/share/taskquery?${tq}`, { cookie, referer });
        const e = errnoOf(t.obj);
        if (e !== 0) fail(stage, `\u67E5\u8BE2\u4EFB\u52A1\u9519\u8BEF\u7801 ${e}`, "other");
        const te = asNumber(t.obj.task_errno) ?? 0;
        if (te !== 0) transferError(stage, te, t.obj);
        if (asString(t.obj.status) === "success") {
          const to = transferTarget(t.obj.list, p.dir);
          return to !== "" ? to : fail(stage, "\u4EFB\u52A1\u5B8C\u6210\u4F46\u672A\u8FD4\u56DE\u76EE\u6807\u8DEF\u5F84", "network");
        }
      }
      return fail(stage, "\u8F6C\u5B58\u4EFB\u52A1\u8D85\u65F6\u672A\u5B8C\u6210\uFF0C\u8BF7\u7A0D\u540E\u91CD\u8BD5", "limit");
    }
    /** locatedownload：取自有文件的 CDN 直链。 */
    async locate(bduss, uid, filePath) {
      const stage = "\u83B7\u53D6\u76F4\u94FE";
      const sign = locateSign(uid, bduss, Math.floor(Date.now() / 1e3));
      const q = formBody({
        ant: "1",
        check_blue: "1",
        es: "1",
        esl: "1",
        app_id: APP_ID,
        method: "locatedownload",
        path: filePath,
        ver: "4.0",
        clienttype: "17",
        channel: "0",
        apn_id: "1_0",
        freeisp: "0",
        queryfree: "0",
        use: "0",
        ...sign
      });
      const { obj } = await this.call(stage, "POST", `${PCS}/rest/2.0/pcs/file?${q}`, {
        cookie: `BDUSS=${bduss}`,
        referer: `${PAN}/disk/home`
      });
      const errno = errnoOf(obj) || (asNumber(obj.error_code) ?? 0);
      if (errno === 9019 || errno === 8002) fail(stage, `\u767E\u5EA6\u4E34\u65F6\u98CE\u63A7\uFF08${errno}\uFF09\uFF0C\u8BF7\u7A0D\u540E\u518D\u8BD5`, "limit");
      if (errno === -6) fail(stage, "\u767E\u5EA6\u62D2\u7EDD\u8BBF\u95EE\uFF08-6\uFF09\uFF0C\u8D26\u53F7\u53EF\u80FD\u9700\u8981\u5148\u5728\u6D4F\u89C8\u5668\u5B8C\u6210\u5B89\u5168\u9A8C\u8BC1", "limit");
      if (errno !== 0) fail(stage, `\u9519\u8BEF\u7801 ${errno}`, "other");
      for (const v of asArray(obj.urls)) {
        const m = asObject(v);
        if (!m || (asNumber(m.encrypt) ?? 0) !== 0) continue;
        const url = asString(m.url);
        if (/^https?:\/\//i.test(url)) return url;
      }
      return fail(stage, "\u63A5\u53E3\u672A\u8FD4\u56DE\u53EF\u7528\u94FE\u63A5", "network");
    }
    /** 把路径移入回收站（回收站不占配额）。 */
    async remove(bdstoken, paths) {
      const stage = "\u5220\u9664\u4E34\u65F6\u76EE\u5F55";
      const q = formBody({
        opera: "delete",
        async: "2",
        onnest: "fail",
        bdstoken,
        newVerify: "1",
        clienttype: "0",
        app_id: APP_ID,
        web: "1"
      });
      const { obj } = await this.call(stage, "POST", `${PAN}/api/filemanager?${q}`, {
        form: { filelist: JSON.stringify(paths) },
        referer: `${PAN}/disk/home`
      });
      const errno = errnoOf(obj);
      if (errno !== 0) fail(stage, `\u9519\u8BEF\u7801 ${errno}`, "other");
    }
  };
  function safeUnescape(s) {
    try {
      return decodeURIComponent(s);
    } catch {
      return s;
    }
  }
  function transferTarget(list, dir) {
    const first = asObject(asArray(list)[0]);
    if (!first) return "";
    const to = asString(first.to);
    if (to !== "") return to;
    const from = asString(first.from);
    return from !== "" ? `${dir}/${from.slice(from.lastIndexOf("/") + 1)}` : "";
  }
  function transferError(stage, errno, obj) {
    if (errno === 12) {
      const inner = asObject(asArray(obj.info)[0]);
      if (inner && asNumber(inner.errno) === -32) fail(stage, "\u7F51\u76D8\u7A7A\u95F4\u4E0D\u8DB3\uFF0C\u8BF7\u6E05\u7406\u7A7A\u95F4\u540E\u91CD\u8BD5", "limit");
    }
    switch (errno) {
      case 2:
        return fail(stage, "\u6587\u4EF6\u4E0D\u5728\u8BE5\u5206\u4EAB\u4E2D\uFF08\u53EF\u80FD\u5DF2\u88AB\u5206\u4EAB\u8005\u5220\u9664\uFF09", "notFound");
      case -9:
        return fail(stage, "\u63D0\u53D6\u7801\u9A8C\u8BC1\u5DF2\u5931\u6548\uFF0C\u8BF7\u91CD\u65B0\u9A8C\u8BC1\u63D0\u53D6\u7801", "password");
      case -6:
        return fail(stage, "\u767E\u5EA6\u62D2\u7EDD\u5199\u5165\uFF08-6\uFF09\uFF0C\u8D26\u53F7\u53EF\u80FD\u9700\u8981\u5148\u5728\u6D4F\u89C8\u5668\u5B8C\u6210\u5B89\u5168\u9A8C\u8BC1", "limit");
      case 9019:
      case 8002:
        return fail(stage, `\u767E\u5EA6\u4E34\u65F6\u98CE\u63A7\uFF08${errno}\uFF09\uFF0C\u8BF7\u7A0D\u540E\u518D\u8BD5`, "limit");
      default:
        return fail(stage, asString(obj.show_msg) || `\u9519\u8BEF\u7801 ${errno}`, "other");
    }
  }

  // src/sites/baidu/index.ts
  var LIST_CONCURRENCY = 4;
  var MiB = 1024 * 1024;
  var CONNECTIONS = [1, 10, 15];
  var FILE_ITEM_RE = /^(\d{1,20})(?::(\d{1,16}))?$/;
  function requireLogin(cookies) {
    const bduss = parseCookies(cookies).get("BDUSS") ?? "";
    if (bduss === "") {
      throw new SiteError(SITE_NAME, "\u68C0\u67E5\u767B\u5F55", "\u6CA1\u6709\u68C0\u6D4B\u5230\u767E\u5EA6\u7F51\u76D8\u767B\u5F55\u4FE1\u606F\uFF1A\u8BF7\u5148\u5728\u6D4F\u89C8\u5668\u767B\u5F55\u767E\u5EA6\u7F51\u76D8\uFF0C\u518D\u4ECE\u5206\u4EAB\u9875\u7684\u6309\u94AE\u53D1\u8D77\u4E0B\u8F7D", "login");
    }
    return bduss;
  }
  async function listManifest(client, surl, startDir, pwd, name) {
    const bdclnd = await client.verifyShare(surl, pwd);
    const files = [];
    let level = [{ dir: startDir, rel: [] }];
    while (level.length > 0) {
      const next = [];
      for (let i = 0; i < level.length; i += LIST_CONCURRENCY) {
        const chunk = level.slice(i, i + LIST_CONCURRENCY);
        const lists = await Promise.all(chunk.map((d) => client.listAll(surl, d.dir, bdclnd)));
        lists.forEach((entries, idx) => {
          const rel = chunk[idx].rel;
          for (const e of entries) {
            if (e.isDir) next.push({ dir: e.path, rel: [...rel, e.name] });
            else files.push({ id: e.size >= 0 ? `${e.fsid}:${e.size}` : e.fsid, name: e.name, dirs: rel, ...e.size >= 0 ? { size: e.size } : {} });
          }
        });
        if (files.length > MAX_ITEMS) {
          throw new SiteError(SITE_NAME, "\u8BFB\u53D6\u5206\u4EAB\u76EE\u5F55", `\u6587\u4EF6\u8D85\u8FC7 ${MAX_ITEMS} \u4E2A\uFF0C\u8BF7\u8FDB\u5165\u5B50\u76EE\u5F55\u5206\u6279\u4E0B\u8F7D`, "limit");
        }
      }
      level = next;
    }
    return manifestResult(SITE_NAME, name, files);
  }
  async function resolveFile(client, bduss, task, item) {
    const m = FILE_ITEM_RE.exec(item);
    if (!m) throw new SiteError(SITE_NAME, "\u8BC6\u522B\u6761\u76EE", "\u6587\u4EF6\u6807\u8BC6\u683C\u5F0F\u4E0D\u6B63\u786E", "unsupported");
    const fsid = m[1];
    const size = m[2] === void 0 ? -1 : Number(m[2]);
    const [share, acct, vip] = await Promise.all([
      (async () => {
        const bdclnd = await client.verifyShare(task.surl, task.pwd);
        return { bdclnd, page: await client.listPage(task.surl, "", bdclnd, 1) };
      })(),
      client.account(),
      client.vipType()
    ]);
    if (share.page.shareId === "" || share.page.uk === "") throw new SiteError(SITE_NAME, "\u8BFB\u53D6\u5206\u4EAB\u4FE1\u606F", "\u672A\u8FD4\u56DE share_id \u6216 uk", "notFound");
    const dir = `${SCRATCH_ROOT}/${Math.floor(Date.now() / 1e3)}-${Math.random().toString(16).slice(2, 10)}`;
    let to;
    let link;
    try {
      await client.mkdir(acct.bdstoken, dir);
      to = await client.transfer({
        bdstoken: acct.bdstoken,
        bdclnd: share.bdclnd,
        key: task.key,
        shareId: share.page.shareId,
        uk: share.page.uk,
        fsid,
        dir
      });
      link = await client.locate(bduss, acct.uid, to);
    } finally {
      try {
        await client.remove(acct.bdstoken, [dir]);
      } catch (e) {
        flux.logger.warn(`\u4E34\u65F6\u76EE\u5F55\u5220\u9664\u5931\u8D25\uFF08${dir}\uFF09\uFF1A${errorMessage(e)}`);
      }
    }
    const connections = CONNECTIONS[vip] ?? 1;
    return {
      url: link,
      fileName: safeFileName(to.slice(to.lastIndexOf("/") + 1)),
      ...size >= 0 ? { totalBytes: size } : {},
      request: {
        // 直链自带签名，只需要安卓 UA，不带任何网盘 Cookie（否则宿主会把整串浏览器 Cookie 发给 CDN）。
        cookies: "",
        userAgent: ANDROID_UA,
        maxConnections: connections,
        // CDN 单次 Range 硬上限 5 MiB（ops 实测）；非 SVIP 按 ops 的 4 MiB。
        maxRangeBytes: vip === 2 ? 5 * MiB : 4 * MiB,
        ...size >= 0 ? { segments: Math.min(connections, Math.max(1, Math.floor(size / (4 * MiB)))) } : {}
      }
    };
  }
  var baidu = {
    id: SITE_ID,
    name: SITE_NAME,
    claims: (url) => readTask(url) !== null,
    async resolve(input) {
      const task = readTask(input.parsed);
      if (!task) throw new SiteError(SITE_NAME, "\u8BC6\u522B\u4EFB\u52A1", "\u4EFB\u52A1\u94FE\u63A5\u53C2\u6570\u4E0D\u6B63\u786E\uFF0C\u8BF7\u4ECE\u5206\u4EAB\u9875\u91CD\u65B0\u53D1\u8D77", "unsupported");
      const bduss = requireLogin(input.cookies);
      const client = new BaiduClient(input.cookies, input.userAgent || BROWSER_UA);
      if (input.resolverItem !== "") return resolveFile(client, bduss, task, input.resolverItem);
      const name = task.name || task.dir.slice(task.dir.lastIndexOf("/") + 1) || "\u767E\u5EA6\u7F51\u76D8\u5206\u4EAB";
      return listManifest(client, task.surl, task.dir, task.pwd, name);
    }
  };

  // src/sites/bilibili/streams.ts
  var CODEC_BY_ID = { 7: "avc", 12: "hevc", 13: "av1" };
  var CODEC_ORDER = {
    avc: ["avc", "hevc", "av1"],
    hevc: ["hevc", "avc", "av1"],
    av1: ["av1", "hevc", "avc"]
  };
  var SDR_RANK = [6, 16, 32, 64, 74, 80, 112, 116, 120, 127];
  var CAP_BY_PREF = {
    best: 127,
    "2160": 120,
    "1080": 116,
    "720": 74,
    "480": 32,
    "360": 16
  };
  var QUALITY_NAMES = {
    127: "8K \u8D85\u9AD8\u6E05",
    126: "\u675C\u6BD4\u89C6\u754C",
    125: "HDR \u771F\u5F69",
    120: "4K \u8D85\u6E05",
    116: "1080P60 \u9AD8\u5E27\u7387",
    112: "1080P+ \u9AD8\u7801\u7387",
    80: "1080P \u9AD8\u6E05",
    74: "720P60 \u9AD8\u5E27\u7387",
    64: "720P \u9AD8\u6E05",
    32: "480P \u6E05\u6670",
    16: "360P \u6D41\u7545",
    6: "240P \u6781\u901F"
  };
  var CODEC_NAMES = { avc: "AVC", hevc: "HEVC", av1: "AV1" };
  function qualityName(id) {
    return QUALITY_NAMES[id] ?? `\u753B\u8D28 ${id}`;
  }
  function codecName(codec) {
    return CODEC_NAMES[codec];
  }
  function sdrRank(id) {
    return SDR_RANK.indexOf(id);
  }
  function sortKey(id) {
    if (id === 125) return SDR_RANK.indexOf(120) + 0.5;
    if (id === 126) return SDR_RANK.indexOf(120) + 0.6;
    const r = sdrRank(id);
    return r >= 0 ? r : -1;
  }
  function urlList(o) {
    const out = [];
    const base = asString(o["baseUrl"]) || asString(o["base_url"]) || asString(o["url"]);
    if (base) out.push(base);
    for (const b of asArray(o["backupUrl"] ?? o["backup_url"])) {
      const u = asString(b);
      if (u && !out.includes(u)) out.push(u);
    }
    return out;
  }
  function codecOf(o) {
    const byId = CODEC_BY_ID[asNumber(o["codecid"]) ?? -1];
    if (byId) return byId;
    const codecs = asString(o["codecs"]).toLowerCase();
    if (codecs.startsWith("avc")) return "avc";
    if (codecs.startsWith("hev") || codecs.startsWith("hvc")) return "hevc";
    if (codecs.startsWith("av01")) return "av1";
    return null;
  }
  function audioOf(o, kind) {
    if (!o) return null;
    const urls = urlList(o);
    const id = asNumber(o["id"]);
    if (urls.length === 0 || id === null) return null;
    return { id, kind, bandwidth: asNumber(o["bandwidth"]) ?? 0, urls };
  }
  function parsePlay(data) {
    const dash = asObject(data["dash"]);
    if (dash) {
      const best = /* @__PURE__ */ new Map();
      for (const item of asArray(dash["video"])) {
        const o = asObject(item);
        if (!o) continue;
        const id = asNumber(o["id"]);
        const codec = codecOf(o);
        const urls = urlList(o);
        if (id === null || codec === null || urls.length === 0) continue;
        const stream = {
          id,
          codec,
          bandwidth: asNumber(o["bandwidth"]) ?? 0,
          width: asNumber(o["width"]) ?? 0,
          height: asNumber(o["height"]) ?? 0,
          urls
        };
        const key = `${id}/${codec}`;
        const prev = best.get(key);
        if (!prev || stream.bandwidth > prev.bandwidth) best.set(key, stream);
      }
      const audios = [];
      for (const item of asArray(dash["audio"])) {
        const a = audioOf(asObject(item), "aac");
        if (a) audios.push(a);
      }
      const flac = audioOf(asObject(asObject(dash["flac"])?.["audio"]), "flac");
      if (flac) audios.push(flac);
      for (const item of asArray(asObject(dash["dolby"])?.["audio"])) {
        const a = audioOf(asObject(item), "dolby");
        if (a) audios.push(a);
      }
      if (best.size > 0) return { kind: "dash", videos: [...best.values()], audios };
    }
    const parts = [];
    for (const item of asArray(data["durl"])) {
      const o = asObject(item);
      if (!o) continue;
      const urls = urlList(o);
      if (urls.length > 0) parts.push({ urls, size: asNumber(o["size"]) ?? 0 });
    }
    if (parts.length > 0) return { kind: "durl", parts, quality: asNumber(data["quality"]) ?? 0 };
    return null;
  }
  function chooseVideo(videos, quality, codec) {
    const cap = CAP_BY_PREF[quality];
    const ids = [...new Set(videos.map((v) => v.id))];
    const sdr = ids.filter((id2) => sdrRank(id2) >= 0).sort((a, b) => sdrRank(a) - sdrRank(b));
    let id;
    if (sdr.length > 0) {
      const within = sdr.filter((x) => x <= cap);
      id = within.length > 0 ? within[within.length - 1] : sdr[0];
    } else {
      id = ids.sort((a, b) => sortKey(a) - sortKey(b))[0];
    }
    return pickCodec(videos.filter((v) => v.id === id), codec);
  }
  function pickCodec(candidates, codec) {
    for (const c of CODEC_ORDER[codec]) {
      const hit = candidates.find((v) => v.codec === c);
      if (hit) return hit;
    }
    return candidates[0];
  }
  function listVideoChoices(videos, codec) {
    const order = CODEC_ORDER[codec];
    return [...videos].sort((a, b) => sortKey(b.id) - sortKey(a.id) || order.indexOf(a.codec) - order.indexOf(b.codec));
  }
  function chooseAudio(audios, pref) {
    const byRate = (a, b) => b.bandwidth - a.bandwidth;
    const aac = audios.filter((a) => a.kind === "aac").sort(byRate);
    if (pref === "best") {
      const flac = audios.find((a) => a.kind === "flac");
      if (flac) return flac;
      const dolby = audios.filter((a) => a.kind === "dolby").sort(byRate)[0];
      if (dolby) return dolby;
    }
    return aac[0] ?? audios.slice().sort(byRate)[0] ?? null;
  }
  function pickStreamUrl(urls) {
    const ok = urls.find((u) => {
      const host = parseUrl(u)?.host ?? "";
      return host !== "" && !/(^|\.)mcdn\.bilivideo\.(cn|com)$/.test(host) && !host.endsWith(".szbdyd.com") && !/^\d+(\.\d+){3}$/.test(host);
    });
    return ok ?? urls[0];
  }

  // src/sites/bilibili/wbi.ts
  var MIXIN_TAB = [
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
    37,
    48,
    7,
    16,
    24,
    55,
    40,
    61,
    26,
    17,
    0,
    1,
    60,
    51,
    30,
    4,
    22,
    25,
    54,
    21,
    56,
    59,
    6,
    63,
    57,
    62,
    11,
    36,
    20,
    34,
    44,
    52
  ];
  function wbiKeyFromUrl(url) {
    const m = /\/([0-9a-f]{32})\.[A-Za-z0-9]+(?:$|\?)/i.exec(url);
    return m ? m[1] : "";
  }
  function mixinKey(imgKey, subKey) {
    const raw = imgKey + subKey;
    if (raw.length < 64) return "";
    return MIXIN_TAB.map((i) => raw[i]).join("").slice(0, 32);
  }
  function signWbi(params, mixin, nowSeconds) {
    const all = { ...params, wts: String(nowSeconds) };
    const query = Object.keys(all).sort().map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(all[k].replace(/[!'()*]/g, ""))}`).join("&");
    return `${query}&w_rid=${md5(query + mixin)}`;
  }

  // src/sites/bilibili/api.ts
  var SITE = "\u54D4\u54E9\u54D4\u54E9";
  var API = "https://api.bilibili.com";
  function hasSession(cookies) {
    return parseCookies(cookies).has("SESSDATA");
  }
  async function get(stage, path, query, auth) {
    const res = await request(SITE, stage, { url: `${API}${path}?${query}`, cookies: auth.cookies, userAgent: auth.userAgent });
    if (res.status === 412 || res.status === 429) return { code: -412, message: "", data: null, risk: true };
    if (res.status < 200 || res.status >= 300) throw new SiteError(SITE, stage, `HTTP ${res.status}`, "network");
    const body = parseJsonObject(SITE, stage, res.body);
    const code = asNumber(body["code"]);
    if (code === null) throw new SiteError(SITE, stage, "\u8FD4\u56DE\u7F3A\u5C11 code \u5B57\u6BB5\uFF08\u7AD9\u70B9\u53EF\u80FD\u6539\u7248\uFF09", "network");
    const data = asObject(body["data"]) ?? asObject(body["result"]);
    const voucher = data !== null && asString(data["v_voucher"]) !== "";
    return { code, message: asString(body["message"]) || asString(body["msg"]), data, risk: voucher || code === -352 || code === -412 };
  }
  var RISK_DETAIL = "\u88AB\u7AD9\u70B9\u98CE\u63A7\u62E6\u622A\uFF08\u8BF7\u5728\u6D4F\u89C8\u5668\u91CC\u6B63\u5E38\u6253\u5F00\u8BE5\u89C6\u9891\u9875\u5E76\u901A\u8FC7\u9A8C\u8BC1\u540E\u91CD\u8BD5\uFF0C\u6216\u7A0D\u540E\u518D\u8BD5\uFF09";
  function mapCode(stage, code, message, session) {
    const text = message ? `${message}\uFF08${code}\uFF09` : `\u63A5\u53E3\u8FD4\u56DE ${code}`;
    const fail2 = (kind, detail) => new SiteError(SITE, stage, detail, kind);
    if (/大会员|会员专享|付费|购买|充电/.test(message)) return fail2("limit", `\u9700\u8981\u5927\u4F1A\u5458\u3001\u4ED8\u8D39\u6216\u5145\u7535\u540E\u624D\u80FD\u89C2\u770B\uFF1A${text}`);
    if (/地区|区域/.test(message)) return fail2("limit", `\u6240\u5728\u5730\u533A\u4E0D\u53EF\u89C2\u770B\uFF1A${text}`);
    switch (code) {
      case -101:
        return fail2("login", "\u672A\u767B\u5F55\u6216\u767B\u5F55\u5DF2\u5931\u6548\uFF0C\u8BF7\u5148\u5728\u6D4F\u89C8\u5668\u91CC\u767B\u5F55\u54D4\u54E9\u54D4\u54E9\uFF0C\u518D\u4ECE\u7F51\u9875\u6309\u94AE\u53D1\u8D77\u4E0B\u8F7D");
      case -404:
      case 62002:
      case 62004:
      case 62003:
        return fail2("notFound", `\u89C6\u9891\u4E0D\u5B58\u5728\u3001\u5DF2\u5220\u9664\u6216\u4E0D\u53EF\u89C1\uFF1A${text}`);
      case 62012:
        return fail2("limit", `\u4EC5 UP \u4E3B\u81EA\u5DF1\u53EF\u89C1\uFF1A${text}`);
      case -403:
        return session ? fail2("limit", `\u8D26\u53F7\u65E0\u6743\u89C2\u770B\uFF1A${text}`) : fail2("login", `\u9700\u8981\u767B\u5F55\u540E\u89C2\u770B\uFF1A${text}`);
      case -10403:
        return fail2("limit", `\u65E0\u6743\u89C2\u770B\uFF08\u53EF\u80FD\u9700\u8981\u5927\u4F1A\u5458\u6216\u6240\u5728\u5730\u533A\u53D7\u9650\uFF09\uFF1A${text}`);
      case -352:
      case -412:
      case -799:
        return fail2("limit", RISK_DETAIL);
      case -400:
        return fail2("other", `\u8BF7\u6C42\u53C2\u6570\u9519\u8BEF\uFF1A${text}`);
      default:
        return fail2("other", text);
    }
  }
  function requireOk(stage, env, session) {
    if (env.code !== 0) throw mapCode(stage, env.code, env.message, session);
    if (env.data === null) throw new SiteError(SITE, stage, "\u8FD4\u56DE\u7F3A\u5C11\u6570\u636E\uFF08\u7AD9\u70B9\u53EF\u80FD\u6539\u7248\uFF09", "network");
    return env.data;
  }
  async function fetchVideo(target, auth) {
    const stage = "\u83B7\u53D6\u89C6\u9891\u4FE1\u606F";
    const data = requireOk(stage, await get(stage, "/x/web-interface/view", `${target.idKey}=${target.id}`, auth), hasSession(auth.cookies));
    const redirectUrl = asString(data["redirect_url"]);
    const pages = [];
    asArray(data["pages"]).forEach((item, i) => {
      const o = asObject(item);
      const cid = o ? asString(o["cid"]) : "";
      if (o && cid) pages.push({ page: asNumber(o["page"]) ?? i + 1, cid, part: asString(o["part"]).trim() });
    });
    if (pages.length === 0 && redirectUrl === "") {
      const cid = asString(data["cid"]);
      if (!cid) throw new SiteError(SITE, stage, "\u89C6\u9891\u6CA1\u6709\u53EF\u4E0B\u8F7D\u7684\u5206 P", "notFound");
      pages.push({ page: 1, cid, part: "" });
    }
    return { bvid: asString(data["bvid"]) || (target.idKey === "bvid" ? target.id : ""), title: asString(data["title"]).trim(), pages, redirectUrl };
  }
  async function fetchSeason(target, auth) {
    const stage = "\u83B7\u53D6\u756A\u5267\u4FE1\u606F";
    const query = target.kind === "episode" ? `ep_id=${target.id}` : `season_id=${target.id}`;
    const data = requireOk(stage, await get(stage, "/pgc/view/web/season", query, auth), hasSession(auth.cookies));
    const episodes = [];
    for (const item of asArray(data["episodes"])) {
      const o = asObject(item);
      const id = o ? asString(o["id"]) || asString(o["ep_id"]) : "";
      const cid = o ? asString(o["cid"]) : "";
      if (o && id && cid) episodes.push({ id, cid, title: asString(o["title"]).trim(), longTitle: asString(o["long_title"]).trim() });
    }
    return { title: (asString(data["title"]) || asString(data["season_title"])).trim(), episodes };
  }
  var PLAY_PARAMS = { qn: "127", fnval: "4048", fourk: "1" };
  function playParams(base, auth) {
    return { ...base, ...PLAY_PARAMS, ...hasSession(auth.cookies) ? {} : { try_look: "1" } };
  }
  function toQuery(params) {
    return Object.entries(params).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
  }
  function playOf(stage, data, session) {
    const info = asObject(data["video_info"]) ?? data;
    if (asNumber(data["is_preview"]) === 1 || asNumber(info["is_preview"]) === 1) {
      throw new SiteError(SITE, stage, session ? "\u8BE5\u5185\u5BB9\u9700\u8981\u5927\u4F1A\u5458\u6216\u4ED8\u8D39\uFF0C\u5F53\u524D\u8D26\u53F7\u53EA\u80FD\u8BD5\u770B" : "\u8BE5\u5185\u5BB9\u9700\u8981\u767B\u5F55\u5E76\u5F00\u901A\u5927\u4F1A\u5458\uFF0C\u533F\u540D\u53EA\u80FD\u8BD5\u770B", session ? "limit" : "login");
    }
    const play = parsePlay(info);
    if (!play) throw new SiteError(SITE, stage, "\u6CA1\u6709\u53EF\u7528\u7684\u89C6\u9891\u6D41\uFF08\u7AD9\u70B9\u53EF\u80FD\u6539\u7248\uFF09", "network");
    return play;
  }
  async function fetchUgcPlay(bvid, cid, auth) {
    const stage = "\u83B7\u53D6\u89C6\u9891\u6D41";
    const session = hasSession(auth.cookies);
    const params = playParams({ bvid, cid }, auth);
    let env = await get(stage, "/x/player/playurl", toQuery(params), auth);
    if (env.risk) env = await getSigned(stage, "/x/player/wbi/playurl", params, auth);
    if (env.risk) throw new SiteError(SITE, stage, RISK_DETAIL, "limit");
    return playOf(stage, requireOk(stage, env, session), session);
  }
  async function getSigned(stage, path, params, auth) {
    const nav = await get(stage, "/x/web-interface/nav", "", auth);
    const wbi = nav.data ? asObject(nav.data["wbi_img"]) : null;
    const mixin = wbi ? mixinKey(wbiKeyFromUrl(asString(wbi["img_url"])), wbiKeyFromUrl(asString(wbi["sub_url"]))) : "";
    if (mixin === "") throw new SiteError(SITE, stage, "\u53D6\u4E0D\u5230 WBI \u7B7E\u540D\u5BC6\u94A5\uFF08\u7AD9\u70B9\u53EF\u80FD\u6539\u7248\uFF09", "network");
    return get(stage, path, signWbi(params, mixin, Math.floor(Date.now() / 1e3)), auth);
  }
  async function fetchPgcPlay(epId, cid, auth) {
    const stage = "\u83B7\u53D6\u89C6\u9891\u6D41";
    const session = hasSession(auth.cookies);
    const env = await get(stage, "/pgc/player/web/playurl", toQuery(playParams({ ep_id: epId, cid }, auth)), auth);
    if (env.risk) throw new SiteError(SITE, stage, RISK_DETAIL, "limit");
    return playOf(stage, requireOk(stage, env, session), session);
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

  // src/sites/bilibili/index.ts
  var REFERER = "https://www.bilibili.com/";
  var DEFAULT_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";
  var MAX_VARIANTS = 50;
  function oneOf(value, allowed, fallback) {
    return allowed.find((a) => a === value) ?? fallback;
  }
  function readPrefs() {
    const s = flux.settings;
    return {
      quality: oneOf(s["bilibiliQuality"], ["best", "ask", "2160", "1080", "720", "480", "360"], "best"),
      codec: oneOf(s["bilibiliCodec"], ["avc", "hevc", "av1"], "avc"),
      audio: oneOf(s["bilibiliAudio"], ["standard", "best"], "standard")
    };
  }
  function pageName(title, page, part, multi) {
    if (!multi) return title || "\u54D4\u54E9\u54D4\u54E9\u89C6\u9891";
    const own = (title ? part.split(title).join("") : part).trim();
    const suffix = own ? `P${page} ${own}` : `P${page}`;
    return title ? `${title} - ${suffix}` : suffix;
  }
  function episodeName(seasonTitle, ep) {
    const label = /^\d+(\.\d+)?$/.test(ep.title) ? `\u7B2C${ep.title}\u8BDD` : ep.title;
    const long = ep.longTitle && ep.longTitle !== ep.title ? ep.longTitle : "";
    const tail = [label, long].filter((s) => s !== "").join(" ");
    return [seasonTitle, tail].filter((s) => s !== "").join(" - ") || "\u54D4\u54E9\u54D4\u54E9\u89C6\u9891";
  }
  function downloadPatch(auth) {
    return { cookies: "", referrer: REFERER, userAgent: auth.userAgent };
  }
  function variantLabel(v) {
    const rate = v.bandwidth > 0 ? ` \xB7 ${(v.bandwidth / 1e6).toFixed(1)} Mbps` : "";
    return `${qualityName(v.id)} \xB7 ${codecName(v.codec)}${rate}`;
  }
  function dashResult(play, name, prefs, auth) {
    const fileName = safeFileName(`${name}.mp4`);
    const audio = chooseAudio(play.audios, prefs.audio);
    const audioUrl = audio ? pickStreamUrl(audio.urls) : void 0;
    const mainQuality = prefs.quality === "ask" ? "best" : prefs.quality;
    const video = chooseVideo(play.videos, mainQuality, prefs.codec);
    const result = {
      url: pickStreamUrl(video.urls),
      ...audioUrl ? { audioUrl } : {},
      fileName,
      request: downloadPatch(auth)
    };
    if (prefs.quality !== "ask") return result;
    const choices = listVideoChoices(play.videos, prefs.codec).slice(0, MAX_VARIANTS);
    const variants = choices.map((v) => ({
      label: variantLabel(v),
      url: pickStreamUrl(v.urls),
      ...audioUrl ? { audioUrl } : {},
      fileName,
      bandwidth: Math.round(v.bandwidth),
      width: Math.round(v.width),
      height: Math.round(v.height),
      container: "mp4"
    }));
    const preferred = choices.findIndex((v) => v === video);
    return { ...result, variants, defaultVariantIndex: preferred >= 0 ? preferred : 0 };
  }
  function durlResult(play, name, input, auth, canSplit) {
    const extOf2 = (url) => (/\.(mp4|flv)(?:$|\?)/i.exec(url)?.[1] ?? "mp4").toLowerCase();
    const segment = /^s(\d+)$/.exec(input.resolverItem);
    if (play.parts.length === 1 || segment) {
      const index = segment ? Number(segment[1]) - 1 : 0;
      const part = play.parts[index];
      if (!part) throw new SiteError(SITE, "\u83B7\u53D6\u89C6\u9891\u6D41", `\u6CA1\u6709\u7B2C ${index + 1} \u6BB5\uFF08\u5171 ${play.parts.length} \u6BB5\uFF09`, "notFound");
      const url = pickStreamUrl(part.urls);
      const label = play.parts.length > 1 ? ` - \u7247\u6BB5${index + 1}` : "";
      return { url, fileName: safeFileName(`${name}${label}.${extOf2(url)}`), request: downloadPatch(auth) };
    }
    if (!canSplit) {
      throw new SiteError(SITE, "\u83B7\u53D6\u89C6\u9891\u6D41", "\u8BE5\u5185\u5BB9\u53EA\u6709\u5206\u6BB5 FLV \u6D41\uFF0C\u8BF7\u5355\u72EC\u6253\u5F00\u5B83\u81EA\u5DF1\u7684\u9875\u9762\u4E0B\u8F7D", "unsupported");
    }
    return manifestResult(
      SITE,
      name,
      play.parts.map((part, i) => ({ id: `s${i + 1}`, name: `${name} - \u7247\u6BB5${i + 1}.${extOf2(part.urls[0])}`, size: part.size }))
    );
  }
  function playResult(play, name, input, auth, prefs, canSplit) {
    return play.kind === "dash" ? dashResult(play, name, prefs, auth) : durlResult(play, name, input, auth, canSplit);
  }
  async function resolveVideo(target, input, auth, prefs) {
    const info = await fetchVideo(target, auth);
    if (info.redirectUrl) {
      const redirected = parseUrl(info.redirectUrl);
      const next = redirected ? parseBilibiliLink(redirected) : null;
      if (next && next.kind !== "video") return resolveBangumi(next, input, auth, prefs);
      throw new SiteError(SITE, "\u83B7\u53D6\u89C6\u9891\u4FE1\u606F", "\u8BE5\u7A3F\u4EF6\u4E0D\u662F\u666E\u901A\u89C6\u9891\uFF0C\u6682\u4E0D\u652F\u6301", "unsupported");
    }
    const multi = info.pages.length > 1;
    const itemPage = /^p(\d+)$/.exec(input.resolverItem);
    const wanted = itemPage ? Number(itemPage[1]) : target.page;
    if (wanted === null && multi) {
      return manifestResult(
        SITE,
        info.title || "\u54D4\u54E9\u54D4\u54E9\u89C6\u9891",
        info.pages.map((p) => ({ id: `p${p.page}`, name: `${pageName(info.title, p.page, p.part, true)}.mp4` }))
      );
    }
    const page = info.pages.find((p) => p.page === (wanted ?? 1));
    if (!page) throw new SiteError(SITE, "\u83B7\u53D6\u89C6\u9891\u4FE1\u606F", `\u6CA1\u6709\u7B2C ${wanted} P\uFF08\u5171 ${info.pages.length} P\uFF09`, "notFound");
    if (info.bvid === "") throw new SiteError(SITE, "\u83B7\u53D6\u89C6\u9891\u4FE1\u606F", "\u8FD4\u56DE\u7F3A\u5C11 BV \u53F7\uFF08\u7AD9\u70B9\u53EF\u80FD\u6539\u7248\uFF09", "network");
    const play = await fetchUgcPlay(info.bvid, page.cid, auth);
    return playResult(play, pageName(info.title, page.page, page.part, multi), input, auth, prefs, !itemPage);
  }
  async function resolveBangumi(target, input, auth, prefs) {
    const itemEp = target.kind === "season" ? /^e(\d{1,12})$/.exec(input.resolverItem) : null;
    const effective = itemEp ? { kind: "episode", id: itemEp[1] } : target;
    const season = await fetchSeason(effective, auth);
    if (effective.kind === "season") {
      if (season.episodes.length > MAX_ITEMS) {
        throw new SiteError(SITE, "\u83B7\u53D6\u756A\u5267\u4FE1\u606F", `\u5171 ${season.episodes.length} \u96C6\uFF0C\u8D85\u8FC7\u5355\u6B21 ${MAX_ITEMS} \u96C6\u4E0A\u9650\uFF0C\u8BF7\u4ECE\u7F51\u9875\u6253\u5F00\u5177\u4F53\u5267\u96C6\u4E0B\u8F7D`, "limit");
      }
      return manifestResult(
        SITE,
        season.title || "\u54D4\u54E9\u54D4\u54E9\u756A\u5267",
        season.episodes.map((ep2) => ({ id: `e${ep2.id}`, name: `${episodeName("", ep2)}.mp4` }))
      );
    }
    const ep = season.episodes.find((e) => e.id === effective.id);
    if (!ep) throw new SiteError(SITE, "\u83B7\u53D6\u756A\u5267\u4FE1\u606F", "\u6CA1\u6709\u627E\u5230\u8FD9\u4E00\u96C6\uFF08\u53EF\u80FD\u5DF2\u4E0B\u67B6\uFF09", "notFound");
    const play = await fetchPgcPlay(ep.id, ep.cid, auth);
    return playResult(play, episodeName(season.title, ep), input, auth, prefs, !itemEp);
  }
  var bilibili = {
    id: "bilibili",
    name: SITE,
    claims: (url) => parseBilibiliLink(url) !== null,
    async resolve(input) {
      const target = parseBilibiliLink(input.parsed);
      if (!target) throw new SiteError(SITE, "\u8BC6\u522B\u94FE\u63A5", "\u4E0D\u662F\u53D7\u652F\u6301\u7684\u54D4\u54E9\u54D4\u54E9\u89C6\u9891\u6216\u756A\u5267\u94FE\u63A5", "unsupported");
      const auth = { cookies: input.cookies, userAgent: input.userAgent || DEFAULT_UA };
      const prefs = readPrefs();
      return target.kind === "video" ? resolveVideo(target, input, auth, prefs) : resolveBangumi(target, input, auth, prefs);
    }
  };

  // src/sites/lanzou/acw.ts
  var POSITIONS = [
    6,
    28,
    34,
    31,
    33,
    18,
    30,
    23,
    9,
    8,
    19,
    38,
    17,
    24,
    0,
    5,
    32,
    21,
    10,
    22,
    25,
    14,
    15,
    3,
    16,
    27,
    13,
    35,
    2,
    29,
    11,
    26,
    4,
    36,
    1,
    39,
    37,
    7,
    20,
    12
  ];
  var MASK = "3000176000856006061501533003690027800375";
  var ARG1_RE = /\barg1\s*=\s*['"]([0-9A-Fa-f]{40})['"]/;
  function findChallenge(body) {
    return ARG1_RE.exec(body)?.[1] ?? null;
  }
  function calcAcwScV2(arg1) {
    if (!/^[0-9A-Fa-f]{40}$/.test(arg1)) throw new Error("arg1 \u5FC5\u987B\u662F 40 \u4F4D\u5341\u516D\u8FDB\u5236");
    const shuffled = new Array(40).fill("");
    POSITIONS.forEach((to, from) => {
      shuffled[to] = arg1[from];
    });
    const mixed = shuffled.join("");
    let out = "";
    for (let i = 0; i < 40; i += 2) {
      const x = parseInt(mixed.slice(i, i + 2), 16) ^ parseInt(MASK.slice(i, i + 2), 16);
      out += x.toString(16).padStart(2, "0");
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
  function shareUrl(host, id, pwd = "") {
    return `https://${host}/${id}${pwd ? `?pwd=${encodeURIComponent(pwd)}` : ""}`;
  }

  // src/sites/lanzou/parse.ts
  function stripComments(src) {
    return src.replace(/<!--[\s\S]*?-->/g, "\n").replace(/\/\*[\s\S]*?\*\//g, "\n").split("\n").filter((line) => !line.trimStart().startsWith("//")).join("\n");
  }
  function decodeEntities(s) {
    return s.replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&");
  }
  function escapeRegExp(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }
  function jsVar(src, name) {
    const re = new RegExp(`\\bvar\\s+${escapeRegExp(name)}\\s*=\\s*(?:'([^']*)'|"([^"]*)"|(-?\\d+(?:\\.\\d+)?))`, "g");
    let last = null;
    for (const m of src.matchAll(re)) {
      const value = m[1] ?? m[2] ?? m[3] ?? "";
      if (value !== "" || last === null) last = value;
    }
    return last;
  }
  var PAIR_RE = /['"]([^'"]+)['"]\s*:\s*(?:'([^']*)'|"([^"]*)"|([A-Za-z_$][\w$]*|-?\d+(?:\.\d+)?))/g;
  function parseDataBlock(src, startAt, contains, resolveIdent) {
    const blocks = /\bdata\s*:\s*\{([^}]*)\}/g;
    blocks.lastIndex = startAt;
    for (let m = blocks.exec(src); m; m = blocks.exec(src)) {
      if (!m[1].includes(contains)) continue;
      const form = {};
      for (const p of m[1].matchAll(PAIR_RE)) {
        const key = p[1];
        if (p[4] !== void 0 && !/^-?\d/.test(p[4])) {
          const value = resolveIdent(key, p[4]);
          if (value === null) return null;
          form[key] = value;
        } else {
          form[key] = p[2] ?? p[3] ?? p[4] ?? "";
        }
      }
      return form;
    }
    return null;
  }
  function absolute(origin, path) {
    if (/^https?:\/\//i.test(path)) return path;
    return `${origin}${path.startsWith("/") ? "" : "/"}${path}`;
  }
  function parseDownprocess(src, origin, pwd) {
    const form = parseDataBlock(src, 0, "downprocess", (key, ident) => {
      if (key === "p" || ident === "pwd") return pwd;
      if (key === "kd") return "1";
      return jsVar(src, ident);
    });
    if (!form || !form.sign) return null;
    const domain1 = jsVar(src, "domain1");
    const direct = domain1 !== null && /ajax(?:m|file)\.php\?file=\d+/.test(domain1) ? domain1 : null;
    const found = /['"]((?:https?:\/\/[^'"\s]+)?\/?ajax(?:m|file)\.php\?file=\d+)['"]/.exec(src)?.[1];
    const path = direct ?? found;
    return path ? { url: absolute(origin, path), form } : null;
  }
  function parseFolderCall(src, origin, pwd) {
    const ajax2 = /['"]((?:https?:\/\/[^'"\s]+)?\/?filemoreajax\.php[^'"]*)['"]/.exec(src);
    if (!ajax2) return null;
    const path = ajax2[1];
    const form = parseDataBlock(src, ajax2.index, "'lx'", (key, ident) => {
      if (key === "pg") return "1";
      if (ident === "pwd") return pwd;
      return jsVar(src, ident);
    });
    if (!form) return null;
    return { url: absolute(origin, path), form, locked: /id=["']pwdload["']/.test(src) };
  }
  function findIframePath(src) {
    const m = /<iframe\b[^>]*\bsrc=["'](\/[^"']+)["']/i.exec(src);
    return m ? decodeEntities(m[1]) : null;
  }
  function pageTitle(src) {
    const m = /<title>([^<]*)<\/title>/i.exec(src);
    return m ? decodeEntities(m[1]).replace(/\s*-\s*蓝奏云\s*$/, "").trim() : "";
  }
  function pageFileName(src) {
    const title = pageTitle(src);
    if (title !== "") return title;
    const m = /id=["']filenajax["'][^>]*>([^<]+)</.exec(src) ?? /<div style="font-size: ?30px;[^"]*">([^<]+)<\/div>/.exec(src);
    return m ? decodeEntities(m[1]).trim() : "";
  }
  function isGone(src) {
    return src.includes("\u53D6\u6D88\u5206\u4EAB") || src.includes("\u6587\u4EF6\u4E0D\u5B58\u5728");
  }
  function isPasswordFilePage(src) {
    return /function\s+down_p\s*\(/.test(src) || /id=["']passwddiv["']/.test(src);
  }
  function hasSubfolders(src) {
    return /\b(?:mbxfolder|folderlink)\b/.test(src);
  }
  function parseSize(text) {
    const m = /^\s*([0-9]+(?:\.[0-9]+)?)\s*([BKMG])/i.exec(text);
    if (!m) return void 0;
    const unit = { B: 1, K: 1024, M: 1024 ** 2, G: 1024 ** 3 }[m[2].toUpperCase()];
    return Math.round(Number(m[1]) * unit);
  }

  // src/sites/lanzou/index.ts
  var SITE_NAME2 = "\u84DD\u594F\u4E91";
  var ACCEPT_LANGUAGE = "zh-CN,zh;q=0.9";
  var DEFAULT_UA2 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";
  var PAGE_SIZE2 = 50;
  var MAX_PAGES = Math.ceil(MAX_ITEMS / PAGE_SIZE2) + 1;
  var ITEM_ID_RE = /^[A-Za-z0-9]{5,32}$/;
  var MAX_CHALLENGES = 3;
  var Session = class {
    constructor(userAgent) {
      this.userAgent = userAgent;
    }
    userAgent;
    acw = "";
    /** 当前应答 Cookie（可能为 ""）。 */
    get acwValue() {
      return this.acw;
    }
    /** 按挑战页的 arg1 算出并记住 Cookie。 */
    answer(arg1) {
      this.acw = calcAcwScV2(arg1);
    }
    async send(stage, req) {
      for (let attempt = 0; ; attempt++) {
        const res = await request(SITE_NAME2, stage, {
          ...req,
          headers: { "Accept-Language": ACCEPT_LANGUAGE, ...req.headers ?? {} },
          cookies: this.acw ? `acw_sc__v2=${this.acw}` : "",
          userAgent: this.userAgent
        });
        const arg1 = findChallenge(res.body);
        if (arg1 === null) {
          if (res.status < 200 || res.status >= 300) throw new SiteError(SITE_NAME2, stage, `HTTP ${res.status}`, "network");
          return res;
        }
        if (attempt + 1 >= MAX_CHALLENGES) throw new SiteError(SITE_NAME2, stage, "\u53CD\u722C\u9A8C\u8BC1\uFF08acw_sc__v2\uFF09\u672A\u901A\u8FC7", "limit");
        this.answer(arg1);
      }
    }
    /** 读 HTML 页面（去注释）。 */
    async page(stage, url, referer) {
      const res = await this.send(stage, { url, referer });
      return stripComments(res.body);
    }
    async postJson(stage, url, form, referer) {
      const res = await this.send(stage, {
        method: "POST",
        url,
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: formBody(form),
        referer
      });
      return parseJsonObject(SITE_NAME2, stage, res.body);
    }
  };
  function failure(stage, info) {
    const text = info.trim();
    if (/密码|提取码/.test(text)) return new SiteError(SITE_NAME2, stage, text, "password");
    if (/取消分享|不存在|已删除|已失效/.test(text)) return new SiteError(SITE_NAME2, stage, text, "notFound");
    if (/频繁|限制|次数|稍后/.test(text)) return new SiteError(SITE_NAME2, stage, text, "limit");
    return new SiteError(SITE_NAME2, stage, text || "\u7AD9\u70B9\u8FD4\u56DE\u5931\u8D25", "network");
  }
  var NEED_PASSWORD = "\u8BE5\u5206\u4EAB\u9700\u8981\u63D0\u53D6\u7801\uFF1A\u5728\u5206\u4EAB\u9875\u8F93\u5165\u63D0\u53D6\u7801\u540E\u518D\u70B9\u4E0B\u8F7D\u6309\u94AE\uFF0C\u6216\u5728\u94FE\u63A5\u540E\u52A0 ?pwd=\u63D0\u53D6\u7801";
  function pageChanged(stage) {
    return new SiteError(SITE_NAME2, stage, "\u6CA1\u6709\u627E\u5230\u9875\u9762\u91CC\u7684\u4E0B\u8F7D\u53C2\u6570\uFF08\u84DD\u594F\u4E91\u53EF\u80FD\u6539\u7248\uFF09", "network");
  }
  async function probeDirect(session, dom, url) {
    const stage = "\u6821\u9A8C\u76F4\u94FE";
    for (let attempt = 0; ; attempt++) {
      const cookies = session.acwValue ? `down_ip=1; acw_sc__v2=${session.acwValue}` : "down_ip=1";
      let res;
      try {
        res = await flux.fetch({
          url,
          headers: {
            "Accept-Language": ACCEPT_LANGUAGE,
            Range: "bytes=0-0",
            Cookie: cookies,
            "User-Agent": session.userAgent,
            Referer: dom
          }
        });
      } catch (e) {
        throw new SiteError(SITE_NAME2, stage, `\u7F51\u7EDC\u8BF7\u6C42\u5931\u8D25\uFF08${e instanceof Error ? e.message : String(e)}\uFF09`, "network");
      }
      const type = res.headers["content-type"] ?? "";
      if (/text\/html/i.test(type)) {
        const arg1 = findChallenge(res.body);
        if (arg1 !== null && attempt + 1 < MAX_CHALLENGES) {
          session.answer(arg1);
          continue;
        }
        throw new SiteError(SITE_NAME2, stage, "\u84DD\u594F\u4E91\u8981\u6C42\u4E0B\u8F7D\u524D\u9A8C\u8BC1\uFF08\u7F51\u7EDC\u5F02\u5E38\uFF09\uFF0C\u8BF7\u7A0D\u540E\u91CD\u8BD5\u6216\u5148\u5728\u6D4F\u89C8\u5668\u91CC\u4E0B\u8F7D\u4E00\u6B21", "limit");
      }
      if (res.status < 200 || res.status >= 300) throw new SiteError(SITE_NAME2, stage, `\u76F4\u94FE HTTP ${res.status}`, "network");
      const range = /\/(\d+)\s*$/.exec(res.headers["content-range"] ?? "");
      const length = res.status === 200 && !res.truncated ? asNumber(res.headers["content-length"]) : null;
      const totalBytes = range ? Number(range[1]) : length !== null && length > 0 ? length : void 0;
      return { cookies, ...totalBytes !== void 0 ? { totalBytes } : {} };
    }
  }
  async function directResult(session, stage, json, name) {
    const zt = asNumber(json.zt);
    if (zt !== 1) {
      const info = typeof json.inf === "string" ? json.inf : "";
      throw zt === 4 ? new SiteError(SITE_NAME2, stage, info || "\u8BF7\u6C42\u8FC7\u4E8E\u9891\u7E41\uFF0C\u8BF7\u7A0D\u540E\u91CD\u8BD5", "limit") : failure(stage, info);
    }
    const dom = asString(json.dom).replace(/\/+$/, "");
    const token = asString(json.url);
    if (!/^https?:\/\//i.test(dom) || token === "") throw new SiteError(SITE_NAME2, stage, "\u4E0B\u8F7D\u63A5\u53E3\u6CA1\u6709\u8FD4\u56DE\u76F4\u94FE", "network");
    const url = `${dom}/file/${token}`;
    const { cookies, totalBytes } = await probeDirect(session, dom, url);
    const fileName = name === "" ? "" : safeFileName(name);
    return {
      url,
      ...fileName ? { fileName } : {},
      ...totalBytes !== void 0 ? { totalBytes } : {},
      request: { cookies, referrer: dom, setHeaders: { "Accept-Language": ACCEPT_LANGUAGE } }
    };
  }
  async function fileFromPage(session, link, pageUrl, page, pwd) {
    const origin = `https://${link.host}`;
    if (isGone(page)) throw new SiteError(SITE_NAME2, "\u8BFB\u53D6\u5206\u4EAB\u9875", "\u5206\u4EAB\u5DF2\u53D6\u6D88\u6216\u6587\u4EF6\u4E0D\u5B58\u5728", "notFound");
    if (isPasswordFilePage(page)) {
      if (pwd === "") throw new SiteError(SITE_NAME2, "\u8BFB\u53D6\u5206\u4EAB\u9875", NEED_PASSWORD, "password");
      const call2 = parseDownprocess(page, origin, pwd);
      if (!call2) throw pageChanged("\u8BFB\u53D6\u5206\u4EAB\u9875");
      const json2 = await session.postJson("\u83B7\u53D6\u76F4\u94FE", call2.url, call2.form, pageUrl);
      return directResult(session, "\u83B7\u53D6\u76F4\u94FE", json2, typeof json2.inf === "string" ? json2.inf : "");
    }
    const iframe = findIframePath(page);
    if (!iframe) throw pageChanged("\u8BFB\u53D6\u5206\u4EAB\u9875");
    const innerUrl = `${origin}${iframe}`;
    const inner = await session.page("\u8BFB\u53D6\u4E0B\u8F7D\u9875", innerUrl, pageUrl);
    const call = parseDownprocess(inner, origin, "");
    if (!call) throw pageChanged("\u8BFB\u53D6\u4E0B\u8F7D\u9875");
    const json = await session.postJson("\u83B7\u53D6\u76F4\u94FE", call.url, call.form, innerUrl);
    return directResult(session, "\u83B7\u53D6\u76F4\u94FE", json, pageFileName(page));
  }
  async function resolveFile2(session, link, id, referer) {
    const pageUrl = shareUrl(link.host, id);
    const page = await session.page("\u8BFB\u53D6\u5206\u4EAB\u9875", pageUrl, referer);
    return fileFromPage(session, link, pageUrl, page, link.pwd);
  }
  async function resolveFolder(session, link, pageUrl, page) {
    if (isGone(page)) throw new SiteError(SITE_NAME2, "\u8BFB\u53D6\u5206\u4EAB\u9875", "\u5206\u4EAB\u5DF2\u53D6\u6D88\u6216\u6587\u4EF6\u4E0D\u5B58\u5728", "notFound");
    const stage = "\u8BFB\u53D6\u6587\u4EF6\u5939";
    const call = parseFolderCall(page, `https://${link.host}`, link.pwd);
    if (!call) throw pageChanged(stage);
    if (call.locked && link.pwd === "") throw new SiteError(SITE_NAME2, stage, NEED_PASSWORD, "password");
    if (hasSubfolders(page)) {
      throw new SiteError(SITE_NAME2, stage, "\u8BE5\u6587\u4EF6\u5939\u542B\u5B50\u6587\u4EF6\u5939\uFF08\u4F1A\u5458\u5206\u4EAB\uFF09\uFF0C\u6682\u4E0D\u652F\u6301\u5C55\u5F00\uFF1B\u8BF7\u5206\u522B\u6253\u5F00\u5B50\u6587\u4EF6\u5939\u94FE\u63A5\u4E0B\u8F7D", "unsupported");
    }
    const files = [];
    for (let pg = 1; pg <= MAX_PAGES; pg++) {
      const json = await session.postJson(stage, call.url, { ...call.form, pg: String(pg) }, pageUrl);
      const zt = asNumber(json.zt);
      const info = typeof json.info === "string" ? json.info : "";
      if (zt === 2) break;
      if (zt === 3) throw new SiteError(SITE_NAME2, stage, info || "\u63D0\u53D6\u7801\u9519\u8BEF", "password");
      if (zt !== 1) throw failure(stage, info);
      const rows = asArray(json.text);
      for (const row of rows) {
        const o = asObject(row);
        const id = o ? asString(o.id) : "";
        if (!o || asNumber(o.t) === 1 || !ITEM_ID_RE.test(id)) continue;
        const size = parseSize(asString(o.size));
        files.push({ id, name: decodeEntities(asString(o.name_all)), ...size !== void 0 ? { size } : {} });
      }
      if (rows.length < PAGE_SIZE2) break;
      if (pg === MAX_PAGES) {
        throw new SiteError(SITE_NAME2, stage, `\u6587\u4EF6\u5939\u5185\u6587\u4EF6\u8D85\u8FC7 ${MAX_ITEMS} \u4E2A\uFF0C\u65E0\u6CD5\u4E00\u6B21\u5217\u51FA`, "limit");
      }
    }
    if (files.length > MAX_ITEMS) throw new SiteError(SITE_NAME2, stage, `\u6587\u4EF6\u5939\u5185\u6587\u4EF6\u8D85\u8FC7 ${MAX_ITEMS} \u4E2A\uFF0C\u65E0\u6CD5\u4E00\u6B21\u5217\u51FA`, "limit");
    const name = pageTitle(page) || link.id;
    return manifestResult(SITE_NAME2, name, files);
  }
  async function resolveShare(input, link) {
    const session = new Session(input.userAgent || DEFAULT_UA2);
    const pageUrl = shareUrl(link.host, link.id);
    if (input.resolverItem !== "") {
      if (!ITEM_ID_RE.test(input.resolverItem)) throw new SiteError(SITE_NAME2, "\u8BC6\u522B\u6761\u76EE", "\u6E05\u5355\u6761\u76EE\u6807\u8BC6\u65E0\u6548", "unsupported");
      return resolveFile2(session, link, input.resolverItem, pageUrl);
    }
    const page = await session.page("\u8BFB\u53D6\u5206\u4EAB\u9875", pageUrl);
    if (page.includes("filemoreajax.php")) return resolveFolder(session, link, pageUrl, page);
    return fileFromPage(session, link, pageUrl, page, link.pwd);
  }
  var lanzou = {
    id: "lanzou",
    name: SITE_NAME2,
    claims: (url) => parseShareLink(url) !== null,
    async resolve(input) {
      const link = parseShareLink(input.parsed);
      if (!link) throw new SiteError(SITE_NAME2, "\u8BC6\u522B\u94FE\u63A5", "\u4E0D\u662F\u84DD\u594F\u4E91\u5206\u4EAB\u94FE\u63A5", "unsupported");
      return resolveShare(input, link);
    }
  };

  // src/sites/pan115/m115.ts
  var MODULUS = BigInt(
    "0x8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b8602136477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad6338c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f10a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683"
  );
  var EXPONENT = 0x10001n;
  var BLOCK = 128;
  var BLOCK_PAYLOAD = BLOCK - 11;
  var XOR_SEED = Uint8Array.from([
    240,
    229,
    105,
    174,
    191,
    220,
    191,
    138,
    26,
    69,
    232,
    190,
    125,
    166,
    115,
    184,
    222,
    143,
    231,
    196,
    69,
    218,
    134,
    196,
    155,
    100,
    139,
    20,
    106,
    180,
    241,
    170,
    56,
    1,
    53,
    158,
    38,
    105,
    44,
    134,
    0,
    107,
    79,
    165,
    54,
    52,
    98,
    166,
    42,
    150,
    104,
    24,
    242,
    74,
    253,
    189,
    107,
    151,
    143,
    77,
    143,
    137,
    19,
    183,
    108,
    142,
    147,
    237,
    14,
    13,
    72,
    62,
    215,
    47,
    136,
    216,
    254,
    254,
    126,
    134,
    80,
    149,
    79,
    209,
    235,
    131,
    38,
    52,
    219,
    102,
    123,
    156,
    126,
    157,
    122,
    129,
    50,
    234,
    182,
    51,
    222,
    58,
    169,
    89,
    52,
    102,
    59,
    170,
    186,
    129,
    96,
    72,
    185,
    213,
    129,
    156,
    248,
    108,
    132,
    119,
    255,
    84,
    120,
    38,
    95,
    190,
    232,
    30,
    54,
    159,
    52,
    128,
    92,
    69,
    44,
    155,
    118,
    213,
    27,
    143,
    204,
    195,
    184,
    245
  ]);
  var XOR_CLIENT_KEY = Uint8Array.from([120, 6, 173, 76, 51, 134, 93, 24, 76, 1, 63, 70]);
  var KEY_SIZE = 16;
  function deriveKey(seed, size) {
    const key = new Uint8Array(size);
    for (let i = 0; i < size; i++) {
      key[i] = seed[i] + XOR_SEED[size * i] & 255 ^ XOR_SEED[size * (size - i - 1)];
    }
    return key;
  }
  function xorTransform(data, key) {
    const mod = data.length % 4;
    for (let i = 0; i < mod; i++) data[i] = data[i] ^ key[i % key.length];
    for (let i = mod; i < data.length; i++) data[i] = data[i] ^ key[(i - mod) % key.length];
  }
  function bytesToBigInt(bytes) {
    let n = 0n;
    for (const b of bytes) n = n << 8n | BigInt(b);
    return n;
  }
  function bigIntToBytes(n, length) {
    const out = new Uint8Array(length);
    for (let i = length - 1; i >= 0 && n > 0n; i--) {
      out[i] = Number(n & 0xffn);
      n >>= 8n;
    }
    return out;
  }
  function modPowPublic(base) {
    let result = 1n;
    let b = base % MODULUS;
    let e = EXPONENT;
    while (e > 0n) {
      if (e & 1n) result = result * b % MODULUS;
      b = b * b % MODULUS;
      e >>= 1n;
    }
    return result;
  }
  function rsaEncrypt(input, pad) {
    const blocks = [];
    for (let off = 0; off < input.length; off += BLOCK_PAYLOAD) {
      const slice = input.subarray(off, Math.min(off + BLOCK_PAYLOAD, input.length));
      const padSize = BLOCK - slice.length - 3;
      const msg = new Uint8Array(BLOCK);
      msg[1] = 2;
      for (let i = 0; i < padSize; i++) msg[2 + i] = pad(i) % 255 + 1;
      msg.set(slice, padSize + 3);
      blocks.push(bigIntToBytes(modPowPublic(bytesToBigInt(msg)), BLOCK));
    }
    const out = new Uint8Array(blocks.length * BLOCK);
    blocks.forEach((b, i) => out.set(b, i * BLOCK));
    return out;
  }
  function rsaDecrypt(input) {
    const parts = [];
    for (let off = 0; off < input.length; off += BLOCK) {
      const block = input.subarray(off, Math.min(off + BLOCK, input.length));
      const raw = bigIntToBytes(modPowPublic(bytesToBigInt(block)), BLOCK);
      let start = 0;
      while (start < raw.length && raw[start] === 0) start++;
      const zero = raw.indexOf(0, start + 1);
      if (zero < 0) throw new Error("m115 \u89E3\u5BC6\u5931\u8D25\uFF1A\u586B\u5145\u4E0D\u5408\u6CD5");
      parts.push(raw.subarray(zero + 1));
    }
    const total = parts.reduce((n, p) => n + p.length, 0);
    const out = new Uint8Array(total);
    let pos = 0;
    for (const p of parts) {
      out.set(p, pos);
      pos += p.length;
    }
    return out;
  }
  function randomBytes(n) {
    const out = new Uint8Array(n);
    for (let i = 0; i < n; i++) out[i] = Math.floor(Math.random() * 256);
    return out;
  }
  function m115Encode(input, key, pad = () => Math.floor(Math.random() * 256)) {
    if (key.length !== KEY_SIZE) throw new Error("m115 \u5BC6\u94A5\u957F\u5EA6\u5FC5\u987B\u662F 16 \u5B57\u8282");
    const buf = new Uint8Array(KEY_SIZE + input.length);
    buf.set(key);
    buf.set(input, KEY_SIZE);
    const body = buf.subarray(KEY_SIZE);
    xorTransform(body, deriveKey(key, 4));
    body.reverse();
    xorTransform(body, XOR_CLIENT_KEY);
    return base64Encode(rsaEncrypt(buf, pad));
  }
  function m115Decode(text, key) {
    const data = rsaDecrypt(base64Decode(text));
    if (data.length < KEY_SIZE) throw new Error("m115 \u89E3\u5BC6\u5931\u8D25\uFF1A\u6570\u636E\u8FC7\u77ED");
    const out = data.slice(KEY_SIZE);
    xorTransform(out, deriveKey(data.subarray(0, KEY_SIZE), 12));
    out.reverse();
    xorTransform(out, deriveKey(key, 4));
    return out;
  }

  // src/sites/pan115/link.ts
  var SITE_ID2 = "pan115";
  var SITE_NAME3 = "115 \u7F51\u76D8";
  var TASK_HOST = "115.com";
  var SHARE_CODE_RE = /^[A-Za-z0-9]{4,32}$/;
  var RECEIVE_CODE_RE = /^[A-Za-z0-9]{0,16}$/;
  var DIR_RE = /^[0-9]{1,30}$/;
  function readTask2(url) {
    if (url.host !== TASK_HOST) return null;
    const parsed = parseTaskUrl(url);
    if (!parsed || parsed.siteId !== SITE_ID2) return null;
    const { s = "", p = "", d = "" } = parsed.params;
    if (!SHARE_CODE_RE.test(s) || !RECEIVE_CODE_RE.test(p)) return null;
    if (d !== "" && !DIR_RE.test(d)) return null;
    return { shareCode: s, receiveCode: p, dir: d };
  }
  function isTaskUrl(url) {
    return url.host === TASK_HOST && parseTaskUrl(url)?.siteId === SITE_ID2;
  }

  // src/sites/pan115/api.ts
  var BROWSER_UA2 = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";
  var APP_UA = "Mozilla/5.0 115Browser/27.0.5.7";
  var SNAP_URL = "https://webapi.115.com/share/snap";
  var DOWNURL_URL = "https://proapi.115.com/app/share/downurl";
  var SHARE_REFERER = "https://115cdn.com/s/";
  var MAX_SNAP_REQUESTS = 20;
  var SNAP_PAGE_LIMIT = 1e3;
  var LOGIN_MESSAGE = "\u6CA1\u6709\u767B\u5F55\u6216\u767B\u5F55\u5DF2\u5931\u6548\uFF1A\u8BF7\u5148\u5728\u6D4F\u89C8\u5668\u767B\u5F55 115\uFF0C\u518D\u4ECE\u5206\u4EAB\u9875\u7684\u6309\u94AE\u53D1\u8D77\u4E0B\u8F7D";
  var SHARE_STATE_TEXT = {
    2: "\u5206\u4EAB\u56E0\u7248\u6743\u88AB\u7981\u6B62",
    3: "\u5206\u4EAB\u56E0\u8FDD\u89C4\u88AB\u7981\u6B62",
    4: "\u5206\u4EAB\u5DF2\u88AB\u5206\u4EAB\u8005\u53D6\u6D88",
    5: "\u5206\u4EAB\u5DF2\u88AB\u5220\u9664",
    6: "\u5206\u4EAB\u56E0\u8FDD\u89C4\u88AB\u7981\u6B62",
    7: "\u5206\u4EAB\u5DF2\u8FC7\u671F",
    8: "\u5206\u4EAB\u5BA1\u6838\u4E2D\uFF0C\u6682\u4E0D\u53EF\u8BBF\u95EE"
  };
  function quoteBigIds(body) {
    return body.replace(/("(?:cid|fid|pid)"\s*:\s*)(\d{16,})/g, '$1"$2"');
  }
  function firstCode(body) {
    for (const key of ["errno", "errNo", "errcode", "msg_code", "code"]) {
      const n = asNumber(body[key]);
      if (n !== null && n !== 0) return n;
    }
    return 0;
  }
  function failure2(stage, body) {
    const code = firstCode(body);
    const message = asString(body.error) || asString(body.msg) || asString(body.message);
    const raise = (detail, kind) => new SiteError(SITE_NAME3, stage, detail, kind);
    if (code === 99 || code === 990001) return raise(LOGIN_MESSAGE, "login");
    if (code === 4100012) return raise("\u5206\u4EAB\u9700\u8981\u63D0\u53D6\u7801\uFF0C\u94FE\u63A5\u91CC\u6CA1\u6709\u63D0\u53D6\u7801", "password");
    if (code === 4100008) return raise("\u63D0\u53D6\u7801\u9519\u8BEF", "password");
    if (code === 4100009 || code === 4100026) return raise("\u5206\u4EAB\u4E0D\u5B58\u5728\u3001\u5DF2\u5931\u6548\u6216\u5DF2\u88AB\u53D6\u6D88", "notFound");
    if (code === 70005 || code === 231011 || code === 50003 || code === 50015) return raise("\u6587\u4EF6\u4E0D\u5B58\u5728\u6216\u5DF2\u88AB\u5220\u9664", "notFound");
    if (code === 50028) return raise("\u6587\u4EF6\u8FC7\u5927\uFF0C115 \u4E0D\u5141\u8BB8\u76F4\u63A5\u4E0B\u8F7D", "limit");
    if (code === 911) return raise("115 \u8981\u6C42\u5B8C\u6210\u9A8C\u8BC1\uFF1A\u8BF7\u5148\u5728 115 \u7F51\u9875\u91CC\u901A\u8FC7\u9A8C\u8BC1\u540E\u91CD\u8BD5", "limit");
    if (message.includes("\u7248\u672C\u8FC7\u4F4E")) return raise("115 \u62D2\u7EDD\u4E86\u672C\u63D2\u4EF6\u4F7F\u7528\u7684\u5BA2\u6237\u7AEF\u6807\u8BC6\uFF08\u7248\u672C\u8FC7\u4F4E\uFF09\uFF0C\u9700\u8981\u66F4\u65B0\u63D2\u4EF6", "unsupported");
    if (message.includes("\u9891\u7E41") || message.includes("\u9891\u7387")) return raise(`\u8BF7\u6C42\u8FC7\u4E8E\u9891\u7E41\uFF08${message}\uFF09\uFF0C\u8BF7\u7A0D\u540E\u518D\u8BD5`, "limit");
    return raise(`${message || "\u7AD9\u70B9\u8FD4\u56DE\u5931\u8D25"}\uFF08\u9519\u8BEF\u7801 ${code}\uFF09`, "other");
  }
  function checkState(stage, body) {
    if (body.state === true || body.state === 1) return;
    throw failure2(stage, body);
  }
  function checkHttp(stage, status) {
    if (status === 401 || status === 403) throw new SiteError(SITE_NAME3, stage, `HTTP ${status}\uFF0C\u767B\u5F55\u6001\u65E0\u6548\u6216\u65E0\u6743\u8BBF\u95EE`, "login");
    if (status === 405) throw new SiteError(SITE_NAME3, stage, "HTTP 405\uFF0C\u8BF7\u6C42\u88AB\u7AD9\u70B9\u9632\u62A4\u62E6\u622A", "network");
    if (status < 200 || status >= 300) throw new SiteError(SITE_NAME3, stage, `HTTP ${status}`, "network");
  }
  function parseEntry(raw) {
    const o = asObject(raw);
    if (!o) return null;
    const name = asString(o.n);
    const fid = asString(o.fid);
    const cid = asString(o.cid);
    const fc = asNumber(o.fc);
    const isDir = fc === null ? fid === "" : fc === 0;
    const id = isDir ? cid : fid;
    if (name === "" || id === "") return null;
    const size = asNumber(o.s);
    return { id, name, isDir, size: !isDir && size !== null && size >= 0 ? size : -1 };
  }
  async function shareSnap(cookies, shareCode, receiveCode, dir, offset) {
    const stage = "\u5217\u51FA\u5206\u4EAB\u76EE\u5F55";
    const query = encodeQuery({
      share_code: shareCode,
      receive_code: receiveCode,
      cid: dir,
      limit: String(SNAP_PAGE_LIMIT),
      offset: String(offset),
      asc: "0",
      format: "json"
    });
    const res = await request(SITE_NAME3, stage, {
      url: `${SNAP_URL}?${query}`,
      headers: { Accept: "application/json, text/plain, */*" },
      cookies,
      userAgent: BROWSER_UA2,
      referer: `${SHARE_REFERER}${shareCode}?password=${receiveCode}&`
    });
    checkHttp(stage, res.status);
    const body = parseJsonObject(SITE_NAME3, stage, quoteBigIds(res.body));
    checkState(stage, body);
    const data = asObject(body.data);
    if (!data) throw new SiteError(SITE_NAME3, stage, "\u8FD4\u56DE\u7F3A\u5C11\u5206\u4EAB\u6570\u636E", "network");
    const info = asObject(data.shareinfo);
    return {
      title: info ? asString(info.share_title) : "",
      shareState: asNumber(data.share_state) ?? (info ? asNumber(info.share_state) ?? 1 : 1),
      total: asNumber(data.count) ?? 0,
      entries: asArray(data.list).flatMap((raw) => {
        const entry = parseEntry(raw);
        return entry ? [entry] : [];
      })
    };
  }
  async function shareDownurl(cookies, shareCode, receiveCode, fileId) {
    const stage = "\u83B7\u53D6\u76F4\u94FE";
    const key = randomBytes(KEY_SIZE);
    const payload = JSON.stringify({ share_code: shareCode, receive_code: receiveCode, file_id: fileId });
    const res = await request(SITE_NAME3, stage, {
      method: "POST",
      url: `${DOWNURL_URL}?t=${Math.floor(Date.now() / 1e3)}`,
      headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json;charset=UTF-8" },
      body: formBody({ data: m115Encode(utf8Bytes(payload), key) }),
      cookies,
      userAgent: APP_UA
    });
    checkHttp(stage, res.status);
    const body = parseJsonObject(SITE_NAME3, stage, res.body);
    checkState(stage, body);
    const encoded = body.data;
    if (typeof encoded !== "string" || encoded === "") throw new SiteError(SITE_NAME3, stage, "\u8FD4\u56DE\u7F3A\u5C11\u4E0B\u8F7D\u4FE1\u606F", "network");
    let info;
    try {
      info = parseJsonObject(SITE_NAME3, stage, utf8Decode(m115Decode(encoded, key)));
    } catch (e) {
      if (e instanceof SiteError) throw e;
      throw new SiteError(SITE_NAME3, stage, "\u4E0B\u8F7D\u4FE1\u606F\u89E3\u5BC6\u5931\u8D25\uFF08\u7AD9\u70B9\u534F\u8BAE\u53EF\u80FD\u5DF2\u53D8\u66F4\uFF09", "network");
    }
    const link = asObject(info.url);
    const url = link ? asString(link.url) : "";
    if (url === "") throw new SiteError(SITE_NAME3, stage, "\u6CA1\u6709\u53EF\u7528\u7684\u4E0B\u8F7D\u5730\u5740\uFF08\u76EE\u6807\u53EF\u80FD\u662F\u6587\u4EF6\u5939\uFF09", "unsupported");
    if (!parseUrl(url)) throw new SiteError(SITE_NAME3, stage, "\u8FD4\u56DE\u7684\u4E0B\u8F7D\u5730\u5740\u683C\u5F0F\u4E0D\u6B63\u786E", "network");
    const size = asNumber(info.fs);
    return {
      url,
      name: asString(info.fn),
      size: size !== null && size >= 0 ? size : -1,
      cookies: mergeSetCookie("", res.headers["set-cookie"])
    };
  }
  async function listTree(cookies, shareCode, receiveCode, startDir) {
    const files = [];
    const queue = [{ dir: startDir || "0", rel: [] }];
    let requests = 0;
    let title = "";
    while (queue.length > 0) {
      const { dir, rel } = queue.shift();
      let offset = 0;
      for (; ; ) {
        if (++requests > MAX_SNAP_REQUESTS) {
          throw new SiteError(SITE_NAME3, "\u5217\u51FA\u5206\u4EAB\u76EE\u5F55", `\u5206\u4EAB\u7684\u76EE\u5F55\u7ED3\u6784\u592A\u5927\uFF0C\u5217\u5B8C\u9700\u8981\u8D85\u8FC7 ${MAX_SNAP_REQUESTS} \u6B21\u8BF7\u6C42\uFF0830 \u79D2\u5185\u65E0\u6CD5\u5B8C\u6210\uFF09`, "limit");
        }
        const page = await shareSnap(cookies, shareCode, receiveCode, dir, offset);
        if (requests === 1) {
          title = page.title;
          if (page.shareState > 1) {
            throw new SiteError(SITE_NAME3, "\u8BFB\u53D6\u5206\u4EAB\u4FE1\u606F", SHARE_STATE_TEXT[page.shareState] ?? `\u5206\u4EAB\u72B6\u6001\u5F02\u5E38\uFF08${page.shareState}\uFF09`, "notFound");
          }
        }
        for (const entry of page.entries) {
          if (entry.isDir) {
            queue.push({ dir: entry.id, rel: [...rel, entry.name] });
            continue;
          }
          files.push({ id: entry.id, name: entry.name, dirs: rel, ...entry.size >= 0 ? { size: entry.size } : {} });
          if (files.length > MAX_ITEMS) {
            throw new SiteError(SITE_NAME3, "\u5217\u51FA\u5206\u4EAB\u76EE\u5F55", `\u5206\u4EAB\u5185\u6587\u4EF6\u8D85\u8FC7 ${MAX_ITEMS} \u4E2A\uFF0C\u4E00\u6B21\u6700\u591A\u4E0B\u8F7D ${MAX_ITEMS} \u4E2A`, "limit");
          }
        }
        offset += page.entries.length;
        if (page.entries.length === 0 || offset >= page.total) break;
      }
    }
    return { title, files };
  }

  // src/sites/pan115/index.ts
  var ITEM_RE = /^[A-Za-z0-9_-]{1,64}$/;
  async function directLink(cookies, task, fileId, fallbackName) {
    const dl = await shareDownurl(cookies, task.shareCode, task.receiveCode, fileId);
    return {
      url: dl.url,
      fileName: safeFileName(dl.name || fallbackName || `115-${fileId}`),
      ...dl.size > 0 ? { totalBytes: dl.size } : {},
      request: {
        // 直链不需要账号 Cookie：只带取链响应下发的 Cookie（通常为空），防止宿主把整串浏览器 Cookie 发给 CDN。
        cookies: dl.cookies,
        userAgent: APP_UA,
        referrer: ""
      }
    };
  }
  async function resolve(input) {
    const task = readTask2(input.parsed);
    if (!task) throw new SiteError(SITE_NAME3, "\u8BC6\u522B\u4EFB\u52A1", "\u4EFB\u52A1\u94FE\u63A5\u65E0\u6548\uFF0C\u8BF7\u4ECE\u5206\u4EAB\u9875\u91CD\u65B0\u53D1\u8D77", "unsupported");
    if (input.cookies.trim() === "") {
      throw new SiteError(SITE_NAME3, "\u68C0\u67E5\u767B\u5F55", "\u6CA1\u6709\u68C0\u6D4B\u5230 115 \u767B\u5F55\u4FE1\u606F\uFF1A\u8BF7\u5148\u5728\u6D4F\u89C8\u5668\u767B\u5F55 115\uFF0C\u518D\u4ECE\u5206\u4EAB\u9875\u7684\u6309\u94AE\u53D1\u8D77\u4E0B\u8F7D", "login");
    }
    if (input.resolverItem) {
      if (!ITEM_RE.test(input.resolverItem)) throw new SiteError(SITE_NAME3, "\u8BC6\u522B\u6761\u76EE", "\u6761\u76EE\u6807\u8BC6\u65E0\u6548", "unsupported");
      return directLink(input.cookies, task, input.resolverItem, "");
    }
    const tree = await listTree(input.cookies, task.shareCode, task.receiveCode, task.dir);
    if (tree.files.length === 1) {
      const only = tree.files[0];
      return directLink(input.cookies, task, only.id, only.name);
    }
    return manifestResult(SITE_NAME3, tree.title || `115\u5206\u4EAB-${task.shareCode}`, tree.files);
  }
  var pan115 = {
    id: SITE_ID2,
    name: SITE_NAME3,
    // 只按主机与路径认领；参数非法由 resolve 报「任务链接无效」，比落到通用的「不支持的任务链接」更清楚。
    claims: isTaskUrl,
    resolve
  };

  // src/core/site.ts
  function hostIn(host, domains) {
    return domains.some((d) => host === d || host.endsWith(`.${d}`));
  }

  // src/sites/pan123/link.ts
  var SITE_ID3 = "pan123";
  var SITE_NAME4 = "123 \u4E91\u76D8";
  var SHARE_DOMAINS2 = [
    "123pan.com",
    "123pan.cn",
    "123684.com",
    "123865.com",
    "123912.com",
    "123592.com",
    "123295.com",
    "123278.com"
  ];
  var KEY_RE2 = /^[A-Za-z0-9]{1,32}-[A-Za-z0-9]{1,32}$/;
  var PWD_RE2 = /^[A-Za-z0-9]{1,32}$/;
  function isShareHost2(host) {
    return hostIn(host, SHARE_DOMAINS2);
  }
  function parseShareTask(url) {
    if (!isShareHost2(url.host)) return null;
    const task = parseTaskUrl(url);
    if (!task || task.siteId !== SITE_ID3) return null;
    const key = task.params.key ?? "";
    if (!KEY_RE2.test(key)) return null;
    const pwd = task.params.pwd ?? "";
    if (pwd !== "" && !PWD_RE2.test(pwd)) return null;
    return { key, pwd };
  }

  // src/sites/pan123/sign.ts
  var SIGN_TABLE = "adefghlmyijnopkqrstubcvwsz";
  var CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 3988292384 ^ c >>> 1 : c >>> 1;
    return c >>> 0;
  });
  function crc32(text) {
    let crc = 4294967295;
    for (const b of utf8Bytes(text)) crc = CRC_TABLE[(crc ^ b) & 255] ^ crc >>> 8;
    return (crc ^ 4294967295) >>> 0;
  }
  function pad2(n) {
    return n < 10 ? `0${n}` : String(n);
  }
  function signPath(path, nowMs, random) {
    const unix = Math.floor(nowMs / 1e3);
    const d = new Date(nowMs + 8 * 3600 * 1e3);
    const stamp = `${d.getUTCFullYear()}${pad2(d.getUTCMonth() + 1)}${pad2(d.getUTCDate())}${pad2(d.getUTCHours())}${pad2(d.getUTCMinutes())}`;
    const mapped = Array.from(stamp, (c) => SIGN_TABLE[Number(c)]).join("");
    const key = String(crc32(mapped));
    return [key, `${unix}-${random}-${crc32(`${unix}|${random}|${path}|web|3|${key}`)}`];
  }

  // src/sites/pan123/api.ts
  var WEB_REFERER = "https://yun.123pan.com/";
  var WEB_ORIGIN = "https://yun.123pan.com";
  var BROWSER_UA3 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";
  var API_BASES = [
    { origin: "https://yun.123pan.com", prefix: "/b/api" },
    { origin: "https://www.123pan.cn", prefix: "/b/api" }
  ];
  var PAGE_LIMIT = 100;
  var MAX_LIST_REQUESTS2 = 20;
  var LIST_CONCURRENCY2 = 3;
  var LIST_DEADLINE_MS = 2e4;
  function toEntry(value) {
    const obj = asObject(value);
    if (!obj) return null;
    const rawId = obj.FileId;
    if (typeof rawId === "number" && !Number.isSafeInteger(rawId)) {
      throw new SiteError(SITE_NAME4, "\u8BFB\u53D6\u5206\u4EAB\u76EE\u5F55", "\u6587\u4EF6\u6807\u8BC6\u8D85\u51FA\u53EF\u5904\u7406\u8303\u56F4", "unsupported");
    }
    const id = asString(rawId);
    const name = asString(obj.FileName);
    if (id === "" || name === "") return null;
    const size = asNumber(obj.Size);
    return {
      id,
      name,
      isDir: asNumber(obj.Type) === 1,
      size: size !== null && size > 0 ? size : 0,
      etag: asString(obj.Etag),
      s3Key: asString(obj.S3KeyFlag)
    };
  }
  var ShareClient = class {
    constructor(key, pwd, auth) {
      this.key = key;
      this.pwd = pwd;
      this.auth = auth;
    }
    key;
    pwd;
    auth;
    listRequests = 0;
    deadline = Date.now() + LIST_DEADLINE_MS;
    /** 调业务接口，返回 `data` 对象。 */
    async call(method, path, query, body, stage) {
      let lastError = null;
      for (const base of API_BASES) {
        const [signKey, signValue] = signPath(`${base.prefix}${path}`, Date.now(), Math.floor(Math.random() * 10000001));
        const headers = { Origin: WEB_ORIGIN, platform: "web", "app-version": "3" };
        if (this.auth.token) headers["Authorization"] = `Bearer ${this.auth.token}`;
        if (body !== void 0) headers["Content-Type"] = "application/json";
        let text;
        try {
          const res = await request(SITE_NAME4, stage, {
            method,
            url: `${base.origin}${base.prefix}${path}?${encodeQuery({ ...query, [signKey]: signValue })}`,
            headers,
            body: body === void 0 ? void 0 : JSON.stringify(body),
            userAgent: BROWSER_UA3,
            referer: WEB_REFERER
          });
          text = res.body;
        } catch (e) {
          if (!(e instanceof SiteError)) throw e;
          lastError = e;
          continue;
        }
        let obj = null;
        try {
          obj = asObject(JSON.parse(text));
        } catch {
        }
        if (!obj) {
          lastError = new SiteError(SITE_NAME4, stage, "\u63A5\u53E3\u8FD4\u56DE\u7684\u4E0D\u662F JSON\uFF08\u7AD9\u70B9\u53EF\u80FD\u6539\u7248\u6216\u8981\u6C42\u9A8C\u8BC1\uFF09", "network");
          continue;
        }
        return this.unwrap(obj, stage);
      }
      throw lastError ?? new SiteError(SITE_NAME4, stage, "\u8BF7\u6C42\u63A5\u53E3\u5931\u8D25", "network");
    }
    /** 按 `code` 归类业务响应。 */
    unwrap(obj, stage) {
      const code = asNumber(obj.code);
      if (code === 0) return asObject(obj.data) ?? {};
      const message = asString(obj.message).slice(0, 100);
      switch (code) {
        case 401: {
          const hint = this.auth.state === "ok" ? "\u767B\u5F55\u5DF2\u5931\u6548\uFF0C\u8BF7\u5728\u6D4F\u89C8\u5668\u91CD\u65B0\u767B\u5F55 123 \u4E91\u76D8\u540E\uFF0C\u518D\u4ECE\u5206\u4EAB\u9875\u70B9\u51FB\u300C\u76F4\u94FE\u4E0B\u8F7D\u300D" : "\u8BE5\u5206\u4EAB\u9700\u8981\u767B\u5F55\uFF1A\u8BF7\u5148\u5728\u6D4F\u89C8\u5668\u767B\u5F55 123 \u4E91\u76D8\uFF0C\u518D\u4ECE\u5206\u4EAB\u9875\u70B9\u51FB\u300C\u76F4\u94FE\u4E0B\u8F7D\u300D";
          throw new SiteError(SITE_NAME4, stage, hint, "login");
        }
        case 5103:
          throw new SiteError(SITE_NAME4, stage, message || "\u63D0\u53D6\u7801\u9519\u8BEF\u6216\u5206\u4EAB\u4E0D\u5B58\u5728", message.includes("\u63D0\u53D6\u7801") ? "password" : "notFound");
        case 5112:
          throw new SiteError(SITE_NAME4, stage, `${message || "\u5206\u4EAB\u65B9\u63D0\u53D6\u6D41\u91CF\u5305\u4E0D\u8DB3"}\uFF08${this.trafficHint()}\uFF09`, "limit");
        case 400:
          throw new SiteError(SITE_NAME4, stage, message || "\u8BF7\u6C42\u53C2\u6570\u5F02\u5E38", "other");
        default:
          throw new SiteError(SITE_NAME4, stage, `${message || "\u63A5\u53E3\u8FD4\u56DE\u5F02\u5E38"}\uFF08code ${code ?? "?"}\uFF09`, "other");
      }
    }
    trafficHint() {
      if (this.auth.state === "ok") return "\u5F53\u524D\u8D26\u53F7\u7684\u4E0B\u8F7D\u6D41\u91CF\u53EF\u80FD\u4E0D\u8DB3";
      if (this.auth.state === "expired") return "\u767B\u5F55\u5DF2\u8FC7\u671F\uFF0C\u5DF2\u6309\u672A\u767B\u5F55\u89E3\u6790\uFF0C\u4F1A\u6D88\u8017\u5206\u4EAB\u8005\u7684\u63D0\u53D6\u6D41\u91CF\uFF1B\u8BF7\u91CD\u65B0\u767B\u5F55 123 \u4E91\u76D8\u540E\u518D\u8BD5";
      return "\u672A\u767B\u5F55\u65F6\u4F1A\u6D88\u8017\u5206\u4EAB\u8005\u7684\u63D0\u53D6\u6D41\u91CF\uFF1B\u8BF7\u5148\u5728\u6D4F\u89C8\u5668\u767B\u5F55 123 \u4E91\u76D8\uFF0C\u518D\u4ECE\u5206\u4EAB\u9875\u70B9\u51FB\u300C\u76F4\u94FE\u4E0B\u8F7D\u300D";
    }
    spendListRequest() {
      if (this.listRequests >= MAX_LIST_REQUESTS2) {
        throw new SiteError(SITE_NAME4, "\u8BFB\u53D6\u5206\u4EAB\u76EE\u5F55", `\u5206\u4EAB\u5185\u5BB9\u8FC7\u591A\uFF08\u8D85\u8FC7 ${MAX_ITEMS} \u4E2A\u6587\u4EF6\u6216 ${MAX_LIST_REQUESTS2} \u6B21\u76EE\u5F55\u8BF7\u6C42\uFF09\uFF0C\u65E0\u6CD5\u4E00\u6B21\u5217\u51FA`, "limit");
      }
      if (Date.now() > this.deadline) {
        throw new SiteError(SITE_NAME4, "\u8BFB\u53D6\u5206\u4EAB\u76EE\u5F55", "\u8BFB\u53D6\u76EE\u5F55\u8017\u65F6\u8FC7\u957F\uFF0C\u5DF2\u4E2D\u6B62", "limit");
      }
      this.listRequests++;
    }
    /** 一页目录；last 表示最后一页。 */
    async listPage(dirId, page) {
      this.spendListRequest();
      const data = await this.call(
        "GET",
        "/share/get",
        {
          limit: String(PAGE_LIMIT),
          next: "0",
          orderBy: "file_id",
          orderDirection: "desc",
          parentFileId: dirId,
          Page: String(page),
          shareKey: this.key,
          SharePwd: this.pwd
        },
        void 0,
        "\u8BFB\u53D6\u5206\u4EAB\u76EE\u5F55"
      );
      if (data.Expired === true) throw new SiteError(SITE_NAME4, "\u8BFB\u53D6\u5206\u4EAB\u76EE\u5F55", "\u5206\u4EAB\u5DF2\u8FC7\u671F", "notFound");
      const list = asArray(data.InfoList);
      const items = [];
      for (const v of list) {
        const entry = toEntry(v);
        if (entry) items.push(entry);
      }
      return { items, last: list.length === 0 || asString(data.Next) === "-1" };
    }
    async listDir(dirId) {
      const out = [];
      for (let page = 1; ; page++) {
        const { items, last } = await this.listPage(dirId, page);
        out.push(...items);
        if (last) return out;
      }
    }
    /** 递归列出整个分享（广度优先，目录请求并发 3 个），按目录先后顺序展平成文件列表。 */
    async walk() {
      const listing = /* @__PURE__ */ new Map();
      const seen = /* @__PURE__ */ new Set(["0"]);
      let level = ["0"];
      let fileCount = 0;
      while (level.length > 0) {
        const next = [];
        for (let i = 0; i < level.length; i += LIST_CONCURRENCY2) {
          const batch = level.slice(i, i + LIST_CONCURRENCY2);
          const results = await Promise.all(batch.map((id) => this.listDir(id)));
          batch.forEach((id, j) => {
            const entries = results[j];
            listing.set(id, entries);
            for (const e of entries) {
              if (!e.isDir) fileCount++;
              else if (!seen.has(e.id)) {
                seen.add(e.id);
                next.push(e.id);
              }
            }
          });
          if (fileCount > MAX_ITEMS) {
            throw new SiteError(SITE_NAME4, "\u8BFB\u53D6\u5206\u4EAB\u76EE\u5F55", `\u5206\u4EAB\u5185\u5BB9\u8FC7\u591A\uFF08\u8D85\u8FC7 ${MAX_ITEMS} \u4E2A\u6587\u4EF6\uFF09\uFF0C\u65E0\u6CD5\u4E00\u6B21\u5217\u51FA`, "limit");
          }
        }
        level = next;
      }
      const files = [];
      const onPath = /* @__PURE__ */ new Set();
      const visit = (dirId, dirs) => {
        onPath.add(dirId);
        for (const e of listing.get(dirId) ?? []) {
          if (!e.isDir) files.push({ entry: e, parentId: dirId, dirs });
          else if (!onPath.has(e.id)) visit(e.id, [...dirs, e.name]);
        }
        onPath.delete(dirId);
      };
      visit("0", []);
      return files;
    }
    /** 在父目录里按 id 找文件（清单二段解析用）。 */
    async findFile(fileId, parentId) {
      for (let page = 1; ; page++) {
        const { items, last } = await this.listPage(parentId, page);
        const hit = items.find((e) => e.id === fileId);
        if (hit) {
          if (hit.isDir) throw new SiteError(SITE_NAME4, "\u67E5\u627E\u6587\u4EF6", "\u76EE\u6807\u662F\u6587\u4EF6\u5939\uFF0C\u4E0D\u662F\u6587\u4EF6", "unsupported");
          return hit;
        }
        if (last) throw new SiteError(SITE_NAME4, "\u67E5\u627E\u6587\u4EF6", "\u6587\u4EF6\u4E0D\u5B58\u5728\u6216\u5DF2\u79FB\u51FA\u5206\u4EAB", "notFound");
      }
    }
    /** 取一个文件的直链。 */
    async downloadLink(entry) {
      if (entry.isDir) throw new SiteError(SITE_NAME4, "\u83B7\u53D6\u4E0B\u8F7D\u5730\u5740", "\u76EE\u6807\u662F\u6587\u4EF6\u5939\uFF0C\u4E0D\u662F\u6587\u4EF6", "unsupported");
      if (!/^\d+$/.test(entry.id) || !Number.isSafeInteger(Number(entry.id))) {
        throw new SiteError(SITE_NAME4, "\u83B7\u53D6\u4E0B\u8F7D\u5730\u5740", "\u6587\u4EF6\u6807\u8BC6\u683C\u5F0F\u4E0D\u6B63\u786E", "unsupported");
      }
      const fileId = Number(entry.id);
      const data = await this.call(
        "POST",
        "/share/download/info",
        {},
        { shareKey: this.key, SharePwd: this.pwd, etag: entry.etag, fileId, s3keyFlag: entry.s3Key, size: entry.size },
        "\u83B7\u53D6\u4E0B\u8F7D\u5730\u5740"
      );
      let downloadUrl = asString(data.DownloadURL) || asString(data.DownloadUrl);
      if (!parseUrl(downloadUrl)) downloadUrl = await this.downloadUrlV2(entry, fileId);
      return this.follow(downloadUrl);
    }
    /**
     * 备用接口：网页分享页当前用 `/v2/share/download/info`，返回 `dispatchList[0].prefix + downloadPath`
     * （源码依据：statics.123pan.com 分享页 bundle；登录后的返回未实测）。
     */
    async downloadUrlV2(entry, fileId) {
      const data = await this.call(
        "POST",
        "/v2/share/download/info",
        {},
        { ShareKey: this.key, SharePwd: this.pwd, FileID: fileId, S3keyFlag: entry.s3Key, Size: entry.size, Etag: entry.etag },
        "\u83B7\u53D6\u4E0B\u8F7D\u5730\u5740\uFF08\u5907\u7528\u63A5\u53E3\uFF09"
      );
      const prefix = asString(asObject(asArray(data.dispatchList)[0])?.prefix);
      const url = prefix + asString(data.downloadPath);
      if (!parseUrl(url)) throw new SiteError(SITE_NAME4, "\u83B7\u53D6\u4E0B\u8F7D\u5730\u5740", "\u63A5\u53E3\u672A\u8FD4\u56DE\u4E0B\u8F7D\u5730\u5740", "network");
      return url;
    }
    /**
     * 处理下载地址（OpenList 123_share 同款）：`params` 是 base64 的真实地址，解码后 GET，
     * 返回 302（跳到文件）或 JSON `data.redirect_url`。
     * flux.fetch 自动跟随重定向，读不到 302 的 Location：JSON 形态能拿到 redirect_url；
     * 跳到文件的形态只能返回解码后的地址，由下载引擎自己跟随 302（Referer 仍用网页版）。
     */
    async follow(downloadUrl) {
      const stage = "\u83B7\u53D6\u76F4\u94FE";
      const origin = parseUrl(downloadUrl);
      if (!origin) throw new SiteError(SITE_NAME4, stage, "\u4E0B\u8F7D\u5730\u5740\u65E0\u6548", "network");
      let target = downloadUrl;
      const params = parseQuery(origin.query).params;
      if (params) {
        let decoded = "";
        try {
          decoded = utf8Decode(base64Decode(params.replace(/ /g, "+")));
        } catch {
        }
        if (!parseUrl(decoded)) throw new SiteError(SITE_NAME4, stage, "\u4E0B\u8F7D\u5730\u5740\u53C2\u6570\u65E0\u6CD5\u89E3\u7801\uFF08\u63A5\u53E3\u53EF\u80FD\u5DF2\u6539\u7248\uFF09", "network");
        target = decoded;
      }
      let res;
      try {
        res = await flux.fetch({ method: "GET", url: target, headers: { Referer: WEB_REFERER, "User-Agent": BROWSER_UA3, Range: "bytes=0-0" } });
      } catch (e) {
        throw new SiteError(SITE_NAME4, stage, `\u8BF7\u6C42\u4E0B\u8F7D\u5730\u5740\u5931\u8D25\uFF08${e instanceof Error ? e.message : String(e)}\uFF09`, "network");
      }
      if (res.status >= 400) throw new SiteError(SITE_NAME4, stage, `\u4E0B\u8F7D\u5730\u5740\u8FD4\u56DE HTTP ${res.status}`, "network");
      const type = (res.headers["content-type"] ?? "").toLowerCase();
      if (type.startsWith("text/html")) {
        throw new SiteError(SITE_NAME4, stage, "\u4E0B\u8F7D\u5730\u5740\u8FD4\u56DE\u4E86\u7F51\u9875\u800C\u4E0D\u662F\u6587\u4EF6\uFF08\u53EF\u80FD\u9700\u8981\u9A8C\u8BC1\u6216\u63A5\u53E3\u5DF2\u6539\u7248\uFF09", "network");
      }
      const text = res.body.trim();
      const isFileSlice = res.status === 206 || res.headers["content-range"] !== void 0;
      if (!isFileSlice && !res.truncated && (type.includes("json") || text.startsWith("{"))) {
        let obj = null;
        try {
          obj = asObject(JSON.parse(text));
        } catch {
        }
        if (obj && "code" in obj) {
          const redirect = asString(asObject(obj.data)?.redirect_url);
          if (parseUrl(redirect)) return { url: redirect, referrer: `${origin.scheme}://${origin.host}/` };
          throw new SiteError(SITE_NAME4, stage, asString(obj.message).slice(0, 100) || "\u4E0B\u8F7D\u5730\u5740\u672A\u8FD4\u56DE\u76F4\u94FE", "network");
        }
      }
      return { url: target, referrer: WEB_REFERER };
    }
  };

  // src/sites/pan123/jwt.ts
  var MAX_TOKEN_CHARS = 4096;
  var EXPIRY_SKEW_SEC = 60;
  var SEGMENT_RE = /^[A-Za-z0-9_-]+$/;
  function normalizeToken(raw) {
    let s = raw.trim();
    if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) s = s.slice(1, -1).trim();
    return s.replace(/^bearer\s+/i, "").trim();
  }
  function decodeSegment(seg) {
    try {
      return asObject(JSON.parse(utf8Decode(base64Decode(seg))));
    } catch {
      return null;
    }
  }
  function jwtExpiry(token) {
    if (token.length === 0 || token.length > MAX_TOKEN_CHARS) return null;
    const parts = token.split(".");
    if (parts.length !== 3 || !parts.every((p) => SEGMENT_RE.test(p))) return null;
    if (!decodeSegment(parts[0])) return null;
    const payload = decodeSegment(parts[1]);
    const exp = payload ? asNumber(payload.exp) : null;
    return exp !== null && exp > 0 ? Math.floor(exp) : null;
  }
  function checkToken(raw, nowSec) {
    const token = normalizeToken(raw);
    const exp = jwtExpiry(token);
    if (exp === null) return { kind: "shape" };
    if (exp <= nowSec + EXPIRY_SKEW_SEC) return { kind: "expired" };
    return { kind: "ok", token, exp };
  }

  // src/sites/pan123/token.ts
  var KEY = "pan123.auth";
  async function saveToken(token, exp) {
    await flux.storage.set(KEY, JSON.stringify({ token, exp }));
  }
  async function clearToken() {
    await flux.storage.set(KEY, "");
  }
  async function loadAuth(nowSec) {
    const raw = await flux.storage.get(KEY);
    if (!raw) return { token: "", state: "none" };
    let record;
    try {
      record = JSON.parse(raw);
    } catch {
      return { token: "", state: "none" };
    }
    const token = asObject(record)?.token;
    if (typeof token !== "string") return { token: "", state: "none" };
    const checked = checkToken(token, nowSec);
    if (checked.kind === "ok") return { token: checked.token, state: "ok" };
    return { token: "", state: checked.kind === "expired" ? "expired" : "none" };
  }

  // src/sites/pan123/index.ts
  var ITEM_ID_RE2 = /^(\d+):(\d+)$/;
  async function fileResult(client, entry) {
    const link = await client.downloadLink(entry);
    return {
      url: link.url,
      fileName: safeFileName(entry.name),
      ...entry.size > 0 ? { totalBytes: entry.size } : {},
      // 直链不需要任何浏览器 Cookie；显式置空，免得宿主把任务上的整串 Cookie 发给 CDN。
      request: { cookies: "", referrer: link.referrer, userAgent: BROWSER_UA3 }
    };
  }
  async function resolve2(input) {
    const share = parseShareTask(input.parsed);
    if (!share) throw new SiteError(SITE_NAME4, "\u8BC6\u522B\u4EFB\u52A1", "\u4EFB\u52A1\u94FE\u63A5\u7F3A\u5C11\u6709\u6548\u7684\u5206\u4EAB\u6807\u8BC6\uFF0C\u8BF7\u4ECE\u5206\u4EAB\u9875\u91CD\u65B0\u53D1\u8D77", "unsupported");
    const client = new ShareClient(share.key, share.pwd, await loadAuth(Math.floor(Date.now() / 1e3)));
    if (input.resolverItem !== "") {
      const m = ITEM_ID_RE2.exec(input.resolverItem);
      if (!m) throw new SiteError(SITE_NAME4, "\u8BC6\u522B\u4EFB\u52A1", "\u6761\u76EE\u6807\u8BC6\u65E0\u6548", "unsupported");
      return fileResult(client, await client.findFile(m[1], m[2]));
    }
    const files = await client.walk();
    if (files.length === 1) return fileResult(client, files[0].entry);
    return manifestResult(
      SITE_NAME4,
      `\u5206\u4EAB ${share.key}`,
      files.map((f) => ({
        id: `${f.entry.id}:${f.parentId}`,
        name: f.entry.name,
        dirs: f.dirs,
        ...f.entry.size > 0 ? { size: f.entry.size } : {}
      }))
    );
  }
  async function syncToken(args) {
    const raw = asObject(args)?.token;
    if (typeof raw !== "string" || raw.length > MAX_TOKEN_CHARS * 2) {
      throw new SiteError(SITE_NAME4, "\u540C\u6B65\u767B\u5F55\u6001", "\u53C2\u6570\u65E0\u6548", "unsupported");
    }
    if (raw.trim() === "") {
      await clearToken();
      return { loggedIn: false, expiresAt: 0 };
    }
    const checked = checkToken(raw, Math.floor(Date.now() / 1e3));
    if (checked.kind === "shape") throw new SiteError(SITE_NAME4, "\u540C\u6B65\u767B\u5F55\u6001", "\u767B\u5F55\u4EE4\u724C\u683C\u5F0F\u65E0\u6548", "unsupported");
    if (checked.kind === "expired") {
      await clearToken();
      throw new SiteError(SITE_NAME4, "\u540C\u6B65\u767B\u5F55\u6001", "\u767B\u5F55\u5DF2\u8FC7\u671F\uFF0C\u8BF7\u5148\u5728 123 \u4E91\u76D8\u91CD\u65B0\u767B\u5F55", "login");
    }
    await saveToken(checked.token, checked.exp);
    return { loggedIn: true, expiresAt: checked.exp };
  }
  var pan123 = {
    id: SITE_ID3,
    name: SITE_NAME4,
    claims: (url) => isShareHost2(url.host) && parseTaskUrl(url)?.siteId === SITE_ID3,
    resolve: resolve2,
    page: { hosts: SHARE_DOMAINS2, rpc: { syncToken } }
  };

  // src/sites/pixiv/link.ts
  var PIXIV_HOSTS = ["pixiv.net"];
  var ARTWORK_PATH = /^(?:\/[a-z]{2}(?:[-_][a-z]{2,4})?)?\/artworks\/(\d{1,12})\/?$/;
  function parseArtworkId(url) {
    if (url.scheme !== "https" && url.scheme !== "http") return null;
    if (!hostIn(url.host, PIXIV_HOSTS)) return null;
    const m = ARTWORK_PATH.exec(url.path);
    return m ? m[1] : null;
  }

  // src/sites/pixiv/index.ts
  var NAME = "Pixiv";
  var REFERER2 = "https://www.pixiv.net/";
  var DEFAULT_UA3 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
  function imagePatch(userAgent, fileName) {
    return { cookies: "", referrer: REFERER2, userAgent, ...fileName ? { fileName } : {} };
  }
  async function ajax(input, stage, id, suffix) {
    const res = await request(NAME, stage, {
      url: `https://www.pixiv.net/ajax/illust/${id}${suffix}`,
      headers: { Accept: "application/json", "Accept-Language": "ja,en;q=0.8" },
      cookies: input.cookies,
      userAgent: input.userAgent || DEFAULT_UA3,
      referer: REFERER2
    });
    if (res.status === 429) throw new SiteError(NAME, stage, "\u8BF7\u6C42\u8FC7\u4E8E\u9891\u7E41\uFF0C\u8BF7\u7A0D\u540E\u518D\u8BD5", "limit");
    if (res.status >= 500) throw new SiteError(NAME, stage, `HTTP ${res.status}`, "network");
    const denied = () => input.cookies ? new SiteError(NAME, stage, "\u4F5C\u54C1\u4E0D\u5B58\u5728\u3001\u5DF2\u5220\u9664\uFF0C\u6216\u5F53\u524D\u8D26\u53F7\u65E0\u6743\u67E5\u770B", "notFound") : new SiteError(NAME, stage, "\u4F5C\u54C1\u4E0D\u5B58\u5728\uFF0C\u6216\u9700\u8981\u767B\u5F55\u624D\u80FD\u67E5\u770B\uFF1B\u8BF7\u5148\u5728\u6D4F\u89C8\u5668\u767B\u5F55 Pixiv\uFF0C\u518D\u4ECE\u4F5C\u54C1\u9875\u6309\u94AE\u53D1\u8D77", "login");
    if (res.status === 401 || res.status === 403) throw denied();
    let json;
    try {
      json = parseJsonObject(NAME, stage, res.body);
    } catch (e) {
      if (res.status >= 400) throw denied();
      throw e;
    }
    if (json["error"] === true || res.status >= 400) {
      throw denied();
    }
    const body = json["body"];
    if (body === void 0 || body === null) throw new SiteError(NAME, stage, "\u8FD4\u56DE\u5185\u5BB9\u7F3A\u5C11 body", "network");
    return body;
  }
  function extOf(url) {
    const m = /\.([A-Za-z0-9]{1,5})(?:\?|$)/.exec(url);
    return m ? m[1].toLowerCase() : "jpg";
  }
  function pageFileName2(id, index, url) {
    return `${id}_p${index}.${extOf(url)}`;
  }
  async function loadIllust(input, id) {
    const body = asObject(await ajax(input, "\u8BFB\u53D6\u4F5C\u54C1", id, ""));
    if (!body) throw new SiteError(NAME, "\u8BFB\u53D6\u4F5C\u54C1", "\u8FD4\u56DE\u5185\u5BB9\u683C\u5F0F\u5F02\u5E38", "network");
    return {
      title: asString(body["illustTitle"]) || asString(body["title"]) || id,
      author: asString(body["userName"]),
      isUgoira: asNumber(body["illustType"]) === 2,
      pageCount: asNumber(body["pageCount"]) ?? 1
    };
  }
  async function loadPages(input, id) {
    const body = await ajax(input, "\u8BFB\u53D6\u56FE\u7247\u5217\u8868", id, "/pages");
    const urls = [];
    for (const page of asArray(body)) {
      const original = asString(asObject(asObject(page)?.["urls"])?.["original"]);
      if (original) urls.push(original);
    }
    if (urls.length === 0) throw new SiteError(NAME, "\u8BFB\u53D6\u56FE\u7247\u5217\u8868", "\u6CA1\u6709\u627E\u5230\u539F\u56FE\u5730\u5740", "notFound");
    return urls;
  }
  async function resolveUgoira(input, id) {
    const body = asObject(await ajax(input, "\u8BFB\u53D6\u52A8\u56FE", id, "/ugoira_meta"));
    if (!body) throw new SiteError(NAME, "\u8BFB\u53D6\u52A8\u56FE", "\u8FD4\u56DE\u5185\u5BB9\u683C\u5F0F\u5F02\u5E38", "network");
    const src = asString(body["originalSrc"]) || asString(body["src"]);
    if (!src) throw new SiteError(NAME, "\u8BFB\u53D6\u52A8\u56FE", "\u6CA1\u6709\u627E\u5230\u52A8\u56FE\u538B\u7F29\u5305\u5730\u5740", "notFound");
    const fileName = `${id}_ugoira.zip`;
    return { url: src, fileName, request: imagePatch(input.userAgent || DEFAULT_UA3, fileName) };
  }
  var pixiv = {
    id: "pixiv",
    name: NAME,
    claims: (url) => parseArtworkId(url) !== null,
    async resolve(input) {
      const id = parseArtworkId(input.parsed);
      if (!id) throw new SiteError(NAME, "\u8BC6\u522B\u94FE\u63A5", "\u4E0D\u662F Pixiv \u4F5C\u54C1\u9875\u94FE\u63A5", "unsupported");
      const ua = input.userAgent || DEFAULT_UA3;
      if (input.resolverItem !== "") {
        if (!/^\d{1,4}$/.test(input.resolverItem)) throw new SiteError(NAME, "\u89E3\u6790\u6761\u76EE", "\u6761\u76EE\u6807\u8BC6\u65E0\u6548", "unsupported");
        const index = Number(input.resolverItem);
        const urls2 = await loadPages(input, id);
        const url = urls2[index];
        if (!url) throw new SiteError(NAME, "\u89E3\u6790\u6761\u76EE", "\u8BE5\u9875\u5DF2\u4E0D\u5B58\u5728", "notFound");
        const fileName = pageFileName2(id, index, url);
        return { url, fileName, request: imagePatch(ua, fileName) };
      }
      const illust = await loadIllust(input, id);
      if (illust.isUgoira) return resolveUgoira(input, id);
      const urls = await loadPages(input, id);
      if (urls.length === 1) {
        const fileName = pageFileName2(id, 0, urls[0]);
        return { url: urls[0], fileName, request: imagePatch(ua, fileName) };
      }
      const dir = illust.author ? `${illust.author} - ${illust.title}` : illust.title;
      return manifestResult(
        NAME,
        dir,
        urls.map((u, i) => ({ id: String(i), name: pageFileName2(id, i, u), dirs: [dir] }))
      );
    }
  };

  // src/sites/quark/api.ts
  var SITE_NAME5 = "\u5938\u514B\u7F51\u76D8";
  var QUARK_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch";
  var QUARK_ORIGIN = "https://pan.quark.cn";
  var QUARK_REFERER = `${QUARK_ORIGIN}/`;
  var DRIVE_BASE = "https://drive-pc.quark.cn";
  var SESSION_COOKIES = ["__pus", "__puus"];
  var PAGE_SIZE3 = 100;
  var MAX_LIST_REQUESTS3 = 20;
  var MAX_FILES = 1e3;
  var TASK_POLLS = 15;
  var ROOT_PAGES = 10;
  var MAX_FIND_PAGES = 20;
  var SCRATCH_ROOT2 = "accountdl-tmp";
  var SCRATCH_TTL_SEC = 6 * 3600;
  var QuarkError = class extends SiteError {
    code;
    constructor(stage, detail, kind, code) {
      super(SITE_NAME5, stage, detail, kind);
      this.name = "QuarkError";
      this.code = code;
    }
  };
  function codeOf(obj) {
    return asNumber(obj.code) ?? 0;
  }
  function loggedOut(status, obj) {
    const code = codeOf(obj);
    return status === 401 || code === 31001 || code === 20002;
  }
  function driveError(stage, obj) {
    const code = codeOf(obj);
    switch (code) {
      case 31001:
      case 20002:
        return new QuarkError(stage, "\u767B\u5F55\u5DF2\u5931\u6548\uFF0C\u8BF7\u5728\u6D4F\u89C8\u5668\u91CD\u65B0\u767B\u5F55 pan.quark.cn \u540E\u518D\u53D1\u8D77", "login", code);
      case 41008:
        return new QuarkError(stage, "\u6B64\u5206\u4EAB\u9700\u8981\u63D0\u53D6\u7801", "password", code);
      case 41007:
      case 41009:
      case 24e3:
        return new QuarkError(stage, "\u63D0\u53D6\u7801\u9519\u8BEF", "password", code);
      case 41006:
      case 41012:
      case 24001:
        return new QuarkError(stage, "\u5206\u4EAB\u4E0D\u5B58\u5728\u3001\u5DF2\u53D6\u6D88\u6216\u5DF2\u5931\u6548", "notFound", code);
      case 41010:
        return new QuarkError(stage, "\u5206\u4EAB\u6587\u4EF6\u6D89\u53CA\u8FDD\u89C4\u5185\u5BB9\uFF0C\u65E0\u6CD5\u8BBF\u95EE", "notFound", code);
      case 23018:
        return new QuarkError(stage, "\u8BE5\u6587\u4EF6\u8D85\u51FA\u53EF\u76F4\u63A5\u4E0B\u8F7D\u7684\u989D\u5EA6\uFF08\u9700\u8981\u4F1A\u5458\u6216\u7F51\u76D8\u7A7A\u95F4\uFF09", "limit", code);
    }
    const msg = asString(obj.message);
    if (/capacity|容量|空间不足/i.test(msg)) return new QuarkError(stage, "\u8D26\u53F7\u7F51\u76D8\u7A7A\u95F4\u4E0D\u8DB3\uFF0C\u65E0\u6CD5\u8F6C\u5B58", "limit", code);
    return new QuarkError(stage, msg || `\u9519\u8BEF\u7801 ${code}`, "other", code);
  }
  function rotateSession(cookie, setCookie) {
    if (!setCookie) return cookie;
    const fresh = parseCookies(mergeSetCookie("", setCookie));
    const jar = parseCookies(cookie);
    for (const name of SESSION_COOKIES) {
      const value = fresh.get(name);
      if (value) jar.set(name, value);
    }
    return formatCookies(jar);
  }
  var Conn = class {
    cookie;
    refreshed = false;
    constructor(cookie) {
      this.cookie = cookie;
    }
    /** 最小化后的直链 Cookie（只含 `__pus` / `__puus`）。 */
    directCookie() {
      return pickCookies(this.cookie, SESSION_COOKIES);
    }
    async once(stage, method, url, body) {
      const res = await request(SITE_NAME5, stage, {
        method,
        url,
        cookies: this.cookie,
        userAgent: QUARK_UA,
        referer: QUARK_REFERER,
        headers: {
          Origin: QUARK_ORIGIN,
          Accept: "application/json, text/plain, */*",
          ...body === void 0 ? {} : { "Content-Type": "application/json" }
        },
        body: body === void 0 ? void 0 : JSON.stringify(body)
      });
      this.cookie = rotateSession(this.cookie, res.headers["set-cookie"]);
      let obj = null;
      try {
        obj = asObject(JSON.parse(res.body));
      } catch {
        obj = null;
      }
      if (!obj) {
        if (res.status === 401) throw new QuarkError(stage, "\u767B\u5F55\u5DF2\u5931\u6548\uFF0C\u8BF7\u5728\u6D4F\u89C8\u5668\u91CD\u65B0\u767B\u5F55 pan.quark.cn \u540E\u518D\u53D1\u8D77", "login", 31001);
        throw new SiteError(SITE_NAME5, stage, `HTTP ${res.status}\uFF0C\u8FD4\u56DE\u7684\u4E0D\u662F JSON\uFF08\u7AD9\u70B9\u53EF\u80FD\u6539\u7248\u6216\u8981\u6C42\u9A8C\u8BC1\uFF09`, "network");
      }
      return { status: res.status, obj };
    }
    /** `/config` 不带 `__puus` 请求，网盘用 `__pus` 重发新的 `__puus`（AList quark_uc refreshPuus）。 */
    async refresh() {
      this.refreshed = true;
      const full = this.cookie;
      const jar = parseCookies(full);
      jar.delete("__puus");
      this.cookie = formatCookies(jar);
      try {
        await this.once("\u5237\u65B0\u4F1A\u8BDD", "GET", `${DRIVE_BASE}/1/clouddrive/config?pr=ucpro&fr=pc&uc_param_str=`, void 0);
      } catch {
      }
      if (!parseCookies(this.cookie).get("__puus")) this.cookie = full;
    }
    /** 调用 drive-pc 接口；登录失效时刷新会话后重试一次。返回响应对象（不检查 code）。 */
    async drive(stage, method, path, query, body) {
      let url = `${DRIVE_BASE}${path}?pr=ucpro&fr=pc&uc_param_str=`;
      for (const [k, v] of Object.entries(query)) url += `&${encodeURIComponent(k)}=${encodeURIComponent(v)}`;
      for (; ; ) {
        const { status, obj } = await this.once(stage, method, url, body);
        if (loggedOut(status, obj) && this.cookie !== "" && !this.refreshed) {
          await this.refresh();
          continue;
        }
        return obj;
      }
    }
    async data(stage, method, path, query, body) {
      const obj = await this.drive(stage, method, path, query, body);
      if (codeOf(obj) !== 0) throw driveError(stage, obj);
      return { data: obj.data, obj };
    }
    /** 分享标识 + 提取码 → stoken。 */
    async shareToken(key, password) {
      const { data } = await this.data("\u8BFB\u53D6\u5206\u4EAB", "POST", "/1/clouddrive/share/sharepage/token", {}, {
        pwd_id: key,
        passcode: password,
        support_visit_limit_private_share: true
      });
      const stoken = asString(asObject(data)?.stoken);
      if (!stoken) throw new SiteError(SITE_NAME5, "\u8BFB\u53D6\u5206\u4EAB", "\u672A\u8FD4\u56DE stoken", "network");
      return stoken;
    }
    /** 列分享目录的一页；last 表示最后一页。 */
    async sharePage(key, stoken, dir, page) {
      const { data, obj } = await this.data("\u8BFB\u53D6\u5206\u4EAB\u76EE\u5F55", "GET", "/1/clouddrive/share/sharepage/detail", {
        pwd_id: key,
        stoken,
        pdir_fid: dir,
        force: "0",
        ver: "2",
        _page: String(page),
        _size: String(PAGE_SIZE3),
        _fetch_banner: "0",
        _fetch_share: "0",
        _fetch_total: "1",
        _sort: "file_type:asc,file_name:asc"
      });
      const list = asArray(asObject(data)?.list);
      const files = [];
      for (const v of list) {
        const it = asObject(v);
        if (!it) continue;
        const fid = asString(it.fid);
        const name = asString(it.file_name);
        if (!fid || !name) continue;
        const isDir = it.dir === true;
        const size = asNumber(it.size);
        files.push({
          fid,
          name,
          isDir,
          size: !isDir && size !== null && size >= 0 ? size : -1,
          parent: dir,
          fidToken: asString(it.share_fid_token)
        });
      }
      let last = list.length < PAGE_SIZE3;
      const total = asNumber(asObject(obj.metadata)?._total);
      if (total !== null && page * PAGE_SIZE3 >= total) last = true;
      return { files, last };
    }
    /** 递归列出 dir 下所有文件（广度优先）。超出请求或文件数上限给出明确错误。 */
    async listTree(key, stoken, dir) {
      const out = [];
      const queue = [{ fid: dir, dirs: [] }];
      let requests = 0;
      const tooBig = () => new SiteError(SITE_NAME5, "\u8BFB\u53D6\u5206\u4EAB\u76EE\u5F55", `\u5185\u5BB9\u8FC7\u591A\uFF08\u8D85\u8FC7 ${MAX_LIST_REQUESTS3} \u6B21\u5217\u76EE\u5F55\u8BF7\u6C42\u6216 ${MAX_FILES} \u4E2A\u6587\u4EF6\uFF09\uFF0C\u8BF7\u8FDB\u5165\u5B50\u76EE\u5F55\u540E\u5206\u6279\u4E0B\u8F7D`, "limit");
      for (let head = 0; head < queue.length; head++) {
        const cur = queue[head];
        for (let page = 1; ; page++) {
          if (++requests > MAX_LIST_REQUESTS3) throw tooBig();
          const { files, last } = await this.sharePage(key, stoken, cur.fid, page);
          for (const f of files) {
            if (f.isDir) queue.push({ fid: f.fid, dirs: [...cur.dirs, f.name] });
            else if (out.push({ ...f, dirs: cur.dirs }) > MAX_FILES) throw tooBig();
          }
          if (last) break;
        }
      }
      return out;
    }
    /** 在 parent 目录里按 fid 找文件（二段解析）。 */
    async findShareFile(key, stoken, parent, fid) {
      for (let page = 1; page <= MAX_FIND_PAGES; page++) {
        const { files, last } = await this.sharePage(key, stoken, parent, page);
        const hit = files.find((f) => f.fid === fid);
        if (hit) {
          if (hit.isDir) throw new SiteError(SITE_NAME5, "\u8BFB\u53D6\u5206\u4EAB\u76EE\u5F55", "\u76EE\u6807\u662F\u6587\u4EF6\u5939\uFF0C\u4E0D\u80FD\u76F4\u63A5\u4E0B\u8F7D", "unsupported");
          return hit;
        }
        if (last) break;
      }
      throw new SiteError(SITE_NAME5, "\u8BFB\u53D6\u5206\u4EAB\u76EE\u5F55", "\u5206\u4EAB\u4E2D\u627E\u4E0D\u5230\u8BE5\u6587\u4EF6\uFF08\u5206\u4EAB\u5185\u5BB9\u53EF\u80FD\u5DF2\u53D8\u66F4\uFF09", "notFound");
    }
    async download(body) {
      const { data } = await this.data("\u83B7\u53D6\u76F4\u94FE", "POST", "/1/clouddrive/file/download", { sys: "win32", ve: "3.23.2" }, body);
      const it = asObject(asArray(data)[0]);
      if (!it) throw new SiteError(SITE_NAME5, "\u83B7\u53D6\u76F4\u94FE", "\u672A\u8FD4\u56DE\u4E0B\u8F7D\u5730\u5740", "network");
      const url = asString(it.download_url);
      if (!parseUrl(url)) throw new SiteError(SITE_NAME5, "\u83B7\u53D6\u76F4\u94FE", "\u8FD4\u56DE\u7684\u4E0B\u8F7D\u5730\u5740\u65E0\u6548", "network");
      const size = asNumber(it.size);
      return { url, name: asString(it.file_name), size: size !== null && size >= 0 ? size : -1 };
    }
    /** 带分享凭证免转存取链。 */
    downloadShared(key, stoken, f) {
      return this.download({ fids: [f.fid], fids_token: [f.fidToken], pwd_id: key, stoken, speedup_session: "", token: "" });
    }
    /** 转存到账号临时目录，取账号自己那份文件的直链。副本保留（删源后直链是否有效未验证），过期副本由 purgeScratch 清理。 */
    async downloadViaTransfer(key, stoken, f) {
      const root = await this.scratchRoot(true);
      const dir = await this.mkdir(root, scratchName());
      const { data } = await this.data("\u8F6C\u5B58\u6587\u4EF6", "POST", "/1/clouddrive/share/sharepage/save", {}, {
        fid_list: [f.fid],
        fid_token_list: [f.fidToken],
        to_pdir_fid: dir,
        pwd_id: key,
        stoken,
        pdir_fid: f.parent,
        scene: "link"
      });
      const task = asString(asObject(data)?.task_id);
      if (!task) throw new SiteError(SITE_NAME5, "\u8F6C\u5B58\u6587\u4EF6", "\u672A\u8FD4\u56DE\u4EFB\u52A1", "network");
      const fid = await this.waitSave(task);
      return this.download({ fids: [fid] });
    }
    async waitSave(task) {
      for (let i = 0; i < TASK_POLLS; i++) {
        const { data } = await this.data("\u8F6C\u5B58\u6587\u4EF6", "GET", "/1/clouddrive/task", { task_id: task, retry_index: String(i) });
        const m = asObject(data);
        const status = asNumber(m?.status);
        if (status === 2) {
          const fid = asString(asArray(asObject(m?.save_as)?.save_as_top_fids)[0]);
          if (!fid) throw new SiteError(SITE_NAME5, "\u8F6C\u5B58\u6587\u4EF6", "\u4EFB\u52A1\u672A\u8FD4\u56DE\u65B0\u6587\u4EF6", "network");
          return fid;
        }
        if (status === 3) throw driveError("\u8F6C\u5B58\u6587\u4EF6", { code: -1, message: asString(m?.message) || "\u8F6C\u5B58\u4EFB\u52A1\u5931\u8D25" });
      }
      throw new SiteError(SITE_NAME5, "\u8F6C\u5B58\u6587\u4EF6", "\u7B49\u5F85\u8F6C\u5B58\u8D85\u65F6", "network");
    }
    async ownPage(dir, page) {
      const { data } = await this.data("\u8BFB\u53D6\u8D26\u53F7\u76EE\u5F55", "GET", "/1/clouddrive/file/sort", {
        pdir_fid: dir,
        _page: String(page),
        _size: String(PAGE_SIZE3),
        _fetch_total: "1",
        _fetch_sub_dirs: "0",
        _sort: "file_type:asc,file_name:asc"
      });
      const list = asArray(asObject(data)?.list);
      const files = list.flatMap((v) => {
        const it = asObject(v);
        const fid = asString(it?.fid);
        return it && fid ? [{ fid, name: asString(it.file_name), isDir: it.dir === true }] : [];
      });
      return { files, last: list.length < PAGE_SIZE3 };
    }
    async scratchRoot(create) {
      for (let page = 1; page <= ROOT_PAGES; page++) {
        const { files, last } = await this.ownPage("0", page);
        const hit = files.find((f) => f.isDir && f.name === SCRATCH_ROOT2);
        if (hit) return hit.fid;
        if (last) break;
      }
      return create ? this.mkdir("0", SCRATCH_ROOT2) : "";
    }
    async mkdir(parent, name) {
      const { data } = await this.data("\u521B\u5EFA\u4E34\u65F6\u76EE\u5F55", "POST", "/1/clouddrive/file", {}, {
        pdir_fid: parent,
        file_name: name,
        dir_path: "",
        dir_init_lock: false
      });
      const fid = asString(asObject(data)?.fid);
      if (!fid) throw new SiteError(SITE_NAME5, "\u521B\u5EFA\u4E34\u65F6\u76EE\u5F55", "\u672A\u8FD4\u56DE\u76EE\u5F55\u6807\u8BC6", "network");
      return fid;
    }
    /** 删除超过 TTL 的转存副本目录；其他条目不动。 */
    async purgeScratch(nowSec) {
      const root = await this.scratchRoot(false);
      if (!root) return;
      const stale = [];
      for (let page = 1; page <= ROOT_PAGES; page++) {
        const { files, last } = await this.ownPage(root, page);
        for (const f of files) if (f.isDir && scratchExpired(f.name, nowSec)) stale.push(f.fid);
        if (last) break;
      }
      if (stale.length === 0) return;
      await this.data("\u6E05\u7406\u4E34\u65F6\u76EE\u5F55", "POST", "/1/clouddrive/file/delete", {}, { action_type: 2, filelist: stale, exclude_fids: [] });
    }
    /** 会员等级 `member_type`；查询失败为 ""。 */
    async memberType() {
      try {
        const { data } = await this.data("\u4F1A\u5458\u4FE1\u606F", "GET", "/1/clouddrive/member", { fetch_subscribe: "true" });
        return asString(asObject(data)?.member_type);
      } catch {
        return "";
      }
    }
  };
  function scratchName() {
    let hex = "";
    for (let i = 0; i < 8; i++) hex += Math.floor(Math.random() * 16).toString(16);
    return `${Math.floor(Date.now() / 1e3)}-${hex}`;
  }
  function scratchExpired(name, nowSec) {
    const m = /^(\d{1,12})-/.exec(name);
    return m !== null && nowSec - Number(m[1]) > SCRATCH_TTL_SEC;
  }
  function sizedSegments(want, size) {
    if (size < 0) return want;
    const n = Math.ceil(size / (4 << 20));
    return Math.max(1, Math.min(want, n));
  }
  function memberThreads(memberType) {
    switch (memberType) {
      case "SUPER_VIP":
      case "EXP_SVIP":
      case "Z_VIP":
        return 32;
      case "VIP":
      case "EXP_VIP":
        return 16;
      default:
        return 8;
    }
  }

  // src/sites/quark/link.ts
  var QUARK_HOST = "pan.quark.cn";
  var SITE_ID4 = "quark";
  var SHARE_KEY_RE = /^[A-Za-z0-9]{6,40}$/;
  var FID_RE = /^[A-Za-z0-9]{1,64}$/;
  var MAX_PASSWORD_CHARS = 32;
  function isShareKey(key) {
    return SHARE_KEY_RE.test(key);
  }
  function isFid(fid) {
    return FID_RE.test(fid);
  }
  function readTaskParams(params) {
    const key = params.key ?? "";
    const password = params.pwd ?? "";
    const dir = params.dir || "0";
    if (!isShareKey(key) || !isFid(dir) || password.length > MAX_PASSWORD_CHARS) return null;
    return { key, password, dir };
  }

  // src/sites/quark/index.ts
  var ITEM_RE2 = /^([A-Za-z0-9]{1,64}):([A-Za-z0-9]{1,64})$/;
  function transferMayHelp(e) {
    return e instanceof QuarkError && (e.kind === "other" || e.kind === "limit");
  }
  async function directLink2(conn, key, stoken, file) {
    let dl;
    let transferred = false;
    try {
      dl = await conn.downloadShared(key, stoken, file);
    } catch (e) {
      if (!transferMayHelp(e)) throw e;
      dl = await conn.downloadViaTransfer(key, stoken, file);
      transferred = true;
    }
    if (transferred) {
      try {
        await conn.purgeScratch(Math.floor(Date.now() / 1e3));
      } catch {
      }
    }
    const size = dl.size >= 0 ? dl.size : file.size;
    const threads = sizedSegments(memberThreads(await conn.memberType()), size);
    const fileName = safeFileName(dl.name || file.name);
    return {
      url: dl.url,
      fileName,
      ...size >= 0 ? { totalBytes: size } : {},
      request: {
        // 直链只认账号会话：最小化为 __pus + __puus，同取链 UA 与 pan.quark.cn Referer。
        cookies: conn.directCookie(),
        userAgent: QUARK_UA,
        referrer: QUARK_REFERER,
        segments: threads,
        maxConnections: threads
      }
    };
  }
  async function resolve3(input) {
    const task = parseTaskUrl(input.parsed);
    const params = task ? readTaskParams(task.params) : null;
    if (!params) throw new SiteError(SITE_NAME5, "\u8BC6\u522B\u4EFB\u52A1", "\u4EFB\u52A1\u94FE\u63A5\u65E0\u6548\uFF0C\u8BF7\u4ECE\u5206\u4EAB\u9875\u91CD\u65B0\u53D1\u8D77", "unsupported");
    if (!parseCookies(input.cookies).get("__pus")) {
      throw new SiteError(SITE_NAME5, "\u8BC6\u522B\u4EFB\u52A1", "\u6CA1\u6709\u5938\u514B\u767B\u5F55\u6001\uFF0C\u8BF7\u5148\u5728\u6D4F\u89C8\u5668\u767B\u5F55 pan.quark.cn\uFF0C\u518D\u4ECE\u5206\u4EAB\u9875\u53D1\u8D77", "login");
    }
    const conn = new Conn(input.cookies);
    const stoken = await conn.shareToken(params.key, params.password);
    if (input.resolverItem) {
      const m = ITEM_RE2.exec(input.resolverItem);
      if (!m) throw new SiteError(SITE_NAME5, "\u8BC6\u522B\u6761\u76EE", "\u6761\u76EE\u6807\u8BC6\u65E0\u6548", "unsupported");
      const file = await conn.findShareFile(params.key, stoken, m[1], m[2]);
      return directLink2(conn, params.key, stoken, file);
    }
    const files = await conn.listTree(params.key, stoken, params.dir);
    if (files.length === 1) return directLink2(conn, params.key, stoken, files[0]);
    const name = `\u5938\u514B\u5206\u4EAB-${params.key}`;
    return manifestResult(
      SITE_NAME5,
      name,
      files.map((f) => ({ id: `${f.parent}:${f.fid}`, name: f.name, dirs: f.dirs, ...f.size >= 0 ? { size: f.size } : {} }))
    );
  }
  var quark = {
    id: SITE_ID4,
    name: SITE_NAME5,
    claims: (url) => url.host === QUARK_HOST && parseTaskUrl(url)?.siteId === SITE_ID4,
    resolve: resolve3
  };

  // src/core/registry.ts
  var SITES = [baidu, quark, pan123, pan115, lanzou, bilibili, pixiv];

  // src/resolve.ts
  defineResolver(async (ctx) => {
    const parsed = parseUrl(ctx.url);
    if (!parsed) return null;
    const site = SITES.find((s) => s.claims(parsed));
    if (site) {
      return site.resolve({
        taskId: ctx.taskId,
        url: ctx.url,
        parsed,
        cookies: ctx.cookies ?? "",
        userAgent: ctx.userAgent ?? "",
        referrer: ctx.referrer ?? "",
        resolverItem: ctx.resolverItem ?? ""
      });
    }
    if (parseTaskUrl(parsed)) throw new SiteError("\u8D26\u53F7\u76F4\u94FE", "\u8BC6\u522B\u4EFB\u52A1", "\u4E0D\u652F\u6301\u7684\u4EFB\u52A1\u94FE\u63A5\uFF08\u63D2\u4EF6\u7248\u672C\u53EF\u80FD\u5DF2\u66F4\u65B0\uFF0C\u8BF7\u4ECE\u7F51\u9875\u91CD\u65B0\u53D1\u8D77\uFF09", "unsupported");
    return null;
  });
})();
