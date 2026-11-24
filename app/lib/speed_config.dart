/// 测速地址的轻量 TOML 配置（导入 / 导出共用）。
///
/// 自动识别的键名（大小写不敏感，兼容常见测速工具的配置）：
/// - 下载：`endpoints` / `download` / `downloads` / `urls` / `url` / `servers` / `dl`
/// - 上传：`upload` / `uploads` / `upload_urls` / `upload_urls` / `up` / `upurls`
///
/// 值既支持 TOML 数组（`["https://a", "https://b"]`，可跨行），也支持
/// 单个字符串（`upload = "https://x"`）。导入纯 URL 列表也可以。
class SpeedTomlConfig {
  const SpeedTomlConfig({required this.download, required this.uploads});

  final List<String> download;
  final List<String> uploads;

  String? get upload => uploads.isEmpty ? null : uploads.first;

  bool get isEmpty => download.isEmpty && uploads.isEmpty;
}

const _urlPattern = r'''https?://[^\s"'<>,\]\}]+''';

String _esc(String s) => s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

/// 生成可直接复用的 TOML：下载 `endpoints` + 上传 `upload`，同时写一份
/// `download`/`upload_urls` 别名，兼容只认其中一种键名的第三方工具。
String encodeSpeedToml({
  required List<String> download,
  required List<String> uploads,
}) {
  final b = StringBuffer()
    ..writeln('# NetPulse 测速地址配置')
    ..writeln('# endpoints/download = 下载地址; upload/upload_urls = 上传地址')
    ..writeln('version = 1')
    ..writeln();
  b.writeln('upload = [');
  for (final e in uploads) {
    b.writeln('  "${_esc(e)}",');
  }
  b.writeln(']');
  b.writeln();
  b.writeln('endpoints = [');
  for (final e in download) {
    b.writeln('  "${_esc(e)}",');
  }
  b.writeln(']');
  return b.toString();
}

/// 从任意文本里提取 HTTP(S) URL 并按段落归类。
/// 返回 (download, uploads)。[preferUploadContext] 决定无法判断归属时的兜底。
List<String> _extractUrlsBySection(
  String text,
  String Function(String line) sectionOf,
) {
  final result = <String>[];
  for (final line in text.split('\n')) {
    final section = sectionOf(line);
    for (final m in RegExp(_urlPattern).allMatches(line)) {
      final url = m
          .group(0)!
          .replaceAll(RegExp(r'["\],;]+$'), '')
          .replaceAll(RegExp(r'^["\[]+'), '')
          .trim();
      if (Uri.tryParse(url)?.host.isNotEmpty != true) continue;
      result.add(section == 'upload' ? 'U$url' : url);
    }
  }
  return result;
}

SpeedTomlConfig decodeSpeedToml(String text) {
  final download = <String>[];
  final uploads = <String>[];

  // 括号数组可能跨行：先折叠 —— 追踪每行是否处于未闭合的 `= [` 数组内。
  final lines = text.split('\n');
  final flattened = <String>[];
  var buffer = '';
  var depth = 0;
  for (final raw in lines) {
    final line = raw.trim();
    if (depth > 0) {
      buffer += ' $line';
      final opens = '['.allMatches(line).length;
      final closes = ']'.allMatches(line).length;
      depth += opens - closes;
      if (depth <= 0) {
        flattened.add(buffer);
        buffer = '';
        depth = 0;
      }
      continue;
    }
    final opens = '['.allMatches(line).length;
    final closes = ']'.allMatches(line).length;
    // 只有赋值行的数组才跨行（[section] 头开闭相等不折叠）
    final isAssign = RegExp(r'^\s*[A-Za-z_][\w-]*\s*=').hasMatch(line);
    if (isAssign && opens > closes) {
      depth = opens - closes;
      buffer = line;
      continue;
    }
    flattened.add(line);
  }
  if (buffer.isNotEmpty) flattened.add(buffer);

  final uploadKey = RegExp(
    r'^\s*(upload_urls?|uploads?|up_?urls?|up)\s*=',
    caseSensitive: false,
  );
  final downloadKey = RegExp(
    r'^\s*(endpoints?|downloads?|urls?|servers?|dl)\s*=',
    caseSensitive: false,
  );

  String sectionOf(String line) {
    final lower = line.toLowerCase();
    if (uploadKey.hasMatch(lower)) return 'upload';
    if (downloadKey.hasMatch(lower)) return 'download';
    // 无键名的裸行：看是否处于 [upload] / [download] TOML 段落之后
    return '';
  }

  var currentSection = '';
  for (final line in flattened) {
    final sectionMatch =
        RegExp(r'^\s*\[\s*\.?\s*([A-Za-z_][\w-]*)\s*\]\s*$').firstMatch(line);
    if (sectionMatch != null) {
      final name = sectionMatch.group(1)!.toLowerCase();
      currentSection =
          (name == 'upload' || name == 'uploads' || name == 'up') ? 'upload' : 'download';
      continue;
    }
    String sectionOf(String line) {
      final lower = line.toLowerCase();
      if (uploadKey.hasMatch(lower)) return 'upload';
      if (downloadKey.hasMatch(lower)) {
        // 显式 [upload] 段内的通用键名（urls/servers）仍归上传；
        // 但明确的 download/endpoints 键始终是下载。
        if (currentSection == 'upload' &&
            !RegExp(r'^\s*(endpoints?|downloads?|dl)\s*=', caseSensitive: false).hasMatch(lower)) {
          return 'upload';
        }
        return 'download';
      }
      return '';
    }

    String section = sectionOf(line);
    if (section.isEmpty) section = currentSection;
    for (final m in RegExp(_urlPattern).allMatches(line)) {
      final url = m
          .group(0)!
          .replaceAll(RegExp(r'''["',\]]+$'''), '')
          .trim();
      if (Uri.tryParse(url)?.host.isNotEmpty != true) continue;
      if (section == 'upload') {
        uploads.add(url);
      } else {
        download.add(url);
      }
    }
  }

  // 纯 URL 列表兜底：没有任何键名可判断时全部当下载地址。
  if (download.isEmpty && uploads.isEmpty) {
    for (final m in RegExp(_urlPattern).allMatches(text)) {
      final url = m.group(0)!.trim();
      if (Uri.tryParse(url)?.host.isNotEmpty == true) download.add(url);
    }
  }

  final seen = <String>{};
  return SpeedTomlConfig(
    download: download.where(seen.add).toList(),
    uploads: uploads.toSet().toList(),
  );
}
