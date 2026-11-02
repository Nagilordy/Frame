// Which version plays: every case of the original-or-server rule.

import 'package:flutter_test/flutter_test.dart';
import 'package:player_test/playback_rules.dart';

Map<String, dynamic> movie({String range = 'SDR', String videoType = 'VideoFile', String container = 'mkv'}) => {
      'VideoType': videoType,
      'Container': container,
      'MediaStreams': [
        {'Type': 'Video', 'Width': 3840, 'VideoRangeType': range},
        {'Type': 'Audio', 'Channels': 8},
      ],
    };

void main() {
  group('Dolby Vision Profile 5', () {
    test('"DOVI" alone is Profile 5', () {
      expect(isDolbyVisionOnly(movie(range: 'DOVI')), isTrue);
    });
    test('Dolby Vision with an HDR10 or SDR picture inside is not', () {
      expect(isDolbyVisionOnly(movie(range: 'DOVIWithHDR10')), isFalse);
      expect(isDolbyVisionOnly(movie(range: 'DOVIWithSDR')), isFalse);
      expect(isDolbyVisionOnly(movie(range: 'HDR10')), isFalse);
    });
    test('no video stream, or no streams at all', () {
      expect(isDolbyVisionOnly({'MediaStreams': []}), isFalse);
      expect(isDolbyVisionOnly(<String, dynamic>{}), isFalse);
    });
    test('fewer adapting steps before the server version', () {
      expect(serverStepFor(movie(range: 'DOVI')), 1);
      expect(serverStepFor(movie()), 2);
    });
  });

  group('Discs', () {
    test('ISO, Blu-ray and DVD are discs', () {
      expect(isDisc(movie(container: 'iso')), isTrue);
      expect(isDisc(movie(videoType: 'BluRay')), isTrue);
      expect(isDisc(movie(videoType: 'Dvd')), isTrue);
    });
    test('an MKV or MP4 file is not', () {
      expect(isDisc(movie()), isFalse);
      expect(isDisc(movie(container: 'mp4')), isFalse);
    });
  });

  group('Original or server', () {
    bool server(Map<String, dynamic> item, {bool downloaded = false, String mode = 'auto', bool phone = false, int level = 0}) =>
        startWithServer(item: item, downloaded: downloaded, mode: mode, phone: phone, level: level);

    test('Automatic plays the original file', () {
      expect(server(movie()), isFalse);
      expect(server(movie(), phone: true), isFalse);
      expect(server(movie(range: 'HDR10'), phone: true), isFalse);
    });
    test('Automatic on a phone: Dolby Vision 5 uses the server version', () {
      expect(server(movie(range: 'DOVI'), phone: true), isTrue);
    });
    test('Automatic on a PC: Dolby Vision 5 plays the original (mpv fixes the colours)', () {
      expect(server(movie(range: 'DOVI')), isFalse);
    });
    test('Automatic after stuttering reaches the server step', () {
      expect(server(movie(), level: 1), isFalse);
      expect(server(movie(), level: 2), isTrue);
      expect(server(movie(range: 'DOVI'), level: 1), isTrue);
    });
    test('"Server version" always uses the server', () {
      expect(server(movie(), mode: 'server'), isTrue);
      expect(server(movie(), mode: 'server', phone: true), isTrue);
    });
    test('"Original file" always plays the original, even Dolby Vision 5 on a phone', () {
      expect(server(movie(), mode: 'original', level: 5), isFalse);
      expect(server(movie(range: 'DOVI'), mode: 'original', phone: true), isFalse);
    });
    test('discs always use the server, whatever the choice', () {
      expect(server(movie(container: 'iso')), isTrue);
      expect(server(movie(container: 'iso'), mode: 'original'), isTrue);
    });
    test('a downloaded file always plays from the device', () {
      expect(server(movie(), downloaded: true, mode: 'server'), isFalse);
      expect(server(movie(range: 'DOVI'), downloaded: true, phone: true), isFalse);
      expect(server(movie(container: 'iso'), downloaded: true), isFalse);
    });
  });
}
