// Notification banners, console style: a slim solid bar that pops in at the top centre,
// with a picture, a small name in capitals, one bold line, and (when there's something to do)
// a Triangle action on the right. A line along the bottom runs down in the person's colour;
// when it runs out the banner lifts away.
//
// A banner never takes the controller away from what you're doing: you keep browsing, and
// Triangle (Y on Xbox, or a click on the action) acts on it while it's showing.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui.dart';

class _Current {
  _Current(this.entry, this.view);
  final OverlayEntry entry;
  final GlobalKey<_BannerViewState> view;
}

_Current? _current;
VoidCallback? _action;

/// Triangle / Y while a banner with an action is showing: does that action.
/// Returns true when it used the key.
bool bannerHandlesKey(LogicalKeyboardKey key) {
  final action = _action;
  if (key != LogicalKeyboardKey.contextMenu || action == null) return false;
  _action = null;
  _current?.view.currentState?.leave();
  action();
  return true;
}

/// The picture on the left: an initial on a colour (people) or an icon.
Widget bannerInitial(String name, Color a, Color b) => Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [a, b]),
      ),
      child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: tvDisplay(28).copyWith(letterSpacing: 0)),
    );

Widget bannerIcon(IconData icon, {Color color = kFg}) => Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: kFg.withOpacity(0.10)),
      child: Icon(icon, size: 32, color: color),
    );

void showBanner(
  BuildContext context, {
  required Widget picture,
  required String who,
  required String text,
  Color? line,
  String? action, // e.g. 'JOIN'
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 6),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  // One at a time: a new banner replaces the one showing.
  final old = _current;
  if (old != null) {
    old.entry.remove();
    _current = null;
  }
  _action = onAction;
  final key = GlobalKey<_BannerViewState>();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _BannerView(
      key: key,
      picture: picture,
      who: who,
      text: text,
      line: line ?? kAccent,
      action: action,
      onAction: onAction == null
          ? null
          : () {
              _action = null;
              key.currentState?.leave();
              onAction();
            },
      duration: duration,
      onGone: () {
        if (_current?.entry == entry) {
          _current = null;
          if (identical(_action, onAction)) _action = null;
        }
        entry.remove();
      },
    ),
  );
  _current = _Current(entry, key);
  overlay.insert(entry);
}

class _BannerView extends StatefulWidget {
  const _BannerView({
    super.key,
    required this.picture,
    required this.who,
    required this.text,
    required this.line,
    required this.action,
    required this.onAction,
    required this.duration,
    required this.onGone,
  });
  final Widget picture;
  final String who;
  final String text;
  final Color line;
  final String? action;
  final VoidCallback? onAction;
  final Duration duration;
  final VoidCallback onGone;

  @override
  State<_BannerView> createState() => _BannerViewState();
}

class _BannerViewState extends State<_BannerView> with TickerProviderStateMixin {
  // In: drop with a small overshoot (0.45 s). The picture pops, the text rises, the action
  // pops last. Out: lift and fade (0.3 s).
  late final AnimationController _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
  late final AnimationController _timer = AnimationController(vsync: this, duration: widget.duration);
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _in.forward().whenComplete(() {
      if (!_leaving && mounted) _timer.forward().whenComplete(leave);
    });
  }

  Future<void> leave() async {
    if (_leaving || !mounted) return;
    _leaving = true;
    _timer.stop();
    _in.duration = const Duration(milliseconds: 300);
    try {
      await _in.reverse();
    } catch (_) {}
    widget.onGone();
  }

  @override
  void dispose() {
    _in.dispose();
    _timer.dispose();
    super.dispose();
  }

  Animation<double> _part(double from, double to, Curve curve) =>
      CurvedAnimation(parent: _in, curve: Interval(from, to, curve: curve), reverseCurve: Curves.easeIn);

  @override
  Widget build(BuildContext context) {
    final drop = _part(0, 0.85, Curves.easeOutBack);
    final fade = _part(0, 0.45, Curves.easeOut);
    final pop = _part(0.25, 1, Curves.easeOutBack);
    final rise = _part(0.35, 0.9, Curves.easeOutCubic);
    final act = _part(0.55, 1, Curves.easeOutBack);

    return IgnorePointer(
      ignoring: widget.onAction == null,
      child: TvCanvas(
        child: Stack(children: [
          Positioned(
            left: 0,
            right: 0,
            top: 40,
            child: Center(
              child: AnimatedBuilder(
                animation: _in,
                builder: (_, child) => Opacity(
                  opacity: fade.value.clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(0, -140 * (1 - drop.value)),
                    child: Transform.scale(scale: 0.94 + 0.06 * drop.value, child: child),
                  ),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: Container(
                    width: 860,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: kSurface,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const [BoxShadow(color: Color(0x8C000000), blurRadius: 70, offset: Offset(0, 24))],
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 22, 16),
                        child: Row(children: [
                          ScaleTransition(
                            scale: Tween(begin: 0.4, end: 1.0).animate(pop),
                            child: SizedBox.square(dimension: 64, child: widget.picture),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: AnimatedBuilder(
                              animation: rise,
                              builder: (_, c) => Opacity(
                                opacity: rise.value.clamp(0.0, 1.0),
                                child: Transform.translate(offset: Offset(0, 10 * (1 - rise.value)), child: c),
                              ),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                                Text(widget.who.toUpperCase(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: tvBody(15, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1.2)),
                                const SizedBox(height: 4),
                                Text(widget.text,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: tvBody(24, weight: FontWeight.w700)),
                              ]),
                            ),
                          ),
                          if (widget.action != null) ...[
                            const SizedBox(width: 20),
                            Container(width: 1, height: 56, color: kFg.withOpacity(0.16)),
                            const SizedBox(width: 8),
                            ScaleTransition(
                              scale: Tween(begin: 0.8, end: 1.0).animate(act),
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  onTap: widget.onAction,
                                  child: SizedBox(
                                    width: 80,
                                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                                      Container(
                                        width: 34,
                                        height: 34,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(shape: BoxShape.circle, color: kFg.withOpacity(0.16)),
                                        child: CustomPaint(size: const Size.square(16), painter: _Triangle()),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(widget.action!.toUpperCase(),
                                          style: tvBody(14, weight: FontWeight.w700, color: kSoft).copyWith(letterSpacing: 1.1)),
                                    ]),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ]),
                      ),
                      // The line that runs down until the banner leaves.
                      SizedBox(
                        height: 4,
                        child: ColoredBox(
                          color: kFg.withOpacity(0.08),
                          child: AnimatedBuilder(
                            animation: _timer,
                            builder: (_, __) => FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: 1 - _timer.value,
                              child: ColoredBox(color: widget.line),
                            ),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Triangle extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = kFg
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.13
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
        Path()
          ..moveTo(size.width / 2, size.height * 0.1)
          ..lineTo(size.width, size.height * 0.92)
          ..lineTo(0, size.height * 0.92)
          ..close(),
        p);
  }

  @override
  bool shouldRepaint(_Triangle old) => false;
}
