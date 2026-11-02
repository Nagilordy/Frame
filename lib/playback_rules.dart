// Which version of a video to play: the original file or the version the server converts.
//
// Pure rules, no Flutter and no player: the player asks here, and test/playback_rules_test.dart
// checks every case, so a change can't quietly break one of them.

/// Dolby Vision with no HDR10 or SDR picture inside (Profile 5). Jellyfin calls it "DOVI";
/// the kinds with a fallback picture are "DOVIWithHDR10", "DOVIWithSDR" and so on.
bool isDolbyVisionOnly(dynamic item) {
  final streams = (item['MediaStreams'] as List?) ?? const [];
  for (final s in streams) {
    if (s is Map && s['Type'] == 'Video') return s['VideoRangeType'] == 'DOVI';
  }
  return false;
}

/// Disc images and disc folders (ISO, Blu-ray, DVD): they can't be streamed as one file.
bool isDisc(dynamic item) {
  final type = (item['VideoType'] ?? 'VideoFile').toString();
  final container = (item['Container'] ?? '').toString().toLowerCase();
  return type != 'VideoFile' || const ['iso', 'bluray', 'dvd'].contains(container);
}

/// The step of "adapting to this device" that means the server's version. Dolby Vision 5
/// has fewer steps before it, because lowering the original's quality doesn't fix its colours.
int serverStepFor(dynamic item) => isDolbyVisionOnly(item) ? 1 : 2;

/// True to start with the server's version, false for the original file.
///
/// - [downloaded]: the file is on this device. Always played from here, nothing else applies.
/// - [mode]: the Playback choice: 'auto', 'original' or 'server'.
/// - [phone]: iPhone, iPad or Android.
/// - [level]: how far "adapting to this device" has gone for this kind of file (0 = original
///   at full quality).
bool startWithServer({
  required dynamic item,
  required bool downloaded,
  required String mode,
  required bool phone,
  int level = 0,
}) {
  if (downloaded) return false;
  if (isDisc(item)) return true;
  if (mode == 'server') return true;
  if (mode == 'original') return false;
  // Automatic.
  if (level >= serverStepFor(item)) return true;
  // Phones can't fix Dolby Vision 5's colours (pink and green) like mpv on a PC can.
  if (phone && isDolbyVisionOnly(item)) return true;
  return false;
}
