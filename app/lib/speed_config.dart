/// 测速地址的轻量 TOML 配置。
///
/// 兼容 endpoints / urls 数组、upload 字符串或 upload 数组；
/// 解析时只提取 HTTP(S) URL，避免引入额外 TOML 依赖。
class SpeedTomlConfig {
  const SpeedTomlConfig({required this.download, required this.uploads});

  final List<String> download;
  final List<String> uploads;

  String? get upload => uploads.isEmpty ? null : uploads.first;
}

const _urlPattern = r'''https?://[^\s"'<>,\]]+''';

String encodeSpeedToml({
  required List<String> download,
  required List<String> uploads,
}) {
  String esc(String s) => s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  final b = StringBuffer()
    ..writeln('# NetPulse 测速地址配置')
    ..writeln('version = 1')
    ..writeln()
    ..writeln('upload = [');
  for (final e in uploads) {
    b.writeln('  "${esc(e)}",');
  }
  b.writeln(']');
  b.writeln();
  b.writeln('endpoints = [');
  for (final e in download) {
    b.writeln('  "${esc(e)}",');
  }
  b.writeln(']');
  return b.toString();
}

SpeedTomlConfig decodeSpeedToml(String text) {
  String clean(String s) => s.replaceAll(RegExp(r'["\\,]+$'), '').trim();
  final urls = RegExp(_urlPattern)
      .allMatches(text)
      .map((m) => clean(m.group(0)!))
      .where((e) => Uri.tryParse(e)?.host.isNotEmpty == true)
      .toList();
  final uploads = <String>[];
  final download = <String>[];
  for (final line in text.split('\n')) {
    final lower = line.toLowerCase();
    final matches = RegExp(_urlPattern).allMatches(line);
    if (matches.isEmpty) continue;
    final url = clean(matches.first.group(0)!);
    if (lower.contains('upload') || lower.contains('上传')) {
      uploads.add(url);
    } else {
      download.add(url);
    }
  }
  if (download.isEmpty) {
    for (final u in urls) {
      if (!uploads.contains(u)) download.add(u);
    }
  }
  final seen = <String>{};
  return SpeedTomlConfig(
    download: download.where(seen.add).toList(),
    uploads: uploads.where((e) => e.isNotEmpty).toList()..sort(),
  );
}
