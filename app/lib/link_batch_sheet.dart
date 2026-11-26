import 'package:flutter/material.dart';

import 'bridge.dart';
import 'store.dart';
import 'theme.dart';
import 'widgets.dart';

/// 网页脚本解析出的多个直链：勾选确认后一次性入队。
///
/// 与单链接参数页的区别是「详情页已经确定了请求头」，这里不再让用户
/// 逐项填 URL，只保留目录与筛选，避免几十个文件时反复确认。
/// 返回实际入队的数量。
Future<int> showLinkBatchSheet(
  BuildContext context, {
  required List<Map<String, dynamic>> items,
  Map<String, String> headers = const {},
  String referrer = '',
  String source = '',
}) async {
  final store = AppScope.of(context);
  final dir = TextEditingController(text: store.downloadDirEffective);
  final picked = <int>{for (var i = 0; i < items.length; i++) i};
  var busy = false;
  final queued = await showPmSheet<int>(
    context,
    title: '加入下载队列',
    maxHeight: 0.9,
    body: StatefulBuilder(
      builder: (ctx, setSheet) {
        final pm = ctx.pm;
        final totalBytes = picked.fold<int>(
          0,
          (sum, i) => sum + ((items[i]['size'] as num?)?.toInt() ?? 0),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              source.isEmpty
                  ? '共 ${items.length} 个文件，请求头已按来源页自动补齐。'
                  : '$source · 共 ${items.length} 个文件，请求头已按来源页自动补齐。',
              style: ctx.text.bodySmall?.copyWith(color: pm.muted, height: 1.5),
            ),
            if (headers.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final k in headers.keys.take(4))
                    PmPill(
                      label: '$k ${headers[k]!.isEmpty ? '—' : '已带'}',
                      dense: true,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  '已选 ${picked.length}/${items.length}',
                  style: ctx.text.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (totalBytes > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    formatBytes(totalBytes.toDouble()),
                    style: ctx.text.bodySmall?.copyWith(color: pm.muted),
                  ),
                ],
                const Spacer(),
                TextButton(
                  onPressed: () => setSheet(() {
                    if (picked.length == items.length) {
                      picked.clear();
                    } else {
                      picked
                        ..clear()
                        ..addAll(List.generate(items.length, (i) => i));
                    }
                  }),
                  child: Text(picked.length == items.length ? '全不选' : '全选'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (ctx, i) {
                  final it = items[i];
                  final name = it['name']?.toString() ?? '';
                  final url = it['url']?.toString() ?? '';
                  final size = (it['size'] as num?)?.toInt() ?? 0;
                  final on = picked.contains(i);
                  return PmCard(
                    padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
                    radius: 14,
                    onTap: () => setSheet(() {
                      if (on) {
                        picked.remove(i);
                      } else {
                        picked.add(i);
                      }
                    }),
                    child: Row(
                      children: [
                        Icon(
                          on
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 20,
                          color: on ? ctx.scheme.primary : pm.muted,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name.isEmpty ? _guessName(url) : name,
                                style: ctx.text.bodySmall?.copyWith(
                                  fontSize: 12.5,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                size > 0
                                    ? formatBytes(size.toDouble())
                                    : _hostOf(url),
                                style: ctx.text.bodySmall?.copyWith(
                                  color: pm.muted,
                                  fontSize: 10.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            PmField(
              controller: dir,
              label: '保存目录',
              hint: kDefaultDownloadDir,
            ),
            const SizedBox(height: 14),
            PmPrimaryButton(
              label: busy ? '正在入队…' : '开始下载 ${picked.length} 个',
              icon: Icons.download_rounded,
              loading: busy,
              onPressed: busy || picked.isEmpty
                  ? null
                  : () async {
                      final saveDir = dir.text.trim().isEmpty
                          ? store.downloadDirEffective
                          : dir.text.trim();
                      setSheet(() => busy = true);
                      var ok = 0;
                      final order = picked.toList()..sort();
                      for (final i in order) {
                        final url = items[i]['url']?.toString() ?? '';
                        if (url.isEmpty) continue;
                        final name = items[i]['name']?.toString() ?? '';
                        if (await _enqueue(
                          store,
                          url: url,
                          name: name.isEmpty ? _guessName(url) : name,
                          headers: headers,
                          dir: saveDir,
                        )) {
                          ok++;
                        }
                      }
                      if (!ctx.mounted) return;
                      store.setDownloadDir(saveDir);
                      Navigator.pop(ctx, ok);
                    },
            ),
            if (referrer.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '来源页：$referrer',
                style: ctx.text.bodySmall?.copyWith(
                  color: pm.muted,
                  fontSize: 10.5,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        );
      },
    ),
  );
  return queued ?? 0;
}

Future<bool> _enqueue(
  AppStore store, {
  required String url,
  required String name,
  required Map<String, String> headers,
  required String dir,
}) async {
  if (!Core.i.ready) return false;
  final r = Core.i.call('start_download', {
    'url': url,
    'mirrors': store.downloadMirrors,
    'dir': dir,
    'name': name,
    'connections': store.downloadConnections,
    'block_kb': store.downloadBlockKb,
    'retries': store.downloadRetries,
    'dns_servers': store.downloadDns,
    'headers': headers,
    'bind': store.downloadBind,
    'ip_mode': store.downloadIpMode,
    'dns_mode': store.downloadDnsMode,
  });
  if (r['ok'] != true) return false;
  final data = r['data'] as Map?;
  store.upsertDownloadRecord({
    'id': data?['task_id']?.toString() ?? '',
    'url': url,
    'name': data?['name']?.toString() ?? name,
    'dir': dir,
    'kind': 'http',
    'status': 'running',
    'size': 0,
    'done': 0,
    'mirrors': store.downloadMirrors,
    'headers': headers,
    'dns': store.downloadDns,
    'connections': store.downloadConnections,
    'block_kb': store.downloadBlockKb,
    'retries': store.downloadRetries,
    'created': DateTime.now().toIso8601String(),
  });
  return true;
}

String _guessName(String url) {
  final uri = Uri.tryParse(url);
  final segs =
      uri?.pathSegments.where((e) => e.isNotEmpty).toList() ?? const <String>[];
  return segs.isEmpty ? 'netpulse_download.bin' : segs.last;
}

String _hostOf(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.isEmpty ? url : host;
}
