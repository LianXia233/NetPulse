import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'bridge.dart';
import 'ip_geo_widgets.dart';

class EgressFamily {
  EgressFamily({
    required this.family,
    required this.ip,
    this.local,
    this.api,
    this.purity,
    this.apiError = '',
    this.type,
    this.scope = '当前出口',
    this.source = '',
  });

  final String family; // v4 / v6
  final String ip;
  final IpGeoInfo? local;
  final Map<String, dynamic>? api;
  final int? purity;
  final String apiError;
  final IpTypeInfo? type;
  final String scope;
  final String source;

  String get countryCode =>
      api?['countryCode']?.toString() ?? local?.countryCode ?? '';

  String get geo {
    final raw = [api?['country'], api?['regionName'], api?['city']]
        .map((e) => e?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
    if (raw.isNotEmpty) return raw.join(' · ');
    return local?.label ?? '';
  }

  String get isp {
    for (final raw in [api?['isp'], api?['org'], type?.org, type?.asnName, local?.isp]) {
      final v = raw?.toString().trim() ?? '';
      if (v.isNotEmpty && v != '0' && v != '-' && v.toLowerCase() != 'null') return v;
    }
    return '';
  }

  int get score => type?.purity ?? (purity ?? 0);

  String get typeLabel => type?.type ?? '';

  String get nativeLabel => type?.nativeLabel ?? '';
}

/// 当前出口 IP 探测：多接口 + 系统 DNS + 归属地/纯净度。
class EgressService extends ChangeNotifier {
  EgressService._();

  static final EgressService shared = EgressService._();

  bool busy = false;
  bool loaded = false;
  String? error;
  DateTime? updatedAt;
  final Map<String, EgressFamily> families = {};
  final Map<String, EgressFamily> probes = {};
  final List<String> notes = [];

  Future<void>? _inflight;

  Future<void> refresh({String endpoint = ''}) {
    final running = _inflight;
    if (running != null) return running;
    final f = _refresh(endpoint).whenComplete(() => _inflight = null);
    _inflight = f;
    return f;
  }

  Future<void> _refresh(String endpoint) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final r = await Isolate.run(() {
        Core.i.init();
        return Core.i.call('ipdb_egress', const {});
      });
      if (r['ok'] != true) throw (r['error']?.toString() ?? '出口探测失败');
      final d = (r['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final errs = (d['errors'] as List? ?? const []).map((e) => e.toString()).toList();
      final out = <String, EgressFamily>{};
      final probeOut = <String, EgressFamily>{};
      final jobs = <String, Future<EgressFamily>>{};
      final probeData = (d['probes'] as Map?)?.cast<String, dynamic>() ?? const {};
      // IPv4 国内 / 外部两组探测分开显示；IPv6 仍保留当前出口。
      for (final spec in const [
        (key: 'v4_cn', family: 'v4', scope: '国内探测', probe: 'ipv4_cn'),
        (key: 'v4_intl', family: 'v4', scope: '外部探测', probe: 'ipv4_intl'),
        (key: 'v6_intl', family: 'v6', scope: '外部探测', probe: 'ipv6_intl'),
      ]) {
        final p = (probeData[spec.probe] as Map?)?.cast<String, dynamic>();
        final ip = p?['ip']?.toString() ?? '';
        if (ip.isEmpty) continue;
        jobs[spec.key] = _loadFamily(
          spec.family,
          ip,
          endpoint,
          scope: spec.scope,
          source: p?['source']?.toString() ?? '',
        );
      }
      // 兼容旧 core：没有 probes 时退回 ipv4 / ipv6 两个主字段。
      if (jobs.isEmpty) {
        for (final family in ['ipv4', 'ipv6']) {
          final ip = d[family]?.toString() ?? '';
          if (ip.isEmpty) continue;
          jobs[family == 'ipv4' ? 'v4' : 'v6'] = _loadFamily(
            family == 'ipv4' ? 'v4' : 'v6',
            ip,
            endpoint,
          );
        }
      }
      final keys = jobs.keys.toList();
      final results = await Future.wait(jobs.values);
      for (var i = 0; i < results.length; i++) {
        final key = keys[i];
        if (key == 'v4' || key == 'v6') {
          out[key] = results[i];
        } else {
          probeOut[key] = results[i];
        }
      }
      families
        ..clear()
        ..addAll(out);
      probes
        ..clear()
        ..addAll(probeOut);
      notes
        ..clear()
        ..addAll(errs.take(4));
      loaded = true;
      updatedAt = DateTime.now();
      if (out.isEmpty && probeOut.isEmpty) {
        error = errs.isEmpty ? '未取到当前出口 IP' : errs.first;
      }
    } catch (e) {
      error = '$e';
      loaded = true;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<EgressFamily> _loadFamily(
    String family,
    String ip,
    String endpoint, {
    String scope = '当前出口',
    String source = '',
  }) async {
    IpGeoInfo? local;
    try {
      local = await IpGeoService.lookup(ip).timeout(const Duration(seconds: 3));
    } catch (_) {}
    Map<String, dynamic>? api;
    IpTypeInfo? type;
    var apiError = '';
    await Future.wait([
      () async {
        try {
          final r = await Isolate.run(() {
            Core.i.init();
            return Core.i.call('ip_api', {'ip': ip, 'endpoint': endpoint});
          }).timeout(const Duration(seconds: 7));
          if (r['ok'] == true) {
            api = (r['data'] as Map?)?.cast<String, dynamic>();
          } else {
            apiError = r['error']?.toString() ?? 'API 无响应';
          }
        } catch (e) {
          apiError = '$e';
        }
      }(),
      () async {
        try {
          type = await IpTypeService.lookup(ip);
        } catch (_) {}
      }(),
    ]);
    final purity = type?.purity ?? (api == null ? _purityFromIsp(local?.isp ?? '') : purityScore(api));
    return EgressFamily(
      family: family,
      ip: ip,
      local: local,
      api: api,
      purity: purity,
      apiError: apiError,
      type: type,
      scope: scope,
      source: source,
    );
  }

  static int? _purityFromIsp(String isp) {
    if (isp.trim().isEmpty) return null;
    return purityScore({'isp': isp, 'org': '', 'as': ''});
  }

  static int purityScore(Map<String, dynamic>? api) {
    if (api == null || api['status'] == 'fail') return 0;
    final text = '${api['isp'] ?? ''} ${api['org'] ?? ''} ${api['as'] ?? ''}'.toLowerCase();
    const hosting = ['amazon', 'aws', 'google cloud', 'azure', 'aliyun', 'tencent cloud', 'cloud', 'hosting', 'datacenter', 'data center', 'vps', 'server', 'digitalocean', 'linode', 'vultr', 'ovh', 'hetzner', 'oracle cloud', 'colocation', 'idc'];
    const proxy = ['vpn', 'proxy', 'tor ', 'shadowsocks', 'socks'];
    var score = 92;
    if (hosting.any(text.contains)) score -= 42;
    if (proxy.any(text.contains)) score -= 32;
    if ((api['isp']?.toString() ?? '').isEmpty) score -= 8;
    if ((api['org']?.toString() ?? '').isEmpty) score -= 4;
    return score.clamp(0, 100);
  }
}
