// Library grid (one per Jellyfin library) and the show page with seasons and episodes.
// Keyboard: arrows move, Enter opens, Escape goes back (or closes a picker).

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main.dart' show Jellyfin;
import 'syncplay.dart' show startWatchTogether, watchTogetherButton, playOrParty;
import 'images.dart';
import 'movie.dart' show MovieScreen;
import 'ui.dart';

// ---------- Sorting ----------

class _Sort {
  const _Sort(this.label, this.sortBy, this.order);
  final String label;
  final String sortBy;
  final String order;
}

const _sorts = [
  _Sort('Recently added', 'DateCreated,SortName', 'Descending'),
  _Sort('A–Z', 'SortName', 'Ascending'),
  _Sort('Year', 'ProductionYear,SortName', 'Descending'),
  _Sort('Rating', 'CommunityRating,SortName', 'Descending'),
];

const _letters = ['#', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z'];

enum _Picker { none, sort, genre }

// ---------- Library grid ----------

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.jf, required this.libraries, required this.library});
  final Jellyfin jf;
  final List<dynamic> libraries;
  final dynamic library;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const _cols = 7;
  static const _gap = 30.0;
  static const _rowGap = 34.0;
  static const _pageSize = 100;

  Jellyfin get jf => widget.jf;
  String get _libId => widget.library['Id'];

  _Sort _sort = _sorts[0];
  bool _unwatched = false;
  bool _only4k = false;
  String? _genre;

  final List<dynamic> _items = [];
  int _total = 0;
  bool _firstLoad = true;
  int _generation = 0; // ignores answers from an older filter after the filters change

  List<String>? _genres;
  _Picker _picker = _Picker.none;
  final _pickerFirst = FocusNode();
  // The Sort and Genre buttons, so focus goes back to the one that opened the picker.
  final _sortChip = FocusNode();
  final _genreChip = FocusNode();
  final _unwatchedChip = FocusNode();
  final _fourKChip = FocusNode();
  FocusNode? _lastChip;

  // Fixed jumps for the controller: tabs ↓ filter buttons ↓ grid, and Up from the top row
  // of the grid goes back to the filter buttons (Flutter's guess skipped them from the left).
  final _posterNodes = FocusNodeList('Library: Poster');
  // Selected while the first posters load, so L2 / R2 and Back work straight away.
  final _rootFocus = namedNode('Library: loading');
  int _focusedIndex = 0;
  Timer? _prefetchTimer;

  bool _focusGrid() {
    if (_items.isEmpty) return false;
    final i = _focusedIndex < _items.length ? _focusedIndex : 0;
    return focusOn(_posterNodes[i]) || _posterNodes.focusFirstVisible();
  }
  final _grid = ScrollController();
  double _rowExtent = 400; // height of one grid row, measured at layout

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _grid.dispose();
    _pickerFirst.dispose();
    _sortChip.dispose();
    _genreChip.dispose();
    _unwatchedChip.dispose();
    _fourKChip.dispose();
    _posterNodes.dispose();
    _rootFocus.dispose();
    _prefetchTimer?.cancel();
    super.dispose();
  }

  // ---------- Loading ----------

  Future<void> _reload() async {
    _generation++;
    _inflight = null;
    setState(() {
      _items.clear();
      _total = 0;
      _firstLoad = true;
      _error = null;
    });
    if (_grid.hasClients) _grid.jumpTo(0);
    _focusedIndex = 0;
    await _loadMore();
  }

  // The page being fetched right now, if any. Asking for more while it loads waits for that
  // same page instead of returning straight away (which made the A–Z rail loop forever).
  Future<void>? _inflight;
  String? _error;

  Future<void> _loadMore() {
    final running = _inflight;
    if (running != null) return running;
    if (_error != null || (!_firstLoad && _items.length >= _total)) return Future.value();
    final page = _fetchPage(_generation);
    _inflight = page;
    page.whenComplete(() {
      if (identical(_inflight, page)) _inflight = null;
    });
    return page;
  }

  Future<void> _fetchPage(int gen) async {
    try {
      final page = await jf.libraryPage(
        parentId: _libId,
        sortBy: _sort.sortBy,
        sortOrder: _sort.order,
        start: _items.length,
        limit: _pageSize,
        unwatched: _unwatched,
        only4k: _only4k,
        genre: _genre,
      );
      if (!mounted || gen != _generation) return;
      final first = _items.isEmpty;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _firstLoad = false;
      });
      // The first posters arrived: select the first one (unless you moved somewhere already).
      if (first) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _rootFocus.hasPrimaryFocus) _focusGrid();
        });
      }
    } catch (e) {
      if (mounted && gen == _generation) {
        setState(() {
          _firstLoad = false;
          _error = errorText(e);
        });
      }
    }
  }

  // A–Z rail: count the titles before the letter, load up to there, and scroll to its row.
  Future<void> _jumpTo(String letter) async {
    var index = 0;
    if (letter != '#') {
      try {
        final before = await jf.libraryPage(
          parentId: _libId,
          sortBy: _sort.sortBy,
          sortOrder: _sort.order,
          limit: 0,
          unwatched: _unwatched,
          only4k: _only4k,
          genre: _genre,
          nameLessThan: letter,
        );
        index = before.total;
      } catch (_) {
        return;
      }
    }
    while (mounted && _items.length <= index && _items.length < _total) {
      final before = _items.length;
      await _loadMore();
      if (_items.length == before) break; // nothing new arrived (error or filters changed): stop
    }
    if (!mounted || !_grid.hasClients || !_grid.position.hasContentDimensions) return;
    final target = (index ~/ _cols) * (_rowExtent + _rowGap);
    _grid.animateTo(target.clamp(0.0, _grid.position.maxScrollExtent).toDouble(),
        duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
  }

  // After watching, refresh just that title (watched tick, progress) without losing my place.
  Future<void> _open(int index) async {
    final item = _items[index];
    if (item['Type'] == 'Series') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShowScreen(jf: jf, series: item)));
    } else if (item['Type'] == 'Movie') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MovieScreen(jf: jf, movie: item)));
    } else {
      await playOrParty(context, jf, item); // for the party when you're in one
    }
    try {
      final fresh = await jf.item(item['Id'], fresh: true);
      if (mounted && index < _items.length && _items[index]['Id'] == item['Id']) {
        setState(() => _items[index] = {...item, 'UserData': fresh['UserData']});
      }
    } catch (_) {}
  }

  // ---------- Pickers (sort and genre) ----------

  Future<void> _openPicker(_Picker picker) async {
    if (_genres == null) { // the sheet always shows the Genre column
      try {
        _genres = await jf.genres(_libId);
      } catch (_) {
        _genres = [];
      }
    }
    if (!mounted) return;
    setState(() => _picker = picker);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pickerFirst.context != null) _pickerFirst.requestFocus();
    });
  }

  void _closePicker() {
    final opener = _picker == _Picker.sort ? _sortChip : _genreChip;
    setState(() => _picker = _Picker.none);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && opener.context != null) opener.requestFocus();
    });
  }

  // L2 / R2 (Page Up / Page Down): the tab to the left or right.
  void _switchTab(int step) {
    final i = widget.libraries.indexWhere((l) => l['Id'] == _libId);
    final next = i + step;
    if (next < 0) {
      Navigator.of(context).popUntil((r) => r.isFirst); // left of the first library: Home
    } else if (next < widget.libraries.length) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => LibraryScreen(jf: jf, libraries: widget.libraries, library: widget.libraries[next])));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_picker == _Picker.none &&
        (event.logicalKey == LogicalKeyboardKey.pageUp || event.logicalKey == LogicalKeyboardKey.pageDown)) {
      _switchTab(event.logicalKey == LogicalKeyboardKey.pageUp ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape || event.logicalKey == LogicalKeyboardKey.backspace) {
      if (_picker != _Picker.none) {
        _closePicker();
      } else if (_posterNodes.anyFocused && _grid.hasClients && _grid.offset > 1) {
        // Deep in the grid: back to the top first (the filters), then Back again leaves.
        _grid.animateTo(0, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
        focusOn(_lastChip ?? _sortChip);
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------- Building ----------

  @override
  Widget build(BuildContext context) {
    final filters = [
      if (_unwatched) 'unwatched',
      if (_only4k) '4K',
      if (_genre != null) _genre!,
    ];
    final subtitle = _firstLoad
        ? 'Loading…'
        : '$_total ${_total == 1 ? 'title' : 'titles'} · ${_sort.label}'
            '${filters.isEmpty ? '' : ' · ${filters.join(', ')}'}';
    final showRail = _sort.label == 'A–Z' && _total > 40;

    return Focus(
      focusNode: _rootFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: kBg,
        body: TvCanvas(
          child: Stack(children: [
            Positioned(
              left: 120,
              top: 52,
              right: 200,
              child: FocusLinks(
                down: () => focusOn(_lastChip ?? _sortChip),
                child: NavBar(
                libraries: widget.libraries,
                currentId: _libId,
                onHome: () => Navigator.of(context).popUntil((r) => r.isFirst),
                onLibrary: (lib) {
                  if (lib['Id'] == _libId) return;
                  Navigator.of(context).pushReplacement(MaterialPageRoute(
                      builder: (_) => LibraryScreen(jf: jf, libraries: widget.libraries, library: lib)));
                },
              ),
              ),
            ),
            Positioned(left: 120, right: 120, top: 150, child: _header(subtitle)),
            // The grid is clipped to its own area (so scrolled-away posters can't cover the
            // header), with 24 px of extra room on each side for the selected poster's glow.
            Positioned(
              left: 96,
              right: showRail ? 176 : 96,
              top: 250,
              bottom: 0,
              child: _gridView(),
            ),
            // Soft fade where the grid scrolls under the bottom edge.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 140,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [kBg.withOpacity(0), kBg],
                    ),
                  ),
                ),
              ),
            ),
            if (showRail) Positioned(right: 120, top: 284, bottom: 110, width: 48, child: _rail()),
            if (_picker != _Picker.none) _pickerPanel(),
          ]),
        ),
      ),
    );
  }

  Widget _header(String subtitle) {
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.library['Name']?.toString() ?? 'Library', style: tvDisplay(48)),
          const SizedBox(height: 6),
          Text(subtitle, style: tvBody(22, color: kDim)),
        ]),
      ),
      FocusLinks(
        down: _focusGrid,
        child: FocusTraversalGroup(
        // One button: everything (sort, unwatched, 4K, genre) is in the sheet it opens. Lit up
        // while a filter is on; the line under the library's name says which.
        child: Wrap(spacing: 12, children: [
          Focusable(
            focusNode: _sortChip,
            onFocus: (_) => _lastChip = _sortChip,
            onSelect: () => _openPicker(_Picker.sort),
            builder: (f) => tvPill('Sort & filter',
                focused: f, on: _unwatched || _only4k || _genre != null, icon: Icons.tune_rounded),
          ),
        ]),
        ),
      ),
    ]);
  }

  Widget _gridView() {
    if (_firstLoad) {
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Text('Loading…', style: tvBody(26, color: kMuted)),
        ),
      );
    }
    if (_error != null && _items.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 40, left: 24),
          child: TvError(message: _error!, onRetry: _reload),
        ),
      );
    }
    if (_items.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Text(
              _unwatched || _only4k || _genre != null ? 'Nothing matches these filters.' : 'This library is empty.',
              style: tvBody(26, color: kMuted)),
        ),
      );
    }
    return LayoutBuilder(builder: (context, box) {
      final cellW = (box.maxWidth - 48 - _gap * (_cols - 1)) / _cols;
      final posterH = cellW * 1.5;
      _rowExtent = posterH + 66;
      return FocusLinks(
        up: () => _focusedIndex < _cols && focusOn(_lastChip ?? _sortChip),
        child: FocusTraversalGroup(
        child: GridView.builder(
          controller: _grid,
          clipBehavior: Clip.hardEdge,
          // Keep two rows built above and below the screen, so arrow keys always have a
          // poster to move to, even at the edge of what's visible.
          cacheExtent: (_rowExtent + _rowGap) * 2,
          padding: const EdgeInsets.fromLTRB(24, 34, 24, 160),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _cols,
            crossAxisSpacing: _gap,
            mainAxisSpacing: _rowGap,
            mainAxisExtent: _rowExtent,
          ),
          itemCount: _items.length,
          itemBuilder: (_, i) {
            // Fetch the next page before reaching the end.
            if (i >= _items.length - _cols * 3) _loadMore();
            return _poster(i, cellW, posterH);
          },
        ),
        ),
      );
    });
  }

  Widget _poster(int index, double w, double h) {
    final item = _items[index];
    final watched = isWatched(item);
    final progress = progressOf(item);
    final badge = item['Type'] == 'Movie' ? qualityBadge(item) : '';
    final year = item['ProductionYear']?.toString() ?? '';

    return Focusable(
      // The first poster takes focus when the screen opens, so the keyboard works right away.
      autofocus: index == 0,
      focusNode: _posterNodes[index],
      onFocus: (_) {
        _focusedIndex = index;
        // A show selected for a moment: fetch its page now, so opening it is instant.
        _prefetchTimer?.cancel();
        if (item['Type'] == 'Series') {
          _prefetchTimer = Timer(const Duration(milliseconds: 250), () => jf.prefetchShow(item));
        }
      },
      scrollAlignment: 0.25,
      onSelect: () => _open(index),
      builder: (f) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AnimatedScale(
          scale: f ? 1.07 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: w,
            height: h,
            decoration: BoxDecoration(
              // Shown while the poster loads, so it never looks missing.
              color: kPlaceholder,
              borderRadius: BorderRadius.circular(12),
              boxShadow: f
                  ? [
                      const BoxShadow(color: kBg, spreadRadius: 4),
                      BoxShadow(color: kFg.withOpacity(0.95), spreadRadius: 8),
                      BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 40, offset: const Offset(0, 20)),
                    ]
                  : [],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(fit: StackFit.expand, children: [
                netImage(
                  // Downloaded at the size it's shown on this screen (sharper on 4K, smaller on 1080p).
                  jf.image(item['Id'], 'Primary', maxWidth: sizeBucket(tvPx(w * 1.07))),
                  cacheWidth: tvPx(w * 1.07),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: kPlaceholder,
                    padding: const EdgeInsets.all(14),
                    alignment: Alignment.bottomLeft,
                    child: Text(titleOf(item), style: tvBody(19, weight: FontWeight.w700)),
                  ),
                ),
                if (f && badge.isNotEmpty)
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration:
                          BoxDecoration(color: kBg.withOpacity(0.8), borderRadius: BorderRadius.circular(6)),
                      child: Text(badge, style: tvBody(14, weight: FontWeight.w700)),
                    ),
                  ),
                if (watched)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(color: kBg.withOpacity(0.8), shape: BoxShape.circle),
                      child: const Icon(Icons.check_rounded, size: 20, color: kFg),
                    ),
                  ),
                if (progress > 0 && !watched)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      height: 5,
                      color: kFg.withOpacity(0.25),
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(widthFactor: progress, child: Container(color: kFg)),
                    ),
                  ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(item['Name']?.toString() ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tvBody(20, weight: f ? FontWeight.w700 : FontWeight.w600, color: f ? kFg : kSoft)),
        Text(year, style: tvBody(17, color: kDim)),
      ]),
    );
  }

  Widget _rail() {
    return FocusTraversalGroup(
      child: Container(
        decoration: BoxDecoration(color: kFg.withOpacity(0.06), borderRadius: BorderRadius.circular(999)),
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final l in _letters)
              Focusable(
                onSelect: () => _jumpTo(l),
                builder: (f) => AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 34,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: f ? kFg : Colors.transparent, borderRadius: BorderRadius.circular(999)),
                  child: Text(l, style: tvBody(16, weight: FontWeight.w700, color: f ? kBg : kDim)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---------- Sort & filter sheet ----------
  //
  // Slides up from the bottom (like the profile menu), with everything in three columns:
  // Sort by, Show (Unwatched, 4K) and Genre. Each choice applies straight away and the sheet
  // stays open, so they combine; Circle closes it. It opens on the column of the button that
  // opened it.

  static const _sheet = Color(0xFF12151B);

  // One choice: a pill, white with a ring when selected; the current one is lighter and ticked.
  Widget _choice(String label, bool on, VoidCallback onSelect, {FocusNode? node, double height = 64}) => Focusable(
        focusNode: node,
        scrollAlignment: 0.3,
        onSelect: () {
          onSelect();
          _reload();
        },
        builder: (f) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 26),
          decoration: BoxDecoration(
            color: f ? kFg : kFg.withOpacity(on ? 0.18 : 0.08),
            borderRadius: BorderRadius.circular(999),
            boxShadow: f ? const [BoxShadow(color: _sheet, spreadRadius: 4), BoxShadow(color: kFg, spreadRadius: 9)] : const [],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: tvBody(height > 60 ? 24 : 22, weight: f || on ? FontWeight.w700 : FontWeight.w600, color: f ? kBg : kFg)),
            ),
            if (on) ...[
              const SizedBox(width: 12),
              Icon(Icons.check_rounded, size: 28, color: f ? kBg : kFg),
            ],
          ]),
        ),
      );

  // A switch row: label, then a small switch in the profile's colour.
  Widget _toggle(String label, bool on, VoidCallback onSelect, {FocusNode? node}) => Focusable(
        focusNode: node,
        onSelect: () {
          onSelect();
          _reload();
        },
        builder: (f) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 64,
          padding: const EdgeInsets.fromLTRB(26, 0, 14, 0),
          decoration: BoxDecoration(
            color: f ? kFg : kFg.withOpacity(0.08),
            borderRadius: BorderRadius.circular(999),
            boxShadow: f ? const [BoxShadow(color: _sheet, spreadRadius: 4), BoxShadow(color: kFg, spreadRadius: 9)] : const [],
          ),
          child: Row(children: [
            Expanded(
              child: Text(label, style: tvBody(24, weight: FontWeight.w600, color: f ? kBg : kFg)),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 64,
              height: 36,
              padding: const EdgeInsets.all(4),
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                color: on ? kAccent : (f ? kBg.withOpacity(0.25) : kFg.withOpacity(0.22)),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(shape: BoxShape.circle, color: f && !on ? kBg : kFg),
              ),
            ),
          ]),
        ),
      );

  Widget _columnTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Text(text.toUpperCase(), style: tvBody(20, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1.6)),
      );

  Widget _pickerPanel() {
    final isSort = _picker == _Picker.sort;
    final genres = _genres ?? const <String>[];
    final filters = [
      if (_unwatched) 'unwatched',
      if (_only4k) '4K',
      if (_genre != null) _genre!,
    ];
    return Positioned.fill(
      child: Stack(children: [
        // The library behind, dimmed; a click there closes the sheet.
        Positioned.fill(
          child: GestureDetector(onTap: _closePicker, child: Container(color: kBg.withOpacity(0.5))),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 560,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            builder: (_, t, child) => Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform.translate(offset: Offset(0, 100 * (1 - t)), child: child),
            ),
            child: Container(
              padding: const EdgeInsets.fromLTRB(120, 40, 120, 0),
              decoration: BoxDecoration(
                color: _sheet.withOpacity(0.97),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(36)),
                border: Border(top: BorderSide(color: kFg.withOpacity(0.08))),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                    Text(widget.library['Name']?.toString() ?? 'Library', style: tvDisplay(40)),
                    const SizedBox(width: 20),
                    Text(
                        '$_total ${_total == 1 ? 'title' : 'titles'}${filters.isEmpty ? '' : ' · ${filters.join(', ')}'}',
                        style: tvBody(22, color: kMuted)),
                  ]),
                  const SizedBox(height: 30),
                  Expanded(
                    child: FocusScope(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        // Sort by
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            _columnTitle('Sort by'),
                            for (final srt in _sorts)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _choice(srt.label, srt.label == _sort.label, () => setState(() => _sort = srt),
                                    node: isSort && srt.label == _sort.label ? _pickerFirst : null),
                              ),
                          ]),
                        ),
                        const SizedBox(width: 60),
                        // Show
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            _columnTitle('Show'),
                            _toggle('Unwatched only', _unwatched, () => setState(() => _unwatched = !_unwatched)),
                            const SizedBox(height: 12),
                            _toggle('4K only', _only4k, () => setState(() => _only4k = !_only4k)),
                          ]),
                        ),
                        const SizedBox(width: 60),
                        // Genre
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            _columnTitle('Genre'),
                            Expanded(
                              child: SingleChildScrollView(
                                clipBehavior: Clip.none,
                                padding: const EdgeInsets.only(bottom: 40),
                                child: Wrap(spacing: 12, runSpacing: 12, children: [
                                  _choice('All', _genre == null, () => setState(() => _genre = null),
                                      node: !isSort && _genre == null ? _pickerFirst : null, height: 56),
                                  for (final g in genres)
                                    _choice(g, g == _genre, () => setState(() => _genre = g),
                                        node: !isSort && g == _genre ? _pickerFirst : null, height: 56),
                                ]),
                              ),
                            ),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// ---------- Show page ----------

class ShowScreen extends StatefulWidget {
  const ShowScreen({super.key, required this.jf, required this.series});
  final Jellyfin jf;
  final dynamic series;

  @override
  State<ShowScreen> createState() => _ShowScreenState();
}

class _ShowScreenState extends State<ShowScreen> {
  Jellyfin get jf => widget.jf;
  String get _id => widget.series['Id'];

  dynamic _details;
  List<dynamic> _seasons = [];
  int _season = 0;
  List<dynamic> _episodes = [];
  dynamic _next;
  bool _loading = true;

  // Mouse arrows on the episode row.
  final _epScroll = ScrollController();
  bool _epHover = false;

  // Hero layout: full artwork while focus is on the top buttons; episodes rise when focus moves down.
  bool _hero = true;
  static const _move = Duration(milliseconds: 420);

  @override
  void initState() {
    super.initState();
    _load();
  }

  // Every focusable thing on the page, so Up and Down always go to the right place:
  //   Back button  ↕  Play / Mark watched  ↕  season tabs  ↕  episodes
  final _backNode = namedNode('Show: Back');
  final _playNode = namedNode('Show: Play/Resume');
  final _markNode = namedNode('Show: Mark watched');
  final _tabNodes = FocusNodeList('Show: Season tab');
  final _epNodes = FocusNodeList('Show: Episode');
  int _lastEp = -1; // the episode that had focus last, so coming back down returns to it

  void _setHero(bool hero) {
    if (_hero != hero) setState(() => _hero = hero);
  }

  bool _focusBelowButtons() => _seasons.length > 1 ? focusOn(_tabNodes[_season]) : _focusEpisode();

  bool _focusEpisode() {
    if (_episodes.isEmpty) return true; // still loading: stay where we are
    var i = _lastEp;
    if (i < 0 || i >= _episodes.length) {
      final next = _next;
      i = next == null ? 0 : _episodes.indexWhere((e) => e['Id'] == next['Id']);
      if (i < 0) i = 0;
    }
    return focusOn(_epNodes[i]) || _epNodes.focusFirstVisible();
  }

  bool _focusAboveEpisodes() => _seasons.length > 1 ? focusOn(_tabNodes[_season]) : focusOn(_playNode);

  @override
  void dispose() {
    _markTimer?.cancel();
    _seasonTimer?.cancel();
    _epScroll.dispose();
    _backNode.dispose();
    _playNode.dispose();
    _markNode.dispose();
    _tabNodes.dispose();
    _epNodes.dispose();
    super.dispose();
  }

  void _pageEpisodes(int direction) {
    if (!_epScroll.hasClients || !_epScroll.position.hasContentDimensions) return;
    final p = _epScroll.position;
    final target = (p.pixels + direction * 1170).clamp(p.minScrollExtent, p.maxScrollExtent).toDouble();
    _epScroll.animateTo(target, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
  }

  Widget _epArrow(int direction) {
    // Only check positions once the row has been laid out.
    final canMove = _epScroll.hasClients &&
        _epScroll.position.hasContentDimensions &&
        (direction < 0
            ? _epScroll.position.pixels > _epScroll.position.minScrollExtent + 1
            : _epScroll.position.pixels < _epScroll.position.maxScrollExtent - 1);
    final show = _epHover && canMove;
    return AnimatedOpacity(
      opacity: show ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: IgnorePointer(
        ignoring: !show,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _pageEpisodes(direction),
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: kBg.withOpacity(0.75), shape: BoxShape.circle),
              child: Icon(direction < 0 ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                  size: 44, color: kFg),
            ),
          ),
        ),
      ),
    );
  }

  String? _error;

  // fresh: ask the server again (after watching or marking), instead of using what was
  // fetched a moment ago when the show's card was selected.
  Future<void> _load({bool keepSeason = false, bool fresh = false}) async {
    if (fresh) jf.forgetShow(_id);
    Object? failure;
    final results = await Future.wait([
      jf.item(_id).catchError((_) => widget.series),
      jf.seasons(_id).catchError((Object e) {
        failure = e;
        return <dynamic>[];
      }),
      jf.nextUp(_id),
    ]);
    if (!mounted) return;
    if (failure != null) {
      // Keep what's on screen after a failed refresh; only show the error when there's nothing.
      setState(() {
        _loading = false;
        if (_seasons.isEmpty) _error = errorText(failure!);
      });
      return;
    }
    _error = null;
    final seasons = results[1] as List<dynamic>;
    final next = results[2];
    var season = keepSeason ? _season : 0;
    if (!keepSeason && next != null) {
      final i = seasons.indexWhere((s) => s['Id'] == next['SeasonId']);
      if (i >= 0) season = i;
    }
    setState(() {
      _details = results[0];
      _seasons = seasons;
      _next = next;
      _season = season.clamp(0, seasons.isEmpty ? 0 : seasons.length - 1);
    });
    await _loadEpisodes();
  }

  Future<void> _loadEpisodes() async {
    if (_seasons.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final seasonId = _seasons[_season]['Id'];
    try {
      final eps = await jf.seasonEpisodes(_id, seasonId);
      if (mounted && _seasons.isNotEmpty && _seasons[_season]['Id'] == seasonId) {
        setState(() {
          _episodes = eps;
          _loading = false;
        });
        _scrollToNext();
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // The episode row opens on the next episode to watch, not Episode 1.
  static const _epStep = 360.0 + 30.0; // card width + gap
  void _scrollToNext() {
    final next = _next;
    if (next == null) return;
    final i = _episodes.indexWhere((e) => e['Id'] == next['Id']);
    if (i <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_epScroll.hasClients || !_epScroll.position.hasContentDimensions) return;
      final p = _epScroll.position;
      _epScroll.jumpTo((i * _epStep).clamp(p.minScrollExtent, p.maxScrollExtent).toDouble());
      // Back from watching an episode: select the next one, so Select plays it right away.
      if (_epNodes.anyFocused) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && focusOn(_epNodes[i])) _lastEp = i;
        });
      }
    });
  }

  // Moving across the season tabs: a season seen before shows at once; a new one waits until
  // the tab has been selected for a moment, so holding Left across 28 seasons doesn't send
  // 28 requests.
  Timer? _seasonTimer;

  void _pickSeason(int i) {
    if (i == _season) return;
    _seasonTimer?.cancel();
    final cached = jf.isCached(Jellyfin.episodesKey(_id, _seasons[i]['Id']));
    setState(() {
      _season = i;
      _episodes = [];
      _lastEp = -1;
      _loading = true;
    });
    if (cached) {
      _loadEpisodes();
    } else {
      _seasonTimer = Timer(const Duration(milliseconds: 180), _loadEpisodes);
    }
  }

  Future<void> _play(dynamic episode) async {
    await playOrParty(context, jf, episode); // for the party when you're in one
    // Back from watching: the page moves to the next episode's season (after a season finale,
    // that's the next season), with the next episode selected.
    _load(fresh: true);
  }

  // Marking a whole season can't be undone from here, so it takes two presses:
  // the first asks "Press again to confirm" for a few seconds.
  bool _confirmMark = false;
  String? _markNote;
  Timer? _markTimer;

  Future<void> _markSeason() async {
    if (_seasons.isEmpty) return;
    _markTimer?.cancel();
    if (!_confirmMark) {
      setState(() => _confirmMark = true);
      _markTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _confirmMark = false);
      });
      return;
    }
    setState(() {
      _confirmMark = false;
      _markNote = 'Marking…';
    });
    try {
      await jf.markPlayed(_seasons[_season]['Id']);
      if (mounted) setState(() => _markNote = 'Season marked watched');
      await _load(keepSeason: true, fresh: true);
    } catch (e) {
      if (mounted) setState(() => _markNote = errorText(e));
    }
    _markTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _markNote = null);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.escape || event.logicalKey == LogicalKeyboardKey.backspace)) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    // L2 / R2 (Page Up / Page Down): previous or next season, with its tab selected.
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.pageUp || event.logicalKey == LogicalKeyboardKey.pageDown)) {
      final next = _season + (event.logicalKey == LogicalKeyboardKey.pageUp ? -1 : 1);
      if (next >= 0 && next < _seasons.length) {
        _pickSeason(next);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) focusOn(_tabNodes[next]);
        });
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final series = _details ?? widget.series;
    final logo = jf.logoFor(series);
    final title = Text(series['Name']?.toString() ?? '', style: tvDisplay(64), maxLines: 2);
    final sample = _episodes.isNotEmpty ? _episodes.first : _next;
    final meta = [
      series['ProductionYear']?.toString() ?? '',
      if (_seasons.isNotEmpty) '${_seasons.length} ${_seasons.length == 1 ? 'season' : 'seasons'}',
      if (sample != null) qualityLine(sample),
    ].where((s) => s.isNotEmpty).join(' · ');
    final overview = (series['Overview'] ?? '').toString();

    final next = _next;
    final nextLabel = next == null
        ? 'Play'
        : '${progressOf(next) > 0 ? 'Resume' : 'Play'} '
            'S${next['ParentIndexNumber'] ?? '?'} · E${next['IndexNumber'] ?? '?'}';

    return Focus(
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: kBg,
        body: TvCanvas(
          child: Stack(children: [
            Positioned.fill(
              child: RepaintBoundary(
                // Keep the top of the artwork (faces, titles); trim the hidden bottom instead.
                child: netImage(
                  jf.backdropFor(series, maxWidth: sizeBucket(tvPx(1920)).clamp(1280, 2560)),
                  cacheWidth: sizeBucket(tvPx(1920)).clamp(1280, 2560),
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => const ColoredBox(color: kPlaceholder),
                ),
              ),
            ),
            // Shading over the backdrop: one small picture stretched, made once (see ShadeOverlay).
            const Positioned.fill(child: ShadeOverlay(shades: [kShadeLeft, kShadeTopBottom])),
            // Strong fade under the episodes, only when they're up (see FadingShade).
            Positioned.fill(
              child: FadingShade(
                visible: !_hero,
                duration: _move,
                curve: Curves.easeOutCubic,
                alphas: const [0, 0, 0.9, 1],
                stops: const [0, 0.34, 0.56, 0.72],
              ),
            ),
            Positioned(
              left: 120,
              top: 52,
              child: FocusLinks(
                down: () => focusOn(_playNode),
                child: Focusable(
                focusNode: _backNode,
                onSelect: () => Navigator.of(context).maybePop(),
                onFocus: (viaMouse) {
                  if (!viaMouse) _setHero(true);
                },
                builder: (f) => AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: f ? kFg : kFg.withOpacity(0.12)),
                  child: Icon(Icons.arrow_back_rounded, size: 28, color: f ? kBg : kFg),
                ),
              ),
              ),
            ),
            // Title, summary and buttons sit low over the full artwork, and move up when the
            // episodes rise.
            AnimatedPositioned(
              duration: _move,
              curve: Curves.easeOutCubic,
              left: 120,
              top: _hero ? 470 : 140,
              width: 1000,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  height: 120,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: logo == null
                        ? title
                        : LogoImage(url: logo, height: 120, cacheHeight: tvPx(120), fallback: title),
                  ),
                ),
                const SizedBox(height: 16),
                Text(meta, style: tvBody(26, color: kSoft)),
                if (overview.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: 780,
                    child: Text(overview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: tvBody(24, weight: FontWeight.w400, color: const Color(0xFFC3C9D3), height: 1.45)),
                  ),
                ],
                const SizedBox(height: 22),
                FocusLinks(
                  up: () => focusOn(_backNode),
                  down: _focusBelowButtons,
                  child: FocusTraversalGroup(
                  child: Row(children: [
                    Focusable(
                      autofocus: true,
                      focusNode: _playNode,
                      onFocus: (viaMouse) {
                        if (!viaMouse) _setHero(true);
                      },
                      onSelect: () {
                        final target = _next ?? (_episodes.isNotEmpty ? _episodes.first : null);
                        if (target != null) _play(target);
                      },
                      builder: (f) => AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        height: 64,
                        padding: const EdgeInsets.only(left: 26, right: 34),
                        decoration: BoxDecoration(
                          color: f ? kFg : kPillFill,
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: f ? [BoxShadow(color: kFg.withOpacity(0.22), spreadRadius: 5)] : [],
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.play_arrow_rounded, size: 34, color: f ? kBg : kFg),
                          const SizedBox(width: 10),
                          Text(nextLabel, style: tvBody(26, weight: FontWeight.w700, color: f ? kBg : kFg)),
                        ]),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Focusable(
                      onFocus: (viaMouse) {
                        if (!viaMouse) _setHero(true);
                      },
                      onSelect: () {
                        final target = _next ?? (_episodes.isNotEmpty ? _episodes.first : null);
                        if (target != null) startWatchTogether(context, jf, target);
                      },
                      builder: watchTogetherButton,
                    ),
                    const SizedBox(width: 16),
                    Focusable(
                      focusNode: _markNode,
                      onFocus: (viaMouse) {
                        if (!viaMouse) _setHero(true);
                      },
                      onSelect: _markSeason,
                      builder: (f) => AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        height: 64,
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: f ? kFg : kPillFill,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(_markNote ?? (_confirmMark ? 'Press again to confirm' : 'Mark season watched'),
                            style: tvBody(24, weight: FontWeight.w600, color: f ? kBg : kFg)),
                      ),
                    ),
                  ]),
                  ),
                ),
              ]),
            ),
            // Seasons and episodes peek in at the bottom over the full artwork, and rise when
            // focus moves down into them.
            AnimatedPositioned(
              duration: _move,
              curve: Curves.easeOutCubic,
              left: 0,
              right: 0,
              top: _hero ? 880 : 600,
              bottom: 0,
              child: Stack(children: [
                Positioned(
                  left: 120,
                  right: 120,
                  top: 0,
                  child: FocusLinks(up: () => focusOn(_playNode), down: _focusEpisode, child: _seasonTabs()),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: _seasons.length > 1 ? 76 : 0,
                  bottom: 0,
                  child: FocusLinks(up: _focusAboveEpisodes, child: _episodeRow()),
                ),
              ]),
            ),
            // Mouse wheel: down brings the episodes up, up goes back to the full artwork.
            // It listens without blocking clicks on anything underneath.
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
                    final hero = event.scrollDelta.dy < 0;
                    if (hero != _hero) setState(() => _hero = hero);
                  }
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _seasonTabs() {
    if (_seasons.length <= 1) return const SizedBox.shrink();
    return FocusTraversalGroup(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        child: Row(children: [
          for (var i = 0; i < _seasons.length; i++) ...[
            Focusable(
              focusNode: _tabNodes[i],
              scrollAlignment: 0,
              onSelect: () => _pickSeason(i),
              // Moving across the tabs with the controller shows each season's episodes.
              onFocus: (viaMouse) {
                if (!viaMouse) {
                  _setHero(false);
                  _pickSeason(i);
                }
              },
              builder: (f) => tvPill(_seasons[i]['Name']?.toString() ?? 'Season ${i + 1}',
                  focused: f, on: i == _season, size: 23),
            ),
            const SizedBox(width: 8),
          ],
        ]),
      ),
    );
  }

  Widget _episodeRow() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.only(left: 120, top: 30),
        child: TvError(
          message: _error!,
          onRetry: () {
            setState(() {
              _error = null;
              _loading = true;
            });
            _load();
          },
        ),
      );
    }
    if (_loading && _episodes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(left: 120, top: 30),
        child: Text('Loading…', style: tvBody(26, color: kMuted)),
      );
    }
    if (_episodes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(left: 120, top: 30),
        child: Text('No episodes in this season.', style: tvBody(26, color: kMuted)),
      );
    }
    const w = 360.0, h = 203.0;
    return MouseRegion(
      onEnter: (_) => setState(() => _epHover = true),
      onExit: (_) => setState(() => _epHover = false),
      child: Stack(children: [
        Positioned.fill(child: _episodeList(w, h)),
        // Only the arrows redraw while the row scrolls.
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _epScroll,
            builder: (_, __) => Stack(children: [
              Positioned(left: 36, top: 16 + h / 2 - 32, child: _epArrow(-1)),
              Positioned(right: 36, top: 16 + h / 2 - 32, child: _epArrow(1)),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _episodeList(double w, double h) {
    return FocusTraversalGroup(
      child: ListView.separated(
        controller: _epScroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(120, 16, 120, 0),
        itemCount: _episodes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 30),
        itemBuilder: (_, i) {
          final ep = _episodes[i];
          final watched = isWatched(ep);
          final progress = progressOf(ep);
          final mins = runtimeMinutes(ep);
          final overview = (ep['Overview'] ?? '').toString();
          return Focusable(
            focusNode: _epNodes[i],
            onFocus: (viaMouse) {
              _lastEp = i;
              if (!viaMouse) _setHero(false);
            },
            onSelect: () => _play(ep),
            builder: (f) => SizedBox(
              width: w,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AnimatedScale(
                  scale: f ? 1.06 : 1,
                  duration: const Duration(milliseconds: 160),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: w,
                    height: h,
                    decoration: BoxDecoration(
                      // Shown while the picture loads, so a card never looks missing.
                      color: kPlaceholder,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: f
                          ? [
                              const BoxShadow(color: kBg, spreadRadius: 4),
                              BoxShadow(color: kFg.withOpacity(0.95), spreadRadius: 8),
                              BoxShadow(
                                  color: Colors.black.withOpacity(0.6), blurRadius: 40, offset: const Offset(0, 20)),
                            ]
                          : [],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Stack(fit: StackFit.expand, children: [
                        netImage(
                          jf.image(ep['Id'], 'Primary', maxWidth: sizeBucket(tvPx(w * 1.06))),
                          cacheWidth: tvPx(w * 1.06),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const ColoredBox(color: kPlaceholder),
                        ),
                        if (f)
                          Center(
                            child: Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(color: kFg.withOpacity(0.92), shape: BoxShape.circle),
                              child: const Icon(Icons.play_arrow_rounded, size: 40, color: kBg),
                            ),
                          ),
                        if (watched && !f)
                          Positioned(
                            top: 12,
                            right: 12,
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(color: kBg.withOpacity(0.8), shape: BoxShape.circle),
                              child: const Icon(Icons.check_rounded, size: 20, color: kFg),
                            ),
                          ),
                        if (progress > 0 && !watched)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              height: 5,
                              color: kFg.withOpacity(0.25),
                              alignment: Alignment.centerLeft,
                              child: FractionallySizedBox(widthFactor: progress, child: Container(color: kFg)),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'EPISODE ${ep['IndexNumber'] ?? '?'}${mins > 0 ? ' · $mins MIN' : ''}',
                  style: tvBody(18, weight: FontWeight.w700, color: kDim).copyWith(letterSpacing: 0.7),
                ),
                const SizedBox(height: 4),
                Text(ep['Name']?.toString() ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tvBody(23, weight: FontWeight.w700, color: f ? kFg : kSoft)),
                if (overview.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(overview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tvBody(19, weight: FontWeight.w400, color: const Color(0xFFA8B0BD), height: 1.4)),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }
}
