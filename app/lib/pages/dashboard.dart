import 'package:flutter/material.dart';

import '../bridge.dart';
import '../egress_card.dart';
import '../egress_service.dart';
import '../page_kit.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';
import 'browser_page.dart';
import 'ip_geo_page.dart';
import 'lan_info_page.dart';
import 'tools_page.dart';
import '../nav_scope.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  @override
  void initState() {
    super.initState();
    NativeInfo.refreshNetwork().then((_) {
      if (mounted) setState(() {});
    });
    EgressService.shared.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    final scheme = context.scheme;

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: () => EgressService.shared.refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            PmPageHeader(
              title: 'NetPulse',
              subtitle: '当前出口 IP · 归属地 · 纯净度 · 多 CDN / 多 DNS 下载',
              actions: [
                PmIconAction(
                  icon: Icons.settings_rounded,
                  onTap: () => HomeNavScope.jump(context, 4),
                ),
                PmIconAction(
                  icon: store.themeMode == ThemeMode.dark
                      ? Icons.dark_mode_rounded
                      : store.themeMode == ThemeMode.light
                          ? Icons.light_mode_rounded
                          : Icons.brightness_auto_rounded,
                  onTap: () {
                    final next = store.themeMode == ThemeMode.system
                        ? ThemeMode.light
                        : store.themeMode == ThemeMode.light
                            ? ThemeMode.dark
                            : ThemeMode.system;
                    store.setThemeMode(next);
                  },
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
              child: Column(
                children: [
                  EgressOverviewCard(
                    service: EgressService.shared,
                    onRefresh: () => EgressService.shared.refresh(),
                  ),
                  const SizedBox(height: 12),
                  PmCard(
                    padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
                    child: Row(
                      children: [
                        Icon(Icons.speed_rounded, size: 18, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '纯净度低通常意味着机房 / 云主机 / 代理出口；住宅宽带纯净度更高。',
                            style: context.text.bodySmall?.copyWith(
                              fontSize: 11.5,
                              height: 1.4,
                              color: context.pm.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            PmSectionTitle('快捷工具', subtitle: '网络诊断与下载能力全部由 Rust core 执行'),
            const _ToolGrid(),
          ],
        ),
      ),
    );
  }
}

class _ToolGrid extends StatelessWidget {
  const _ToolGrid();

  static const _tools = [
    (tool: ToolKind.lan, icon: Icons.lan_rounded, label: '局域网信息', subtitle: '地址 · 网关 · 网卡', color: Color(0xFF00C7BE)),
    (tool: ToolKind.ipgeo, icon: Icons.flag_rounded, label: 'IP 归属地', subtitle: '归属地 · 纯净度', color: Color(0xFF30B0C7)),
    (tool: ToolKind.browser, icon: Icons.travel_explore_rounded, label: '内置浏览器', subtitle: '直链嗅探 · UA', color: Color(0xFF5AC8FA)),
    (tool: ToolKind.ping, icon: Icons.network_ping_rounded, label: 'Ping 延迟', subtitle: 'TCP 握手 RTT', color: Color(0xFF34C759)),
    (tool: ToolKind.dns, icon: Icons.dns_rounded, label: 'DNS 对照', subtitle: '多服务器解析', color: Color(0xFF007AFF)),
    (tool: ToolKind.nat, icon: Icons.router_rounded, label: 'NAT 类型', subtitle: 'STUN 检测', color: Color(0xFFFF8D28)),
    (tool: ToolKind.trace, icon: Icons.route_rounded, label: '路由追踪', subtitle: 'UDP 路径', color: Color(0xFFCB30E0)),
    (tool: ToolKind.iperf, icon: Icons.speed_rounded, label: 'iperf3 打流', subtitle: '内置吞吐测试', color: Color(0xFFFF2D55)),
    (tool: ToolKind.download, icon: Icons.download_rounded, label: '分段下载', subtitle: '多 CDN · 续传', color: Color(0xFF5E5CE6)),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cols = constraints.maxWidth >= 520 ? 4 : 3;
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _tools.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: cols == 3 ? 0.92 : 1.05,
            ),
            itemBuilder: (context, index) {
              final t = _tools[index];
              final subtitle = t.tool == ToolKind.lan && NativeInfo.localIp.isNotEmpty
                  ? '${NativeInfo.networkType} · ${NativeInfo.localIp}'
                  : t.subtitle;
              return PmCard(
                padding: const EdgeInsets.all(12),
                radius: 18,
                onTap: () {
                  if (t.tool == ToolKind.download) {
                    HomeNavScope.jump(context, 3);
                  } else if (t.tool == ToolKind.browser) {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const BrowserPage()),
                    );
                  } else if (t.tool == ToolKind.ipgeo) {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const IpGeoPage()),
                    );
                  } else if (t.tool == ToolKind.lan) {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LanInfoPage()),
                    );
                  } else {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => ToolDetailPage(tool: t.tool)),
                    );
                  }
                },
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    PmIconBadge(t.icon, color: t.color, size: 36, radius: 11),
                    const SizedBox(height: 7),
                    Text(
                      t.label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall?.copyWith(
                        fontSize: 9.5,
                        color: context.pm.muted,
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

}
