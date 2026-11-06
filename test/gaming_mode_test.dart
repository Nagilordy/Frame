// Noticing SteamOS Gaming Mode, and how the player is started there.

import 'package:flutter_test/flutter_test.dart';
import 'package:player_test/gaming_mode.dart';

void main() {
  test('Gaming Mode (Gamescope) is recognised', () {
    expect(isGamingModeEnvironment({'XDG_CURRENT_DESKTOP': 'gamescope'}), isTrue);
    expect(isGamingModeEnvironment({'GAMESCOPE_WAYLAND_DISPLAY': 'gamescope-0'}), isTrue);
  });
  test('Desktop Mode and other desktops are not', () {
    expect(isGamingModeEnvironment({'XDG_CURRENT_DESKTOP': 'KDE'}), isFalse);
    expect(isGamingModeEnvironment({'GAMESCOPE_WAYLAND_DISPLAY': ''}), isFalse);
    expect(isGamingModeEnvironment({'SteamDeck': '1'}), isFalse); // set in Desktop Mode too
    expect(isGamingModeEnvironment({'SteamGamepadUI': '1'}), isFalse); // Big Picture on a desktop
    expect(isGamingModeEnvironment({}), isFalse);
  });
  test('FRAME_GAMING_MODE overrides the detection', () {
    expect(isGamingModeEnvironment({'XDG_CURRENT_DESKTOP': 'gamescope', 'FRAME_GAMING_MODE': '0'}), isFalse);
    expect(isGamingModeEnvironment({'FRAME_GAMING_MODE': '1'}), isTrue);
  });
  test('the player opens full screen, with HDR through Gamescope when mpv can', () {
    final hdr = gamingModePlayer(hdr: true);
    expect(hdr.args, ['--fs', '--gpu-api=vulkan']);
    expect(hdr.env, isEmpty);
    final sdr = gamingModePlayer(hdr: false);
    expect(sdr.args, ['--fs']);
    expect(sdr.env, isEmpty);
  });
  test('Gaming Mode plays inside Frame\'s window', () {
    expect(useInAppPlayer(mpvFound: true, gamingMode: true), isTrue);
    expect(useInAppPlayer(mpvFound: true, gamingMode: true, env: {'FRAME_SEPARATE_PLAYER': '1'}), isFalse);
  });
  test('the desktop keeps the mpv window, unless mpv is missing', () {
    expect(useInAppPlayer(mpvFound: true, gamingMode: false), isFalse);
    expect(useInAppPlayer(mpvFound: false, gamingMode: false), isTrue);
    expect(useInAppPlayer(mpvFound: false, gamingMode: true, env: {'FRAME_SEPARATE_PLAYER': '1'}), isTrue);
  });
}
