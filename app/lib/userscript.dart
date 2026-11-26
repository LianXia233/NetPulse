import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bridge.dart';

/// 一个用户脚本（Greasemonkey / Tampermonkey 兼容）。
class UserScript {
  UserScript({
    required this.id,
    required this.name,
    this.namespace = '',
    this.version = '',
    this.description = '',
    this.author = '',
    this.homepage = '',
    this.sourceUrl = '',
    this.match = const [],
    this.include = const [],
    this.exclude = const [],
    this.grant = const [],
    this.requires = const [],
    this.resources = const {},
    this.runAt = 'document-idle',
    this.enabled = true,
    this.bytes = 0,
    this.installedAt = '',
    this.updatedAt = '',
  });

  final String id;
  final String name;
  final String namespace;
  final String version;
  final String description;
  final String author;
  final String homepage;

  /// 安装来源（GreasyFork 脚本页或 .user.js 地址），用于检查更新。
  final String sourceUrl;
  final List<String> match;
  final List<String> include;
  final List<String> exclude;
  final List<String> grant;

  /// `@require` 的远程地址。
  final List<String> requires;

  /// `@resource`：名称 → 地址。
  final Map<String, String> resources;
  final String runAt;
  final bool enabled;
  final int bytes;
  final String installedAt;
  final String updatedAt;

  bool get atDocumentStart => runAt == 'document-start';
  bool get atDocumentEnd => runAt == 'document-end';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'namespace': namespace,
    'version': version,
    'description': description,
    'author': author,
    'homepage': homepage,
    'sourceUrl': sourceUrl,
    'match': match,
    'include': include,
    'exclude': exclude,
    'grant': grant,
    'requires': requires,
    'resources': resources,
    'runAt': runAt,
    'enabled': enabled,
    'bytes': bytes,
    'installedAt': installedAt,
    'updatedAt': updatedAt,
  };

  factory UserScript.fromJson(Map<String, dynamic> j) => UserScript(
    id: j['id']?.toString() ?? '',
    name: j['name']?.toString() ?? '',
    namespace: j['namespace']?.toString() ?? '',
    version: j['version']?.toString() ?? '',
    description: j['description']?.toString() ?? '',
    author: j['author']?.toString() ?? '',
    homepage: j['homepage']?.toString() ?? '',
    sourceUrl: j['sourceUrl']?.toString() ?? '',
    match: _strList(j['match']),
    include: _strList(j['include']),
    exclude: _strList(j['exclude']),
    grant: _strList(j['grant']),
    requires: _strList(j['requires']),
    resources: (j['resources'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
        ) ??
        const {},
    runAt: j['runAt']?.toString() ?? 'document-idle',
    enabled: j['enabled'] != false,
    bytes: (j['bytes'] as num?)?.toInt() ?? 0,
    installedAt: j['installedAt']?.toString() ?? '',
    updatedAt: j['updatedAt']?.toString() ?? '',
  );

  UserScript copyWith({bool? enabled, String? version, String? updatedAt}) =>
      UserScript(
        id: id,
        name: name,
        namespace: namespace,
        version: version ?? this.version,
        description: description,
        author: author,
        homepage: homepage,
        sourceUrl: sourceUrl,
        match: match,
        include: include,
        exclude: exclude,
        grant: grant,
        requires: requires,
        resources: resources,
        runAt: runAt,
        enabled: enabled ?? this.enabled,
        bytes: bytes,
        installedAt: installedAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 页面是否需要注入本脚本。
  bool matches(String url) {
    final target = url.trim();
    if (target.isEmpty) return false;
    for (final pattern in exclude) {
      if (_matchPattern(pattern, target) || _matchInclude(pattern, target)) {
        return false;
      }
    }
    for (final pattern in match) {
      if (_matchPattern(pattern, target)) return true;
    }
    for (final pattern in include) {
      if (_matchInclude(pattern, target)) return true;
    }
    return false;
  }

  /// 展示用的匹配摘要：优先站点域名，避免长规则刷屏。
  List<String> get hostHints {
    final out = <String>[];
    for (final raw in [...match, ...include]) {
      var p = raw.trim();
      if (p.isEmpty || p == '<all_urls>') {
        if (!out.contains('*')) out.add('*');
        continue;
      }
      if (p.startsWith('/') && p.lastIndexOf('/') > 0) continue;
      final schemeEnd = p.indexOf('://');
      if (schemeEnd >= 0) p = p.substring(schemeEnd + 3);
      var host = p.split('/').first;
      host = host.split(':').first;
      if (host.startsWith('*.')) host = host.substring(2);
      if (host.isEmpty) continue;
      if (!out.contains(host)) out.add(host);
    }
    return out.take(6).toList();
  }
}

List<String> _strList(Object? raw) {
  if (raw is List) {
    return raw
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  return const [];
}

/// Chrome `@match` 语法：`scheme://host/path`，`*` 只在整段生效。
bool _matchPattern(String pattern, String url) {
  final p = pattern.trim();
  if (p.isEmpty) return false;
  if (p == '<all_urls>') {
    return url.startsWith('http://') ||
        url.startsWith('https://') ||
        url.startsWith('file://');
  }
  final m = RegExp(r'^(\*|[a-zA-Z][a-zA-Z0-9+.-]*|\*?)://([^/]*)(/.*)$')
      .firstMatch(p);
  if (m == null) return _matchInclude(p, url);
  final schemePat = m.group(1)!;
  final hostPat = m.group(2)!;
  final pathPat = m.group(3)!;
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (schemePat != '*' && schemePat.toLowerCase() != uri.scheme.toLowerCase()) {
    return false;
  }
  final host = uri.host.toLowerCase();
  final hp = hostPat.toLowerCase();
  if (hp != '*') {
    if (hp.startsWith('*.')) {
      final base = hp.substring(2);
      if (host != base && !host.endsWith('.$base')) return false;
    } else if (hp != host) {
      return false;
    }
  }
  // path 段内 `*` 是通配符。
  var path = uri.path.isEmpty ? '/' : uri.path;
  final query = uri.hasQuery ? '?${uri.query}' : '';
  if (pathPat.contains('*')) {
    final re = RegExp(
      '^${RegExp.escape(pathPat).replaceAll(r'\*', '.*')}\$',
    );
    return re.hasMatch(path) || re.hasMatch('$path$query');
  }
  return path == pathPat;
}

/// `@include`：支持 `*` 通配与 `/正则/`。
bool _matchInclude(String pattern, String url) {
  final p = pattern.trim();
  if (p.isEmpty) return false;
  if (p.length > 2 && p.startsWith('/') && p.endsWith('/')) {
    try {
      return RegExp(p.substring(1, p.length - 1)).hasMatch(url);
    } catch (_) {
      return false;
    }
  }
  if (!p.contains('*')) return url.startsWith(p);
  final re = RegExp(
    '^${RegExp.escape(p).replaceAll(r'\*', '.*')}\$',
    caseSensitive: false,
  );
  return re.hasMatch(url);
}

/// 解析 `==UserScript==` 元数据块；没有元数据块时返回 null。
Map<String, dynamic>? parseUserScriptMeta(String source) {
  final start = source.indexOf('==UserScript==');
  if (start < 0) return null;
  final end = source.indexOf('==/UserScript==', start);
  if (end < 0) return null;
  final block = source.substring(start, end);
  final match = <String>[];
  final include = <String>[];
  final exclude = <String>[];
  final grant = <String>[];
  final requires = <String>[];
  final resources = <String, String>{};
  var name = '';
  var namespace = '';
  var version = '';
  var description = '';
  var author = '';
  var homepage = '';
  var runAt = '';
  for (final raw in block.split('\n')) {
    final line = raw.trim();
    if (!line.startsWith('//')) continue;
    var body = line.substring(2).trim();
    if (!body.startsWith('@')) continue;
    body = body.substring(1).trim();
    final sp = body.indexOf(RegExp(r'\s'));
    final key = (sp < 0 ? body : body.substring(0, sp)).toLowerCase();
    final value = sp < 0 ? '' : body.substring(sp + 1).trim();
    if (value.isEmpty && key != 'noframes' && key != 'grant') continue;
    switch (key) {
      case 'name':
        if (name.isEmpty) name = value;
        break;
      case 'namespace':
        namespace = value;
        break;
      case 'version':
        version = value;
        break;
      case 'description':
        description = value;
        break;
      case 'author':
        author = value;
        break;
      case 'homepage':
      case 'homepageurl':
      case 'website':
        homepage = value;
        break;
      case 'match':
        match.add(value);
        break;
      case 'include':
        include.add(value);
        break;
      case 'exclude':
        exclude.add(value);
        break;
      case 'grant':
        grant.add(value);
        break;
      case 'require':
        requires.add(value);
        break;
      case 'resource':
        final parts = value.split(RegExp(r'\s+'));
        if (parts.length >= 2) resources[parts.first] = parts[1];
        break;
      case 'run-at':
        runAt = value.toLowerCase();
        break;
    }
  }
  if (name.isEmpty) name = '未命名脚本';
  return {
    'name': name,
    'namespace': namespace,
    'version': version,
    'description': description,
    'author': author,
    'homepage': homepage,
    'match': match,
    'include': include,
    'exclude': exclude,
    'grant': grant,
    'require': requires,
    'resource': resources,
    'runAt': runAt.isEmpty ? 'document-idle' : runAt,
  };
}

/// 稳定的脚本 id：FNV-1a(32) 十六进制，跨运行不变。
String userScriptId({required String name, String namespace = ''}) {
  final key = '${namespace.trim()}\u0000${name.trim()}'.toLowerCase();
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(key)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// 用户脚本仓库：源码与资源落盘，元数据存 `index.json`。
class UserScriptStore {
  UserScriptStore._();

  static final UserScriptStore i = UserScriptStore._();

  List<UserScript> _scripts = [];
  bool _loaded = false;
  final Map<String, Map<String, dynamic>> _kv = {};

  List<UserScript> get scripts => List.unmodifiable(_scripts);
  bool get loaded => _loaded;

  int get enabledCount => _scripts.where((s) => s.enabled).length;

  static Directory get dir =>
      Directory('${NativeInfo.filesDir}/userscripts');

  File get _indexFile => File('${dir.path}/index.json');
  File get _kvFile => File('${dir.path}/kv.json');

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      if (await _indexFile.exists()) {
        final raw = jsonDecode(await _indexFile.readAsString());
        if (raw is List) {
          _scripts = raw
              .whereType<Map>()
              .map((e) => UserScript.fromJson(e.cast<String, dynamic>()))
              .where((s) => s.id.isNotEmpty)
              .toList();
        }
      }
      if (await _kvFile.exists()) {
        final raw = jsonDecode(await _kvFile.readAsString());
        if (raw is Map) {
          _kv.clear();
          raw.forEach((k, v) {
            _kv[k.toString()] = v is Map
                ? v.cast<String, dynamic>()
                : {'value': v};
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      await _indexFile.writeAsString(
        jsonEncode(_scripts.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _saveKv() async {
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      await _kvFile.writeAsString(jsonEncode(_kv));
    } catch (_) {}
  }

  UserScript? byId(String id) {
    for (final s in _scripts) {
      if (s.id == id) return s;
    }
    return null;
  }

  File sourceFile(String id) => File('${dir.path}/$id.user.js');
  File requireFile(String id) => File('${dir.path}/$id.require.js');
  Directory resourceDir(String id) => Directory('${dir.path}/res/$id');

  Future<String> readSource(String id) async {
    try {
      final f = sourceFile(id);
      if (await f.exists()) return await f.readAsString();
    } catch (_) {}
    return '';
  }

  /// 安装结果：成功返回脚本，失败给出原因。
  Future<({UserScript? script, String error})> install(
    String source, {
    String sourceUrl = '',
    bool enabled = true,
  }) async {
    await ensureLoaded();
    final meta = parseUserScriptMeta(source);
    if (meta == null) {
      return (script: null, error: '不是有效的用户脚本：缺少 ==UserScript== 元数据');
    }
    final name = meta['name'] as String;
    final namespace = meta['namespace'] as String;
    final id = userScriptId(name: name, namespace: namespace);
    final requires = (meta['require'] as List).cast<String>();
    final resources = (meta['resource'] as Map).cast<String, String>();

    if (!await dir.exists()) await dir.create(recursive: true);
    await sourceFile(id).writeAsString(source);

    // @require 在安装时预取并合并，运行时不再依赖网络与 CORS。
    final reqBuf = StringBuffer();
    for (final url in requires) {
      final text = await fetchText(url);
      if (text.isEmpty) continue;
      reqBuf.writeln('/* @require $url */');
      reqBuf.writeln(text);
      reqBuf.writeln(';');
    }
    await requireFile(id).writeAsString(reqBuf.toString());

    // @resource 同样落地，供 GM_getResourceText 同步读取。
    final resDir = resourceDir(id);
    try {
      if (await resDir.exists()) await resDir.delete(recursive: true);
      await resDir.create(recursive: true);
    } catch (_) {}
    for (final entry in resources.entries) {
      final text = await fetchText(entry.value);
      if (text.isEmpty) continue;
      try {
        await File('${resDir.path}/${_safeName(entry.key)}').writeAsString(
          text,
        );
      } catch (_) {}
    }

    final now = DateTime.now().toIso8601String();
    final existing = byId(id);
    final script = UserScript(
      id: id,
      name: name,
      namespace: namespace,
      version: meta['version'] as String,
      description: meta['description'] as String,
      author: meta['author'] as String,
      homepage: meta['homepage'] as String,
      sourceUrl: sourceUrl.isEmpty ? (existing?.sourceUrl ?? '') : sourceUrl,
      match: (meta['match'] as List).cast<String>(),
      include: (meta['include'] as List).cast<String>(),
      exclude: (meta['exclude'] as List).cast<String>(),
      grant: (meta['grant'] as List).cast<String>(),
      requires: requires,
      resources: resources,
      runAt: meta['runAt'] as String,
      enabled: existing?.enabled ?? enabled,
      bytes: utf8.encode(source).length,
      installedAt: existing?.installedAt ?? now,
      updatedAt: now,
    );
    final index = _scripts.indexWhere((s) => s.id == id);
    if (index >= 0) {
      _scripts[index] = script;
    } else {
      _scripts.insert(0, script);
    }
    await _save();
    return (script: script, error: '');
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = _scripts.indexWhere((s) => s.id == id);
    if (i < 0) return;
    _scripts[i] = _scripts[i].copyWith(enabled: enabled);
    await _save();
  }

  Future<void> remove(String id) async {
    _scripts.removeWhere((s) => s.id == id);
    _kv.removeWhere((k, _) => k.startsWith('$id\u0000'));
    await _save();
    await _saveKv();
    try {
      final f = sourceFile(id);
      if (await f.exists()) await f.delete();
      final r = requireFile(id);
      if (await r.exists()) await r.delete();
      final rd = resourceDir(id);
      if (await rd.exists()) await rd.delete(recursive: true);
    } catch (_) {}
  }

  /// 读取注入所需的全部文本（依赖库、主体、资源、键值）。
  Future<({
    String requires,
    String body,
    Map<String, String> resources,
    Map<String, dynamic> values,
  })>
  payloadFor(UserScript script) async {
    var req = '';
    var body = '';
    try {
      final f = requireFile(script.id);
      if (await f.exists()) req = await f.readAsString();
    } catch (_) {}
    body = await readSource(script.id);
    final res = <String, String>{};
    final rd = resourceDir(script.id);
    try {
      if (await rd.exists()) {
        for (final f in rd.listSync().whereType<File>()) {
          final name = f.uri.pathSegments.last;
          res[name] = await f.readAsString();
        }
      }
    } catch (_) {}
    final prefix = '${script.id}\u0000';
    final values = <String, dynamic>{
      for (final e in _kv.entries)
        if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value,
    };
    return (requires: req, body: body, resources: res, values: values);
  }

  Map<String, dynamic>? kvGet(String scriptId, String name) =>
      _kv['$scriptId\u0000$name'];

  Future<void> kvSet(String scriptId, String name, dynamic value) async {
    final key = '$scriptId\u0000$name';
    if (value == null) {
      _kv.remove(key);
    } else {
      _kv[key] = {'value': value};
    }
    await _saveKv();
  }

  Future<void> kvDelete(String scriptId, String name) async {
    _kv.remove('$scriptId\u0000$name');
    await _saveKv();
  }

  /// 从 .user.js 地址安装。
  Future<({UserScript? script, String error})> installFromUrl(String url) async {
    final text = await fetchText(url);
    if (text.isEmpty) {
      return (script: null, error: '下载脚本源码失败，请检查链接或网络');
    }
    if (parseUserScriptMeta(text) == null) {
      return (script: null, error: '该地址不是用户脚本（缺少元数据块）');
    }
    return install(text, sourceUrl: url);
  }

  /// 从 GreasyFork 等托管站的脚本页安装：先抓 HTML 找出 .user.js 地址。
  Future<({UserScript? script, String error})> installFromPage(
    String pageUrl,
  ) async {
    final html = await fetchText(pageUrl);
    if (html.isEmpty) {
      return (script: null, error: '打开脚本页面失败');
    }
    var codeUrl = '';
    final patterns = [
      RegExp(
        r'''class="[^"]*install-link[^"]*"[^>]*href="([^"]+\.user\.js[^"]*)"''',
        caseSensitive: false,
      ),
      RegExp(
        r'''href="([^"]*/code/[^"]+\.user\.js[^"]*)"''',
        caseSensitive: false,
      ),
      RegExp(
        r'''(https?://[^"' ]+\.user\.js)''',
        caseSensitive: false,
      ),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(html);
      if (m != null) {
        codeUrl = m.group(1) ?? '';
        if (codeUrl.isNotEmpty) break;
      }
    }
    if (codeUrl.isEmpty) {
      return (script: null, error: '没能在这个页面找到脚本安装地址');
    }
    codeUrl = codeUrl
        .replaceAll('&amp;', '&')
        .replaceAll('\\/', '/')
        .trim();
    if (codeUrl.startsWith('//')) {
      codeUrl = 'https:$codeUrl';
    } else if (codeUrl.startsWith('/')) {
      final base = Uri.tryParse(pageUrl);
      if (base != null) {
        codeUrl = '${base.scheme}://${base.authority}$codeUrl';
      }
    }
    final r = await installFromUrl(codeUrl);
    if (r.script == null) return r;
    // 记住脚本页地址，方便之后从页面再检查更新。
    return install(await readSource(r.script!.id), sourceUrl: pageUrl);
  }

  /// 检查更新：重新抓取来源并比对版本号。
  Future<({bool updated, String version, String error})> checkUpdate(
    UserScript script,
  ) async {
    final url = script.sourceUrl;
    if (url.isEmpty) {
      return (updated: false, version: script.version, error: '没有记录安装来源');
    }
    final result = url.contains('/code/') || url.endsWith('.user.js')
        ? await installFromUrl(url)
        : await installFromPage(url);
    if (result.script == null) {
      return (updated: false, version: script.version, error: result.error);
    }
    final next = result.script!;
    final changed =
        next.version.isNotEmpty && next.version != script.version;
    return (updated: changed, version: next.version, error: '');
  }

  /// 通过宿主网络栈抓文本，绕开页面 CORS。
  static Future<String> fetchText(String url) async {
    final target = url.trim();
    if (target.isEmpty) return '';
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      return '';
    }
    if (!Core.i.ready) return '';
    try {
      final r = await Core.callAsync('web_fetch', {
        'url': target,
        'timeoutMs': 20000,
        'maxBytes': 4 * 1024 * 1024,
        'userAgent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      });
      if (r['ok'] != true) return '';
      final body = (r['data'] as Map?)?['body']?.toString() ?? '';
      return body;
    } catch (_) {
      return '';
    }
  }
}

String _safeName(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return cleaned.isEmpty ? 'resource' : cleaned;
}
