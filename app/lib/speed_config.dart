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
  String clean(String s) => s.replaceAll(RegExp(r'["\],]+$'), '').trim();
  final uploads = <String>[];
  final download = <String>[];
  String? section;
  final uploadRe = RegExp(r'^\s*(upload|uploads|upload_url)\s*=',
      caseSensitive: false);
  final downloadRe = RegExp(r'^\s*(endpoints|download|downloads|urls)\s*=',
      caseSensitive: false);
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final lower = trimmed.toLowerCase();
    if (uploadRe.hasMatch(lower)) {
      section = 'upload';
    } else if (downloadRe.hasMatch(lower)) {
      section = 'download';
    }
    final matches = RegExp(_urlPattern).allMatches(trimmed);
    for (final m in matches) {
      final url = clean(m.group(0)!);
      if (Uri.tryParse(url)?.host.isNotEmpty != true) continue;
      final isUpload = section == 'upload' ||
          (section == null && lower.contains('upload'));
      (isUpload ? uploads : download).add(url);
    }
  }
  final seen = <String>{};
  return SpeedTomlConfig(
    download: download.where(seen.add).toList(),
    uploads: uploads.where((e) => e.isNotEmpty).toSet().toList()..sort(),
  );
}
