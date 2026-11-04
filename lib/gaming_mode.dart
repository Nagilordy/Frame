// SteamOS Gaming Mode (Steam Machine, Steam Deck, Bazzite and other "console mode" setups).
//
// In Gaming Mode, Steam runs every app inside Gamescope: one app at a time, full screen, with
// Steam's own controller handling, overlay and HDR. Frame notices and adjusts:
// - Frame opens full screen (there are no windows to move around).
// - The player (mpv) always opens full screen, drawn with Vulkan, so Gamescope can show it in
//   real HDR on an HDR TV (ENABLE_HDR_WSI turns on Gamescope's HDR path for that program).
// Desktop Mode, other Linux desktops, Windows and phones are unchanged.

import 'dart:io' show Platform;

/// Whether these environment settings mean "running inside Gamescope" (Gaming Mode).
/// Separate from [inGamingMode] so test/gaming_mode_test.dart can check every case.
bool isGamingModeEnvironment(Map<String, String> env) {
  if (env['XDG_CURRENT_DESKTOP']?.toLowerCase() == 'gamescope') return true;
  if ((env['GAMESCOPE_WAYLAND_DISPLAY'] ?? '').isNotEmpty) return true;
  // Started from Steam's TV interface (Big Picture / Gaming Mode).
  if (env['SteamGamepadUI'] == '1') return true;
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
      env: {
        if (hdr) 'ENABLE_HDR_WSI': '1',
      },
    );
