import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse/store.dart';

void main() {
  test('DNS list dedupes aliases and keeps first spelling', () {
    final out = normalizeDnsList([
      ' 8.8.8.8 ',
      '8.8.8.8:53',
      'tls://dns.google',
      'dot://dns.google:853',
      'https://dns.google/dns-query/',
      'https://dns.google/dns-query',
      '# comment',
      '',
    ]);
    expect(out, [
      '8.8.8.8',
      'tls://dns.google',
      'https://dns.google/dns-query/',
    ]);
  });
}
