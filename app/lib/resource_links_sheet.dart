import 'package:flutter/material.dart';

import 'bridge.dart';
import 'page_kit.dart';
import 'store.dart';
import 'theme.dart';
import 'widgets.dart';

/// 解析资源清单 JSON（如启动器 resource 接口），列出全部直连并批量加入下载队列。
/// 不预制任何游戏或站点 URL，完全依赖接口返回内容。
Future<void> showResourceLinksSheet(
  BuildContext context, {
  required String sourceUrl,
  required String dir,
  required int connections,
  required int blockKb,
  required int retries,
  required Map<String, String> headers,
}) async {
  final store = AppScope.of(context);
  // 网络请求放到后台 isolate，避免解析 12 秒超时期间冻结 UI。
  final r = await Core.callAsync('resource_links', {
    'url': sourceUrl,
    'headers': headers,
  });
  if (r['ok'] != true) {
    if (context.mounted) pmToast(context, r['error']?.toString() ?? '资源解析失败');
    return;
  }
  final raw = (r['data'] as Map?)?['items'];
  final items = (raw is List ? raw : const [])
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .where((e) => (e['url'] ?? '').toString().startsWith('http'))
      .toList();
  if (items.isEmpty) {
    if (context.mounted) pmToast(context, '接口里没有找到下载直连');
    return;
  }
  if (!context.mounted) return;
  showPmSheet(
    context,
    title: '资源直连 · ${items.length} 个',
    body: StatefulBuilder(
      builder: (context, setSheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '来自接口返回的 path / url 字段，按出现顺序排列；不会预置到默认测速或下载列表。',
            style: context.text.bodySmall?.copyWith(color: context.pm.muted, height: 1.45),
          ),
          const SizedBox(height: 10),
          for (final it in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PmCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                radius: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (it['name'] ?? '').toString().isEmpty
                          ? '未命名直连'
                          : '${it['name']}',
                      style: context.text.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      (it['url'] ?? '').toString(),
                      style: context.text.bodySmall?.copyWith(color: context.pm.muted, fontSize: 10.5),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if ((it['size'] as num?) != null)
                      Text(
                        '${formatBytes((it['size'] as num).toInt())} · ${it['key'] ?? ''}',
                        style: context.text.bodySmall?.copyWith(color: context.pm.muted, fontSize: 10),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 6),
          PmPrimaryButton(
            label: '全部加入下载队列',
            icon: Icons.download_rounded,
            onPressed: () {
              var ok = 0;
              final targetDir = dir.isEmpty ? store.downloadDirEffective : dir;
              for (final it in items) {
                final rr = Core.i.call('start_download', {
                  'url': it['url'],
                  'dir': targetDir,
                  'name': it['name'],
                  'connections': connections,
                  'block_kb': blockKb,
                  'retries': retries,
                  'dns_servers': store.downloadDns,
                  'headers': headers,
                  'bind': store.downloadBind,
                  'ip_mode': store.downloadIpMode,
                  'dns_mode': store.downloadDnsMode,
                });
                if (rr['ok'] == true) {
                  ok++;
                  final data = rr['data'] as Map?;
                  final id = data?['task_id']?.toString() ?? '';
                  final url = (it['url'] ?? '').toString();
                  final uri = Uri.tryParse(url);
                  final name = data?['name']?.toString() ?? ((it['name'] ?? '').toString().isNotEmpty
                      ? it['name'].toString()
                      : (uri?.pathSegments.isNotEmpty == true ? uri!.pathSegments.last : 'download.bin'));
                  store.upsertDownloadRecord({
                    'id': id,
                    'url': url,
                    'name': name,
                    'dir': targetDir,
                    'kind': 'http',
                    'status': 'running',
                    'size': it['size'] ?? 0,
                    'done': 0,
                    'mirrors': const [],
                    'headers': headers,
                    'dns': store.downloadDns,
                    'connections': connections,
                    'block_kb': blockKb,
                    'retries': retries,
                    'created': DateTime.now().toIso8601String(),
                  }, persist: false);
                }
              }
              store.save();
              pmToast(context, '已加入 $ok / ${items.length} 个下载');
              Navigator.pop(context);
            },
          ),
        ],
      ),
    ),
  );
}
