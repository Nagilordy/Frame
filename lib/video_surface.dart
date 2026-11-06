// Whether Frame's player draws through the video surface (packages/frame_video): the video
// engine (libmpv) draws with mpv's best renderer (gpu-next: HDR, Dolby Vision, smooth motion)
// into a window kept just under Frame's, and Frame's window is see-through behind the player's
// controls. Windows only for now: there it gives real HDR in a window. On Linux the player
// draws the video inside Frame's window (proven, no extra window): the X11 surface needed X11
// mode, where KDE can't show HDR anyway, and it was fragile (black picture, crashes). Real HDR
// on Linux will come through Wayland / Gaming Mode as its own project.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// FRAME_OLD_PLAYER=1, set before starting Frame, brings back the old separate mpv window: an
/// emergency way out while the new player is young, not an option in the app.
final bool oldPlayerRequested = (Platform.environment['FRAME_OLD_PLAYER'] ?? '') == '1';

/// Linux: whether Frame is running in X11 mode right now (the surface needs it).
bool get runningInX11 {
  final env = Platform.environment;
  final backend = env['GDK_BACKEND'] ?? '';
  if (backend.startsWith('x11')) return true;
  if (backend.startsWith('wayland')) return false;
  return (env['WAYLAND_DISPLAY'] ?? '').isEmpty && (env['DISPLAY'] ?? '').isNotEmpty;
}

/// Whether to try the surface on this system.
// Off for now on every system: the player draws inside Frame's window, the version that works.
// The surface (real HDR) comes back once it's been made reliable, Windows first.
bool get surfaceWanted => false;

/// Set when the surface couldn't be used (shown once as a banner by the app).
final ValueNotifier<String?> surfacePlayerSkipped = ValueNotifier(null);
