// Shared look and behavior for every TV-style screen: colors, text styles, the 1920x1080 canvas,
// focusable cards and buttons, and the top tabs built from my Jellyfin libraries.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ---------- Colors and text ----------

const kBg = Color(0xFF06080B);
const kFg = Color(0xFFF4F5F7);
const kMuted = Color(0xFFB9C0CB);
const kSoft = Color(0xFFD3D8E0);
const kDim = Color(0xFF8E97A6);
const kPlaceholder = Color(0xFF1C2230);

TextStyle tvBody(double size, {FontWeight weight = FontWeight.w500, Color color = kFg, double? height}) =>
    GoogleFonts.getFont('Hanken Grotesk', fontSize: size, fontWeight: weight, color: color, height: height);

TextStyle tvDisplay(double size) => GoogleFonts.getFont('Sora',
    fontSize: size, fontWeight: FontWeight.w700, color: kFg, letterSpacing: -0.02 * size, height: 1.05);

// ---------- The TV canvas ----------

// How much bigger (or smaller) the screen is than the 1920x1080 design, so images can be
// decoded at the size they're really shown. Same look on every device.
double tvDecodeScale = 1;
int tvPx(double designPixels) => (designPixels * tvDecodeScale).ceil();

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
  return ((total - pos) / 600000000).ceil();
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
        if (hovering && !_node.hasFocus) {
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

// ---------- Top tabs: Home + one tab per Jellyfin library ----------

class NavBar extends StatelessWidget {
  const NavBar({
    super.key,
    required this.libraries,
    required this.currentId,
    required this.onHome,
    required this.onLibrary,
  });

  final List<dynamic> libraries;
  final String? currentId; // null = Home
  final VoidCallback onHome;
  final void Function(dynamic library) onLibrary;

  @override
  Widget build(BuildContext context) {
    Widget tab(String label, bool selected, VoidCallback onSelect) => Focusable(
          onSelect: onSelect,
          builder: (f) => AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            decoration: BoxDecoration(
              color: f ? kFg : (selected ? kFg.withOpacity(0.14) : Colors.transparent),
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
