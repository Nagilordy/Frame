// Shared look and behavior for every TV-style screen: colors, text styles, the 1920x1080 canvas,
// focusable cards and buttons, and the top tabs built from my Jellyfin libraries.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'gamepad.dart' show padActive;

// ---------- Full screen (PC only) ----------

final bool isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;

// Whether the app is full screen right now, so the player button can show the right icon.
final ValueNotifier<bool> fullScreen = ValueNotifier(false);

// Full screen is a choice, never automatic (this is a PC app): F11 anywhere, the controller's
// touchpad / Create button (shown in the controller legend), the button in the player, or
// double-clicking the video.
Future<void> toggleFullScreen() {
  final override = fullScreenOverride;
  if (override != null) return override();
  return setFullScreen(!fullScreen.value);
}

// While a video plays in the mpv window, full screen applies to that window instead.
Future<void> Function()? fullScreenOverride;

Future<void> setFullScreen(bool on) async {
  if (!isDesktop) return;
  fullScreen.value = on;
  try {
    await windowManager.setFullScreen(on);
    // Check the window really did it, so a problem shows in the terminal.
    await Future.delayed(const Duration(milliseconds: 500));
    final actual = await windowManager.isFullScreen();
    debugPrint('Full screen: asked ${on ? 'on' : 'off'}, window is ${actual ? 'full screen' : 'not full screen'}');
  } catch (e) {
    fullScreen.value = !on;
    debugPrint('Full screen failed: $e');
  }
}

// ---------- Colors and text ----------

const kBg = Color(0xFF06080B);
const kFg = Color(0xFFF4F5F7);
const kMuted = Color(0xFFB9C0CB);
const kSoft = Color(0xFFD3D8E0);
const kDim = Color(0xFF8E97A6);
const kPlaceholder = Color(0xFF1C2230);

// Translucent buttons over artwork: grey glass that darkens bright pictures (white text stays
// readable on a white sky) and looks like a light veil on dark ones.
const kPillFill = Color(0x8C4A4E57);

// Text styles are made once and reused: screens ask for the same few sizes over and over.
final Map<String, TextStyle> _styleCache = {};

TextStyle tvBody(double size, {FontWeight weight = FontWeight.w500, Color color = kFg, double? height}) {
  final key = '$size|${weight.value}|${color.value}|$height';
  return _styleCache[key] ??= TextStyle(
      fontFamily: 'Hanken Grotesk',
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      decoration: TextDecoration.none);
}

final Map<double, TextStyle> _displayCache = {};

TextStyle tvDisplay(double size) => _displayCache[size] ??= TextStyle(
    fontFamily: 'Sora',
    fontSize: size,
    fontWeight: FontWeight.w700,
    color: kFg,
    letterSpacing: -0.02 * size,
    height: 1.05,
    decoration: TextDecoration.none);

// ---------- Shading over backdrops ----------

// Darkens the left side so text stays readable on any artwork. Eases out gradually, so it
// reads as a shadow, not a bar.
const kShadeLeft = LinearGradient(
  colors: [Color(0xD906080B), Color(0xB806080B), Color(0x8506080B), Color(0x4D06080B), Color(0x1A06080B), Color(0x0006080B)],
  stops: [0, 0.2, 0.38, 0.54, 0.7, 0.82],
);

// Light fade at the top and bottom edges, always on, so the peeking rows stay readable.
const kShadeTopBottom = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0x5906080B), Color(0x0006080B), Color(0x0006080B), Color(0x4006080B), Color(0xA606080B), Color(0xE606080B)],
  stops: [0, 0.18, 0.42, 0.58, 0.78, 1],
);

// A top-to-bottom dark shade that fades in and out by changing its own colours.
//
// Fading it with an opacity animation instead costs an extra full-screen layer on every frame
// of the fade (heavy at 4K). Changing the colours draws the same single gradient, just a
// little darker or lighter each frame; fully faded out, it isn't drawn at all.
class FadingShade extends StatelessWidget {
  const FadingShade({
    super.key,
    required this.visible,
    required this.duration,
    required this.curve,
    required this.alphas,
    required this.stops,
  });

  final bool visible;
  final Duration duration;
  final Curve curve;
  final List<double> alphas; // how dark at each stop when fully shown (0 to 1)
  final List<double> stops;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: visible ? 1 : 0),
        duration: duration,
        curve: curve,
        builder: (context, t, _) {
          if (t <= 0.001) return const SizedBox.shrink();
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [for (final a in alphas) kBg.withOpacity((a * t).clamp(0.0, 1.0))],
                stops: stops,
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------- Surfaces: everything that pops up ----------
//
// Frame's design has two layers (the way TV interfaces from Google, Sony and Netflix work):
//  - over the artwork (Home, show pages, the player): translucent pill buttons; selected =
//    solid white.
//  - anything that pops up (menus, panels, the keyboard, notifications): one solid dark
//    surface with soft corners and a shadow, no blur, with the same pill buttons inside.
// A thin line in your profile's colour along the top ties a surface to you. Solid surfaces
// keep text readable over any picture, and they cost far less to draw than blur.

const kSurface = Color(0xFF1A1E25);

/// The profile colour of whoever is using Frame (set when a profile opens Home).
Color kAccent = const Color(0xFF6F8CFF);

class Surface extends StatelessWidget {
  const Surface({super.key, required this.child, this.padding, this.radius = 18, this.accentLine = true, this.width});
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final bool accentLine;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final column = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (accentLine) Container(height: 4, color: kAccent),
      Flexible(child: Padding(padding: padding ?? EdgeInsets.zero, child: child)),
    ]);
    return Container(
      width: width,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 100, offset: Offset(0, 40))],
      ),
      // With no width from its place on screen (a box pinned only by a corner, like the
      // player's info box), size to the content: stretching to an unlimited width fails and the
      // box doesn't show at all.
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.hasBoundedWidth ? column : IntrinsicWidth(child: column),
      ),
    );
  }
}

/// A row inside a surface: a pill like the buttons on Home. Selected = solid white.
Widget surfaceRow(String label,
    {required bool focused, IconData? icon, bool selected = false, bool quiet = false, Widget? trailing, double height = 64}) {
  final fg = focused ? kBg : (quiet ? kMuted : kFg);
  return AnimatedContainer(
    duration: const Duration(milliseconds: 130),
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: 22),
    decoration: BoxDecoration(
      color: focused ? kFg : (quiet ? Colors.transparent : kFg.withOpacity(0.08)),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(children: [
      if (icon != null) ...[Icon(icon, size: 26, color: fg), const SizedBox(width: 16)],
      Expanded(
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tvBody(23, weight: focused || selected ? FontWeight.w700 : FontWeight.w600, color: fg)),
      ),
      if (selected) Icon(Icons.check_rounded, size: 26, color: fg),
      if (trailing != null) trailing,
    ]),
  );
}

/// Kept for the screens that still say Frost: now the same solid surface (no blur).
/// [edgeLeft]: a panel along the right edge of the screen (square corners on that side).
class Frost extends StatelessWidget {
  const Frost({super.key, required this.child, this.padding, this.radius = 0, this.edgeLeft = false});
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final bool edgeLeft;

  @override
  Widget build(BuildContext context) =>
      Surface(radius: radius > 18 ? 18 : radius, padding: padding, child: child);
}

// ---------- The TV canvas ----------

// How much bigger (or smaller) the screen is than the 1920x1080 design, so images can be
// decoded at the size they're really shown. Same look on every device.
double tvDecodeScale = 1;
int tvPx(double designPixels) => (designPixels * tvDecodeScale).ceil();

// Rounds an image size up to a step of 160 px, so small window changes reuse the same saved
// artwork instead of downloading a slightly different size.
int sizeBucket(int px) => ((px + 159) ~/ 160) * 160;

// Lays out a screen as if it were 1920x1080, scaled to the window, and stretched to fill the
// window's real shape so wider or taller windows get more room instead of black bars.
class TvCanvas extends StatelessWidget {
  const TvCanvas({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final scale = (w / 1920) < (h / 1080) ? w / 1920 : h / 1080;
      tvDecodeScale = (scale * mq.devicePixelRatio).clamp(0.5, 2.0);
      return FittedBox(
        fit: BoxFit.fill,
        child: SizedBox(width: w / scale, height: h / scale, child: child),
      );
    });
  }
}

// ---------- Reading Jellyfin items ----------

String titleOf(dynamic item) =>
    (item['Type'] == 'Episode' ? item['SeriesName'] : item['Name'])?.toString() ?? 'Untitled';

// "S2 · E5 · The Jedi" for episodes, empty otherwise.
String episodeLine(dynamic item) {
  if (item['Type'] != 'Episode') return '';
  final s = item['ParentIndexNumber'];
  final e = item['IndexNumber'];
  return [if (s != null) 'S$s', if (e != null) 'E$e', item['Name'] ?? ''].join(' · ');
}

// "4K · Dolby Vision · 7.1"
String qualityLine(dynamic item) {
  final streams = (item['MediaStreams'] as List?) ?? [];
  final video = streams.cast<dynamic>().firstWhere((s) => s['Type'] == 'Video', orElse: () => null);
  final audio = streams.cast<dynamic>().firstWhere((s) => s['Type'] == 'Audio', orElse: () => null);
  final parts = <String>[];
  if (video != null) {
    final w = (video['Width'] ?? 0) as int;
    parts.add(w >= 3200 ? '4K' : w >= 1800 ? '1080p' : w >= 1200 ? '720p' : 'SD');
    final range = (video['VideoRangeType'] ?? '').toString();
    if (range.startsWith('DOVI')) {
      parts.add('Dolby Vision');
    } else if (range == 'HDR10Plus') {
      parts.add('HDR10+');
    } else if (range == 'HDR10' || range == 'HLG') {
      parts.add(range);
    }
  }
  if (audio != null) {
    final ch = audio['Channels'] ?? 0;
    parts.add(ch >= 8 ? '7.1' : ch >= 6 ? '5.1' : 'Stereo');
  }
  return parts.join(' · ');
}

// Short badge for a poster: "4K · DV", "4K · HDR10", "1080p".
String qualityBadge(dynamic item) => qualityLine(item)
    .replaceAll('Dolby Vision', 'DV')
    .replaceAll(RegExp(r' · (7\.1|5\.1|Stereo)$'), '');

double progressOf(dynamic item) {
  final pos = (item['UserData']?['PlaybackPositionTicks'] ?? 0) as int;
  final total = (item['RunTimeTicks'] ?? 0) as int;
  if (pos <= 0 || total <= 0) return 0;
  return (pos / total).clamp(0.0, 1.0);
}

bool isWatched(dynamic item) => item['UserData']?['Played'] == true;

int minutesLeft(dynamic item) {
  final pos = (item['UserData']?['PlaybackPositionTicks'] ?? 0) as int;
  final total = (item['RunTimeTicks'] ?? 0) as int;
  return ((total - pos) / 600000000).ceil().clamp(0, 1 << 30);
}

int runtimeMinutes(dynamic item) => (((item['RunTimeTicks'] ?? 0) as int) / 600000000).round();

// ---------- Anything you can move to with arrows and press with Enter ----------

class Focusable extends StatefulWidget {
  const Focusable({
    super.key,
    required this.builder,
    required this.onSelect,
    this.onFocus,
    this.autofocus = false,
    this.focusNode,
    this.scrollAlignment,
  });

  final Widget Function(bool focused) builder;
  final VoidCallback onSelect;
  // viaMouse is true when focus came from hovering, so callers can skip automatic scrolling.
  final void Function(bool viaMouse)? onFocus;
  final bool autofocus;
  final FocusNode? focusNode;
  // Where the focused item should land in its scrolling list (0 = start, 0.5 = middle).
  // Left empty, it lands at the 120 px left margin, which suits horizontal rows.
  final double? scrollAlignment;

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  FocusNode? _own;
  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());
  bool _focused = false;
  bool _hoverRequested = false;

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: _node,
      autofocus: widget.autofocus,
      mouseCursor: SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onSelect();
          return null;
        }),
      },
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) {
          final viaMouse = _hoverRequested;
          _hoverRequested = false;
          widget.onFocus?.call(viaMouse);
          // Keyboard or controller: scroll so the focused item is in view.
          // Mouse: never scroll, or the list would move under the pointer and keep re-selecting.
          if (!viaMouse) {
            final position = Scrollable.maybeOf(context)?.position;
            final box = context.findRenderObject();
            if (position != null && box != null && position.hasViewportDimension) {
              position.ensureVisible(box,
                  alignment: widget.scrollAlignment ?? 120 / position.viewportDimension,
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic);
            }
          }
        }
      },
      // Hovering selects the item (highlight), without scrolling anything.
      onShowHoverHighlight: (hovering) {
        // While the controller is in use, the pointer never moves focus.
        if (hovering && !_node.hasFocus && !padActive.value) {
          _hoverRequested = true;
          _node.requestFocus();
        }
      },
      child: GestureDetector(onTap: widget.onSelect, child: widget.builder(_focused)),
    );
  }
}

// A rounded pill: tabs, filter chips, small buttons.
Widget tvPill(String label, {required bool focused, bool on = false, IconData? icon, double size = 22}) {
  final fill = focused ? kFg : (on ? kFg.withOpacity(0.18) : kFg.withOpacity(0.08));
  final color = focused ? kBg : (on ? kFg : kMuted);
  return AnimatedContainer(
    duration: const Duration(milliseconds: 140),
    height: 52,
    padding: const EdgeInsets.symmetric(horizontal: 22),
    decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(999)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      if (icon != null) ...[Icon(icon, size: size, color: color), const SizedBox(width: 8)],
      Text(label, style: tvBody(size, weight: on || focused ? FontWeight.w700 : FontWeight.w500, color: color)),
    ]),
  );
}

// ---------- Fixed Up / Down / Left / Right jumps between parts of a screen ----------

// Flutter normally guesses where an arrow goes from where things sit on screen. That breaks
// when parts slide around (hero layout) or aren't lined up (buttons far left, rows far right).
// A section wrapped in FocusLinks sends an arrow to a chosen place instead. Each callback
// returns true if it moved focus; false lets Flutter guess as usual.
class FocusLinks extends StatelessWidget {
  const FocusLinks({super.key, this.up, this.down, this.left, this.right, required this.child});
  final bool Function()? up, down, left, right;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        final go = key == LogicalKeyboardKey.arrowUp
            ? up
            : key == LogicalKeyboardKey.arrowDown
                ? down
                : key == LogicalKeyboardKey.arrowLeft
                    ? left
                    : key == LogicalKeyboardKey.arrowRight
                        ? right
                        : null;
        if (go != null && go()) return KeyEventResult.handled;
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

// Names for focus nodes, printed in the terminal when they get focus (debug names are
// stripped from release builds, so they're kept here instead).
final Expando<String> focusLabels = Expando('focus label');

FocusNode namedNode(String name) {
  final n = FocusNode();
  focusLabels[n] = name;
  return n;
}

// Moves focus to a node if it's on screen. Returns false if it can't.
bool focusOn(FocusNode? node) {
  if (node == null || node.context == null || !node.canRequestFocus) return false;
  node.requestFocus();
  return true;
}

// A list of focus nodes, one per item, that grows as needed and keeps each node when the
// list reloads, so focus stays put after coming back from a video.
class FocusNodeList {
  FocusNodeList([this.name = 'item']);
  final String name;
  final List<FocusNode> _nodes = [];
  FocusNode operator [](int i) {
    while (_nodes.length <= i) {
      _nodes.add(namedNode('$name ${_nodes.length + 1}'));
    }
    return _nodes[i];
  }

  bool get anyFocused => _nodes.any((n) => n.hasFocus);

  // The first one that is currently on screen.
  bool focusFirstVisible() {
    for (final n in _nodes) {
      if (focusOn(n)) return true;
    }
    return false;
  }

  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
  }
}

// ---------- Something went wrong: a short message and a Retry button ----------

class TvError extends StatelessWidget {
  const TvError({super.key, required this.message, required this.onRetry, this.label = 'Retry'});
  final String message;
  final VoidCallback onRetry;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Text(message, style: tvBody(28, color: kSoft, height: 1.35)),
      ),
      const SizedBox(height: 24),
      Focusable(
        autofocus: true,
        onSelect: onRetry,
        builder: (f) => tvPill(label, focused: f, icon: label == 'Retry' ? Icons.refresh_rounded : Icons.login_rounded, size: 24),
      ),
    ]);
  }
}

// Turns any error into a sentence for the screen.
String errorText(Object e) {
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

// ---------- Top tabs: Home + one tab per Jellyfin library ----------

class NavBar extends StatelessWidget {
  const NavBar({
    super.key,
    required this.libraries,
    required this.currentId,
    required this.onHome,
    required this.onLibrary,
    this.onFocus,
  });

  final List<dynamic> libraries;
  final String? currentId; // null = Home
  final VoidCallback onHome;
  final void Function(dynamic library) onLibrary;
  final void Function(bool viaMouse)? onFocus;

  @override
  Widget build(BuildContext context) {
    Widget tab(String label, bool selected, VoidCallback onSelect) => Focusable(
          onSelect: onSelect,
          onFocus: onFocus,
          builder: (f) => AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            decoration: BoxDecoration(
              color: f ? kFg : (selected ? kPillFill : Colors.transparent),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(label,
                style: tvBody(24,
                    weight: selected || f ? FontWeight.w700 : FontWeight.w500,
                    color: f ? kBg : (selected ? kFg : kMuted))),
          ),
        );

    return FocusTraversalGroup(
      child: Wrap(spacing: 8, children: [
        tab('Home', currentId == null, onHome),
        for (final lib in libraries)
          tab(lib['Name']?.toString() ?? 'Library', lib['Id'] == currentId, () => onLibrary(lib)),
      ]),
    );
  }
}
