import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge.dart';
import '../ip_geo_widgets.dart';
import '../page_kit.dart';
import '../theme.dart';
import '../widgets.dart';

class DownloadDetailPage extends StatefulWidget {
  const DownloadDetailPage({
    super.key,
    required this.id,
    this.name = '',
    this.snapshot,
    this.onResume,
  });

  final String id;
  final String name;
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
    final mirrors = (d?['mirrors'] as List? ?? const []).map((e) => e.toString()).toList();
    final cdnHosts = cdn.map((e) => _hostOf(e['url']?.toString() ?? '')).where((e) => e.isNotEmpty).toSet().toList();

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
            ),
            if (isRecovered) ...[
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
                        Expanded(child: PmStat(label: '速率', value: formatMbps((d['mbps'] as num? ?? 0).toDouble()), unit: 'Mbps', icon: Icons.bolt_rounded)),
                        Expanded(child: PmStat(label: isStream ? '分片' : '分块', value: isStream ? '$partsDone/$partsTotal' : '${chunks.length}', icon: Icons.grid_view_rounded)),
                        Expanded(child: PmStat(label: '线程', value: '${d['connections'] ?? workers.length}', icon: Icons.hub_rounded)),
                      ],
                    ),
                    if ((d['chunk_size'] as num? ?? 0) > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        '块大小 ${formatBytes((d['chunk_size'] as num).toDouble())} · CDN 节点 ${cdn.length} 个 · DNS ${dnsServers.isEmpty ? '—' : dnsServers.length} 个',
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
                    _kvRow(context, 'CDN 节点', cdnHosts.isEmpty ? '解析中…' : cdnHosts.join(' · ')),
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
              PmSectionTitle('工作线程（${workers.length}）'),
              for (final w in workers)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: PmCard(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            PmIconBadge(Icons.memory_rounded, size: 30, radius: 9),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text('Work ${w['id']}', style: context.text.titleSmall),
                            ),
                            PmPill(label: w['state']?.toString() ?? '—', dense: true),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: (w['ip']?.toString().isNotEmpty ?? false)
                                  ? IpGeoInline(ip: w['ip'].toString(), showIp: true, fontSize: 11.5)
                                  : Text('等待分配 CDN IP', style: context.text.bodySmall?.copyWith(color: pm.muted)),
                            ),
                            Text('${formatMbps((w['mbps'] as num? ?? 0).toDouble())} Mbps · ${w['chunks'] ?? 0} 块 · ${formatBytes((w['bytes'] as num? ?? 0).toDouble())}',
                                style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            _tag(context, 'DNS ${w['dns'] ?? '—'}'),
                            const SizedBox(width: 6),
                            Expanded(child: _tag(context, 'CDN ${_hostOf(w['cdn']?.toString() ?? '')}', flex: true)),
                          ],
                        ),
                        if ((w['last_error']?.toString() ?? '').isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(w['last_error'].toString(), style: context.text.bodySmall?.copyWith(color: pm.warn, fontSize: 10.5)),
                        ],
                      ],
                    ),
                  ),
                ),
              if (isRecovered && widget.onResume != null) ...[
                const SizedBox(height: 12),
                PmPrimaryButton(
                  label: '继续下载（断点续传）',
                  icon: Icons.play_arrow_rounded,
                  onPressed: () async {
                    final id = await widget.onResume!();
                    if (id != null && context.mounted) Navigator.of(context).pop();
                  },
                ),
              ],
              const SizedBox(height: 6),
              PmSectionTitle('CDN IP 池（${cdn.length}）'),
              PmCard(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                child: cdn.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Text(
                          isRecovered ? '本地记录未保存 CDN 节点，继续后会重新解析。' : '正在通过多个 DNS 解析 CDN 节点…',
                          style: context.text.bodySmall?.copyWith(color: pm.muted),
                        ),
                      )
                    : Column(
                        children: [
                          for (final e in cdn)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 92,
                                    child: (e['ip']?.toString().isNotEmpty ?? false)
                                        ? IpGeoInline(ip: e['ip'].toString(), showIp: true, fontSize: 11)
                                        : Text('解析失败', style: context.text.bodySmall?.copyWith(color: pm.warn)),
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('CDN ${_hostOf(e['url']?.toString() ?? '')}', style: context.text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                                        Text('DNS ${e['dns']} · ${e['ms']} ms', style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 10)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ],
        ),
      ),
    );
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

  Widget _tag(BuildContext context, String text, {bool flex = false}) {
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: ShapeDecoration(
        color: context.pm.block,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(7)),
      ),
      child: Text(text, style: context.text.bodySmall?.copyWith(fontSize: 10, color: context.pm.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    return flex ? child : child;
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
        final cols = ((width + _gap) / (_cellW + _gap)).floor().clamp(1, chunks.length == 0 ? 1 : chunks.length);
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
    final cols = ((size.width + gap) / (w + gap)).floor().clamp(1, chunks.length == 0 ? 1 : chunks.length);
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
