import 'dart:async';
import 'dart:io';
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import '../bridge.dart';
import '../download_sheet.dart';
import '../page_kit.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';
import 'browser_page.dart';
import 'download_detail_page.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  Timer? _timer;
  List<Map<String, dynamic>> _items = [];
  bool _loaded = false;
  bool _loading = false;
  bool _scanDone = false;
  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(milliseconds: 900), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final store = AppScope.of(context);
      final listR = await Core.callAsync('dl_list');
      final live = _itemsOf(listR);
      var scanned = <Map<String, dynamic>>[];
      if (!_scanDone) {
        final dirs = <String>{store.downloadDirEffective};
        for (final rec in store.downloadRecords) {
          final d = rec['dir']?.toString() ?? '';
          if (d.isNotEmpty) dirs.add(d);
        }
        for (final d in dirs) {
          try {
            final scanR = await Core.callAsync('dl_scan', {'dir': d});
            scanned.addAll(_itemsOf(scanR));
          } catch (_) {}
        }
        _scanDone = true;
      }
      if (!mounted) return;
      final now = DateTime.now();
      var meaningful = false;
      // 实时任务的配置回写到本地记录；进程被杀后仍能继续。
      for (final item in live) {
        final key = AppStore.downloadRecordKey(item);
        final old = store.findDownloadRecord(key);
        final st = item['status']?.toString() ?? 'running';
        if ((st == 'done' || st == 'error' || st == 'paused') &&
            old?['status']?.toString() != st) {
          meaningful = true;
        }
        store.upsertDownloadRecord({
          'id': item['id']?.toString() ?? '',
          'url': item['url']?.toString() ?? '',
          'name': item['name']?.toString() ?? '',
          'dir': item['dir']?.toString() ?? store.downloadDirEffective,
          'kind': item['kind']?.toString() ?? 'http',
          'status': item['status']?.toString() ?? 'running',
          'size': item['size'] ?? 0,
          'done': item['done'] ?? 0,
          'mirrors': item['mirrors'] ?? const [],
          'headers': item['headers'] ?? const {},
          'dns': item['dns'] ?? const [],
          'connections': item['connections'] ?? 8,
          'block_kb': item['block_kb'] ?? 1024,
          'retries': item['retries'] ?? 2,
          'created': old?['created'] ?? now.toIso8601String(),
        }, persist: false);
      }
      final persist = meaningful || now.difference(_lastPersist) > const Duration(seconds: 5);
      if (persist) {
        _lastPersist = now;
        store.save();
      }
      final merged = _mergeRecords(store, live, scanned);
      setState(() {
        _items = merged;
        _loaded = true;
      });
    } catch (_) {
      // 后台 isolate 调用失败时保留上一帧，避免列表闪空。
    } finally {
      _loading = false;
    }
  }

  List<Map<String, dynamic>> _itemsOf(Map<String, dynamic> r) {
    final data = r['data'];
    if (data is Map && data['items'] is List) {
      return (data['items'] as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    return [];
  }

  List<Map<String, dynamic>> _mergeRecords(
    AppStore store,
    List<Map<String, dynamic>> live,
    List<Map<String, dynamic>> scanned,
  ) {
    final map = <String, Map<String, dynamic>>{};
    for (final rec in store.downloadRecords) {
      map[AppStore.downloadRecordKey(rec)] = {...rec, 'live': false};
    }
    for (final rec in scanned) {
      final key = AppStore.downloadRecordKey(rec);
      final old = map[key];
      final oldDone = (old?['done'] as num?)?.toInt() ?? 0;
      final newDone = (rec['done'] as num?)?.toInt() ?? 0;
      map[key] = {
        ...?old,
        ...rec,
        'done': newDone,
        'live': false,
      };
      if (oldDone > newDone) map[key]!['done'] = oldDone;
    }
    for (final rec in live) {
      final key = AppStore.downloadRecordKey(rec);
      final old = map[key];
      map[key] = {
        ...?old,
        ...rec,
        'live': true,
        'recovered': false,
      };
    }
    for (final e in map.entries) {
      final item = e.value;
      if (item['live'] != true) {
        final st = item['status']?.toString() ?? 'paused';
        if (st == 'running' || st == 'probing' || st == 'downloading') {
          item['status'] = 'paused';
        }
        item['recovered'] = true;
        item['mbps'] = 0;
      }
    }
    final out = map.values.toList();
    int rank(Map<String, dynamic> x) => switch (x['status']?.toString()) {
          'running' || 'probing' => 0,
          'paused' => 1,
          'error' => 2,
          _ => 3,
        };
    out.sort((a, b) => rank(a).compareTo(rank(b)));
    return out;
  }

  Map<String, dynamic> _resumeArgs(Map<String, dynamic> item, AppStore store) {
    final headers = (item['headers'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final dns = (item['dns'] as List?)?.map((e) => e.toString()).toList();
    return {
      'url': item['url']?.toString() ?? '',
      'mirrors': item['mirrors'] ?? const [],
      'headers': headers,
      'dns_servers': dns == null || dns.isEmpty ? store.downloadDns : dns,
      'dir': item['dir']?.toString() ?? store.downloadDirEffective,
      'name': item['name']?.toString() ?? '',
      'connections': item['connections'] ?? store.downloadConnections,
      'block_kb': item['block_kb'] ?? store.downloadBlockKb,
      'retries': item['retries'] ?? store.downloadRetries,
      'bind': store.downloadBind,
      'ip_mode': store.downloadIpMode,
      'dns_mode': store.downloadDnsMode,
      'resume': true,
    };
  }

  Future<String?> _resume(Map<String, dynamic> item) async {
    final store = AppScope.of(context);
    final args = _resumeArgs(item, store);
    if (args['url']?.toString().isEmpty ?? true) {
      pmToast(context, '任务缺少下载地址');
      return null;
    }
    try {
      if (item['live'] == true) {
        final oldId = item['id']?.toString() ?? '';
        if (oldId.isNotEmpty) {
          Core.i.cancel(oldId);
          await Future<void>.delayed(const Duration(milliseconds: 260));
          try {
            Core.i.call('dl_delete', {'id': oldId, 'delete_files': false});
            Core.i.dispose(oldId);
          } catch (_) {}
        }
      }
      final r = await Core.callAsync('start_download', args);
      if (!mounted) return null;
      if (r['ok'] != true) {
        pmToast(context, r['error']?.toString() ?? '继续下载失败');
        return null;
      }
      final id = ((r['data'] as Map?)?['task_id'])?.toString() ?? '';
      if (id.isEmpty) {
        pmToast(context, '核心未返回任务编号');
        return null;
      }
      store.upsertDownloadRecord({
        ...item,
        'id': id,
        'status': 'running',
        'live': true,
        'recovered': false,
        'created': item['created'] ?? DateTime.now().toIso8601String(),
      }, persist: true);
      _lastPersist = DateTime.now();
      _loading = false;
      await _refresh();
      if (mounted) pmToast(context, '已继续，分块进度会自动接管');
      return id;
    } catch (e) {
      if (mounted) pmToast(context, '继续下载失败：$e');
      return null;
    }
  }

  void _openDetail(Map<String, dynamic> item) {
    if (item['live'] == true) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DownloadDetailPage(
          id: item['id']?.toString() ?? '',
          name: item['name']?.toString() ?? '',
        ),
      ));
    } else {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DownloadDetailPage(
          id: item['id']?.toString() ?? 'local',
          name: item['name']?.toString() ?? '',
          snapshot: item,
          onResume: () async => await _resume(item),
        ),
      ));
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final store = AppScope.of(context);
    final dir = item['dir']?.toString() ?? store.downloadDirEffective;
    final name = item['name']?.toString() ?? '';
    if (item['live'] == true && !(item['id']?.toString().startsWith('local:') ?? true)) {
      try {
        Core.i.call('dl_delete', {'id': item['id'], 'delete_files': true});
        Core.i.dispose(item['id']?.toString() ?? '');
      } catch (_) {}
    } else if (dir.isNotEmpty && name.isNotEmpty) {
      try {
        await File('$dir/.$name.pmdown').delete();
      } catch (_) {}
      try {
        await File('$dir/.$name.pmdown.json').delete();
      } catch (_) {}
    }
    store.removeDownloadRecord(AppStore.downloadRecordKey(item));
    _scanDone = false;
    await _refresh();
  }

  void _add() => showDownloadSheet(context);

  void _openBrowser() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BrowserPage()));
  }

  void _advanced() {
    final store = AppScope.of(context);
    final mirrors = TextEditingController(text: store.downloadMirrors.join('\n'));
    final dns = TextEditingController(text: store.downloadDns.join('\n'));
    final ua = TextEditingController(text: store.downloadUserAgent);
    final bind = TextEditingController(text: store.downloadBind);
    var ipMode = store.downloadIpMode;
    var dnsMode = store.downloadDnsMode;
    var connections = store.downloadConnections.toDouble();
    var blockKb = store.downloadBlockKb.toDouble();
    var retries = store.downloadRetries.toDouble();

    showPmSheet(
      context,
      title: '下载高级设置',
      body: StatefulBuilder(
        builder: (context, setSheet) {
          final pm = context.pm;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '这里保存默认值；每次推送链接仍可在下载弹层中逐项覆盖。',
                style: context.text.bodySmall?.copyWith(color: pm.muted),
              ),
              const SizedBox(height: 12),
              Text('传输调优', style: context.text.titleSmall),
              const SizedBox(height: 2),
              PmSliderRow(
                label: '单任务并发线程',
                value: connections,
                min: 1,
                max: 32,
                divisions: 31,
                display: (v) => '${v.toStringAsFixed(0)} 条',
                onChanged: (v) => setSheet(() => connections = v),
              ),
              PmSliderRow(
                label: '分片粒度',
                value: blockKb,
                min: 64,
                max: 8192,
                divisions: 127,
                display: (v) => '${(v / 1024).toStringAsFixed(v < 1024 ? 2 : 1)} MB',
                onChanged: (v) => setSheet(() => blockKb = v),
              ),
              PmSliderRow(
                label: '断点重试上限',
                value: retries,
                min: 0,
                max: 10,
                divisions: 10,
                display: (v) => '${v.toStringAsFixed(0)} 次',
                onChanged: (v) => setSheet(() => retries = v),
              ),
              const SizedBox(height: 8),
              Text('出口与连接', style: context.text.titleSmall),
              const SizedBox(height: 4),
              PmField(
                controller: bind,
                label: '源 IP / 网卡名',
                hint: '留空自动 · 192.168.1.5 · wlan0',
              ),
              const SizedBox(height: 10),
              PmSegmented<String>(
                items: const [
                  (value: 'auto', label: '双栈自动'),
                  (value: 'v4', label: '仅 IPv4'),
                  (value: 'v6', label: '仅 IPv6'),
                ],
                value: ipMode,
                onChanged: (v) => setSheet(() => ipMode = v),
              ),
              const SizedBox(height: 12),
              Text('域名解析', style: context.text.bodyMedium),
              const SizedBox(height: 8),
              PmSegmented<String>(
                items: const [
                  (value: 'all', label: '多 DNS 并发'),
                  (value: 'primary', label: '主 DNS 优先'),
                ],
                value: dnsMode,
                onChanged: (v) => setSheet(() => dnsMode = v),
              ),
              const SizedBox(height: 8),
              Text('多 CDN 镜像', style: context.text.bodyMedium),
              const SizedBox(height: 8),
              PmField(
                controller: mirrors,
                label: '镜像地址（每行一条）',
                hint: 'https://cdn-a.example.com/file.zip',
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              PmField(controller: dns, label: '多 DNS 解析（每行一条，支持 DoT/DoH）', hint: '223.5.5.5\nhttps://dns.alidns.com/dns-query\ndot://dns.google', maxLines: 4),
              const SizedBox(height: 12),
              PmField(controller: ua, label: '默认 User-Agent', maxLines: 2),
              const SizedBox(height: 16),
              PmPrimaryButton(
                label: '保存默认值',
                icon: Icons.check_rounded,
                onPressed: () {
                  store.setDownloadConnections(connections.round());
                  store.setDownloadBlockKb(blockKb.round());
                  store.setDownloadRetries(retries.round());
                  store.setDownloadMirrors(
                    mirrors.text.split('\n').map((e) => e.trim()).where((e) => e.startsWith('http')).toList(),
                  );
                  store.setDownloadDns(
                    dns.text.split(RegExp('[,，\\s]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
                  );
                  store.setDownloadBind(bind.text);
                  store.setDownloadIpMode(ipMode);
                  store.setDownloadDnsMode(dnsMode);
                  store.setDownloadUserAgent(ua.text.trim());
                  Navigator.pop(context);
                  pmToast(context, '默认值已保存');
                },
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          PmPageHeader(
            title: '下载',
            subtitle: '多 CDN · 多 DNS · 动态分段 · 断点续传',
            actions: [
              PmIconAction(icon: Icons.travel_explore_rounded, onTap: _openBrowser),
              PmIconAction(icon: Icons.tune_rounded, onTap: _advanced),
              PmIconAction(icon: Icons.add_rounded, onTap: _add),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
            child: Column(
              children: [
                if (!_loaded)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: CircularProgressIndicator(),
                  )
                else if (_items.isEmpty)
                  PmCard(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                    child: Column(
                      children: [
                        PmIconBadge(Icons.cloud_download_rounded, size: 56, radius: 18),
                        const SizedBox(height: 14),
                        Text('还没有下载任务', style: context.text.titleMedium),
                        const SizedBox(height: 6),
                        Text(
                          '粘贴链接即可多连接分段下载；也可以打开内置浏览器，把网页里的直链连同 Cookie、Referer 一键推送过来。',
                          textAlign: TextAlign.center,
                          style: context.text.bodySmall?.copyWith(color: pm.muted, height: 1.5),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: PmPrimaryButton(
                                label: '新建下载',
                                icon: Icons.add_rounded,
                                onPressed: _add,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: PmPrimaryButton(
                                label: '打开浏览器',
                                icon: Icons.travel_explore_rounded,
                                expand: true,
                                onPressed: _openBrowser,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  )
                else
                  for (final item in _items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _DownloadTile(
                        item: item,
                        onChanged: _refresh,
                        onOpen: () => _openDetail(item),
                        onResume: () => _resume(item),
                        onDelete: () => _delete(item),
                        accent: scheme.primary,
                      ),
                    ),
                const SizedBox(height: 8),
                PmCard(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.folder_outlined, size: 16, color: pm.muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '文件保存在 ${AppScope.of(context).downloadDirEffective}；鉴权头与镜像会写入续传元数据，暂停后可原样恢复。',
                          style: context.text.bodySmall?.copyWith(color: pm.muted, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({
    required this.item,
    required this.onChanged,
    required this.onOpen,
    required this.onResume,
    required this.onDelete,
    required this.accent,
  });

  final Map<String, dynamic> item;
  final VoidCallback onChanged;
  final VoidCallback onOpen;
  final Future<String?> Function() onResume;
  final Future<void> Function() onDelete;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final size = (item['size'] as num? ?? 0).toDouble();
    final done = (item['done'] as num? ?? 0).toDouble();
    final pct = size <= 0 ? 0.0 : (done / size).clamp(0.0, 1.0);
    final status = item['status']?.toString() ?? 'probing';
    final statusLabel = switch (status) {
      'done' => '已完成',
      'paused' => '已暂停',
      'error' => '失败',
      'probing' => '探测中',
      _ => '下载中',
    };
    final statusColor = switch (status) {
      'done' => pm.ok,
      'error' => pm.warn,
      'paused' => pm.muted,
      _ => accent,
    };
    final id = item['id']?.toString() ?? '';
    final speed = (item['mbps'] as num? ?? 0).toDouble();
    final mirrors = (item['mirrors'] as List? ?? const []).length;
    final headerKeys = (item['headers'] as Map? ?? const {}).keys.toList();

    return PmCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      onTap: onOpen,
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PmIconBadge(
                status == 'done' ? Icons.check_rounded : Icons.insert_drive_file_rounded,
                color: statusColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['name']?.toString() ?? 'download',
                      style: context.text.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${formatBytes(done)} / ${formatBytes(size)}',
                      style: context.text.bodySmall?.copyWith(
                        color: pm.muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontSize: 11,
                      ),
                    ),
                    if (mirrors > 1 || headerKeys.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 5,
                        runSpacing: 4,
                        children: [
                          if (mirrors > 1) PmPill(label: 'CDN $mirrors', dense: true),
                          if (headerKeys.isNotEmpty)
                            PmPill(label: '鉴权 ${headerKeys.length}', color: pm.series2, dense: true),
                          if ((item['block_kb'] as num? ?? 0) > 0)
                            PmPill(label: '块 ${((item['block_kb'] as num) / 1024).toStringAsFixed(1)}MB', dense: true),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  PmPill(label: statusLabel, color: statusColor, dense: true),
                  const SizedBox(height: 6),
                  if (status == 'probing' || status == 'running' || status == 'downloading')
                    Text(
                      '${formatMbps(speed)} Mbps',
                      style: context.text.bodySmall?.copyWith(color: accent, fontSize: 11),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: pm.block,
              valueColor: AlwaysStoppedAnimation(statusColor),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '${(pct * 100).toStringAsFixed(pct >= 1 ? 0 : 1)}%',
                style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
              ),
              const Spacer(),
              if (status != 'done') ...[
                if (status == 'paused' || (item['recovered'] == true && status != 'done'))
                  _MiniAction(
                    label: '继续',
                    icon: Icons.play_arrow_rounded,
                    onTap: () { onResume(); },
                  )
                else if (status == 'running' || status == 'probing' || status == 'downloading')
                  _MiniAction(
                    label: '暂停',
                    icon: Icons.pause_rounded,
                    onTap: () {
                      Core.i.cancel(id);
                      onChanged();
                    },
                  ),
                const SizedBox(width: 6),
              ],
              _MiniAction(
                label: '删除',
                icon: Icons.delete_outline_rounded,
                danger: true,
                onTap: () => confirmDialog(
                  context,
                  title: '删除任务',
                  message: '同时删除未完成的临时文件？已下载完成的目标文件不会删除。',
                  confirmLabel: '删除',
                  destructive: true,
                  onConfirm: () { onDelete(); },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({required this.label, required this.icon, required this.onTap, this.danger = false});

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final color = danger ? pm.warn : context.scheme.primary;
    return PmPressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: ShapeDecoration(
          color: color.withValues(alpha: context.isDark ? 0.16 : 0.09),
          shape: const StadiumBorder(),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
