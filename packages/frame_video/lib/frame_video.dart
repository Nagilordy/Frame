// Frame's video surface (Windows): a borderless window kept exactly under Frame's window, the
// same size, where the video engine (libmpv) draws with its own renderer, so HDR, Dolby Vision
// and smooth motion work. Frame's window turns see-through while the video plays, so its
// controls sit on top of the picture: one app, one window.
//
// Windows, and Linux when Frame runs in X11 mode (the AppImage switches to it when the preview
// is on; Gaming Mode always is). Elsewhere every call answers null / does nothing.

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class FrameVideo {
  static const _channel = MethodChannel('frame/video');

  static bool get supported => Platform.isWindows || Platform.isLinux;

  /// Creates the video surface under Frame's window and makes Frame's window see-through.
  /// Returns the surface's window handle (for mpv's "wid"), or null if it couldn't.
  static Future<int?> open() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<int>('open');
    } catch (_) {
      return null;
    }
  }

  /// Removes the surface and makes Frame's window solid again.
  static Future<void> close() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('close');
    } catch (_) {}
  }
}
