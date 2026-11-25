import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge.dart';
import '../download_task_ops.dart';
import '../ip_geo_widgets.dart';
import '../page_kit.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';

class DownloadDetailPage extends StatefulWidget {
  const DownloadDetailPage({
    super.key,
    required this.id,
    this.name = '',
    this.dir = '',
    this.snapshot,
    this.onResume,
  });

  final String id;
  final String name;
  final String dir;
  final Map<String, dynamic>? snapshot;
  final Future<String?> Function()? onResume;

  @override
  State<DownloadDetailPage> createState() => _DownloadDetailPageState();
}

class _DownloadDetailPageState extends State<DownloadDetailPage> {
  Map<String, dynamic>? _data;
  Timer? _timer;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    // 本地恢复记录不是活跃 Rust 任务，直接展示快照，避免请求一个不存在的 id。
    if (widget.snapshot == null) {
      _load();
      _timer = Timer.periodic(const Duration(milliseconds: 900), (_) => _load());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final r = await Core.callAsync('dl_detail', {'id': widget.id});
      if (!mounted) return;
      if (r['ok'] == true) {
        final d = (r['data'] as Map).cast<String, dynamic>();
        setState(() {
          _data = d;
          _error = null;
        });
        final s = d['status']?.toString();
        if (s == 'done' || s == 'error' || s == 'paused') {
          _timer?.cancel();
          _timer = null;
        }
      } else {
        setState(() => _error = r['error']?.toString() ?? '任务不存在');
        _timer?.cancel();
        _timer = null;
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _loading = false;
    }
  }

  /// 删除当前任务：先探测磁盘产物，再让用户决定是否连文件一起删。
  Future<void> _deleteTask() async {
    final store = AppScope.of(context);
    final d = _data ?? widget.snapshot;
    final item = <String, dynamic>{
      'id': widget.id,
      'url': d?['url']?.toString() ?? '',
      'name': (d?['name'] ?? widget.name).toString(),
      'dir': widget.dir.isNotEmpty ? widget.dir : store.downloadDirEffective,
      'live': _data != null,
      if (d?['path'] != null) 'path': d!['path'],
      if (d?['data_file'] != null) 'data_file': d!['data_file'],
      if (d?['meta_file'] != null) 'meta_file': d!['meta_file'],
    };
    final files = await probeTaskFiles(item, store.downloadDirEffective);
    if (!mounted) return;
    final withFile = await askDeleteTask(context, files);
    if (withFile == null || !mounted) return;
    final freed = await removeTaskFiles(item, files, withFile: withFile);
    store.removeDownloadRecord(AppStore.downloadRecordKey(item));
    if (!mounted) return;
    pmToast(
      context,
      withFile
          ? (freed > 0 ? '已删除任务与文件，释放 ${formatBytes(freed)}' : '已删除任务')
          : '已删除任务，文件保留在下载目录',
    );
    Navigator.of(context).maybePop();
  }


  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    final d = _data ?? widget.snapshot;
    final isRecovered = _data == null && widget.snapshot != null;
    final size = (d?['size'] as num? ?? 0).toDouble();
    final done = (d?['done'] as num? ?? 0).toDouble();
    final kind = d?['kind']?.toString() ?? 'http';
    final isStream = kind == 'hls' || kind == 'dash';
    final partsTotal = (d?['parts_total'] as num? ?? 0).toInt();
    final partsDone = (d?['parts_done'] as num? ?? 0).toInt();
    final streamPct = partsTotal > 0 ? (partsDone / partsTotal).clamp(0.0, 1.0) : 0.0;
    final pct = isStream ? streamPct : (size <= 0 ? 0.0 : (done / size).clamp(0.0, 1.0));
    final status = d?['status']?.toString() ?? 'probing';
    final statusLabel = switch (status) {
      'done' => '已完成',
      'paused' => '已暂停',
      'error' => '失败',
      'probing' => '解析 CDN…',
      'running' => '下载中',
      _ => status,
    };
    final statusColor = switch (status) {
      'done' => pm.ok,
      'error' => pm.warn,
      'paused' => pm.muted,
      _ => scheme.primary,
    };
    final workers = (d?['workers'] as List? ?? const []).whereType<Map>().toList();
    final cdn = (d?['cdn'] as List? ?? const []).whereType<Map>().toList();
    final chunks = (d?['chunks'] as List? ?? const []).whereType<Map>().toList();
    final dnsServers = (d?['dns_servers'] as List? ?? const []).map((e) => e.toString()).toList();
    final dnsTotal = (d?['dns_total'] as num? ?? 0).toInt();
    final finished = status == 'done' || d?['finished'] == true;
    final mirrors = (d?['mirrors'] as List? ?? const []).map((e) => e.toString()).toList();
    final cdnHosts = cdn.map((e) => _hostOf(e['url']?.toString() ?? '')).where((e) => e.isNotEmpty).toSet().toList();
    final mbpsNow = (d?['mbps'] as num? ?? 0).toDouble();
    // 剩余时间按当前瞬时速度估算；速度为 0 或大小未知时不给假数字。
    final remainBytes = size > 0 ? (size - done).clamp(0.0, size) : 0.0;
    final etaSeconds = (remainBytes > 0 && mbpsNow > 0.05) ? remainBytes * 8 / 1e6 / mbpsNow : 0.0;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 8, kPagePadding, 30),
          children: [
            PmPageHeader(
              title: d?['name']?.toString().isNotEmpty == true ? d!['name'].toString() : (widget.name.isEmpty ? '下载详情' : widget.name),
              subtitle: '任务 ${widget.id}',
              showBack: true,
              actions: [
                PmIconAction(icon: Icons.delete_outline_rounded, onTap: _deleteTask),
              ],
            ),
            if (isRecovered && !finished) ...[
              PmCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                color: scheme.primary.withValues(alpha: 0.08),
                child: Row(
                  children: [
                    Icon(Icons.history_rounded, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '本地保留的续传记录；点击下方按钮会沿用已下载分块继续。',
                        style: context.text.bodySmall?.copyWith(color: pm.muted, height: 1.45),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_error != null)
              PmCard(child: Text(_error!, style: context.text.bodyMedium?.copyWith(color: pm.warn)))
            else if (d == null)
              const PmCard(child: SizedBox(height: 80, child: Center(child: CircularProgressIndicator(strokeWidth: 2))))
            else ...[
              PmCard(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(formatBytes(done), style: context.text.headlineSmall),
                        ),
                        PmPill(label: statusLabel, color: statusColor, dense: true),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isStream
                          ? '已下载 ${formatBytes(done)} · $partsDone / $partsTotal 个分片'
                          : '共 ${formatBytes(size)} · ${(pct * 100).toStringAsFixed(1)}%',
                      style: context.text.bodySmall?.copyWith(color: pm.muted),
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: pct,
                        minHeight: 7,
                        backgroundColor: pm.track,
                        valueColor: AlwaysStoppedAnimation(statusColor),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: PmStat(
                            label: '速率',
                            value: formatMbps(mbpsNow),
                            unit: unitOf(mbpsNow),
                            icon: Icons.bolt_rounded,
                          ),
                        ),
                        Expanded(
                          child: PmStat(
                            label: '剩余',
                            value: etaSeconds > 0 ? formatEta(etaSeconds) : '--',
                            icon: Icons.schedule_rounded,
                          ),
                        ),
                        Expanded(
                          child: PmStat(
                            label: isStream ? '分片' : '分块',
                            value: isStream ? '$partsDone/$partsTotal' : '${chunks.length}',
                            icon: Icons.grid_view_rounded,
                          ),
                        ),
                        Expanded(
                          child: PmStat(
                            label: '线程',
                            value: '${d['connections'] ?? workers.length}',
                            icon: Icons.hub_rounded,
                          ),
                        ),
                      ],
                    ),
                    if ((d['chunk_size'] as num? ?? 0) > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        '块大小 ${formatBytes((d['chunk_size'] as num).toDouble())} · CDN 节点 ${cdn.length} 个 · DNS ${dnsServers.isEmpty ? '—' : dnsServers.length} 个'
                        '${dnsTotal > 1 ? '（$dnsTotal 台按线程分摊）' : ''}',
                        style: context.text.bodySmall?.copyWith(color: pm.muted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              PmSectionTitle('链接与 CDN 解析'),
              PmCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _kvRow(context, '原始链接', d['url']?.toString() ?? '—', mono: true),
                    if (mirrors.isNotEmpty)
                      _kvRow(context, 'CDN 镜像', mirrors.map(_hostOf).join('\n'), mono: true),
                    _kvRow(context, '解析 DNS', dnsServers.isEmpty ? '—' : dnsServers.join(' · '), mono: true),
                    _kvRow(
                      context,
                      'CDN 域名',
                      cdnHosts.isEmpty ? '解析中…' : '${cdnHosts.length} 个（明细见下方 IP 池）',
                      mono: true,
                    ),
                    _kvRow(context, '实际分配', '${workers.length} 个 Work · ${cdn.length} 个 CDN IP'),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              PmSectionTitle(isStream ? '分片进度（$partsDone / $partsTotal）' : '分块进度（${chunks.length}）'),
              PmCard(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                child: isStream
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LinearProgressIndicator(
                            value: streamPct,
                            minHeight: 7,
                            backgroundColor: pm.track,
                            valueColor: AlwaysStoppedAnimation(statusColor),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'HLS/DASH 按清单顺序下载并拼接；段数 $partsDone / $partsTotal。',
                            style: context.text.bodySmall?.copyWith(color: pm.muted),
                          ),
                        ],
                      )
                    : chunks.isEmpty
                    ? Text(
                        isRecovered ? '已保留本地分块进度，继续后从断点接续。' : '正在探测文件与分段…',
                        style: context.text.bodySmall?.copyWith(color: pm.muted),
                      )
                    : _ChunkGrid(
                        chunks: chunks,
                        colorFor: (c) => _chunkColor(context, c, statusColor, pm.ok),
                        onTap: (c) => _showChunk(context, c),
                      ),
              ),
              const SizedBox(height: 14),
              PmSectionTitle(
                '工作线程（${workers.length}）',
                subtitle: workers.isEmpty ? null : '逐条连接的实时速度与出口归属',
              ),
              for (final w in workers) _workerCard(context, w, done: done),
              if (isRecovered && widget.onResume != null && !finished) ...[
                const SizedBox(height: 12),
                PmPrimaryButton(
                  label: '继续下载（断点续传）',
                  icon: Icons.play_arrow_rounded,
                  onPressed: () async {
                    final id = await widget.onResume!();
                    if (id != null && context.mounted) {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (_) => DownloadDetailPage(id: id, name: widget.name),
                        ),
                      );
                    }
                  },
                ),
              ],
              const SizedBox(height: 6),
              PmSectionTitle(
                'CDN IP 池（${cdn.length}）',
                subtitle: cdn.isEmpty ? null : '按响应延迟排序 · 点按 IP 查看完整归属',
              ),
              _cdnPool(context, cdn, isRecovered: isRecovered),
            ],
          ],
        ),
      ),
    );
  }

  /// 单个工作线程卡片。
  ///
  /// 原先速度、块数、IP 归属全挤在同一行，窄屏上归属地会被省略号吃掉；
  /// 这里改成「指标三列 + 出口归属 + CDN/DNS 明细」的纵向结构，信息不再互相挤压。
  Widget _workerCard(BuildContext context, Map w, {required double done}) {
    final pm = context.pm;
    final scheme = context.scheme;
    final mbps = (w['mbps'] as num? ?? 0).toDouble();
    final bytes = (w['bytes'] as num? ?? 0).toDouble();
    final chunks = (w['chunks'] as num? ?? 0).toInt();
    final errs = (w['errs'] as num? ?? 0).toInt();
    final elapsed = (w['elapsed_ms'] as num? ?? 0).toInt();
    // 平均速度只在跑够 1.2 秒后才有意义，避免刚起步时算出夸张数值。
    final avg = elapsed >= 1200 ? bytes * 8 / 1e6 / (elapsed / 1000) : 0.0;
    final share = done > 0 ? (bytes / done * 100).clamp(0.0, 100.0) : 0.0;
    final ip = w['ip']?.toString() ?? '';
    final dns = w['dns']?.toString() ?? '';
    final dnsPref = (w['dns_pref'] as num?)?.toInt();
    final cdnHost = _hostOf(w['cdn']?.toString() ?? '');
    final state = w['state']?.toString() ?? '—';
    final color = switch (state) {
      '失败' => pm.warn,
      '下载中' => scheme.primary,
      '待命' => pm.ok,
      _ => pm.muted,
    };
    final err = w['last_error']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: PmCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                PmIconBadge(Icons.memory_rounded, size: 30, radius: 9, color: color),
                const SizedBox(width: 10),
                Expanded(child: Text('Work ${w['id']}', style: context.text.titleSmall)),
                PmPill(label: state, dense: true, color: color),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 4,
                  child: _metric(
                    context,
                    value: formatMbps(mbps),
                    unit: unitOf(mbps),
                    label: avg > 0 ? '均速 ${formatMbps(avg)}' : '当前速度',
                    color: state == '下载中' ? scheme.primary : null,
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: _metric(
                    context,
                    value: formatBytes(bytes),
                    label: '已下载 ${share.toStringAsFixed(share >= 10 ? 0 : 1)}%',
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: _metric(
                    context,
                    value: '$chunks',
                    unit: '块',
                    label: errs > 0 ? '失败 $errs 次' : '零失败',
                    color: errs > 0 ? pm.warn : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 11),
            Divider(height: 1, thickness: 1, color: pm.track),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.public_rounded, size: 13, color: pm.muted),
                ),
                const SizedBox(width: 6),
                Expanded(child: IpGeoBlock(ip: ip, fontSize: 12.5, showIp: true, showIsp: true)),
              ],
            ),
            if (cdnHost.isNotEmpty) ...[
              const SizedBox(height: 7),
              _lineItem(context, Icons.cloud_queue_rounded, 'CDN', cdnHost),
            ],
            if (dns.isNotEmpty) ...[
              const SizedBox(height: 5),
              _lineItem(
                context,
                Icons.router_rounded,
                'DNS',
                dnsPref == null ? dns : '$dns · 首选 #${dnsPref + 1}',
              ),
            ],
            if (err.isNotEmpty) ...[
              const SizedBox(height: 9),
              _errorNote(context, err),
            ],
          ],
        ),
      ),
    );
  }

  /// 指标单元格：上行数值（可带单位），下行说明文字。
  Widget _metric(
    BuildContext context, {
    required String value,
    String unit = '',
    required String label,
    Color? color,
  }) {
    final pm = context.pm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: value,
                style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                  color: color ?? context.scheme.onSurface,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (unit.isNotEmpty)
                TextSpan(
                  text: ' $unit',
                  style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w500, color: pm.muted),
                ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: context.text.bodySmall?.copyWith(fontSize: 10, color: pm.muted),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  /// 带图标的一行明细（CDN 域名 / DNS 服务器等）。
  Widget _lineItem(BuildContext context, IconData icon, String label, String value) {
    final pm = context.pm;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 13, color: pm.muted),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 30,
          child: Text(
            label,
            style: context.text.bodySmall?.copyWith(fontSize: 10, color: pm.muted),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: context.text.bodySmall?.copyWith(
              fontSize: 11.5,
              height: 1.3,
              color: context.scheme.onSurface.withValues(alpha: 0.85),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _errorNote(BuildContext context, String message) {
    final pm = context.pm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: ShapeDecoration(
        color: pm.warn.withValues(alpha: context.isDark ? 0.14 : 0.09),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(9)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 13, color: pm.warn),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: context.text.bodySmall?.copyWith(
                fontSize: 10.5,
                height: 1.35,
                color: pm.warn,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// CDN IP 池：每条节点独立成块，IP / 归属地（到市）/ 运营商、域名、DNS、延迟分行显示。
  Widget _cdnPool(BuildContext context, List<Map> cdn, {required bool isRecovered}) {
    final pm = context.pm;
    if (cdn.isEmpty) {
      return PmCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Text(
          isRecovered ? '本地记录未保存 CDN 节点，继续后会重新解析。' : '正在通过多个 DNS 解析 CDN 节点…',
          style: context.text.bodySmall?.copyWith(color: pm.muted),
        ),
      );
    }
    // 延迟小的排前面，一眼就能看到当前最快的节点。
    final sorted = [...cdn]..sort((a, b) {
        final x = ((a['ms'] as num?) ?? 0x3FFFFFFF).toDouble();
        final y = ((b['ms'] as num?) ?? 0x3FFFFFFF).toDouble();
        return x.compareTo(y);
      });
    return PmCard(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
      child: Column(
        children: [
          for (var i = 0; i < sorted.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: pm.track),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ((sorted[i]['ip']?.toString() ?? '').isEmpty)
                          Text(
                            '解析失败',
                            style: context.text.bodySmall?.copyWith(fontSize: 12, color: pm.warn),
                          )
                        else
                          IpGeoBlock(
                            ip: sorted[i]['ip'].toString(),
                            fontSize: 12.5,
                            showIp: true,
                            showIsp: true,
                          ),
                        const SizedBox(height: 7),
                        _lineItem(
                          context,
                          Icons.cloud_queue_rounded,
                          'CDN',
                          _hostOf(sorted[i]['url']?.toString() ?? ''),
                        ),
                        const SizedBox(height: 5),
                        _lineItem(
                          context,
                          Icons.router_rounded,
                          'DNS',
                          sorted[i]['dns']?.toString() ?? '—',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _latencyPill(context, (sorted[i]['ms'] as num? ?? 0).toInt()),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 延迟徽标：80ms 内为良好，220ms 内正常，再高标警。
  Widget _latencyPill(BuildContext context, int ms) {
    final pm = context.pm;
    final color = ms <= 0
        ? pm.muted
        : ms < 80
            ? pm.ok
            : ms < 220
                ? context.scheme.primary
                : pm.warn;
    return PmPill(label: ms > 0 ? '$ms ms' : '超时', dense: true, color: color);
  }

  Widget _kvRow(BuildContext context, String k, String v, {bool mono = false}) {
    final pm = context.pm;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(k, style: context.text.bodySmall?.copyWith(fontSize: 12, color: pm.muted)),
          ),
          Expanded(
            child: Text(
              v,
              style: context.text.bodySmall?.copyWith(
                fontSize: 12,
                height: 1.4,
                color: context.scheme.onSurface,
                fontFamily: mono ? 'monospace' : null,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  static String _hostOf(String url) {
    final u = Uri.tryParse(url);
    return u == null ? url : '${u.host}${u.path}';
  }

  Color _chunkColor(BuildContext context, Map c, Color active, Color ok) {
    final done = (c['done'] as num? ?? 0).toDouble();
    final size = (c['size'] as num? ?? 0).toDouble();
    if (size > 0 && done >= size) return ok;
    if (done > 0) return active;
    return context.pm.track;
  }

  void _showChunk(BuildContext context, Map c) {
    showPmSheet(
      context,
      title: '分块 ${(c['index'] as num? ?? 0) + 1}',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _row(context, '字节范围', '${c['start']} - ${c['end']}'),
          _row(context, '分块大小', formatBytes((c['size'] as num? ?? 0).toDouble())),
          _row(context, '已完成', '${formatBytes((c['done'] as num? ?? 0).toDouble())} (${((c['percent'] as num? ?? 0)).toStringAsFixed(1)}%)'),
          _row(context, '状态', (c['done'] as num? ?? 0) >= (c['size'] as num? ?? 0) ? '完成' : ((c['done'] as num? ?? 0) > 0 ? '下载中' : '排队')),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            SizedBox(width: 78, child: Text(k, style: context.text.bodySmall?.copyWith(color: context.pm.muted))),
            Expanded(child: Text(v, style: context.text.bodyMedium)),
          ],
        ),
      );
}

class _ChunkGrid extends StatelessWidget {
  const _ChunkGrid({required this.chunks, required this.colorFor, required this.onTap});

  final List<Map> chunks;
  final Color Function(Map) colorFor;
  final void Function(Map) onTap;

  static const double _cellW = 30;
  static const double _cellH = 24;
  static const double _gap = 4;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cols = ((width + _gap) / (_cellW + _gap)).floor().clamp(1, chunks.isEmpty ? 1 : chunks.length);
        final rows = (chunks.length + cols - 1) ~/ cols;
        final height = rows <= 0 ? 0.0 : rows * _cellH + (rows - 1) * _gap;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            final col = (d.localPosition.dx / (_cellW + _gap)).floor();
            final row = (d.localPosition.dy / (_cellH + _gap)).floor();
            if (col < 0 || col >= cols || row < 0) return;
            final i = row * cols + col;
            if (i >= 0 && i < chunks.length) onTap(chunks[i]);
          },
          child: CustomPaint(
            size: Size(width, height),
            painter: _ChunkGridPainter(chunks: chunks, colorFor: colorFor),
          ),
        );
      },
    );
  }
}

/// 单个 CustomPainter 绘制全部分块：避免几百个 Widget 在每次刷新时重建布局。
class _ChunkGridPainter extends CustomPainter {
  _ChunkGridPainter({required this.chunks, required this.colorFor});

  final List<Map> chunks;
  final Color Function(Map) colorFor;

  @override
  void paint(Canvas canvas, Size size) {
    const w = _ChunkGrid._cellW;
    const h = _ChunkGrid._cellH;
    const gap = _ChunkGrid._gap;
    final cols = ((size.width + gap) / (w + gap)).floor().clamp(1, chunks.isEmpty ? 1 : chunks.length);
    final paint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < chunks.length; i++) {
      final row = i ~/ cols;
      final col = i % cols;
      final x = col * (w + gap);
      final y = row * (h + gap);
      final pct = ((chunks[i]['percent'] as num? ?? 0) / 100).clamp(0.0, 1.0);
      paint.color = colorFor(chunks[i]).withValues(alpha: pct >= 1 ? 1 : 0.18 + pct * 0.7);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), const Radius.circular(5)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChunkGridPainter old) => old.chunks != chunks;
}
