import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../download_sheet.dart';
import '../page_kit.dart';
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

  static const String _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static final _downloadPattern = RegExp(
    r'\.(zip|apk|apks|xapk|exe|msi|dmg|iso|img|rar|7z|tar|gz|tgz|bz2|xz|pdf|epub|mobi|mp4|mkv|avi|mov|flv|webm|mp3|flac|wav|aac|m4a|doc|docx|xls|xlsx|ppt|pptx|bin|dat|jar|aar|whl|crx|ttf|otf)(\?|#|$)',
    caseSensitive: false,
  );

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => setState(() => _progress = p / 100),
          onPageStarted: (url) => setState(() {
            _loading = true;
            _url = url;
            _address.text = url;
          }),
          onPageFinished: (url) async {
            setState(() {
              _loading = false;
              _started = true;
            });
            await _syncNav();
            if ((_store?.browserSniff ?? true) &&
                (_store?.browserJavaScript ?? true)) {
              await _sniff();
            }
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
            if (e.isForMainFrame ?? true) pmToast(context, '打开失败：${e.description}');
          },
          onNavigationRequest: (request) {
            final url = request.url;
            if (url.startsWith('blob:') || url.startsWith('data:')) {
              pmToast(context, '该链接由网页内部生成，暂不支持直接下载');
              return NavigationDecision.prevent;
            }
            if ((_store?.browserIntercept ?? true) && _looksDownload(url)) {
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
      if (reload && _started) {
        _controller.reload();
        if (mounted) setState(() => _loading = true);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _address.dispose();
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
      if (!input.contains('.') && !input.contains(':') && !input.contains('/')) {
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
      if (mounted) pmToast(context, cleared ? '已清除 Cookie 与本地存储' : '没有可清除的 Cookie');
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
                style: ctx.text.bodySmall?.copyWith(color: pm.muted, height: 1.45),
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
                        icon: const Icon(Icons.cleaning_services_outlined, size: 17),
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

  Future<void> _sniff() async {
    const script = r'''
(() => {
  const re = /\.(zip|apk|apks|xapk|exe|msi|dmg|iso|img|rar|7z|tar|gz|tgz|bz2|xz|pdf|epub|mobi|mp4|mkv|avi|mov|flv|webm|mp3|flac|wav|aac|m4a|doc|docx|xls|xlsx|ppt|pptx|bin|dat|jar|aar|whl|crx|ttf|otf)(\?|#|$)/i;
  const out = [];
  document.querySelectorAll('a[href]').forEach(a => {
    const href = a.href || '';
    if (!href.startsWith('http')) return;
    if (a.hasAttribute('download') || re.test(href)) {
      out.push({url: href, name: (a.getAttribute('download') || a.textContent || '').trim().slice(0, 120)});
    }
  });
  return JSON.stringify(out.slice(0, 60));
})()
''';
    final text = await _jsString(script);
    if (text.isEmpty || text == 'null') return;
    try {
      final list = (jsonDecode(text) as List).whereType<Map>().map((e) {
        return {
          'url': e['url']?.toString() ?? '',
          'name': e['name']?.toString() ?? '',
        };
      }).where((e) => (e['url'] ?? '').toString().startsWith('http')).toList();
      if (mounted) setState(() => _links = list);
    } catch (_) {}
  }

  Future<void> _downloadLink(String url, {String? name}) async {
    final headers = await _headers();
    if (!mounted) return;
    await showDownloadSheet(context, initialUrl: url, extraHeaders: headers, suggestedName: name);
  }

  void _showLinks() {
    if (_links.isEmpty) {
      pmToast(context, '当前页面没有嗅探到可下载链接');
      return;
    }
    showPmSheet(
      context,
      title: '页面链接（${_links.length}）',
      body: Column(
        children: [
          for (final l in _links)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PmCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                radius: 16,
                onTap: () {
                  Navigator.pop(context);
                  _downloadLink(l['url'].toString(), name: (l['name'] as String?)?.isEmpty ?? true ? null : l['name']);
                },
                child: Row(
                  children: [
                    PmIconBadge(Icons.insert_drive_file_rounded, size: 32, radius: 10),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (l['name'] as String?)?.isNotEmpty == true ? l['name'] : l['url'],
                            style: context.text.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            l['url'].toString(),
                            style: context.text.bodySmall?.copyWith(color: context.pm.muted, fontSize: 10),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.download_rounded, size: 18, color: context.scheme.primary),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    return Scaffold(
      backgroundColor: pm.page,
      body: SafeArea(
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
                            color: _url.startsWith('https://') ? pm.ok : pm.muted,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: TextField(
                              controller: _address,
                              style: context.text.bodyMedium?.copyWith(fontSize: 13.5),
                              textInputAction: TextInputAction.go,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                                hintText: '输入网址或搜索内容',
                                hintStyle: context.text.bodySmall?.copyWith(color: pm.muted),
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
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: ShapeDecoration(
                    color: pm.card,
                    shape: const StadiumBorder(),
                  ),
                  child: Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall?.copyWith(color: pm.muted),
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
                        label: '链接${_links.isEmpty ? '' : ' ${_links.length}'}',
                        accent: _links.isNotEmpty,
                        onTap: _showLinks,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
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
                  PmIconBadge(Icons.travel_explore_rounded, size: 40, radius: 12),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('内置浏览器', style: context.text.titleMedium),
                        Text(
                          '打开网页后，直链与鉴权参数可一键推送到下载器',
                          style: context.text.bodySmall?.copyWith(color: pm.muted),
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
                        Text(q.$2, style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11)),
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
              color: Colors.black.withValues(alpha: context.isDark ? 0.28 : 0.06),
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
