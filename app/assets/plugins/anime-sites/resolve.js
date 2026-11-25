/*
 * 动漫站点页面级解析 —— NetPulse 内置站点解析器
 * 入口：globalThis.resolve(ctx)（经典脚本，由宿主注入到沙箱）
 *
 * 设计要点：
 *   1. 这里接收的是「网页地址」（详情页 / 播放页），而不是已经嗅探到的媒体直链。
 *      很多站点把播放地址藏在 JS 变量、Next.js RSC 数据或二次加密里，必须回到页面取。
 *   2. 解析完成后统一返回 { url, fileName, extraHeaders }：Referer / User-Agent
 *      随结果一起交给下载引擎，避免下载阶段触发防盗链。
 *   3. 站点一律用「主机名」判断，源码中不出现任何完整页面地址。
 *   4. 分段下载、AES-128 解密、合并落盘仍由引擎负责，插件只负责「找到正确的播放列表」。
 */

var LOG = "anime-sites: ";
function logI(m) { try { flux.logger.info(LOG + m); } catch (e) {} }
function logW(m) { try { flux.logger.warn(LOG + m); } catch (e) {} }

/* ================================================================== *
 * 一、通用工具
 * ================================================================== */

var RE_URL = /^([a-zA-Z][a-zA-Z0-9+.\-]*):\/\/([^\/?#]*)([^?#]*)/;

function hostOf(raw) {
  var m = RE_URL.exec(String(raw == null ? "" : raw));
  return m ? m[2].toLowerCase() : "";
}

function originOf(raw) {
  var m = RE_URL.exec(String(raw == null ? "" : raw));
  return m ? m[1].toLowerCase() + "://" + m[2] : "";
}

function pathOf(raw) {
  var m = RE_URL.exec(String(raw == null ? "" : raw));
  return m ? m[3] : "";
}

function cleanSpace(s) {
  return String(s == null ? "" : s).replace(/\s+/g, " ").trim();
}

function htmlTitle(html) {
  var m = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html || "");
  return m ? cleanSpace(m[1]) : "";
}

var RE_EPISODE = /第\s*[0-9一二三四五六七八九十百]+\s*[集话話期]/;

/* 把页面标题收拾成「番剧名 第X集」这样的任务名。 */
function tidyName(raw) {
  var s = cleanSpace(raw);
  s = s.replace(/^正在播放\s*/, "");
  var bm = /^《([^》]+)》\s*([\s\S]*)$/.exec(s);
  if (bm) s = bm[1] + " " + bm[2];

  /* 有明确集数时，直接截到集数为止，丢掉后面的营销长尾。 */
  var ep = /^(.*?第\s*[0-9一二三四五六七八九十百]+\s*[集话話期])/.exec(s);
  if (ep) {
    s = ep[1];
  } else {
    var parts = s.split(/\s+[-|·｜]\s+/);
    if (parts.length > 1) {
      if (!RE_EPISODE.test(parts[0]) && RE_EPISODE.test(parts[1] || "")) s = parts[0] + " " + parts[1];
      else s = parts[0];
    }
  }

  s = s.replace(/[_\u3000]+/g, " ").replace(/\s+/g, " ").trim();
  /* 「番剧名 01 日番」这类：把孤立的期号补成「第01集」。 */
  s = s.replace(/\s+(\d{1,3})\s+\S+\s*$/, " 第$1集");
  s = s.replace(/\s+(\d{1,3})\s*$/, " 第$1集");
  /* 去掉尾部年份括号，让名字更干净。 */
  s = s.replace(/\s*\((19|20)\d{2}\)\s*$/, "");
  return s;
}

function sanitizeName(n) {
  n = String(n == null ? "" : n).replace(/[\\\/:*?"<>|]/g, "_");
  n = n.replace(/[\u0000-\u001f\u007f]/g, " ");
  n = n.replace(/\.{2,}/g, ".");
  n = n.replace(/\s+/g, " ").trim();
  n = n.replace(/^[.\s]+/, "").replace(/[.\s]+$/, "");
  if (n.length > 100) n = n.slice(0, 100).replace(/[.\s]+$/, "");
  if (!n) n = "video";
  if (/^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i.test(n)) n = "_" + n;
  return n;
}

function withExt(base, ext) {
  return sanitizeName(base) + (ext || ".mp4");
}

/* 还原 JS 字符串字面量里的转义：\uXXXX、\/、\"、\\ */
function jsUnescape(s) {
  return String(s == null ? "" : s)
    .replace(/\\u([0-9a-fA-F]{4})/g, function (_, h) { return String.fromCharCode(parseInt(h, 16)); })
    .replace(/\\\//g, "/")
    .replace(/\\"/g, "\"")
    .replace(/\\\\/g, "\\");
}

/* 从 JSON 文本里抠出某个键的字符串值（避免依赖 JSON.parse 的宽容度差异）。 */
function jsonStringField(text, key) {
  var re = new RegExp("\"" + key + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
  var m = re.exec(String(text || ""));
  return m ? jsUnescape(m[1]) : "";
}

/* ================================================================== *
 * 二、Base64 / UTF-8
 * ================================================================== */

var B64C = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function b64Bytes(s) {
  s = String(s == null ? "" : s).replace(/[^A-Za-z0-9+\/=]/g, "");
  var out = [], buf = 0, bits = 0;
  for (var i = 0; i < s.length; i++) {
    var c = s.charAt(i);
    if (c === "=") break;
    var v = B64C.indexOf(c);
    if (v < 0) continue;
    buf = (buf << 6) | v;
    bits += 6;
    if (bits >= 8) { bits -= 8; out.push((buf >> bits) & 255); }
  }
  return out;
}

function bytesToStr(a) {
  var s = "";
  for (var i = 0; i < a.length; i++) s += String.fromCharCode(a[i]);
  return s;
}

/* UTF-8 字节数组 → 字符串；失败时退回 latin1。 */
function bytesToUtf8(a) {
  try { return decodeURIComponent(escape(bytesToStr(a))); }
  catch (e) { return bytesToStr(a); }
}

/* ================================================================== *
 * 三、MD5（纯 JS，输入为短字符串，按 UTF-8 编码）
 * ================================================================== */

function md5Hex(s) {
  var u = [], i, c;
  for (i = 0; i < s.length; i++) {
    c = s.charCodeAt(i);
    if (c < 128) u.push(c);
    else if (c < 2048) u.push(192 | (c >> 6), 128 | (c & 63));
    else u.push(224 | (c >> 12), 128 | ((c >> 6) & 63), 128 | (c & 63));
  }
  var bits = u.length * 8;
  u.push(0x80);
  while (u.length % 64 !== 56) u.push(0);
  u.push(bits & 255, (bits >>> 8) & 255, (bits >>> 16) & 255, (bits >>> 24) & 255, 0, 0, 0, 0);

  var S = [7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
           5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
           4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
           6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21];
  var K = [];
  for (i = 0; i < 64; i++) K[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) | 0;

  function add(x, y) { return (x + y) | 0; }
  function rol(x, n) { return (x << n) | (x >>> (32 - n)); }

  var a0 = 0x67452301, b0 = 0xefcdab89 | 0, c0 = 0x98badcfe | 0, d0 = 0x10325476;
  for (var off = 0; off < u.length; off += 64) {
    var M = [];
    for (var j = 0; j < 16; j++) {
      M[j] = u[off + 4 * j] | (u[off + 4 * j + 1] << 8) | (u[off + 4 * j + 2] << 16) | (u[off + 4 * j + 3] << 24);
    }
    var A = a0, B = b0, C = c0, D = d0;
    for (i = 0; i < 64; i++) {
      var F, g;
      if (i < 16) { F = (B & C) | (~B & D); g = i; }
      else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
      else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
      else { F = C ^ (B | ~D); g = (7 * i) % 16; }
      var tmp = D; D = C; C = B;
      B = add(B, rol(add(add(A, F), add(K[i], M[g])), S[i]));
      A = tmp;
    }
    a0 = add(a0, A); b0 = add(b0, B); c0 = add(c0, C); d0 = add(d0, D);
  }
  function hx(x) {
    var s = "";
    for (var k = 0; k < 4; k++) s += ("0" + ((x >>> (8 * k)) & 255).toString(16)).slice(-2);
    return s;
  }
  return hx(a0) + hx(b0) + hx(c0) + hx(d0);
}

/* ================================================================== *
 * 四、AES-128-CBC 解密（纯 JS）
 *    沙箱页面不是 secure context，crypto.subtle 不可用，这里自带实现。
 * ================================================================== */

var AES_SBOX = null, AES_INV = null;

(function buildSbox() {
  var p = 1, q = 1, sb = new Array(256), iv = new Array(256);
  do {
    p = (p ^ ((p << 1) & 255) ^ ((p & 128) ? 0x1b : 0)) & 255;
    q ^= (q << 1); q ^= (q << 2); q ^= (q << 4); q &= 255;
    if (q & 128) q ^= 9;
    var x = (q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^
             ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))) & 255;
    x = (x ^ 0x63) & 255;
    sb[p] = x; iv[x] = p;
  } while (p !== 1);
  sb[0] = 0x63; iv[0x63] = 0;
  AES_SBOX = sb; AES_INV = iv;
})();

function aesXtime(a) { return ((a << 1) ^ ((a & 128) ? 0x1b : 0)) & 255; }

function aesMul(a, b) {
  var r = 0;
  while (b) { if (b & 1) r ^= a; a = aesXtime(a); b >>= 1; }
  return r & 255;
}

function aesExpandKey(key) {
  var w = new Array(44), i;
  for (i = 0; i < 4; i++) w[i] = (key[4 * i] << 24) | (key[4 * i + 1] << 16) | (key[4 * i + 2] << 8) | key[4 * i + 3];
  var rc = 1;
  for (i = 4; i < 44; i++) {
    var t = w[i - 1];
    if (i % 4 === 0) {
      t = ((t << 8) | (t >>> 24)) >>> 0;
      t = ((AES_SBOX[(t >>> 24) & 255] << 24) | (AES_SBOX[(t >>> 16) & 255] << 16) |
           (AES_SBOX[(t >>> 8) & 255] << 8) | AES_SBOX[t & 255]) >>> 0;
      t = (t ^ (rc << 24)) >>> 0;
      rc = aesXtime(rc);
    }
    w[i] = (w[i - 4] ^ t) >>> 0;
  }
  return w;
}

function aesDecryptBlock(inBytes, w) {
  var s = inBytes.slice(0, 16);

  function addRoundKey(r) {
    for (var c = 0; c < 4; c++) {
      var word = w[r * 4 + c];
      s[4 * c] ^= (word >>> 24) & 255;
      s[4 * c + 1] ^= (word >>> 16) & 255;
      s[4 * c + 2] ^= (word >>> 8) & 255;
      s[4 * c + 3] ^= word & 255;
    }
  }
  function invShiftRows() {
    var t = s.slice();
    for (var r = 0; r < 4; r++)
      for (var c = 0; c < 4; c++) s[r + 4 * c] = t[r + 4 * ((c - r + 4) % 4)];
  }
  function invSubBytes() {
    for (var i = 0; i < 16; i++) s[i] = AES_INV[s[i]];
  }
  function invMixColumns() {
    for (var c = 0; c < 4; c++) {
      var a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3];
      s[4 * c]     = aesMul(a0, 14) ^ aesMul(a1, 11) ^ aesMul(a2, 13) ^ aesMul(a3, 9);
      s[4 * c + 1] = aesMul(a0, 9)  ^ aesMul(a1, 14) ^ aesMul(a2, 11) ^ aesMul(a3, 13);
      s[4 * c + 2] = aesMul(a0, 13) ^ aesMul(a1, 9)  ^ aesMul(a2, 14) ^ aesMul(a3, 11);
      s[4 * c + 3] = aesMul(a0, 11) ^ aesMul(a1, 13) ^ aesMul(a2, 9)  ^ aesMul(a3, 14);
    }
  }

  addRoundKey(10);
  for (var r = 9; r >= 1; r--) { invShiftRows(); invSubBytes(); addRoundKey(r); invMixColumns(); }
  invShiftRows(); invSubBytes(); addRoundKey(0);
  return s;
}

/* CBC 解密 + PKCS7 去填充，返回明文字节数组。 */
function aesCbcDecrypt(cipher, key, iv) {
  var w = aesExpandKey(key), out = [], prev = iv.slice(0, 16);
  for (var off = 0; off < cipher.length; off += 16) {
    var blk = cipher.slice(off, off + 16);
    if (blk.length < 16) blk = blk.concat(new Array(16 - blk.length).fill(0));
    var d = aesDecryptBlock(blk, w);
    for (var i = 0; i < 16; i++) out.push(d[i] ^ prev[i]);
    prev = blk;
  }
  var pad = out.length ? out[out.length - 1] : 0;
  if (pad > 0 && pad <= 16 && pad <= out.length) out = out.slice(0, out.length - pad);
  return out;
}

/* ================================================================== *
 * 五、HTTP 封装
 * ================================================================== */

async function httpGet(url, headers, timeoutMs) {
  var opt = { url: url, method: "GET", headers: headers || {} };
  if (timeoutMs) opt.timeoutMs = timeoutMs;
  var r = await flux.fetch(opt);
  return {
    status: (r && r.status) || 0,
    body: String((r && r.body) || ""),
    finalUrl: (r && r.finalUrl) || url
  };
}

async function httpPostJson(url, headers, obj, timeoutMs) {
  var h = {}, k;
  for (k in (headers || {})) if (Object.prototype.hasOwnProperty.call(headers, k)) h[k] = headers[k];
  h["Content-Type"] = "application/json";
  var opt = { url: url, method: "POST", headers: h, body: JSON.stringify(obj || {}) };
  if (timeoutMs) opt.timeoutMs = timeoutMs;
  var r = await flux.fetch(opt);
  return {
    status: (r && r.status) || 0,
    body: String((r && r.body) || ""),
    finalUrl: (r && r.finalUrl) || url
  };
}

/* ================================================================== *
 * 六、各站点解析
 * ================================================================== */

/* ---- 6.1 播放器配置型：页面内联 DPlayer 配置，source 就是直链 ---- */
async function resolveInlinePlayerConfig(pageUrl, headers) {
  var resp = await httpGet(pageUrl, headers);
  if (resp.status && (resp.status < 200 || resp.status >= 400)) {
    logW("页面返回 HTTP " + resp.status);
  }
  var html = resp.body;
  if (!html) { logW("页面内容为空"); return null; }

  /* window.MXPRO_DPLAYER_CONFIG = { ... source: "..." ... } */
  var m = /MXPRO_DPLAYER_CONFIG\s*=\s*\{[\s\S]*?\bsource\s*:\s*"((?:[^"\\]|\\.)*)"/.exec(html);
  if (!m) { logW("未找到内联播放器配置"); return null; }

  var url = jsUnescape(m[1]);
  if (!/^https?:\/\//i.test(url)) { logW("播放器配置里的地址不是绝对地址"); return null; }

  var title = tidyName(htmlTitle(html)) || "video";
  var ext = /\.m3u8(\?|$)/i.test(url) ? ".ts" : ".mp4";
  logI("内联播放器配置命中：" + title);
  return { url: url, fileName: withExt(title, ext), extraHeaders: headers };
}

/* ---- 6.2 加密播放器配置型：player_aaaa（Base64 / URL 编码） ---- */

function decodePlayerUrlValue(value, encrypt) {
  var v = String(value == null ? "" : value);
  if (encrypt === 2 || encrypt === "2") {
    return decodeURIComponent(bytesToStr(b64Bytes(v)));
  }
  if (encrypt === 1 || encrypt === "1") {
    return decodeURIComponent(v);
  }
  return "";
}

async function resolvePlayerAaaa(pageUrl, headers) {
  var resp = await httpGet(pageUrl, headers);
  var html = resp.body;
  if (!html) { logW("页面内容为空"); return null; }

  var m = /var\s+player_aaaa\s*=\s*(\{[\s\S]*?\})\s*<\/script>/.exec(html);
  if (!m) { logW("未找到 player_aaaa 配置"); return null; }

  var cfg;
  try { cfg = JSON.parse(m[1]); } catch (e) { logW("player_aaaa 不是合法 JSON"); return null; }

  var encrypt = cfg.encrypt;
  var raw = String(cfg.url || "");

  /* 三段式加密（站点自定义格式）交给专门的分支处理。 */
  if (encrypt === 3 || encrypt === "3" || /^[a-z0-9]+_/i.test(raw) && raw.split("_").length === 4) {
    var deep = await resolveLayeredEncryption(raw, pageUrl, headers);
    if (deep) return deep;
  }

  var url = "";
  try { url = decodePlayerUrlValue(raw, encrypt); } catch (e) { logW("解码 player_aaaa 失败"); return null; }
  if (!url) { logW("解析出的地址为空"); return null; }

  var title = tidyName(htmlTitle(html)) || "video";
  var ext = /\.m3u8(\?|$)/i.test(url) ? ".ts" : ".mp4";
  logI("player_aaaa 命中（encrypt=" + encrypt + "）：" + title);
  return { url: url, fileName: withExt(title, ext), extraHeaders: headers };
}

/* ---- 6.3 分层加密：主站配置 → 中间播放器页 → AES 解密 ---- */

var LAYER_HOST = "ym.bjdaile.fun";     /* 中间播放器页主机（非完整地址） */
var LAYER_SECRET = "3G7Fh9Dp6R2QsE8w"; /* 密钥派生常量 */

async function resolveLayeredEncryption(payload, pageUrl, headers) {
  if (!payload) { logW("分层加密负载为空"); return null; }

  var midUrl = "https://" + LAYER_HOST + "/?url=" + encodeURIComponent(payload) +
               "&next=&title=" + encodeURIComponent("video");
  logI("请求中间播放器页");
  var mid = await httpGet(midUrl, { "Referer": originOf(pageUrl) + "/" });
  var html = mid.body;
  if (!html) { logW("中间页内容为空"); return null; }

  /* 1) AES 密文 */
  var cipherM = /"url"\s*:\s*"([A-Za-z0-9+\/=]{40,})"/.exec(html);
  if (!cipherM) { logW("中间页未找到密文"); return null; }

  /* 2) 两个 meta 的 id，交叉配对后按数值排序拼出种子 */
  var vpM = /<meta[^>]*name=["']viewport["'][^>]*id=["']([^"']+)/i.exec(html);
  var csM = /<meta[^>]*charset=["']?UTF-8["']?[^>]*id=["']([^"']+)/i.exec(html);
  if (!vpM || !csM) { logW("中间页缺少 meta id，无法派生密钥"); return null; }

  var text = String(vpM[1]).replace(/^now_/, "");
  var ids = String(csM[1]).replace(/^now_/, "");
  var pairs = [];
  for (var i = 0; i < ids.length; i++) pairs.push({ id: ids.charAt(i), text: text.charAt(i) || "" });
  pairs.sort(function (a, b) { return parseInt(a.id, 10) - parseInt(b.id, 10); });
  var joined = "";
  for (var k = 0; k < pairs.length; k++) joined += pairs[k].text;

  /* 3) MD5 → key = 后 16 位 ASCII，iv = 前 16 位 ASCII */
  var hex = md5Hex(joined + LAYER_SECRET);
  var key = [], iv = [];
  for (var a = 0; a < 16; a++) key.push(hex.charCodeAt(16 + a));
  for (var b = 0; b < 16; b++) iv.push(hex.charCodeAt(b));

  var plain;
  try { plain = bytesToUtf8(aesCbcDecrypt(b64Bytes(cipherM[1]), key, iv)); }
  catch (e) { logW("AES 解密异常"); return null; }

  if (!/^https?:\/\//i.test(plain)) { logW("解密结果不像地址"); return null; }

  /* 标题通常在主站页面里，取一下更准确；取不到就退回路径名。 */
  var title = "";
  try {
    var page = await httpGet(pageUrl, headers);
    title = tidyName(htmlTitle(page.body));
  } catch (e) {}
  if (!title) title = "video";

  var ext = /\.m3u8(\?|$)/i.test(plain) ? ".ts" : ".mp4";
  logI("分层加密解密成功：" + title);
  return { url: plain, fileName: withExt(title, ext), extraHeaders: headers };
}

/* ---- 6.4 Next.js 站点：从 RSC 数据取线路，再换签名直链 ---- */

var XIFAN_API_HOST = "api.xifanacg.com";
var XIFAN_PUBLISHABLE = "sb_publishable_OBIVAWACIX6lPXrO98_z24_HcsmalkA";

function extractSources(html) {
  /* RSC 里的引号是 \" 转义，先还原成普通引号便于正则。 */
  var flat = String(html || "").replace(/\\"/g, "\"");
  var out = [];
  var re = /\{"id":(\d+),"code":"([^"]+)","name":"[^"]*","episodes":\[\{"id":(\d+)[\s\S]{0,300}?"episode_number":(\d+)/g;
  var m;
  while ((m = re.exec(flat))) {
    out.push({
      id: parseInt(m[1], 10),
      code: m[2],
      firstEpisodeId: parseInt(m[3], 10),
      firstEpisodeNumber: parseInt(m[4], 10)
    });
    if (out.length > 24) break;
  }
  return out;
}

async function resolveNextjsPlayback(pageUrl, headers) {
  var resp = await httpGet(pageUrl, headers);
  var html = resp.body;
  if (!html) { logW("页面内容为空"); return null; }

  var sources = extractSources(html);
  if (!sources.length) { logW("未从页面数据中找到线路"); return null; }

  /* 播放页形如 .../play/{episodeId}，可取到当前集；详情页取第一集。 */
  var epM = /\/play\/(\d+)/.exec(pathOf(pageUrl));
  var episodeId = epM ? parseInt(epM[1], 10) : sources[0].firstEpisodeId;
  if (!episodeId) { logW("未确定剧集编号"); return null; }

  /* ?source=xxx 优先，其次取第一条线路。 */
  var srcCode = "";
  var qm = /[?&]source=([^&#]+)/.exec(String(pageUrl));
  if (qm) { try { srcCode = decodeURIComponent(qm[1]); } catch (e) { srcCode = qm[1]; } }
  var picked = null;
  for (var i = 0; i < sources.length; i++) {
    if (srcCode && sources[i].code === srcCode) { picked = sources[i]; break; }
  }
  if (!picked) picked = sources[0];

  var apiUrl = "https://" + XIFAN_API_HOST + "/functions/v1/issue-web-playback";
  var apiHeaders = {
    "Authorization": "Bearer " + XIFAN_PUBLISHABLE,
    "apikey": XIFAN_PUBLISHABLE,
    "Origin": originOf(pageUrl),
    "Referer": pageUrl
  };
  var body = { action: "fallback", episode_id: episodeId, source_id: picked.id };

  logI("请求播放签发接口（线路 " + picked.code + "，第 " + episodeId + " 集）");
  var r = await httpPostJson(apiUrl, apiHeaders, body, 15000);

  var data = null;
  try { data = JSON.parse(r.body); } catch (e) {}
  if (!data) { logW("签发接口返回的不是 JSON（HTTP " + r.status + "）"); return null; }
  if (data.ok !== true) { logW("签发接口拒绝：" + String(data.error || r.status)); return null; }

  var url = String(data.url || "");
  if (!url && data.candidates && data.candidates.length) url = String(data.candidates[0].url || "");
  if (!/^https?:\/\//i.test(url)) { logW("签发接口没有返回可用地址"); return null; }

  var title = tidyName(htmlTitle(html)) || "video";
  if (!RE_EPISODE.test(title)) {
    var epNum = 0;
    if (epM) {
      var flat = String(html).replace(/\\"/g, "\"");
      var nm = new RegExp("\"id\":" + episodeId + "[\\s\\S]{0,300}?\"episode_number\":(\\d+)").exec(flat);
      if (nm) epNum = parseInt(nm[1], 10);
    }
    if (!epNum) epNum = picked.firstEpisodeNumber;
    if (epNum) title = title + " 第" + epNum + "集";
  }
  var ext = /\.m3u8(\?|$)/i.test(url) ? ".ts" : ".mp4";
  logI("签发成功：" + title + "（" + picked.code + "）");
  return { url: url, fileName: withExt(title, ext), extraHeaders: headers };
}

/* ---- 6.5 页面内明文 HLS 播放器 ---- */
async function resolvePlainHls(pageUrl, headers) {
  var resp = await httpGet(pageUrl, headers);
  var html = resp.body;
  if (!html) { logW("页面内容为空"); return null; }

  var m = /\.loadSource\(\s*["']([^"']+)["']\s*\)/.exec(html) ||
          /source\s*:\s*["']([^"']+\.m3u8[^"']*)["']/.exec(html);
  if (!m) { logW("未找到播放器加载地址"); return null; }

  var url = jsUnescape(m[1]);
  if (!/^https?:\/\//i.test(url)) { logW("播放器地址不是绝对地址"); return null; }

  var title = tidyName(htmlTitle(html)) || "video";
  logI("明文 HLS 命中：" + title);
  return { url: url, fileName: withExt(title, ".ts"), extraHeaders: headers };
}

/* ================================================================== *
 * 七、入口：按主机名分派
 * ================================================================== */

function buildHeaders(ctx, pageUrl) {
  var h = {};
  var ua = String(ctx.userAgent || "").trim();
  if (ua) h["User-Agent"] = ua;

  /* 解析器设置：是否补齐 Referer（默认开启）。 */
  var injectReferer = true;
  try {
    var s = flux.settings || {};
    if (s.injectReferer === false || s.injectReferer === "false") injectReferer = false;
  } catch (e) {}

  if (injectReferer) {
    var ref = String(ctx.referrer || "").trim();
    if (!ref || !/^https?:\/\//i.test(ref)) ref = originOf(pageUrl) + "/";
    h["Referer"] = ref;
  }

  /* 页面上抓到的 Cookie 一并透传，等价于浏览器已登录状态。 */
  var cookie = String(ctx.cookies || "").trim();
  if (cookie) h["Cookie"] = cookie;
  return h;
}

async function resolve(ctx) {
  ctx = ctx || {};
  var pageUrl = String(ctx.url || "").trim();
  var host = hostOf(pageUrl);
  if (!host) { logW("缺少有效的页面地址"); return null; }

  var headers = buildHeaders(ctx, pageUrl);
  logI("解析 " + host);

  /* 按站点特征选择解析策略，只匹配主机名，不依赖完整路径。 */
  if (/(^|\.)mutedm\.com$/.test(host)) {
    return await resolveInlinePlayerConfig(pageUrl, headers);
  }
  if (/(^|\.)xifanacg\.com$/.test(host)) {
    return await resolveNextjsPlayback(pageUrl, headers);
  }
  if (/(^|\.)girigirilove\.com$/.test(host)) {
    return await resolvePlayerAaaa(pageUrl, headers);
  }
  if (/(^|\.)fsdm02\.com$/.test(host)) {
    return await resolvePlayerAaaa(pageUrl, headers);
  }
  if (/(^|\.)2rk\.cc$/.test(host)) {
    return await resolvePlainHls(pageUrl, headers);
  }

  logW("该主机暂未适配：" + host);
  return null;
}

globalThis.resolve = resolve;
