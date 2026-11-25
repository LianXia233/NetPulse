import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../bridge.dart';
import '../download_sheet.dart';
import '../page_kit.dart';
import '../plugin_runtime.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';

/// 内置浏览器：打开网页、嗅探直链，并把链接（含 Cookie / Referer / UA）推给下载器。
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, this.initialUrl});

  final String? initialUrl;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  late final WebViewController _controller;
  final TextEditingController _address = TextEditingController();
  bool _started = false;
  bool _loading = false;
  double _progress = 0;
  String _title = '';
  String _url = '';
  List<Map<String, dynamic>> _links = [];
  AppStore? _store;
  bool _settingsApplied = false;
  late final PluginEngine _pluginEngine;
  bool _pluginsReady = false;
  final Set<String> _injectedScripts = {};

  static const String _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static final _downloadPattern = RegExp(
    r'\.(zip|apk|apks|xapk|apkm|exe|msi|dmg|iso|img|rar|7z|tar|gz|tgz|bz2|xz|zst|pdf|epub|mobi|azw3|mp4|mkv|avi|mov|flv|webm|m4v|ts|mp3|flac|wav|aac|m4a|ogg|opus|doc|docx|xls|xlsx|ppt|pptx|bin|dat|jar|aar|whl|crx|ttf|otf|woff2?|deb|rpm|ipsw|psp|3ds|rom|sav|db|sqlite|sql|csv|psd|ai|cdr|dmg\.part|7z\.001|r\d{2}|part1)(\?|#|$)',
    caseSensitive: false,
  );

  /// 流媒体清单（嗅探后单独标记，不走普通下载）。
  static final _streamPattern = RegExp(
    r'\.(m3u8|mpd|mp3\?|m3u)(\?|#|$)|/hls/|/dash/',
    caseSensitive: false,
  );

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..addJavaScriptChannel('NpPage', onMessageReceived: _onPageBridge)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => setState(() => _progress = p / 100),
          onPageStarted: (url) => setState(() {
            _loading = true;
            _url = url;
            _address.text = url;
            _injectedScripts.clear();
          }),
          onPageFinished: (url) async {
            setState(() {
              _loading = false;
              _started = true;
            });
            await _syncNav();
            if (_store?.browserSniff ?? true) {
              await _installResourceHook();
              await _sniff();
            }
            await _injectPageScripts(url);
            if (_store?.browserUaMode == 'desktop') {
              try {
                await _controller.runJavaScript(
                  "const m=document.querySelector('meta[name=viewport]');"
                  "if(m){m.setAttribute('content','width=1280');}",
                );
              } catch (_) {}
            }
            await _readTitle();
          },
          onUrlChange: (change) {
            if (change.url != null && mounted) {
              setState(() {
                _url = change.url!;
                _address.text = change.url!;
              });
            }
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame ?? true)
              pmToast(context, '打开失败：${e.description}');
          },
          onNavigationRequest: (request) {
            final url = request.url;
            if (url.startsWith('blob:') || url.startsWith('data:')) {
              pmToast(context, '该链接由网页内部生成，暂不支持直接下载');
              return NavigationDecision.prevent;
            }
            if ((_store?.browserIntercept ?? true) &&
                (_looksDownload(url) || _streamPattern.hasMatch(url))) {
              _downloadLink(url);
              return NavigationDecision.prevent;
            }
            if (!url.startsWith('http://') && !url.startsWith('https://')) {
              pmToast(context, '已拦截外部协议：${url.split(':').first}');
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store ??= AppScope.of(context);
    if (!_pluginsReady) {
      _pluginEngine = PluginEngine(store: _store!);
      _pluginEngine.init();
      _pluginsReady = true;
      SitePlugin.all().then((_) {
        if (mounted) setState(() {});
      });
    }
    if (_settingsApplied) return;
    _settingsApplied = true;
    _applyBrowserSettings().then((_) {
      if (!mounted) return;
      final initial = widget.initialUrl?.trim() ?? '';
      final home = _store?.browserHome.trim() ?? '';
      if (initial.isNotEmpty) {
        _address.text = initial;
        _go(initial);
      } else if (home.isNotEmpty) {
        _go(home);
      }
    });
  }

  String? _resolveUserAgent(AppStore store) {
    switch (store.browserUaMode) {
      case 'desktop':
        return _desktopUa;
      case 'custom':
        final custom = store.browserUaCustom.trim();
        return custom.isEmpty ? null : custom;
      default:
        return null;
    }
  }

  Future<void> _applyBrowserSettings({bool reload = false}) async {
    final store = _store;
    if (store == null) return;
    try {
      await _controller.setJavaScriptMode(
        store.browserJavaScript
            ? JavaScriptMode.unrestricted
            : JavaScriptMode.disabled,
      );
      await _controller.setUserAgent(_resolveUserAgent(store));
      await _installResourceHook();
      if (reload && _started) {
        _controller.reload();
        if (mounted) setState(() => _loading = true);
      }
    } catch (_) {}
  }

  /// 注入 fetch / XHR 钩子：页面运行期发出的资源请求（含动态生成的下载直链）
  /// 都会带 Content-Type / Content-Length 记录到 window.__npRes，供嗅探合并。
  Future<void> _installResourceHook() async {
    try {
      await _controller.runJavaScript(ResourceSnifferHook.script);
    } catch (_) {}
  }

  @override
  void dispose() {
    _address.dispose();
    if (_pluginsReady) _pluginEngine.dispose();
    super.dispose();
  }

  bool _looksDownload(String url) {
    final lower = url.toLowerCase();
    return _downloadPattern.hasMatch(lower) ||
        lower.contains('download=') ||
        lower.contains('/download/') ||
        lower.contains('dl=');
  }

  void _go(String raw) {
    var input = raw.trim();
    if (input.isEmpty) return;
    if (!input.contains('://')) {
      if (!input.contains('.') &&
          !input.contains(':') &&
          !input.contains('/')) {
        input = 'https://www.baidu.com/s?wd=${Uri.encodeComponent(input)}';
      } else {
        input = 'https://$input';
      }
    }
    final uri = Uri.tryParse(input);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      pmToast(context, '请输入有效链接');
      return;
    }
    FocusScope.of(context).unfocus();
    _controller.loadRequest(uri);
    setState(() {
      _started = true;
      _loading = true;
      _url = input;
      _address.text = input;
    });
  }

  void _goHome() {
    final home = _store?.browserHome.trim() ?? '';
    if (home.isEmpty) {
      setState(() {
        _started = false;
        _title = '';
        _url = '';
        _address.clear();
        _links = [];
      });
      return;
    }
    _go(home);
  }

  Future<void> _clearCookies() async {
    try {
      final cleared = await WebViewCookieManager().clearCookies();
      await _controller.clearLocalStorage();
      if (mounted)
        pmToast(context, cleared ? '已清除 Cookie 与本地存储' : '没有可清除的 Cookie');
    } catch (e) {
      if (mounted) pmToast(context, '清除失败：$e');
    }
  }

  Future<void> _clearCache() async {
    try {
      await _controller.clearCache();
      await _controller.clearLocalStorage();
      if (mounted) pmToast(context, '已清除网页缓存与本地存储');
    } catch (e) {
      if (mounted) pmToast(context, '清除失败：$e');
    }
  }

  void _openAdvanced() {
    final store = _store;
    if (store == null) return;
    final home = TextEditingController(text: store.browserHome);
    final ua = TextEditingController(text: store.browserUaCustom);
    var mode = store.browserUaMode;
    var js = store.browserJavaScript;
    var sniff = store.browserSniff;
    var intercept = store.browserIntercept;
    showPmSheet(
      context,
      title: '浏览器高级设置',
      body: StatefulBuilder(
        builder: (ctx, setSheet) {
          final pm = ctx.pm;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '首页留空时显示快捷入口；修改浏览器标识后会自动刷新当前页面。',
                style: ctx.text.bodySmall?.copyWith(
                  color: pm.muted,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              PmField(
                controller: home,
                label: '启动首页',
                hint: 'https://example.com（留空显示快捷入口）',
                maxLines: 2,
              ),
              const SizedBox(height: 14),
              Text('浏览器标识', style: ctx.text.bodyMedium),
              const SizedBox(height: 8),
              PmSegmented<String>(
                items: const [
                  (value: 'system', label: '系统默认'),
                  (value: 'desktop', label: '桌面版'),
                  (value: 'custom', label: '自定义'),
                ],
                value: mode,
                onChanged: (v) => setSheet(() => mode = v),
              ),
              if (mode == 'custom') ...[
                const SizedBox(height: 10),
                PmField(
                  controller: ua,
                  label: '自定义 User-Agent',
                  hint: 'Mozilla/5.0 ...',
                  maxLines: 2,
                ),
              ],
              const SizedBox(height: 12),
              _BrowserSwitchRow(
                title: 'JavaScript',
                subtitle: '关闭后网页交互和直链嗅探会失效',
                value: js,
                onChanged: (v) => setSheet(() => js = v),
              ),
              _BrowserSwitchRow(
                title: '自动嗅探直链',
                subtitle: '页面加载完成后收集可下载链接',
                value: sniff,
                onChanged: (v) => setSheet(() => sniff = v),
              ),
              _BrowserSwitchRow(
                title: '拦截下载链接',
                subtitle: '命中下载语义时直接弹出下载参数页',
                value: intercept,
                onChanged: (v) => setSheet(() => intercept = v),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: ShapeDecoration(
                  color: pm.block,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed: _clearCookies,
                        icon: const Icon(Icons.cookie_outlined, size: 17),
                        label: const Text('清除 Cookie'),
                      ),
                    ),
                    Expanded(
                      child: TextButton.icon(
                        onPressed: _clearCache,
                        icon: const Icon(
                          Icons.cleaning_services_outlined,
                          size: 17,
                        ),
                        label: const Text('清除缓存'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  TextButton(
                    onPressed: () {
                      home.clear();
                      ua.clear();
                      setSheet(() {
                        mode = 'system';
                        js = true;
                        sniff = true;
                        intercept = true;
                      });
                    },
                    child: const Text('恢复默认'),
                  ),
                  const Spacer(),
                  PmPrimaryButton(
                    label: '保存并应用',
                    icon: Icons.check_rounded,
                    expand: false,
                    onPressed: () {
                      store.setBrowserSettings(
                        home: home.text,
                        uaMode: mode,
                        uaCustom: ua.text,
                        javaScript: js,
                        sniff: sniff,
                        intercept: intercept,
                      );
                      Navigator.pop(ctx);
                      _applyBrowserSettings(reload: true);
                      if (mounted) pmToast(context, '浏览器设置已应用');
                    },
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _syncNav() async {
    await _controller.canGoBack();
    await _controller.canGoForward();
    if (mounted) setState(() {});
  }

  Future<void> _readTitle() async {
    try {
      final t = await _controller.getTitle();
      if (mounted) setState(() => _title = t ?? '');
    } catch (_) {}
  }

  Future<String> _jsString(String script) async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(script);
      var text = raw.toString();
      if (text.startsWith('"') && text.endsWith('"')) {
        text = jsonDecode(text) as String;
      }
      return text;
    } catch (_) {
      return '';
    }
  }

  Future<Map<String, String>> _headers() async {
    final ua = await _jsString('navigator.userAgent');
    final cookie = await _jsString('document.cookie');
    return {
      if (ua.isNotEmpty && ua != 'null') 'User-Agent': ua,
      if (cookie.isNotEmpty && cookie != 'null') 'Cookie': cookie,
      if (_url.isNotEmpty) 'Referer': _url,
    };
  }

  /// DOM 静态扫描 + 网络钩子记录合并；同一 URL 去重，带类型/大小标注。
  Future<void> _sniff() async {
    if ((_store?.browserJavaScript ?? true) != true) return;
    final text = await _jsString(ResourceSnifferHook.collect);
    if (text.isEmpty || text == 'null') return;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! List) return;
      final list = decoded
          .whereType<Map>()
          .map((e) {
            return {
              'url': e['url']?.toString() ?? '',
              'name': (e['name']?.toString() ?? '').trim(),
              'type': e['type']?.toString() ?? '',
              'size': e['size'] is num ? (e['size'] as num).toInt() : null,
              'source': e['source']?.toString() ?? '',
            };
          })
          .where((e) => (e['url'] ?? '').toString().startsWith('http'))
          .toList();
      // 去重（按 URL），优先保留带 size/type 信息更全的记录
      final byUrl = <String, Map<String, dynamic>>{};
      for (final e in list) {
        final u = e['url'] as String;
        final old = byUrl[u];
        if (old == null) {
          byUrl[u] = e;
        } else {
          if (((old['size'] ?? 0) == 0) && ((e['size'] ?? 0) != 0))
            byUrl[u] = e;
          if ((old['type'] ?? '').toString().isEmpty &&
              (e['type'] ?? '').toString().isNotEmpty) {
            byUrl[u] = {...byUrl[u]!, 'type': e['type']};
          }
        }
      }
      final merged = byUrl.values.toList()
        ..sort((a, b) {
          final as = (a['size'] as int?) ?? 0;
          final bs = (b['size'] as int?) ?? 0;
          return bs.compareTo(as);
        });
      if (mounted) setState(() => _links = merged.take(80).toList());
    } catch (_) {}
  }

  /// 手动重新嗅探当前页面。
  Future<void> _resniff() async {
    await _installResourceHook();
    await _sniff();
    if (mounted) {
      pmToast(context, _links.isEmpty ? '未嗅探到资源' : '已嗅探到 ${_links.length} 个资源');
    }
  }

  Future<void> _downloadLink(String url, {String? name}) async {
    final lower = url.toLowerCase();
    // M3U8 先列清晰度，GitHub 直链先测速改写；插件返回 null 时按原链接继续。
    if (lower.contains('.m3u8')) {
      final plugins = await SitePlugin.all();
      SitePlugin? m3u8;
      for (final p in plugins) {
        if (p.id == 'm3u8-pro') {
          m3u8 = p;
          break;
        }
      }
      if (m3u8 != null && mounted) {
        final handled = await _runPlugin(m3u8, url, quietIfNull: true);
        if (handled) return;
      }
    }
    if (lower.contains('github.com/') ||
        lower.contains('githubusercontent.com/')) {
      final plugins = await SitePlugin.all();
      SitePlugin? accel;
      for (final p in plugins) {
        if (p.id == 'github-accel') {
          accel = p;
          break;
        }
      }
      if (accel != null && mounted) {
        final handled = await _runPlugin(accel, url, quietIfNull: true);
        if (handled) return;
      }
    }
    final headers = await _headers();
    if (!mounted) return;
    await showDownloadSheet(
      context,
      initialUrl: url,
      extraHeaders: headers,
      suggestedName: name,
    );
  }

  void _showLinks() {
    if (_links.isEmpty) {
      pmToast(context, '当前页面没有嗅探到可下载资源；可点“重嗅探”再试');
      return;
    }
    showPmSheet(
      context,
      title: '嗅探资源（${_links.length}）',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Text(
                  '视频 · 音频 · 安装包 · 文档 · 网络钩子捕获的直链',
                  style: context.text.bodySmall?.copyWith(
                    color: context.pm.muted,
                    fontSize: 11,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _resniff();
                  },
                  icon: const Icon(Icons.refresh_rounded, size: 15),
                  label: const Text('重嗅探', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          for (final l in _links)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PmCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                radius: 16,
                onTap: () {
                  Navigator.pop(context);
                  _downloadLink(
                    l['url'].toString(),
                    name: (l['name'] as String?)?.isEmpty ?? true
                        ? null
                        : l['name'],
                  );
                },
                child: Row(
                  children: [
                    PmIconBadge(
                      _typeIcon('${l['type']} ${l['url']}'),
                      size: 32,
                      radius: 10,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (l['name'] as String?)?.isNotEmpty == true
                                ? l['name']!
                                : Uri.tryParse(l['url'].toString())
                                          ?.pathSegments
                                          .last ??
                                      l['url'].toString(),
                            style: context.text.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  l['url'].toString(),
                                  style: context.text.bodySmall?.copyWith(
                                    color: context.pm.muted,
                                    fontSize: 10,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if ((l['size'] as int?) != null &&
                                  (l['size'] as int) > 0)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: PmPill(
                                    label: _fmtSize(l['size'] as int),
                                    dense: true,
                                    color: context.pm.muted,
                                  ),
                                ),
                              if ((l['type'] ?? '').toString().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: PmPill(
                                    label: l['type'].toString(),
                                    dense: true,
                                    color: context.scheme.primary,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.download_rounded,
                      size: 18,
                      color: context.scheme.primary,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static IconData _typeIcon(String haystack) {
    final h = haystack.toLowerCase();
    if (_streamPattern.hasMatch(h)) return Icons.stream_rounded;
    if (h.contains('video') ||
        RegExp(r'\.(mp4|mkv|avi|mov|flv|webm|m4v|ts)(\?|#|$)').hasMatch(h)) {
      return Icons.videocam_rounded;
    }
    if (h.contains('audio') ||
        RegExp(r'\.(mp3|flac|wav|aac|m4a|ogg|opus)(\?|#|$)').hasMatch(h)) {
      return Icons.music_note_rounded;
    }
    if (h.contains('image')) return Icons.image_rounded;
    if (RegExp(r'\.(apk|apks|xapk|apkm|exe|msi|deb|rpm|dmg|ipsw)(\?|#|$)')
        .hasMatch(h)) {
      return Icons.install_mobile_rounded;
    }
    if (RegExp(r'\.(zip|rar|7z|tar|gz|tgz|bz2|xz|zst)(\?|#|$)').hasMatch(h)) {
      return Icons.folder_zip_rounded;
    }
    if (RegExp(r'\.(pdf|epub|mobi|azw3|docx?|xlsx?|pptx?|csv)(\?|#|$)')
        .hasMatch(h)) {
      return Icons.description_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  static String _fmtSize(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  bool _busyDialog = false;

  static IconData _pluginIcon(String id) {
    switch (id) {
      case 'm3u8-pro':
        return Icons.play_circle_outline_rounded;
      case 'github-accel':
        return Icons.rocket_launch_outlined;
      case 'quark-share':
        return Icons.cloud_outlined;
      case 'accountdl':
        return Icons.key_rounded;
      case 'musicdl':
        return Icons.music_note_rounded;
      case 'bilibili':
        return Icons.live_tv_rounded;
      default:
        return Icons.extension_rounded;
    }
  }

  Future<String> _cookiesFor(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host.isNotEmpty) {
      try {
        final list = await WebViewCookieManager().getCookies(domain: uri);
        if (list.isNotEmpty) {
          return list.map((c) => '${c.name}=${c.value}').join('; ');
        }
      } catch (_) {}
    }
    try {
      final c = await _jsString('document.cookie');
      if (c.isNotEmpty && c != 'null') return c;
    } catch (_) {}
    return '';
  }

  Future<String> _requestUserAgent() async {
    final store = _store;
    if (store?.browserUaMode == 'desktop') return _desktopUa;
    final custom = store?.browserUaCustom.trim() ?? '';
    if (store?.browserUaMode == 'custom' && custom.isNotEmpty) return custom;
    final ua = await _jsString('navigator.userAgent');
    return ua.isEmpty || ua == 'null' ? _desktopUa : ua;
  }

  void _showBusy(SitePlugin plugin) {
    if (_busyDialog || !mounted) return;
    _busyDialog = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final pm = ctx.pm;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: pm.card,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            content: Row(
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('正在解析', style: ctx.text.titleSmall),
                      const SizedBox(height: 3),
                      Text(
                        '${plugin.name} 正在请求站点接口，最长 ${(plugin.timeoutMs / 1000).round()} 秒',
                        style: ctx.text.bodySmall?.copyWith(
                          color: pm.muted,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _hideBusy() {
    if (!_busyDialog) return;
    _busyDialog = false;
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  Future<Map<String, dynamic>?> _callPlugin(
    SitePlugin plugin,
    String url, {
    String resolverItem = '',
    required String cookies,
    required String userAgent,
    required String referrer,
  }) async {
    _showBusy(plugin);
    try {
      return await _pluginEngine.resolve(
        plugin,
        {
          'url': url,
          'cookies': cookies,
          'userAgent': userAgent,
          'referrer': referrer,
          'resolverItem': resolverItem,
        },
        cookieFor: _cookiesFor,
        userAgent: userAgent,
      );
    } finally {
      _hideBusy();
    }
  }

  /// 运行插件；返回 true 表示已弹出下载参数页，false 表示插件没处理该链接。
  Future<bool> _runPlugin(
    SitePlugin plugin,
    String rawUrl, {
    bool quietIfNull = false,
  }) async {
    final url = rawUrl.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      if (!quietIfNull && mounted) pmToast(context, '请输入 http/https 链接');
      return false;
    }
    if (!Core.i.ready) {
      if (mounted) pmToast(context, '核心未就绪');
      return false;
    }
    final cookies = await _cookiesFor(url);
    final ua = await _requestUserAgent();
    final referrer = _url.trim().isEmpty || _url.trim() == url
        ? ''
        : _url.trim();
    Map<String, dynamic>? result;
    try {
      result = await _callPlugin(
        plugin,
        url,
        cookies: cookies,
        userAgent: ua,
        referrer: referrer,
      );
      var depth = 0;
      while (result != null && depth < 4) {
        final items = _manifestItems(result);
        if (items.isEmpty) break;
        final picked = await _pickManifestItem(plugin, result, items);
        if (picked == null) return true;
        final itemId =
            (picked['id'] ??
                    picked['resolverItem'] ??
                    picked['path'] ??
                    picked['guid'] ??
                    '')
                .toString();
        if (itemId.isEmpty) break;
        result = await _callPlugin(
          plugin,
          url,
          resolverItem: itemId,
          cookies: cookies,
          userAgent: ua,
          referrer: referrer,
        );
        depth++;
      }
    } catch (e) {
      if (!mounted) return false;
      final msg = e.toString().replaceFirst('Exception: ', '');
      if (!quietIfNull) {
        await showPmSheet(
          context,
          title: '${plugin.name} · 解析失败',
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(msg, style: context.text.bodySmall?.copyWith(height: 1.55)),
              if (_pluginEngine.logs.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _pluginEngine.logs.reversed.take(12).join('\n'),
                  style: context.text.bodySmall?.copyWith(
                    color: context.pm.muted,
                    fontFamily: 'monospace',
                    fontSize: 10.5,
                    height: 1.45,
                  ),
                ),
              ],
            ],
          ),
        );
      }
      return false;
    }
    if (result == null || result.isEmpty) {
      if (!quietIfNull && mounted) {
        pmToast(context, '${plugin.name} 没有处理这个链接，可按直链下载');
      }
      return false;
    }
    if (!mounted) return false;
    await _presentPluginResult(plugin, url, result);
    return true;
  }

  static List<Map<String, dynamic>> _manifestItems(
    Map<String, dynamic> result,
  ) {
    final manifest = result['manifest'];
    final raw = manifest is Map ? manifest['items'] : result['items'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  Future<Map<String, dynamic>?> _pickManifestItem(
    SitePlugin plugin,
    Map<String, dynamic> result,
    List<Map<String, dynamic>> items,
  ) async {
    final manifest = result['manifest'];
    final title = manifest is Map
        ? (manifest['name']?.toString() ?? plugin.name)
        : (result['title']?.toString() ?? plugin.name);
    return showPmSheet<Map<String, dynamic>>(
      context,
      title: '$title（${items.length} 项）',
      body: Column(
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PmCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                radius: 16,
                onTap: () => Navigator.pop(context, item),
                child: Row(
                  children: [
                    PmIconBadge(
                      item['dirs'] != null
                          ? Icons.folder_rounded
                          : Icons.insert_drive_file_rounded,
                      size: 32,
                      radius: 10,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item['name']?.toString() ??
                                item['title']?.toString() ??
                                item['id']?.toString() ??
                                '未命名条目',
                            style: context.text.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if ((item['size'] as num? ?? 0) > 0)
                            Text(
                              _fmtSize((item['size'] as num).toInt()),
                              style: context.text.bodySmall?.copyWith(
                                color: context.pm.muted,
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: context.pm.muted,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<int?> _pickVariant(
    List<Map<String, dynamic>> variants,
    int defaultIndex,
    String title,
  ) async {
    return showPmSheet<int>(
      context,
      title: '选择清晰度',
      body: Column(
        children: [
          for (var i = 0; i < variants.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PmCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                radius: 16,
                onTap: () => Navigator.pop(context, i),
                child: Row(
                  children: [
                    Icon(
                      i == defaultIndex.clamp(0, variants.length - 1)
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      size: 18,
                      color: i == defaultIndex.clamp(0, variants.length - 1)
                          ? context.scheme.primary
                          : context.pm.muted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _variantLabel(variants[i], i),
                        style: context.text.bodySmall,
                      ),
                    ),
                    if ((variants[i]['totalBytes'] as num? ?? 0) > 0)
                      PmPill(
                        label: _fmtSize(
                          (variants[i]['totalBytes'] as num).toInt(),
                        ),
                        dense: true,
                        color: context.pm.muted,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _variantLabel(Map<String, dynamic> v, int index) {
    final label = v['label']?.toString() ?? '';
    if (label.isNotEmpty) return label;
    final h = (v['height'] as num? ?? 0).toInt();
    final w = (v['width'] as num? ?? 0).toInt();
    final bw = (v['bandwidth'] as num? ?? 0).toDouble();
    final parts = <String>[
      if (h > 0) '${h}p' else if (w > 0) '${w}px' else '档位 ${index + 1}',
      if (bw > 0) '${(bw / 1000).toStringAsFixed(0)} kbps',
    ];
    return parts.join(' · ');
  }

  static Map<String, String> _pluginHeaders(
    Map<String, dynamic> result,
    Map<String, dynamic> chosen,
  ) {
    final out = <String, String>{};
    void put(String k, String v) {
      if (k.trim().isNotEmpty && v.trim().isNotEmpty) out[k.trim()] = v.trim();
    }

    void merge(Map<String, dynamic> src) {
      final h = src['extraHeaders'];
      if (h is Map) {
        h.forEach((k, v) {
          if (v != null) put(k.toString(), v.toString());
        });
      }
      final req = src['request'];
      if (req is Map) {
        final cookies = req['cookies']?.toString() ?? '';
        final referrer = req['referrer']?.toString() ?? '';
        final ua = req['userAgent']?.toString() ?? '';
        if (cookies.isNotEmpty) {
          put('Cookie', cookies);
        } else if (req.containsKey('cookies')) {
          out.remove('Cookie');
        }
        put('Referer', referrer);
        put('User-Agent', ua);
        final extra = req['headers'];
        if (extra is Map) {
          extra.forEach((k, v) {
            if (v != null) put(k.toString(), v.toString());
          });
        }
      }
    }

    merge(result);
    if (!identical(result, chosen)) merge(chosen);
    return out;
  }

  Future<void> _presentPluginResult(
    SitePlugin plugin,
    String url,
    Map<String, dynamic> result,
  ) async {
    var chosen = result;
    final rawVariants = result['variants'];
    if (rawVariants is List) {
      final variants = rawVariants
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      if (variants.isNotEmpty) {
        final def = (result['defaultVariantIndex'] as num? ?? 0).toInt();
        final index = await _pickVariant(
          variants,
          def,
          result['fileName']?.toString() ?? plugin.name,
        );
        if (index == null) return;
        chosen = variants[index];
      }
    }
    final link = (chosen['url'] ?? result['url'])?.toString() ?? '';
    if (link.isEmpty) {
      if (mounted) pmToast(context, '${plugin.name} 没有返回下载地址');
      return;
    }
    final headers = _pluginHeaders(result, chosen);
    final name =
        chosen['fileName']?.toString() ??
        result['fileName']?.toString() ??
        null;
    final audioUrl =
        (chosen['audioUrl'] ?? result['audioUrl'])?.toString() ?? '';
    final extras = <Map<String, String>>[];
    if (audioUrl.isNotEmpty) {
      final base = (name == null || name.isEmpty) ? _recordName(link) : name;
      final dot = base.lastIndexOf('.');
      final stem = dot > 0 ? base.substring(0, dot) : base;
      extras.add({'url': audioUrl, 'name': '$stem [audio].m4a'});
    }
    if (!mounted) return;
    await showDownloadSheet(
      context,
      initialUrl: link,
      extraHeaders: headers,
      suggestedName: name,
      extraDownloads: extras,
    );
  }

  Future<void> _injectPageScripts(String url) async {
    if ((_store?.browserJavaScript ?? true) != true) return;
    final plugins = await SitePlugin.all();
    for (final plugin in plugins) {
      for (final page in plugin.pageScripts) {
        if (!page.matches(url)) continue;
        // 夸克分享页由 quark-share 的专用面板处理，避免和 accountdl 的按钮重复。
        if (plugin.id == 'accountdl' && page.id == 'quark') continue;
        final key = '${plugin.id}:${page.id}';
        if (_injectedScripts.contains(key)) continue;
        _injectedScripts.add(key);
        final scripts = <String>[];
        for (final path in page.js) {
          try {
            scripts.add(
              await rootBundle.loadString('assets/plugins/${plugin.id}/$path'),
            );
          } catch (_) {}
        }
        if (scripts.isEmpty) continue;
        final safeKey = jsonEncode(key);
        final body = scripts.join('\n;\n');
        final wrapped =
            """
(function(){
  if (!window.__npInjected) window.__npInjected = {};
  if (window.__npInjected[$safeKey]) return;
  window.__npInjected[$safeKey] = 1;
  if (!window.netpulse) {
    window.__npPagePending = {};
    window.__npPageReply = function(id, ok, payload) {
      var p = window.__npPagePending[id];
      if (!p) return;
      delete window.__npPagePending[id];
      var value;
      try { value = JSON.parse(payload || 'null'); } catch (e) { value = null; }
      if (ok) p.resolve(value); else p.reject(new Error(String(payload || '解析失败')));
    };
    var seq = 0;
    function npPageCall(op, data) {
      return new Promise(function(resolve, reject) {
        var id = 'p' + (++seq) + '_' + Date.now();
        window.__npPagePending[id] = { resolve: resolve, reject: reject };
        NpPage.postMessage(JSON.stringify({ id: id, op: op, data: data || {} }));
      });
    }
    window.netpulse = {
      download: function(opts) { return npPageCall('download', opts || {}); },
      invoke: function(name, args) { return npPageCall('invoke', { name: name, args: args || {} }); }
    };
  }
  try {
$body
  } catch (e) {}
})();
""";
        try {
          await _controller.runJavaScript(wrapped);
        } catch (_) {}
      }
    }
  }

  Future<void> _onPageBridge(JavaScriptMessage message) async {
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
    if (op == 'download') {
      final link = data['url']?.toString() ?? '';
      SitePlugin? target;
      final plugins = await SitePlugin.all();
      for (final p in plugins) {
        if (p.matches(link)) {
          target = p;
          if (p.id == 'quark-share') break;
        }
      }
      if (target == null) {
        _replyPage(id, false, '没有匹配的解析器');
        return;
      }
      // 先结束页面按钮的等待，解析结果在 App 内的下载参数页确认。
      _replyPage(id, true, {'ok': true});
      if (mounted) unawaited(_runPlugin(target, link, quietIfNull: true));
    } else if (op == 'invoke') {
      // 页面脚本的 RPC（如 123 云盘同步登录态）没有宿主实现；
      // 解析器本身会用浏览器 Cookie，返回未登录即可继续。
      _replyPage(id, true, {'ok': true, 'loggedIn': false});
    } else {
      _replyPage(id, false, '不支持的操作: $op');
    }
  }

  void _replyPage(String id, bool ok, Object? payload) {
    final text = payload is String ? payload : jsonEncode(payload);
    final script =
        'window.__npPageReply(${jsonEncode(id)}, ${ok ? 'true' : 'false'}, ${jsonEncode(text)});';
    unawaited(_controller.runJavaScript(script).catchError((_) {}));
  }

  Future<void> _openSiteAssistant() async {
    final all = await SitePlugin.all();
    if (!mounted) return;
    final urlCtrl = TextEditingController(text: _url);
    StateSetter? refresh;
    urlCtrl.addListener(() => refresh?.call(() {}));
    final chosen = await showPmSheet<SitePlugin>(
      context,
      title: '站点解析',
      body: StatefulBuilder(
        builder: (ctx, setSheet) {
          refresh = setSheet;
          final url = urlCtrl.text.trim();
          final matched = all.where((p) => p.matches(url)).toList();
          final others = all.where((p) => !p.matches(url)).toList();
          Widget card(SitePlugin p, bool match) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PmCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                radius: 16,
                onTap: () => Navigator.pop(ctx, p),
                child: Row(
                  children: [
                    PmIconBadge(_pluginIcon(p.id), size: 36, radius: 11),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  p.name,
                                  style: ctx.text.bodyMedium,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (match)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: PmPill(
                                    label: '匹配',
                                    dense: true,
                                    color: ctx.scheme.primary,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            p.description,
                            style: ctx.text.bodySmall?.copyWith(
                              color: ctx.pm.muted,
                              fontSize: 10.5,
                              height: 1.35,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => _openPluginSettings(p),
                      icon: Icon(
                        Icons.tune_rounded,
                        size: 18,
                        color: ctx.pm.muted,
                      ),
                      tooltip: '插件设置',
                      visualDensity: VisualDensity.compact,
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: ctx.pm.muted,
                    ),
                  ],
                ),
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PmField(
                controller: urlCtrl,
                label: '要解析的链接',
                hint: 'https://…',
                maxLines: 2,
              ),
              const SizedBox(height: 10),
              Text(
                '已内置 M3U8 画质、GitHub 加速、B 站、夸克分享、全网音乐、网盘账号与动漫站点页面解析器。'
                'Cookie 直接取自当前浏览器登录态，只在本机使用。',
                style: ctx.text.bodySmall?.copyWith(
                  color: ctx.pm.muted,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              if (matched.isNotEmpty) ...[
                PmSectionTitle('匹配当前链接'),
                for (final p in matched) card(p, true),
              ],
              if (others.isNotEmpty) ...[
                if (matched.isNotEmpty) const SizedBox(height: 6),
                PmSectionTitle(matched.isEmpty ? '可用解析器' : '其他解析器'),
                for (final p in others) card(p, false),
              ],
            ],
          );
        },
      ),
    );
    final url = urlCtrl.text.trim();
    urlCtrl.dispose();
    if (chosen != null && mounted) {
      await _runPlugin(chosen, url);
    }
  }

  Future<void> _openPluginSettings(SitePlugin plugin) async {
    final store = _store;
    if (store == null) return;
    final saved = store.pluginSettingsOf(plugin.id);
    final values = <String, String>{};
    for (final s in plugin.settings) {
      final key = s['key']?.toString() ?? '';
      if (key.isEmpty) continue;
      values[key] = saved[key] ?? s['default']?.toString() ?? '';
    }
    final controllers = {
      for (final e in values.entries)
        e.key: TextEditingController(text: e.value),
    };
    String? cookieKey;
    for (final s in plugin.settings) {
      final key = s['key']?.toString() ?? '';
      if (key.toLowerCase().contains('cookie')) {
        cookieKey = key;
        break;
      }
    }
    await showPmSheet(
      context,
      title: '${plugin.name} 设置',
      body: StatefulBuilder(
        builder: (ctx, setSheet) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '这些设置只保存在本机。${plugin.description}',
                style: ctx.text.bodySmall?.copyWith(
                  color: ctx.pm.muted,
                  height: 1.45,
                ),
              ),
              if (cookieKey != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      final cookie = await _cookiesFor(_url);
                      if (cookie.isEmpty) {
                        if (ctx.mounted) pmToast(ctx, '当前页面没有 Cookie，请先登录');
                        return;
                      }
                      controllers[cookieKey]?.text = cookie;
                      setSheet(() {});
                      if (ctx.mounted) pmToast(ctx, '已填入当前站点的 Cookie');
                    },
                    icon: const Icon(Icons.cookie_outlined, size: 17),
                    label: const Text('从当前页面读取 Cookie'),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              for (final s in plugin.settings)
                if ((s['key']?.toString() ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _pluginSettingField(
                      ctx,
                      s,
                      controllers[s['key'].toString()]!,
                      setSheet,
                    ),
                  ),
              const SizedBox(height: 8),
              PmPrimaryButton(
                label: '保存设置',
                icon: Icons.check_rounded,
                onPressed: () {
                  for (final s in plugin.settings) {
                    final key = s['key']?.toString() ?? '';
                    if (key.isEmpty) continue;
                    store.setPluginSetting(
                      plugin.id,
                      key,
                      controllers[key]?.text.trim() ?? '',
                    );
                  }
                  Navigator.pop(ctx);
                  if (mounted) pmToast(context, '${plugin.name} 设置已保存');
                },
              ),
            ],
          );
        },
      ),
    );
    for (final c in controllers.values) {
      c.dispose();
    }
  }

  Widget _pluginSettingField(
    BuildContext ctx,
    Map<String, dynamic> setting,
    TextEditingController controller,
    void Function(void Function()) setSheet,
  ) {
    final key = setting['key']?.toString() ?? '';
    final title = setting['title']?.toString() ?? key;
    final desc = setting['description']?.toString() ?? '';
    final widget = setting['widget']?.toString() ?? 'text';
    final type = setting['type']?.toString() ?? 'string';
    final options = (setting['options'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    if (type == 'boolean' || widget == 'toggle' || widget == 'switch') {
      final on = controller.text == 'true';
      return Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: ctx.text.bodyMedium),
                if (desc.isNotEmpty)
                  Text(
                    desc,
                    style: ctx.text.bodySmall?.copyWith(
                      color: ctx.pm.muted,
                      fontSize: 10.5,
                      height: 1.4,
                    ),
                  ),
              ],
            ),
          ),
          Switch.adaptive(
            value: on,
            onChanged: (v) {
              controller.text = v ? 'true' : 'false';
              setSheet(() {});
            },
          ),
        ],
      );
    }
    if (widget == 'select' && options.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: ctx.text.bodyMedium),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final o in options)
                ChoiceChip(
                  label: Text(
                    o['label']?.toString() ?? o['value']?.toString() ?? '',
                    style: const TextStyle(fontSize: 11),
                  ),
                  selected: controller.text == o['value']?.toString(),
                  onSelected: (_) {
                    controller.text = o['value']?.toString() ?? '';
                    setSheet(() {});
                  },
                ),
            ],
          ),
          if (desc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                desc,
                style: ctx.text.bodySmall?.copyWith(
                  color: ctx.pm.muted,
                  fontSize: 10.5,
                  height: 1.4,
                ),
              ),
            ),
        ],
      );
    }
    return PmField(
      controller: controller,
      label: title,
      hint: desc.isEmpty ? null : desc,
      maxLines: widget == 'textarea' ? 4 : 1,
      keyboardType: setting['type']?.toString() == 'number'
          ? TextInputType.number
          : TextInputType.text,
    );
  }

  String _recordName(String url) {
    final uri = Uri.tryParse(url);
    final segs =
        uri?.pathSegments.where((e) => e.isNotEmpty).toList() ??
        const <String>[];
    if (segs.isEmpty) return 'netpulse_download.bin';
    var name = segs.last;
    if (name.endsWith('.m3u8'))
      return '${name.substring(0, name.length - 5)}.ts';
    if (name.endsWith('.mpd'))
      return '${name.substring(0, name.length - 4)}.mp4';
    return name;
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    return Scaffold(
      backgroundColor: pm.page,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      _BrowserCircleButton(
                        icon: Icons.close_rounded,
                        onTap: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          height: 46,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: ShapeDecoration(
                            color: pm.card,
                            shape: const StadiumBorder(),
                            shadows: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: context.isDark ? 0.28 : 0.06,
                                ),
                                blurRadius: 16,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              GestureDetector(
                                onTap: _goHome,
                                behavior: HitTestBehavior.opaque,
                                child: Icon(
                                  Icons.home_rounded,
                                  size: 19,
                                  color: scheme.primary,
                                ),
                              ),
                              const SizedBox(width: 9),
                              Icon(
                                _url.startsWith('https://')
                                    ? Icons.lock_rounded
                                    : Icons.language_rounded,
                                size: 13,
                                color: _url.startsWith('https://')
                                    ? pm.ok
                                    : pm.muted,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: TextField(
                                  controller: _address,
                                  style: context.text.bodyMedium?.copyWith(
                                    fontSize: 13.5,
                                  ),
                                  textInputAction: TextInputAction.go,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  decoration: InputDecoration(
                                    isDense: true,
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                    hintText: '输入网址或搜索内容',
                                    hintStyle: context.text.bodySmall?.copyWith(
                                      color: pm.muted,
                                    ),
                                  ),
                                  onSubmitted: _go,
                                ),
                              ),
                              if (_address.text.isNotEmpty)
                                GestureDetector(
                                  onTap: () => setState(_address.clear),
                                  child: Icon(
                                    Icons.cancel_rounded,
                                    size: 15,
                                    color: pm.muted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _BrowserCircleButton(
                        icon: Icons.tune_rounded,
                        accent: true,
                        onTap: _openAdvanced,
                      ),
                    ],
                  ),
                ),
                if (_loading)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: _progress == 0 ? null : _progress,
                        minHeight: 3,
                        backgroundColor: pm.track,
                        valueColor: AlwaysStoppedAnimation(scheme.primary),
                      ),
                    ),
                  ),
                if (_title.isNotEmpty && _started)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: ShapeDecoration(
                        color: pm.card,
                        shape: const StadiumBorder(),
                      ),
                      child: Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodySmall?.copyWith(
                          color: pm.muted,
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: _started
                          ? WebViewWidget(controller: _controller)
                          : _BrowserHome(
                              onOpen: _go,
                              onPaste: _paste,
                              onSettings: _openAdvanced,
                            ),
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(21, 6, 21, 8),
                  child: Container(
                    height: 60,
                    decoration: ShapeDecoration(
                      color: pm.card,
                      shape: const StadiumBorder(),
                      shadows: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: context.isDark ? 0.38 : 0.09,
                          ),
                          blurRadius: 22,
                          offset: const Offset(0, 7),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _NavButton(
                            icon: Icons.arrow_back_rounded,
                            label: '后退',
                            onTap: () async {
                              if (await _controller.canGoBack()) {
                                await _controller.goBack();
                                await _syncNav();
                              }
                            },
                          ),
                        ),
                        Expanded(
                          child: _NavButton(
                            icon: Icons.arrow_forward_rounded,
                            label: '前进',
                            onTap: () async {
                              if (await _controller.canGoForward()) {
                                await _controller.goForward();
                                await _syncNav();
                              }
                            },
                          ),
                        ),
                        Expanded(
                          child: _NavButton(
                            icon: Icons.refresh_rounded,
                            label: '刷新',
                            onTap: () {
                              _controller.reload();
                              setState(() => _loading = true);
                            },
                          ),
                        ),
                        Expanded(
                          child: _NavButton(
                            icon: Icons.link_rounded,
                            label:
                                '资源${_links.isEmpty ? '' : ' ${_links.length}'}',
                            accent: _links.isNotEmpty,
                            onTap: _showLinks,
                          ),
                        ),
                        Expanded(
                          child: _NavButton(
                            icon: Icons.auto_awesome_rounded,
                            label: '解析',
                            accent:
                                _url.isNotEmpty &&
                                SitePlugin.matching(_url).isNotEmpty,
                            onTap: _openSiteAssistant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_pluginsReady)
            Positioned(
              right: 0,
              bottom: 0,
              width: 1,
              height: 1,
              child: IgnorePointer(
                child: WebViewWidget(controller: _pluginEngine.controller),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      pmToast(context, '剪贴板为空');
      return;
    }
    _address.text = text;
    _go(text);
  }
}

class _BrowserHome extends StatelessWidget {
  const _BrowserHome({
    required this.onOpen,
    required this.onPaste,
    required this.onSettings,
  });

  final void Function(String url) onOpen;
  final VoidCallback onPaste;
  final VoidCallback onSettings;

  static const _quick = [
    ('常用下载站', 'https://www.coolapk.com/apk', Icons.android_rounded),
    ('GitHub Releases', 'https://github.com/trending', Icons.code_rounded),
    ('Cloudflare', 'https://speed.cloudflare.com/', Icons.speed_rounded),
    ('百度', 'https://www.baidu.com', Icons.search_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return ListView(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 12, kPagePadding, 20),
      children: [
        PmCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  PmIconBadge(
                    Icons.travel_explore_rounded,
                    size: 40,
                    radius: 12,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('内置浏览器', style: context.text.titleMedium),
                        Text(
                          '打开网页后，直链与鉴权参数可一键推送到下载器',
                          style: context.text.bodySmall?.copyWith(
                            color: pm.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: PmPrimaryButton(
                      label: '粘贴链接',
                      icon: Icons.content_paste_rounded,
                      expand: true,
                      onPressed: onPaste,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: PmPrimaryButton(
                      label: '浏览器设置',
                      icon: Icons.tune_rounded,
                      expand: true,
                      onPressed: onSettings,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        PmSectionTitle('快捷入口'),
        for (final q in _quick)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: PmCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              radius: 16,
              onTap: () => onOpen(q.$2),
              child: Row(
                children: [
                  PmIconBadge(q.$3, size: 34, radius: 10),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(q.$1, style: context.text.bodyMedium),
                        Text(
                          q.$2,
                          style: context.text.bodySmall?.copyWith(
                            color: pm.muted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.north_east_rounded, size: 16, color: pm.muted),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final color = accent ? context.scheme.primary : pm.muted;
    return InkWell(
      onTap: onTap,
      splashFactory: NoSplash.splashFactory,
      borderRadius: BorderRadius.circular(30),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: 10.5,
              color: color,
              fontWeight: accent ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowserCircleButton extends StatelessWidget {
  const _BrowserCircleButton({
    required this.icon,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 42,
        height: 42,
        decoration: ShapeDecoration(
          color: pm.card,
          shape: const StadiumBorder(),
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: context.isDark ? 0.28 : 0.06,
              ),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(
          icon,
          size: 20,
          color: accent ? context.scheme.primary : context.scheme.onSurface,
        ),
      ),
    );
  }
}

class _BrowserSwitchRow extends StatelessWidget {
  const _BrowserSwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.bodyMedium),
                Text(
                  subtitle,
                  style: context.text.bodySmall?.copyWith(
                    color: pm.muted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeTrackColor: context.scheme.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// 资源嗅探钩子：注入页面后持续记录网络请求与媒体元素。
class ResourceSnifferHook {
  /// 安装 fetch / XHR 钩子；幂等（重复注入直接返回）。
  static const String script = r'''
(() => {
  if (window.__npHookInstalled) return 'ok';
  window.__npHookInstalled = true;
  window.__npRes = [];
  const push = (rec) => {
    try {
      if (!rec || !rec.url || !/^https?:/.test(rec.url)) return;
      if (window.__npRes.length < 400) window.__npRes.push(rec);
    } catch (e) {}
  };
  // fetch 钩子
  const origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function (...args) {
      const url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
      const p = origFetch.apply(this, args);
      p.then(res => {
        try {
          push({
            url: res.url || url,
            type: res.headers.get('content-type') || '',
            size: Number(res.headers.get('content-length')) || 0,
            source: 'fetch',
          });
        } catch (e) { push({url: url, type: '', size: 0, source: 'fetch'}); }
      }).catch(() => push({url: url, type: '', size: 0, source: 'fetch'}));
      return p;
    };
  }
  // XHR 钩子
  const OrigOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__npUrl = url;
    this.addEventListener('load', () => {
      try {
        const ct = this.getResponseHeader('content-type') || '';
        const cl = this.getResponseHeader('content-length') || '0';
        push({url: this.responseURL || this.__npUrl, type: ct, size: Number(cl) || 0, source: 'xhr'});
      } catch (e) {}
    });
    return OrigOpen.apply(this, arguments);
  };
  return 'ok';
})()
''';

  /// 收集：网络钩子记录 + DOM 媒体/直链扫描，合并去重后返回 JSON 数组文本。
  static const String collect = r'''
(() => {
  const re = /\.(zip|apk|apks|xapk|apkm|exe|msi|dmg|iso|img|rar|7z|tar|gz|tgz|bz2|xz|zst|pdf|epub|mobi|azw3|mp4|mkv|avi|mov|flv|webm|m4v|ts|mp3|flac|wav|aac|m4a|ogg|opus|doc|docx|xls|xlsx|ppt|pptx|bin|dat|jar|aar|whl|crx|ttf|otf|woff2?|deb|rpm|ipsw|db|sqlite|sql|csv)(\?|#|$)/i;
  const streamRe = /\.(m3u8|mpd|m3u)(\?|#|$)/i;
  const out = [];
  const seen = {};
  const add = (url, name, type, size, source) => {
    try {
      if (!url || !/^https?:/.test(url)) return;
      if (seen[url]) {
        if (!seen[url].size && size) seen[url].size = size;
        if (!seen[url].type && type) seen[url].type = type;
        return;
      }
      seen[url] = {url: url, name: name || '', type: type || '', size: size || 0, source: source || ''};
      out.push(seen[url]);
    } catch (e) {}
  };
  // 1) 网络钩子记录：过滤出"像资源"的响应（大体积 / 媒体 / 下载扩展名）
  (window.__npRes || []).forEach(r => {
    const u = r.url || '';
    const looksRes = r.size > 100000 || /video|audio|application\/(zip|x-7z|rar|octet-stream|pdf|epub)/i.test(r.type || '') || re.test(u) || streamRe.test(u);
    if (looksRes) {
      const isStream = streamRe.test(u);
      add(u, '', isStream ? 'stream' : r.type, r.size, 'net');
    }
  });
  // 2) a[download] 与下载扩展名直链
  document.querySelectorAll('a[href]').forEach(a => {
    const href = a.href || '';
    if (!href.startsWith('http')) return;
    const text = (a.getAttribute('download') || a.textContent || '').trim().slice(0, 120);
    if (a.hasAttribute('download')) { add(href, text, 'download', 0, 'dom'); return; }
    if (streamRe.test(href)) { add(href, text, 'stream', 0, 'dom'); }
    else if (re.test(href)) { add(href, text, 'file', 0, 'dom'); }
  });
  // 3) 媒体元素（video / source / audio）
  document.querySelectorAll('video,source,audio').forEach(m => {
    const src = m.src || m.currentSrc || m.getAttribute('src') || '';
    if (src) add(src, '', m.tagName === 'AUDIO' ? 'audio' : 'video', 0, 'media');
    const poster = m.getAttribute('poster');
    if (poster && /^https?:/.test(poster)) add(poster, '', 'poster', 0, 'media');
  });
  // 4) blob 视频源背后的真实地址提示（部分站点把直链放 data-* 里）
  document.querySelectorAll('video[src^="blob:"]').forEach(v => {
    const hint = v.getAttribute('data-src') || v.getAttribute('data-video') || '';
    if (/^https?:/.test(hint)) add(hint, '', 'video', 0, 'media');
  });
  return JSON.stringify(out.slice(0, 80));
})()
''';
}
