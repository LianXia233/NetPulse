import 'dart:async';

import 'package:flutter/material.dart';

import '../page_kit.dart';
import '../store.dart';
import '../theme.dart';
import '../userscript.dart';
import '../widgets.dart';
import 'browser_page.dart';

/// 用户脚本管理器：查看、启停、更新、删除 GreasyFork / Tampermonkey 脚本。
class UserScriptsPage extends StatefulWidget {
  const UserScriptsPage({super.key});

  @override
  State<UserScriptsPage> createState() => _UserScriptsPageState();
}

class _UserScriptsPageState extends State<UserScriptsPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await UserScriptStore.i.ensureLoaded();
    if (mounted) setState(() {});
  }

  Future<void> _import() async {
    final urlC = TextEditingController();
    final srcC = TextEditingController();
    var mode = 'url';
    var busy = false;
    var error = '';
    await showPmSheet<void>(
      context,
      title: '添加用户脚本',
      maxHeight: 0.9,
      body: StatefulBuilder(
        builder: (ctx, setSheet) {
          final pm = ctx.pm;
          Future<void> submit() async {
            final store = UserScriptStore.i;
            setSheet(() {
              busy = true;
              error = '';
            });
            final r = mode == 'url'
                ? (urlC.text.trim().contains('/scripts/') &&
                          !urlC.text.trim().endsWith('.user.js')
                      ? await store.installFromPage(urlC.text.trim())
                      : await store.installFromUrl(urlC.text.trim()))
                : await store.install(srcC.text);
            if (!ctx.mounted) return;
            setSheet(() => busy = false);
            if (r.script == null) {
              setSheet(() => error = r.error);
              return;
            }
            final s = r.script!;
            Navigator.pop(ctx);
            if (!mounted) return;
            setState(() {});
            pmToast(
              context,
              '已安装 ${s.name}${s.version.isEmpty ? '' : ' v${s.version}'}',
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '支持 GreasyFork 脚本页链接、.user.js 直链，或直接粘贴脚本源码。'
                '@require 依赖与 @resource 资源会在安装时一并抓取，之后离线也能跑。',
                style: ctx.text.bodySmall?.copyWith(
                  color: pm.muted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              PmSegmented<String>(
                items: const [
                  (value: 'url', label: '链接导入'),
                  (value: 'code', label: '粘贴代码'),
                ],
                value: mode,
                onChanged: (v) => setSheet(() => mode = v),
              ),
              const SizedBox(height: 12),
              if (mode == 'url')
                PmField(
                  controller: urlC,
                  label: '脚本链接',
                  hint: 'https://greasyfork.org/zh-CN/scripts/… 或 *.user.js',
                  maxLines: 2,
                )
              else
                PmField(
                  controller: srcC,
                  label: '脚本源码',
                  hint: '// ==UserScript== …',
                  maxLines: 8,
                ),
              if (error.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  error,
                  style: ctx.text.bodySmall?.copyWith(color: pm.warn),
                ),
              ],
              const SizedBox(height: 14),
              PmPrimaryButton(
                label: busy ? '正在安装…' : '安装',
                icon: Icons.download_done_rounded,
                loading: busy,
                onPressed: busy
                    ? null
                    : () {
                        if (mode == 'url' && urlC.text.trim().isEmpty) {
                          setSheet(() => error = '请填写脚本链接');
                          return;
                        }
                        if (mode == 'code' && srcC.text.trim().isEmpty) {
                          setSheet(() => error = '请粘贴脚本源码');
                          return;
                        }
                        unawaited(submit());
                      },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _detail(UserScript script) async {
    await showPmSheet<void>(
      context,
      title: script.name,
      maxHeight: 0.9,
      body: _ScriptDetail(
        script: script,
        onToggle: (v) async {
          await UserScriptStore.i.setEnabled(script.id, v);
          if (mounted) setState(() {});
        },
        onUpdate: () => _checkUpdate(script),
        onDelete: () => _delete(script),
      ),
    );
  }

  Future<void> _checkUpdate(UserScript script) async {
    setState(() => _busy = true);
    final r = await UserScriptStore.i.checkUpdate(script);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.error.isNotEmpty) {
      pmToast(context, r.error);
      return;
    }
    pmToast(
      context,
      r.updated ? '已更新到 v${r.version}' : '已是最新版本（v${r.version}）',
    );
  }

  Future<void> _delete(UserScript script) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除脚本'),
        content: Text('将删除「${script.name}」及其本地数据，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: ctx.pm.warn)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await UserScriptStore.i.remove(script.id);
    if (!mounted) return;
    Navigator.of(context).maybePop();
    setState(() {});
    pmToast(context, '已删除 ${script.name}');
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final store = AppScope.of(context);
    final scripts = UserScriptStore.i.scripts;
    final enabled = scripts.where((s) => s.enabled).length;
    return Scaffold(
      backgroundColor: pm.page,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            PmPageHeader(
              title: '用户脚本',
              subtitle: 'GreasyFork / Tampermonkey 兼容',
              showBack: true,
              actions: [
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                PmIconAction(icon: Icons.add_rounded, onTap: _import),
              ],
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  kPagePadding,
                  0,
                  kPagePadding,
                  24,
                ),
                children: [
                  PmCard(
                    padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                    child: Row(
                      children: [
                        PmIconBadge(
                          Icons.extension_rounded,
                          size: 38,
                          radius: 12,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '在网页中运行用户脚本',
                                style: context.text.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '共 ${scripts.length} 个 · 启用 $enabled 个',
                                style: context.text.bodySmall?.copyWith(
                                  color: pm.muted,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch.adaptive(
                          value: store.userScriptsEnabled,
                          onChanged: (v) => store.setUserScriptsEnabled(v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (scripts.isEmpty)
                    _empty(pm)
                  else ...[
                    for (final s in scripts) ...[
                      _scriptCard(s),
                      const SizedBox(height: 8),
                    ],
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const BrowserPage(
                                initialUrl: 'https://greasyfork.org/zh-CN',
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.public_rounded, size: 17),
                          label: const Text('浏览 GreasyFork'),
                        ),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _import,
                          icon: const Icon(Icons.link_rounded, size: 17),
                          label: const Text('从链接安装'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '脚本在内置浏览器中按 @match 规则自动运行；'
                    'GreasyFork 页面会多出「安装到 NetPulse」按钮。',
                    style: context.text.bodySmall?.copyWith(
                      color: pm.muted,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(PmColors pm) => PmCard(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
    child: Column(
      children: [
        Icon(Icons.code_off_rounded, size: 30, color: pm.muted),
        const SizedBox(height: 10),
        Text(
          '还没有安装用户脚本',
          style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '打开 GreasyFork，脚本页会出现「安装到 NetPulse」按钮。',
          textAlign: TextAlign.center,
          style: context.text.bodySmall?.copyWith(color: pm.muted, height: 1.5),
        ),
      ],
    ),
  );

  Widget _scriptCard(UserScript s) {
    final pm = context.pm;
    final hosts = s.hostHints;
    return PmCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      onTap: () => _detail(s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PmIconBadge(
            s.enabled ? Icons.code_rounded : Icons.code_off_rounded,
            size: 38,
            radius: 12,
            color: s.enabled ? null : pm.muted,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        s.name,
                        style: context.text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (s.version.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        'v${s.version}',
                        style: context.text.bodySmall?.copyWith(
                          color: pm.muted,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ],
                ),
                if (s.description.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    s.description,
                    style: context.text.bodySmall?.copyWith(
                      color: pm.muted,
                      fontSize: 11,
                      height: 1.35,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (hosts.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 5,
                    runSpacing: 4,
                    children: [
                      for (final h in hosts.take(3))
                        PmPill(label: h, dense: true),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Switch.adaptive(
            value: s.enabled,
            onChanged: (v) async {
              await UserScriptStore.i.setEnabled(s.id, v);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

class _ScriptDetail extends StatelessWidget {
  const _ScriptDetail({
    required this.script,
    required this.onToggle,
    required this.onUpdate,
    required this.onDelete,
  });

  final UserScript script;
  final Future<void> Function(bool) onToggle;
  final Future<void> Function() onUpdate;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final rows = <(String, String)>[
      if (script.version.isNotEmpty) ('版本', script.version),
      if (script.author.isNotEmpty) ('作者', script.author),
      if (script.namespace.isNotEmpty) ('命名空间', script.namespace),
      ('运行时机', _runAtLabel(script.runAt)),
      ('体积', formatBytes(script.bytes.toDouble())),
      if (script.grant.isNotEmpty) ('申请权限', script.grant.join('、')),
      if (script.requires.isNotEmpty) ('依赖库', '${script.requires.length} 个'),
      if (script.resources.isNotEmpty) ('脚本资源', '${script.resources.length} 个'),
      if (script.sourceUrl.isNotEmpty) ('安装来源', script.sourceUrl),
    ];
    final patterns = [...script.match, ...script.include];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (script.description.isNotEmpty) ...[
          Text(
            script.description,
            style: context.text.bodySmall?.copyWith(
              color: pm.muted,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
        ],
        PmCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Column(
            children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 72,
                        child: Text(
                          r.$1,
                          style: context.text.bodySmall?.copyWith(
                            color: pm.muted,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          r.$2,
                          style: context.text.bodySmall?.copyWith(
                            fontSize: 12,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (patterns.isNotEmpty) ...[
          const SizedBox(height: 12),
          PmSectionTitle('匹配规则', subtitle: '仅在命中的页面注入'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in patterns)
                PmPill(label: p, dense: true),
            ],
          ),
        ],
        if (script.exclude.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in script.exclude)
                PmPill(label: '排除 $p', dense: true, color: pm.warn),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: onUpdate,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('检查更新'),
              ),
            ),
            Expanded(
              child: TextButton.icon(
                onPressed: onDelete,
                icon: Icon(Icons.delete_outline_rounded, size: 17),
                label: Text('删除', style: TextStyle(color: pm.warn)),
              ),
            ),
            const SizedBox(width: 6),
            Switch.adaptive(
              value: script.enabled,
              onChanged: (v) => onToggle(v),
            ),
          ],
        ),
      ],
    );
  }

  static String _runAtLabel(String raw) => switch (raw) {
    'document-start' => '页面开始加载',
    'document-end' => 'DOM 就绪',
    _ => '页面加载完成',
  };
}
