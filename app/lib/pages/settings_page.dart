import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../bridge.dart';
import '../speed_config.dart';
import '../nav_scope.dart';
import '../page_kit.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    final pm = context.pm;
    final scheme = context.scheme;
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 30),
        children: [
          const PmPageHeader(title: '设置', subtitle: '外观、默认参数与关于'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kPagePadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PmSectionTitle('外观'),
                PmCard(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('主题模式', style: context.text.bodyMedium),
                      const SizedBox(height: 10),
                      PmSegmented<int>(
                        items: const [
                          (value: 0, label: '跟随系统'),
                          (value: 1, label: '浅色'),
                          (value: 2, label: '深色'),
                        ],
                        value: store.themeMode.index,
                        onChanged: (v) => store.setThemeMode(ThemeMode.values[v]),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('纯黑背景', style: context.text.bodyMedium),
                                Text('深色模式使用 AMOLED 纯黑', style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11)),
                              ],
                            ),
                          ),
                          Switch(
                            value: store.pureBlack,
                            activeTrackColor: scheme.primary,
                            onChanged: store.setPureBlack,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('主题色', style: context.text.bodyMedium),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final c in kAccentPalette)
                            GestureDetector(
                              onTap: () => store.setSeed(c),
                              child: AnimatedContainer(
                                duration: kFast,
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: store.seed.toARGB32() == c.toARGB32()
                                      ? Border.all(color: pm.card, width: 3)
                                      : null,
                                  boxShadow: store.seed.toARGB32() == c.toARGB32()
                                      ? [BoxShadow(color: c.withValues(alpha: 0.45), blurRadius: 16, offset: const Offset(0, 4))]
                                      : null,
                                ),
                                child: store.seed.toARGB32() == c.toARGB32()
                                    ? const Icon(Icons.check_rounded, size: 20, color: Colors.white)
                                    : null,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                PmSectionTitle('测速默认值'),
                PmCard(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Column(
                    children: [
                      PmSliderRow(
                        label: '默认并发线程',
                        value: store.workers.toDouble(),
                        min: 1,
                        max: 32,
                        divisions: 31,
                        display: (v) => '${v.toStringAsFixed(0)} 线程',
                        onChanged: (v) => store.setWorkers(v.round()),
                      ),
                      PmSliderRow(
                        label: '默认测试时长',
                        value: store.durationSec.toDouble(),
                        min: 5,
                        max: 60,
                        divisions: 55,
                        display: (v) => '${v.toStringAsFixed(0)} 秒',
                        onChanged: (v) => store.setDuration(v.round()),
                      ),
                      PmSliderRow(
                        label: '采样间隔',
                        value: store.sampleMs.toDouble(),
                        min: 100,
                        max: 1000,
                        divisions: 18,
                        display: (v) => '${v.toStringAsFixed(0)} ms',
                        onChanged: (v) => store.setSampleMs(v.round()),
                      ),
                      const SizedBox(height: 4),
                      Text('速度单位', style: context.text.bodyMedium),
                      const SizedBox(height: 10),
                      PmSegmented<bool>(
                        items: const [
                          (value: true, label: 'Mbps'),
                          (value: false, label: 'MB/s'),
                        ],
                        value: store.useMbps,
                        onChanged: store.setUnit,
                      ),
                    ],
                  ),
                ),
                PmSectionTitle('网络与解析'),
                PmCard(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.dns_rounded,
                        title: 'DNS 服务器',
                        subtitle: '${store.dnsServers.length} 个 · ${store.dnsServers.join(' / ')}',
                        onTap: () => _editDns(context, store),
                      ),
                      Divider(height: 1, color: pm.inset),
                      _Row(
                        icon: Icons.public_rounded,
                        title: '测速地址（多 CDN）',
                        subtitle: '${store.speedEndpoints.length} 条 · 点按编辑',
                        onTap: () => _editEndpoints(context, store),
                      ),
                      Divider(height: 1, color: pm.inset),
                      _Row(
                        icon: Icons.upload_rounded,
                        title: '上传测速地址',
                        subtitle: '${store.uploadEndpoints.length} 条 · 点按编辑',
                        onTap: () => _editUpload(context, store),
                      ),
                      Divider(height: 1, color: pm.inset),
                      _Row(
                        icon: Icons.lan_rounded,
                        title: '本机网络',
                        subtitle: '${NativeInfo.networkType} · ${NativeInfo.localIp.isEmpty ? '未知' : NativeInfo.localIp}',
                        onTap: () {
                          NativeInfo.refreshNetwork();
                          pmToast(context, '已刷新');
                        },
                      ),
                      Divider(height: 1, color: pm.inset),
                      _Row(
                        icon: Icons.alt_route_rounded,
                        title: '测速出口与解析',
                        subtitle: _bindSummary(store.speedBind, store.speedIpMode, store.speedDnsMode),
                        onTap: () => _editBind(context, store, false),
                      ),
                    ],
                  ),
                ),
                PmSectionTitle('下载'),
                PmCard(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.folder_rounded,
                        title: '下载保存目录',
                        subtitle: store.downloadDirEffective,
                        onTap: () => _editDownloadDir(context, store),
                      ),
                      Divider(height: 1, color: pm.inset),
                      _Row(
                        icon: Icons.tune_rounded,
                        title: '默认下载参数',
                        subtitle: '${store.downloadConnections} 线程 · ${store.downloadBlockKb ~/ 1024} MB 分片 · 重试 ${store.downloadRetries}',
                        onTap: () => HomeNavScope.jump(context, 3),
                      ),
                      Divider(height: 1, color: pm.inset),
                      _Row(
                        icon: Icons.alt_route_rounded,
                        title: '下载出口与解析',
                        subtitle: _bindSummary(store.downloadBind, store.downloadIpMode, store.downloadDnsMode),
                        onTap: () => _editBind(context, store, true),
                      ),
                    ],
                  ),
                ),
                PmSectionTitle('数据'),
                PmCard(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.history_rounded,
                        title: '历史记录',
                        subtitle: '${store.history.length} 条 · 点按查看',
                        onTap: () => _showHistory(context, store),
                      ),
                      Divider(height: 1, color: pm.inset),
                      _Row(
                        icon: Icons.info_outline_rounded,
                        title: '版本信息',
                        subtitle: 'NetPulse $kAppVersion · Flutter ${_flutterVersion()} · ${Core.i.ready ? Core.i.version() : 'core 未加载'}',
                        onTap: () => _about(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '多 CDN / 多 DNS 测速、动态分段下载、内置浏览器与网络诊断。'
                  'iperf3 依 BSD-3-Clause 随包分发。',
                  textAlign: TextAlign.center,
                  style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _flutterVersion() => '3.50.1';

  void _editBind(BuildContext context, AppStore store, bool download) {
    final bind = TextEditingController(text: download ? store.downloadBind : store.speedBind);
    var ipMode = download ? store.downloadIpMode : store.speedIpMode;
    var dnsMode = download ? store.downloadDnsMode : store.speedDnsMode;
    showPmSheet(
      context,
      title: download ? '下载出口与解析' : '测速出口与解析',
      body: StatefulBuilder(
        builder: (context, setSheet) {
          final ifaces = NativeInfo.interfaces
              .where((e) => (e['ip'] ?? '').isNotEmpty && e['loopback'] != 'true')
              .toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '留空表示跟随系统默认网络。可填本机源 IP（推荐）或网卡名（如 wlan0 / rmnet0）；'
                '网卡名绑定通常需要 root，源 IP 绑定在双 Wi-Fi / 蜂窝并行时更稳。',
                style: context.text.bodySmall?.copyWith(color: context.pm.muted, height: 1.45),
              ),
              const SizedBox(height: 12),
              PmField(
                controller: bind,
                label: '源 IP / 网卡名',
                hint: '留空自动 · 192.168.1.5 · wlan0',
              ),
              if (ifaces.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('本机接口（点按填入源 IP）', style: context.text.bodySmall?.copyWith(color: context.pm.muted)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final i in ifaces)
                      ActionChip(
                        label: Text('${i['name']} · ${i['ip']}', style: const TextStyle(fontSize: 11)),
                        onPressed: () {
                          bind.text = i['ip'] ?? '';
                          setSheet(() {});
                        },
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Text('地址协议', style: context.text.bodyMedium),
              const SizedBox(height: 8),
              PmSegmented<String>(
                items: const [
                  (value: 'auto', label: '双栈自动'),
                  (value: 'v4', label: '仅 IPv4'),
                  (value: 'v6', label: '仅 IPv6'),
                ],
                value: ipMode,
                onChanged: (v) => setSheet(() => ipMode = v),
              ),
              const SizedBox(height: 14),
              Text('域名解析', style: context.text.bodyMedium),
              const SizedBox(height: 8),
              PmSegmented<String>(
                items: const [
                  (value: 'all', label: '全部 DNS 并发'),
                  (value: 'primary', label: '主 DNS 优先'),
                ],
                value: dnsMode,
                onChanged: (v) => setSheet(() => dnsMode = v),
              ),
              const SizedBox(height: 6),
              Text(
                '“全部并发”会把设置里的每台 DNS 都查询并合并结果；“主 DNS 优先”只取第一台可用结果，失败再切换。',
                style: context.text.bodySmall?.copyWith(color: context.pm.muted, height: 1.45),
              ),
              const SizedBox(height: 16),
              PmPrimaryButton(
                label: '保存',
                icon: Icons.check_rounded,
                onPressed: () {
                  if (download) {
                    store.setDownloadBind(bind.text);
                    store.setDownloadIpMode(ipMode);
                    store.setDownloadDnsMode(dnsMode);
                  } else {
                    store.setSpeedBind(bind.text);
                    store.setSpeedIpMode(ipMode);
                    store.setSpeedDnsMode(dnsMode);
                  }
                  Navigator.pop(context);
                  pmToast(context, '出口配置已保存');
                },
              ),
            ],
          );
        },
      ),
    );
  }

  void _editDownloadDir(BuildContext context, AppStore store) {
    final controller = TextEditingController(text: store.downloadDirEffective);
    showPmSheet(
      context,
      title: '下载保存目录',
      body: StatefulBuilder(
        builder: (context, setSheet) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PmField(controller: controller, label: '保存路径', hint: '/storage/emulated/0/Download', maxLines: 2),
            const SizedBox(height: 8),
            Text(
              '可直接调用系统文件管理器选择文件夹。Android 11+ 首次使用需授予“所有文件访问权限”，目录才会对 Rust 下载器可写。',
              style: context.text.bodySmall?.copyWith(color: context.pm.muted, height: 1.45),
            ),
            const SizedBox(height: 12),
            PmPrimaryButton(
              label: '从文件管理器选择',
              icon: Icons.folder_open_rounded,
              onPressed: () async {
                final path = await NativeInfo.selectDirectory();
                if (path == null || path.isEmpty) {
                  if (context.mounted) pmToast(context, '未选择目录，或需要先授予所有文件访问权限');
                  return;
                }
                controller.text = path;
                setSheet(() {});
              },
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton(
                  onPressed: () {
                    controller.text = '${NativeInfo.filesDir}/downloads';
                    setSheet(() {});
                  },
                  child: const Text('恢复默认'),
                ),
                const Spacer(),
                PmPrimaryButton(
                  label: '保存',
                  expand: false,
                  onPressed: () {
                    store.setDownloadDir(controller.text);
                    Navigator.pop(context);
                    pmToast(context, '下载目录已保存');
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _editDns(BuildContext context, AppStore store) {
    final controller = TextEditingController();
    final bulk = TextEditingController(text: store.dnsServers.join('\n'));
    showPmSheet(
      context,
      title: 'DNS 服务器',
      body: StatefulBuilder(
        builder: (context, setSheet) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '支持 UDP/TCP DNS、DoT、DoH，可混合填写很多台；下载器和测速会全部并发解析。',
              style: context.text.bodySmall?.copyWith(color: context.pm.muted, height: 1.45),
            ),
            const SizedBox(height: 10),
            for (final d in store.dnsServers)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: PmCard(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  radius: 16,
                  child: Row(
                    children: [
                      Icon(
                        d.startsWith('https://') || d.startsWith('doh://')
                            ? Icons.cloud_rounded
                            : (d.startsWith('dot://') || d.startsWith('tls://'))
                                ? Icons.lock_rounded
                                : Icons.dns_rounded,
                        size: 16,
                        color: context.scheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(d, style: context.text.bodyMedium)),
                      IconButton(
                        onPressed: () {
                          final next = [...store.dnsServers]..remove(d);
                          store.setDnsServers(next);
                          bulk.text = next.join('\n');
                          setSheet(() {});
                        },
                        icon: Icon(Icons.delete_outline_rounded, size: 18, color: context.pm.warn),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 4),
            PmField(
              controller: bulk,
              label: '批量 DNS 列表（每行一条，逗号也可）',
              hint: '223.5.5.5\nhttps://dns.alidns.com/dns-query\ndot://dns.google',
              maxLines: 6,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: () {
                    bulk.text = kDnsPreset.join('\n');
                    setSheet(() {});
                  },
                  child: const Text('填入国内外推荐'),
                ),
                const Spacer(),
                PmPrimaryButton(
                  label: '保存全部',
                  icon: Icons.save_rounded,
                  expand: false,
                  onPressed: () {
                    final list = _parseDnsList(bulk.text);
                    store.setDnsServers(list);
                    setSheet(() => bulk.text = list.join('\n'));
                    pmToast(context, '已保存 ${list.length} 台 DNS');
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            PmField(
              controller: controller,
              label: '新增单台',
              hint: '223.5.5.5 / dot://dot.pub / https://doh.pub/dns-query',
            ),
            const SizedBox(height: 10),
            PmPrimaryButton(
              label: '添加',
              icon: Icons.add_rounded,
              onPressed: () {
                final v = controller.text.trim();
                if (v.isEmpty) return;
                final next = _parseDnsList('${store.dnsServers.join('\n')}\n$v');
                store.setDnsServers(next);
                controller.clear();
                bulk.text = next.join('\n');
                setSheet(() {});
              },
            ),
            const SizedBox(height: 4),
            Text(
              '格式：8.8.8.8、8.8.8.8:53、dot://dns.google、dot://dot.pub、https://dns.google/dns-query、https://doh.pub/dns-query',
              style: context.text.bodySmall?.copyWith(color: context.pm.muted, fontSize: 11, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  void _editEndpoints(BuildContext context, AppStore store) {
    final controller = TextEditingController();
    showPmSheet(
      context,
      title: '测速地址',
      body: StatefulBuilder(
        builder: (context, setSheet) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => _importSpeedToml(context, store),
                  icon: const Icon(Icons.file_open_rounded, size: 17),
                  label: const Text('导入 TOML'),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: () => _exportSpeedToml(context, store),
                  icon: const Icon(Icons.file_download_rounded, size: 17),
                  label: const Text('导出 TOML'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    store.setEndpoints(kSpeedPreset);
                    setSheet(() {});
                    pmToast(context, '已填入推荐测速源');
                  },
                  child: const Text('推荐源'),
                ),
              ],
            ),
            const SizedBox(height: 4),
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
                          store.setEndpoints([...store.speedEndpoints]..remove(e));
                          setSheet(() {});
                        },
                        icon: Icon(Icons.delete_outline_rounded, size: 18, color: context.pm.warn),
                      ),
                    ],
                  ),
                ),
              ),
            PmField(
              controller: controller,
              label: '新增 URL 或资源接口',
              hint: 'https://example.com/100MB.bin\n或启动器 resource?key=… 接口',
              maxLines: 2,
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  final v = controller.text.trim();
                  if (v.isEmpty) {
                    pmToast(context, '请填写链接或资源接口');
                    return;
                  }
                  final r = await Core.callAsync('resource_links', {'url': v});
                  if (!context.mounted) return;
                  if (r['ok'] != true) {
                    pmToast(context, '不是可解析的资源 JSON：${r['error']}');
                    return;
                  }
                  final items = ((r['data'] as Map?)?['items'] as List? ?? const [])
                      .whereType<Map>()
                      .map((e) => e['url']?.toString() ?? '')
                      .where((e) => e.startsWith('http'))
                      .toList();
                  if (items.isEmpty) {
                    pmToast(context, '接口里没有直连');
                    return;
                  }
                  final next = [...store.speedEndpoints];
                  for (final u in items) {
                    if (!next.contains(u)) next.add(u);
                  }
                  store.setEndpoints(next);
                  controller.clear();
                  setSheet(() {});
                  pmToast(context, '已解析并加入 ${items.length} 条直连');
                },
                icon: const Icon(Icons.account_tree_rounded, size: 17),
                label: const Text('解析资源 JSON 并加入测速'),
              ),
            ),
            const SizedBox(height: 8),
            PmPrimaryButton(
              label: '添加单条链接',
              icon: Icons.add_rounded,
              onPressed: () {
                final v = controller.text.trim();
                if (v.isEmpty) return;
                store.setEndpoints([...store.speedEndpoints, v]);
                controller.clear();
                setSheet(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  void _exportSpeedToml(BuildContext context, AppStore store) {
    final text = encodeSpeedToml(
      download: store.speedEndpoints,
      uploads: store.uploadEndpoints,
    );
    showPmSheet(
      context,
      title: '导出测速 TOML',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '可直接复制，或另存为 .toml 文件。字段：upload、endpoints。',
            style: context.text.bodySmall?.copyWith(color: context.pm.muted),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: ShapeDecoration(
              color: context.pm.card,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: context.pm.inset),
              ),
            ),
            child: SelectableText(
              text,
              style: context.text.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.5),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: PmPrimaryButton(
                  label: '复制',
                  icon: Icons.copy_rounded,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (context.mounted) pmToast(context, 'TOML 已复制');
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PmPrimaryButton(
                  label: '保存文件',
                  icon: Icons.save_alt_rounded,
                  onPressed: () async {
                    final saved = await NativeInfo.saveTextFile(text, 'netpulse-speed.toml');
                    if (context.mounted) {
                      pmToast(context, saved == null ? '未保存文件' : 'TOML 已保存');
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _importSpeedToml(BuildContext context, AppStore store) {
    final controller = TextEditingController();
    showPmSheet(
      context,
      title: '导入测速 TOML',
      body: StatefulBuilder(
        builder: (context, setSheet) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '支持 endpoints / urls 数组和 upload 字段；也可以直接粘贴 URL 列表。',
              style: context.text.bodySmall?.copyWith(color: context.pm.muted, height: 1.45),
            ),
            const SizedBox(height: 10),
            PmPrimaryButton(
              label: '从文件选择',
              icon: Icons.file_open_rounded,
              onPressed: () async {
                final text = await NativeInfo.pickTextFile();
                if (text == null || text.trim().isEmpty) {
                  if (context.mounted) pmToast(context, '未读取到 TOML 内容');
                  return;
                }
                controller.text = text;
                setSheet(() {});
              },
            ),
            const SizedBox(height: 10),
            PmField(
              controller: controller,
              label: 'TOML 内容 / URL 列表',
              hint: 'upload = "https://…"\nendpoints = ["https://…"]',
              maxLines: 10,
            ),
            const SizedBox(height: 12),
            PmPrimaryButton(
              label: '解析并应用',
              icon: Icons.check_rounded,
              onPressed: () {
                final cfg = decodeSpeedToml(controller.text);
                if (cfg.download.isEmpty && (cfg.upload == null || cfg.upload!.isEmpty)) {
                  pmToast(context, '没有识别到可用的测速地址');
                  return;
                }
                store.setEndpoints(cfg.download);
                if (cfg.uploads.isNotEmpty) {
                  store.setUploadEndpoints(cfg.uploads);
                }
                pmToast(context, '已导入 ${cfg.download.length} 条下载地址');
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _editUpload(BuildContext context, AppStore store) {
    final controller = TextEditingController(text: store.uploadEndpoints.join('\n'));
    showPmSheet(
      context,
      title: '上传测速地址',
      body: StatefulBuilder(
        builder: (context, setSheet) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '每行一个可接收 POST 的上传端点；测速时所有端点会轮询/回退，避免单个源失败导致整轮报错。',
              style: context.text.bodySmall?.copyWith(color: context.pm.muted, height: 1.45),
            ),
            const SizedBox(height: 10),
            PmField(
              controller: controller,
              label: '上传端点（每行一条）',
              hint: 'https://speed.cloudflare.com/__up\nhttps://httpbin.org/post\nhttps://httpbun.com/post',
              maxLines: 5,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                controller.text = kUploadPreset.join('\n');
                setSheet(() {});
              },
              child: const Text('填入推荐上传源'),
            ),
            const SizedBox(height: 12),
            PmPrimaryButton(
              label: '保存',
              onPressed: () {
                store.setUploadEndpoints(
                  controller.text.split(RegExp(r'[,，\s]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
                );
                Navigator.pop(context);
                pmToast(context, '上传源已保存');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showHistory(BuildContext context, AppStore store) {
    if (store.history.isEmpty) {
      pmToast(context, '还没有历史记录');
      return;
    }
    showPmSheet(
      context,
      title: '历史记录',
      body: StatefulBuilder(
        builder: (context, setSheet) {
          final records = store.history;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('${records.length} 条测速记录', style: context.text.bodySmall?.copyWith(color: context.pm.muted)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => confirmDialog(
                      context,
                      title: '清空历史',
                      message: '将删除全部测速记录，无法恢复。',
                      confirmLabel: '清空',
                      destructive: true,
                      onConfirm: () {
                        store.clearHistory();
                        setSheet(() {});
                      },
                    ),
                    icon: Icon(Icons.delete_sweep_rounded, size: 17, color: context.pm.warn),
                    label: Text('清空', style: TextStyle(color: context.pm.warn, fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (records.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text('暂无记录', textAlign: TextAlign.center, style: context.text.bodySmall?.copyWith(color: context.pm.muted)),
                ),
              for (final r in records)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: PmCard(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    radius: 16,
                    child: Row(
                      children: [
                        PmIconBadge(
                          r.kind == 'upload' ? Icons.upload_rounded : Icons.download_rounded,
                          size: 32,
                          radius: 10,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.title, style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 2),
                              Text(
                                '${r.time.year}-${r.time.month.toString().padLeft(2, '0')}-${r.time.day.toString().padLeft(2, '0')} '
                                '${r.time.hour.toString().padLeft(2, '0')}:${r.time.minute.toString().padLeft(2, '0')}',
                                style: context.text.bodySmall?.copyWith(color: context.pm.muted, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              r.unit.isEmpty ? r.value : '${r.value} ${r.unit}',
                              style: context.text.titleSmall,
                            ),
                            if ((r.detail['avg_all_mbps'] as num?) != null)
                              Text(
                                '全程 ${formatMbps((r.detail['avg_all_mbps'] as num).toDouble())} ${r.unit}',
                                style: context.text.bodySmall?.copyWith(color: context.pm.muted, fontSize: 10),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _about(BuildContext context) {
    final version = kAppVersion;
    showPmSheet(
      context,
      title: '关于 NetPulse',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFF007AFF), Color(0xFF5AC8FA)]),
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF007AFF).withValues(alpha: 0.22),
                        blurRadius: 22,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.speed_rounded, color: Colors.white, size: 40),
                ),
                const SizedBox(height: 12),
                Text('NetPulse', style: context.text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text('$version · Flutter + Rust', style: context.text.bodySmall?.copyWith(color: context.pm.muted)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PmCard(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            radius: 16,
            child: Row(
              children: [
                PmIconBadge(Icons.memory_rounded, size: 34, radius: 10),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Flutter 负责界面，Rust core 负责多线程下载、测速、DNS 与网络诊断；数据只在本机流转。',
                    style: context.text.bodySmall?.copyWith(color: context.pm.muted, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          PmSectionTitle('开发与维护'),
          _creditTile(
            context,
            'LianXia233 · 开发与维护',
            'NetPulse 源码、构建与 CI',
            'https://github.com/LianXia233/NetPulse',
            Icons.person_rounded,
          ),
          const SizedBox(height: 18),
          PmSectionTitle('开源声明'),
          PmCard(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            radius: 16,
            child: Text(
              'NetPulse 使用下列开源组件构建，各组件的版权归原作者所有，并遵循其各自许可证。'
              '应用不修改、不重新授权这些组件的原始许可证；完整许可证文本可点击下方按钮查看。',
              style: context.text.bodySmall?.copyWith(color: context.pm.muted, height: 1.55),
            ),
          ),
          const SizedBox(height: 12),
          PmSectionTitle('运行时与库'),
          _licenseTile(context, 'Flutter / Dart', '界面框架与运行时', 'BSD-3-Clause', 'https://flutter.dev'),
          const SizedBox(height: 8),
          _licenseTile(context, 'Rust / serde / serde_json', '核心序列化与 JSON 桥', 'MIT / Apache-2.0', 'https://www.rust-lang.org'),
          const SizedBox(height: 8),
          _licenseTile(context, 'rustls / webpki-roots', 'TLS 与根证书', 'Apache-2.0 / ISC / MPL-2.0', 'https://github.com/rustls/rustls'),
          const SizedBox(height: 8),
          _licenseTile(context, 'AES / CBC / regex', 'HLS AES-128 解密与清单解析', 'MIT / Apache-2.0', 'https://crates.io'),
          const SizedBox(height: 8),
          _licenseTile(context, 'iperf3', '内置打流可执行文件', 'BSD-3-Clause', 'https://github.com/esnet/iperf'),
          const SizedBox(height: 8),
          _licenseTile(context, 'Android System WebView', '内置浏览器渲染内核', 'Apache-2.0', 'https://developer.android.com/guide/webapps'),
          const SizedBox(height: 16),
          PmSectionTitle('交互与设计参考'),
          Text(
            '感谢以下项目在界面组织、交互方式与下载器功能设计上的启发；项目名称与商标归原作者。',
            style: context.text.bodySmall?.copyWith(color: context.pm.muted, height: 1.45),
          ),
          const SizedBox(height: 8),
          _creditTile(context, 'FlClash', '网络工具界面与交互参考 · GPL-3.0', 'https://github.com/chen08209/FlClash', Icons.auto_awesome_rounded),
          const SizedBox(height: 8),
          _creditTile(context, 'FluxDown', '下载器功能组织与分片思路参考 · AGPL-3.0', 'https://github.com/zerx-lab/FluxDown', Icons.download_rounded),
          const SizedBox(height: 16),
          PmPrimaryButton(
            label: '查看完整开源许可证',
            icon: Icons.description_rounded,
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'NetPulse',
              applicationVersion: version,
              applicationLegalese: 'Copyright © 2026 NetPulse contributors. 第三方组件版权归各自作者。',
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Copyright © 2026 NetPulse contributors\n'
            '第三方组件按其原始许可证分发；本页面不构成对任何商标或源码授权的变更。',
            textAlign: TextAlign.center,
            style: context.text.bodySmall?.copyWith(color: context.pm.muted, fontSize: 10.5, height: 1.5),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _creditTile(BuildContext context, String name, String desc, String url, IconData icon) {
    final pm = context.pm;
    return PmCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      radius: 16,
      onTap: () => NativeInfo.openUrl(url),
      child: Row(
        children: [
          PmIconBadge(icon, size: 34, radius: 10),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: context.text.titleSmall),
                Text(desc, style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11)),
                const SizedBox(height: 2),
                Text(url, style: context.text.bodySmall?.copyWith(color: context.scheme.primary, fontSize: 10.5), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Icon(Icons.open_in_new_rounded, size: 16, color: pm.muted),
        ],
      ),
    );
  }

  Widget _licenseTile(BuildContext context, String name, String desc, String license, String url, {VoidCallback? onTap}) {
    final pm = context.pm;
    return PmCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      radius: 16,
      onTap: onTap ?? (url.isEmpty ? null : () => NativeInfo.openUrl(url)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: context.text.titleSmall),
                Text(desc, style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11)),
              ],
            ),
          ),
          PmPill(label: license, dense: true),
          if (onTap != null) ...[
            const SizedBox(width: 5),
            Icon(Icons.open_in_new_rounded, size: 14, color: pm.muted),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.subtitle, this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 13),
        child: Row(
          children: [
            PmIconBadge(icon, size: 36, radius: 11),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: context.text.bodyMedium),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: pm.muted),
          ],
        ),
      ),
    );
  }
}

const kDnsPreset = [
  // 国内大厂：阿里、腾讯、百度、360
  '223.5.5.5',
  'https://dns.alidns.com/dns-query',
  'dot://dns.alidns.com',
  '119.29.29.29',
  'https://doh.pub/dns-query',
  'dot://dot.pub',
  '180.76.76.76',
  'https://doh.x.baidu.com/dns-query',
  'https://doh.360.cn/dns-query',
  // 国际大厂：Google、Cloudflare、Quad9、OpenDNS
  '8.8.8.8',
  'https://dns.google/dns-query',
  'dot://dns.google',
  '1.1.1.1',
  'https://cloudflare-dns.com/dns-query',
  'dot://one.one.one.one',
  '9.9.9.9',
  'https://doh.quad9.net/dns-query',
  'dot://dns.quad9.net',
  '208.67.222.222',
  'https://doh.opendns.com/dns-query',
];

List<String> _parseDnsList(String text) {
  return normalizeDnsList(text.split(RegExp(r'[,，\n\r]+')));
}


String _bindSummary(String bind, String ipMode, String dnsMode) {
  final b = bind.trim().isEmpty ? '自动出口' : bind.trim();
  final ip = switch (ipMode) {
    'v4' => 'IPv4',
    'v6' => 'IPv6',
    _ => '双栈',
  };
  final dns = dnsMode == 'primary' ? '主 DNS 优先' : '多 DNS 并发';
  return '$b · $ip · $dns';
}


const kSpeedPreset = [
  'https://speed.cloudflare.com/__down?bytes=50000000',
  'https://speed.hetzner.de/100MB.bin',
  'https://proof.ovh.net/files/100Mb.dat',
  'https://speedtest.tele2.net/100MB.zip',
  'https://download.thinkbroadband.com/100MB.zip',
  'https://mirror.leaseweb.com/speedtest/100mb.bin',
  'https://cachefly.cachefly.net/100mb.test',
];


const kUploadPreset = [
  'https://speed.cloudflare.com/__up',
  'https://httpbin.org/post',
  'https://httpbun.com/post',
  'https://echo.zuplo.io/',
];
