// SteamOS Gaming Mode (Steam Machine, Steam Deck, Bazzite and other "console mode" setups).
//
// In Gaming Mode, Steam runs every app inside Gamescope: one app at a time, full screen, with
// Steam's own controller handling, overlay and HDR. Frame notices and adjusts:
// - Frame opens full screen (there are no windows to move around).
// - Videos play inside Frame's own window (the in-app player), not in a separate mpv window:
//   Gamescope shows one window at a time, so a second window can leave the video hidden or the
//   controller talking to the wrong window. (FRAME_SEPARATE_PLAYER=1 brings the mpv window back
//   for testing; Frame then steps aside while it plays.)
// - The player (mpv) always opens full screen, drawn with Vulkan, so Gamescope can show it in
//   real HDR on an HDR TV.
// Desktop Mode, other Linux desktops, Windows and phones are unchanged.

import 'dart:io' show Platform;

/// Whether these environment settings mean "running inside Gamescope" (Gaming Mode).
/// Separate from [inGamingMode] so test/gaming_mode_test.dart can check every case.
bool isGamingModeEnvironment(Map<String, String> env) {
  // Override for testing or if detection is wrong: FRAME_GAMING_MODE=0 (off) or 1 (on).
  if (env['FRAME_GAMING_MODE'] == '0') return false;
  if (env['FRAME_GAMING_MODE'] == '1') return true;
  if (env['XDG_CURRENT_DESKTOP']?.toLowerCase() == 'gamescope') return true;
  if ((env['GAMESCOPE_WAYLAND_DISPLAY'] ?? '').isNotEmpty) return true;
  // (Not SteamGamepadUI: Steam also sets it for Big Picture on a normal desktop, where Frame
  // must behave like any desktop app.)
  return false;
}

/// Frame is running in SteamOS Gaming Mode (Linux only).
final bool inGamingMode = Platform.isLinux && isGamingModeEnvironment(Platform.environment);

/// Extra settings for mpv in Gaming Mode. [hdr]: this mpv can output HDR (0.40 or newer).
({List<String> args, Map<String, String> env}) gamingModePlayer({required bool hdr}) => (
      args: [
        '--fs',
        if (hdr) '--gpu-api=vulkan',
      ],
      // Gamescope turns on its own HDR path for programs Steam starts; nothing to add here
      // (ENABLE_HDR_WSI is for KDE's HDR layer and can break the player outside Gamescope).
      env: const <String, String>{},
    );

/// Whether videos play inside Frame's window (the in-app player) instead of a separate mpv
/// window: always in Gaming Mode (one window at a time there), and whenever mpv isn't found.
bool useInAppPlayer({required bool mpvFound, required bool gamingMode, Map<String, String> env = const {}}) {
  if (!mpvFound) return true;
  if (gamingMode) return env['FRAME_SEPARATE_PLAYER'] != '1';
  return false;
}
