import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse/userscript.dart';

const _sample = r'''
// ==UserScript==
// @name         示例脚本
// @namespace    https://example.com/ns
// @version      1.2.3
// @description  只在示例站生效
// @author       tester
// @homepage     https://example.com/about
// @match        *://*.example.com/*
// @match        https://other.test/path/*
// @include      /^https?:\/\/regex\.test\/.*$/
// @exclude      *://*.example.com/admin/*
// @grant        GM_getValue
// @grant        GM_xmlhttpRequest
// @require      https://cdn.example.com/lib.js
// @resource     SwalLigt https://cdn.example.com/a.css
// @run-at       document-start
// ==/UserScript==

console.log('hello');
''';

void main() {
  test('解析 UserScript 元数据', () {
    final meta = parseUserScriptMeta(_sample);
    expect(meta, isNotNull);
    expect(meta!['name'], '示例脚本');
    expect(meta['namespace'], 'https://example.com/ns');
    expect(meta['version'], '1.2.3');
    expect(meta['author'], 'tester');
    expect(meta['homepage'], 'https://example.com/about');
    expect(meta['match'], [
      '*://*.example.com/*',
      'https://other.test/path/*',
    ]);
    expect(meta['include'], [r'/^https?:\/\/regex\.test\/.*$/']);
    expect(meta['exclude'], ['*://*.example.com/admin/*']);
    expect(meta['grant'], ['GM_getValue', 'GM_xmlhttpRequest']);
    expect(meta['require'], ['https://cdn.example.com/lib.js']);
    expect(meta['resource'], {'SwalLigt': 'https://cdn.example.com/a.css'});
    expect(meta['runAt'], 'document-start');
  });

  test('不是用户脚本时返回 null', () {
    expect(parseUserScriptMeta('console.log(1);'), isNull);
    expect(parseUserScriptMeta('// ==UserScript==\n// @name x\n'), isNull);
  });

  test('脚本 id 稳定且区分命名空间', () {
    final a = userScriptId(name: '示例脚本', namespace: 'https://example.com/ns');
    final b = userScriptId(name: '示例脚本', namespace: 'https://example.com/ns');
    final c = userScriptId(name: '示例脚本', namespace: 'https://other.com');
    expect(a, b);
    expect(a, isNot(c));
    expect(a.length, 8);
  });

  test('@match / @include / @exclude 命中规则', () {
    final meta = parseUserScriptMeta(_sample)!;
    final script = UserScript(
      id: 'x',
      name: meta['name'] as String,
      match: (meta['match'] as List).cast<String>(),
      include: (meta['include'] as List).cast<String>(),
      exclude: (meta['exclude'] as List).cast<String>(),
      runAt: meta['runAt'] as String,
    );
    expect(script.matches('https://www.example.com/a/b'), isTrue);
    expect(script.matches('https://example.com/'), isTrue);
    expect(script.matches('http://sub.example.com:8080/x?y=1'), isTrue);
    // 路径段里的 * 生效，但子域之外的站点不命中
    expect(script.matches('https://other.test/path/1'), isTrue);
    expect(script.matches('https://other.test/other'), isFalse);
    // @exclude 优先
    expect(script.matches('https://www.example.com/admin/users'), isFalse);
    // @include 正则
    expect(script.matches('http://regex.test/anything'), isTrue);
    expect(script.matches('https://notregex.test/x'), isFalse);
    expect(script.matches('https://another.com/x'), isFalse);
  });

  test('<all_urls> 覆盖 http/https', () {
    final script = UserScript(id: 'x', name: 'all', match: ['<all_urls>']);
    expect(script.matches('https://a.com/'), isTrue);
    expect(script.matches('http://b.cn/x'), isTrue);
    expect(script.matches('ftp://b.cn/x'), isFalse);
  });

  test('匹配摘要只取站点域名', () {
    final script = UserScript(
      id: 'x',
      name: 'n',
      match: ['*://*.pan.baidu.com/*', 'https://example.com/x/y'],
      include: ['/re/'],
    );
    expect(script.hostHints, ['pan.baidu.com', 'example.com']);
    final all = UserScript(id: 'y', name: 'n', match: ['<all_urls>']);
    expect(all.hostHints, ['*']);
  });

  test('识别 .user.js 直链，避免把源码当网页打开', () {
    expect(
      UserScriptStore.looksLikeUserScriptUrl(
        'https://update.greasyfork.org/scripts/470233/name.user.js',
      ),
      isTrue,
    );
    expect(
      UserScriptStore.looksLikeUserScriptUrl(
        'https://example.com/a.user.js?raw=1',
      ),
      isTrue,
    );
    expect(
      UserScriptStore.looksLikeUserScriptUrl(
        'https://greasyfork.org/zh-CN/scripts/470233',
      ),
      isFalse,
    );
    expect(
      UserScriptStore.looksLikeUserScriptUrl('https://example.com/a.js'),
      isFalse,
    );
    expect(UserScriptStore.looksLikeUserScriptUrl('javascript:void(0)'), isFalse);
  });

  test('补充安装来源时保留其它字段', () {
    final s = UserScript(
      id: 'x',
      name: 'n',
      version: '1.0',
      sourceUrl: 'https://update.greasyfork.org/scripts/1/a.user.js',
    );
    final next = s.copyWith(sourceUrl: 'https://greasyfork.org/zh-CN/scripts/1');
    expect(next.sourceUrl, 'https://greasyfork.org/zh-CN/scripts/1');
    expect(next.name, 'n');
    expect(next.version, '1.0');
  });

  test('GreasyFork 增强脚本接管官方安装按钮', () async {
    final js = await File('assets/userscript/greasyfork.js').readAsString();
    expect(js.contains('hookInstallLinks'), isTrue);
    expect(js.contains('#install-area a.install-link'), isTrue);
    expect(js.contains('__npGreasyRefresh'), isTrue);
    expect(js.contains("invoke('installScript'"), isTrue);
  });
}
