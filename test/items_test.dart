// The text shown for Jellyfin items: titles, episode lines, quality, progress.

import 'package:flutter_test/flutter_test.dart';
import 'package:player_test/ui.dart';

void main() {
  final episode = {
    'Type': 'Episode',
    'Name': 'The Jedi',
    'SeriesName': 'The Mandalorian',
    'ParentIndexNumber': 2,
    'IndexNumber': 5,
    'RunTimeTicks': 36000000000, // 60 minutes
    'UserData': {'PlaybackPositionTicks': 9000000000, 'Played': false}, // 15 minutes in
    'MediaStreams': [
      {'Type': 'Video', 'Width': 3840, 'VideoRangeType': 'DOVIWithHDR10'},
      {'Type': 'Audio', 'Channels': 6},
    ],
  };

  test('an episode is titled by its show, with its own line', () {
    expect(titleOf(episode), 'The Mandalorian');
    expect(episodeLine(episode), 'S2 · E5 · The Jedi');
  });
  test('a movie is titled by its name and has no episode line', () {
    final movie = {'Type': 'Movie', 'Name': 'Dune'};
    expect(titleOf(movie), 'Dune');
    expect(episodeLine(movie), '');
    expect(titleOf(<String, dynamic>{}), 'Untitled');
  });
  test('quality line and poster badge', () {
    expect(qualityLine(episode), '4K · Dolby Vision · 5.1');
    expect(qualityBadge(episode), '4K · DV');
    expect(
      qualityLine({
        'MediaStreams': [
          {'Type': 'Video', 'Width': 1920, 'VideoRangeType': 'SDR'},
          {'Type': 'Audio', 'Channels': 2},
        ],
      }),
      '1080p · Stereo',
    );
    expect(qualityLine({'MediaStreams': []}), '');
  });
  test('progress, minutes left and length', () {
    expect(progressOf(episode), closeTo(0.25, 0.0001));
    expect(minutesLeft(episode), 45);
    expect(runtimeMinutes(episode), 60);
    expect(isWatched(episode), isFalse);
    expect(progressOf({'RunTimeTicks': 0}), 0);
  });
  test('error text drops Dart\'s "Exception: " prefix', () {
    expect(errorText(Exception('No connection')), 'No connection');
    expect(errorText('plain'), 'plain');
  });
}
