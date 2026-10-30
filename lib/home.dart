// Home screen: full-screen backdrop, title logo, Resume, and two rows of my library.
// Built on a fixed 1920x1080 canvas that scales to any window, like a TV app.
// Works with arrow keys + Enter (and a controller mapped to them), or the mouse.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'main.dart';
import 'library.dart';
import 'movie.dart' show MovieScreen;
import 'images.dart';
import 'profiles.dart' show ProfileChip, ProfileStore, WhoScreen, showProfileMenu;
import 'syncplay.dart' show TogetherPill, startWatchTogether, watchTogetherButton, playOrParty;
import 'ui.dart';

// ---------- Look (shared with the other screens, see ui.dart) ----------

const _bg = kBg;
const _fg = kFg;
const _muted = kMuted;
const _soft = kSoft;
const _placeholder = kPlaceholder;

int _px(double designPixels) => tvPx(designPixels);
// Loaded a bit wider than the design, so wide windows don't stretch it soft.
// The backdrop always sits under dark shading, so it never needs more than 2560 pixels wide,
// even on a 4K screen. That's under half the pixels of a full 4K picture to load and draw.
int get _backdropWidth => sizeBucket(tvPx(1920)).clamp(1280, 2560);

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
  // What's selected right now: its backdrop and title fill the screen. Kept in its own
  // notifier so moving between cards redraws only the backdrop and title, not both rows.
  final _featuredN = ValueNotifier<dynamic>(null);
  dynamic get _featured => _featuredN.value;
  set _featured(dynamic item) => _featuredN.value = item;
  bool _loading = true;

  Jellyfin get jf => widget.jf;

  String? _serverName; // shown under your name, top right
  final _profileNode = namedNode('Home: Profile');

  @override
  void initState() {
    super.initState();
    _loadSaved();
    _load();
    ProfileStore.serverName().then((n) {
      if (mounted) setState(() => _serverName = n);
    }, onError: (_) {});
  }

  // The last home screen is saved on disk, so the app opens straight onto your rows (with
  // artwork from the disk cache) and refreshes them a moment later.
  Future<File> _savedFile() async => File('${(await getApplicationSupportDirectory()).path}/home.json');

  Future<void> _loadSaved() async {
    try {
      final file = await _savedFile();
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      // Only if it's for this server and user, and the fresh answer hasn't arrived yet.
      if (data['server'] != jf.server || data['userId'] != jf.userId) return;
      if (!mounted || !_loading) return;
      setState(() {
        _resume = data['resume'] as List;
        _latest = data['latest'] as List;
        _libraries = data['views'] as List;
        _featured = _resume.isNotEmpty ? _resume.first : (_latest.isNotEmpty ? _latest.first : null);
        _loading = false;
      });
    } catch (_) {
      // No saved screen, or it can't be read: just wait for the server.
    }
  }

  Future<void> _save(List<dynamic> resume, List<dynamic> latest, List<dynamic> views) async {
    try {
      final file = await _savedFile();
      final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.part');
      await tmp.writeAsString(jsonEncode(
          {'server': jf.server, 'userId': jf.userId, 'resume': resume, 'latest': latest, 'views': views}));
      await tmp.rename(file.path);
    } catch (_) {}
  }

  List<dynamic> _libraries = [];

  String? _error;
  int _retriesLeft = 3;
  // The server didn't answer at all (a NAS waking up, Wi-Fi reconnecting): keep trying quietly
  // for about 20 seconds before showing an error.
  int _offlineTry = 0;
  static const _offlineWaits = [2, 3, 5, 10];

  Future<void> _load() async {
    Object? failure;
    // A list that fails to load keeps what it showed before (null = failed), instead of
    // quietly turning empty. The reason is printed in the terminal.
    Future<List<dynamic>?> attempt(String name, Future<List<dynamic>> f) => f.then<List<dynamic>?>((v) => v,
            onError: (Object e) {
          failure = e;
          debugPrint('Home: $name failed to load: $e');
          return null;
        });
    final loaded = await Future.wait([
      attempt('Continue watching', jf.resume()),
      attempt('Recently added', jf.latest()),
      attempt('Libraries (tabs)', jf.views()),
    ]);
    if (!mounted) return;
    final results = [loaded[0] ?? _resume, loaded[1] ?? _latest, loaded[2] ?? _libraries];
    final nothing = loaded.every((r) => r == null || r.isEmpty);
    setState(() {
      // Only a real failure is an error (an empty library is not). If a refresh fails while
      // the screen already shows something, keep showing it.
      if (nothing && failure != null) {
        final text = errorText(failure!);
        final login = text.contains('Sign in again');
        if (!login && _offlineTry < _offlineWaits.length) {
          final wait = _offlineWaits[_offlineTry++];
          debugPrint('Home: server not answering, trying again in $wait s');
          Timer(Duration(seconds: wait), () {
            if (mounted) _load();
          });
          return; // still "Connecting…" (or the saved screen) meanwhile
        }
        // An expired login always shows (with Sign in), even over a saved screen.
        if ((_resume.isEmpty && _latest.isEmpty) || login) _error = text;
        return;
      }
      _offlineTry = 0;
      _error = null;
      _resume = results[0];
      _latest = results[1];
      _libraries = results[2];
      // Keep the artwork of what's selected when coming back from a video.
      final keep = _featured == null
          ? null
          : [..._resume, ..._latest].cast<dynamic>().firstWhere((i) => i['Id'] == _featured['Id'], orElse: () => null);
      _featured = keep ?? (_resume.isNotEmpty ? _resume.first : (_latest.isNotEmpty ? _latest.first : null));
      _loading = false;
    });
    if (failure == null) _save(results[0], results[1], results[2]);
    // Something failed but the rest loaded: try the missing part again in a few seconds.
    if (failure != null && !nothing && _retriesLeft > 0) {
      _retriesLeft--;
      Timer(const Duration(seconds: 5), () {
        if (mounted) _load();
      });
    }
    if (failure == null) _retriesLeft = 3;
  }

  // The saved login no longer works: forget it and go back to Who's watching.
  Future<void> _signInAgain() async {
    try {
      if (jf.userId != null) await ProfileStore.forget(jf.userId!);
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => WhoScreen(server: jf.server)), (_) => false);
  }

  void _retry() {
    _offlineTry = 0;
    setState(() {
      _error = null;
      _loading = true;
    });
    _load();
  }

  // Movies and episodes play; a show opens its show page. Coming back refreshes Continue Watching.
  Future<void> _open(dynamic item) async {
    if (item == null) return;
    if (item['Type'] == 'Series') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShowScreen(jf: jf, series: item)));
    } else {
      await playOrParty(context, jf, item); // for the party when you're in one
    }
    // Watched something from a show: its saved pages (next episode, progress) are out of date.
    final series = item['Type'] == 'Series' ? item['Id'] : item['SeriesId'];
    if (series != null) jf.forgetShow(series.toString());
    _load();
  }

  // Recently added: a movie opens its page first (Continue watching resumes straight away).
  Future<void> _openDetails(dynamic item) async {
    if (item?['Type'] != 'Movie') return _open(item);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MovieScreen(jf: jf, movie: item)));
    _load();
  }

  // Wait until focus rests on a card before loading its backdrop, so holding an arrow key
  // along a row doesn't load every backdrop it passes.
  Timer? _featureTimer;
  void _feature(dynamic item) {
    _featureTimer?.cancel();
    _featureTimer = Timer(const Duration(milliseconds: 160), () {
      if (!mounted) return;
      _featured = item;
      // A show selected for a moment: fetch its page now, so opening it is instant.
      if (item?['Type'] == 'Series') jf.prefetchShow(item);
    });
  }

  @override
  void dispose() {
    _featureTimer?.cancel();
    _profileNode.dispose();
    _playNode.dispose();
    _featuredN.dispose();
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
  final _rowKeys = [GlobalKey<_MediaRowState>(), GlobalKey<_MediaRowState>()];

  // Fixed Up / Down jumps for the controller: tabs ↕ Play ↕ row 1 ↕ row 2.
  final _playNode = namedNode('Home: Play');

  // Focuses the first row with something in it, starting at [from] and going in [step].
  bool _focusRow(int from, int step) {
    for (var i = from; i >= 0 && i < _rowKeys.length; i += step) {
      final row = _rowKeys[i].currentState;
      if (row != null && row.focusRow()) return true;
    }
    return false;
  }
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
    const move = Duration(milliseconds: 420);
    const curve = Curves.easeOutCubic;
    // The mouse wheel works anywhere on the screen. Triangle / Y opens your profile menu.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.contextMenu) {
          showProfileMenu(context, jf);
          return KeyEventResult.handled;
        }
        // R2 / Page Down: the next tab (the first library).
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.pageDown && _libraries.isNotEmpty) {
          _openLibrary(_libraries.first);
          return KeyEventResult.handled;
        }
        // Circle / B in the rows: back up to the artwork and Play, like a console's home.
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && !_hero) {
          _setHero(true);
          focusOn(_playNode);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Listener(
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
            child: ValueListenableBuilder<dynamic>(
              valueListenable: _featuredN,
              builder: (context, featured, _) => AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              child: featured == null
                  ? const ColoredBox(key: ValueKey('none'), color: _bg)
                  // Keeps the top of the artwork (faces, titles); trims the bottom, which sits
                  // behind the rows and the dark fade anyway.
                  : netImage(
                      jf.backdropFor(featured, maxWidth: _backdropWidth),
                      key: ValueKey(jf.backdropFor(featured, maxWidth: _backdropWidth)),
                      width: double.infinity,
                      height: double.infinity,
                      cacheWidth: _backdropWidth,
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => const ColoredBox(color: _placeholder),
                    ),
            ),
            ),
          ),
        ),
        // Shading over the backdrop: one small picture stretched, made once (see ShadeOverlay).
        const Positioned.fill(child: ShadeOverlay(shades: [kShadeLeft, kShadeTopBottom])),
        // Strong fade under the rows, faded in only when the rows are up (see FadingShade).
        Positioned.fill(
          child: FadingShade(
            visible: !_hero,
            duration: move,
            curve: curve,
            alphas: const [0, 0, 0.88, 1],
            stops: const [0, 0.38, 0.6, 0.8],
          ),
        ),
        // Moving focus with the keyboard or controller raises and lowers the rows; the mouse
        // never does (it would move the screen under the pointer). The wheel does that instead.
        Positioned(
          left: 120,
          top: 52,
          child: FocusLinks(down: () => focusOn(_playNode) || _focusRow(0, 1), child: _nav(context)),
        ),
        // You, top right: avatar, name and server. Select it (or Triangle / Y anywhere) for the menu.
        Positioned(
          right: 120,
          top: 48,
          child: FocusLinks(
            down: () => focusOn(_playNode) || _focusRow(0, 1),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              // Shows only while someone has a Watch together room open on this server.
              TogetherPill(jf: jf),
              ProfileChip(jf: jf, serverName: _serverName, focusNode: _profileNode),
            ]),
          ),
        ),
        if (_error != null)
          Positioned(
            left: 120,
            top: 200,
            child: _error!.contains('Sign in again')
                ? TvError(message: _error!, onRetry: _signInAgain, label: 'Sign in')
                : TvError(message: _error!, onRetry: _retry),
          )
        else if (_loading)
          Positioned(
              left: 120,
              top: 200,
              child: Text(_offlineTry > 0 ? 'Connecting to ${_serverName ?? 'your server'}…' : 'Loading your library…',
                  style: _body(28, color: _muted)))
        else
          // The title, summary and Play button sit low over the full artwork, and move up
          // out of the way when the rows rise.
          AnimatedPositioned(
            duration: move,
            curve: curve,
            left: 120,
            top: _hero ? 470 : 150,
            width: 1000,
            child: RepaintBoundary(
              child: ValueListenableBuilder<dynamic>(
                valueListenable: _featuredN,
                builder: (context, featured, _) => featured == null
                    ? Text('Nothing here yet.', style: _body(28, color: _muted))
                    : _heroBlock(featured),
              ),
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
          child: _error != null ? const SizedBox.shrink() : SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              // Only a small margin under the last row: moving down to it stops when it reaches
              // the bottom of the screen (the row above stays partly in view), instead of
              // sliding it to the top and leaving an empty black band below.
              padding: const EdgeInsets.only(bottom: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FocusLinks(
                    up: () => focusOn(_playNode),
                    down: () => _focusRow(1, 1) || true,
                    child: _MediaRow(
                      key: _rowKeys[0],
                      title: 'Continue watching',
                      items: _resume,
                      jf: jf,
                      onSelect: _open,
                      onFocus: _feature,
                      onActivate: () {
                        _rowIndex = 0;
                        _setHero(false);
                      }),
                  ),
                  const SizedBox(height: 28),
                  FocusLinks(
                    up: () => _focusRow(0, -1) || focusOn(_playNode),
                    down: () => true, // last row: nothing below
                    child: _MediaRow(
                      key: _rowKeys[1],
                      title: 'Recently added',
                      items: _latest,
                      jf: jf,
                      onSelect: _openDetails,
                      onFocus: _feature,
                      onActivate: () {
                        _rowIndex = 1;
                        _setHero(false);
                      }),
                  ),
                ],
              ),
            ),
        ),
      ],
      ),
      ),
    );
  }

  // Tabs: Home + one per Jellyfin library (Movies, Shows, Anime...).
  Widget _nav(BuildContext context) {
    return NavBar(
      libraries: _libraries,
      currentId: null,
      onHome: () {},
      onFocus: (viaMouse) {
        if (!viaMouse) _setHero(true);
      },
      onLibrary: _openLibrary,
    );
  }

  Future<void> _openLibrary(dynamic lib) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LibraryScreen(jf: jf, libraries: _libraries, library: lib)));
    _load();
    // Came back with L2 from another tab: if nothing on Home is selected, select Play.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final f = FocusManager.instance.primaryFocus;
      if (mounted && (f == null || focusLabels[f] == null)) {
        _setHero(true);
        focusOn(_playNode);
      }
    });
  }

  Widget _heroBlock(dynamic item) {
    final logo = jf.logoFor(item);
    final title = Text(_titleOf(item), style: _display(64), maxLines: 2, overflow: TextOverflow.ellipsis);
    final year = item['ProductionYear']?.toString() ?? '';
    final meta = [_episodeLine(item), year, _qualityLine(item)].where((s) => s.isNotEmpty).join('   ·   ');
    final overview = (item['Overview'] ?? '').toString();
    final progress = _progress(item);
    final label = item['Type'] == 'Series' ? 'Open' : (progress > 0 ? 'Resume' : 'Play');

    // Only the text cross-fades between titles. The Play button stays the same button, so
    // the controller can always jump back to it.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      layoutBuilder: (current, previous) =>
          Stack(alignment: Alignment.topLeft, children: [...previous, if (current != null) current]),
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
                      // Blurred once per title and kept as a picture (see BakedGlow), instead
                      // of being blurred again on every frame.
                      Positioned.fill(child: BakedGlow(url: logo, cacheHeight: _px(120))),
                      LogoImage(url: logo, height: 120, cacheHeight: _px(120), fallback: title),
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
        ],
      ),
      ),
          const SizedBox(height: 22),
          FocusLinks(
            down: () => _focusRow(0, 1),
            child: Row(children: [
            Focusable(
              autofocus: true,
              focusNode: _playNode,
              onSelect: () => _open(_featured),
              onFocus: (viaMouse) {
                if (!viaMouse) _setHero(true);
              },
              builder: (f) => AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 64,
                padding: const EdgeInsets.only(left: 26, right: 34),
                decoration: BoxDecoration(
                  color: f ? _fg : kPillFill,
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
            if (item['Type'] != 'Series') ...[
              const SizedBox(width: 16),
              Focusable(
                onSelect: () => startWatchTogether(context, jf, item),
                onFocus: (viaMouse) {
                  if (!viaMouse) _setHero(true);
                },
                builder: watchTogetherButton,
              ),
            ],
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
          ),
    ]);
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
  late final _nodes = FocusNodeList('Home: ${widget.title} card');
  int _last = 0; // the card that had focus last, so coming back to this row returns to it

  List<dynamic> get items => widget.items;
  Jellyfin get jf => widget.jf;

  // The row was refreshed (fresh data from the server replacing the saved screen, or after a
  // video) while one of its cards is selected: stay on the same title wherever it moved,
  // instead of keeping the position and silently landing on a different one.
  @override
  void didUpdateWidget(_MediaRow old) {
    super.didUpdateWidget(old);
    if (identical(old.items, widget.items) || !_nodes.anyFocused) return;
    final was = _last < old.items.length ? old.items[_last] : null;
    final now = was == null ? -1 : items.indexWhere((i) => i['Id'] == was['Id']);
    if (now == _last) return; // same title in the same place
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || items.isEmpty) return;
      if (now >= 0) {
        _last = now;
        _focusIndex(now);
      } else {
        // That title left the row (finished, say): the card now in its place, which becomes
        // the selected one, with its artwork.
        _last = _last.clamp(0, items.length - 1);
        _focusIndex(_last);
        widget.onFocus(items[_last]);
      }
    });
  }

  // Selects a card, scrolling to it first if it's off screen (cards off screen aren't built).
  void _focusIndex(int i) {
    if (focusOn(_nodes[i])) return;
    if (_scroll.hasClients) {
      final p = _scroll.position;
      _scroll.jumpTo((i * (cardW + 30) - 120).clamp(p.minScrollExtent, p.maxScrollExtent));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focusOn(_nodes[i]);
    });
  }

  // Called when the controller moves into this row from above or below.
  bool focusRow() {
    if (items.isEmpty) return false;
    final i = _last < items.length ? _last : 0;
    return focusOn(_nodes[i]) || _nodes.focusFirstVisible();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _nodes.dispose();
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
                          itemBuilder: (_, i) => _card(items[i], i),
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

  Widget _card(dynamic item, int index) {
    final progress = _progress(item);
    final episode = item['Type'] == 'Episode'
        ? [
            if (item['ParentIndexNumber'] != null) 'S${item['ParentIndexNumber']}',
            if (item['IndexNumber'] != null) 'E${item['IndexNumber']}',
          ].join(' · ')
        : '';
    return Focusable(
      focusNode: _nodes[index],
      onSelect: () => widget.onSelect(item),
      onFocus: (viaMouse) {
        _last = index;
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
                  // Shown while the picture loads, so a card never looks missing.
                  color: _placeholder,
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
                    netImage(
                      jf.thumbFor(item, maxWidth: sizeBucket(_px(cardW * 1.08))),
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
