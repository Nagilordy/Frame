// The movie page: full artwork, title logo, what it's about, and Play / Watch together.
// Same look as the show page. Opened from a library, from Recently added on Home, and from
// anywhere else a movie is picked to see more than just play it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gamepad.dart' show PadHint, PadButton, PadHints;
import 'images.dart';
import 'main.dart' show Jellyfin;
import 'phone.dart';
import 'downloads.dart' show DownloadButton;
import 'syncplay.dart' show SyncPlay, playOrParty, startWatchTogether, watchTogetherButton;
import 'ui.dart';

class MovieScreen extends StatefulWidget {
  const MovieScreen({super.key, required this.jf, required this.movie});
  final Jellyfin jf;
  final dynamic movie;

  @override
  State<MovieScreen> createState() => _MovieScreenState();
}

class _MovieScreenState extends State<MovieScreen> {
  Jellyfin get jf => widget.jf;
  dynamic _details; // the full details (cast, genres, rating), once they arrive
  dynamic get _movie => _details ?? widget.movie;

  final _backNode = namedNode('Movie: Back');
  final _playNode = namedNode('Movie: Play');
  String? _markNote;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _backNode.dispose();
    _playNode.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await jf.item(widget.movie['Id'].toString(), fresh: true);
      if (mounted) setState(() => _details = d);
    } catch (_) {
      // Keep what the card already had.
    }
  }

  Future<void> _play({bool fromStart = false}) async {
    await playOrParty(context, jf, _movie, startTicks: fromStart ? 0 : null);
    // Phones: the player turned the phone sideways; this page can turn again.
    if (mounted && isPhone(context)) phoneAnyOrientation();
    _load(); // where you stopped, watched or not
  }

  Future<void> _toggleWatched() async {
    final watched = isWatched(_movie);
    setState(() => _markNote = watched ? 'Marking as not watched…' : 'Marking as watched…');
    try {
      final id = _movie['Id'].toString();
      if (watched) {
        await jf.markUnplayed(id);
      } else {
        await jf.markPlayed(id);
      }
      await _load();
      if (mounted) setState(() => _markNote = null);
    } catch (e) {
      if (mounted) setState(() => _markNote = errorText(e));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.escape || event.logicalKey == LogicalKeyboardKey.backspace)) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static String _runtime(dynamic item) {
    final m = runtimeMinutes(item);
    if (m <= 0) return '';
    return m >= 60 ? '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min' : '$m min';
  }

  Widget _pill(String label, bool f, {IconData? icon, bool strong = false}) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 64,
        padding: EdgeInsets.only(left: icon != null ? 24 : 28, right: 30),
        decoration: BoxDecoration(
          color: f ? kFg : kPillFill,
          borderRadius: BorderRadius.circular(999),
          boxShadow: f && strong ? [BoxShadow(color: kFg.withOpacity(0.22), spreadRadius: 5)] : [],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: strong ? 34 : 28, color: f ? kBg : kFg), const SizedBox(width: 10)],
          Text(label, style: tvBody(strong ? 26 : 24, weight: strong ? FontWeight.w700 : FontWeight.w600, color: f ? kBg : kFg)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (isPhone(context)) return _phoneBuild(context);
    final movie = _movie;
    final logo = jf.logoFor(movie);
    final title = Text(movie['Name']?.toString() ?? '', style: tvDisplay(64), maxLines: 2);
    final rating = movie['CommunityRating'] is num ? '★ ${(movie['CommunityRating'] as num).toStringAsFixed(1)}' : '';
    final meta = [
      movie['ProductionYear']?.toString() ?? '',
      _runtime(movie),
      movie['OfficialRating']?.toString() ?? '',
      rating,
      qualityLine(movie),
    ].where((s) => s.isNotEmpty).join('   ·   ');
    final genres = ((movie['Genres'] as List?) ?? const []).take(4).join(', ');
    final tagline = ((movie['Taglines'] as List?) ?? const []).isNotEmpty ? movie['Taglines'][0].toString() : '';
    final overview = (movie['Overview'] ?? '').toString();
    final people = (movie['People'] as List?) ?? const [];
    final cast = people.where((p) => p['Type'] == 'Actor').take(4).map((p) => p['Name']).join(', ');
    final director = people.where((p) => p['Type'] == 'Director').take(2).map((p) => p['Name']).join(', ');
    final progress = progressOf(movie);
    final inParty = SyncPlay.of(jf).inParty;

    return PadHints(
      hints: const [PadHint(PadButton.select, 'Select'), PadHint(PadButton.back, 'Back')],
      child: Focus(
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: kBg,
          body: TvCanvas(
            child: Stack(children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: netImage(
                    jf.backdropFor(movie, maxWidth: sizeBucket(tvPx(1920)).clamp(1280, 2560)),
                    cacheWidth: sizeBucket(tvPx(1920)).clamp(1280, 2560),
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => const ColoredBox(color: kPlaceholder),
                  ),
                ),
              ),
              const Positioned.fill(child: ShadeOverlay(shades: [kShadeLeft, kShadeTopBottom])),
              Positioned(
                left: 120,
                top: 52,
                child: FocusLinks(
                  down: () => focusOn(_playNode),
                  child: Focusable(
                    focusNode: _backNode,
                    onSelect: () => Navigator.of(context).maybePop(),
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
              Positioned(
                left: 120,
                bottom: 110,
                width: 1060,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    height: 140,
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: logo == null
                          ? title
                          : LogoImage(url: logo, height: 140, cacheHeight: tvPx(140), fallback: title),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(meta, style: tvBody(26, color: kSoft)),
                  if (genres.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(genres, style: tvBody(22, color: kMuted)),
                  ],
                  if (tagline.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(tagline, style: tvBody(24, weight: FontWeight.w600)),
                  ],
                  if (overview.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: 900,
                      child: Text(overview,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: tvBody(23, weight: FontWeight.w400, color: const Color(0xFFC3C9D3), height: 1.45)),
                    ),
                  ],
                  if (cast.isNotEmpty || director.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    if (cast.isNotEmpty) Text('Starring  $cast', style: tvBody(20, color: kMuted)),
                    if (director.isNotEmpty) Text('Directed by  $director', style: tvBody(20, color: kMuted)),
                  ],
                  const SizedBox(height: 28),
                  FocusLinks(
                    up: () => focusOn(_backNode),
                    down: () => true,
                    child: FocusTraversalGroup(
                      child: Row(children: [
                        Focusable(
                          autofocus: true,
                          focusNode: _playNode,
                          onSelect: _play,
                          builder: (f) => _pill(
                              inParty
                                  ? 'Play for the party'
                                  : (progress > 0 ? 'Resume · ${minutesLeft(movie)} min left' : 'Play'),
                              f,
                              icon: Icons.play_arrow_rounded,
                              strong: true),
                        ),
                        if (progress > 0) ...[
                          const SizedBox(width: 16),
                          Focusable(
                            onSelect: () => _play(fromStart: true),
                            builder: (f) => _pill('From the beginning', f, icon: Icons.replay_rounded),
                          ),
                        ],
                        if (!inParty) ...[
                          const SizedBox(width: 16),
                          Focusable(
                            onSelect: () => startWatchTogether(context, jf, movie),
                            builder: watchTogetherButton,
                          ),
                        ],
                        const SizedBox(width: 16),
                        Focusable(
                          onSelect: _toggleWatched,
                          builder: (f) => _pill(_markNote ?? (isWatched(movie) ? 'Watched' : 'Mark watched'), f,
                              icon: isWatched(movie) ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded),
                        ),
                      ]),
                    ),
                  ),
                  if (progress > 0) ...[
                    const SizedBox(height: 18),
                    Container(
                      width: 420,
                      height: 5,
                      decoration: BoxDecoration(color: kFg.withOpacity(0.22), borderRadius: BorderRadius.circular(5)),
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: progress,
                        child: Container(decoration: BoxDecoration(color: kFg, borderRadius: BorderRadius.circular(5))),
                      ),
                    ),
                  ],
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------- Phone layout ----------
  //
  // Upright: the artwork at the top, then the logo, details, Play (Resume) across the width,
  // Watch together and Mark watched under it, the summary (tap for all of it) and the cast.
  // Sideways: the TV page re-sized for a phone, artwork across the screen and everything on
  // the left, scrolling if it doesn't fit.

  bool _phoneRotationSet = false;
  bool _fullSummary = false;

  Widget _phoneBuild(BuildContext context) {
    if (!_phoneRotationSet) {
      _phoneRotationSet = true;
      phoneAnyOrientation();
    }
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final upright = size.height > size.width;
    final m = phoneMargins(context, min: upright ? 20 : 44);
    final movie = _movie;
    final logo = jf.logoFor(movie);
    final name = movie['Name']?.toString() ?? '';
    final title = Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: phoneTitle(upright ? 30 : 28));
    final rating = movie['CommunityRating'] is num ? '★ ${(movie['CommunityRating'] as num).toStringAsFixed(1)}' : '';
    final meta = [
      movie['ProductionYear']?.toString() ?? '',
      _runtime(movie),
      movie['OfficialRating']?.toString() ?? '',
      rating,
    ].where((s) => s.isNotEmpty).join(' · ');
    final quality = qualityLine(movie);
    final genres = ((movie['Genres'] as List?) ?? const []).take(3).join(', ');
    final overview = (movie['Overview'] ?? '').toString();
    final people = (movie['People'] as List?) ?? const [];
    final cast = people.where((p) => p['Type'] == 'Actor').take(12).toList();
    final director = people.where((p) => p['Type'] == 'Director').take(2).map((p) => p['Name']).join(', ');
    final progress = progressOf(movie);
    final inParty = SyncPlay.of(jf).inParty;
    final watched = isWatched(movie);
    final backW = upright ? 400 * 16 / 9 : size.width;
    final decode = phoneDecode(context, backW).clamp(640, 2560).toInt();

    final playLabel = inParty ? 'Play for the party' : (progress > 0 ? 'Resume · ${minutesLeft(movie)} min left' : 'Play');
    final play = PhoneButton(
        primary: true, label: playLabel, icon: Icons.play_arrow_rounded, height: upright ? 52 : 44, onTap: _play);
    final together = PhoneButton(
      label: 'Watch together',
      icon: Icons.people_alt_outlined,
      height: upright ? 48 : 44,
      onTap: () async {
        await startWatchTogether(context, jf, movie);
        if (mounted) phoneAnyOrientation();
      },
    );
    final mark = PhoneButton(
      label: upright ? (_markNote ?? (watched ? 'Watched' : 'Mark watched')) : null,
      semanticLabel: watched ? 'Watched: tap to mark not watched' : 'Mark watched',
      icon: watched ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded,
      height: upright ? 48 : 44,
      onTap: _toggleWatched,
    );
    final fromStart = PhoneButton(
      label: 'From the beginning',
      icon: Icons.replay_rounded,
      height: upright ? 44 : 40,
      onTap: () => _play(fromStart: true),
    );

    final castRow = cast.isEmpty
        ? const SizedBox.shrink()
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: EdgeInsets.only(left: m.left, right: m.right, bottom: 10),
              child: Text('Cast', style: phoneText(17, weight: FontWeight.w700)),
            ),
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.only(left: m.left, right: m.right),
                itemCount: cast.length,
                separatorBuilder: (_, __) => const SizedBox(width: 14),
                itemBuilder: (_, i) {
                  final p = cast[i];
                  final face = phoneDecode(context, 64);
                  return SizedBox(
                    width: 72,
                    child: Column(children: [
                      ClipOval(
                        child: SizedBox(
                          width: 64,
                          height: 64,
                          child: p['PrimaryImageTag'] == null
                              ? Container(
                                  color: kPlaceholder,
                                  alignment: Alignment.center,
                                  child: Text('${p['Name'] ?? '?'} '.substring(0, 1),
                                      style: phoneText(22, weight: FontWeight.w700, color: kMuted)),
                                )
                              : netImage(jf.image(p['Id'].toString(), 'Primary', maxWidth: face),
                                  cacheWidth: face,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const ColoredBox(color: kPlaceholder)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text((p['Name'] ?? '').toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: phoneText(12)),
                    ]),
                  );
                },
              ),
            ),
          ]);

    final summary = overview.isEmpty
        ? const SizedBox.shrink()
        : GestureDetector(
            onTap: () => setState(() => _fullSummary = !_fullSummary),
            child: Text(overview,
                maxLines: _fullSummary ? null : (upright ? 4 : 3),
                overflow: _fullSummary ? TextOverflow.visible : TextOverflow.ellipsis,
                style: phoneText(14, weight: FontWeight.w400, color: const Color(0xFFC3C9D3), height: 1.5)),
          );

    final heading = SizedBox(
      height: upright ? 72 : 60,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: logo == null
            ? title
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: LogoImage(
                    url: logo,
                    height: upright ? 72 : 60,
                    cacheHeight: phoneDecode(context, upright ? 72 : 60),
                    fallback: title),
              ),
      ),
    );

    final info = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      heading,
      const SizedBox(height: 10),
      if (meta.isNotEmpty) Text(meta, style: phoneText(13, color: kSoft)),
      if (quality.isNotEmpty || genres.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text([quality, genres].where((s) => s.isNotEmpty).join(' · '), style: phoneText(13, color: kMuted)),
      ],
    ]);

    final back = Positioned(
      left: upright ? m.left - 4 : m.left,
      top: pad.top + (upright ? 8 : 12),
      child: Semantics(
        button: true,
        label: 'Back',
        child: GestureDetector(
          onTap: () {
            phoneTap();
            Navigator.of(context).maybePop();
          },
          child: Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(color: Color(0x8C06080B), shape: BoxShape.circle),
            child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: kFg),
          ),
        ),
      ),
    );

    final backdrop = netImage(
      jf.backdropFor(movie, maxWidth: decode),
      cacheWidth: decode,
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
      alignment: upright ? Alignment.center : Alignment.topCenter,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const ColoredBox(color: kPlaceholder),
    );

    if (upright) {
      return Scaffold(
        backgroundColor: kBg,
        body: ListView(
          padding: EdgeInsets.only(bottom: pad.bottom + 28),
          physics: const BouncingScrollPhysics(),
          children: [
            SizedBox(
              height: 400,
              child: Stack(fit: StackFit.expand, children: [
                backdrop,
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x8006080B), Color(0x0006080B), Color(0x0006080B), kBg],
                      stops: [0, 0.25, 0.55, 1],
                    ),
                  ),
                ),
                Positioned(left: m.left, right: m.right, bottom: 0, child: info),
                back,
              ]),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(m.left, 18, m.right, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                play,
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: together),
                  const SizedBox(width: 10),
                  Expanded(child: mark),
                ]),
                const SizedBox(height: 10),
                DownloadButton(jf: jf, item: movie, height: 48),
                if (progress > 0) ...[
                  const SizedBox(height: 10),
                  fromStart,
                  const SizedBox(height: 12),
                  PhoneProgress(value: progress),
                ],
                const SizedBox(height: 18),
                summary,
                if (director.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('Directed by $director', style: phoneText(13, color: kMuted)),
                ],
                const SizedBox(height: 22),
              ]),
            ),
            castRow,
          ],
        ),
      );
    }

    // Sideways.
    final columnW = (size.width * 0.58).clamp(320.0, 520.0).toDouble();
    return Scaffold(
      backgroundColor: kBg,
      body: Stack(children: [
        Positioned.fill(child: backdrop),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xE606080B), Color(0xA606080B), Color(0x0006080B)],
                stops: [0, 0.5, 0.78],
              ),
            ),
          ),
        ),
        ListView(
          padding: EdgeInsets.only(top: pad.top + 64, bottom: pad.bottom + 20),
          physics: const BouncingScrollPhysics(),
          children: [
            Padding(
              padding: EdgeInsets.only(left: m.left),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: columnW,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    info,
                    const SizedBox(height: 8),
                    summary,
                    const SizedBox(height: 14),
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      play,
                      together,
                      mark,
                      DownloadButton(jf: jf, item: movie, height: 44),
                      if (progress > 0) fromStart,
                    ]),
                    if (_markNote != null) ...[
                      const SizedBox(height: 8),
                      Text(_markNote!, style: phoneText(13, color: kSoft)),
                    ],
                    if (progress > 0) ...[
                      const SizedBox(height: 12),
                      SizedBox(width: 260, child: PhoneProgress(value: progress)),
                    ],
                    if (director.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text('Directed by $director', style: phoneText(13, color: kMuted)),
                    ],
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 20),
            castRow,
          ],
        ),
        back,
      ]),
    );
  }
}
