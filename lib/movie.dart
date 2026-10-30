// The movie page: full artwork, title logo, what it's about, and Play / Watch together.
// Same look as the show page. Opened from a library, from Recently added on Home, and from
// anywhere else a movie is picked to see more than just play it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gamepad.dart' show PadHint, PadButton, PadHints;
import 'images.dart';
import 'main.dart' show Jellyfin;
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
}
