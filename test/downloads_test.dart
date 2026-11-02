// Downloads: the saved list survives a restart, sizes read well.

import 'package:flutter_test/flutter_test.dart';
import 'package:player_test/downloads.dart';

void main() {
  test('a download is saved and read back unchanged', () {
    final d = Download(
      id: 'abc',
      item: {'Type': 'Episode', 'SeriesName': 'Frieren', 'Name': 'The Journey\'s End'},
      server: 'http://nas:8096',
      userId: 'u1',
      file: 'abc.mkv',
      status: 'paused',
      progress: 0.42,
      bytes: 1200000000,
      positionTicks: 123,
      pendingSync: true,
      added: DateTime.utc(2026, 11, 1, 12),
    );
    final back = Download.fromJson(d.toJson());
    expect(back.toJson(), d.toJson());
    expect(back.title, 'Frieren');
    expect(back.taskId, 'frame-abc');
    expect(back.done, isFalse);
  });

  test('an old or partial saved entry still loads', () {
    final d = Download.fromJson({'id': 1, 'item': {'Name': 'Dune'}, 'server': 's', 'userId': 'u', 'file': 'f'});
    expect(d.id, '1');
    expect(d.status, 'queued');
    expect(d.progress, 0);
    expect(d.positionTicks, isNull);
    expect(d.added, isNull);
    expect(d.title, 'Dune');
  });

  test('sizes', () {
    expect(formatBytes(0), '');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1500000), '1.5 MB');
    expect(formatBytes(3400000000), '3.4 GB');
    expect(formatBytes(18400000000), '18.4 GB');
    expect(formatBytes(250000000), '250 MB');
  });
}
