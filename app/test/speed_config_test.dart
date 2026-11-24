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
    expect(cfg.uploads, isNot(contains('https://example.com/help')));
  });

  test('single string upload value', () {
    const text = 'upload = "https://x.com/up"\nendpoints = ["https://y.com/dl"]';
    final cfg = decodeSpeedToml(text);
    expect(cfg.uploads, ['https://x.com/up']);
    expect(cfg.download, ['https://y.com/dl']);
  });

  test('multiline arrays', () {
    const text = '''
endpoints = [
  "https://a.com/1.bin",
  "https://b.com/2.bin",
]
upload = [
  "https://u.com/up",
]
''';
    final cfg = decodeSpeedToml(text);
    expect(cfg.download, ['https://a.com/1.bin', 'https://b.com/2.bin']);
    expect(cfg.upload, 'https://u.com/up');
  });

  test('toml sections [download] / [upload]', () {
    const text = '''
[download]
urls = ["https://a.com/x"]
[upload]
urls = ["https://b.com/y"]
''';
    final cfg = decodeSpeedToml(text);
    expect(cfg.download, contains('https://a.com/x'));
    expect(cfg.upload, 'https://b.com/y');
  });

  test('alias keys download / upload_urls', () {
    const text = 'download = ["https://a.com/1"]\nupload_urls = ["https://b.com/2"]';
    final cfg = decodeSpeedToml(text);
    expect(cfg.download, ['https://a.com/1']);
    expect(cfg.uploads, ['https://b.com/2']);
  });

  test('plain URL list fallback', () {
    const text = 'https://a.com/1.bin\nhttps://b.com/2.bin';
    final cfg = decodeSpeedToml(text);
    expect(cfg.download.length, 2);
    expect(cfg.uploads, isEmpty);
  });
}
