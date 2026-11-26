import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' show Color;
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';

import 'bridge.dart';
import 'store.dart';

/// 一个内置站点解析器（兼容 FluxDown 的 manifest + resolve.js 结构）。
class SitePlugin {
  SitePlugin({
    required this.id,
    required this.identity,
    required this.name,
    required this.version,
    required this.description,
    required this.homepage,
    required this.patterns,
    required this.entry,
    required this.timeoutMs,
    required this.settings,
    required this.pageScripts,
  });

  final String id;
  final String identity;
  final String name;
  final String version;
  final String description;
  final String homepage;
  final List<String> patterns;
  final String entry;
  final int timeoutMs;
  final List<Map<String, dynamic>> settings;
  final List<SitePageScript> pageScripts;

  static final List<SitePlugin> _cache = [];
  static bool _loaded = false;

  static Future<List<SitePlugin>> all() async {
    if (_loaded) return _cache;
    try {
      final raw = await rootBundle.loadString('assets/plugins/index.json');
      final list = jsonDecode(raw);
      if (list is List) {
        for (final item in list.whereType<Map>()) {
          final m = item.cast<String, dynamic>();
          _cache.add(
            SitePlugin(
              id: m['id']?.toString() ?? '',
              identity: m['identity']?.toString() ?? '',
              name: m['name']?.toString() ?? '',
              version: m['version']?.toString() ?? '',
              description: m['description']?.toString() ?? '',
              homepage: m['homepage']?.toString() ?? '',
              patterns: (m['match'] as List? ?? const [])
                  .map((e) => e.toString())
                  .toList(),
              entry: m['entry']?.toString() ?? 'resolve.js',
              timeoutMs: (m['timeoutMs'] as num? ?? 20000).toInt().clamp(
                3000,
                120000,
              ),
              settings: (m['settings'] as List? ?? const [])
                  .whereType<Map>()
                  .map((e) => e.cast<String, dynamic>())
                  .toList(),
              pageScripts: (m['pageScripts'] as List? ?? const [])
                  .whereType<Map>()
                  .map(
                    (e) => SitePageScript.fromJson(e.cast<String, dynamic>()),
                  )
                  .toList(),
            ),
          );
        }
      }
    } catch (_) {}
    _loaded = true;
    return _cache;
  }

  static List<SitePlugin> matching(String url) {
    return _cache.where((p) => p.matches(url)).toList();
  }

  bool matches(String url) =>
      patterns.any((p) => _wildcard(p).hasMatch(url.trim()));

  static final Map<String, RegExp> _regexCache = {};

  static RegExp _wildcard(String pattern) {
    return _regexCache.putIfAbsent(pattern, () {
      final b = StringBuffer('^');
      for (final rune in pattern.runes) {
        final ch = String.fromCharCode(rune);
        if (ch == '*') {
          b.write('.*');
        } else if (ch == '?') {
          b.write('.');
        } else {
          b.write(RegExp.escape(ch));
        }
      }
      b.write(r'$');
      return RegExp(b.toString(), caseSensitive: false);
    });
  }

  Map<String, dynamic> settingsMap(AppStore store) {
    final saved = store.pluginSettingsOf(id);
    final out = <String, dynamic>{};
    for (final s in settings) {
      final key = s['key']?.toString() ?? '';
      if (key.isEmpty) continue;
      final raw = saved[key] ?? s['default'];
      if (raw == null) continue;
      final type = s['type']?.toString() ?? 'string';
      if (type == 'number') {
        out[key] = num.tryParse(raw.toString()) ?? 0;
      } else if (type == 'boolean') {
        out[key] = raw == true || raw.toString() == 'true';
      } else {
        out[key] = raw.toString();
      }
    }
    return out;
  }
}

class SitePageScript {
  SitePageScript({
    required this.id,
    required this.patterns,
    required this.batches,
    this.resources = const {},
  });

  final String id;
  final List<String> patterns;

  /// 每个子列表是一次执行单元：同一批里的脚本共享临时的全局状态
  /// （依赖库里 jQuery 这类只能按全局挂载的库需要这样串起来）。
  final List<List<String>> batches;

  /// `GM_getResourceText` 的资源文本，键名与上游 @resource 一致。
  final Map<String, String> resources;

  factory SitePageScript.fromJson(Map<String, dynamic> m) {
    final raw = m['js'] as List? ?? const [];
    final batches = <List<String>>[];
    for (final item in raw) {
      if (item is List) {
        final group = item
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList();
        if (group.isNotEmpty) batches.add(group);
      } else {
        final one = item.toString();
        if (one.isNotEmpty) batches.add([one]);
      }
    }
    final resRaw = m['resources'];
    final resources = <String, String>{};
    if (resRaw is Map) {
      resRaw.forEach((k, v) {
        final key = k.toString();
        final path = v?.toString() ?? '';
        if (key.isNotEmpty && path.isNotEmpty) resources[key] = path;
      });
    }
    return SitePageScript(
      id: m['id']?.toString() ?? '',
      patterns: (m['matches'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      batches: batches,
      resources: resources,
    );
  }

  bool matches(String url) =>
      patterns.any((p) => SitePlugin._wildcard(p).hasMatch(url.trim()));
}

/// 在隐藏 WebView 里运行插件 JS，并把 `flux.fetch` / `flux.storage`
/// 桥接到 Rust core 与本机存储。插件只拿到当前页面上下文和它自己的设置。
class PluginEngine {
  PluginEngine({required this.store});

  final AppStore store;
  late final WebViewController controller;
  final List<String> logs = [];
  String? _loadedPlugin;
  Completer<Map<String, dynamic>>? _pending;
  int _seq = 0;
  int _activeSeq = 0;
  bool _ready = false;
  Completer<void>? _readyWaiter;

  void init() {
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel('NpBridge', onMessageReceived: _onBridge)
      ..addJavaScriptChannel('NpResult', onMessageReceived: _onResult)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _ready = true;
            _readyWaiter?.complete();
            _readyWaiter = null;
          },
        ),
      );
  }

  Future<void> dispose() async {
    final pending = _pending;
    _pending = null;
    pending?.completeError('解析已取消');
  }

  Future<Map<String, dynamic>> resolve(
    SitePlugin plugin,
    Map<String, dynamic> ctx, {
    required Future<String> Function(String url) cookieFor,
    required String userAgent,
  }) async {
    if (_pending != null) throw '已有解析任务进行中';
    final done = Completer<Map<String, dynamic>>();
    _pending = done;
    final seq = ++_seq;
    _activeSeq = seq;
    logs.clear();
    try {
      await _ensureLoaded(plugin, cookieFor, userAgent);
      final settings = plugin.settingsMap(store);
      // 夸克只读 settings.cookie，不读 ctx.cookies；把浏览器登录态补进去。
      for (final key in [...settings.keys, 'cookie']) {
        if (!key.toLowerCase().contains('cookie')) continue;
        final current = settings[key]?.toString().trim() ?? '';
        final cookies = ctx['cookies']?.toString().trim() ?? '';
        if (current.isEmpty && cookies.isNotEmpty) settings[key] = cookies;
      }
      await controller.runJavaScript(
        'window.flux.settings = ${jsonEncode(settings)};'
        'window.flux.info = ${jsonEncode({'identity': plugin.identity, 'version': plugin.version, 'appVersion': kAppVersion})};',
      );
      final packet = jsonEncode({
        'url': ctx['url']?.toString() ?? '',
        'taskId':
            ctx['taskId']?.toString() ??
            'web-${DateTime.now().millisecondsSinceEpoch}',
        'cookies': ctx['cookies']?.toString() ?? '',
        'userAgent': ctx['userAgent']?.toString() ?? userAgent,
        'referrer': ctx['referrer']?.toString() ?? '',
        'resolverItem': ctx['resolverItem']?.toString() ?? '',
        'extraHeaders': ctx['extraHeaders'] ?? const <String, String>{},
      });
      await controller.runJavaScript(
        'window.__npStart(${jsonEncode(packet)}, $seq);',
      );
      return await done.future.timeout(
        Duration(milliseconds: plugin.timeoutMs),
        onTimeout: () {
          _pending = null;
          // 插件可能还卡在网络请求里；下次解析会重新加载运行时把它终止。
          _loadedPlugin = null;
          throw '解析超时（${(plugin.timeoutMs / 1000).round()} 秒）';
        },
      );
    } catch (e) {
      if (identical(_pending, done)) _pending = null;
      rethrow;
    } finally {
      if (identical(_pending, done)) _pending = null;
    }
  }

  Future<void> _ensureLoaded(
    SitePlugin plugin,
    Future<String> Function(String url) cookieFor,
    String userAgent,
  ) async {
    _cookieFor = cookieFor;
    if (_loadedPlugin == plugin.id && _ready) return;
    _ready = false;
    _readyWaiter = Completer<void>();
    _loadedPlugin = plugin.id;
    final js = await rootBundle.loadString(
      'assets/plugins/${plugin.id}/${plugin.entry}',
    );
    final html = _shellHtml(plugin, js);
    await controller.loadHtmlString(html);
    await _readyWaiter!.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw '插件运行时加载超时',
    );
  }

  Future<String> Function(String url) _cookieFor = (_) async => '';

  void _onResult(JavaScriptMessage message) {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    Map<String, dynamic> m;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) {
        _pending = null;
        pending.completeError('插件返回了无法识别的内容');
        return;
      }
      m = decoded.cast<String, dynamic>();
    } catch (e) {
      _pending = null;
      pending.completeError('解析结果无效: $e');
      return;
    }
    // 超时后重载运行时，旧页面可能迟到一条结果；序号不匹配就忽略。
    if ((m['seq'] as num?)?.toInt() != _activeSeq) return;
    _pending = null;
    if (m['ok'] == true) {
      final data = m['data'];
      pending.complete(
        data is Map
            ? data.cast<String, dynamic>()
            : <String, dynamic>{'value': data},
      );
    } else {
      pending.completeError(m['error']?.toString() ?? '解析失败');
    }
  }

  Future<void> _onBridge(JavaScriptMessage message) async {
    Map<String, dynamic> req;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) return;
      req = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final id = req['id']?.toString() ?? '';
    final op = req['op']?.toString() ?? '';
    final data = req['data'] is Map
        ? (req['data'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    if (id.isEmpty) return;
    try {
      switch (op) {
        case 'fetch':
          final r = await Core.callAsync('web_fetch', data);
          if (r['ok'] == true) {
            _reply(id, true, r['data']);
          } else {
            _reply(id, false, r['error']?.toString() ?? '请求失败');
          }
        case 'storage.get':
          _reply(
            id,
            true,
            store.pluginStorageGet(data['key']?.toString() ?? ''),
          );
        case 'storage.set':
          store.pluginStorageSet(
            data['key']?.toString() ?? '',
            data['value']?.toString() ?? '',
          );
          _reply(id, true, true);
        case 'auth.get':
          final ref = data['ref']?.toString() ?? '';
          final url = _hostFromAuthRef(ref);
          final cookie = url.isEmpty ? '' : await _cookieFor(url);
          _reply(id, true, {'cookies': cookie, 'expiresAt': 0});
        case 'log':
          final msg = data['message']?.toString() ?? '';
          if (msg.isNotEmpty) {
            logs.add(msg);
            if (logs.length > 200) logs.removeAt(0);
          }
          _reply(id, true, true);
        default:
          _reply(id, false, '不支持的操作: $op');
      }
    } catch (e) {
      _reply(id, false, e.toString());
    }
  }

  void _reply(String id, bool ok, Object? payload) {
    final text = payload is String ? payload : jsonEncode(payload);
    final script =
        'window.__npReply(${jsonEncode(id)}, ${ok ? 'true' : 'false'}, ${jsonEncode(text)});';
    unawaited(controller.runJavaScript(script).catchError((_) {}));
  }

  static String _hostFromAuthRef(String ref) {
    var s = ref.trim();
    final marker = s.indexOf('::');
    if (marker >= 0) s = s.substring(marker + 2);
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    if (s.isEmpty) return '';
    return 'https://$s/';
  }

  static const String _shim =
      '<script>window.__npPending={};'
      'window.__npReply=function(id,ok,payload){var p=window.__npPending[id];if(!p)return;'
      'delete window.__npPending[id];if(ok){try{p.resolve(JSON.parse(payload||"null"));}'
      'catch(e){p.reject(e);}}else{p.reject(new Error(String(payload||"请求失败")));}};'
      'var __npSeq=0;function __npCall(op,data){return new Promise(function(resolve,reject){'
      'var id="r"+(++__npSeq)+"_"+Date.now();window.__npPending[id]={resolve:resolve,reject:reject};'
      'NpBridge.postMessage(JSON.stringify({id:id,op:op,data:data||{}}));});}'
      'var flux={settings:{},info:{},fetch:function(o){return __npCall("fetch",o||{});},'
      'storage:{get:function(k){return __npCall("storage.get",{key:String(k)});},'
      'set:function(k,v){return __npCall("storage.set",{key:String(k),value:String(v)});}},'
      'auth:{get:function(r){return __npCall("auth.get",{ref:String(r)});}},'
      'logger:{info:function(m){__npLog(m);},warn:function(m){__npLog(m);},'
      'error:function(m){__npLog(m);},debug:function(m){__npLog(m);}},'
      'timers:{setTimeout:setTimeout,clearTimeout:clearTimeout,setInterval:setInterval,clearInterval:clearInterval},'
      'ui:{toast:function(){},h:function(){return null;},view:function(){return {};}},'
      'tasks:{create:function(){throw new Error("当前环境不支持插件创建任务");},get:function(){return null;}},'
      'events:{on:function(){return function(){};}},rpc:{handle:function(){},call:function(){return null;}}};'
      'function __npLog(m){NpBridge.postMessage(JSON.stringify({id:"log_"+Date.now(),op:"log",'
      'data:{message:String(m)}}));}window.flux=flux;'
      'window.__npStart=function(packet,seq){var ctx=JSON.parse(packet);'
      'Promise.resolve().then(function(){return globalThis.resolve?globalThis.resolve(ctx):null;})'
      '.then(function(data){NpResult.postMessage(JSON.stringify({ok:true,data:data,seq:seq}));})'
      '.catch(function(e){NpResult.postMessage(JSON.stringify({ok:false,seq:seq,'
      'error:String((e&&e.message)||e),stack:String((e&&e.stack)||"")}));});};'
      '</script>';

  static String _shellHtml(SitePlugin plugin, String js) {
    final safe = js.replaceAll('</script', '<\\/script');
    return '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>${_escapeHtml(plugin.name)}</title></head><body>'
        '$_shim<script>$safe</script></body></html>';
  }

  static String _escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
