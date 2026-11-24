import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../bridge.dart';
import '../ip_geo_widgets.dart';
import '../page_kit.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';

enum ToolKind { ping, dns, nat, trace, iperf, download, browser, ipgeo, lan }

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  int _index = 0;

  static const _tabs = ['Ping', 'DNS', 'NAT', '路由', 'iperf3'];

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return SafeArea(
      bottom: false,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 110),
        children: [
          const PmPageHeader(
            title: '诊断工具',
            subtitle: 'TCP Ping · DNS 对照 · STUN NAT · UDP 路由追踪 · iperf3',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
            child: Column(
              children: [
                PmSegmented<int>(
                  items: [
                    for (var i = 0; i < _tabs.length; i++) (value: i, label: _tabs[i]),
                  ],
                  value: _index,
                  onChanged: (v) => setState(() => _index = v),
                ),
                const SizedBox(height: 14),
                AnimatedSwitcher(
                  duration: kMid,
                  switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(animation),
                      child: child,
                    ),
                  ),
                  child: switch (_index) {
                    0 => const PingPanel(),
                    1 => const DnsPanel(),
                    2 => const NatPanel(),
                    3 => const TracePanel(),
                    _ => const IperfPanel(),
                  },
                ),
                const SizedBox(height: 14),
                PmCard(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded, size: 16, color: pm.muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '诊断全部在本机 Rust core 执行：DNS 查询走自定义 UDP/TCP 解析器，Ping 为 TCP 握手 RTT，'
                          'NAT 使用 STUN Binding，路由追踪依赖内核 IP_RECVERR（部分 ROM 需 root）。',
                          style: context.text.bodySmall?.copyWith(color: pm.muted, height: 1.4),
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

class ToolDetailPage extends StatelessWidget {
  const ToolDetailPage({super.key, required this.tool});

  final ToolKind tool;

  @override
  Widget build(BuildContext context) {
    final name = switch (tool) {
      ToolKind.ping => 'Ping 延迟',
      ToolKind.dns => 'DNS 对照',
      ToolKind.nat => 'NAT 类型',
      ToolKind.trace => '路由追踪',
      ToolKind.iperf => 'iperf3 打流',
      ToolKind.download => '分段下载',
      ToolKind.browser => '浏览器',
      ToolKind.ipgeo => 'IP 归属地',
      ToolKind.lan => '局域网信息',
    };
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(kPagePadding, 8, kPagePadding, 100),
          children: [
            PmPageHeader(title: name, showBack: true),
            const SizedBox(height: 6),
            switch (tool) {
              ToolKind.ping => const PingPanel(),
              ToolKind.dns => const DnsPanel(),
              ToolKind.nat => const NatPanel(),
              ToolKind.trace => const TracePanel(),
              ToolKind.iperf => const IperfPanel(),
              ToolKind.download => const SizedBox.shrink(),
              ToolKind.ipgeo => const SizedBox.shrink(),
              ToolKind.lan => const SizedBox.shrink(),
              ToolKind.browser => const SizedBox.shrink(),
            },
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Ping

class PingPanel extends StatefulWidget {
  const PingPanel({super.key});

  @override
  State<PingPanel> createState() => _PingPanelState();
}

class _PingPanelState extends State<PingPanel> {
  final _target = TextEditingController(text: '223.5.5.5');
  final _port = TextEditingController(text: '53');
  final _count = TextEditingController(text: '20');
  bool _countInit = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_countInit) {
      _countInit = true;
      _count.text = '${AppScope.of(context).pingCount}';
    }
  }
  CoreTask? _task;
  final List<double> _rtts = [];
  final List<Map<String, dynamic>> _rows = [];
  Map<String, dynamic>? _summary;
  int _seen = 0;

  @override
  void dispose() {
    _task?.removeListener(_onTask);
    _task?.dispose();
    _target.dispose();
    _port.dispose();
    _count.dispose();
    super.dispose();
  }

  void _onTask() {
    final t = _task;
    if (t == null || !mounted) return;
    for (var i = _seen; i < t.events.length; i++) {
      final e = t.events[i];
      if (e['type'] == 'sample') {
        _rows.insert(0, e);
        if (_rows.length > 40) _rows.removeLast();
        if (e['ok'] == true && e['ms'] is num) {
          _rtts.add((e['ms'] as num).toDouble());
          if (_rtts.length > 60) _rtts.removeAt(0);
        }
      }
      if (e['type'] == 'resolve' && _rows.isEmpty) {
        _rows.insert(0, e);
      }
    }
    _seen = t.events.length;
    if (t.summary != null) _summary = t.summary;
    setState(() {});
    if (!t.running) _task?.removeListener(_onTask);
  }

  void _start() {
    final target = _target.text.trim();
    if (target.isEmpty) return;
    final count = (int.tryParse(_count.text) ?? 20).clamp(1, 500);
    _count.text = '$count';
    AppScope.of(context).setPingCount(count);
    final task = CoreTask.start('ping', {
      'target': target,
      'port': int.tryParse(_port.text) ?? 443,
      'count': count,
      'interval_ms': 700,
      'timeout_ms': 3000,
      'dns_servers': AppScope.of(context).dnsServers,
    });
    _rtts.clear();
    _rows.clear();
    _summary = null;
    _seen = 0;
    setState(() => _task = task);
    task.addListener(_onTask);
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final t = _task;
    final running = t?.running ?? false;
    return Column(
      children: [
        PmCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              PmField(controller: _target, label: '目标地址', hint: 'IP 或域名'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: PmField(controller: _port, label: 'TCP 端口', keyboardType: TextInputType.number),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PmField(controller: _count, label: '次数（默认 20）', keyboardType: TextInputType.number),
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: PmPrimaryButton(
                      label: running ? '停止' : '开始',
                      expand: false,
                      icon: running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      destructive: running,
                      onPressed: running ? () => t?.stop() : _start,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_summary != null) ...[
          const SizedBox(height: 12),
          PmCard(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(child: PmStat(label: '平均', value: formatLatency((_summary!['avg'] as num? ?? 0)), unit: 'ms')),
                Expanded(child: PmStat(label: '抖动', value: formatLatency((_summary!['jitter'] as num? ?? 0)), unit: 'ms')),
                Expanded(child: PmStat(label: '丢包', value: '${_summary!['loss'] ?? 0}', unit: '%')),
              ],
            ),
          ),
        ],
        if (_rtts.length > 1) ...[
          const SizedBox(height: 12),
          PmCard(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              children: [
                Row(
                  children: [
                    Text('RTT 曲线', style: context.text.titleSmall),
                    const Spacer(),
                    Text('${_rtts.length} 次成功', style: context.text.bodySmall?.copyWith(color: pm.muted)),
                  ],
                ),
                const SizedBox(height: 8),
                PmChart(values: _rtts, height: 110, maxValue: math.max(50, _rtts.reduce(math.max) * 1.2)),
              ],
            ),
          ),
        ],
        if (_rows.isNotEmpty) ...[
          const SizedBox(height: 12),
          PmCard(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('最近记录', style: context.text.titleSmall),
                    const Spacer(),
                    Text('${_rows.length} 条 · 可上下滑动', style: context.text.bodySmall?.copyWith(color: pm.muted)),
                  ],
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: _rows.length,
                    itemBuilder: (context, index) {
                      final r = _rows[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            if (r['type'] == 'resolve') ...[
                              PmIconBadge(Icons.lan_rounded, size: 30, radius: 10),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${r['ip']} · ${r['dns_server']} (${r['dns_ms']}ms)',
                                      style: context.text.bodySmall,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if ((r['ip'] ?? '').toString() != '*') IpGeoInline(ip: '${r['ip']}', fontSize: 10),
                                  ],
                                ),
                              ),
                            ] else ...[
                              SizedBox(
                                width: 34,
                                child: Text(
                                  '#${r['seq']}',
                                  style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  r['ok'] == true ? '${formatLatency((r['ms'] as num? ?? 0))} ms' : '超时',
                                  style: context.text.bodySmall?.copyWith(
                                    color: r['ok'] == true ? null : pm.warn,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 80,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: r['ok'] == true ? ((r['ms'] as num? ?? 0) / 200).clamp(0.05, 1.0) : 0,
                                    minHeight: 5,
                                    backgroundColor: pm.block,
                                    valueColor: AlwaysStoppedAnimation(r['ok'] == true ? pm.ok : pm.warn),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],

      ],
    );
  }
}

// ------------------------------------------------------------------ DNS

class DnsPanel extends StatefulWidget {
  const DnsPanel({super.key});

  @override
  State<DnsPanel> createState() => _DnsPanelState();
}

class _DnsPanelState extends State<DnsPanel> {
  final _host = TextEditingController(text: 'www.baidu.com');
  CoreTask? _task;
  final List<Map<String, dynamic>> _rows = [];
  int _seen = 0;

  @override
  void dispose() {
    _task?.removeListener(_onTask);
    _task?.dispose();
    _host.dispose();
    super.dispose();
  }

  void _onTask() {
    final t = _task;
    if (t == null || !mounted) return;
    for (var i = _seen; i < t.events.length; i++) {
      final e = t.events[i];
      if (e['type'] == 'result' || e['type'] == 'error') {
        _rows.add(e);
        if (_rows.length > 80) _rows.removeAt(0);
      }
    }
    _seen = t.events.length;
    setState(() {});
    if (!t.running) _task?.removeListener(_onTask);
  }

  void _start() {
    final host = _host.text.trim();
    if (host.isEmpty) return;
    _rows.clear();
    _seen = 0;
    final task = CoreTask.start('dns', {
      'host': host,
      'servers': normalizeDnsList(AppScope.of(context).dnsServers),
      'timeout_ms': 3000,
      'qtype': 'BOTH',
    });
    setState(() => _task = task);
    task.addListener(_onTask);
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final running = _task?.running ?? false;
    final fastest = _rows.where((r) => r['ms'] is num).isEmpty
        ? null
        : _rows.where((r) => r['ms'] is num).reduce((a, b) => (a['ms'] as num) < (b['ms'] as num) ? a : b);
    return Column(
      children: [
        PmCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              PmField(controller: _host, label: '域名', hint: 'example.com'),
              const SizedBox(height: 12),
              PmPrimaryButton(
                label: running ? '查询中…' : '多 DNS 对照查询',
                icon: Icons.search_rounded,
                loading: running,
                onPressed: running ? null : _start,
              ),
            ],
          ),
        ),
        if (fastest != null) ...[
          const SizedBox(height: 12),
          PmCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                PmIconBadge(Icons.bolt_rounded, color: pm.ok),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '最快：${fastest['server']} · ${fastest['ms']} ms',
                    style: context.text.titleSmall,
                  ),
                ),
                PmPill(label: '${_rows.where((e) => e['type'] == 'error').length} 失败', color: pm.warn, dense: true),
              ],
            ),
          ),
        ],
        if (_rows.isNotEmpty) ...[
          const SizedBox(height: 12),
          PmCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Column(
              children: [
                for (final r in _rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 46,
                          child: Text(
                            r['record']?.toString() ?? 'ERR',
                            style: context.text.bodySmall?.copyWith(
                              color: r['type'] == 'error' ? pm.warn : context.scheme.primary,
                              fontWeight: FontWeight.w600,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 108,
                          child: Text(
                            r['server']?.toString() ?? '',
                            style: context.text.bodySmall?.copyWith(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Expanded(
                          child: r['type'] == 'error'
                              ? Text(r['message']?.toString() ?? '', style: context.text.bodySmall?.copyWith(color: pm.warn, fontSize: 11))
                              : (r['ips'] as List? ?? const []).isEmpty
                                  ? Text('无记录', style: context.text.bodySmall?.copyWith(fontSize: 12))
                                  : Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        for (final ip in (r['ips'] as List))
                                          IpGeoInline(ip: ip.toString(), showIp: true, fontSize: 11.5),
                                      ],
                                    ),
                        ),
                        Text(
                          r['ms'] == null ? '' : '${r['ms']}ms',
                          style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ------------------------------------------------------------------ NAT

class NatPanel extends StatefulWidget {
  const NatPanel({super.key});

  @override
  State<NatPanel> createState() => _NatPanelState();
}

class _NatPanelState extends State<NatPanel> {
  CoreTask? _task;
  Map<String, dynamic>? _summary;
  final List<Map<String, dynamic>> _logs = [];
  int _seen = 0;

  @override
  void dispose() {
    _task?.removeListener(_onTask);
    _task?.dispose();
    super.dispose();
  }

  void _onTask() {
    final t = _task;
    if (t == null || !mounted) return;
    for (var i = _seen; i < t.events.length; i++) {
      final e = t.events[i];
      if (e['type'] != 'sample') {
        _logs.add(e);
        if (_logs.length > 30) _logs.removeAt(0);
      }
    }
    _seen = t.events.length;
    if (t.summary != null) _summary = t.summary;
    setState(() {});
    if (!t.running) _task?.removeListener(_onTask);
  }

  void _start() {
    _logs.clear();
    _seen = 0;
    _summary = null;
    final task = CoreTask.start('nat', {
      'servers': const [
        'stun.cloudflare.com:3478',
        'stun.l.google.com:19302',
        'stun1.l.google.com:19302',
        'stun.nextcloud.com:3478',
        'stun.sipgate.net:3478',
        'stun.voipbuster.com:3478',
        'stun.miwifi.com:3478',
      ],
      'timeout_ms': 1500,
      'dns_servers': AppScope.of(context).dnsServers,
    });
    setState(() => _task = task);
    task.addListener(_onTask);
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final running = _task?.running ?? false;
    return Column(
      children: [
        PmCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  PmIconBadge(Icons.router_rounded, color: pm.warn),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('STUN NAT 探测', style: context.text.titleSmall),
                        Text('Cloudflare / Google / Nextcloud / 小米 STUN · 多服务器映射判定', style: context.text.bodySmall?.copyWith(color: pm.muted)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              PmPrimaryButton(
                label: running ? '探测中…' : '开始探测',
                loading: running,
                icon: Icons.wifi_tethering_rounded,
                onPressed: running ? null : _start,
              ),
            ],
          ),
        ),
        if (_summary != null) ...[
          const SizedBox(height: 12),
          PmCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: PmStat(label: '公网地址', value: '${_summary!['public'] ?? '--'}')),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: PmStat(label: '映射行为', value: '${_summary!['mapping_behavior'] ?? '--'}')),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: PmStat(label: 'NAT 类型', value: '${_summary!['nat_type'] ?? '--'}', tint: pm.warn)),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: ShapeDecoration(
                    color: pm.warnSoft,
                    shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    '过滤行为：${_summary!['filtering_behavior'] ?? '未测试'}。完整类型判定需要双 STUN 服务器配合，本页给出映射行为与端口稳定性。',
                    style: context.text.bodySmall?.copyWith(color: pm.warn),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_logs.isNotEmpty) ...[
          const SizedBox(height: 12),
          PmCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final l in _logs.take(10))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      l['type'] == 'error'
                          ? '× ${l['server'] ?? ''} ${l['message'] ?? ''}'
                          : '· ${l['type']} ${l['server'] ?? ''} ${l['public'] ?? ''}',
                      style: context.text.bodySmall?.copyWith(color: l['type'] == 'error' ? pm.warn : pm.muted, fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ------------------------------------------------------------------ Trace

class TracePanel extends StatefulWidget {
  const TracePanel({super.key});

  @override
  State<TracePanel> createState() => _TracePanelState();
}

class _TracePanelState extends State<TracePanel> {
  final _target = TextEditingController(text: '223.5.5.5');
  final _maxHops = TextEditingController(text: '30');
  CoreTask? _task;
  final List<Map<String, dynamic>> _hops = [];
  int _seen = 0;

  @override
  void dispose() {
    _task?.removeListener(_onTask);
    _task?.dispose();
    _target.dispose();
    _maxHops.dispose();
    super.dispose();
  }

  void _onTask() {
    final t = _task;
    if (t == null || !mounted) return;
    // 只消费新增事件，避免每次轮询把旧 hop 重复追加，看起来像无限循环。
    for (var i = _seen; i < t.events.length; i++) {
      final e = t.events[i];
      if (e['type'] == 'hop' && e['hop'] is Map) {
        final hop = (e['hop'] as Map).cast<String, dynamic>();
        final ttl = hop['ttl'];
        _hops.removeWhere((h) => h['ttl'] == ttl);
        _hops.add(hop);
      }
    }
    _seen = t.events.length;
    setState(() {});
    if (!t.running) _task?.removeListener(_onTask);
  }

  void _start() {
    _task?.removeListener(_onTask);
    _task?.dispose();
    _seen = 0;
    final hops = (int.tryParse(_maxHops.text.trim()) ?? 30).clamp(1, 64);
    _maxHops.text = '$hops';
    final task = CoreTask.start('trace', {
      'target': _target.text.trim(),
      'max_hops': hops,
      'timeout_ms': 1500,
    });
    setState(() => _task = task);
    task.addListener(_onTask);
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final running = _task?.running ?? false;
    return Column(
      children: [
        PmCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              PmField(controller: _target, label: '目标 IP', hint: '例如 223.5.5.5'),
              const SizedBox(height: 10),
              PmField(
                controller: _maxHops,
                label: '最大跳数（默认 30，可填 1–64）',
                hint: '30',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 10),
              Text(
                'Android 无 root 时通过内核 IP_RECVERR 读取 ICMP，部分 ROM 可能拒绝该 sockopt。',
                style: context.text.bodySmall?.copyWith(color: pm.muted),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: PmPrimaryButton(
                      label: running
                          ? ((_task?.stopping ?? false) ? '停止中…' : '停止追踪')
                          : '开始追踪',
                      loading: _task?.stopping ?? false,
                      icon: running ? Icons.stop_rounded : Icons.route_rounded,
                      destructive: running,
                      onPressed: running ? () => _task?.stop() : _start,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_hops.isNotEmpty) ...[
          const SizedBox(height: 12),
          PmCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              children: [
                for (final h in _hops)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 28,
                          child: Text('${h['ttl']}', style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11)),
                        ),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: h['ip'] == '*' ? pm.track : (h['reached'] == true ? pm.ok : context.scheme.primary),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${h['ip']}',
                                style: context.text.bodySmall?.copyWith(
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                  color: h['ip'] == '*' ? pm.muted : null,
                                ),
                              ),
                              if (h['ip'] != '*') IpGeoInline(ip: '${h['ip']}', fontSize: 10),
                            ],
                          ),
                        ),
                        Text(
                          h['ms'] == null ? '*' : '${h['ms']} ms',
                          style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ------------------------------------------------------------------ iperf3

/// 内置公共 iperf3 服务器（来源：iperf.fr 官方列表，按地区分组）。
const _iperfServers = [
  ('巴黎 · OpenDSL', 'iperf.par2.as49434.net', '9200'),
  ('阿姆斯特丹 · WorldStream', 'speedtest.worldstream.nl', '5201'),
  ('法兰克福 · LG', 'speedtest.frankfurt.linode.com', '5201'),
  ('悉尼 · LG', 'speedtest.sydney.linode.com', '5201'),
  ('新加坡 · LG', 'speedtest.singapore.linode.com', '5201'),
  ('纽约 · LG', 'speedtest.newark.linode.com', '5201'),
  ('达拉斯 · LG', 'speedtest.dallas.linode.com', '5201'),
  ('弗里蒙特 · LG', 'speedtest.fremont.linode.com', '5201'),
  ('亚特兰大 · LG', 'speedtest.atlanta.linode.com', '5201'),
  ('伦敦 · Linode', 'speedtest.london.linode.com', '5201'),
];

class IperfPanel extends StatefulWidget {
  const IperfPanel({super.key});

  @override
  State<IperfPanel> createState() => _IperfPanelState();
}

class _IperfPanelState extends State<IperfPanel> {
  String _role = 'client';
  final _host = TextEditingController(text: 'iperf.par2.as49434.net');
  final _port = TextEditingController(text: '9200');
  final _streams = TextEditingController(text: '4');
  final _duration = TextEditingController(text: '10');
  final _interval = TextEditingController(text: '1');
  bool _reverse = false;
  bool _udp = false;
  bool _downloadMode = true;
  CoreTask? _task;
  final List<String> _lines = [];
  int _seen = 0;
  String? _binProblem;

  @override
  void initState() {
    super.initState();
    _checkBinary();
  }

  Future<void> _checkBinary() async {
    // iperf3 以 libiperf3.so 形式打进 nativeLibDir，Android 9+ 可直接执行。
    await NativeInfo.load();
    if (!mounted) return;
    String? problem;
    if (!NativeInfo.iperfAvailable) {
      problem = NativeInfo.iperfPath.isEmpty
          ? '未找到内置 iperf3（libiperf3.so 未打包）'
          : '内置 iperf3 不可执行：${NativeInfo.iperfPath}';
    } else if (NativeInfo.sdkInt != 0 && NativeInfo.sdkInt < 28) {
      problem = '内置 iperf3 需要 Android 9（API 28）及以上，当前 API ${NativeInfo.sdkInt}';
    }
    setState(() => _binProblem = problem);
  }

  @override
  void dispose() {
    _task?.removeListener(_onTask);
    _task?.dispose();
    _host.dispose();
    _port.dispose();
    _streams.dispose();
    _duration.dispose();
    _interval.dispose();
    super.dispose();
  }

  void _onTask() {
    final t = _task;
    if (t == null || !mounted) return;
    for (var i = _seen; i < t.events.length; i++) {
      final e = t.events[i];
      if (e['type'] == 'line' && e['line'] != null) {
        _lines.add(e['line'].toString());
        if (_lines.length > 400) _lines.removeAt(0);
      }
      if (e['type'] == 'error') _lines.add('ERROR: ${e['message']}');
    }
    _seen = t.events.length;
    setState(() {});
    if (!t.running) _task?.removeListener(_onTask);
  }

  void _start() {
    final bin = NativeInfo.iperfPath;
    if (bin.isEmpty || !NativeInfo.iperfAvailable) {
      pmToast(context, '未找到内置 iperf3 可执行文件');
      return;
    }
    if (NativeInfo.sdkInt != 0 && NativeInfo.sdkInt < 28) {
      pmToast(context, '内置 iperf3 需要 Android 9（API 28）及以上');
      return;
    }
    final port = _port.text.trim().isEmpty ? '5201' : _port.text.trim();
    final args = <String>[];
    if (_role == 'server') {
      args.addAll(['-s', '-p', port]);
    } else {
      args.addAll(['-c', _host.text.trim(), '-p', port]);
      final streams = (int.tryParse(_streams.text) ?? 4).clamp(1, 128);
      final secs = (int.tryParse(_duration.text) ?? 10).clamp(1, 3600);
      final interval = (int.tryParse(_interval.text) ?? 1).clamp(1, 60);
      args.addAll(['-P', '$streams', '-t', '$secs', '-i', '$interval']);
      if (_reverse) args.add('-R');
      if (_udp) args.add('-u');
      if (_udp) args.addAll(['-b', '100M']);
    }
    _lines.clear();
    _seen = 0;
    _task?.removeListener(_onTask);
    _task?.dispose();
    final task = CoreTask.start('iperf', {
      'bin': bin,
      'args': args,
      'cwd': NativeInfo.cacheDir.isEmpty ? null : NativeInfo.cacheDir,
    });
    setState(() => _task = task);
    task.addListener(_onTask);
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final running = _task?.running ?? false;
    return Column(
      children: [
        if (_binProblem != null) ...[
          PmCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 18, color: pm.warn),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _binProblem!,
                    style: context.text.bodySmall?.copyWith(color: pm.warn, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        PmCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              PmSegmented<String>(
                items: const [
                  (value: 'client', label: '客户端'),
                  (value: 'server', label: '服务端'),
                ],
                value: _role,
                onChanged: (v) => setState(() => _role = v),
              ),
              const SizedBox(height: 14),
              if (_role == 'client') ...[
                PmField(controller: _host, label: '服务器', hint: 'host 或 IP'),
                const SizedBox(height: 8),
                SizedBox(
                  height: 34,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (name, host, port) in _iperfServers)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ActionChip(
                              label: Text(name, style: const TextStyle(fontSize: 10.5)),
                              onPressed: () {
                                setState(() {
                                  _host.text = host;
                                  _port.text = port;
                                });
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: PmField(controller: _streams, label: '并发流 (-P)', keyboardType: TextInputType.number)),
                    const SizedBox(width: 10),
                    Expanded(child: PmField(controller: _duration, label: '时长秒 (-t)', keyboardType: TextInputType.number)),
                    const SizedBox(width: 10),
                    Expanded(child: PmField(controller: _interval, label: '报告间隔 (-i)', keyboardType: TextInputType.number)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: PmSegmented<String>(
                        items: const [
                          (value: 'down', label: '下行 (-R)'),
                          (value: 'up', label: '上行'),
                        ],
                        value: _downloadMode ? 'down' : 'up',
                        onChanged: (v) => setState(() {
                          _downloadMode = v == 'down';
                          _reverse = _downloadMode;
                        }),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: PmSegmented<String>(
                        items: const [
                          (value: 'tcp', label: 'TCP'),
                          (value: 'udp', label: 'UDP'),
                        ],
                        value: _udp ? 'udp' : 'tcp',
                        onChanged: (v) => setState(() => _udp = v == 'udp'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  Expanded(child: PmField(controller: _port, label: '端口 (-p)', keyboardType: TextInputType.number)),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: PmPrimaryButton(
                      label: running ? '停止' : (_role == 'server' ? '启动服务端' : '开始打流'),
                      expand: false,
                      icon: running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      destructive: running,
                      onPressed: running ? () => _task?.stop() : _start,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        PmCard(
          padding: const EdgeInsets.all(0),
          color: const Color(0xFF0D0D10),
          border: BorderSide(color: pm.inset),
          child: Container(
            height: 300,
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_lines.isEmpty)
                    Text(
                      _binProblem != null
                          ? '解决上方问题后即可打流。'
                          : 'iperf3 输出将显示在这里。\n'
                              '客户端示例：iperf3 -c <服务器> -p 5201 -P 4 -t 10 -i 1 -R\n'
                              '也可自建：电脑端运行 iperf3 -s，手机连同一网络后填电脑 IP。',
                      style: const TextStyle(color: Color(0xFF6E6E7A), fontSize: 11, height: 1.5, fontFamily: 'monospace'),
                    ),
                  for (final line in _lines.reversed.take(60).toList().reversed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        line,
                        style: const TextStyle(color: Color(0xFFB9F6CA), fontSize: 11, height: 1.45, fontFamily: 'monospace'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '内置 iperf3 由 BSD-3-Clause 授权（Lawrence Berkeley National Laboratory），以 libiperf3.so 形式随包提供；'
          '公共服务器来自 iperf.fr 公开列表，可用性以实际为准。',
          style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
        ),
      ],
    );
  }
}
