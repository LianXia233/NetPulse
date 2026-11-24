import 'package:flutter/material.dart';

import 'bridge.dart';
import 'egress_service.dart';
import 'ip_geo_widgets.dart';
import 'theme.dart';
import 'widgets.dart';

/// 首页出口卡片：IPv4 / IPv6、归属省市、运营商、纯净度。
class EgressOverviewCard extends StatelessWidget {
  const EgressOverviewCard({super.key, required this.service, this.onRefresh});

  final EgressService service;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final v4 = service.families['v4'];
        final v6 = service.families['v6'];
        final v4cn = service.probes['v4_cn'];
        final v4intl = service.probes['v4_intl'];
        final v6intl = service.probes['v6_intl'] ?? v6;
        final hasProbes = service.probes.isNotEmpty;
        final empty = v4 == null && v6 == null && !hasProbes;
        return PmCard(
          padding: const EdgeInsets.fromLTRB(18, 15, 18, 16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(scheme.primary.withValues(alpha: context.isDark ? 0.15 : 0.08), pm.card),
              pm.card,
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  PmIconBadge(Icons.public_rounded, color: scheme.primary, size: 38, radius: 12),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('当前出口 IP', style: context.text.titleMedium),
                        const SizedBox(height: 2),
                        Text(
                          '${NativeInfo.networkType} · ${NativeInfo.localIp.isEmpty ? '本机地址获取中' : NativeInfo.localIp}',
                          style: context.text.bodySmall?.copyWith(fontSize: 11.5, color: pm.muted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (service.busy)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  IconButton(
                    onPressed: service.busy ? null : onRefresh,
                    tooltip: '重新探测',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.refresh_rounded, size: 21, color: service.busy ? pm.muted : scheme.primary),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (hasProbes) ...[
                _probeGroup(context, 'IPv4', v4cn, v4intl),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Divider(height: 1, color: pm.inset),
                ),
                if (v6intl != null)
                  _familyRow(context, v6intl, label: 'IPv6 · 外部探测')
                else if (service.loaded)
                  _missingRow(context, 'IPv6 · 外部探测', '当前网络未分配 IPv6，或运营商未开启'),
              ] else if (v4 != null || v6 != null) ...[
                if (v4 != null)
                  _familyRow(context, v4, label: 'IPv4 · 当前出口')
                else if (service.loaded)
                  _missingRow(context, 'IPv4 · 当前出口', '当前网络未获取到 IPv4 出口'),
                if (v4 != null && v6 != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Divider(height: 1, color: pm.inset),
                  ),
                if (v6 != null)
                  _familyRow(context, v6, label: 'IPv6 · 当前出口')
                else if (service.loaded)
                  _missingRow(context, 'IPv6 · 当前出口', '当前网络未分配 IPv6，或运营商未开启'),
              ] else if (service.busy || !service.loaded)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Row(
                    children: [
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 10),
                      Text('正在探测当前出口 IPv4 / IPv6…',
                          style: context.text.bodyMedium?.copyWith(color: pm.muted)),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                  decoration: BoxDecoration(color: pm.warnSoft, borderRadius: BorderRadius.circular(14)),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline_rounded, size: 18, color: pm.warn),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              service.error ?? '未获取到出口 IP',
                              style: context.text.bodyMedium?.copyWith(fontSize: 13, color: pm.warn),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '可点右上角刷新重试，或切换网络后再试',
                              style: context.text.bodySmall?.copyWith(fontSize: 11.5, color: pm.warn),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.verified_user_outlined, size: 14, color: pm.muted),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      empty
                          ? '多接口探测 · 系统 DNS · 归属地到省/市'
                          : '归属地精确到省/市 · 纯净度按 ISP / 机房特征评估',
                      style: context.text.bodySmall?.copyWith(fontSize: 11, color: pm.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (service.notes.isNotEmpty && empty)
                    Tooltip(
                      message: service.notes.join('\n'),
                      child: Icon(Icons.info_outline_rounded, size: 15, color: pm.muted),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _probeGroup(BuildContext context, String family, EgressFamily? cn, EgressFamily? intl) {
    final pm = context.pm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (cn != null)
          _familyRow(context, cn, label: '$family · 国内探测')
        else
          _missingRow(context, '$family · 国内探测', '国内探测接口未返回地址'),
        const SizedBox(height: 6),
        if (intl != null)
          _familyRow(context, intl, label: '$family · 外部探测')
        else
          _missingRow(context, '$family · 外部探测', '外部探测接口未返回地址'),
        if (cn != null && intl != null) ...[
          const SizedBox(height: 4),
          Text(
            cn.ip == intl.ip
                ? '国内与外部探测结果一致'
                : '国内与外部出口 IP 不同，可能存在分流、代理或智能路由',
            style: context.text.bodySmall?.copyWith(
              fontSize: 11,
              color: cn.ip == intl.ip ? pm.muted : pm.warn,
            ),
          ),
        ],
      ],
    );
  }

  Widget _missingRow(BuildContext context, String label, String hint) {
    final pm = context.pm;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          const Text('🌐', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 9),
          PmPill(label: label, dense: true),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hint,
              style: context.text.bodySmall?.copyWith(fontSize: 11.5, color: pm.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _familyRow(BuildContext context, EgressFamily f, {String? label}) {
    final pm = context.pm;
    final scheme = context.scheme;
    final score = f.score;
    final color = score >= 80 ? pm.ok : (score >= 55 ? scheme.primary : pm.warn);
    return InkWell(
      onTap: () => showIpDetailSheet(context, f.ip),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(f.countryCode.isNotEmpty ? flagOf(f.countryCode) : '🌐',
                style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      PmPill(label: label ?? f.family.toUpperCase(), dense: true),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          f.ip,
                          style: context.text.titleSmall?.copyWith(
                            fontSize: 15,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [f.geo, if (f.isp.isNotEmpty) f.isp, if (f.source.isNotEmpty) '来源 ${_hostOf(f.source)}']
                        .where((e) => e.isNotEmpty)
                        .join(' · '),
                    style: context.text.bodySmall?.copyWith(fontSize: 12.5, color: pm.muted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (f.typeLabel.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      [f.typeLabel, f.nativeLabel].where((e) => e.isNotEmpty).join(' · '),
                      style: context.text.bodySmall?.copyWith(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: f.type?.datacenter == true || f.type?.native == false ? pm.warn : pm.ok,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            PmPill(
              label: score > 0 ? '纯净度 $score' : '纯净度 —',
              color: score > 0 ? color : pm.muted,
              dense: true,
            ),
          ],
        ),
      ),
    );
  }

  static String _hostOf(String url) {
    final uri = Uri.tryParse(url);
    return uri?.host.isNotEmpty == true ? uri!.host : url;
  }
}
