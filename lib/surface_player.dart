// Frame's own player, drawing straight to the screen (preview, Windows).
//
// The goal: everything the separate mpv window does (real HDR, Dolby Vision, 4K, smooth
// motion), but inside Frame's window, with Frame's own controls, so the mpv program can go.
//
// How: the video engine (libmpv, the same one inside every Frame player) draws with its own
// renderer (gpu-next, Direct3D 11, HDR) into a surface kept just under Frame's window
// (packages/frame_video). Frame's window turns see-through while the video plays, and this
// screen draws only the controls, on top. One app, one window.
//
// Preview: off by default; F9 turns it on or off (saved). Original file only, no Watch
// together yet: those fall back to the usual player. The info line at the bottom shows what
// the engine is doing (renderer, decoder, HDR or not) so tests can tell it works.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:frame_video/frame_video.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'main.dart' show Jellyfin;
import 'player.dart' show PlayerScreen;
import 'ui.dart';

/// The preview switch (F9), remembered between launches.
final ValueNotifier<bool> newPlayerPreview = ValueNotifier(false);

Future<void> loadNewPlayerPreview() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    newPlayerPreview.value = prefs.getBool('newPlayerPreview') ?? false;
  } catch (_) {}
}

Future<void> toggleNewPlayerPreview() async {
  newPlayerPreview.value = !newPlayerPreview.value;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('newPlayerPreview', newPlayerPreview.value);
  } catch (_) {}
}

/// Whether this video can use the preview player.
bool canUseSurfacePlayer({required bool inParty}) => FrameVideo.supported && newPlayerPreview.value && !inParty;

class SurfacePlayerScreen extends StatefulWidget {
  const SurfacePlayerScreen({super.key, required this.jf, required this.item, this.startTicks});
  final Jellyfin jf;
  final dynamic item;
  final int? startTicks;

  @override
  State<SurfacePlayerScreen> createState() => _SurfacePlayerScreenState();
}

class _SurfacePlayerScreenState extends State<SurfacePlayerScreen> {
  final Player _player = Player(
    configuration: const PlayerConfiguration(
      bufferSize: 256 * 1024 * 1024,
      logLevel: MPVLogLevel.warn,
      // mpv's best renderer, drawing into our surface (its "wid", set before the video opens).
      vo: 'gpu-next',
      // Subtitles drawn by mpv onto the picture (every kind, styled ones kept).
      libass: true,
    ),
  );
  final _focus = FocusNode();
  final List<StreamSubscription> _subs = [];
  Timer? _hideTimer, _reportTimer;

  bool _controls = true;
  bool _playing = false;
  bool _buffering = true;
  bool _started = false;
  bool _closing = false;
  Duration _pos = Duration.zero, _dur = Duration.zero;
  double? _drag; // 0..1 while dragging the timeline
  String _engine = ''; // renderer · decoder · picture, for testing
  String? _error;

  String get _id => widget.item['Id'].toString();
  int get _resumeTicks => widget.startTicks ?? (widget.item['UserData']?['PlaybackPositionTicks'] ?? 0) as int;
  int get _ticks => _pos.inMicroseconds * 10;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final surface = await FrameVideo.open();
    if (!mounted) return;
    if (surface == null) {
      // No surface (older Windows, or it failed): the usual player instead.
      debugPrint('Surface player: no video surface, using the usual player');
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => PlayerScreen(jf: widget.jf, item: widget.item, startTicks: widget.startTicks),
      ));
      return;
    }
    final mpv = _player.platform;
    if (mpv is! NativePlayer) return;
    Future<void> set(String k, String v) async {
      try {
        await mpv.setProperty(k, v);
      } catch (e) {
        debugPrint('Surface player: $k=$v not accepted ($e)');
      }
    }

    // Draw into the surface with mpv's best renderer, exactly like the mpv window.
    await set('wid', '$surface');
    await set('gpu-api', 'd3d11');
    await set('gpu-context', 'd3d11');
    await set('hwdec', 'auto-safe');
    // HDR: tell Windows the video's real colours and brightness, so an HDR screen shows HDR.
    await set('target-colorspace-hint', 'yes');
    await set('tone-mapping', 'bt.2446a');
    await set('hdr-compute-peak', 'no');
    // Smooth motion: frames timed to the screen, with light blending between them.
    await set('video-sync', 'display-resample');
    await set('interpolation', 'yes');
    await set('tscale', 'oversample');
    // Network: read ahead, reconnect on drops.
    await set('cache', 'yes');
    await set('demuxer-max-bytes', '256MiB');
    await set('demuxer-max-back-bytes', '128MiB');
    await set('demuxer-readahead-secs', '60');
    await set('cache-pause-initial', 'yes');
    await set('cache-pause-wait', '1');
    await set('stream-lavf-o', 'reconnect=1,reconnect_on_network_error=1,reconnect_delay_max=4');
    await set('hr-seek', 'absolute');
    await set('deinterlace', 'auto');
    // Subtitles drawn by mpv onto the picture (every kind, styled ones kept).
    await set('sub-visibility', 'yes');
    await set('sub-ass-override', 'scale');
    await set('osd-level', '0');
    await set('background-color', '#000000');

    _subs.addAll([
      _player.stream.position.listen((p) {
        if (_drag == null && mounted) setState(() => _pos = p);
      }),
      _player.stream.duration.listen((d) {
        if (mounted) setState(() => _dur = d);
      }),
      _player.stream.playing.listen((p) {
        if (!mounted) return;
        setState(() => _playing = p);
        if (p) _scheduleHide();
        _report();
      }),
      _player.stream.buffering.listen((b) {
        if (mounted) setState(() => _buffering = b);
      }),
      _player.stream.completed.listen((done) {
        if (done) _close();
      }),
      _player.stream.error.listen((e) {
        debugPrint('Surface player: $e');
        if (!_started && mounted) setState(() => _error = e);
      }),
      _player.stream.videoParams.listen((_) => _readEngine()),
    ]);

    final resume = _resumeTicks > 0 ? Duration(microseconds: _resumeTicks ~/ 10) : null;
    await _player.open(Media(widget.jf.directStreamUrl(_id), start: resume));
    _started = true;
    unawaited(widget.jf.reportStart(_id, resume == null ? 0 : resume.inMicroseconds * 10).catchError((_) {}));
    _reportTimer = Timer.periodic(const Duration(seconds: 10), (_) => _report());
    Timer(const Duration(seconds: 2), _readEngine);
  }

  Future<void> _readEngine() async {
    final mpv = _player.platform;
    if (mpv is! NativePlayer || !mounted) return;
    Future<String> p(String k) async {
      try {
        return await mpv.getProperty(k);
      } catch (_) {
        return '';
      }
    }

    final vo = await p('current-vo');
    final hw = await p('hwdec-current');
    final w = await p('video-params/w');
    final h = await p('video-params/h');
    final gamma = await p('video-params/gamma');
    final hdr = gamma == 'pq' || gamma == 'hlg';
    final picture = [
      if (w.isNotEmpty && h.isNotEmpty) '${w}x$h',
      if (gamma.isNotEmpty) hdr ? 'HDR (${gamma.toUpperCase()})' : 'SDR',
    ].join(' ');
    if (!mounted) return;
    setState(() => _engine = [
          'renderer ${vo.isEmpty ? '?' : vo}',
          'decoder ${hw.isEmpty || hw == 'no' ? 'software' : hw}',
          if (picture.isNotEmpty) picture,
        ].join(' · '));
  }

  void _report() {
    if (!_started) return;
    unawaited(widget.jf.reportProgress(_id, _ticks, !_playing).catchError((_) {}));
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    final ticks = _ticks;
    unawaited(widget.jf.reportStopped(_id, ticks).catchError((_) {}));
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _reportTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    if (!_closing && _started) {
      unawaited(widget.jf.reportStopped(_id, _ticks).catchError((_) {}));
    }
    // Stop the engine before the surface goes, then make Frame's window solid again.
    _player.dispose().whenComplete(FrameVideo.close);
    _focus.dispose();
    super.dispose();
  }

  // ---------- Controls ----------

  void _show() {
    if (!_controls) setState(() => _controls = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing && _drag == null) setState(() => _controls = false);
    });
  }

  void _seekBy(int seconds) {
    var to = _pos + Duration(seconds: seconds);
    if (to < Duration.zero) to = Duration.zero;
    if (_dur > Duration.zero && to > _dur) to = _dur;
    _player.seek(to);
    setState(() => _pos = to);
    _show();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.backspace || k == LogicalKeyboardKey.goBack) {
      _close();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.mediaPlayPause) {
      _player.playOrPause();
      _show();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(30);
      return KeyEventResult.handled;
    }
    _show();
    return KeyEventResult.ignored;
  }

  static String _clock(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final episode = item['Type'] == 'Episode';
    final title = (episode ? item['SeriesName'] : item['Name'])?.toString() ?? '';
    final sub = episode
        ? 'S${item['ParentIndexNumber'] ?? '?'} · E${item['IndexNumber'] ?? '?'} · ${item['Name'] ?? ''}'
        : (item['ProductionYear']?.toString() ?? '');
    final total = _dur.inMilliseconds;
    final f = _drag ?? (total > 0 ? (_pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0);

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        // See-through: the video is drawn behind Frame's window.
        backgroundColor: Colors.transparent,
        body: MouseRegion(
          cursor: _controls ? SystemMouseCursors.basic : SystemMouseCursors.none,
          onHover: (_) => _show(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _controls ? setState(() => _controls = false) : _show(),
            onDoubleTap: toggleFullScreen,
            child: TvCanvas(
              child: Stack(children: [
                if (_error != null)
                  Center(
                    child: Container(
                      width: 900,
                      padding: const EdgeInsets.all(40),
                      decoration: BoxDecoration(color: const Color(0xF212151B), borderRadius: BorderRadius.circular(28)),
                      child: Text("This video couldn't play here.\n$_error",
                          textAlign: TextAlign.center, style: tvBody(26, color: kSoft)),
                    ),
                  ),
                if (_buffering && _error == null)
                  const Center(
                    child: SizedBox(width: 64, height: 64, child: CircularProgressIndicator(strokeWidth: 3, color: kFg)),
                  ),
                IgnorePointer(
                  ignoring: !_controls,
                  child: AnimatedOpacity(
                    opacity: _controls ? 1 : 0,
                    duration: const Duration(milliseconds: 250),
                    child: Stack(children: [
                      // Top: title.
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: 260,
                        child: DecoratedBox(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xB306080B), Color(0x0006080B)],
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(120, 64, 120, 0),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(title, style: tvDisplay(44)),
                              if (sub.isNotEmpty) Text(sub, style: tvBody(26, color: kSoft)),
                            ]),
                          ),
                        ),
                      ),
                      // Bottom: timeline, buttons, engine info.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 340,
                        child: DecoratedBox(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [Color(0xD906080B), Color(0x0006080B)],
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(120, 0, 120, 56),
                            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                              LayoutBuilder(builder: (context, box) {
                                final w = box.maxWidth;
                                double at(double dx) => (dx / w).clamp(0.0, 1.0);
                                return GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapUp: (d) => _player.seek(Duration(milliseconds: (at(d.localPosition.dx) * total).round())),
                                  onHorizontalDragStart: (d) => setState(() => _drag = at(d.localPosition.dx)),
                                  onHorizontalDragUpdate: (d) => setState(() => _drag = at(d.localPosition.dx)),
                                  onHorizontalDragEnd: (_) {
                                    final to = _drag;
                                    setState(() => _drag = null);
                                    if (to != null) _player.seek(Duration(milliseconds: (to * total).round()));
                                    _scheduleHide();
                                  },
                                  child: SizedBox(
                                    height: 40,
                                    child: Stack(alignment: Alignment.centerLeft, children: [
                                      Container(height: 8, decoration: BoxDecoration(color: kFg.withOpacity(0.25), borderRadius: BorderRadius.circular(4))),
                                      Container(width: w * f, height: 8, decoration: BoxDecoration(color: kFg, borderRadius: BorderRadius.circular(4))),
                                      Positioned(
                                        left: (w * f - 12).clamp(0.0, w - 24).toDouble(),
                                        child: Container(width: 24, height: 24, decoration: const BoxDecoration(color: kFg, shape: BoxShape.circle)),
                                      ),
                                    ]),
                                  ),
                                );
                              }),
                              const SizedBox(height: 18),
                              Row(children: [
                                _button(Icons.replay_10_rounded, () => _seekBy(-10)),
                                const SizedBox(width: 16),
                                _button(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, () {
                                  _player.playOrPause();
                                  _show();
                                }, primary: true),
                                const SizedBox(width: 16),
                                _button(Icons.forward_30_rounded, () => _seekBy(30)),
                                const SizedBox(width: 28),
                                Text(
                                  '${_clock(_drag == null ? _pos : Duration(milliseconds: (f * total).round()))} / ${_clock(_dur)}',
                                  style: tvBody(26, weight: FontWeight.w600),
                                ),
                                const Spacer(),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  decoration: BoxDecoration(color: kFg.withOpacity(0.12), borderRadius: BorderRadius.circular(18)),
                                  child: Text('Preview player${_engine.isEmpty ? '' : ' · $_engine'}',
                                      style: tvBody(19, weight: FontWeight.w600, color: kSoft)),
                                ),
                              ]),
                            ]),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _button(IconData icon, VoidCallback onTap, {bool primary = false}) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: primary ? 76 : 64,
          height: primary ? 76 : 64,
          decoration: BoxDecoration(shape: BoxShape.circle, color: primary ? kFg : kFg.withOpacity(0.14)),
          child: Icon(icon, size: primary ? 44 : 34, color: primary ? kBg : kFg),
        ),
      );
}

/// Used by playerScreen: the preview player for this video, when it applies.
Widget? surfacePlayerFor(Jellyfin jf, dynamic item, {required bool inParty, int? startTicks}) {
  if (!Platform.isWindows || !canUseSurfacePlayer(inParty: inParty)) return null;
  return SurfacePlayerScreen(jf: jf, item: item, startTicks: startTicks);
}
