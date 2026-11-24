import 'dart:isolate';

import 'package:flutter/material.dart';

import '../bridge.dart';
import '../ip_geo_widgets.dart';
import '../page_kit.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';

const _cnNames = <String, String>{
  'CN': '中国', 'HK': '中国香港', 'MO': '中国澳门', 'TW': '中国台湾',
  'US': '美国', 'JP': '日本', 'KR': '韩国', 'SG': '新加坡', 'MY': '马来西亚',
  'TH': '泰国', 'VN': '越南', 'PH': '菲律宾', 'ID': '印度尼西亚', 'IN': '印度',
  'AU': '澳大利亚', 'NZ': '新西兰', 'CA': '加拿大', 'GB': '英国', 'DE': '德国',
  'FR': '法国', 'IT': '意大利', 'ES': '西班牙', 'NL': '荷兰', 'BE': '比利时',
  'CH': '瑞士', 'SE': '瑞典', 'NO': '挪威', 'DK': '丹麦', 'FI': '芬兰',
  'RU': '俄罗斯', 'UA': '乌克兰', 'TR': '土耳其', 'AE': '阿联酋', 'SA': '沙特阿拉伯',
  'IL': '以色列', 'BR': '巴西', 'AR': '阿根廷', 'MX': '墨西哥', 'CL': '智利',
  'ZA': '南非', 'EG': '埃及', 'NG': '尼日利亚', 'KE': '肯尼亚', 'PK': '巴基斯坦',
  'BD': '孟加拉国', 'LK': '斯里兰卡', 'MM': '缅甸', 'KH': '柬埔寨', 'LA': '老挝',
  'MN': '蒙古', 'NP': '尼泊尔', 'KZ': '哈萨克斯坦', 'IR': '伊朗', 'IQ': '伊拉克',
};

String flagOf(String code) {
  final c = code.toUpperCase();
  if (c.length != 2 || c == 'ZZ') return '🌐';
  final runes = c.runes.map((r) => String.fromCharCode(0x1F1E6 + (r - 65))).join();
  return runes;
}

String countryLabel(Map<String, dynamic> data) {
  final code = (data['country_code'] ?? '').toString().toUpperCase();
  final cn = _cnNames[code];
  if (cn != null) return cn;
  final en = (data['country'] ?? '').toString();
  return en.isEmpty ? (code.isEmpty ? '未知' : code) : en;
}

typedef _Job = ({String op, Map<String, dynamic> args});

Future<Map<String, dynamic>> _runCore(_Job job) {
  return Isolate.run(() {
    Core.i.init();
    return Core.i.call(job.op, job.args);
  });
}

class IpGeoPage extends StatefulWidget {
  const IpGeoPage({super.key});

  @override
  State<IpGeoPage> createState() => _IpGeoPageState();
}

class _IpGeoPageState extends State<IpGeoPage> {
  final _ip = TextEditingController(text: '8.8.8.8');
  late final TextEditingController _dbUrl;
  late final TextEditingController _api;
  Map<String, dynamic>? _local;
  Map<String, dynamic>? _apiData;
  IpTypeInfo? _type;
  Map<String, dynamic>? _resolved;
  Map<String, dynamic> _egress = {};
  bool _egressBusy = false;
  Map<String, dynamic>? _info;
  String? _error;
  bool _busy = false;
  bool _updating = false;

  String get _dbPath => '${NativeInfo.filesDir}/ipdb.tsv';

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final store = AppScope.of(context);
    _dbUrl = TextEditingController(text: store.ipdbUrl);
    _api = TextEditingController(text: store.ipApiEndpoint);
    _loadInfo();
    _loadEgress();
  }

  @override
  void dispose() {
    _ip.dispose();
    _dbUrl.dispose();
    _api.dispose();
    super.dispose();
  }

  Future<void> _loadInfo() async {
    try {
      final r = await _runCore((op: 'ipdb_info', args: {'path': _dbPath}));
      if (mounted) setState(() => _info = r['data'] as Map<String, dynamic>?);
    } catch (_) {}
  }

  Future<void> _loadEgress() async {
    setState(() => _egressBusy = true);
    try {
      final r = await _runCore((op: 'ipdb_egress', args: const {}));
      final d = (r['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final out = <String, dynamic>{};
      final probeData = (d['probes'] as Map?)?.cast<String, dynamic>() ?? const {};
      Future<void> load(String key, String ip) async {
        if (ip.isEmpty) return;
        IpGeoInfo? info;
        try { info = await IpGeoService.lookup(ip); } catch (_) {}
        Map<String, dynamic>? api;
        try {
          final a = await _runCore((op: 'ip_api', args: {'ip': ip, 'endpoint': _api.text.trim()}));
          if (a['ok'] == true) api = (a['data'] as Map).cast<String, dynamic>();
        } catch (_) {}
        out[key] = {'ip': ip, 'local': info, 'api': api, 'purity': _purity(api)};
      }
      if (probeData.isNotEmpty) {
        for (final spec in const [
          (key: 'ipv4_cn', probe: 'ipv4_cn'),
          (key: 'ipv4_intl', probe: 'ipv4_intl'),
          (key: 'ipv6_intl', probe: 'ipv6_intl'),
        ]) {
          final p = (probeData[spec.probe] as Map?)?.cast<String, dynamic>();
          await load(spec.key, p?['ip']?.toString() ?? '');
        }
      } else {
        for (final family in ['ipv4', 'ipv6']) {
          await load(family, d[family]?.toString() ?? '');
        }
      }
      if (mounted) setState(() { _egress = out; _egressBusy = false; });
    } catch (e) {
      if (mounted) setState(() { _egressBusy = false; _error = '出口 IP 探测失败：$e'; });
    }
  }

  int _purity(Map<String, dynamic>? api) {
    if (api == null || api['status'] == 'fail') return 0;
    final text = '${api['isp'] ?? ''} ${api['org'] ?? ''} ${api['as'] ?? ''}'.toLowerCase();
    const hosting = ['amazon', 'aws', 'google cloud', 'azure', 'aliyun', 'tencent cloud', 'cloud', 'hosting', 'datacenter', 'data center', 'vps', 'server', 'digitalocean', 'linode', 'vultr', 'ovh', 'hetzner', 'oracle cloud', 'colocation'];
    const proxy = ['vpn', 'proxy', 'tor ', 'shadowsocks', 'socks'];
    var score = 92;
    if (hosting.any(text.contains)) score -= 42;
    if (proxy.any(text.contains)) score -= 32;
    if ((api['isp']?.toString() ?? '').isEmpty) score -= 8;
    if ((api['country']?.toString() ?? '').isEmpty) score -= 20;
    return score.clamp(0, 100);
  }

  Future<void> _query() async {
    var ip = _ip.text.trim();
    final isV4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(ip);
    final isV6 = ip.contains(':') && RegExp(r'^[0-9a-fA-F:]+$').hasMatch(ip);
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _local = null;
      _apiData = null;
      _type = null;
      _resolved = null;
    });
    try {
      if (!isV4 && !isV6) {
        if (ip.isEmpty) throw '请输入 IP 或域名';
        final r = await _runCore((op: 'dns_resolve', args: {'host': ip, 'servers': AppScope.of(context).dnsServers}));
        if (r['ok'] != true) throw (r['error']?.toString() ?? '解析失败');
        final d = (r['data'] as Map).cast<String, dynamic>();
        _resolved = d;
        final v4 = (d['ipv4'] as List? ?? const []);
        final v6 = (d['ipv6'] as List? ?? const []);
        if (v4.isEmpty && v6.isEmpty) {
          throw '域名未解析到可用地址';
        }
        ip = (v4.isNotEmpty ? (v4.first as Map)['ip'] : (v6.first as Map)['ip']).toString();
      }
      Map<String, dynamic>? api;
      IpTypeInfo? type;
      // 在线优先：自定义 API 失败时，自动尝试内置的多个公共 API。
      try {
        final r = await _runCore((op: 'ip_api', args: {'ip': ip, 'endpoint': _api.text.trim()}));
        if (r['ok'] == true) {
          final data = (r['data'] as Map).cast<String, dynamic>();
          if (data['status'] == 'success') api = data;
        }
        if (api == null) {
          final fallback = await _runCore((op: 'ip_geo_auto', args: {'ip': ip}));
          if (fallback['ok'] == true) {
            api = (fallback['data'] as Map?)?.cast<String, dynamic>();
          }
        }
      } catch (e) {
        _error = 'IP API 不可用：$e';
      }
      // 离线库始终查询，作为在线 API 失败时的兜底。
      final local = await _runCore((op: 'ipdb_lookup', args: {'ip': ip, 'path': _dbPath}));
      try {
        final q = await _runCore((op: 'ip_type', args: {'ip': ip}));
        if (q['ok'] == true) {
          type = IpTypeInfo.fromJson((q['data'] as Map).cast<String, dynamic>());
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _local = (local['data'] as Map?)?.cast<String, dynamic>();
        _apiData = api;
        _type = type;
        _busy = false;
      });
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = '$e'; });
    }
  }

  Future<void> _updateDb() async {
    final url = _dbUrl.text.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      pmToast(context, '请填写 CSV / CSV.GZ 更新地址');
      return;
    }
    AppScope.of(context).setIpdbUrl(url);
    setState(() => _updating = true);
    try {
      final r = await _runCore((op: 'ipdb_update', args: {'path': _dbPath, 'url': url}));
      if (!mounted) return;
      if (r['ok'] == true) {
        final data = (r['data'] as Map?) ?? const {};
        pmToast(context, '位置库已更新：${data['count']} 条');
        await _loadInfo();
      } else {
        pmToast(context, r['error']?.toString() ?? '更新失败');
      }
    } catch (e) {
      if (mounted) pmToast(context, '更新失败：$e');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  String _monthPreset() {
    final now = DateTime.now();
    final m = now.month.toString().padLeft(2, '0');
    return 'https://download.db-ip.com/free/dbip-country-lite-${now.year}-$m.csv.gz';
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    final info = _info;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 8, kPagePadding, 30),
          children: [
            const PmPageHeader(title: 'IP 归属地', subtitle: '内置位置库 · 出口纯净度 · 多字段 IP API', showBack: true),
            _buildEgress(context),
            const SizedBox(height: 14),
            PmCard(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PmField(controller: _ip, label: 'IP 或域名', hint: '8.8.8.8 / example.com / IPv6', keyboardType: TextInputType.text),
                  const SizedBox(height: 12),
                  PmPrimaryButton(
                    label: _busy ? '查询中…' : '查询归属地',
                    icon: Icons.travel_explore_rounded,
                    onPressed: _busy ? null : _query,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: context.text.bodySmall?.copyWith(color: pm.warn)),
                  ],
                ],
              ),
            ),
            if (_resolved != null) ...[
              const SizedBox(height: 14),
              _ResolvedCard(data: _resolved!),
            ],
            const SizedBox(height: 14),
            if (_local != null) _LocalCard(data: _local!, info: info, api: _apiData, type: _type),
            if (_apiData != null) ...[
              const SizedBox(height: 14),
              _ApiCard(data: _apiData!, local: _local),
            ],
            const SizedBox(height: 14),
            PmSectionTitle('位置库'),
            PmCard(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      PmIconBadge(Icons.public_rounded, color: scheme.primary, size: 36, radius: 12),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(info?['builtin'] == true ? '内置国家 / 地区库' : '本地位置库', style: context.text.titleMedium),
                            const SizedBox(height: 2),
                            Text(
                              '${info?['count'] ?? '—'} 条 · ${info?['builtin'] == true ? '开箱可用' : _fmtDate(info?['updated'])}',
                              style: context.text.bodySmall?.copyWith(color: pm.muted),
                            ),
                          ],
                        ),
                      ),
                      PmPill(label: info?['builtin'] == true ? '内置' : '已更新', dense: true),
                    ],
                  ),
                  const SizedBox(height: 12),
                  PmField(
                    controller: _dbUrl,
                    label: '更新地址（CSV / CSV.GZ）',
                    hint: _monthPreset(),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          _dbUrl.text = _monthPreset();
                          setState(() {});
                        },
                        child: const Text('填入本月国家库'),
                      ),
                      const Spacer(),
                      PmPrimaryButton(
                        label: _updating ? '更新中…' : '更新位置库',
                        icon: Icons.system_update_alt_rounded,
                        expand: false,
                        onPressed: _updating ? null : _updateDb,
                      ),
                    ],
                  ),
                  Text(
                    info?['source']?.toString() ?? '',
                    style: context.text.bodySmall?.copyWith(color: pm.muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            PmSectionTitle('IP API'),
            PmCard(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PmField(
                    controller: _api,
                    label: '接口地址（{ip} 占位）',
                    hint: 'https://ipwho.is/{ip}',
                    maxLines: 2,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '留空使用内置默认接口。接口返回的原始字段会全部展示，便于查看 ISP、ASN、坐标与时区。',
                    style: context.text.bodySmall?.copyWith(color: pm.muted, height: 1.45),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEgress(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    Widget family(String key, String label) {
      final e = _egress[key] as Map<String, dynamic>?;
      if (e == null) {
        return Text('$label 不可用', style: context.text.bodySmall?.copyWith(color: pm.muted));
      }
      final local = e['local'] as IpGeoInfo?;
      final api = e['api'] as Map<String, dynamic>?;
      final purity = e['purity'] as int? ?? 0;
      final color = purity >= 80 ? pm.ok : (purity >= 55 ? scheme.primary : pm.warn);
      final rawGeo = [api?['country'], api?['regionName'], api?['city']]
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
      final geo = rawGeo.isEmpty ? (local?.label ?? '未知') : rawGeo.join(' · ');
      final isp = api?['isp']?.toString() ?? local?.isp ?? '';
      final cc = api?['countryCode']?.toString() ?? local?.countryCode ?? '';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(cc.isNotEmpty ? flagOf(cc) : '🌐', style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 6),
              Text(label, style: context.text.bodySmall?.copyWith(color: pm.muted, fontWeight: FontWeight.w600)),
              const Spacer(),
              PmPill(label: '纯净度 $purity', color: color, dense: true),
            ],
          ),
          const SizedBox(height: 3),
          Text(e['ip'].toString(), style: context.text.bodyMedium?.copyWith(fontFamily: 'monospace')),
          const SizedBox(height: 1),
          Text(
            [geo, if (isp.isNotEmpty) isp].join(' · '),
            style: context.text.bodySmall?.copyWith(fontSize: 12.5, color: pm.muted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );
    }

    return PmCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PmIconBadge(Icons.wifi_tethering_rounded, color: scheme.primary, size: 34, radius: 11),
              const SizedBox(width: 10),
              Expanded(child: Text('当前出口 IP', style: context.text.titleMedium)),
              if (_egressBusy)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              else
                InkWell(onTap: _loadEgress, child: Icon(Icons.refresh_rounded, size: 18, color: pm.muted)),
            ],
          ),
          const SizedBox(height: 10),
          if (_egress.containsKey('ipv4_cn') || _egress.containsKey('ipv4_intl')) ...[
            family('ipv4_cn', 'IPv4 · 国内探测'),
            const SizedBox(height: 10),
            family('ipv4_intl', 'IPv4 · 外部探测'),
            const SizedBox(height: 10),
            Divider(height: 1, color: pm.inset),
            const SizedBox(height: 10),
            family('ipv6_intl', 'IPv6 · 外部探测'),
          ] else ...[
            family('ipv4', 'IPv4'),
            const SizedBox(height: 10),
            Divider(height: 1, color: pm.inset),
            const SizedBox(height: 10),
            family('ipv6', 'IPv6'),
          ],
          const SizedBox(height: 8),
          Text(
            '纯净度基于 ISP / 组织名称中的机房、云主机、代理特征做启发式评估，仅供参考。',
            style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 10.5),
          ),
        ],
      ),
    );
  }

  static String _fmtDate(dynamic v) {
    final ts = v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    if (ts <= 0) return '内置';
    final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

class _ResolvedCard extends StatelessWidget {
  const _ResolvedCard({required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final v4 = (data['ipv4'] as List? ?? const []).whereType<Map>().toList();
    final v6 = (data['ipv6'] as List? ?? const []).whereType<Map>().toList();
    return PmCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PmIconBadge(Icons.dns_rounded, size: 32, radius: 10),
              const SizedBox(width: 10),
              Expanded(child: Text('域名解析 · ${data['host']}', style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ),
          const SizedBox(height: 10),
          for (final ip in [...v4, ...v6])
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: IpGeoInline(ip: ip['ip'].toString(), showIp: true, fontSize: 11.5),
            ),
          if (v4.isEmpty && v6.isEmpty)
            Text('无解析结果', style: context.text.bodySmall?.copyWith(color: pm.warn)),
        ],
      ),
    );
  }
}

class _LocalCard extends StatelessWidget {
  const _LocalCard({required this.data, this.info, this.api, this.type});

  final Map<String, dynamic> data;
  final Map<String, dynamic>? info;
  final Map<String, dynamic>? api;
  final IpTypeInfo? type;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    final code = (api?['countryCode'] ?? data['country_code'] ?? '').toString();
    final found = data['found'] == true || api?['status'] == 'success';
    final precise = [api?['country'], api?['regionName'], api?['city']]
        .map((e) => e?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
    final regionText = precise.isEmpty
        ? [data['region'], data['city']].where((e) => (e ?? '').toString().isNotEmpty).join(' · ')
        : precise.join(' · ');
    final headline = precise.isNotEmpty ? precise.join(' · ') : (found ? countryLabel(data) : '未收录该 IP');
    return PmCard(
      gradient: LinearGradient(
        colors: [
          Color.alphaBlend(scheme.primary.withValues(alpha: context.isDark ? 0.20 : 0.09), pm.card),
          pm.card,
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(found ? flagOf(code) : '🌐', style: const TextStyle(fontSize: 34)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(headline, style: context.text.titleLarge?.copyWith(fontSize: 20), maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      '${data['ip']} · ${code.isEmpty ? '未知地区' : code}',
                      style: context.text.bodySmall?.copyWith(color: pm.muted),
                    ),
                    if (type != null && type!.found) ...[
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          PmPill(label: type!.type, dense: true,
                              color: type!.datacenter ? pm.warn : pm.ok),
                          PmPill(label: type!.nativeLabel, dense: true,
                              color: type!.native == false ? pm.warn : pm.ok),
                          PmPill(label: '纯度 ${type!.purity}', dense: true),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              PmPill(label: data['builtin'] == true ? '内置库' : '本地库', dense: true),
            ],
          ),
          if (found) ...[
            const SizedBox(height: 14),
            Divider(height: 1, color: pm.inset),
            const SizedBox(height: 12),
            _kv(context, '归属地', regionText.isEmpty ? countryLabel(data) : regionText),
            if ((data['isp'] ?? '').toString().isNotEmpty) _kv(context, '运营商', data['isp'].toString()),
            _kv(context, 'IP 段', data['range']?.toString() ?? '—'),
          ],
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 70, child: Text(k, style: context.text.bodySmall?.copyWith(fontSize: 12.5, color: context.pm.muted))),
          Expanded(child: Text(v, style: context.text.bodyMedium?.copyWith(fontSize: 14.5, color: context.scheme.onSurface))),
        ],
      ),
    );
  }
}

class _ApiCard extends StatelessWidget {
  const _ApiCard({required this.data, this.local});

  final Map<String, dynamic> data;
  final Map<String, dynamic>? local;

  static const _labels = {
    'status': '状态', 'message': '消息', 'country': '国家', 'regionName': '地区',
    'region': '地区代码', 'city': '城市', 'isp': '运营商', 'org': '组织',
    'as': 'ASN', 'lat': '纬度', 'lon': '经度', 'timezone': '时区', 'query': '查询 IP',
    'countryCode': '国家代码', 'zip': '邮编',
  };

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    final code = (local?['country_code'] ?? '').toString();
    final failed = data['status'] == 'fail';
    return PmCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(code.isEmpty ? '🛰️' : flagOf(code), style: const TextStyle(fontSize: 26)),
              const SizedBox(width: 10),
              Expanded(child: Text('IP API 详情', style: context.text.titleMedium)),
              PmPill(label: failed ? '失败' : '在线', dense: true, color: failed ? pm.warn : scheme.primary),
            ],
          ),
          const SizedBox(height: 12),
          if (failed)
            Text(data['message']?.toString() ?? '接口未返回结果', style: context.text.bodySmall?.copyWith(color: pm.warn))
          else
            for (final e in data.entries)
              if (e.value is! Map && e.value is! List && e.value != null && e.value.toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 82, child: Text(_labels[e.key] ?? e.key, style: context.text.bodySmall?.copyWith(fontSize: 12.5, color: pm.muted))),
                      Expanded(child: Text(e.value.toString(), style: context.text.bodyMedium?.copyWith(fontSize: 14.5, color: context.scheme.onSurface), maxLines: 3, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
        ],
      ),
    );
  }
}
