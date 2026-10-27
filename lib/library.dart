// Library grid (one per Jellyfin library) and the show page with seasons and episodes.
// Keyboard: arrows move, Enter opens, Escape goes back (or closes a picker).

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main.dart' show Jellyfin;
import 'player.dart';
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
  bool _loading = false;
  bool _firstLoad = true;
  int _generation = 0; // ignores answers from an older filter after the filters change

  List<String>? _genres;
  _Picker _picker = _Picker.none;
  final _pickerFirst = FocusNode();
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
    super.dispose();
  }

  // ---------- Loading ----------

  Future<void> _reload() async {
    _generation++;
    setState(() {
      _items.clear();
      _total = 0;
      _firstLoad = true;
      _loading = false;
    });
    if (_grid.hasClients) _grid.jumpTo(0);
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || (!_firstLoad && _items.length >= _total)) return;
    final gen = _generation;
    _loading = true;
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
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _firstLoad = false;
      });
    } catch (_) {
      if (mounted && gen == _generation) setState(() => _firstLoad = false);
    } finally {
      if (gen == _generation) _loading = false;
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
      await _loadMore();
    }
    if (!mounted || !_grid.hasClients || !_grid.position.hasContentDimensions) return;
    final target = (index ~/ _cols) * (_rowExtent + _rowGap);
    _grid.animateTo(target.clamp(0.0, _grid.position.maxScrollExtent).toDouble(),
        duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
  }

  // After watching, refresh just that title (watched tick, progress) without losing my place.
  Future<void> _open(int index) async {
    final item = _items[index];
    final Widget screen =
        item['Type'] == 'Series' ? ShowScreen(jf: jf, series: item) : PlayerScreen(jf: jf, item: item);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    try {
      final fresh = await jf.item(item['Id']);
      if (mounted && index < _items.length && _items[index]['Id'] == item['Id']) {
        setState(() => _items[index] = {...item, 'UserData': fresh['UserData']});
      }
    } catch (_) {}
  }

  // ---------- Pickers (sort and genre) ----------

  Future<void> _openPicker(_Picker picker) async {
    if (picker == _Picker.genre && _genres == null) {
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

  void _closePicker() => setState(() => _picker = _Picker.none);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape || event.logicalKey == LogicalKeyboardKey.backspace) {
      if (_picker != _Picker.none) {
        _closePicker();
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
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: kBg,
        body: TvCanvas(
          child: Stack(children: [
            Positioned(
              left: 120,
              top: 52,
              right: 200,
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
      FocusTraversalGroup(
        child: Wrap(spacing: 12, children: [
          Focusable(
            onSelect: () => _openPicker(_Picker.sort),
            builder: (f) => tvPill(_sort.label, focused: f, icon: Icons.swap_vert_rounded),
          ),
          Focusable(
            onSelect: () {
              setState(() => _unwatched = !_unwatched);
              _reload();
            },
            builder: (f) => tvPill('Unwatched', focused: f, on: _unwatched),
          ),
          Focusable(
            onSelect: () {
              setState(() => _only4k = !_only4k);
              _reload();
            },
            builder: (f) => tvPill('4K', focused: f, on: _only4k),
          ),
          Focusable(
            onSelect: () => _openPicker(_Picker.genre),
            builder: (f) => tvPill(_genre ?? 'Genre', focused: f, on: _genre != null, icon: Icons.expand_more_rounded),
          ),
        ]),
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
    if (_items.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Text('Nothing matches these filters.', style: tvBody(26, color: kMuted)),
        ),
      );
    }
    return LayoutBuilder(builder: (context, box) {
      final cellW = (box.maxWidth - 48 - _gap * (_cols - 1)) / _cols;
      final posterH = cellW * 1.5;
      _rowExtent = posterH + 66;
      return FocusTraversalGroup(
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
                Image.network(
                  jf.image(item['Id'], 'Primary', maxWidth: 400),
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

  Widget _pickerPanel() {
    final isSort = _picker == _Picker.sort;
    final options = <(String, bool, VoidCallback)>[
      if (isSort)
        for (final s in _sorts)
          (s.label, s.label == _sort.label, () => setState(() => _sort = s))
      else ...[
        ('All genres', _genre == null, () => setState(() => _genre = null)),
        for (final g in _genres ?? <String>[]) (g, g == _genre, () => setState(() => _genre = g)),
      ],
    ];

    return Positioned.fill(
      child: Stack(children: [
        Positioned.fill(
          child: GestureDetector(onTap: _closePicker, child: Container(color: Colors.black.withOpacity(0.45))),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: 460,
          child: Container(
            color: kBg.withOpacity(0.96),
            padding: const EdgeInsets.fromLTRB(28, 56, 28, 28),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(isSort ? 'Sort by' : 'Genre', style: tvDisplay(30)),
              const SizedBox(height: 24),
              Expanded(
                child: FocusScope(
                  child: ListView(children: [
                    for (var i = 0; i < options.length; i++)
                      Focusable(
                        focusNode: i == 0 ? _pickerFirst : null,
                        scrollAlignment: 0.3,
                        onSelect: () {
                          options[i].$3();
                          _closePicker();
                          _reload();
                        },
                        builder: (f) => AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          decoration: BoxDecoration(
                            color: f ? kFg : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(children: [
                            Expanded(
                              child: Text(options[i].$1,
                                  style: tvBody(21,
                                      weight: options[i].$2 ? FontWeight.w700 : FontWeight.w500,
                                      color: f ? kBg : kFg)),
                            ),
                            if (options[i].$2) Icon(Icons.check_rounded, color: f ? kBg : kFg, size: 26),
                          ]),
                        ),
                      ),
                  ]),
                ),
              ),
            ]),
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

  @override
  void dispose() {
    _epScroll.dispose();
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

  Future<void> _load({bool keepSeason = false}) async {
    final results = await Future.wait([
      jf.item(_id).catchError((_) => widget.series),
      jf.seasons(_id).catchError((_) => <dynamic>[]),
      jf.nextUp(_id),
    ]);
    if (!mounted) return;
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
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _pickSeason(int i) {
    if (i == _season) return;
    setState(() {
      _season = i;
      _episodes = [];
    });
    _loadEpisodes();
  }

  Future<void> _play(dynamic episode) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(jf: jf, item: episode)));
    _load(keepSeason: true);
  }

  Future<void> _markSeason() async {
    if (_seasons.isEmpty) return;
    await jf.markPlayed(_seasons[_season]['Id']);
    _load(keepSeason: true);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.escape || event.logicalKey == LogicalKeyboardKey.backspace)) {
      Navigator.of(context).maybePop();
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
                child: Image.network(
                  jf.backdropFor(series, maxWidth: tvPx(2560).clamp(1280, 3840)),
                  cacheWidth: tvPx(2560).clamp(1280, 3840),
                  fit: BoxFit.cover,
                  // Keep the top of the artwork (faces, titles); trim the hidden bottom instead.
                  alignment: Alignment.topCenter,
                  errorBuilder: (_, __, ___) => const ColoredBox(color: kPlaceholder),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      kBg.withOpacity(0.8),
                      kBg.withOpacity(0.62),
                      kBg.withOpacity(0.35),
                      kBg.withOpacity(0.12),
                      kBg.withOpacity(0),
                    ],
                    stops: const [0, 0.22, 0.42, 0.6, 0.75],
                  ),
                ),
              ),
            ),
            // Light fade at the top and bottom edges, always on.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [kBg.withOpacity(0.35), kBg.withOpacity(0), kBg.withOpacity(0), kBg.withOpacity(0.75)],
                    stops: const [0, 0.18, 0.72, 1],
                  ),
                ),
              ),
            ),
            // Strong fade under the episodes, only when they're up.
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _hero ? 0 : 1,
                  duration: _move,
                  curve: Curves.easeOutCubic,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [kBg.withOpacity(0), kBg.withOpacity(0), kBg.withOpacity(0.9), kBg],
                        stops: const [0, 0.34, 0.56, 0.72],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 120,
              top: 52,
              child: Focusable(
                onSelect: () => Navigator.of(context).maybePop(),
                onFocus: (_) => setState(() => _hero = true),
                builder: (f) => AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: f ? kFg : kFg.withOpacity(0.12)),
                  child: Icon(Icons.arrow_back_rounded, size: 28, color: f ? kBg : kFg),
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
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onFocusChange: (f) {
                  if (f) setState(() => _hero = true);
                },
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  height: 120,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: logo == null
                        ? title
                        : Image.network(logo,
                            height: 120,
                            cacheHeight: tvPx(120),
                            fit: BoxFit.contain,
                            alignment: Alignment.bottomLeft,
                            errorBuilder: (_, __, ___) => title),
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
                FocusTraversalGroup(
                  child: Row(children: [
                    Focusable(
                      autofocus: true,
                      onSelect: () {
                        final target = _next ?? (_episodes.isNotEmpty ? _episodes.first : null);
                        if (target != null) _play(target);
                      },
                      builder: (f) => AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        height: 64,
                        padding: const EdgeInsets.only(left: 26, right: 34),
                        decoration: BoxDecoration(
                          color: f ? kFg : kFg.withOpacity(0.14),
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
                      onSelect: _markSeason,
                      builder: (f) => AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        height: 64,
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: f ? kFg : kFg.withOpacity(0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text('Mark season watched',
                            style: tvBody(24, weight: FontWeight.w600, color: f ? kBg : kFg)),
                      ),
                    ),
                  ]),
                ),
              ]),
              ),
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
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onFocusChange: (f) {
                  if (f) setState(() => _hero = false);
                },
                child: Stack(children: [
                  Positioned(left: 120, right: 120, top: 0, child: _seasonTabs()),
                  Positioned(left: 0, right: 0, top: _seasons.length > 1 ? 76 : 0, bottom: 0, child: _episodeRow()),
                ]),
              ),
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
              scrollAlignment: 0,
              onSelect: () => _pickSeason(i),
              onFocus: (viaMouse) {
                if (!viaMouse) _pickSeason(i);
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
                        Image.network(
                          jf.image(ep['Id'], 'Primary', maxWidth: 720),
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
