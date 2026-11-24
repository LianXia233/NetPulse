import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse/bridge.dart';
import 'package:netpulse/main.dart';
import 'package:netpulse/store.dart';
import 'package:netpulse/theme.dart';

void main() {
  test('format helpers', () {
    expect(formatBytes(1024), contains('KB'));
    expect(formatMbps(100), contains('100'));
  });

  testWidgets('五个页面可渲染且无布局异常', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    NativeInfo.filesDir = Directory.systemTemp.path;
    NativeInfo.initialized = true;
    final store = AppStore();
    await tester.runAsync(() => store.load());

    await tester.pumpWidget(PmApp(store: store));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: '概览首屏');

    for (final label in ['测速', '下载', '工具', '仪表盘']) {
      await tester.tap(find.text(label).last);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull, reason: label);
    }
  });
}
