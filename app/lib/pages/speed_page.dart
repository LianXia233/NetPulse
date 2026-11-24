import 'dart:math' as math;
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import '../bridge.dart';
import '../ip_geo_widgets.dart';
import '../page_kit.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';

class SpeedPage extends StatefulWidget {
  const SpeedPage({super.key});

  @override
  State<SpeedPage> createState() => _SpeedPageState();
}

class _SpeedPageState extends State<SpeedPage> {
  String _mode = 'download';
  CoreTask? _task;
  final List<double> _series = [];
  final List<Map<String, dynamic>> _routes = [];
  final List<String> _errors = [];
  double _peak = 0;
  double _avgWindow = 0;

  @override
  void dispose() {
    _task?.removeListener(_onTask);
    _task?.dispose();
    super.dispose();
  }

  void _onTask() {
    final t = _task;
    if (t == null || !mounted) return;
    for (final e in t.events) {
      if (e['type'] == 'route') {
        final idx = e['idx'];
        if (!_routes.any((r) => r['idx'] == idx)) _routes.add(e);
      }
      if (e['type'] == 'error' && _errors.length < 40) {
        _errors.add(e['message']?.toString() ?? '');
      }
    }
    if (t.samples.isNotEmpty) {
      final v = t.lastSmoothMbps;
      if (_series.isEmpty || (v - _series.last).abs() > 0.01) {
        _series.add(v);
        if (_series.length > 140) _series.removeAt(0);
      }
      final lastSample = t.samples.last;
      final elapsed = (lastSample['t'] as num? ?? 0).toInt();
      if (elapsed >= 1200) _peak = math.max(_peak, v);
      final start = math.max(0, t.samples.length - 8);
      final window = t.samples.sublist(start);
      _avgWindow = window
              .map((e) => ((e['mbps_smooth'] ?? e['mbps']) as num? ?? 0).toDouble())
              .reduce((a, b) => a + b) /
          window.length;
    }
    setState(() {});
    if (!t.running) {
      _saveHistory(t);
      _task?.removeListener(_onTask);
    }
  }

  void _saveHistory(CoreTask t) {
    final summary = t.summary;
    if (summary == null) return;
    final store = AppScope.of(context);
    final avg = (summary['steady_mbps'] ?? summary['avg_mbps'] as num?)?.toDouble() ?? 0;
    store.addHistory(
      HistoryRecord(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        kind: 'speed',
        time: DateTime.now(),
        title: _mode == 'upload' ? '上传测速' : '下载测速',
        value: store.displaySpeed(avg),
        unit: store.displayUnit,
        detail: {...summary, 'display_unit': store.displayUnit},
      ),
    );
  }

  void _start() {
    final store = AppScope.of(context);
    _series.clear();
    _routes.clear();
    _errors.clear();
    _peak = 0;
    _avgWindow = 0;
    final task = CoreTask.start('speed', {
      'mode': _mode,
      'endpoints': _mode == 'upload' ? store.uploadEndpoints : store.speedEndpoints,
      'dns_servers': store.dnsServers,
      'workers': store.workers,
      'buffer_kb': 64,
      'duration_ms': store.durationSec * 1000,
      'sample_ms': store.sampleMs,
      'total_limit_bytes': 0,
      'timeout_ms': 8000,
      'bind': store.speedBind,
      'ip_mode': store.speedIpMode,
      'dns_mode': store.speedDnsMode,
    });
    setState(() => _task = task);
    task.addListener(_onTask);
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    final pm = context.pm;
    final scheme = context.scheme;
    final task = _task;
    final running = task?.running ?? false;
    final stopping = task?.stopping ?? false;
    final current = task?.lastSmoothMbps ?? 0;
    final totalBytes = (task?.samples.isNotEmpty ?? false)
        ? (task!.samples.last['bytes'] as num? ?? 0).toInt()
        : 0;
    final maxScale = math.max(50.0, _peak * 1.2);

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          PmPageHeader(
            title: '测速',
            subtitle: '多 CDN 并发 · 多 DNS 轮询 · Range 随机起点',
            actions: [
              PmIconAction(
                icon: Icons.tune_rounded,
                badge: '${store.workers}线程',
                onTap: () => _openTuning(store),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PmSegmented<String>(
                  items: const [
                    (value: 'download', label: '下载'),
                    (value: 'upload', label: '上传'),
                  ],
                  value: _mode,
                  onChanged: running ? (_) {} : (v) => setState(() => _mode = v),
                ),
                const SizedBox(height: 14),
                PmCard(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Text('测速配置', style: context.text.titleMedium),
                          const Spacer(),
                          PmPill(label: '${store.durationSec}s', dense: true),
                          const SizedBox(width: 6),
                          PmPill(label: '${store.workers} 线程', dense: true),
                        ],
                      ),
                      const SizedBox(height: 12),
                      PmGauge(
                        value: current,
                        maxValue: maxScale,
                        headline: store.displaySpeed(current),
                        unit: store.displayUnit,
                        caption: stopping
                            ? '正在停止并汇总结果…'
                            : running
                                ? '稳定 ${store.displaySpeed(_avgWindow)} ${store.displayUnit} · 峰值 ${store.displaySpeed(_peak)}'
                                : (_mode == 'download' ? '默认：Cloudflare / Hetzner / OVH 三 CDN' : '上传：Cloudflare __up'),
                        running: running && !stopping,
                        onTap: stopping ? null : (running ? () { task?.stop(); setState(() {}); } : _start),
                        size: 248,
                        buttonLabel: stopping ? '停止中' : (running ? '停止' : '开始'),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: PmStat(label: '瞬时', value: store.displaySpeed(current), unit: store.displayUnit, icon: Icons.bolt_rounded)),
                          Expanded(child: PmStat(label: '峰值', value: store.displaySpeed(_peak), unit: store.displayUnit, icon: Icons.trending_up_rounded)),
                          Expanded(child: PmStat(label: '流量', value: formatBytes(totalBytes), icon: Icons.data_usage_rounded)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                PmCard(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Text('吞吐曲线', style: context.text.titleMedium),
                          const Spacer(),
                          if (running)
                            PmPill(label: '${_routes.length} 条连接', icon: Icons.hub_rounded, dense: true),
                        ],
                      ),
                      const SizedBox(height: 8),
                      PmChart(
                        values: _series.length < 2 ? const [0, 0] : _series,
                        maxValue: maxScale,
                        height: 150,
                        color: _mode == 'upload' ? pm.series2 : scheme.primary,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                PmCard(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('目标与 DNS', style: context.text.titleMedium),
                          const Spacer(),
                          TextButton(
                            onPressed: running ? null : () => _openEndpoints(store),
                            child: Text('编辑', style: TextStyle(color: scheme.primary, fontSize: 13)),
                          ),
                        ],
                      ),
                      _ChipLine(
                        label: '测速目标 · ${(_mode == 'upload' ? store.uploadEndpoints : store.speedEndpoints).length}',
                        children: [
                          for (final e in (_mode == 'upload' ? store.uploadEndpoints : store.speedEndpoints))
                            PmChip(
                              label: _shortUrl(e),
                              icon: _mode == 'upload' ? Icons.upload_rounded : Icons.public_rounded,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _ChipLine(
                        label: 'DNS · ${store.dnsServers.length}',
                        children: [
                          for (final d in store.dnsServers)
                            PmChip(label: d, icon: Icons.dns_rounded, color: pm.muted),
                        ],
                      ),
                    ],
                  ),
                ),
                if (running || _routes.isNotEmpty) ...[
                  PmSectionTitle('连接明细', subtitle: '每个 worker 命中的 CDN IP 与 DNS 服务器'),
                  PmCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Column(
                      children: [
                        for (final r in _routes.take(12))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                PmPill(label: '#${r['idx']}', dense: true),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${r['ip']} · ${r['dns_server']}',
                                        style: context.text.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      IpGeoInline(ip: '${r['ip']}', fontSize: 10),
                                    ],
                                  ),
                                ),
                                Text(
                                  '${r['dns_ms']} ms',
                                  style: context.text.bodySmall?.copyWith(color: pm.muted),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (_errors.isNotEmpty) ...[
                  PmSectionTitle('错误', subtitle: '${_errors.length} 条'),
                  PmCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final e in _errors.take(5))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text('· $e', style: context.text.bodySmall?.copyWith(color: pm.warn)),
                          ),
                      ],
                    ),
                  ),
                ],
                if (!running && task?.summary != null) ...[
                  const SizedBox(height: 4),
                  _ResultCard(summary: task!.summary!, unit: store.displayUnit, factor: store.displayFactor, mode: _mode),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _shortUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return '${uri.host}${uri.path == '/' ? '' : uri.path}';
  }

  void _openEndpoints(AppStore store) {
    final controller = TextEditingController();
    showPmSheet(
      context,
      title: '测速地址（多 CDN）',
      body: StatefulBuilder(
        builder: (context, setSheet) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final e in store.speedEndpoints)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: PmCard(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  radius: 16,
                  child: Row(
                    children: [
                      Expanded(child: Text(e, style: context.text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis)),
                      IconButton(
                        onPressed: () {
                          final list = [...store.speedEndpoints]..remove(e);
                          store.setEndpoints(list);
                          setSheet(() {});
                          setState(() {});
                        },
                        icon: Icon(Icons.delete_outline_rounded, size: 18, color: context.pm.warn),
                      ),
                    ],
                  ),
                ),
              ),
            PmField(controller: controller, label: '新增 URL', hint: 'https://example.com/100MB.bin'),
            const SizedBox(height: 12),
            PmPrimaryButton(
              label: '添加',
              icon: Icons.add_rounded,
              onPressed: () {
                final v = controller.text.trim();
                if (v.isEmpty) return;
                store.setEndpoints([...store.speedEndpoints, v]);
                controller.clear();
                setSheet(() {});
                setState(() {});
              },
            ),
            const SizedBox(height: 10),
            Text('提示：地址需支持 Range 或返回大文件；Cloudflare __down 会自动按 bytes 参数返回。', style: context.text.bodySmall?.copyWith(color: context.pm.muted)),
          ],
        ),
      ),
    );
  }

  void _openTuning(AppStore store) {
    var workers = store.workers;
    var duration = store.durationSec;
    var sample = store.sampleMs;
    showPmSheet(
      context,
      title: '并发与时长',
      body: StatefulBuilder(
        builder: (context, setSheet) => Column(
          children: [
            PmSliderRow(
              label: '并发线程',
              value: workers.toDouble(),
              min: 1,
              max: 32,
              divisions: 31,
              display: (v) => v.toStringAsFixed(0),
              onChanged: (v) => setSheet(() => workers = v.round()),
            ),
            PmSliderRow(
              label: '测试时长',
              value: duration.toDouble(),
              min: 5,
              max: 60,
              divisions: 55,
              display: (v) => '${v.toStringAsFixed(0)} 秒',
              onChanged: (v) => setSheet(() => duration = v.round()),
            ),
            PmSliderRow(
              label: '采样间隔',
              value: sample.toDouble(),
              min: 100,
              max: 1000,
              divisions: 18,
              display: (v) => '${v.toStringAsFixed(0)} ms',
              onChanged: (v) => setSheet(() => sample = v.round()),
            ),
            const SizedBox(height: 12),
            PmPrimaryButton(
              label: '保存',
              onPressed: () {
                store.setWorkers(workers);
                store.setDuration(duration);
                store.setSampleMs(sample);
                Navigator.pop(context);
                setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ChipLine extends StatelessWidget {
  const _ChipLine({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 10.5, letterSpacing: 0.2),
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 36,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.summary, required this.unit, required this.factor, required this.mode});

  final Map<String, dynamic> summary;
  final String unit;
  final double factor;
  final String mode;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final pm = context.pm;
    final avg = (summary['steady_mbps'] ?? summary['avg_mbps'] as num? ?? 0).toDouble() * factor;
    final peak = (summary['peak_mbps'] as num? ?? 0).toDouble() * factor;
    final bytes = (summary['total_bytes'] as num? ?? 0).toInt();
    final errors = (summary['errors'] as num? ?? 0).toInt();
    return PmCard(
      gradient: LinearGradient(
        colors: [
          Color.alphaBlend(scheme.primary.withValues(alpha: context.isDark ? 0.20 : 0.10), pm.card),
          pm.card,
        ],
      ),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PmIconBadge(Icons.check_circle_rounded, color: pm.ok),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${mode == 'upload' ? '上传' : '下载'}测速完成', style: context.text.titleMedium),
                    const SizedBox(height: 2),
                    Text('稳定速率（已剔除启动爬升）', style: context.text.bodySmall?.copyWith(color: pm.muted)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatMbps(avg),
                    style: context.text.headlineMedium?.copyWith(color: scheme.primary),
                  ),
                  Text('稳定 $unit', style: context.text.bodySmall?.copyWith(color: pm.muted)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: PmStat(label: '峰值', value: formatMbps(peak), unit: unit)),
              Expanded(child: PmStat(label: '流量', value: formatBytes(bytes))),
              Expanded(child: PmStat(label: '错误', value: '$errors')),
            ],
          ),
        ],
      ),
    );
  }
}
