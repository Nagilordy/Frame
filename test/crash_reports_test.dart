// Crash reports never carry the server's sign-in token.

import 'package:flutter_test/flutter_test.dart';
import 'package:player_test/crash_reports.dart';

void main() {
  test('tokens are removed from addresses', () {
    expect(
      scrubSecrets('http://nas:8096/Videos/1/stream?static=true&ApiKey=abc123def'),
      'http://nas:8096/Videos/1/stream?static=true&ApiKey=…',
    );
    expect(scrubSecrets('GET /Items?api_key=SECRET&Limit=5'), 'GET /Items?api_key=…&Limit=5');
  });
  test('tokens are removed from the sign-in header', () {
    expect(
      scrubSecrets('MediaBrowser Client="Frame", Token="abc123"'),
      'MediaBrowser Client="Frame", Token="…"',
    );
  });
  test('ordinary text is left alone', () {
    expect(scrubSecrets('Playback failed: no picture'), 'Playback failed: no picture');
  });
  test('reports are off in builds without a Sentry address', () {
    expect(crashReportsOn, isFalse);
  });
}
