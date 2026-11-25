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
  var MusicError = class extends Error {
    constructor(source, stage, detail, kind = "other") {
      super(`${source}\xB7${stage}\uFF1A${detail}`);
      this.source = source;
      this.stage = stage;
      this.detail = detail;
      this.kind = kind;
      this.name = "MusicError";
    }
    source;
    stage;
    detail;
    kind;
  };

  // src/core/http.ts
  function asObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value) ? value : null;
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

  // src/core/sources.ts
  function fragmentParts(fragment) {
    const q = fragment.indexOf("?");
    return q < 0 ? { path: fragment, query: "" } : { path: fragment.slice(0, q), query: fragment.slice(q + 1) };
  }
  var netease = {
    id: "netease",
    name: "\u7F51\u6613\u4E91\u97F3\u4E50",
    short: "\u7F51\u6613\u4E91",
    hosts: ["music.163.com", "y.music.163.com"],
    idRe: /^\d{1,15}$/,
    songUrl: (id) => `https://music.163.com/#/song?id=${id}`,
    parse(url) {
      for (const part of [{ path: url.path, query: url.query }, fragmentParts(url.fragment)]) {
        if (/^(?:\/m)?\/song\/?$/.test(part.path)) {
          const id = parseQuery(part.query).id ?? "";
          if (netease.idRe.test(id)) return id;
        }
        const m = /^\/song\/(\d{1,15})(?:[/?]|$)/.exec(part.path);
        if (m) return m[1];
      }
      return null;
    }
  };
  var qq = {
    id: "qq",
    name: "QQ\u97F3\u4E50",
    short: "QQ\u97F3\u4E50",
    hosts: ["y.qq.com", "i.y.qq.com"],
    idRe: /^[0-9A-Za-z]{14}$/,
    songUrl: (id) => `https://y.qq.com/n/ryqq/songDetail/${id}`,
    parse(url) {
      const m = /^\/n\/(?:ryqq\w*\/songDetail|yqq\/song)\/([0-9A-Za-z]{14})(?:\.html)?\/?$/.exec(url.path);
      if (m) return m[1];
      if (/^\/v8\/playsong\.html$/.test(url.path)) {
        const mid = parseQuery(url.query).songmid ?? "";
        if (qq.idRe.test(mid)) return mid;
      }
      return null;
    }
  };
  var kugou = {
    id: "kugou",
    name: "\u9177\u72D7\u97F3\u4E50",
    short: "\u9177\u72D7",
    hosts: ["www.kugou.com", "kugou.com"],
    idRe: /^[0-9A-Fa-f]{32}$/,
    songUrl: (id) => `https://www.kugou.com/song/#hash=${id.toUpperCase()}`,
    parse(url) {
      if (!/^\/song\/?$/.test(url.path)) return null;
      const hash = parseQuery(url.fragment).hash ?? parseQuery(url.query).hash ?? "";
      return kugou.idRe.test(hash) ? hash.toUpperCase() : null;
    }
  };
  var kuwo = {
    id: "kuwo",
    name: "\u9177\u6211\u97F3\u4E50",
    short: "\u9177\u6211",
    hosts: ["www.kuwo.cn", "kuwo.cn"],
    idRe: /^\d{1,15}$/,
    songUrl: (id) => `https://www.kuwo.cn/play_detail/${id}`,
    parse(url) {
      const m = /^\/play_detail\/(\d{1,15})\/?$/.exec(url.path);
      return m ? m[1] : null;
    }
  };
  var SOURCES = [qq, netease, kugou, kuwo];
  function sourceOf(id) {
    return SOURCES.find((s) => s.id === id) ?? null;
  }
  function sourceForHost(host) {
    const h = host.toLowerCase();
    return SOURCES.find((s) => s.hosts.includes(h)) ?? null;
  }

  // src/core/task.ts
  var SITE_ORIGIN = "https://www.jbsou.cn";
  var SITE_HOSTS = ["www.jbsou.cn", "jbsou.cn"];
  function parseSongUrl(url) {
    const u = parseUrl(url);
    if (!u) return null;
    if (SITE_HOSTS.includes(u.host)) {
      if (u.path !== "/") return null;
      const q = parseQuery(u.query);
      const source2 = sourceOf(q.type);
      const id2 = q.id ?? "";
      if (!source2 || !source2.idRe.test(id2)) return null;
      return { source: source2.id, id: id2 };
    }
    const source = sourceForHost(u.host);
    const id = source?.parse(u) ?? null;
    return source && id ? { source: source.id, id } : null;
  }
  function isMusicPage(url) {
    return SITE_HOSTS.includes(url.host) && url.path === "/" || SOURCES.some((s) => s.hosts.includes(url.host));
  }

  // src/core/jbsou.ts
  var SITE = "\u714E\u997C\u641C";
  var USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36";
  var PAGE_SIZE = 10;
  var VISIT_KEY = "jbsou.visit";
  var VISIT_MAX_AGE_S = 43200;
  var VISIT_MARGIN_MS = 10 * 6e4;
  var AUDIO_PATH_RE = /^api\.php\?get=url&[A-Za-z0-9_=&%.\/+-]+$/;
  function siteUrl(path) {
    return `${SITE_ORIGIN}/${path}`;
  }
  function cleanSiteError(text) {
    const i = text.search(/[\u4e00-\u9fff]/);
    return (i >= 0 ? text.slice(i) : text).trim();
  }
  async function storedVisit() {
    const raw = await flux.storage.get(VISIT_KEY);
    if (!raw) return null;
    try {
      const v = JSON.parse(raw);
      if (typeof v.cookie === "string" && typeof v.expires === "number" && v.expires > Date.now()) return v.cookie;
    } catch {
    }
    return null;
  }
  async function freshVisit() {
    const res = await flux.fetch({ url: `${SITE_ORIGIN}/`, headers: { "User-Agent": USER_AGENT, Accept: "text/html" } });
    if (res.status !== 200) throw new MusicError(SITE, "\u8BBF\u95EE\u9A8C\u8BC1", `\u7AD9\u70B9\u6682\u65F6\u4E0D\u53EF\u7528\uFF08HTTP ${res.status}\uFF09`, "network");
    const m = /mk_visit=([A-Za-z0-9_-]{4,200})/.exec(res.body);
    if (!m) throw new MusicError(SITE, "\u8BBF\u95EE\u9A8C\u8BC1", "\u7AD9\u70B9\u7684\u8BBF\u95EE\u9A8C\u8BC1\u5DF2\u6539\u7248\uFF0C\u6682\u65F6\u65E0\u6CD5\u641C\u7D22", "unsupported");
    const age = Number(/max-age=(\d{1,7})/.exec(res.body)?.[1] ?? VISIT_MAX_AGE_S);
    const cookie = `mk_visit=${m[1]}`;
    const visit = { cookie, expires: Date.now() + Math.min(age, VISIT_MAX_AGE_S) * 1e3 - VISIT_MARGIN_MS };
    await flux.storage.set(VISIT_KEY, JSON.stringify(visit));
    return cookie;
  }
  function toSong(source, raw) {
    const o = asObject(raw);
    if (!o) return null;
    const id = typeof o.songid === "number" ? String(o.songid) : typeof o.songid === "string" ? o.songid : "";
    const audioPath = typeof o.url === "string" ? o.url : "";
    if (!source.idRe.test(id) || !AUDIO_PATH_RE.test(audioPath)) return null;
    const name = typeof o.name === "string" && o.name.trim() !== "" ? o.name.trim() : "\u672A\u77E5\u6B4C\u66F2";
    const artist = typeof o.artist === "string" ? o.artist.trim() : "";
    return { source: source.id, id, name, artist, link: source.songUrl(id), audioPath };
  }
  async function querySongs(sourceId, input, filter, page) {
    const source = sourceOf(sourceId);
    if (!source) throw new MusicError(SITE, "\u641C\u7D22", `\u4E0D\u652F\u6301\u7684\u97F3\u4E50\u6E90\uFF1A${sourceId}`, "unsupported");
    let cookie = await storedVisit() ?? await freshVisit();
    for (let attempt = 0; ; attempt++) {
      const res = await flux.fetch({
        method: "POST",
        url: `${SITE_ORIGIN}/`,
        headers: {
          "User-Agent": USER_AGENT,
          "X-Requested-With": "XMLHttpRequest",
          "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
          Accept: "application/json, text/javascript, */*; q=0.01",
          Origin: SITE_ORIGIN,
          Referer: `${SITE_ORIGIN}/`,
          Cookie: cookie
        },
        body: encodeQuery({ input, filter, type: source.id, page: String(page) })
      });
      if (res.status >= 500) throw new MusicError(source.name, "\u641C\u7D22", `\u89E3\u6790\u7AD9\u6682\u65F6\u4E0D\u53EF\u7528\uFF08HTTP ${res.status}\uFF09`, "network");
      if (res.truncated) throw new MusicError(source.name, "\u641C\u7D22", "\u89E3\u6790\u7AD9\u8FD4\u56DE\u7684\u6570\u636E\u8FC7\u5927", "network");
      let body = null;
      try {
        body = asObject(JSON.parse(res.body));
      } catch {
        body = null;
      }
      const code = body?.code;
      const error = typeof body?.error === "string" ? cleanSiteError(body.error) : "";
      const needVisit = body === null || code === 403 && error.includes("\u5237\u65B0");
      if (needVisit && attempt === 0) {
        cookie = await freshVisit();
        continue;
      }
      if (body === null) throw new MusicError(source.name, "\u641C\u7D22", `\u89E3\u6790\u7AD9\u8FD4\u56DE\u4E86\u65E0\u6CD5\u8BC6\u522B\u7684\u5185\u5BB9\uFF08HTTP ${res.status}\uFF09`, "network");
      if (code === 404) return { songs: [], hasMore: false };
      if (code !== 200) throw new MusicError(source.name, "\u641C\u7D22", error || `\u89E3\u6790\u7AD9\u8FD4\u56DE\u9519\u8BEF ${String(code)}`, "other");
      const list = Array.isArray(body.data) ? body.data : [];
      const songs = [];
      for (const raw of list) {
        const song = toSong(source, raw);
        if (song) songs.push(song);
      }
      return { songs, hasMore: filter === "name" && list.length >= PAGE_SIZE };
    }
  }
  async function lookupSong(ref) {
    const source = sourceOf(ref.source);
    if (!source || !source.idRe.test(ref.id)) throw new MusicError(SITE, "\u8BC6\u522B\u6B4C\u66F2", "\u6B4C\u66F2\u6807\u8BC6\u65E0\u6548", "unsupported");
    const { songs } = await querySongs(source.id, ref.id, "id", 1);
    const song = songs.find((s) => s.id.toLowerCase() === ref.id.toLowerCase()) ?? songs[0];
    if (!song) throw new MusicError(source.name, "\u67E5\u627E\u6B4C\u66F2", "\u6CA1\u6709\u627E\u5230\u8FD9\u9996\u6B4C\uFF08\u53EF\u80FD\u5DF2\u4E0B\u67B6\uFF09", "notFound");
    return song;
  }
  var EXT_BY_TYPE = [
    [/flac/, "flac"],
    [/(mp4|m4a|aac)/, "m4a"],
    [/ogg/, "ogg"],
    [/wav/, "wav"],
    [/(mpeg|mp3)/, "mp3"]
  ];
  function extForContentType(type) {
    const t = type.toLowerCase();
    for (const [re, ext] of EXT_BY_TYPE) if (re.test(t)) return ext;
    return "mp3";
  }
  async function probeAudio(song) {
    const source = sourceOf(song.source);
    const res = await flux.fetch({ url: siteUrl(song.audioPath), headers: { "User-Agent": USER_AGENT, Range: "bytes=0-1" } });
    const type = (res.headers["content-type"] ?? "").toLowerCase();
    if (type.startsWith("text/") || type.includes("json") || res.body.includes("\u83B7\u53D6\u5931\u8D25")) {
      throw new MusicError(source.name, "\u83B7\u53D6\u97F3\u6E90", `\u300C${song.name}\u300D\u6682\u65E0\u53EF\u7528\u97F3\u6E90\uFF08\u5E38\u89C1\u4E8E\u7248\u6743\u53D7\u9650\u7684\u539F\u5531\uFF09\uFF0C\u6362\u4E2A\u7248\u672C\u6216\u97F3\u4E50\u6E90\u8BD5\u8BD5`, "notFound");
    }
    if (res.status !== 200 && res.status !== 206) {
      throw new MusicError(source.name, "\u83B7\u53D6\u97F3\u6E90", `\u97F3\u6E90\u670D\u52A1\u5668\u8FD4\u56DE HTTP ${res.status}`, "network");
    }
    return { ext: extForContentType(type) };
  }

  // src/core/names.ts
  var MAX_BASE_CHARS = 150;
  function cleanName(text) {
    const s = text.replace(/[\u0000-\u001f\u007f]/g, "").replace(/[\\/:*?"<>|]/g, "_").replace(/\s+/g, " ").replace(/\.{2,}/g, ".").trim().replace(/^\.+|\.+$/g, "");
    return s === "" ? "\u672A\u547D\u540D" : s;
  }
  function songBaseName(name, artist) {
    const title = cleanName(name);
    const who = artist.trim() === "" ? "" : cleanName(artist);
    const base = who === "" || who === "\u672A\u547D\u540D" ? title : `${title} - ${who}`;
    return Array.from(base).slice(0, MAX_BASE_CHARS).join("").trim();
  }

  // src/resolve.ts
  defineResolver(async (ctx) => {
    const ref = parseSongUrl(ctx.url);
    if (!ref) {
      const url = parseUrl(ctx.url);
      if (url && isMusicPage(url)) throw new MusicError("\u5168\u7F51\u97F3\u4E50", "\u8BC6\u522B\u94FE\u63A5", "\u53EA\u652F\u6301\u5355\u66F2\u9875\u9762\u94FE\u63A5", "unsupported");
      return null;
    }
    const song = await lookupSong(ref);
    const base = songBaseName(song.name, song.artist);
    const request = { cookies: "", userAgent: USER_AGENT };
    const { ext } = await probeAudio(song);
    return { url: siteUrl(song.audioPath), fileName: `${base}.${ext}`, request };
  });
})();
