// Noticing SteamOS Gaming Mode.

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
}
