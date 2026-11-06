// Whether Frame's player draws through the video surface (packages/frame_video): the video
// engine (libmpv) draws with mpv's best renderer (gpu-next: HDR, Dolby Vision, smooth motion)
// into a window kept just under Frame's, and Frame's window is see-through behind the player's
// controls. Windows always; Linux when Frame runs in X11 mode (the AppImage always starts it
// that way). Elsewhere, and if the surface can't be made, the player draws the video inside
// Frame's window instead (normal picture, no HDR).

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:frame_video/frame_video.dart';

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
bool get surfaceWanted => FrameVideo.supported && (!Platform.isLinux || runningInX11);

/// Set when the surface couldn't be used (shown once as a banner by the app).
final ValueNotifier<String?> surfacePlayerSkipped = ValueNotifier(null);
