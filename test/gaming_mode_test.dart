// Noticing SteamOS Gaming Mode, and how the player is started there.

import 'package:flutter_test/flutter_test.dart';
import 'package:player_test/gaming_mode.dart';

void main() {
  test('Gaming Mode (Gamescope) is recognised', () {
    expect(isGamingModeEnvironment({'XDG_CURRENT_DESKTOP': 'gamescope'}), isTrue);
    expect(isGamingModeEnvironment({'GAMESCOPE_WAYLAND_DISPLAY': 'gamescope-0'}), isTrue);
    expect(isGamingModeEnvironment({'SteamGamepadUI': '1'}), isTrue);
  });
  test('Desktop Mode and other desktops are not', () {
    expect(isGamingModeEnvironment({'XDG_CURRENT_DESKTOP': 'KDE'}), isFalse);
    expect(isGamingModeEnvironment({'GAMESCOPE_WAYLAND_DISPLAY': ''}), isFalse);
    expect(isGamingModeEnvironment({'SteamDeck': '1'}), isFalse); // set in Desktop Mode too
    expect(isGamingModeEnvironment({}), isFalse);
  });
  test('the player opens full screen, with HDR through Gamescope when mpv can', () {
    final hdr = gamingModePlayer(hdr: true);
    expect(hdr.args, ['--fs', '--gpu-api=vulkan']);
    expect(hdr.env, {'ENABLE_HDR_WSI': '1'});
    final sdr = gamingModePlayer(hdr: false);
    expect(sdr.args, ['--fs']);
    expect(sdr.env, isEmpty);
  });
}
