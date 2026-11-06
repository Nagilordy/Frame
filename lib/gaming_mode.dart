// SteamOS Gaming Mode (Steam Machine, Steam Deck, Bazzite and other "console mode" setups).
//
// In Gaming Mode, Steam runs every app inside Gamescope: one app at a time, full screen, with
// Steam's own controller handling and overlay. Frame notices and opens full screen (there are
// no windows to move around). Desktop Mode, other Linux desktops, Windows and phones are
// unchanged.

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
