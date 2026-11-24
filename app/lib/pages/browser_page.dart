import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../download_sheet.dart';
import '../page_kit.dart';
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
            await _sniff();
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
            if (_looksDownload(url)) {
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
    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      _address.text = widget.initialUrl!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _go(widget.initialUrl!));
    }
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
    if (!input.contains('://')) input = 'https://$input';
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
    return Scaffold(
      backgroundColor: pm.page,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, kPagePadding, 6),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    visualDensity: VisualDensity.compact,
                  ),
                  Expanded(
                    child: Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: ShapeDecoration(
                        color: pm.card,
                        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _url.startsWith('https://') ? Icons.lock_rounded : Icons.language_rounded,
                            size: 14,
                            color: _url.startsWith('https://') ? pm.ok : pm.muted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _address,
                              style: context.text.bodyMedium,
                              textInputAction: TextInputAction.go,
                              decoration: InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                hintText: '输入或粘贴链接',
                                hintStyle: context.text.bodySmall?.copyWith(color: pm.muted),
                              ),
                              onSubmitted: _go,
                            ),
                          ),
                          if (_address.text.isNotEmpty)
                            GestureDetector(
                              onTap: () => setState(_address.clear),
                              child: Icon(Icons.cancel_rounded, size: 15, color: pm.muted),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  PmIconAction(icon: Icons.arrow_forward_rounded, onTap: () => _go(_address.text)),
                ],
              ),
            ),
            if (_loading)
              LinearProgressIndicator(
                value: _progress == 0 ? null : _progress,
                minHeight: 2,
                backgroundColor: pm.track,
                valueColor: AlwaysStoppedAnimation(context.scheme.primary),
              )
            else
              const SizedBox(height: 2),
            if (_title.isNotEmpty && _started)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall?.copyWith(color: pm.muted),
                ),
              ),
            Expanded(
              child: _started
                  ? WebViewWidget(controller: _controller)
                  : _BrowserHome(onOpen: _go, onPaste: _paste),
            ),
            Container(
              decoration: BoxDecoration(
                color: pm.card,
                border: Border(top: BorderSide(color: pm.inset, width: 0.5)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _NavButton(
                    icon: Icons.arrow_back_rounded,
                    label: '后退',
                    onTap: () async {
                      if (await _controller.canGoBack()) {
                        await _controller.goBack();
                        await _syncNav();
                      }
                    },
                  ),
                  _NavButton(
                    icon: Icons.arrow_forward_rounded,
                    label: '前进',
                    onTap: () async {
                      if (await _controller.canGoForward()) {
                        await _controller.goForward();
                        await _syncNav();
                      }
                    },
                  ),
                  _NavButton(
                    icon: Icons.refresh_rounded,
                    label: '刷新',
                    onTap: () {
                      _controller.reload();
                      setState(() => _loading = true);
                    },
                  ),
                  _NavButton(
                    icon: Icons.link_rounded,
                    label: '链接${_links.isEmpty ? '' : ' ${_links.length}'}',
                    onTap: _showLinks,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
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
  const _BrowserHome({required this.onOpen, required this.onPaste});

  final void Function(String url) onOpen;
  final VoidCallback onPaste;

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
  const _NavButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 21, color: pm.muted),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11.5, color: pm.muted, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
