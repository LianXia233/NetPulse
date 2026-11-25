import 'package:flutter/material.dart';

import 'bridge.dart';
import 'page_kit.dart';
import 'resource_links_sheet.dart';
import 'store.dart';
import 'theme.dart';
import 'widgets.dart';

/// 打开「链接推送 / 下载参数」弹层。
/// 浏览器嗅探、系统分享、手动新建下载都走这里，保证参数一致。
Future<void> showDownloadSheet(
  BuildContext context, {
  String initialUrl = '',
  Map<String, String> extraHeaders = const {},
  String? suggestedName,
  List<Map<String, String>> extraDownloads = const [],
}) {
  final store = AppScope.of(context);
  final url = TextEditingController(text: initialUrl);
  final name = TextEditingController(text: suggestedName ?? '');
  final mirrors = TextEditingController(text: store.downloadMirrors.join('\n'));
  final dns = TextEditingController(text: store.downloadDns.join('\n'));
  final ua = TextEditingController(
    text: extraHeaders['User-Agent'] ?? store.downloadUserAgent,
  );
  final referer = TextEditingController(text: extraHeaders['Referer'] ?? '');
  final cookie = TextEditingController(text: extraHeaders['Cookie'] ?? '');
  final auth = TextEditingController(text: extraHeaders['Authorization'] ?? '');
  final extra = TextEditingController();
  final dir = TextEditingController(text: store.downloadDirEffective);
  var connections = store.downloadConnections.toDouble();
  var retries = store.downloadRetries.toDouble();
  var blockKb = store.downloadBlockKb.toDouble();

  Future<void> enqueue(
    String link, {
    String? name,
    Map<String, String> headers = const {},
    String? dir,
    List<String>? mirrors,
    List<String>? dns,
    int? connections,
    int? blockKb,
    int? retries,
  }) async {
    final targetDir = dir ?? store.downloadDirEffective;
    final conn = connections ?? store.downloadConnections;
    final block = blockKb ?? store.downloadBlockKb;
    final tries = retries ?? store.downloadRetries;
    final dnsServers = dns ?? store.downloadDns;
    final mirrorList = mirrors ?? const <String>[];
    final r = Core.i.call('start_download', {
      'url': link,
      'mirrors': mirrorList,
      'dir': targetDir,
      'name': name,
      'connections': conn,
      'block_kb': block,
      'retries': tries,
      'dns_servers': dnsServers,
      'headers': headers,
      'bind': store.downloadBind,
      'ip_mode': store.downloadIpMode,
      'dns_mode': store.downloadDnsMode,
    });
    if (r['ok'] != true) return;
    final data = r['data'] as Map?;
    store.upsertDownloadRecord({
      'id': data?['task_id']?.toString() ?? '',
      'url': link,
      'name': data?['name']?.toString() ?? name ?? _recordName(link),
      'dir': targetDir,
      'kind': 'http',
      'status': 'running',
      'size': 0,
      'done': 0,
      'mirrors': mirrorList,
      'headers': headers,
      'dns': dnsServers,
      'connections': conn,
      'block_kb': block,
      'retries': tries,
      'created': DateTime.now().toIso8601String(),
    });
  }

  return showPmSheet(
    context,
    title: '下载链接',
    body: StatefulBuilder(
      builder: (context, setSheet) {
        final pm = context.pm;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionLabel('链接与来源'),
            PmField(
              controller: url,
              label: '下载地址',
              hint: 'https://example.com/file.zip?sig=…',
              maxLines: 2,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  final link = url.text.trim();
                  if (link.isEmpty) {
                    pmToast(context, '请先填写资源接口地址');
                    return;
                  }
                  showResourceLinksSheet(
                    context,
                    sourceUrl: link,
                    dir: dir.text.trim().isEmpty
                        ? store.downloadDirEffective
                        : dir.text.trim(),
                    connections: connections.round(),
                    blockKb: blockKb.round(),
                    retries: retries.round(),
                    headers: {
                      if (ua.text.trim().isNotEmpty)
                        'User-Agent': ua.text.trim(),
                      if (referer.text.trim().isNotEmpty)
                        'Referer': referer.text.trim(),
                      if (cookie.text.trim().isNotEmpty)
                        'Cookie': cookie.text.trim(),
                      if (auth.text.trim().isNotEmpty)
                        'Authorization': auth.text.trim(),
                    },
                  );
                },
                icon: const Icon(Icons.account_tree_rounded, size: 17),
                label: const Text('解析资源 JSON 并批量添加'),
              ),
            ),
            const SizedBox(height: 10),
            PmField(
              controller: mirrors,
              label: '多 CDN 镜像（每行一条，可选）',
              hint: 'https://cdn-a.example.com/file.zip\nhttps://cdn-b.example.com/file.zip',
              maxLines: 3,
            ),
            const SizedBox(height: 10),
            PmField(controller: name, label: '文件名（可选）', hint: '留空则从链接与响应头推断'),
            const SizedBox(height: 10),
            PmField(
              controller: dir,
              label: '保存目录',
              hint: '/storage/.../NetPulse/downloads',
              suffix: IconButton(
                onPressed: () async {
                  final path = await NativeInfo.selectDirectory();
                  if (path == null || path.isEmpty) {
                    if (context.mounted)
                      pmToast(context, '未选择目录，或需要先授予所有文件访问权限');
                    return;
                  }
                  dir.text = path;
                  setSheet(() {});
                },
                icon: Icon(
                  Icons.folder_open_rounded,
                  color: context.scheme.primary,
                  size: 20,
                ),
                tooltip: '从文件管理器选择',
              ),
            ),
            const SizedBox(height: 16),
            _SectionLabel('并发与分块'),
            PmSliderRow(
              label: '并发连接',
              value: connections,
              min: 1,
              max: 32,
              divisions: 31,
              display: (v) => '${v.toStringAsFixed(0)} 条',
              onChanged: (v) => setSheet(() => connections = v),
            ),
            PmSliderRow(
              label: '分块大小',
              value: blockKb,
              min: 64,
              max: 8192,
              divisions: 127,
              display: (v) =>
                  '${(v / 1024).toStringAsFixed(v < 1024 ? 2 : 1)} MB',
              onChanged: (v) => setSheet(() => blockKb = v),
            ),
            PmSliderRow(
              label: '失败重试',
              value: retries,
              min: 0,
              max: 10,
              divisions: 10,
              display: (v) => '${v.toStringAsFixed(0)} 次',
              onChanged: (v) => setSheet(() => retries = v),
            ),
            const SizedBox(height: 6),
            _SectionLabel('DNS 与请求头'),
            PmField(
              controller: dns,
              label: '多 DNS（每行一条，支持 DoT/DoH）',
              hint: '223.5.5.5\n119.29.29.29\nhttps://dns.alidns.com/dns-query\ndot://dns.google',
              maxLines: 4,
            ),
            const SizedBox(height: 10),
            PmField(controller: ua, label: 'User-Agent', maxLines: 2),
            const SizedBox(height: 10),
            PmField(
              controller: referer,
              label: 'Referer',
              hint: '来源页，部分站点用于鉴权',
            ),
            const SizedBox(height: 10),
            PmField(
              controller: cookie,
              label: 'Cookie',
              maxLines: 2,
              hint: '从浏览器带入的会话信息',
            ),
            const SizedBox(height: 10),
            PmField(
              controller: auth,
              label: 'Authorization',
              hint: 'Bearer … / Basic …',
            ),
            const SizedBox(height: 10),
            PmField(
              controller: extra,
              label: '自定义请求头（每行 Key: Value）',
              hint: 'X-Sign: 9f2c…\nX-Timestamp: 1760000000',
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: ShapeDecoration(
                color: pm.block,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                '保存到 ${dir.text.trim().isEmpty ? '${NativeInfo.filesDir}/downloads' : dir.text.trim()}\n'
                '鉴权参数会原样透传给下载器（含查询串、Cookie、Referer 与自定义头）；Cookie/Authorization 仅保存在本机私有记录，不写入下载目录。',
                style: context.text.bodySmall?.copyWith(
                  color: pm.muted,
                  height: 1.5,
                ),
              ),
            ),
            if (extraDownloads.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: ShapeDecoration(
                  color: pm.block,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  '该资源含独立音轨，下载视频时会同时加入 ${extraDownloads.length} 个音频任务；如需单个文件请用支持音视频合并的工具处理。',
                  style: context.text.bodySmall?.copyWith(
                    color: pm.muted,
                    height: 1.5,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            PmPrimaryButton(
              label: '开始下载',
              icon: Icons.download_rounded,
              onPressed: () async {
                final link = url.text.trim();
                final uri = Uri.tryParse(link);
                if (uri == null ||
                    !(uri.scheme == 'http' || uri.scheme == 'https')) {
                  pmToast(context, '请输入 http/https 下载地址');
                  return;
                }
                if (!Core.i.ready) {
                  pmToast(context, '下载核心未就绪');
                  return;
                }
                final headerMap = <String, String>{
                  ...extraHeaders,
                  if (ua.text.trim().isNotEmpty) 'User-Agent': ua.text.trim(),
                  if (referer.text.trim().isNotEmpty)
                    'Referer': referer.text.trim(),
                  if (cookie.text.trim().isNotEmpty)
                    'Cookie': cookie.text.trim(),
                  if (auth.text.trim().isNotEmpty)
                    'Authorization': auth.text.trim(),
                };
                for (final line in extra.text.split('\n')) {
                  final i = line.indexOf(':');
                  if (i > 0) {
                    final k = line.substring(0, i).trim();
                    final v = line.substring(i + 1).trim();
                    if (k.isNotEmpty && v.isNotEmpty) headerMap[k] = v;
                  }
                }
                final mirrorList = mirrors.text
                    .split('\n')
                    .map((e) => e.trim())
                    .where((e) => e.startsWith('http'))
                    .toList();
                final dnsList = dns.text
                    .split(RegExp('[,，\\s]+'))
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList();
                var saveDir = dir.text.trim().isEmpty
                    ? store.downloadDirEffective
                    : dir.text.trim();
                if (saveDir == kDefaultDownloadDir) {
                  final prepared = await NativeInfo.prepareDownloadDir();
                  if (prepared == null) {
                    if (context.mounted) {
                      pmToast(context, '需要“所有文件访问权限”才能写入 Download/NetPulse');
                    }
                    return;
                  }
                  saveDir = prepared;
                }
                if (!context.mounted) return;
                final r = Core.i.call('start_download', {
                  'url': link,
                  'mirrors': mirrorList,
                  'dir': saveDir,
                  'name': name.text.trim().isEmpty ? null : name.text.trim(),
                  'connections': connections.round(),
                  'block_kb': blockKb.round(),
                  'retries': retries.round(),
                  'dns_servers': dnsList.isEmpty ? store.downloadDns : dnsList,
                  'headers': headerMap,
                  'bind': store.downloadBind,
                  'ip_mode': store.downloadIpMode,
                  'dns_mode': store.downloadDnsMode,
                });
                if (r['ok'] != true) {
                  pmToast(context, r['error']?.toString() ?? '启动失败');
                  return;
                }
                final data = r['data'] as Map?;
                final recordName =
                    data?['name']?.toString() ??
                    (name.text.trim().isEmpty
                        ? _recordName(link)
                        : name.text.trim());
                final id = data?['task_id']?.toString() ?? '';
                store.upsertDownloadRecord({
                  'id': id,
                  'url': link,
                  'name': recordName,
                  'dir': saveDir,
                  'kind': 'http',
                  'status': 'running',
                  'size': 0,
                  'done': 0,
                  'mirrors': mirrorList,
                  'headers': headerMap,
                  'dns': dnsList.isEmpty ? store.downloadDns : dnsList,
                  'connections': connections.round(),
                  'block_kb': blockKb.round(),
                  'retries': retries.round(),
                  'created': DateTime.now().toIso8601String(),
                });
                store.setDownloadConnections(connections.round());
                store.setDownloadRetries(retries.round());
                store.setDownloadBlockKb(blockKb.round());
                store.setDownloadMirrors(mirrorList);
                store.setDownloadDns(
                  dnsList.isEmpty ? store.downloadDns : dnsList,
                );
                if (ua.text.trim().isNotEmpty)
                  store.setDownloadUserAgent(ua.text.trim());
                store.setDownloadDir(saveDir);
                for (final item in extraDownloads) {
                  final extraUrl = item['url']?.trim() ?? '';
                  if (extraUrl.isEmpty) continue;
                  await enqueue(
                    extraUrl,
                    name: item['name'],
                    headers: headerMap,
                    dir: saveDir,
                    mirrors: mirrorList,
                    dns: dnsList.isEmpty ? store.downloadDns : dnsList,
                    connections: connections.round(),
                    blockKb: blockKb.round(),
                    retries: retries.round(),
                  );
                }
                Navigator.pop(context);
                pmToast(
                  context,
                  '已加入下载队列${extraDownloads.isEmpty ? '' : '（含音轨）'}',
                );
              },
            ),
          ],
        );
      },
    ),
  );
}

String _recordName(String url) {
  final uri = Uri.tryParse(url);
  final segs =
      uri?.pathSegments.where((e) => e.isNotEmpty).toList() ?? const <String>[];
  if (segs.isEmpty) return 'netpulse_download.bin';
  var name = segs.last;
  if (name.endsWith('.m3u8')) return '${name.substring(0, name.length - 5)}.ts';
  if (name.endsWith('.mpd')) return '${name.substring(0, name.length - 4)}.mp4';
  return name;
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        text,
        style: context.text.labelLarge?.copyWith(
          fontSize: 13.5,
          color: context.scheme.onSurface.withValues(alpha: 0.78),
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
