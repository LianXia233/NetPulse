import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';

import 'bridge.dart';
import 'store.dart';
import 'theme.dart';
import 'widgets.dart';

const cnCountryNames = <String, String>{
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
  return c.runes.map((r) => String.fromCharCode(0x1F1E6 + (r - 65))).join();
}

class IpGeoInfo {
  IpGeoInfo({
    required this.ip,
    required this.found,
    this.countryCode = '',
    this.country = '',
    this.region = '',
    this.city = '',
    this.isp = '',
    this.range = '',
    this.detailed = false,
    this.asn = '',
    this.org = '',
    this.timezone = '',
    this.lat = '',
    this.lon = '',
    this.source = '本地库',
  });

  final String ip;
  final bool found;
  final String countryCode;
  final String country;
  final String region;
  final String city;
  final String isp;
  final String range;
  final bool detailed;
  final String asn;
  final String org;
  final String timezone;
  final String lat;
  final String lon;
  final String source;

  String get label {
    if (!found) return '';
    final cn = cnCountryNames[countryCode.toUpperCase()];
    final base = cn ?? (country.isEmpty ? countryCode : country);
    final parts = <String>[];
    for (final e in [base, region, city]) {
      final t = e.trim();
      if (t.isEmpty || parts.contains(t)) continue;
      parts.add(t);
    }
    return parts.join(' · ');
  }

  static IpGeoInfo fromJson(Map<String, dynamic> j) => IpGeoInfo(
        ip: j['ip']?.toString() ?? '',
        found: j['found'] == true || j['status'] == 'success',
        countryCode: j['country_code']?.toString() ?? j['countryCode']?.toString() ?? '',
        country: j['country']?.toString() ?? '',
        region: j['region']?.toString() ?? j['regionName']?.toString() ?? '',
        city: j['city']?.toString() ?? '',
        isp: j['isp']?.toString() ?? '',
        range: j['range']?.toString() ?? '',
        asn: j['as']?.toString() ?? '',
        org: j['org']?.toString() ?? '',
        timezone: j['timezone']?.toString() ?? '',
        lat: j['lat']?.toString() ?? '',
        lon: j['lon']?.toString() ?? '',
      );

  IpGeoInfo enriched(Map<String, dynamic> api) {
    if (api['status'] != 'success') return this;
    return IpGeoInfo(
      ip: ip,
      found: true,
      countryCode: api['countryCode']?.toString() ?? countryCode,
      country: api['country']?.toString() ?? country,
      region: api['regionName']?.toString() ?? region,
      city: api['city']?.toString() ?? city,
      isp: api['isp']?.toString().isNotEmpty == true ? api['isp'].toString() : isp,
      range: range,
      detailed: true,
      asn: api['as']?.toString() ?? asn,
      org: api['org']?.toString() ?? org,
      timezone: api['timezone']?.toString() ?? timezone,
      lat: api['lat']?.toString() ?? lat,
      lon: api['lon']?.toString() ?? lon,
      source: 'IP API',
    );
  }

  Map<String, String> get detailMap => {
        '国家/地区': label,
        '运营商': isp,
        'ASN / 组织': [asn, org].where((e) => e.isNotEmpty && e != isp).join(' · '),
        '时区': timezone,
        '坐标': (lat.isEmpty || lon.isEmpty) ? '' : '$lat, $lon',
        'IP 段': range,
        '数据源': source,
      };
}

class _GeoNotifier extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// 批量、去重、合并请求：先用内置库给出国家，再用批量 IP API 补全省/市。
class IpGeoService {
  static final Map<String, IpGeoInfo> _cache = {};
  static final Map<String, Completer<IpGeoInfo?>> _waiting = {};
  static final Set<String> _apiAsked = {};
  static final _GeoNotifier _notifier = _GeoNotifier();
  static Timer? _timer;
  static bool _apiRunning = false;

  static Listenable get changes => _notifier;
  static String get _path => '${NativeInfo.filesDir}/ipdb.tsv';

  static IpGeoInfo? cached(String ip) => _cache[ip];

  static Future<IpGeoInfo?> lookup(String ip) {
    final hit = _cache[ip];
    if (hit != null) {
      if (!hit.detailed && !_apiAsked.contains(ip)) _enrich([ip]);
      return Future.value(hit);
    }
    final c = _waiting.putIfAbsent(ip, () => Completer<IpGeoInfo?>());
    _scheduleFlush();
    return c.future;
  }

  static void _scheduleFlush() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 70), _flush);
  }

  static Future<Map<String, dynamic>> _callCore(Map<String, dynamic> args) async {
    final r = await Isolate.run(() {
      Core.i.init();
      return Core.i.call('ipdb_lookup_many', args);
    });
    return (r['data'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  static Future<Map<String, dynamic>> _batchApi(List<String> ips) async {
    final r = await Isolate.run(() {
      Core.i.init();
      return Core.i.call('ip_geo_auto_batch', {'ips': ips});
    });
    return (r['data'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  static Future<void> _flush() async {
    final ips = _waiting.keys.toList();
    if (ips.isEmpty) return;
    // 1) 在线优先：预制多源 API 逐个回退。
    try {
      final api = await _batchApi(ips);
      for (final it in (api['items'] as List? ?? const [])) {
        if (it is! Map) continue;
        final m = it.cast<String, dynamic>();
        final ip = m['query']?.toString() ?? '';
        if (ip.isEmpty) continue;
        if (m['status'] != 'success') continue;
        final base = _cache[ip];
        _cache[ip] = base == null
            ? IpGeoInfo.fromJson(m).enriched(m)
            : base.enriched(m);
      }
      _notifier.ping();
    } catch (_) {}
    // 2) 离线兜底：在线失败或字段缺失时，仍用内置库补国家/地区。
    try {
      final local = await _callCore({'ips': ips, 'path': _path});
      for (final it in (local['items'] as List? ?? const [])) {
        if (it is! Map) continue;
        final info = IpGeoInfo.fromJson(it.cast<String, dynamic>());
        if (_cache[info.ip] == null) _cache[info.ip] = info;
      }
    } catch (_) {}
    for (final ip in ips) {
      final c = _waiting.remove(ip);
      c?.complete(_cache[ip]);
    }
    _notifier.ping();
    await _enrich(ips);
  }

  /// 用批量 IP API 补全省/市/运营商；失败时保留本地结果。
  static Future<void> _enrich(List<String> ips) async {
    if (_apiRunning) return;
    final need = ips.where((ip) {
      final c = _cache[ip];
      return c != null && !c.detailed && !_apiAsked.contains(ip);
    }).toList();
    if (need.isEmpty) return;
    _apiRunning = true;
    try {
      for (var i = 0; i < need.length; i += 100) {
        final chunk = need.sublist(i, (i + 100).clamp(0, need.length));
        for (final ip in chunk) {
          _apiAsked.add(ip);
        }
        try {
          final r = await _batchApi(chunk);
          for (final it in (r['items'] as List? ?? const [])) {
            if (it is! Map) continue;
            final m = it.cast<String, dynamic>();
            final ip = m['query']?.toString() ?? '';
            if (ip.isEmpty || m['status'] != 'success') continue;
            final base = _cache[ip];
            _cache[ip] = base == null
                ? IpGeoInfo.fromJson(m).enriched(m)
                : base.enriched(m);
          }
          _notifier.ping();
        } catch (_) {}
      }
    } finally {
      _apiRunning = false;
    }
  }

  /// 预热一批 IP，避免逐条触发加载。
  static Future<void> preload(Iterable<String> ips) async {
    for (final ip in ips) {
      if (!_cache.containsKey(ip)) lookup(ip);
    }
  }
}


/// IP 类型 / 原生状态（来源：ASN type、privacy、anycast、注册国对比）。
class IpTypeInfo {
  const IpTypeInfo({
    required this.found,
    this.type = '未知类型',
    this.datacenter = false,
    this.native,
    this.nativeLabel = '原生状态未知',
    this.purity = 0,
    this.anycast = false,
    this.mobile = false,
    this.risk = const [],
    this.org = '',
    this.asnName = '',
  });

  final bool found;
  final String type;
  final bool datacenter;
  final bool? native;
  final String nativeLabel;
  final int purity;
  final bool anycast;
  final bool mobile;
  final List<String> risk;
  final String org;
  final String asnName;

  static IpTypeInfo fromJson(Map<String, dynamic> j) {
    final p = (j['privacy'] as Map?) ?? const {};
    final risk = <String>[
      if (p['hosting'] == true) '机房',
      if (p['vpn'] == true) 'VPN',
      if (p['proxy'] == true) '代理',
      if (p['tor'] == true) 'Tor',
      if (p['relay'] == true) '中继',
    ];
    return IpTypeInfo(
      found: j['found'] == true,
      type: j['type']?.toString() ?? '未知类型',
      datacenter: j['datacenter'] == true,
      native: j['native'] is bool ? j['native'] as bool : null,
      nativeLabel: j['native_label']?.toString() ?? '原生状态未知',
      purity: (j['purity'] as num?)?.toInt() ?? 0,
      anycast: j['anycast'] == true,
      mobile: j['mobile'] == true,
      risk: risk,
      org: j['org']?.toString() ?? '',
      asnName: j['asn_name']?.toString() ?? '',
    );
  }
}

class IpTypeService {
  static final Map<String, IpTypeInfo> _cache = {};
  static final Map<String, Future<IpTypeInfo?>> _inflight = {};

  static IpTypeInfo? cached(String ip) => _cache[ip];

  static Future<IpTypeInfo?> lookup(String ip) {
    final hit = _cache[ip];
    if (hit != null) return Future.value(hit);
    return _inflight.putIfAbsent(ip, () async {
      try {
        final r = await Isolate.run(() {
          Core.i.init();
          return Core.i.call('ip_type', {'ip': ip});
        }).timeout(const Duration(seconds: 8));
        if (r['ok'] == true) {
          final d = (r['data'] as Map?)?.cast<String, dynamic>() ?? const {};
          final info = IpTypeInfo.fromJson(d);
          _cache[ip] = info;
          return info;
        }
      } catch (_) {}
      return null;
    }).whenComplete(() => _inflight.remove(ip));
  }
}

class IpGeoInline extends StatelessWidget {
  const IpGeoInline({super.key, required this.ip, this.showIp = false, this.fontSize = 12});

  final String ip;
  final bool showIp;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    if (ip.isEmpty || ip == '*') return const SizedBox.shrink();
    IpGeoService.lookup(ip);
    return ListenableBuilder(
      listenable: IpGeoService.changes,
      builder: (context, _) {
        final info = IpGeoService.cached(ip);
        final geo = info == null
            ? '🌐 查询归属中…'
            : info.found
                ? '${flagOf(info.countryCode)} ${info.label}'
                : '🌐 未知';
        return InkWell(
          onTap: () => showIpDetailSheet(context, ip),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              showIp ? '$ip  $geo' : geo,
              style: context.text.bodySmall?.copyWith(
                fontSize: fontSize,
                color: info?.detailed == true ? context.scheme.onSurface.withValues(alpha: 0.82) : pm.muted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
  }
}

Future<Map<String, dynamic>?> _apiDetail(String ip, String endpoint) async {
  try {
    final r = await Isolate.run(() {
      Core.i.init();
      return Core.i.call('ip_api', {'ip': ip, 'endpoint': endpoint});
    });
    if (r['ok'] == true) {
      final data = (r['data'] as Map?)?.cast<String, dynamic>();
      if (data != null && data['status'] == 'success') return data;
    }
    // 自定义源失败时，回退到内置的在线多源（仍失败则由离线库展示）。
    final fallback = await Core.callAsync('ip_geo_auto', {'ip': ip});
    if (fallback['ok'] == true) {
      return (fallback['data'] as Map?)?.cast<String, dynamic>();
    }
    return null;
  } catch (_) {
    return null;
  }
}

Future<void> showIpDetailSheet(BuildContext context, String ip) {
  final store = AppScope.of(context);
  final endpoint = store.ipApiEndpoint;
  final cached = IpGeoService.cached(ip);
  IpGeoService.lookup(ip);
  return showPmSheet(
    context,
    title: 'IP 归属详情',
    body: FutureBuilder<List<dynamic>>(
      future: Future.wait([
        _apiDetail(ip, endpoint),
        IpTypeService.lookup(ip),
      ]).timeout(const Duration(seconds: 8), onTimeout: () => <dynamic>[null, null]),
      builder: (context, snap) {
        final pm = context.pm;
        final api = snap.data?[0] as Map<String, dynamic>?;
        final type = snap.data?[1] as IpTypeInfo?;
        final base = cached ?? IpGeoService.cached(ip);
        final info = api != null
            ? (base?.enriched(api) ?? IpGeoInfo.fromJson(api).enriched(api))
            : base;
        final waiting = snap.connectionState != ConnectionState.done;
        if (info == null && waiting) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(18, 28, 18, 40),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final rows = <MapEntry<String, String>>[];
        if (type != null && type.found) {
          rows.add(MapEntry('IP 类型', type.type));
          rows.add(MapEntry('原生 IP', type.nativeLabel));
          rows.add(MapEntry('纯净度', '${type.purity} / 100'));
          if (type.risk.isNotEmpty) rows.add(MapEntry('风险标记', type.risk.join(' · ')));
        }
        rows.addAll((info?.detailMap ?? const <String, String>{}).entries
            .where((e) => e.value.trim().isNotEmpty));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              decoration: BoxDecoration(
                color: pm.block,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  Text(info?.found == true ? flagOf(info!.countryCode) : '🌐', style: const TextStyle(fontSize: 34)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ip, style: context.text.titleMedium?.copyWith(fontSize: 18, fontFeatures: const [FontFeature.tabularFigures()])),
                        const SizedBox(height: 4),
                        Text(
                          info?.label.isNotEmpty == true ? info!.label : '正在查询归属地…',
                          style: context.text.bodyMedium?.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: context.scheme.onSurface,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            for (final e in rows) _detailRow(context, e.key, e.value),
            if (waiting)
              Row(
                children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text('正在补全省/市精度…', style: context.text.bodySmall?.copyWith(fontSize: 12.5, color: pm.muted)),
                ],
              )
            else if (api == null)
              Text('IP API 无响应，当前显示本地库结果', style: context.text.bodySmall?.copyWith(fontSize: 12.5, color: pm.warn)),
            const SizedBox(height: 8),
          ],
        );
      },
    ),
  );
}

Widget _detailRow(BuildContext context, String k, String v) {
  final pm = context.pm;
  return Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            k,
            style: context.text.bodySmall?.copyWith(fontSize: 13, color: pm.muted, height: 1.35),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: context.text.bodyMedium?.copyWith(
              fontSize: 14.5,
              height: 1.4,
              color: context.scheme.onSurface,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    ),
  );
}

