import 'dart:async';
import 'dart:ui' show FontFeature;

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

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    final active = NativeInfo.interfaces
        .where((e) => e['loopback'] != 'true')
        .toList();

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(kPagePadding, 8, kPagePadding, 30),
            children: [
              PmPageHeader(
                title: '局域网信息',
                subtitle: 'Wi-Fi / 蜂窝 / 以太网 · 地址 · 网关 · DNS · 网卡',
                showBack: true,
                actions: [
                  PmIconAction(
                    icon: Icons.refresh_rounded,
                    onTap: _refreshing ? null : _refresh,
                  ),
                ],
              ),
              PmCard(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        PmIconBadge(
                          NativeInfo.networkType == 'Wi-Fi'
                              ? Icons.wifi_rounded
                              : NativeInfo.networkType == '蜂窝网络'
                                  ? Icons.cell_tower_rounded
                                  : Icons.lan_rounded,
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
                    const SizedBox(height: 16),
                    _ipLine(context, 'IPv4', NativeInfo.localIp, mono: true, onCopy: _copy),
                    const SizedBox(height: 10),
                    _ipLine(context, 'IPv6', NativeInfo.ipv6.isEmpty ? '未分配' : NativeInfo.ipv6, mono: true, onCopy: _copy),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              PmSectionTitle('网络参数'),
              PmCard(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Column(
                  children: [
                    _kvRow(context, '子网掩码', NativeInfo.netmask.isEmpty ? '—' : NativeInfo.netmask, mono: true),
                    _kvRow(context, '前缀长度', NativeInfo.ipPrefix > 0 ? '/${NativeInfo.ipPrefix}' : '—'),
                    _kvRow(context, '默认网关', NativeInfo.gateway.isEmpty ? '—' : NativeInfo.gateway, mono: true, onCopy: _copy),
                    _kvRow(context, 'MAC 地址', NativeInfo.macAddress.isEmpty ? '—' : NativeInfo.macAddress, mono: true),
                    _kvRow(context, 'MTU', NativeInfo.mtu > 0 ? '${NativeInfo.mtu} bytes' : '—'),
                    _kvRow(
                      context,
                      '链路速率',
                      NativeInfo.linkDownKbps > 0
                          ? '↓ ${(NativeInfo.linkDownKbps / 1000).toStringAsFixed(1)} Mbps · ↑ ${(NativeInfo.linkUpKbps / 1000).toStringAsFixed(1)} Mbps'
                          : '系统未提供',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              PmSectionTitle('DNS 服务器'),
              PmCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                child: Column(
                  children: [
                    if (NativeInfo.systemDns.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text('未获取到系统 DNS', style: context.text.bodySmall?.copyWith(color: pm.muted)),
                      )
                    else
                      for (final dns in NativeInfo.systemDns)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 9),
                          child: Row(
                            children: [
                              Icon(Icons.dns_rounded, size: 16, color: scheme.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  dns,
                                  style: context.text.bodySmall?.copyWith(
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
                              PmPressable(
                                onTap: () => _copy(dns),
                                child: Icon(Icons.copy_rounded, size: 16, color: pm.muted),
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              PmSectionTitle('本机网卡（${active.length}）', subtitle: '已过滤回环与虚拟接口'),
              PmCard(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                child: Column(
                  children: [
                    for (final it in active)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            PmIconBadge(
                              it['name']?.toString().startsWith('wlan') == true
                                  ? Icons.wifi_rounded
                                  : Icons.settings_ethernet_rounded,
                              size: 30,
                              radius: 9,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(it['name']?.toString() ?? '—', style: context.text.bodyMedium),
                                  const SizedBox(height: 2),
                                  Text(
                                    it['ip']?.toString() ?? '—',
                                    style: context.text.bodySmall?.copyWith(
                                      color: pm.muted,
                                      fontFeatures: const [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PmPressable(
                              onTap: () => _copy(it['ip']?.toString() ?? ''),
                              child: Icon(Icons.copy_rounded, size: 16, color: pm.muted),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              PmCard(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, size: 16, color: pm.muted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '数据由 Android 系统网络栈提供，仅显示本机已连接的接口；不发起外部扫描或探测。',
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
