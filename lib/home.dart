// Home screen: full-screen backdrop, title logo, Resume, and two rows of my library.
// Built on a fixed 1920x1080 canvas that scales to any window, like a TV app.
// Works with arrow keys + Enter (and a controller mapped to them), or the mouse.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main.dart';
import 'library.dart';
import 'player.dart';
import 'ui.dart';

// ---------- Look (shared with the other screens, see ui.dart) ----------

const _bg = kBg;
const _fg = kFg;
const _muted = kMuted;
const _soft = kSoft;
const _placeholder = kPlaceholder;

int _px(double designPixels) => tvPx(designPixels);
// Loaded a bit wider than the design, so wide windows don't stretch it soft.
int get _backdropWidth => tvPx(2560).clamp(1280, 3840);

TextStyle _body(double size, {FontWeight weight = FontWeight.w500, Color color = kFg, double? height}) =>
    tvBody(size, weight: weight, color: color, height: height);
TextStyle _display(double size) => tvDisplay(size);

String _titleOf(dynamic item) => titleOf(item);
String _episodeLine(dynamic item) => episodeLine(item);
String _qualityLine(dynamic item) => qualityLine(item);
double _progress(dynamic item) => progressOf(item);
int _minutesLeft(dynamic item) => minutesLeft(item);

// ---------- The screen ----------

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.jf});
  final Jellyfin jf;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<dynamic> _resume = [];
  List<dynamic> _latest = [];
  dynamic _featured;
  bool _loading = true;

  Jellyfin get jf => widget.jf;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<dynamic> _libraries = [];

  Future<void> _load() async {
    final results = await Future.wait([
      jf.resume().catchError((_) => <dynamic>[]),
      jf.latest().catchError((_) => <dynamic>[]),
      jf.views().catchError((_) => <dynamic>[]),
    ]);
    if (!mounted) return;
    setState(() {
      _resume = results[0];
      _latest = results[1];
      _libraries = results[2];
      _featured = _resume.isNotEmpty ? _resume.first : (_latest.isNotEmpty ? _latest.first : null);
      _loading = false;
    });
  }

  // Movies and episodes play; a show opens its show page. Coming back refreshes Continue Watching.
  Future<void> _open(dynamic item) async {
    if (item == null) return;
    final Widget screen =
        item['Type'] == 'Series' ? ShowScreen(jf: jf, series: item) : PlayerScreen(jf: jf, item: item);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _load();
  }

  // Wait until focus rests on a card before loading its backdrop, so holding an arrow key
  // along a row doesn't load every backdrop it passes.
  Timer? _featureTimer;
  void _feature(dynamic item) {
    _featureTimer?.cancel();
    _featureTimer = Timer(const Duration(milliseconds: 160), () {
      if (mounted) setState(() => _featured = item);
    });
  }

  @override
  void dispose() {
    _featureTimer?.cancel();
    super.dispose();
  }

  // Hero layout: while focus is at the top (tabs, Play), the artwork fills the screen and the
  // rows only peek in at the bottom. Moving down into the rows slides them up over a dimmed backdrop.
  bool _hero = true;

  void _setHero(bool hero) {
    if (_hero == hero) return;
    setState(() => _hero = hero);
    if (hero) {
      // Back at the top: reset the rows to the first one.
      _rowIndex = 0;
      final first = _rowKeys[0].currentContext;
      if (first != null) {
        Scrollable.ensureVisible(first, alignment: 0, duration: const Duration(milliseconds: 320));
      }
    }
  }

  // Which row is at the top of the rows area, for the mouse wheel.
  final _rowKeys = [GlobalKey(), GlobalKey()];
  int _rowIndex = 0;
  DateTime _lastWheel = DateTime(0);

  void _wheelToRow(int direction) {
    // One wheel flick sends many events; only act on the first.
    final now = DateTime.now();
    if (now.difference(_lastWheel) < const Duration(milliseconds: 400)) return;
    _lastWheel = now;
    final rows = [
      if (_resume.isNotEmpty) 0,
      if (_latest.isNotEmpty) 1,
    ];
    if (rows.isEmpty) return;
    final current = rows.indexOf(_rowIndex).clamp(0, rows.length - 1);
    // Wheel down from the full-screen artwork brings the rows up; wheel up from the first row
    // goes back to the artwork.
    if (direction > 0 && _hero) {
      _setHero(false);
      return;
    }
    if (direction < 0 && !_hero && current == 0) {
      _setHero(true);
      return;
    }
    final next = (current + direction).clamp(0, rows.length - 1);
    _rowIndex = rows[next];
    final target = _rowKeys[_rowIndex].currentContext;
    if (target != null) {
      Scrollable.ensureVisible(target,
          alignment: 0, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: _bg,
      body: LayoutBuilder(builder: (context, box) {
        // Scale the 1920x1080 design to the window, then stretch the canvas to fill the window's
        // actual shape, so wider or taller windows get more room instead of black bars.
        final w = box.maxWidth, h = box.maxHeight;
        final scale = (w / 1920) < (h / 1080) ? w / 1920 : h / 1080;
        tvDecodeScale = (scale * mq.devicePixelRatio).clamp(0.5, 2.0);
        return FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(width: w / scale, height: h / scale, child: _canvas(context)),
        );
      }),
    );
  }

  Widget _canvas(BuildContext context) {
    final featured = _featured;
    const move = Duration(milliseconds: 420);
    const curve = Curves.easeOutCubic;
    // The mouse wheel works anywhere on the screen.
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && !HardwareKeyboard.instance.isShiftPressed) {
          _wheelToRow(event.scrollDelta.dy > 0 ? 1 : -1);
        }
      },
      child: Stack(
      children: [
        // Backdrop of whatever is focused, cross-fading as you move.
        // Its own layer, so moving focus around doesn't redraw the big backdrop.
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              child: featured == null
                  ? const ColoredBox(key: ValueKey('none'), color: _bg)
                  : Image.network(
                      jf.backdropFor(featured, maxWidth: _backdropWidth),
                      key: ValueKey(jf.backdropFor(featured, maxWidth: _backdropWidth)),
                      width: double.infinity,
                      height: double.infinity,
                      // Decode at the size it's shown, not the file's full size.
                      cacheWidth: _backdropWidth,
                      fit: BoxFit.cover,
                      // Keep the top of the artwork (faces, titles); trim the bottom, which sits
                      // behind the rows and the dark fade anyway.
                      alignment: Alignment.topCenter,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => const ColoredBox(color: _placeholder),
                    ),
            ),
          ),
        ),
        // Darken the left side and the bottom so text stays readable on any artwork.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                // A softer shade that eases out gradually, so it reads as a shadow, not a bar.
                colors: [
                  _bg.withOpacity(0.8),
                  _bg.withOpacity(0.62),
                  _bg.withOpacity(0.35),
                  _bg.withOpacity(0.12),
                  _bg.withOpacity(0),
                ],
                stops: const [0, 0.22, 0.42, 0.6, 0.75],
              ),
            ),
          ),
        ),
        // Light fade at the top and bottom edges, always on, so the peeking rows stay readable.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _bg.withOpacity(0.35),
                  _bg.withOpacity(0),
                  _bg.withOpacity(0),
                  _bg.withOpacity(0.75),
                ],
                stops: const [0, 0.18, 0.72, 1],
              ),
            ),
          ),
        ),
        // Strong fade under the rows, faded in only when the rows are up.
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _hero ? 0 : 1,
              duration: move,
              curve: curve,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      _bg.withOpacity(0),
                      _bg.withOpacity(0),
                      _bg.withOpacity(0.88),
                      _bg,
                    ],
                    stops: const [0, 0.38, 0.6, 0.8],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 120,
          top: 52,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (f) {
              if (f) _setHero(true);
            },
            child: _nav(context),
          ),
        ),
        if (_loading)
          Positioned(left: 120, top: 200, child: Text('Loading your library…', style: _body(28, color: _muted)))
        else if (featured == null)
          Positioned(left: 120, top: 200, child: Text('Nothing here yet.', style: _body(28, color: _muted)))
        else
          // The title, summary and Play button sit low over the full artwork, and move up
          // out of the way when the rows rise.
          AnimatedPositioned(
            duration: move,
            curve: curve,
            left: 120,
            top: _hero ? 470 : 150,
            width: 1000,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (f) {
                if (f) _setHero(true);
              },
              child: RepaintBoundary(child: _heroBlock(featured)),
            ),
          ),
        // Rows live in their own scrolling area: they peek in at the bottom over the full artwork,
        // and rise when focus moves into them. Moving down to a lower row slides it into place.
        AnimatedPositioned(
          duration: move,
          curve: curve,
          left: 0,
          right: 0,
          top: _hero ? 880 : 540,
          bottom: 0,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (f) {
              if (f) _setHero(false);
            },
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 280),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _MediaRow(
                      key: _rowKeys[0],
                      title: 'Continue watching',
                      items: _resume,
                      jf: jf,
                      onSelect: _open,
                      onFocus: _feature,
                      onActivate: () => _rowIndex = 0),
                  const SizedBox(height: 28),
                  _MediaRow(
                      key: _rowKeys[1],
                      title: 'Recently added',
                      items: _latest,
                      jf: jf,
                      onSelect: _open,
                      onFocus: _feature,
                      onActivate: () => _rowIndex = 1),
                ],
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }

  // Tabs: Home + one per Jellyfin library (Movies, Shows, Anime...).
  Widget _nav(BuildContext context) {
    return NavBar(
      libraries: _libraries,
      currentId: null,
      onHome: () {},
      onLibrary: (lib) async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => LibraryScreen(jf: jf, libraries: _libraries, library: lib)));
        _load();
      },
    );
  }

  Widget _heroBlock(dynamic item) {
    final logo = jf.logoFor(item);
    final title = Text(_titleOf(item), style: _display(64), maxLines: 2, overflow: TextOverflow.ellipsis);
    final year = item['ProductionYear']?.toString() ?? '';
    final meta = [_episodeLine(item), year, _qualityLine(item)].where((s) => s.isNotEmpty).join('   ·   ');
    final overview = (item['Overview'] ?? '').toString();
    final progress = _progress(item);
    final label = item['Type'] == 'Series' ? 'Open' : (progress > 0 ? 'Resume' : 'Play');

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Column(
        key: ValueKey(item['Id']),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 120,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: logo == null
                  ? title
                  // A soft dark glow behind the logo keeps dark logos readable on busy artwork.
                  // It's in its own layer, so the blur is drawn once per title, not every frame.
                  : Stack(children: [
                      RepaintBoundary(
                        child: ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                          child: ColorFiltered(
                            colorFilter: ColorFilter.mode(Colors.black.withOpacity(0.75), BlendMode.srcIn),
                            child: Image.network(logo,
                                height: 120,
                                cacheHeight: _px(120),
                                fit: BoxFit.contain,
                                alignment: Alignment.bottomLeft,
                                errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                          ),
                        ),
                      ),
                      Image.network(logo,
                          height: 120,
                          cacheHeight: _px(120),
                          fit: BoxFit.contain,
                          alignment: Alignment.bottomLeft,
                          errorBuilder: (_, __, ___) => title),
                    ]),
            ),
          ),
          const SizedBox(height: 16),
          Text(meta, style: _body(26, color: _soft)),
          if (overview.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: 780,
              child: Text(overview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: _body(24, weight: FontWeight.w400, color: const Color(0xFFC3C9D3), height: 1.45)),
            ),
          ],
          const SizedBox(height: 22),
          Row(children: [
            Focusable(
              autofocus: true,
              onSelect: () => _open(_featured),
              builder: (f) => AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 64,
                padding: const EdgeInsets.only(left: 26, right: 34),
                decoration: BoxDecoration(
                  color: f ? _fg : _fg.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: f ? [BoxShadow(color: _fg.withOpacity(0.22), spreadRadius: 5)] : [],
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.play_arrow_rounded, size: 34, color: f ? _bg : _fg),
                  const SizedBox(width: 10),
                  Text(label, style: _body(26, weight: FontWeight.w700, color: f ? _bg : _fg)),
                ]),
              ),
            ),
            if (progress > 0) ...[
              const SizedBox(width: 26),
              Container(
                width: 140,
                height: 5,
                decoration: BoxDecoration(color: _fg.withOpacity(0.22), borderRadius: BorderRadius.circular(5)),
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: progress,
                  child: Container(
                      decoration: BoxDecoration(color: _fg, borderRadius: BorderRadius.circular(5))),
                ),
              ),
              const SizedBox(width: 14),
              Text('${_minutesLeft(item)} min left', style: _body(24, color: _muted)),
            ],
          ]),
        ],
      ),
    );
  }
}

// ---------- A row of 16:9 cards ----------

class _MediaRow extends StatefulWidget {
  const _MediaRow({
    super.key,
    required this.title,
    required this.items,
    required this.jf,
    required this.onSelect,
    required this.onFocus,
    this.onActivate,
  });

  final String title;
  final List<dynamic> items;
  final Jellyfin jf;
  final void Function(dynamic item) onSelect;
  final void Function(dynamic item) onFocus;
  // Called when the keyboard moves into this row, so the mouse wheel knows where we are.
  final VoidCallback? onActivate;

  @override
  State<_MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<_MediaRow> {
  static const cardW = 264.0;
  static const cardH = 148.0;

  final _scroll = ScrollController();
  bool _hovering = false;

  List<dynamic> get items => widget.items;
  Jellyfin get jf => widget.jf;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // Moving into this row with the keyboard slides it to the top of the rows area.
  void _bringRowIntoView() {
    widget.onActivate?.call();
    Scrollable.ensureVisible(context,
        alignment: 0, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  // Mouse arrow buttons: move about one screen of cards at a time.
  void _page(int direction) {
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) return;
    final p = _scroll.position;
    final target = (p.pixels + direction * 1500).clamp(p.minScrollExtent, p.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
  }

  Widget _arrow(int direction) {
    // Only check positions once the row has been laid out.
    final canMove = _scroll.hasClients &&
        _scroll.position.hasContentDimensions &&
        (direction < 0
            ? _scroll.position.pixels > _scroll.position.minScrollExtent + 1
            : _scroll.position.pixels < _scroll.position.maxScrollExtent - 1);
    return AnimatedOpacity(
      opacity: _hovering && canMove ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: IgnorePointer(
        ignoring: !(_hovering && canMove),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _page(direction),
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: _bg.withOpacity(0.75), shape: BoxShape.circle),
              child: Icon(direction < 0 ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                  size: 44, color: _fg),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 120),
          child: Text(widget.title, style: _body(28, weight: FontWeight.w700)),
        ),
        const SizedBox(height: 4),
        MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: SizedBox(
            height: cardH + 96,
            child: Stack(children: [
              // Cards fade out softly at both screen edges, without darkening the backdrop
              // behind them: the fade applies to the cards only.
              Positioned.fill(
                child: LayoutBuilder(builder: (context, box) {
                  final edge = 110 / box.maxWidth;
                  return ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => LinearGradient(
                      colors: const [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
                      stops: [0.0, edge, 1 - edge, 1.0],
                    ).createShader(rect),
                    child: RepaintBoundary(
                      child: FocusTraversalGroup(
                        child: ListView.separated(
                          controller: _scroll,
                          scrollDirection: Axis.horizontal,
                          // Room above and below so the focused card's lift and glow aren't clipped.
                          padding: const EdgeInsets.fromLTRB(120, 16, 120, 0),
                          itemCount: items.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 30),
                          itemBuilder: (_, i) => _card(items[i]),
                        ),
                      ),
                    ),
                  );
                }),
              ),
              // Only the arrows redraw while the row scrolls, not every card.
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _scroll,
                  builder: (_, __) => Stack(children: [
                    Positioned(left: 36, top: 16 + cardH / 2 - 32, child: _arrow(-1)),
                    Positioned(right: 36, top: 16 + cardH / 2 - 32, child: _arrow(1)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _card(dynamic item) {
    final progress = _progress(item);
    final episode = item['Type'] == 'Episode'
        ? [
            if (item['ParentIndexNumber'] != null) 'S${item['ParentIndexNumber']}',
            if (item['IndexNumber'] != null) 'E${item['IndexNumber']}',
          ].join(' · ')
        : '';
    return Focusable(
      onSelect: () => widget.onSelect(item),
      onFocus: (viaMouse) {
        widget.onFocus(item);
        if (!viaMouse) _bringRowIntoView();
      },
      builder: (f) => SizedBox(
        width: cardW,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedScale(
              scale: f ? 1.08 : 1,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: cardW,
                height: cardH,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: f
                      ? [
                          BoxShadow(color: _fg.withOpacity(0.9), spreadRadius: 4),
                          BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 40, offset: const Offset(0, 20)),
                        ]
                      : [],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(fit: StackFit.expand, children: [
                    Image.network(
                      jf.thumbFor(item),
                      // Decode at the size it's shown on this screen (focused size included).
                      cacheWidth: _px(cardW * 1.08),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: _placeholder,
                        padding: const EdgeInsets.all(14),
                        alignment: Alignment.bottomLeft,
                        child: Text(_titleOf(item), style: _body(20, weight: FontWeight.w700)),
                      ),
                    ),
                    // Unfocused cards are dimmed with a plain dark layer, cheaper than transparency.
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      color: Colors.black.withOpacity(f ? 0 : 0.22),
                    ),
                    if (progress > 0)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          height: 5,
                          color: _fg.withOpacity(0.25),
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(widthFactor: progress, child: Container(color: _fg)),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _titleOf(item),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _body(f ? 24 : 22, weight: f ? FontWeight.w700 : FontWeight.w500, color: f ? _fg : _muted),
            ),
            if (episode.isNotEmpty)
              Text(episode, maxLines: 1, style: _body(20, color: f ? _soft : const Color(0xFF8E97A6))),
          ],
        ),
      ),
    );
  }
}

// ---------- Plain list screens (Movies, Shows, episodes) until they get their own design ----------

class _ListScreen extends StatelessWidget {
  const _ListScreen({required this.title, required this.jf, required this.load});
  final String title;
  final Jellyfin jf;
  final Future<List<dynamic>> Function() load;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ItemList(jf: jf, load: load),
    );
  }
}
