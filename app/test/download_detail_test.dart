import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse/bridge.dart';
import 'package:netpulse/pages/download_detail_page.dart';
import 'package:netpulse/store.dart';
import 'package:netpulse/theme.dart';

/// 窄屏（320dp）下渲染下载详情页。
///
/// 工作线程与 CDN 池是信息最密的两块：速度、块数、出口 IP、归属地、域名、
/// DNS、延迟全部要显示完整。一旦某行装不下，Flutter 会在窄屏抛 overflow，
/// 这个用例就是拦住那类回归。
void main() {
  testWidgets('下载详情页窄屏渲染工作线程与 CDN 池无溢出', (tester) async {
    // 视口给足高度：ListView 只构建可见项，一屏渲染才能一次性校验全部卡片。
    tester.view.physicalSize = const Size(960, 18000);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    NativeInfo.filesDir = Directory.systemTemp.path;
    NativeInfo.initialized = true;
    final store = AppStore();
    await tester.runAsync(() => store.load());

    final snapshot = <String, dynamic>{
      'id': 'local:demo',
      'url': 'https://cdn.example.com/media/2026/11/demo-ep01.mp4',
      'name': '示例番剧 第01集.mp4',
      'dir': '/tmp',
      'size': 290664597,
      'done': 123456789,
      'mbps': 12.345,
      'status': 'paused',
      'kind': 'http',
      'connections': 8,
      'chunk_size': 1048576,
      'parts_total': 0,
      'parts_done': 0,
      'dns_servers': ['223.5.5.5', '119.29.29.29'],
      'mirrors': ['https://mirror.example.net/media/demo-ep01.mp4'],
      'chunks': [
        {'index': 0, 'start': 0, 'end': 1048575, 'size': 1048576, 'done': 1048576, 'percent': 100.0},
        {'index': 1, 'start': 1048576, 'end': 2097151, 'size': 1048576, 'done': 524288, 'percent': 50.0},
      ],
      'workers': [
        {
          'id': 1,
          'ip': '203.0.113.7',
          'dns': '223.5.5.5',
          'cdn': 'https://cdn.example.com/media/2026/11/demo-ep01.mp4',
          'bytes': 12000000,
          'mbps': 12.345,
          'chunks': 12,
          'state': '下载中',
          'last_error': '',
          'elapsed_ms': 9600,
          'errs': 2,
        },
        {
          'id': 2,
          'ip': '',
          'dns': '',
          'cdn': '',
          'bytes': 0,
          'mbps': 0.0,
          'chunks': 0,
          'state': '待命',
          'last_error': 'connection reset by peer',
          'elapsed_ms': 0,
          'errs': 0,
        },
      ],
      'cdn': [
        {
          'url': 'https://cdn.example.com/media/2026/11/demo-ep01.mp4',
          'ip': '203.0.113.7',
          'dns': '223.5.5.5',
          'ms': 46,
        },
        {
          'url': 'https://cdn2.example.com/media/2026/11/demo-ep01.mp4',
          'ip': '',
          'dns': '119.29.29.29',
          'ms': 0,
        },
      ],
    };

    await tester.pumpWidget(
      AppScope(
        store: store,
        child: MaterialApp(
          theme: buildPmTheme(
            brightness: Brightness.light,
            seed: store.seed,
            pureBlack: store.pureBlack,
          ),
          home: DownloadDetailPage(
            id: 'local:demo',
            name: '示例番剧 第01集.mp4',
            dir: '/tmp',
            snapshot: snapshot,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '详情页首帧');
    // 线程与节点都按快照渲染出来了，说明这块没有被异常路径吞掉。
    expect(find.text('Work 1'), findsOneWidget);
    expect(find.text('Work 2'), findsOneWidget);
    expect(find.textContaining('CDN IP 池'), findsOneWidget);

    // IpGeoBlock 挂载时会起一个 70ms 的合批定时器去查归属地；
    // 测试里推进时间让它跑完，避免结束时残留 pending timer。
    await tester.pump(const Duration(milliseconds: 200));
  });
}
