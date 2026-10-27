// Built-in controller support: PS5, Xbox, Steam Controller and most others, no Steam needed.
//
// The controller is turned into the same keys the app already understands, sent to whatever
// is selected on screen, so every screen works with it without its own controller code:
//   D-pad or left stick  -> arrow keys (held = repeats, like a TV remote)
//   Cross / A            -> Enter (select)
//   Circle / B           -> Escape (back)
//   Options / Menu       -> play or pause (in the player)
//   Triangle / Y         -> the menu of the screen (Home: your profile; player: info)
//   Square / X           -> delete a letter (on-screen keyboard)
//   L1 / R1  (LB / RB)   -> skip back 10 s / forward 30 s (in the player)
//
// While a controller is in use, a small legend in the bottom right shows which button does
// what, with PlayStation or Xbox symbols to match the controller. Moving the mouse or typing
// hides it again.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';

import 'banners.dart' show bannerHandlesKey;
import 'ui.dart' show toggleFullScreen, focusLabels, fullScreen, isDesktop;

enum PadStyle { playstation, xbox }

enum PadButton { select, back, playPause, skip, fullScreen, menu, delete }

class PadHint {
  const PadHint(this.button, this.label);
  final PadButton button;
  final String label;
}

/// True while the controller is the last thing used.
final ValueNotifier<bool> padActive = ValueNotifier(false);

/// Which symbols to draw in the legend.
final ValueNotifier<PadStyle> padStyle = ValueNotifier(PadStyle.playstation);

// ---------- Reading the controller ----------

class GamepadInput {
  static StreamSubscription<NormalizedGamepadEvent>? _events;
  static final Map<String, PadStyle> _styles = {};
  static final Set<String> _ignored = {};
  static final Set<String> _touchpads = {};
  static bool _touchpadDown = false;
  static final Set<GamepadButton> _down = {};
  static Timer? _repeat;
  static LogicalKeyboardKey? _held; // direction currently held, from the d-pad or the stick
  static LogicalKeyboardKey? _stickDir;
  static double _lx = 0, _ly = 0;
  static double _drift = 0;
  static LogicalKeyboardKey? _hatV, _hatH; // d-pad directions held, when it's an axis
  static const _dpad = {
    GamepadButton.dpadUp,
    GamepadButton.dpadDown,
    GamepadButton.dpadLeft,
    GamepadButton.dpadRight,
  };
  static FocusNode? _lastLogged;

  static const _firstRepeat = Duration(milliseconds: 380);
  static const _nextRepeat = Duration(milliseconds: 110);

  static void start() {
    if (_events != null) return;
    try {
      _events = Gamepads.normalizedEvents.listen(_onEvent, onError: (e) => debugPrint('Controller: $e'));
      Gamepads.onConnected.listen((_) => _readNames());
      // The touchpad is its own device: its movement is ignored, but a press of it switches
      // full screen, if Linux passes the press to us at all.
      Gamepads.events.listen((e) {
        if (!_touchpads.contains(e.gamepadId) || e.type != KeyType.button) return;
        final pressed = e.value.abs() > 0.5;
        if (pressed == _touchpadDown) return;
        _touchpadDown = pressed;
        debugPrint('Controller: touchpad ${pressed ? 'pressed' : 'released'} (button ${e.key})');
        if (pressed) {
          padActive.value = true;
          toggleFullScreen();
        }
      }, onError: (_) {});
      // A controller that turns off (or runs out of battery) mid-press would otherwise leave
      // a direction held down, scrolling forever.
      Gamepads.onDisconnected.listen((_) => releaseAll());
      _readNames();
    } catch (e) {
      debugPrint('Controller support unavailable: $e');
      return;
    }
    // Real mouse use switches back to mouse mode: a click, the wheel, or moving it a good
    // distance. A little drift (a bumped desk, the controller's touchpad) is ignored, so it
    // can't steal focus from the controller.
    GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
      if (!padActive.value) return;
      if (event is PointerDownEvent || event is PointerScrollEvent) {
        padActive.value = false;
      } else if (event is PointerHoverEvent || event is PointerMoveEvent) {
        _drift += event.delta.distance;
        if (_drift > 200) padActive.value = false;
      }
    });
    padActive.addListener(() {
      if (padActive.value) _drift = 0;
    });
    HardwareKeyboard.instance.addHandler((_) {
      padActive.value = false;
      return false;
    });
    // Log what's selected after each change, so a navigation problem shows up in the terminal.
    FocusManager.instance.addListener(() {
      final f = FocusManager.instance.primaryFocus;
      if (f != _lastLogged) {
        _lastLogged = f;
        final label = f == null ? null : focusLabels[f];
        debugPrint('Focus: ${label ?? f?.context?.widget.runtimeType ?? 'nothing'}');
      }
    });
  }

  static Future<void> _readNames() async {
    try {
      for (final pad in await Gamepads.list()) {
        final name = '${pad.name}'.toLowerCase();
        // The PS5 controller also shows up as a touchpad and a motion sensor. Those aren't
        // for navigating and send updates nonstop, so they're ignored entirely.
        if (['touchpad', 'motion', 'accelerometer', 'gyro'].any(name.contains)) {
          _ignored.add(pad.id);
          if (name.contains('touchpad')) _touchpads.add(pad.id);
          debugPrint('Controller part ignored: ${pad.name}');
          continue;
        }
        // Valve (Steam Controller, Steam Deck) uses A/B/X/Y like Xbox, so it gets the letters.
        final valve = pad.vendorId == 0x28de || ['steam', 'valve'].any(name.contains);
        final sony = !valve &&
            (pad.vendorId == 0x054c ||
                ['sony', 'playstation', 'dualsense', 'dualshock', 'wireless controller'].any(name.contains));
        _styles[pad.id] = sony ? PadStyle.playstation : PadStyle.xbox;
        final kind = valve ? 'Steam' : (sony ? 'PlayStation' : 'Xbox-style');
        debugPrint('Controller found: ${pad.name} ($kind, vendor ${pad.vendorId})');
      }
    } catch (e) {
      debugPrint('Controller list failed: $e');
    }
  }

  static void _onEvent(NormalizedGamepadEvent e) {
    // The controller sends a constant stream of tiny updates (sticks resting slightly off
    // center, triggers, touchpad, motion sensors). Drop everything that isn't a button or
    // the left stick right away, before doing any work.
    if (_ignored.contains(e.gamepadId)) return;
    final axis = e.axis;
    if (axis != null && axis != GamepadAxis.leftStickX && axis != GamepadAxis.leftStickY) return;
    if (axis != null) {
      if (axis == GamepadAxis.leftStickX) _lx = e.value;
      if (axis == GamepadAxis.leftStickY) _ly = e.value;
      // Resting near the center with no direction held: nothing to do.
      if (_stickDir == null && _lx.abs() < 0.6 && _ly.abs() < 0.6) return;
      _onStick();
      return;
    }

    final style = _styles[e.gamepadId];
    if (style != null && padStyle.value != style) padStyle.value = style;

    final button = e.button;

    // On Linux the PlayStation d-pad is one up/down axis and one left/right axis, not four
    // buttons. Read its raw direction (minus = up or left, plus = down or right) so Up can
    // never come out as Down.
    if (button != null && _dpad.contains(button) && e.rawEvent.type == KeyType.analog) {
      final raw = e.rawEvent.value;
      final vertical = button == GamepadButton.dpadUp || button == GamepadButton.dpadDown;
      final LogicalKeyboardKey? dir = raw < -0.5
          ? (vertical ? LogicalKeyboardKey.arrowUp : LogicalKeyboardKey.arrowLeft)
          : raw > 0.5
              ? (vertical ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.arrowRight)
              : null;
      final held = vertical ? _hatV : _hatH;
      if (dir == held) return;
      debugPrint('Controller: d-pad ${dir?.keyLabel ?? 'released'} (axis, raw $raw)');
      if (held != null) _direction(held, false);
      if (vertical) {
        _hatV = dir;
      } else {
        _hatH = dir;
      }
      if (dir != null) {
        padActive.value = true;
        _direction(dir, true);
      }
      return;
    }

    if (button != null) {
      // Some controllers report the d-pad as -1 / +1 instead of 0 / 1, so either counts as pressed.
      final pressed = e.value.abs() > 0.5;
      if (pressed != _down.contains(button)) debugPrint('Controller: ${button.name} ${pressed ? 'down' : 'up'}');
      if (pressed == _down.contains(button)) return; // ignore repeats of the same state
      pressed ? _down.add(button) : _down.remove(button);
      padActive.value = true;
      _onButton(button, pressed);
    }
  }

  static void _onButton(GamepadButton button, bool pressed) {
    switch (button) {
      case GamepadButton.dpadUp:
        _direction(LogicalKeyboardKey.arrowUp, pressed);
      case GamepadButton.dpadDown:
        _direction(LogicalKeyboardKey.arrowDown, pressed);
      case GamepadButton.dpadLeft:
        _direction(LogicalKeyboardKey.arrowLeft, pressed);
      case GamepadButton.dpadRight:
        _direction(LogicalKeyboardKey.arrowRight, pressed);
      case GamepadButton.a:
        if (pressed) _send(LogicalKeyboardKey.enter);
      case GamepadButton.b:
        if (pressed) _send(LogicalKeyboardKey.escape);
      case GamepadButton.y:
        if (pressed) _send(LogicalKeyboardKey.contextMenu);
      case GamepadButton.x:
        if (pressed) _send(LogicalKeyboardKey.delete);
      case GamepadButton.start:
        if (pressed) _send(LogicalKeyboardKey.mediaPlayPause);
      case GamepadButton.leftBumper:
        if (pressed) _send(LogicalKeyboardKey.mediaRewind);
      case GamepadButton.rightBumper:
        if (pressed) _send(LogicalKeyboardKey.mediaFastForward);
      // Create (PlayStation) or View (Xbox) switches full screen. The touchpad press counts
      // too when Linux passes it to the controller (often it goes to the mouse instead).
      case GamepadButton.touchpad:
      case GamepadButton.back:
        if (pressed) toggleFullScreen();
      default:
        break;
    }
  }

  // Lets go of everything: no direction held, no repeat running.
  static void releaseAll() {
    _repeat?.cancel();
    _repeat = null;
    _held = null;
    _stickDir = null;
    _hatV = null;
    _hatH = null;
    _lx = 0;
    _ly = 0;
    _down.clear();
  }

  // The stick counts as a direction once pushed past 60%, and lets go below 35%,
  // so it never flickers between two directions.
  static void _onStick() {
    LogicalKeyboardKey? dir = _stickDir;
    final ax = _lx.abs(), ay = _ly.abs();
    if (ax < 0.35 && ay < 0.35) {
      dir = null;
    } else if (ax > 0.6 || ay > 0.6) {
      if (ax > ay) {
        dir = _lx > 0 ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
      } else {
        dir = _ly > 0 ? LogicalKeyboardKey.arrowUp : LogicalKeyboardKey.arrowDown;
      }
    }
    if (dir == _stickDir) return;
    if (_stickDir != null) _direction(_stickDir!, false);
    _stickDir = dir;
    if (dir != null) {
      padActive.value = true;
      _direction(dir, true);
    }
  }

  static void _direction(LogicalKeyboardKey key, bool pressed) {
    if (pressed) {
      _repeat?.cancel();
      _held = key;
      _send(key);
      _repeat = Timer(_firstRepeat, () {
        _repeat = Timer.periodic(_nextRepeat, (_) {
          if (_held == key) _send(key, repeat: true);
        });
      });
    } else if (_held == key) {
      _held = null;
      _repeat?.cancel();
      _repeat = null;
    }
  }

  static final Map<LogicalKeyboardKey, PhysicalKeyboardKey> _physical = {
    LogicalKeyboardKey.arrowUp: PhysicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown: PhysicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft: PhysicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight: PhysicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.enter: PhysicalKeyboardKey.enter,
    LogicalKeyboardKey.escape: PhysicalKeyboardKey.escape,
    LogicalKeyboardKey.contextMenu: PhysicalKeyboardKey.contextMenu,
    LogicalKeyboardKey.delete: PhysicalKeyboardKey.delete,
    LogicalKeyboardKey.mediaPlayPause: PhysicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.mediaRewind: PhysicalKeyboardKey.mediaRewind,
    LogicalKeyboardKey.mediaFastForward: PhysicalKeyboardKey.mediaFastForward,
  };

  // Hands the key to the selected widget, then to each widget around it, exactly the way
  // Flutter delivers a real key press, stopping at the first one that uses it.
  /// While a video plays in the mpv window, its screen takes the controller's buttons
  /// directly (Frame's own window isn't in front, so it may not have keyboard focus).
  static bool Function(LogicalKeyboardKey key)? keyOverride;

  static void _send(LogicalKeyboardKey key, {bool repeat = false}) {
    // A notification banner with an action (Triangle) comes first, whatever is selected.
    if (!repeat && bannerHandlesKey(key)) return;
    final override = keyOverride;
    if (override != null && override(key)) return;
    final physical = _physical[key]!;
    final time = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);
    final KeyEvent event = repeat
        ? KeyRepeatEvent(physicalKey: physical, logicalKey: key, timeStamp: time)
        : KeyDownEvent(physicalKey: physical, logicalKey: key, timeStamp: time);

    // Safety net: if nothing on screen is selected (focus got lost), the first press just
    // selects something again instead of doing nothing.
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || (primary is FocusScopeNode && primary.focusedChild == null)) {
      debugPrint('Controller: focus was lost, selecting the first item again');
      final scope = primary is FocusScopeNode ? primary : FocusManager.instance.rootScope;
      final first = scope.traversalDescendants.where((n) => n.canRequestFocus && n.context != null);
      if (first.isNotEmpty) first.first.requestFocus();
      return;
    }

    FocusNode? node = primary;
    while (node != null) {
      final handler = node.onKeyEvent;
      if (handler != null) {
        final result = handler(node, event);
        if (result == KeyEventResult.handled || result == KeyEventResult.skipRemainingHandlers) return;
      }
      node = node.parent;
    }
  }
}

// ---------- Which hints each screen shows ----------

class _HintsEntry {
  _HintsEntry(this.hints);
  List<PadHint> hints;
}

final List<_HintsEntry> _hintStack = [];
final ValueNotifier<int> _hintsChanged = ValueNotifier(0);

/// "Full screen" or "Window", depending on which one the touchpad / View button switches to.
PadHint fullScreenHint() => PadHint(PadButton.fullScreen, fullScreen.value ? 'Window' : 'Full screen');

/// Lets a screen choose its own legend. The newest screen on top wins.
/// An empty list hides the legend (the player does this while the video is clean).
class PadHints extends StatefulWidget {
  const PadHints({super.key, required this.hints, required this.child});
  final List<PadHint> hints;
  final Widget child;

  @override
  State<PadHints> createState() => _PadHintsState();
}

class _PadHintsState extends State<PadHints> {
  late final _HintsEntry _entry = _HintsEntry(widget.hints);

  @override
  void initState() {
    super.initState();
    _hintStack.add(_entry);
    _bump();
  }

  @override
  void didUpdateWidget(PadHints old) {
    super.didUpdateWidget(old);
    // Only redraw the legend when the hints really changed, not every time the screen redraws.
    final same = old.hints.length == widget.hints.length &&
        List.generate(old.hints.length, (i) => i).every(
            (i) => old.hints[i].button == widget.hints[i].button && old.hints[i].label == widget.hints[i].label);
    _entry.hints = widget.hints;
    if (!same) _bump();
  }

  @override
  void dispose() {
    _hintStack.remove(_entry);
    _bump();
    super.dispose();
  }

  void _bump() => WidgetsBinding.instance.addPostFrameCallback((_) => _hintsChanged.value++);

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Tells the legend when screens open and close, so Back only shows when there is somewhere to go.
class PadRouteWatcher extends NavigatorObserver {
  void _changed() => WidgetsBinding.instance.addPostFrameCallback((_) => _hintsChanged.value++);
  @override
  void didPush(Route route, Route? previousRoute) => _changed();
  @override
  void didPop(Route route, Route? previousRoute) => _changed();
  @override
  void didRemove(Route route, Route? previousRoute) => _changed();
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) => _changed();
}

// ---------- The legend ----------

/// Sits above every screen. Shows the hints only while the controller is being used.
class PadLegend extends StatelessWidget {
  const PadLegend({super.key, required this.navigatorKey});
  final GlobalKey<NavigatorState> navigatorKey;

  List<PadHint> _current() {
    if (_hintStack.isNotEmpty) return _hintStack.last.hints;
    final canGoBack = navigatorKey.currentState?.canPop() ?? false;
    return [
      const PadHint(PadButton.select, 'Select'),
      if (canGoBack) const PadHint(PadButton.back, 'Back'),
      if (!canGoBack) const PadHint(PadButton.menu, 'Profile'),
      if (isDesktop) fullScreenHint(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final s = (size.height / 1080).clamp(0.6, 2.0);
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([padActive, padStyle, _hintsChanged, fullScreen]),
        builder: (context, _) {
          // The full screen hint always shows what the button will do right now.
          final hints = [
            for (final h in _current()) h.button == PadButton.fullScreen ? fullScreenHint() : h,
          ];
          final show = padActive.value && hints.isNotEmpty;
          return Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: EdgeInsets.only(right: 40 * s, bottom: 28 * s),
              child: AnimatedOpacity(
                opacity: show ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 18 * s, vertical: 10 * s),
                  decoration: BoxDecoration(
                    color: const Color(0xFF06080B).withOpacity(0.72),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    for (var i = 0; i < hints.length; i++) ...[
                      if (i > 0) SizedBox(width: 26 * s),
                      PadGlyph(hints[i].button, style: padStyle.value, size: 30 * s),
                      SizedBox(width: 10 * s),
                      Text(
                        hints[i].label,
                        style: TextStyle(fontFamily: 'Hanken Grotesk', 
                          fontSize: 19 * s,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFF4F5F7),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One button symbol: PlayStation shapes or Xbox letters, drawn so they look the same everywhere.
class PadGlyph extends StatelessWidget {
  const PadGlyph(this.button, {super.key, required this.style, required this.size});
  final PadButton button;
  final PadStyle style;
  final double size;

  @override
  Widget build(BuildContext context) {
    const fg = Color(0xFFF4F5F7);
    const bg = Color(0x2EF4F5F7);
    final ps = style == PadStyle.playstation;

    Widget pill(String text) => Container(
          height: size,
          padding: EdgeInsets.symmetric(horizontal: size * 0.32),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size * 0.3)),
          child: Text(text,
              style: TextStyle(fontFamily: 'Hanken Grotesk', 
                  fontSize: size * 0.46, fontWeight: FontWeight.w800, color: fg, decoration: TextDecoration.none)),
        );

    switch (button) {
      case PadButton.playPause:
        return Container(
          height: size,
          padding: EdgeInsets.symmetric(horizontal: size * 0.22),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size * 0.3)),
          child: Icon(Icons.menu_rounded, size: size * 0.62, color: fg),
        );
      // The Create button (PlayStation: the small oval left of the touchpad) or the View
      // button (Xbox: two overlapping squares).
      case PadButton.fullScreen:
        return ps
            ? Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: bg, shape: BoxShape.circle),
                child: Container(
                  width: size * 0.3,
                  height: size * 0.56,
                  decoration: BoxDecoration(
                    border: Border.all(color: fg, width: size * 0.07),
                    borderRadius: BorderRadius.circular(size),
                  ),
                ),
              )
            : Container(
                width: size,
                height: size,
                decoration: const BoxDecoration(color: bg, shape: BoxShape.circle),
                child: Icon(Icons.filter_none_rounded, size: size * 0.5, color: fg),
              );
      case PadButton.skip:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          pill(ps ? 'L1' : 'LB'),
          SizedBox(width: size * 0.18),
          pill(ps ? 'R1' : 'RB'),
        ]);
      case PadButton.delete:
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: ps
              ? Container(
                  width: size * 0.42,
                  height: size * 0.42,
                  decoration: BoxDecoration(
                    border: Border.all(color: fg, width: size * 0.07),
                    borderRadius: BorderRadius.circular(size * 0.04),
                  ),
                )
              : Text('X',
                  style: TextStyle(fontFamily: 'Hanken Grotesk',
                      fontSize: size * 0.52, fontWeight: FontWeight.w800, color: fg, decoration: TextDecoration.none)),
        );
      case PadButton.menu:
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: ps
              ? CustomPaint(size: Size.square(size * 0.48), painter: _PsTriangle())
              : Text('Y',
                  style: TextStyle(fontFamily: 'Hanken Grotesk',
                      fontSize: size * 0.52, fontWeight: FontWeight.w800, color: fg, decoration: TextDecoration.none)),
        );
      case PadButton.select:
      case PadButton.back:
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: ps
              ? CustomPaint(size: Size.square(size * 0.46), painter: _PsShape(button == PadButton.select))
              : Text(button == PadButton.select ? 'A' : 'B',
                  style: TextStyle(fontFamily: 'Hanken Grotesk', 
                      fontSize: size * 0.52, fontWeight: FontWeight.w800, color: fg, decoration: TextDecoration.none)),
        );
    }
  }
}

class _PsShape extends CustomPainter {
  _PsShape(this.cross);
  final bool cross;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFF4F5F7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.16
      ..strokeCap = StrokeCap.round;
    if (cross) {
      canvas.drawLine(Offset.zero, Offset(size.width, size.height), paint);
      canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), paint);
    } else {
      canvas.drawCircle(size.center(Offset.zero), size.width / 2, paint);
    }
  }

  @override
  bool shouldRepaint(_PsShape old) => old.cross != cross;
}

class _PsTriangle extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFF4F5F7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.14
      ..strokeJoin = StrokeJoin.round;
    final h = size.height;
    canvas.drawPath(
        Path()
          ..moveTo(size.width / 2, h * 0.08)
          ..lineTo(size.width, h * 0.92)
          ..lineTo(0, h * 0.92)
          ..close(),
        paint);
  }

  @override
  bool shouldRepaint(_PsTriangle old) => false;
}
