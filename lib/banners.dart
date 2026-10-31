// Notifications, PS5 style: a card that slides in at the top right, under your profile, with
// a round picture, a small name in capitals, one bold line, and (when there's something to do)
// a white "Triangle Join" button. A line along the bottom runs down in the person's colour;
// when it runs out the card slides away.
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
      decoration: BoxDecoration(shape: BoxShape.circle, color: a),
      child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: tvDisplay(28).copyWith(letterSpacing: 0, color: kBg)),
    );

Widget bannerIcon(IconData icon, {Color color = kFg}) => Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: kFg.withOpacity(0.10)),
      child: Icon(icon, size: 32, color: color),
    );

void showBanner(
  BuildContext context, {
  required Widget picture,
  required String who,
  required String text,
  String? detail, // a third, quieter line (what's playing)
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
      detail: detail,
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
    this.detail,
    required this.line,
    required this.action,
    required this.onAction,
    required this.duration,
    required this.onGone,
  });
  final Widget picture;
  final String who;
  final String text;
  final String? detail;
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

  static const _card = Color(0xFF12151B);

  @override
  Widget build(BuildContext context) {
    final slide = _part(0, 0.85, Curves.easeOutCubic);
    final fade = _part(0, 0.45, Curves.easeOut);
    final pop = _part(0.2, 1, Curves.easeOutBack);
    final rise = _part(0.3, 0.9, Curves.easeOutCubic);
    final act = _part(0.5, 1, Curves.easeOutBack);

    return IgnorePointer(
      ignoring: widget.onAction == null,
      child: TvCanvas(
        child: Stack(children: [
          // Top right, just under your profile, like the PS5's notifications.
          Positioned(
            right: 120,
            top: 140,
            width: 600,
            child: AnimatedBuilder(
              animation: _in,
              builder: (_, child) => Opacity(
                opacity: fade.value.clamp(0.0, 1.0),
                child: Transform.translate(offset: Offset(80 * (1 - slide.value), 0), child: child),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(28, 26, 28, 22),
                  decoration: BoxDecoration(
                    color: _card.withOpacity(0.97),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: kFg.withOpacity(0.10)),
                    boxShadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 18))],
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
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
                                style: tvBody(18, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1.4)),
                            const SizedBox(height: 4),
                            Text(widget.text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: tvBody(26, weight: FontWeight.w700, height: 1.2)),
                            if (widget.detail != null && widget.detail!.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(widget.detail!,
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: tvBody(22, color: kSoft)),
                            ],
                          ]),
                        ),
                      ),
                    ]),
                    // What to do: a white pill with the Triangle, like the buttons on Home.
                    if (widget.action != null) ...[
                      const SizedBox(height: 20),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ScaleTransition(
                          scale: Tween(begin: 0.8, end: 1.0).animate(act),
                          alignment: Alignment.centerLeft,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: widget.onAction,
                              child: Container(
                                height: 56,
                                padding: const EdgeInsets.fromLTRB(14, 0, 24, 0),
                                decoration: BoxDecoration(color: kFg, borderRadius: BorderRadius.circular(999)),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Container(
                                    width: 32,
                                    height: 32,
                                    alignment: Alignment.center,
                                    decoration: const BoxDecoration(shape: BoxShape.circle, color: kBg),
                                    child: CustomPaint(size: const Size.square(15), painter: _Triangle()),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(widget.action!, style: tvBody(22, weight: FontWeight.w700, color: kBg)),
                                ]),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    // The line that runs down until the card leaves.
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: SizedBox(
                        height: 4,
                        child: ColoredBox(
                          color: kFg.withOpacity(0.12),
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
                    ),
                  ]),
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
