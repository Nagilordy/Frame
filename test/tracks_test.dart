// Remembered audio and subtitle choices: picking the same kind of track in the next video.

import 'package:flutter_test/flutter_test.dart';
import 'package:player_test/tracks.dart';

void main() {
  group('describing tracks', () {
    test('forced, SDH and audio description are read from the title too', () {
      final forced = TrackPrefs.describe(lang: 'ENG', title: 'English (Forced)');
      expect(forced['lang'], 'eng');
      expect(forced['forced'], isTrue);

      expect(TrackPrefs.describe(lang: 'eng', title: 'English SDH')['sdh'], isTrue);
      expect(TrackPrefs.describe(lang: 'fre', title: 'Français malentendants')['sdh'], isTrue);
      expect(TrackPrefs.describe(lang: 'eng', title: 'Audio Description')['ad'], isTrue);
      expect(TrackPrefs.describe(lang: 'eng', title: 'Director\'s commentary')['ad'], isTrue);
    });
    test('a plain track is none of those', () {
      final plain = TrackPrefs.describe(lang: 'eng', title: 'English');
      expect(plain['forced'], isFalse);
      expect(plain['sdh'], isFalse);
      expect(plain['ad'], isFalse);
    });
    test('Jellyfin streams and mpv tracks describe the same track the same way', () {
      final fromJellyfin = TrackPrefs.describeStream({'Language': 'jpn', 'Title': 'Japanese', 'IsForced': false});
      final fromMpv = TrackPrefs.describeMpv({'lang': 'jpn', 'title': 'Japanese'});
      expect(fromJellyfin, fromMpv);
    });
  });

  group('picking the best match', () {
    final english = TrackPrefs.describe(lang: 'eng', title: 'English');
    final englishSdh = TrackPrefs.describe(lang: 'eng', title: 'English SDH');
    final englishForced = TrackPrefs.describe(lang: 'eng', title: 'Forced');
    final french = TrackPrefs.describe(lang: 'fre', title: 'Français');

    test('another language never matches', () {
      expect(TrackPrefs.score(english, french), 0);
      expect(TrackPrefs.best<String>(english, [('fr', french)]), isNull);
    });
    test('the same kind of track wins over others in the same language', () {
      final candidates = [('forced', englishForced), ('sdh', englishSdh), ('full', english)];
      expect(TrackPrefs.best<String>(english, candidates), 'full');
      expect(TrackPrefs.best<String>(englishSdh, candidates), 'sdh');
      expect(TrackPrefs.best<String>(englishForced, candidates), 'forced');
    });
    test('the first of equally good matches is kept', () {
      expect(TrackPrefs.best<int>(english, [(1, english), (2, english)]), 1);
    });
  });
}
