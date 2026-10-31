// Typing with the controller: text fields that open a console-style on-screen keyboard.
//
// With the controller, a text field is a button: Up/Down/Left/Right move past it like any
// other button, and Cross opens the keyboard at the bottom of the screen. On the keyboard:
//   D-pad / stick  move between keys        Cross      type the key
//   Square         delete a letter          Triangle   space
//   Circle         close (keeps the text)   Options    Done
// A real keyboard types into the field directly (click it, or select it with Enter), and also
// works while the on-screen keyboard is open.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gamepad.dart' show PadHint, PadButton, PadHints, padActive;
import 'ui.dart';

// ---------- The field ----------

class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    required this.label,
    required this.controller,
    this.obscure = false,
    this.autofocus = false,
    this.onSubmit,
    this.focusNode,
    this.hint,
  });

  final String label;
  final TextEditingController controller;
  final bool obscure;
  final bool autofocus;
  final VoidCallback? onSubmit; // Enter on a real keyboard, or Done on the on-screen one
  final FocusNode? focusNode; // the field as a button (what the controller moves to)
  final String? hint;

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  FocusNode? _ownOuter;
  FocusNode get _outer => widget.focusNode ?? (_ownOuter ??= FocusNode());
  // The real text box: only reached by clicking it or pressing Enter on a real keyboard,
  // never by arrows, so the controller can't get stuck inside it.
  final _edit = FocusNode(skipTraversal: true);
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _edit.addListener(() {
      if (mounted) setState(() => _editing = _edit.hasFocus);
    });
  }

  @override
  void dispose() {
    _ownOuter?.dispose();
    _edit.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (!padActive.value) {
      _edit.requestFocus();
      return;
    }
    final done = await showTvKeyboard(context,
        controller: widget.controller, label: widget.label, obscure: widget.obscure);
    if (!mounted) return;
    _outer.requestFocus();
    if (done) widget.onSubmit?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Text(widget.label, style: tvBody(21, weight: FontWeight.w600, color: kMuted)),
      ),
      const SizedBox(height: 10),
      Focusable(
        focusNode: _outer,
        autofocus: widget.autofocus,
        onSelect: _open,
        // A pill, like every button; selected (or typing), it gets the white ring.
        builder: (f) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            // Solid (the pill's tint over the card colour): with a see-through fill, the white
            // ring drawn behind it showed through and the field turned solid white (#3).
            color: Color.alphaBlend(kFg.withOpacity(f || _editing ? 0.10 : 0.06), const Color(0xFF12151B)),
            borderRadius: BorderRadius.circular(999),
            boxShadow: f || _editing
                ? const [BoxShadow(color: Color(0xFF12151B), spreadRadius: 4), BoxShadow(color: kFg, spreadRadius: 8)]
                : const [],
          ),
          child: Focus(
            // Escape while typing with a real keyboard: back to the field as a button.
            onKeyEvent: (_, e) {
              if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && _edit.hasFocus) {
                _outer.requestFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            canRequestFocus: false,
            skipTraversal: true,
            child: TextField(
              controller: widget.controller,
              focusNode: _edit,
              obscureText: widget.obscure,
              cursorColor: kFg,
              style: tvBody(28),
              onSubmitted: (_) {
                _outer.requestFocus();
                widget.onSubmit?.call();
              },
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: tvBody(28, color: kDim),
                contentPadding: const EdgeInsets.symmetric(horizontal: 30, vertical: 22),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

// ---------- The on-screen keyboard ----------

/// Opens the keyboard for [controller]. Returns true when closed with Done, false otherwise.
Future<bool> showTvKeyboard(BuildContext context,
    {required TextEditingController controller, required String label, bool obscure = false}) async {
  final done = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close keyboard',
    barrierColor: const Color(0x7306080B),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, __, ___) => _Keyboard(controller: controller, label: label, obscure: obscure),
    transitionBuilder: (_, a, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.12), end: Offset.zero)
            .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );
  return done == true;
}

enum _K { char, shift, symbols, delete, space, done }

class _Key {
  const _Key(this.kind, [this.text = '', this.width = 1]);
  final _K kind;
  final String text;
  final double width; // in key widths
}

class _Keyboard extends StatefulWidget {
  const _Keyboard({required this.controller, required this.label, required this.obscure});
  final TextEditingController controller;
  final String label;
  final bool obscure;

  @override
  State<_Keyboard> createState() => _KeyboardState();
}

class _KeyboardState extends State<_Keyboard> {
  final _focus = FocusNode();
  bool _shift = false;
  bool _symbols = false;
  bool _reveal = false; // show a password while typing it
  int _row = 1, _col = 0;

  static const _unit = 104.0; // one key, gaps included
  static const _gap = 10.0;

  List<List<_Key>> get _rows {
    List<_Key> chars(String s) => [for (final c in s.split('')) _Key(_K.char, c)];
    final bottom = [
      _Key(_K.symbols, _symbols ? 'ABC' : '#+=', 1.5),
      const _Key(_K.char, '@'),
      const _Key(_K.space, 'Space', 4),
      const _Key(_K.char, ':'),
      const _Key(_K.char, '/'),
      const _Key(_K.done, 'Done', 1.5),
    ];
    if (_symbols) {
      return [
        chars('1234567890'),
        chars('!?#\$%&*()='),
        chars('-_+;,"\'<>~'),
        [...chars('[]{}|\\^`.'), const _Key(_K.delete, '', 1)],
        bottom,
      ];
    }
    final letters = _shift ? 'QWERTYUIOPASDFGHJKLZXCVBNM' : 'qwertyuiopasdfghjklzxcvbnm';
    return [
      chars('1234567890'),
      chars(letters.substring(0, 10)),
      [...chars(letters.substring(10, 19)), const _Key(_K.char, '.')],
      [const _Key(_K.shift), ...chars(letters.substring(19)), const _Key(_K.char, '-'), const _Key(_K.delete)],
      bottom,
    ];
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _type(String s) {
    final c = widget.controller;
    c.value = TextEditingValue(text: c.text + s, selection: TextSelection.collapsed(offset: c.text.length + s.length));
  }

  void _delete() {
    final c = widget.controller;
    if (c.text.isEmpty) return;
    final chars = c.text.characters;
    final text = chars.take(chars.length - 1).toString();
    c.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  void _press(_Key k) {
    switch (k.kind) {
      case _K.char:
        _type(k.text);
        if (_shift) _shift = false; // one capital, like a phone
      case _K.shift:
        _shift = !_shift;
      case _K.symbols:
        _symbols = !_symbols;
        _shift = false;
      case _K.delete:
        _delete();
      case _K.space:
        _type(' ');
      case _K.done:
        Navigator.of(context).pop(true);
        return;
    }
    setState(() {});
  }

  // Left edge of key [col] in row [row], in key widths.
  double _x(List<_Key> row, int col) {
    var x = 0.0;
    for (var i = 0; i < col; i++) {
      x += row[i].width;
    }
    return x + row[col].width / 2;
  }

  // Moving up or down lands on the key closest to the one you left.
  int _nearest(List<_Key> row, double x) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < row.length; i++) {
      final d = (_x(row, i) - x).abs();
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final rows = _rows;
    _row = _row.clamp(0, rows.length - 1);
    _col = _col.clamp(0, rows[_row].length - 1);
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      setState(() => _col = (_col - 1) % rows[_row].length);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      setState(() => _col = (_col + 1) % rows[_row].length);
    } else if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      final x = _x(rows[_row], _col);
      final next = (_row + (key == LogicalKeyboardKey.arrowUp ? -1 : 1)).clamp(0, rows.length - 1);
      setState(() {
        _row = next;
        _col = _nearest(rows[next], x);
      });
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      // A real keyboard's Enter is Done; the controller's Cross presses the selected key.
      if (padActive.value && e.physicalKey != PhysicalKeyboardKey.numpadEnter) {
        _press(rows[_row][_col]);
      } else {
        Navigator.of(context).pop(true);
      }
    } else if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      setState(_delete);
    } else if (key == LogicalKeyboardKey.contextMenu) {
      setState(() => _type(' '));
    } else if (key == LogicalKeyboardKey.mediaPlayPause) {
      Navigator.of(context).pop(true);
    } else if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop(false);
    } else if (e.character != null && e.character!.isNotEmpty && e.character!.codeUnitAt(0) >= 32) {
      // Typing on a real keyboard works here too.
      setState(() => _type(e.character!));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    _row = _row.clamp(0, rows.length - 1);
    _col = _col.clamp(0, rows[_row].length - 1);
    final text = widget.controller.text;
    final shown = widget.obscure && !_reveal ? '•' * text.characters.length : text;

    return PadHints(
      hints: const [
        PadHint(PadButton.select, 'Type'),
        PadHint(PadButton.delete, 'Delete'),
        PadHint(PadButton.menu, 'Space'),
        PadHint(PadButton.back, 'Close'),
        PadHint(PadButton.playPause, 'Done'),
      ],
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: TvCanvas(
          child: Stack(children: [
            // A sheet from the bottom, full width, like the player's panel and the PS5 keyboard.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 690,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  padding: const EdgeInsets.only(top: 40),
                  decoration: BoxDecoration(
                    color: const Color(0xF712151B),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(36)),
                    border: Border(top: BorderSide(color: kFg.withOpacity(0.08))),
                  ),
                  child: Column(children: [
                    // What you're typing, with the field's name: the same pill as the field,
                    // with the ring (it's where the letters go).
                    SizedBox(
                      width: 10 * _unit - _gap,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(widget.label, style: tvBody(21, weight: FontWeight.w600, color: kMuted)),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          height: 76,
                          padding: const EdgeInsets.symmetric(horizontal: 30),
                          decoration: BoxDecoration(
                            color: const Color(0xFF22262D),
                            borderRadius: BorderRadius.circular(999),
                            boxShadow: const [
                              BoxShadow(color: Color(0xFF12151B), spreadRadius: 4),
                              BoxShadow(color: kFg, spreadRadius: 8),
                            ],
                          ),
                          child: Row(children: [
                            Expanded(
                              child: Text.rich(
                                TextSpan(children: [
                                  TextSpan(text: shown, style: tvBody(30)),
                                  TextSpan(text: '|', style: tvBody(30, weight: FontWeight.w400, color: kMuted)),
                                ]),
                                maxLines: 1,
                                overflow: TextOverflow.fade,
                                softWrap: false,
                              ),
                            ),
                            if (widget.obscure)
                              GestureDetector(
                                onTap: () => setState(() => _reveal = !_reveal),
                                child: Row(children: [
                                  Icon(_reveal ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                      size: 26, color: kMuted),
                                  const SizedBox(width: 8),
                                  Text(_reveal ? 'Hide' : 'Show', style: tvBody(19, color: kMuted)),
                                ]),
                              ),
                          ]),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 34),
                    for (var r = 0; r < rows.length; r++)
                      Padding(
                        padding: EdgeInsets.only(bottom: r == rows.length - 1 ? 0 : _gap),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          for (var c = 0; c < rows[r].length; c++) _keyView(rows[r][c], r, c),
                        ]),
                      ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _keyView(_Key k, int r, int c) {
    final focused = r == _row && c == _col;
    final special = k.kind != _K.char;
    final on = (k.kind == _K.shift && _shift);
    final done = k.kind == _K.done;
    final fill = focused
        ? kFg
        : done
            ? kFg.withOpacity(0.82) // always lit, easy to find
            : (on ? kFg.withOpacity(0.30) : kFg.withOpacity(special ? 0.14 : 0.08));
    final color = focused || done ? kBg : kFg;
    Widget label;
    switch (k.kind) {
      case _K.shift:
        label = Icon(_shift ? Icons.keyboard_capslock_rounded : Icons.arrow_upward_rounded, size: 30, color: color);
      case _K.delete:
        label = Icon(Icons.backspace_outlined, size: 28, color: color);
      case _K.done:
        label = Text(k.text, style: tvBody(24, weight: FontWeight.w700, color: color));
      default:
        label = Text(k.text, style: tvBody(k.text.length > 1 ? 22 : 30, weight: FontWeight.w600, color: color));
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!padActive.value) setState(() {
          _row = r;
          _col = c;
        });
      },
      child: GestureDetector(
        onTap: () {
          _row = r;
          _col = c;
          _press(k);
        },
        child: Container(
          width: k.width * _unit - _gap,
          height: 72,
          margin: const EdgeInsets.only(right: _gap),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(22),
            // the white ring, kept inside the 10 px gap so the next key doesn't cover it
            boxShadow: focused
                ? const [BoxShadow(color: Color(0xFF12151B), spreadRadius: 3), BoxShadow(color: kFg, spreadRadius: 7)]
                : const [],
          ),
          child: label,
        ),
      ),
    );
  }
}
