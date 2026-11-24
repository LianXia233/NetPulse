import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse/speed_config.dart';

void main() {
  test('TOML round trip keeps download and upload endpoints', () {
    const downloads = [
      'https://speed.cloudflare.com/__down?bytes=50000000',
      'https://example.com/100MB.bin',
    ];
    const uploads = ['https://speed.cloudflare.com/__up'];
    final text = encodeSpeedToml(download: downloads, uploads: uploads);
    final cfg = decodeSpeedToml(text);
    expect(cfg.download, downloads);
    expect(cfg.uploads, uploads);
  });

  test('URL in comment section is not treated as upload', () {
    const text = '''
# upload 说明：https://example.com/help
upload = ["https://speed.cloudflare.com/__up"]
endpoints = ["https://example.com/file.bin"]
''';
    final cfg = decodeSpeedToml(text);
    expect(cfg.download, contains('https://example.com/file.bin'));
    expect(cfg.uploads, contains('https://speed.cloudflare.com/__up'));
  });
}
