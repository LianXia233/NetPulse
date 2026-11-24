import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge.dart';
import '../page_kit.dart';
import '../theme.dart';
import '../widgets.dart';

class LanInfoPage extends StatefulWidget {
  const LanInfoPage({super.key});

  @override
  State<LanInfoPage> createState() => _LanInfoPageState();
}

class _LanInfoPageState extends State<LanInfoPage> {
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    await NativeInfo.refreshNetwork();
    if (!mounted) return;
    setState(() => _refreshing = false);
  }

  void _copy(String text) {
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    pmToast(context, '已复制');
  }

  bool _isPrivate(String ip) {
    if (ip.contains(':')) {
      final lower = ip.toLowerCase();
      return lower.startsWith('fc') ||
          lower.startsWith('fd') ||
          lower.startsWith('fe8') ||
          lower.startsWith('fe9') ||
          lower.startsWith('fea') ||
          lower.startsWith('feb');
    }
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]) ?? -1;
    final b = int.tryParse(parts[1]) ?? -1;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 169 && b == 254);
  }

  String _speed(int kbps) {
    if (kbps <= 0) return '—';
    if (kbps >= 1000) return '${(kbps / 1000).toStringAsFixed(1)} Mbps';
    return '$kbps Kbps';
  }

  String _nicSpeed(int mbps) => mbps > 0 ? '$mbps Mbps' : '系统未提供';

  String _bandLabel(int mhz) {
    if (mhz <= 0) return '';
    if (mhz < 3000) return ' · 2.4 GHz';
    if (mhz < 5925) return ' · 5 GHz';
    return ' · 6 GHz';
  }

  List<int>? _ipv6Bytes(String raw) {
    final s = raw.split('%').first;
    final halves = s.split('::');
    if (halves.length > 2) return null;
    List<int> parse(String part) {
      if (part.isEmpty) return [];
      final out = <int>[];
      for (final h in part.split(':')) {
        final v = int.tryParse(h, radix: 16);
        if (v == null || v < 0 || v > 0xffff) return const [];
        out
          ..add(v >> 8)
          ..add(v & 0xff);
      }
      return out;
    }

    final head = parse(halves[0]);
    final tail = halves.length == 2 ? parse(halves[1]) : const <int>[];
    final missing = 16 - head.length - tail.length;
    if (missing < 0 || (halves.length == 1 && missing != 0)) return null;
    return [...head, ...List.filled(missing, 0), ...tail];
  }

  /// fe80::/64 的 EUI-64 链路本地地址里包含 MAC；Android 10+ 隐藏 MAC 时可用它推导。
  String? _macFromIpv6(String ip) {
    final b = _ipv6Bytes(ip);
    if (b == null || b.length != 16) return null;
    if (b[11] != 0xff || b[12] != 0xfe) return null;
    final mac = [b[8] ^ 0x02, b[9], b[10], b[13], b[14], b[15]];
    return mac
        .map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
  }

  String? _interfaceLinkLocal(Map<String, dynamic> iface) {
    final addresses = iface['addresses'];
    if (addresses is! List) return null;
    for (final a in addresses) {
      if (a is Map) {
        final ip = a['ip']?.toString() ?? '';
        if (ip.toLowerCase().startsWith('fe80')) return ip;
      }
    }
    return null;
  }

  String? _activeDerivedMac() {
    for (final it in NativeInfo.lanInterfaces) {
      if ((it['name']?.toString() ?? '') == NativeInfo.interfaceName) {
        final ll = _interfaceLinkLocal(it);
        if (ll != null) return _macFromIpv6(ll);
      }
    }
    return null;
  }

  IconData _transportIcon(String transport) {
    return switch (transport) {
      'Wi-Fi' => Icons.wifi_rounded,
      '蜂窝网络' => Icons.cell_tower_rounded,
      '以太网' => Icons.settings_ethernet_rounded,
      'VPN' => Icons.vpn_lock_rounded,
      _ => Icons.lan_rounded,
    };
  }

  IconData _nicIcon(String name, bool virtual) {
    if (virtual) return Icons.memory_rounded;
    if (name.startsWith('wlan')) return Icons.wifi_rounded;
    if (name.startsWith('rmnet') || name.startsWith('ccmni')) {
      return Icons.cell_tower_rounded;
    }
    if (name.startsWith('tun') || name.startsWith('ppp')) {
      return Icons.vpn_lock_rounded;
    }
    return Icons.settings_ethernet_rounded;
  }

  String _addressLine(Map<String, dynamic> addr) {
    final ip = addr['ip']?.toString() ?? '';
    final prefix = (addr['prefix'] as num?)?.toInt() ?? 0;
    return prefix > 0 ? '$ip/$prefix' : ip;
  }

  String _summary() {
    final b = StringBuffer()
      ..writeln('NetPulse 网络摘要')
      ..writeln('${NativeInfo.networkType} · ${NativeInfo.interfaceName}')
      ..writeln('IPv4: ${NativeInfo.localIp}${NativeInfo.ipPrefix > 0 ? '/${NativeInfo.ipPrefix}' : ''}')
      ..writeln('IPv6: ${NativeInfo.ipv6.isEmpty ? '未分配' : NativeInfo.ipv6}')
      ..writeln('网关: ${NativeInfo.gateway.isEmpty ? '—' : NativeInfo.gateway}')
      ..writeln('DNS: ${NativeInfo.systemDns.isEmpty ? '—' : NativeInfo.systemDns.join(', ')}')
      ..writeln('MAC: ${NativeInfo.macAddress.isEmpty ? '—' : NativeInfo.macAddress}')
      ..writeln('MTU: ${NativeInfo.mtu}');
    for (final net in NativeInfo.lanNetworks) {
      b.writeln('[${net['transport']}] ${net['interface']} ${_addressLine(((net['addresses'] as List?)?.firstOrNull as Map?)?.cast<String, dynamic>() ?? const {})}');
    }
    return b.toString().trim();
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    final active = NativeInfo.lanActive;
    final allNetworks = NativeInfo.lanNetworks;
    final internetNetworks = allNetworks.where((e) => e['internet'] == true).toList();
    final networks = [...(internetNetworks.isEmpty ? allNetworks : internetNetworks)]
      ..sort((a, b) {
        int rank(Map<String, dynamic> net) {
          if ((net['interface']?.toString() ?? '') == NativeInfo.interfaceName) return 0;
          return net['validated'] == true ? 1 : 2;
        }
        return rank(a).compareTo(rank(b));
      });
    final interfaces = NativeInfo.lanInterfaces
        .where((e) => e['loopback'] != true)
        .toList()
      ..sort((a, b) {
        final au = a['up'] == true ? 1 : 0;
        final bu = b['up'] == true ? 1 : 0;
        if (au != bu) return bu.compareTo(au);
        final av = a['virtual'] == true ? 1 : 0;
        final bv = b['virtual'] == true ? 1 : 0;
        if (av != bv) return av.compareTo(bv);
        return (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? '');
      });

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(kPagePadding, 8, kPagePadding, 110),
            children: [
              PmPageHeader(
                title: '局域网信息',
                subtitle: '活动网络 · 地址 · 网关 · DNS · 本机网卡',
                showBack: true,
                actions: [
                  PmIconAction(
                    icon: Icons.copy_rounded,
                    onTap: () => _copy(_summary()),
                  ),
                  PmIconAction(
                    icon: Icons.refresh_rounded,
                    onTap: _refreshing ? null : _refresh,
                  ),
                ],
              ),
              _activeCard(context, pm, scheme, active),
              const SizedBox(height: 14),
              PmSectionTitle('网络参数'),
              PmCard(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Column(
                  children: [
                    _kvRow(context, '子网掩码', NativeInfo.netmask.isEmpty ? '—' : NativeInfo.netmask, mono: true),
                    _kvRow(context, '前缀长度', NativeInfo.ipPrefix > 0 ? '/${NativeInfo.ipPrefix}' : '—'),
                    _kvRow(context, 'IPv4 网关', NativeInfo.gateway.isEmpty ? '—' : NativeInfo.gateway, mono: true, onCopy: _copy),
                    if (NativeInfo.gateway6.isNotEmpty)
                      _kvRow(context, 'IPv6 网关', NativeInfo.gateway6, mono: true, onCopy: _copy),
                    _kvRow(
                      context,
                      'MAC 地址',
                      NativeInfo.macAddress.isNotEmpty
                          ? NativeInfo.macAddress
                          : (_activeDerivedMac() != null
                              ? '${_activeDerivedMac()}（IPv6 推导）'
                              : (NativeInfo.macHidden ? '系统已隐藏（Android 10+）' : '系统未提供')),
                      mono: true,
                      onCopy: _activeDerivedMac() == null ? null : _copy,
                    ),
                    _kvRow(context, 'MTU', NativeInfo.mtu > 0 ? '${NativeInfo.mtu} bytes' : '—'),
                    _kvRow(
                      context,
                      '链路速率',
                      NativeInfo.linkDownKbps > 0
                          ? '${NativeInfo.linkSource == 'estimate' ? '≈ ' : ''}↓ ${_speed(NativeInfo.linkDownKbps)} · ↑ ${_speed(NativeInfo.linkUpKbps)}'
                          : '系统未提供',
                    ),
                    if (NativeInfo.linkSource == 'estimate' && NativeInfo.linkDownKbps > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 76, bottom: 4),
                        child: Text(
                          '系统只提供带宽估算值；Wi-Fi/以太网真实协商速率需要硬件或系统权限。',
                          style: context.text.bodySmall?.copyWith(
                            color: pm.muted,
                            fontSize: 10.5,
                          ),
                        ),
                      ),
                    if (NativeInfo.wifiStandard.isNotEmpty)
                      _kvRow(context, 'Wi-Fi 标准', NativeInfo.wifiStandard),
                    if (NativeInfo.wifiFrequency > 0)
                      _kvRow(
                        context,
                        'Wi-Fi 频段',
                        '${NativeInfo.wifiFrequency} MHz${_bandLabel(NativeInfo.wifiFrequency)}',
                      ),
                    if (NativeInfo.wifiRssi != 0)
                      _kvRow(context, 'Wi-Fi 信号', '${NativeInfo.wifiRssi} dBm'),
                    if (NativeInfo.wifiSsid.isNotEmpty)
                      _kvRow(context, 'Wi-Fi SSID', NativeInfo.wifiSsid),
                    _kvRow(context, '私有 DNS', NativeInfo.privateDns.isEmpty ? '未启用' : NativeInfo.privateDns),
                    _kvRow(
                      context,
                      '网络状态',
                      [
                        NativeInfo.validated ? '已验证联网' : '未验证',
                        NativeInfo.metered ? '计费网络' : '非计费',
                        if (NativeInfo.vpn) 'VPN',
                      ].join(' · '),
                    ),
                  ],
                ),
              ),
              if (networks.isNotEmpty) ...[
                const SizedBox(height: 14),
                PmSectionTitle('活动网络（${networks.length}）', subtitle: 'Android 已注册的网络与对应接口'),
                for (final net in networks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _networkCard(context, pm, scheme, net),
                  ),
              ],
              const SizedBox(height: 14),
              PmSectionTitle(
                '本机网卡（${interfaces.length}）',
                subtitle: '地址、前缀、MAC、MTU 与链路速率',
              ),
              if (interfaces.isEmpty)
                PmCard(
               
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    '未获取到网卡信息',
                    style: context.text.bodySmall?.copyWith(color: pm.muted),
                  ),
                )
              else
                for (final net in interfaces)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _interfaceCard(context, pm, scheme, net),
                  ),
              const SizedBox(height: 6),
              PmCard(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, size: 16, color: pm.muted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '数据来自 Android ConnectivityManager / NetworkInterface 与 Wi-Fi 链路信息；'
                        'Android 10+ 对普通应用隐藏 Wi-Fi MAC；若存在 EUI-64 链路本地 IPv6，会用其推导 MAC。部分 ROM 只提供带宽估算值。'
                        '仅显示本机接口，不发起外部扫描或探测。',
                        style: context.text.bodySmall?.copyWith(color: pm.muted, height: 1.45),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _activeCard(
    BuildContext context,
    dynamic pm,
    ColorScheme scheme,
    Map<String, dynamic> active,
  ) {
    final v4 = NativeInfo.localIp;
    final v6 = NativeInfo.ipv6;
    return PmCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PmIconBadge(
                _transportIcon(NativeInfo.networkType),
                size: 46,
                radius: 14,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      NativeInfo.networkType,
                      style: context.text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      NativeInfo.interfaceName.isEmpty ? '活动网卡 —' : NativeInfo.interfaceName,
                      style: context.text.bodySmall?.copyWith(color: pm.muted),
                    ),
                  ],
                ),
              ),
              PmPill(
                label: NativeInfo.localIp.isEmpty ? '未连接' : '在线',
                color: NativeInfo.localIp.isEmpty ? pm.warn : pm.ok,
                dense: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (NativeInfo.validated) PmPill(label: '已验证联网', color: pm.ok, dense: true),
              if (NativeInfo.metered) PmPill(label: '计费网络', color: pm.warn, dense: true),
              if (NativeInfo.vpn) PmPill(label: 'VPN', color: scheme.primary, dense: true),
              if (v4.isNotEmpty && _isPrivate(v4))
                PmPill(label: '内网 IPv4', color: scheme.primary, dense: true),
            ],
          ),
          const SizedBox(height: 14),
          _ipLine(
            context,
            'IPv4',
            v4.isEmpty ? '未分配' : '$v4${NativeInfo.ipPrefix > 0 ? '/${NativeInfo.ipPrefix}' : ''}',
            mono: true,
            onCopy: _copy,
          ),
          const SizedBox(height: 10),
          _ipLine(
            context,
            'IPv6',
            v6.isEmpty ? '未分配' : v6,
            mono: true,
            onCopy: _copy,
          ),
        ],
      ),
    );
  }

  Widget _networkCard(BuildContext context, dynamic pm, ColorScheme scheme, Map<String, dynamic> net) {
    final addresses = (net['addresses'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final dns = (net['dns'] as List? ?? const []).map((e) => e.toString()).toList();
    final transport = net['transport']?.toString() ?? '其他';
    return PmCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PmIconBadge(_transportIcon(transport), size: 34, radius: 10),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(transport, style: context.text.titleSmall),
                    Text(
                      net['interface']?.toString().isEmpty == true
                          ? '无接口名'
                          : net['interface']?.toString() ?? '',
                      style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if ((net['interface']?.toString() ?? '') == NativeInfo.interfaceName) ...[
                PmPill(label: '当前', color: scheme.primary, dense: true),
                const SizedBox(width: 5),
              ],
              if (net['validated'] == true) PmPill(label: '已验证', color: pm.ok, dense: true),
              if (net['metered'] == true) ...[
                const SizedBox(width: 5),
                PmPill(label: '计费', color: pm.warn, dense: true),
              ],
            ],
          ),
          const SizedBox(height: 8),
          for (final addr in addresses)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  PmPill(label: (addr['family']?.toString() ?? 'ip').toUpperCase(), dense: true),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      _addressLine(addr),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  PmPressable(
                    onTap: () => _copy(addr['ip']?.toString() ?? ''),
                    child: Icon(Icons.copy_rounded, size: 14, color: pm.muted),
                  ),
                ],
              ),
            ),
          if ((net['gateway']?.toString() ?? '').isNotEmpty)
            _miniRow(context, '网关', net['gateway'].toString(), onCopy: _copy),
          if ((net['gateway6']?.toString() ?? '').isNotEmpty &&
              net['gateway6']?.toString() != net['gateway']?.toString())
            _miniRow(context, 'IPv6 网关', net['gateway6'].toString(), onCopy: _copy),
          if (dns.isNotEmpty) _miniRow(context, 'DNS', dns.join(' · ')),
          if ((net['privateDns']?.toString() ?? '').isNotEmpty)
            _miniRow(context, '私有 DNS', net['privateDns'].toString()),
          if ((net['httpProxy']?.toString() ?? '').isNotEmpty)
            _miniRow(context, '代理', net['httpProxy'].toString()),
        ],
      ),
    );
  }

  Widget _interfaceCard(BuildContext context, dynamic pm, ColorScheme scheme, Map<String, dynamic> net) {
    final name = net['name']?.toString() ?? '—';
    final virtual = net['virtual'] == true;
    final up = net['up'] == true;
    final addresses = (net['addresses'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    return PmCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PmIconBadge(_nicIcon(name, virtual), size: 32, radius: 9),
              const SizedBox(width: 10),
              Expanded(child: Text(name, style: context.text.titleSmall)),
              PmPill(
                label: up ? 'UP' : 'DOWN',
                color: up ? pm.ok : pm.muted,
                dense: true,
              ),
              if (virtual) ...[
                const SizedBox(width: 5),
                PmPill(label: '虚拟', color: scheme.primary, dense: true),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              if ((net['mac']?.toString() ?? '').isNotEmpty)
                Text(
                  'MAC ${net['mac']}',
                  style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
                )
              else if (_macFromIpv6(_interfaceLinkLocal(net) ?? '') != null)
                Text(
                  'MAC ${_macFromIpv6(_interfaceLinkLocal(net) ?? '')}（IPv6 推导）',
                  style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
                )
              else if (net['macHidden'] == true)
                Text(
                  'MAC 系统已隐藏',
                  style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
                ),
              Text(
                'MTU ${net['mtu'] ?? '—'}',
                style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
              ),
              Text(
                '速率 ${
                    name == NativeInfo.interfaceName
                        ? _speed([NativeInfo.linkDownKbps, NativeInfo.linkUpKbps].reduce((a, b) => a > b ? a : b))
                        : _nicSpeed((net['speedMbps'] as num?)?.toInt() ?? 0)
                }',
                style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final addr in addresses)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _addressLine(addr),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  PmPressable(
                    onTap: () => _copy(addr['ip']?.toString() ?? ''),
                    child: Icon(Icons.copy_rounded, size: 14, color: pm.muted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _miniRow(BuildContext context, String label, String value, {void Function(String)? onCopy}) {
    final pm = context.pm;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          SizedBox(
            width: 54,
            child: Text(
              label,
              style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall?.copyWith(fontSize: 11.5),
            ),
          ),
          if (onCopy != null)
            PmPressable(
              onTap: () => onCopy(value),
              child: Icon(Icons.copy_rounded, size: 14, color: pm.muted),
            ),
        ],
      ),
    );
  }

  Widget _ipLine(BuildContext context, String label, String value, {bool mono = false, void Function(String)? onCopy}) {
    final pm = context.pm;
    return Row(
      children: [
        SizedBox(
          width: 58,
          child: Text(label, style: context.text.bodySmall?.copyWith(color: pm.muted)),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '—' : value,
            style: context.text.bodyMedium?.copyWith(
              fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (value.isNotEmpty && onCopy != null)
          PmPressable(
            onTap: () => onCopy(value),
            child: Icon(Icons.copy_rounded, size: 16, color: pm.muted),
          ),
      ],
    );
  }

  Widget _kvRow(BuildContext context, String label, String value, {bool mono = false, void Function(String)? onCopy}) {
    final pm = context.pm;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: context.text.bodySmall?.copyWith(color: pm.muted)),
          ),
          Expanded(
            child: Text(
              value,
              style: context.text.bodySmall?.copyWith(
                fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
              ),
            ),
          ),
          if (onCopy != null && value != '—')
            PmPressable(
              onTap: () => onCopy(value),
              child: Icon(Icons.copy_rounded, size: 15, color: pm.muted),
            ),
        ],
      ),
    );
  }
}
