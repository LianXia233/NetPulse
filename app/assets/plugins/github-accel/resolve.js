// NetPulse 插件：GitHub 加速（classic script，入口挂 globalThis）。
//
// 原理：命中 GitHub 文件链接时，在协议分派前把直链改写到公共加速源。改写前对
// 「本次要下载的这个文件」在所有适用加速源上并行实测（GET + Range: bytes=0-65535，
// 64 KB 采样），一次探测同时验证可用性与速度：
//   - 状态 200/206 视为可用，比较耗时选最快；全部失败 → 返回 null 放行 GitHub
//     直连——加速失败绝不阻断下载（resolve 返回 null 即放行，不触发 fail-closed）。
//   - 206 说明该源支持 Range，回填 rangeSupported 让引擎直接按多线程分段规划；
//     Content-Range / Content-Length 里的总大小一并回填 totalBytes。
//   - 同一 URL 的历史选择会被记住（flux.storage 内 LRU）：上次选中的源本次探测
//     仍可用就继续沿用，避免断点续传恢复时换源导致 ETag 校验不一致而整段重下。
//
// 内置加速源规则（维护参考）：
//   jsDelivr  https://fastly.jsdelivr.net/gh/<owner>/<repo>@<ref>/<path>
//             仅支持仓库内文件（blob / raw），单文件 ≤ 20 MB（超限返回 403，探测
//             自然剔除）；不支持 release 资产与源码归档。ref 可为分支/标签/提交号；
//             分支内容有 CDN 缓存（约 12 小时），标签/提交号则永久缓存。
//   FastGit   https://fastgit.cc/<完整 GitHub URL>（hunshcn/gh-proxy 的 Cloudflare
//             Workers 部署，前缀拼接）。支持 release 资产、源码归档
//             （archive/*.zip|*.tar.gz）、blob/raw 分支文件以及
//             raw./gist.githubusercontent.com；不支持项目文件夹。
//
// 扩展新加速源（两条路径）：
//   1) 代码级——在 BUILTIN_PROVIDERS 追加一项 { id, label, supports, rewrite }；
//   2) 用户级——「附加 gh-proxy 加速源」设置里每行填一个 https:// 前缀，自动生成
//      gh-proxy 风格加速源参与测速，无需改代码。
//
// 注意 QuickJS 运行时没有 URL/定时器等浏览器全局，URL 解析用正则手写。

'use strict';

var PROBE_RANGE = 'bytes=0-65535'; // 64 KB 采样：够摊平 TLS/首包抖动，又不拖慢解析
var PICKS_KEY = 'picks:v1'; // storage：URL → 加速源 的记忆（LRU）
var PICKS_CAP = 24;
var PICKS_TTL_MS = 12 * 60 * 60 * 1000;

// —— 加速源注册表：新增平台只需在此追加一项 ——
// supports(file) 判断该源能否承载此类文件；rewrite(file) 产出加速直链。
var BUILTIN_PROVIDERS = [
  {
    id: 'jsdelivr',
    label: 'jsDelivr CDN',
    supports: function (f) {
      // 仅仓库内文件；release 资产 / 源码归档 / gist 一律不支持。
      return (f.kind === 'blob' || f.kind === 'raw') && !!f.ref && !!f.path;
    },
    rewrite: function (f) {
      return 'https://fastly.jsdelivr.net/gh/' + f.owner + '/' + f.repo + '@' + f.ref + '/' + f.path;
    },
  },
  {
    id: 'fastgit',
    label: 'FastGit',
    supports: function () {
      return true; // gh-proxy 覆盖全部已解析的文件类型
    },
    rewrite: function (f) {
      return 'https://fastgit.cc/' + f.original;
    },
  },
];

// —— GitHub 文件链接解析 ——
// 返回 null = 不是可加速的「文件」链接（仓库主页、PR、Issues……放行）。
// 返回 { kind, owner, repo, ref, path, original }
//   kind ∈ 'release'（release 资产）| 'archive'（源码归档）| 'blob' | 'raw' | 'gist'
function parseGithubFile(url) {
  var m = /^https?:\/\/([^\/?#]+)((?:\/[^?#]*)?)/i.exec(url || '');
  if (!m) return null;
  var host = m[1].toLowerCase();
  var segs = [];
  var parts = (m[2] || '').split('/');
  for (var i = 0; i < parts.length; i++) {
    if (parts[i]) segs.push(parts[i]);
  }

  function mk(kind, owner, repo, ref, path) {
    return { kind: kind, owner: owner, repo: repo, ref: ref, path: path, original: url };
  }

  if (host === 'github.com' || host === 'www.github.com') {
    if (segs.length < 4) return null;
    var owner = segs[0];
    var repo = segs[1];
    var action = segs[2];
    // release 资产：/releases/download/<tag>/<file> 与 /releases/latest/download/<file>
    if (action === 'releases' && segs[3] === 'download' && segs.length >= 5) {
      return mk('release', owner, repo, '', '');
    }
    if (action === 'releases' && segs[3] === 'latest' && segs[4] === 'download' && segs.length >= 6) {
      return mk('release', owner, repo, '', '');
    }
    // 源码归档：/archive/master.zip、/archive/v0.1.0.tar.gz、/archive/refs/heads/main.zip
    if (action === 'archive' && /\.(zip|tar\.gz)$/i.test(segs[segs.length - 1])) {
      return mk('archive', owner, repo, '', '');
    }
    // 分支文件：/blob/<ref>/<path> 或 /raw/<ref>/<path>（含 refs/heads|tags 变体）
    if ((action === 'blob' || action === 'raw') && segs.length >= 5) {
      var ref, rest;
      if (segs[3] === 'refs' && (segs[4] === 'heads' || segs[4] === 'tags') && segs.length >= 7) {
        ref = segs[5];
        rest = segs.slice(6);
      } else {
        ref = segs[3];
        rest = segs.slice(4);
      }
      return mk(action === 'blob' ? 'blob' : 'raw', owner, repo, ref, rest.join('/'));
    }
    return null;
  }

  if (host === 'raw.githubusercontent.com') {
    if (segs.length < 4) return null;
    var ref2, rest2;
    if (segs[2] === 'refs' && (segs[3] === 'heads' || segs[3] === 'tags') && segs.length >= 6) {
      ref2 = segs[4];
      rest2 = segs.slice(5);
    } else {
      ref2 = segs[2];
      rest2 = segs.slice(3);
    }
    return mk('raw', segs[0], segs[1], ref2, rest2.join('/'));
  }

  if (host === 'gist.githubusercontent.com') {
    if (segs.length < 2) return null;
    return mk('gist', segs[0], '', '', '');
  }

  return null;
}

// —— 用户自定义 gh-proxy 加速源（设置项 extraProxies，每行一个 https:// 前缀）——
function extraProviders() {
  var raw = String(flux.settings.extraProxies || '');
  var out = [];
  var seen = {};
  var lines = raw.split(/\r?\n/);
  for (var i = 0; i < lines.length; i++) {
    var s = lines[i].trim();
    if (!s) continue;
    if (!/^https:\/\/[^\/\s]+/i.test(s)) continue; // 仅 https，与宿主 fetch 护栏一致
    if (s.charAt(s.length - 1) !== '/') s += '/';
    if (seen[s]) continue;
    seen[s] = true;
    var hm = /^https:\/\/([^\/]+)/i.exec(s);
    var host = hm ? hm[1].toLowerCase() : 'proxy' + i;
    out.push({
      id: 'extra:' + host,
      label: host + ' (gh-proxy)',
      supports: function () {
        return true;
      },
      rewrite: (function (prefix) {
        return function (f) {
          return prefix + f.original;
        };
      })(s),
    });
  }
  return out;
}

// —— 探测：一次 Range 采样同时得到 可用性 / 耗时 / Range 支持 / 文件总大小 ——
function probeProvider(p, url) {
  var t0 = Date.now();
  return flux.fetch({ url: url, headers: { range: PROBE_RANGE } }).then(
    function (res) {
      var ok = res.status === 200 || res.status === 206;
      return {
        p: p,
        url: url,
        ok: ok,
        ms: Date.now() - t0,
        status: res.status,
        ranged: res.status === 206,
        total: ok ? totalFromHeaders(res.headers, res.status) : 0,
      };
    },
    function (err) {
      return {
        p: p,
        url: url,
        ok: false,
        ms: Date.now() - t0,
        status: 0,
        ranged: false,
        total: 0,
        error: String((err && err.message) || err),
      };
    },
  );
}

function headerValue(headers, name) {
  if (!headers) return '';
  if (typeof headers[name] === 'string') return headers[name];
  var lower = name.toLowerCase();
  for (var k in headers) {
    if (k.toLowerCase() === lower && typeof headers[k] === 'string') return headers[k];
  }
  return '';
}

function totalFromHeaders(headers, status) {
  if (status === 206) {
    // Content-Range: bytes 0-65535/123456789
    var cr = /\/(\d+)\s*$/.exec(headerValue(headers, 'content-range'));
    if (cr) {
      var n = parseInt(cr[1], 10);
      if (isFinite(n) && n > 0) return n;
    }
    return 0;
  }
  // 200 = 服务端忽略 Range，Content-Length 即全长
  var cl = parseInt(headerValue(headers, 'content-length'), 10);
  return isFinite(cl) && cl > 0 ? cl : 0;
}

// —— URL → 加速源 的历史选择（续传稳定性）——
function loadPicks() {
  return flux.storage.get(PICKS_KEY).then(
    function (v) {
      if (!v) return {};
      try {
        var obj = JSON.parse(v);
        return obj && typeof obj === 'object' ? obj : {};
      } catch (e) {
        return {};
      }
    },
    function () {
      return {};
    },
  );
}

function savePick(picks, url, id) {
  var now = Date.now();
  picks[url] = { id: id, at: now };
  var keys = [];
  for (var k in picks) {
    var e = picks[k];
    if (!e || typeof e.at !== 'number' || now - e.at > PICKS_TTL_MS) {
      delete picks[k];
    } else {
      keys.push(k);
    }
  }
  if (keys.length > PICKS_CAP) {
    keys.sort(function (a, b) {
      return picks[a].at - picks[b].at;
    });
    for (var i = 0; i < keys.length - PICKS_CAP; i++) delete picks[keys[i]];
  }
  return flux.storage.set(PICKS_KEY, JSON.stringify(picks)).then(
    function () {},
    function () {}, // 存储失败不影响本次解析
  );
}

function findById(results, id) {
  for (var i = 0; i < results.length; i++) {
    if (results[i].p.id === id) return results[i];
  }
  return null;
}

function fastest(results) {
  var best = results[0];
  for (var i = 1; i < results.length; i++) {
    if (results[i].ms < best.ms) best = results[i];
  }
  return best;
}

globalThis.resolve = async function (ctx) {
  try {
    var mode = String(flux.settings.preferred || 'auto');
    if (mode === 'direct') return null;

    var f = parseGithubFile(ctx.url);
    if (!f) return null; // 非文件链接（仓库页 / PR / Issues …）→ 放行

    var providers = BUILTIN_PROVIDERS.concat(extraProviders());
    var candidates = [];
    for (var i = 0; i < providers.length; i++) {
      if (providers[i].supports(f)) {
        candidates.push({ p: providers[i], url: providers[i].rewrite(f) });
      }
    }
    if (!candidates.length) return null;

    var results = await Promise.all(
      candidates.map(function (c) {
        return probeProvider(c.p, c.url);
      }),
    );

    if (flux.settings.verbose) {
      for (var j = 0; j < results.length; j++) {
        var r = results[j];
        flux.logger.info(
          '[github-accel] 探测 ' + r.p.label + ': ' +
            (r.ok ? 'HTTP ' + r.status + ' ' + r.ms + 'ms' : '失败 ' + (r.error || 'HTTP ' + r.status)),
        );
      }
    }

    var ok = results.filter(function (r) {
      return r.ok;
    });
    if (!ok.length) {
      flux.logger.warn('[github-accel] 所有加速源探测失败，回退 GitHub 直连: ' + ctx.url);
      return null;
    }

    // 优先级：用户强制指定（可用时）> 同 URL 历史选择（可用时，保续传一致）> 实测最快
    var picks = await loadPicks();
    var best = null;
    if (mode !== 'auto') best = findById(ok, mode);
    if (!best && picks[f.original]) best = findById(ok, picks[f.original].id);
    if (!best) best = fastest(ok);

    await savePick(picks, f.original, best.p.id);

    flux.logger.info(
      '[github-accel] 选用 ' + best.p.label + '（' + best.ms + 'ms, HTTP ' + best.status + '）加速 ' + ctx.url,
    );

    var out = { url: best.url };
    if (best.ranged) out.rangeSupported = true; // 206 已实证支持 Range，直接多线程分段
    if (best.total > 0) out.totalBytes = best.total;
    return out;
  } catch (e) {
    // 插件内部任何意外都不应阻断下载：记日志后放行直连。
    flux.logger.error('[github-accel] 解析异常，放行直连: ' + String((e && e.message) || e));
    return null;
  }
};
