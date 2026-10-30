// Player screen: full-screen video with controls that fade away while watching.
// Keyboard: Space play/pause · ←/→ skip (when controls are hidden) · arrows + Enter on buttons
// · Escape hides the controls, or leaves the player when they're already hidden.
// Mouse: moving shows the controls, click buttons, click or drag the progress bar.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gamepad.dart' show PadHint, PadHints, PadButton, padActive, fullScreenHint;
import 'ui.dart' show Frost, Focusable, FocusLinks, focusOn, isDesktop, toggleFullScreen, fullScreen, tvBody, tvDisplay, kAccent;
import 'main.dart' show Jellyfin;
import 'banners.dart' show showBanner, bannerIcon;
import 'syncplay.dart' show SyncPlay, RoomLink, RoomVideo;
import 'perf.dart' show perfLog;
import 'tracks.dart';

// ---------- Look (same palette as the home screen) ----------

const _bg = Color(0xFF06080B);
const _fg = Color(0xFFF4F5F7);
const _muted = Color(0xFFB9C0CB);
const _soft = Color(0xFFD3D8E0);

TextStyle _body(double size, {FontWeight weight = FontWeight.w500, Color color = _fg}) =>
    tvBody(size, weight: weight, color: color);

TextStyle _display(double size) => tvDisplay(size);

const _back = Duration(seconds: 10);
const _forward = Duration(seconds: 30);

String _clock(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

String _qualityLine(dynamic item) {
  final streams = (item['MediaStreams'] as List?) ?? [];
  final video = streams.cast<dynamic>().firstWhere((s) => s['Type'] == 'Video', orElse: () => null);
  final audio = streams.cast<dynamic>().firstWhere((s) => s['Type'] == 'Audio', orElse: () => null);
  final parts = <String>[];
  if (video != null) {
    final w = (video['Width'] ?? 0) as int;
    parts.add(w >= 3200 ? '4K' : w >= 1800 ? '1080p' : w >= 1200 ? '720p' : 'SD');
    final range = (video['VideoRangeType'] ?? '').toString();
    if (range.startsWith('DOVI')) {
      parts.add('Dolby Vision');
    } else if (range == 'HDR10Plus') {
      parts.add('HDR10+');
    } else if (range == 'HDR10' || range == 'HLG') {
      parts.add(range);
    }
  }
  if (audio != null) {
    final ch = audio['Channels'] ?? 0;
    parts.add(ch >= 8 ? '7.1' : ch >= 6 ? '5.1' : 'Stereo');
  }
  return parts.join(' · ');
}

// ---------- The screen ----------

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.jf, required this.item, this.sync, this.playlistItemId, this.startTicks});
  final Jellyfin jf;
  final dynamic item;
  final SyncPlay? sync; // a Watch together room, or null
  final String? playlistItemId;
  final int? startTicks; // where the room starts (instead of your resume point)

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

enum _Panel { none, playback, audio, subtitles }

class _PlayerScreenState extends State<PlayerScreen> {
  // A larger buffer keeps more of the file ready, which helps smoothness and seeking over the network.
  late final Player player = Player(
    configuration: const PlayerConfiguration(bufferSize: 256 * 1024 * 1024),
  );
  late final VideoController controller = VideoController(
    player,
    configuration: const VideoControllerConfiguration(enableHardwareAcceleration: true),
  );

  final _rootFocus = FocusNode();
  final _playFocus = FocusNode();
  final _panelFirst = FocusNode();
  // Fixed Up / Down jumps: Back button ↕ progress bar ↕ Play and the other buttons.
  final _backFocus = FocusNode();
  final _barFocus = FocusNode();

  bool _controls = true;
  bool _chrome = true; // controls are built (true while visible or fading out)
  bool _info = false;

  // Subtitle style, remembered between videos.
  double _subScale = 1.0;
  int _subPos = 100; // 100 = bottom of the picture, lower numbers = higher up
  bool _subBox = false;
  _Panel _panel = _Panel.none;
  String _stats = '';

  Timer? _hideTimer;
  Timer? _statsTimer;
  Timer? _syncTimer;
  final _subs = <StreamSubscription>[];

  String get _id => widget.item['Id'];

  // ---------- Original file or the server's version, and adapting to this device ----------
  //
  // Two ways to play, like Jellyfin's own apps:
  //   Original file: played straight from the NAS, untouched. Best quality.
  //   Converted by the server: Jellyfin re-encodes it on the NAS into a plain 4K stream with
  //     normal colours, and this device just plays that. For devices that can't keep up.
  // The Playback button chooses: Automatic (the default), Original file, or Server.
  //
  // Automatic starts with the original file at full quality. Every 10 seconds it checks how
  // many frames had to be dropped. If this device can't keep up (5 or more in 10 s of normal
  // playback, not counting pauses or skips), it eases off one step:
  //   normal videos:   step 1 simpler scaling (same resolution) -> step 2 the server's version
  //   Dolby Vision P5: step 1 the server's version (it fixes the colours on the NAS)
  // The step is remembered per device, so the next video starts the way that works. After a
  // long video with no dropped frames, it tries one step higher next time.
  int _level = 0;
  int _levelAtStart = 0;
  bool _eased = false; // stepped down during this video
  int _lastDrops = -1;
  int _cleanSeconds = 0; // playback checked with no drops at the current step
  DateTime _lastSeek = DateTime(0);
  Timer? _adaptTimer;

  String _mode = 'auto'; // the Playback choice: auto, original, server
  bool _server = false; // playing the server's version right now
  bool _switching = false;
  String? _session; // Jellyfin's play session while it converts
  // With the server's version: the chosen audio and subtitle streams (Jellyfin's numbering),
  // and the text subtitles it sends as separate files, by stream number.
  int? _serverAudio;
  int? _serverSub; // an image subtitle drawn into the picture by the server, or null
  int? _serverTextSub; // a text subtitle shown on this device, or null
  final Map<int, String> _serverSubUrls = {};

  String get _levelKey => _isDolbyVisionOnly ? 'playbackStepDolbyVision' : 'playbackStep';
  int get _serverStep => _isDolbyVisionOnly ? 1 : 2;
  int get _maxLevel => _mode == 'original' ? _serverStep - 1 : _serverStep;

  Future<void> _loadLevel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _mode = prefs.getString('playbackMode') ?? 'auto';
      _level = (prefs.getInt(_levelKey) ?? 0).clamp(0, _maxLevel).toInt();
    } catch (_) {}
    _levelAtStart = _level;
    if (_level > 0) debugPrint('Player: this device plays smoothest at step $_level, starting there');
  }

  Future<void> _applyLevel() async {
    final mpv = player.platform;
    if (mpv is! NativePlayer || _level < 1 || _server) return;
    Future<void> set(String name, String value) async {
      try {
        await mpv.setProperty(name, value);
      } catch (_) {}
    }

    await set('scale', 'bilinear');
    await set('dscale', 'bilinear');
    await set('cscale', 'bilinear');
    await set('dither-depth', 'no');
    await set('correct-downscaling', 'no');
    await set('linear-downscaling', 'no');
    await set('sigmoid-upscaling', 'no');
    await set('deband', 'no');
  }

  // Once a minute while playing: how playback is going, for the performance log (perf.dart).
  int _statsTicks = 0;
  Future<void> _logPlayback() async {
    final mpv = player.platform;
    if (mpv is! NativePlayer) return;
    Future<String> p(String name) async {
      try {
        return await mpv.getProperty(name);
      } catch (_) {
        return '?';
      }
    }

    perfLog('player: ${widget.item['Name']} · ${await p('width')}x${await p('height')}'
        ' · ${_server ? 'server version' : 'original file'} · decoder ${await p('hwdec-current')}'
        ' · fps ${await p('estimated-vf-fps')}'
        ' · dropped ${await p('frame-drop-count')} (decoder ${await p('decoder-frame-drop-count')})'
        ' · buffered ${await p('demuxer-cache-duration')} s · step $_level');
  }

  Future<void> _checkSmoothness() async {
    final mpv = player.platform;
    if (!mounted || mpv is! NativePlayer || _switching) return;
    if (++_statsTicks % 6 == 0 && player.state.playing) unawaited(_logPlayback());
    int drops;
    try {
      drops = int.parse(await mpv.getProperty('frame-drop-count'));
    } catch (_) {
      return;
    }
    final previous = _lastDrops;
    _lastDrops = drops;
    if (previous < 0 || drops < previous) return;
    // Only judge stretches of normal playback.
    if (!player.state.playing ||
        player.state.buffering ||
        DateTime.now().difference(_lastSeek) < const Duration(seconds: 12)) {
      return;
    }
    final dropped = drops - previous;
    if (dropped == 0) {
      _cleanSeconds += 10;
      return;
    }
    _cleanSeconds = 0;
    if (dropped < 5 || _level >= _maxLevel || _server) return;
    _level++;
    _eased = true;
    debugPrint('Player: $dropped frames dropped in 10 s, easing off to step $_level for this device');
    try {
      await (await SharedPreferences.getInstance()).setInt(_levelKey, _level);
    } catch (_) {}
    if (_level >= _serverStep) {
      await _switchSource(server: true);
    } else {
      await _applyLevel();
    }
    _lastDrops = -1; // count fresh after the change
    _lastSeek = DateTime.now();
  }

  // A long, clean video at a lowered step: next time, try one step higher.
  void _saveLearnedLevel() {
    if (_eased || _levelAtStart == 0 || _level != _levelAtStart || _cleanSeconds < 600) return;
    final key = _levelKey;
    final next = _level - 1;
    SharedPreferences.getInstance().then((p) => p.setInt(key, next)).then((_) {}, onError: (_) {});
  }

  // Opens the server's version (server: true) or the original file, at the same moment.
  // Returns false if the server couldn't provide its version (playback continues unchanged).
  Future<bool> _openSource({required bool server, Duration? at}) async {
    final mpv = player.platform;
    String url;
    String? session;
    List<({String url, String label, String? language, int index})> subtitles = const [];
    if (server) {
      try {
        final stream = await widget.jf.serverStream(_id, audioIndex: _serverAudio, subtitleIndex: _serverSub);
        url = stream.url;
        session = stream.session;
        subtitles = stream.subtitles;
      } catch (e) {
        debugPrint('Player: the server could not provide its version: $e');
        return false;
      }
    } else {
      url = widget.jf.directStreamUrl(_id);
    }
    if (mpv is NativePlayer) {
      // Exact seeks (not the nearest keyframe, which can be seconds away): Watch together
      // only accepts a position within half a second of the room's.
      if (widget.sync != null) await mpv.setProperty('hr-seek', 'yes');
      if (server) {
        // The server already fixed the colours: no conversion on this device.
        await mpv.setProperty('vf', '');
        await mpv.setProperty('hwdec', 'auto-safe');
      } else if (_isDolbyVisionOnly) {
        await _applyDvFilter();
      }
      if (at != null) await mpv.setProperty('start', (at.inMilliseconds / 1000).toStringAsFixed(1));
    }
    _server = server;
    _session = session;
    _serverSubUrls
      ..clear()
      ..addEntries(subtitles.map((s) => MapEntry(s.index, s.url)));
    final wasPlaying = player.state.playing;
    if (!server) _tracksApplied = false;
    await player.open(Media(url), play: widget.sync == null || wasPlaying);
    // A text subtitle that was on before the switch: turn it back on.
    final text = _serverTextSub;
    if (server && text != null && _serverSubUrls[text] != null) await _showServerTextSub(text);
    debugPrint('Player: playing ${server ? "the server's version" : 'the original file'}');
    return true;
  }

  // A text subtitle of the server's version, shown by this device (switches instantly).
  Future<void> _showServerTextSub(int index) async {
    final mpv = player.platform;
    final url = _serverSubUrls[index];
    if (mpv is! NativePlayer || url == null) return;
    try {
      await mpv.command(['sub-add', url, 'select']);
      await mpv.setProperty('sub-visibility', 'yes');
    } catch (e) {
      debugPrint('Player: subtitle could not be added: $e');
    }
  }

  // With the server's version: choose audio. The server restarts its stream with that
  // track, at the same moment.
  Future<void> _chooseServerAudio(int index) async {
    _tracks.rememberStream('audio', index);
    if (index == _serverAudio) return;
    _serverAudio = index;
    await _switchSource(server: true, force: true);
  }

  // With the server's version: choose subtitles (null = off). Text ones switch on this device
  // instantly; image ones (Blu-ray) are drawn into the picture by the server, which restarts
  // its stream at the same moment.
  Future<void> _chooseServerSubtitle(dynamic stream) async {
    if (stream == null) {
      _tracks.rememberSubsOff();
      _serverTextSub = null;
      await player.setSubtitleTrack(SubtitleTrack.no());
      if (_serverSub != null) {
        _serverSub = null;
        await _switchSource(server: true, force: true);
      }
      return;
    }
    final index = (stream['Index'] ?? -1) as int;
    _tracks.rememberStream('sub', index);
    if (stream['IsTextSubtitleStream'] == true && _serverSubUrls[index] != null) {
      _serverTextSub = index;
      if (_serverSub != null) {
        _serverSub = null;
        await _switchSource(server: true, force: true); // turns the text one back on after
      } else {
        await _showServerTextSub(index);
      }
    } else {
      _serverTextSub = null;
      await player.setSubtitleTrack(SubtitleTrack.no());
      _serverSub = index;
      await _switchSource(server: true, force: true);
    }
  }

  // Switches between the original file and the server's version mid-video (force: reopen the
  // server's version, e.g. with another audio track).
  Future<void> _switchSource({required bool server, bool force = false}) async {
    if (_switching || (server == _server && !force)) return;
    _switching = true;
    final at = player.state.position;
    final oldSession = _session;
    try {
      if (await _openSource(server: server, at: at)) {
        // Tell Jellyfin: the old way stopped here, the new one starts here.
        widget.jf.reportStopped(_id, at.inMicroseconds * 10, session: oldSession);
        widget.jf.reportStart(_id, at.inMicroseconds * 10, session: _session);
      }
    } finally {
      _switching = false;
      _lastSeek = DateTime.now();
      _lastDrops = -1;
      if (mounted) setState(() {});
      // In a room: the new stream has to catch up with everyone again.
      if (_room != null) unawaited(_roomReady());
    }
  }

  // The Playback choice from the panel.
  Future<void> _setMode(String mode) async {
    _mode = mode;
    try {
      await (await SharedPreferences.getInstance()).setString('playbackMode', mode);
    } catch (_) {}
    if (mode == 'server') {
      await _switchSource(server: true);
    } else if (mode == 'original') {
      _level = _level.clamp(0, _maxLevel).toInt();
      await _switchSource(server: false);
    }
    if (mounted) setState(() {});
  }

  // The Dolby Vision conversion itself: exactly the settings that gave correct colours.
  static const _dvConvert = 'libplacebo=apply_dolbyvision=1'
      ':tonemapping=bt.2446a:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=yuv420p';

  // Decoded on the GPU, copied to the conversion step.
  Future<void> _applyDvFilter() async {
    final mpv = player.platform;
    if (mpv is! NativePlayer) return;
    await mpv.setProperty('hwdec', 'auto-copy-safe');
    await mpv.setProperty('vf', 'lavfi=[$_dvConvert]');
  }

  // Dolby Vision with no HDR10 or SDR picture inside (Profile 5). Jellyfin calls it "DOVI";
  // the kinds with a fallback picture are "DOVIWithHDR10", "DOVIWithSDR" and so on.
  bool get _isDolbyVisionOnly {
    final streams = (widget.item['MediaStreams'] as List?) ?? [];
    final video = streams.cast<dynamic>().firstWhere((s) => s['Type'] == 'Video', orElse: () => null);
    return video != null && video['VideoRangeType'] == 'DOVI';
  }
  int get _resumeTicks => widget.startTicks ?? (widget.item['UserData']?['PlaybackPositionTicks'] ?? 0) as int;

  // ---------- Remembering audio and subtitle choices (tracks.dart) ----------

  late final TrackPrefs _tracks = TrackPrefs(widget.item);
  bool _tracksApplied = false;

  // Jellyfin's description of one of mpv's tracks: mpv numbers each kind 1, 2, 3… in file
  // order, the same order Jellyfin lists the file's own streams.
  dynamic _streamFor(String id, String type) {
    final n = int.tryParse(id);
    if (n == null || n < 1) return null;
    final list = _streams(type).where((s) => s['IsExternal'] != true).toList();
    return n <= list.length ? list[n - 1] : null;
  }

  Map<String, dynamic> _describeAudio(AudioTrack t) {
    final s = _streamFor(t.id, 'Audio');
    return s != null ? TrackPrefs.describeStream(s) : TrackPrefs.describe(lang: t.language, title: t.title);
  }

  Map<String, dynamic> _describeSub(SubtitleTrack t) {
    final s = _streamFor(t.id, 'Subtitle');
    return s != null ? TrackPrefs.describeStream(s) : TrackPrefs.describe(lang: t.language, title: t.title);
  }

  // Server's version: choose the tracks before asking the server for its stream.
  void _presetServerTracks() {
    final audio = _tracks.audio, sub = _tracks.sub;
    if (audio != null) _serverAudio = _tracks.bestStreamIndex('Audio', audio) ?? _serverAudio;
    if (sub != null && sub['off'] != true) {
      final index = _tracks.bestStreamIndex('Subtitle', sub);
      final stream = _streams('Subtitle').cast<dynamic>().firstWhere((s) => s['Index'] == index, orElse: () => null);
      if (stream != null) {
        if (stream['IsTextSubtitleStream'] == true) {
          _serverTextSub = index;
        } else {
          _serverSub = index;
        }
      }
    }
  }

  // Original file: once its tracks are known, switch to the remembered kind.
  Future<void> _applyTrackPrefs() async {
    if (_server || _tracksApplied) return;
    final audio = _tracks.audio, sub = _tracks.sub;
    if (audio == null && sub == null) return;
    final tracks = player.state.tracks;
    if (tracks.audio.where((t) => int.tryParse(t.id) != null).isEmpty) return; // not known yet
    _tracksApplied = true;
    if (audio != null) {
      final pick = TrackPrefs.best<AudioTrack>(audio, [
        for (final t in tracks.audio)
          if (int.tryParse(t.id) != null) (t, _describeAudio(t)),
      ]);
      if (pick != null) await player.setAudioTrack(pick);
    }
    if (sub != null) {
      if (sub['off'] == true) {
        await player.setSubtitleTrack(SubtitleTrack.no());
        return;
      }
      final inside = TrackPrefs.best<SubtitleTrack>(sub, [
        for (final t in tracks.subtitle)
          if (int.tryParse(t.id) != null) (t, _describeSub(t)),
      ]);
      if (inside != null) {
        await _setSubtitle(inside);
        return;
      }
      // Not inside the file: maybe one stored next to it.
      final external = TrackPrefs.best<dynamic>(sub, [
        for (final s in _streams('Subtitle'))
          if (s['IsExternal'] == true) (s, TrackPrefs.describeStream(s)),
      ]);
      if (external != null) await _setSubtitle(_externalTrack(external));
    }
  }

  SubtitleTrack _externalTrack(dynamic s) => SubtitleTrack.uri(
        widget.jf.externalSubtitleUrl(_id, s['Index'], (s['Codec'] ?? 'srt').toString()),
        title: s['DisplayTitle'],
        language: s['Language'],
      );

  // ---------- Up next (same rules as the mpv player) ----------
  //
  // Near the end of an episode a card offers the next one (from where the credits start when
  // the server knows, otherwise 30 s before the end): Cross / Enter plays it now, Circle /
  // Escape hides the card. At the end, the next episode starts by itself.

  dynamic _next;
  double? _creditsAt;
  bool _nextDismissed = false;
  bool _continuing = false;

  Future<void> _findNext() async {
    if (widget.item['Type'] != 'Episode') return;
    try {
      final results = await Future.wait([
        widget.jf.episodeAfter(widget.item),
        widget.jf.creditsStart(_id),
      ]).timeout(const Duration(seconds: 4));
      if (!mounted) return;
      setState(() {
        _next = results[0];
        _creditsAt = results[1] as double?;
      });
    } catch (e) {
      debugPrint('Player: next episode unknown ($e)');
    }
  }

  // Seconds left and the card's full span, while the card shows; null otherwise.
  (double, double)? _upNextAt(Duration position) {
    if (_next == null || _nextDismissed || _continuing) return null;
    final dur = player.state.duration.inMilliseconds / 1000;
    if (dur < 60) return null;
    final at = _creditsAt ?? dur - 30;
    final pos = position.inMilliseconds / 1000;
    if (pos < at) return null;
    return ((dur - pos).clamp(0, dur).toDouble(), (dur - at).clamp(1, dur).toDouble());
  }

  bool get _upNextShowing => _upNextAt(player.state.position) != null;

  void _onEnded() {
    if (_continuing) return;
    if (_next != null && !_nextDismissed) {
      final sync = widget.sync;
      if (sync == null || sync.isHost) {
        _playNext();
      }
      return; // others in a room wait for the room's next video
    }
    Navigator.of(context).maybePop();
  }

  Future<void> _playNext() async {
    final next = _next;
    if (next == null || _continuing || !mounted) return;
    final sync = widget.sync;
    if (sync != null) {
      // The room's new video reaches everyone, this player included.
      try {
        await sync.play(next['Id'].toString(), 0);
      } catch (e) {
        debugPrint('Player: next episode for the room failed: $e');
      }
      return;
    }
    _continuing = true;
    final series = widget.item['SeriesId'];
    if (series != null) widget.jf.forgetShow(series.toString());
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => PlayerScreen(jf: widget.jf, item: next)));
  }

  Widget _upNextCard() {
    return Positioned(
      right: 56,
      bottom: 230,
      child: StreamBuilder<Duration>(
        stream: player.stream.position,
        initialData: player.state.position,
        builder: (_, snap) {
          final at = _upNextAt(snap.data ?? Duration.zero);
          if (at == null || _panel != _Panel.none) return const SizedBox.shrink();
          final (left, span) = at;
          return GestureDetector(
            onTap: _playNext,
            child: Container(
              width: 600,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1E25),
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [BoxShadow(color: Color(0x8C000000), blurRadius: 60, offset: Offset(0, 20))],
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Container(height: 4, color: kAccent),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 18, 28, 20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('UP NEXT', style: _body(15, weight: FontWeight.w700, color: _muted)),
                    const SizedBox(height: 6),
                    Text(_episodeTitle(_next), maxLines: 1, overflow: TextOverflow.ellipsis, style: _body(24, weight: FontWeight.w700)),
                    const SizedBox(height: 14),
                    Row(children: [
                      Container(
                        height: 44,
                        padding: const EdgeInsets.only(left: 16, right: 22),
                        decoration: BoxDecoration(color: _fg, borderRadius: BorderRadius.circular(22)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.play_arrow_rounded, size: 26, color: _bg),
                          const SizedBox(width: 6),
                          Text('Play now', style: _body(20, weight: FontWeight.w700, color: _bg)),
                        ]),
                      ),
                      if (padActive.value && !_controls) ...[
                        const SizedBox(width: 22),
                        Text('Select: play now   ·   Back: hide', style: _body(17, color: _soft)),
                      ],
                    ]),
                  ]),
                ),
                // Runs down to the end of the episode, when the next one starts by itself.
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: (left / span).clamp(0.0, 1.0),
                    child: Container(height: 4, color: kAccent),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  static String _episodeTitle(dynamic ep) => [
        if (ep['ParentIndexNumber'] != null) 'S${ep['ParentIndexNumber']}',
        if (ep['IndexNumber'] != null) 'E${ep['IndexNumber']}',
        ep['Name'] ?? '',
      ].join(' · ');

  // ---------- Watch together ----------
  RoomLink? _room;

  void _startRoom() {
    final sync = widget.sync;
    if (sync == null) return;
    _room = RoomLink.create(
      sync: sync,
      playlistItemId: widget.playlistItemId ?? '',
      itemId: _id,
      myName: widget.jf.userName,
      position: () => player.state.position.inMicroseconds / 1e6,
      isPaused: () => !player.state.playing,
      seekTo: (sec) => player.seek(Duration(microseconds: (sec * 1e6).round())),
      setPaused: (paused) => paused ? player.pause() : player.play(),
      setSpeed: (speed) => player.setRate(speed),
      notice: (text) {
        if (mounted) {
          showBanner(context,
              picture: bannerIcon(Icons.groups_rounded),
              who: 'Watch together',
              text: text,
              line: kAccent,
              duration: const Duration(milliseconds: 3500));
        }
      },
      onStop: () {
        if (mounted) Navigator.of(context).maybePop();
      },
      onNewVideo: _switchRoomVideo,
      settled: () async => !player.state.buffering && player.state.duration > Duration.zero,
      exactPosition: () async => player.state.position.inMicroseconds / 1e6,
      duration: () => player.state.duration.inMicroseconds / 1e6,
    )..start();
    _subs.add(player.stream.buffering.listen((b) {
      if (!_switching && player.state.duration > Duration.zero) _room?.stalled(b);
    }));
  }

  Future<void> _switchRoomVideo(RoomVideo now) async {
    try {
      final item = await widget.jf.item(now.itemId, fresh: true);
      if (!mounted) return;
      _room?.handingOver = true;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => PlayerScreen(
              jf: widget.jf, item: item, sync: widget.sync, playlistItemId: now.playlistItemId, startTicks: now.startTicks)));
    } catch (e) {
      debugPrint("Together: could not open the room's new video: $e");
    }
  }

  // The video is open: once it has settled, tell the room this player is ready.
  Future<void> _roomReady() async {
    final room = _room;
    if (room == null) return;
    for (var i = 0; i < 100 && mounted; i++) {
      if (!player.state.buffering && player.state.duration > Duration.zero) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (mounted) await room.ready();
  }
  int get _ticksNow => player.state.position.inMicroseconds * 10;

  @override
  void initState() {
    super.initState();
    // Controls hide on their own only while playing; pausing keeps them up.
    _subs.add(player.stream.playing.listen((playing) {
      if (!mounted) return;
      if (playing) {
        _scheduleHide();
      } else {
        _hideTimer?.cancel();
        if (!_controls) {
          setState(() {
            _controls = true;
            _chrome = true;
          });
        }
      }
    }));
    // The file's tracks are known: pick the remembered audio and subtitles.
    _subs.add(player.stream.tracks.listen((_) => _applyTrackPrefs()));
    // Close the player when the video ends.
    // The video ended: the next episode, or back.
    _subs.add(player.stream.completed.listen((done) {
      if (done && mounted) _onEnded();
    }));
    // mpv also reports small, harmless problems here, so an error only counts if the video
    // still hasn't started a few seconds later.
    _subs.add(player.stream.error.listen((message) {
      Timer(const Duration(seconds: 4), () {
        if (player.state.duration == Duration.zero) _fail(message);
      });
    }));
    // Still nothing after 25 seconds: say so instead of spinning forever.
    _openTimer = Timer(const Duration(seconds: 25), () {
      if (player.state.duration == Duration.zero) {
        _fail("The server isn't sending the video. Check that the NAS is on.");
      }
    });
    _start();
  }

  String? _failure;
  Timer? _openTimer;

  void _fail(String message) {
    if (!mounted || _failure != null || _switching) return;
    _openTimer?.cancel();
    debugPrint('Playback failed: $message');
    setState(() => _failure = message);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _failFocus.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_registered) {
      _registered = true;
      widget.sync?.playerOpened(widget.playlistItemId); // watching the party's video
    }
  }

  bool _registered = false;

  final _failFocus = FocusNode();

  // Shown instead of the endless spinner when a video can't play.
  Widget _failureBox() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text("This video couldn't play", style: _display(34), textAlign: TextAlign.center),
              const SizedBox(height: 14),
              Text(_failure!,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: _body(20, color: _muted)),
              const SizedBox(height: 30),
              _iconButton(Icons.arrow_back_rounded, () => Navigator.of(context).maybePop(),
                  focusNode: _failFocus, label: 'Back', size: 64, iconSize: 32),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _start() async {
    final mpv = player.platform;
    if (mpv is NativePlayer) {
      // Decode on the GPU when the hardware supports the codec, otherwise fall back safely.
      await mpv.setProperty('hwdec', 'auto-safe');
      // Dolby Vision Profile 5 (Disney+ and similar) has no normal HDR picture inside, only
      // Dolby's own colour format, so shown as-is it comes out pink and green. mpv only
      // converts it with its newer drawing engine, which the embedded player can't use yet.
      // So for these files the conversion runs as a separate step (libplacebo, the same code
      // that engine uses) before the picture reaches the screen: Dolby Vision colours applied,
      // then converted for the screen. Other files are untouched. If the system's video
      // library lacks that step, mpv just skips it and plays as before.
      if (_isDolbyVisionOnly) {
        debugPrint('Player: Dolby Vision Profile 5 (colours fixed by libplacebo here, or by the server)');
      }
      // HDR to SDR conversion, without per-frame brightness measuring (heavy on small GPUs).
      await mpv.setProperty('tone-mapping', 'bt.2446a');
      await mpv.setProperty('hdr-compute-peak', 'no');
      // Wait for a little data before the first frame, so the start doesn't stutter.
      await mpv.setProperty('cache-pause-initial', 'yes');
      await mpv.setProperty('cache-pause-wait', '1');
      // Read ahead over the network so seeks inside the buffer are instant.
      await mpv.setProperty('cache', 'yes');
      await mpv.setProperty('demuxer-max-bytes', '256MiB');
      await mpv.setProperty('demuxer-max-back-bytes', '128MiB');
      await mpv.setProperty('demuxer-readahead-secs', '60');
      // Jump to the nearest keyframe: much faster seeks.
      await mpv.setProperty('hr-seek', 'no');
      // mpv draws subtitles straight onto the video. This handles every kind, including
      // image subtitles from Blu-rays (PGS) and styled anime subtitles (ASS), with their own styling.
      await mpv.setProperty('sub-visibility', 'yes');
      // Keep styled subtitles' own look, but let the size setting apply to them too.
      await mpv.setProperty('sub-ass-override', 'scale');
      await _loadSubStyle();
      await _applySubStyle();
      await _loadLevel();
      await _applyLevel();
    }
    await _tracks.load();
    // Original file or the server's version (see "Original file or the server's version").
    // Disc images and disc folders (ISO, Blu-ray, DVD) can't be streamed as one file.
    final item = widget.item;
    final disc = (item['VideoType'] ?? 'VideoFile') != 'VideoFile' ||
        ['iso', 'bluray', 'dvd'].contains((item['Container'] ?? '').toString().toLowerCase());
    final wantServer = disc || _mode == 'server' || (_mode == 'auto' && _level >= _serverStep);
    if (wantServer) _presetServerTracks();
    // Resume where I stopped last time (Jellyfin counts time in ticks of 100 nanoseconds).
    final resume = _resumeTicks > 0 ? Duration(microseconds: _resumeTicks ~/ 10) : null;
    try {
      _switching = true;
      final ok = await _openSource(server: wantServer, at: resume);
      if (!ok) await _openSource(server: false, at: resume); // server unavailable: original
    } catch (e) {
      _fail('$e');
      return;
    } finally {
      _switching = false;
    }
    // Left the player while it was still opening: don't start reporting.
    if (!mounted) return;
    if (widget.sync != null) {
      _startRoom();
      unawaited(_roomReady());
    }
    widget.jf.reportStart(_id, _resumeTicks, session: _session);
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_switching) return;
      widget.jf.reportProgress(_id, _ticksNow, !player.state.playing, session: _session);
    });
    _lastSeek = DateTime.now(); // the start itself can drop a frame or two
    _adaptTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkSmoothness());
    unawaited(_findNext());
    if (mounted) _playFocus.requestFocus();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _hideTimer?.cancel();
    _statsTimer?.cancel();
    _syncTimer?.cancel();
    _openTimer?.cancel();
    _adaptTimer?.cancel();
    _saveLearnedLevel();
    _room?.dispose();
    widget.sync?.playerClosed(); // still in the party, just not watching
    _failFocus.dispose();
    if (_failure == null || _session != null) widget.jf.reportStopped(_id, _ticksNow, session: _session);
    player.dispose();
    _rootFocus.dispose();
    _playFocus.dispose();
    _backFocus.dispose();
    _barFocus.dispose();
    _panelFirst.dispose();
    super.dispose();
  }

  // ---------- Showing and hiding the controls ----------

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && player.state.playing && _panel == _Panel.none) {
        setState(() => _controls = false);
        _rootFocus.requestFocus();
      }
    });
  }

  void _showControls({bool focusPlay = false}) {
    if (!_controls) {
      setState(() {
        _controls = true;
        _chrome = true;
      });
      // The buttons are rebuilt this frame; select Play once they exist.
      if (focusPlay) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _playFocus.requestFocus();
        });
      }
    }
    _scheduleHide();
  }

  void _hideControls() {
    _hideTimer?.cancel();
    setState(() {
      _controls = false;
      _panel = _Panel.none;
    });
    _rootFocus.requestFocus();
  }

  // ---------- Actions ----------

  void _togglePlay() {
    final room = _room;
    if (room != null) {
      room.togglePause();
    } else {
      player.playOrPause();
    }
    _showControls();
  }

  // Where the last skip went: holding the button adds up even while the player is still
  // getting there (its position lags behind for a moment after each jump).
  Duration? _skipTarget;
  DateTime _skipAt = DateTime(0);

  void _skip(Duration by) {
    final duration = player.state.duration;
    final recent = DateTime.now().difference(_skipAt) < const Duration(milliseconds: 1500);
    var target = (recent ? _skipTarget ?? player.state.position : player.state.position) + by;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    _lastSeek = DateTime.now();
    _skipTarget = target;
    _skipAt = DateTime.now();
    final room = _room;
    if (room != null) {
      room.seek(target.inMicroseconds / 1e6);
    } else {
      player.seek(target);
    }
    _showControls();
  }

  // Jumps between the Back button, progress bar and buttons, keeping the controls up.
  bool _go(FocusNode node) {
    _scheduleHide();
    return focusOn(node);
  }

  void _openPanel(_Panel panel) {
    _hideTimer?.cancel();
    setState(() => _panel = panel);
    // Select the first choice once the panel is on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _panelFirst.context != null) _panelFirst.requestFocus();
    });
  }

  void _closePanel() {
    setState(() => _panel = _Panel.none);
    _playFocus.requestFocus();
    _scheduleHide();
  }

  void _toggleInfo() {
    setState(() => _info = !_info);
    _statsTimer?.cancel();
    if (_info) {
      _readStats();
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _readStats());
    }
    _showControls();
  }

  // Live numbers: decoder, dropped frames, buffered time.
  Future<void> _readStats() async {
    final mpv = player.platform;
    if (mpv is! NativePlayer || !mounted) return;
    Future<String> p(String name) async {
      try {
        return await mpv.getProperty(name);
      } catch (_) {
        return '?';
      }
    }

    final hw = await p('hwdec-current');
    final dropped = await p('frame-drop-count');
    final decoderDropped = await p('decoder-frame-drop-count');
    final cache = await p('demuxer-cache-duration');
    final cacheSecs = double.tryParse(cache)?.toStringAsFixed(0) ?? cache;
    if (!mounted) return;
    setState(() => _stats = 'Decoder  ${hw.isEmpty || hw == 'no' ? 'CPU' : 'GPU ($hw)'}\n'
        'Dropped frames  $dropped / $decoderDropped\n'
        'Buffered  ${cacheSecs}s\n'
        'Source  ${_server ? 'converted by your server (NAS)' : 'original file, direct play'}'
        '${_isDolbyVisionOnly && !_server ? '\nDolby Vision P5: colours converted by libplacebo' : ''}'
        '${!_server && _level > 0 ? '\nPicture  eased for this device (step $_level)' : ''}'
        '\nPlayback choice  ${_mode == 'auto' ? 'Automatic' : _mode == 'server' ? 'Server' : 'Original file'}');
  }

  // ---------- Keyboard ----------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // The video couldn't play: Back leaves, everything else goes to the Back button.
    if (_failure != null) {
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) {
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Space (or Options on the controller) always plays or pauses.
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    // Triangle / Y: playback info, like in the mpv player.
    if (key == LogicalKeyboardKey.contextMenu && _panel == _Panel.none) {
      _toggleInfo();
      return KeyEventResult.handled;
    }
    // L1 / R1 on the controller always skip, controls up or not.
    if (_panel == _Panel.none && key == LogicalKeyboardKey.mediaRewind) {
      _skip(-_back);
      return KeyEventResult.handled;
    }
    if (_panel == _Panel.none && key == LogicalKeyboardKey.mediaFastForward) {
      _skip(_forward);
      return KeyEventResult.handled;
    }

    if (_panel != _Panel.none) {
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) {
        _closePanel();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // arrows + Enter move inside the panel
    }

    // Up next showing over the picture: Select plays it, Back hides the card.
    if (!_controls && _upNextShowing) {
      if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.select) {
        _playNext();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) {
        setState(() => _nextDismissed = true);
        return KeyEventResult.handled;
      }
    }

    if (!_controls) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _skip(-_back);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _skip(_forward);
        return KeyEventResult.handled;
      }
      // Back with the controls hidden brings them back (a second Back leaves): one stray press
      // no longer ends the video.
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) {
        _showControls(focusPlay: true);
        return KeyEventResult.handled;
      }
      // Any other key brings the controls back, with Play/Pause selected.
      _showControls(focusPlay: true);
      return KeyEventResult.handled;
    }

    // Controls are visible: keys move between buttons, and keep the controls up. Back leaves.
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    _scheduleHide();
    return KeyEventResult.ignored;
  }

  // ---------- Building ----------

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isEpisode = item['Type'] == 'Episode';
    final title = (isEpisode ? item['SeriesName'] : item['Name'])?.toString() ?? '';
    final episodeLine = isEpisode
        ? [
            if (item['ParentIndexNumber'] != null) 'S${item['ParentIndexNumber']}',
            if (item['IndexNumber'] != null) 'E${item['IndexNumber']}',
            item['Name'] ?? '',
          ].join(' · ')
        : (item['ProductionYear']?.toString() ?? '');

    // Controller legend: hidden while just watching, so the picture stays clean.
    final hints = _failure != null
        ? const [PadHint(PadButton.back, 'Back')]
        : _panel != _Panel.none
        ? const [PadHint(PadButton.select, 'Select'), PadHint(PadButton.back, 'Close')]
        : _controls
            ? [
                const PadHint(PadButton.select, 'Select'),
                const PadHint(PadButton.playPause, 'Play/Pause'),
                const PadHint(PadButton.skip, 'Skip'),
                const PadHint(PadButton.back, 'Exit'),
                if (isDesktop) fullScreenHint(),
              ]
            : const <PadHint>[];

    return PadHints(
      hints: hints,
      child: Focus(
      focusNode: _rootFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: MouseRegion(
          cursor: _controls ? SystemMouseCursors.basic : SystemMouseCursors.none,
          // Mouse movement shows the controls, but not while the controller is in use
          // (so a resting pointer or the touchpad can't keep popping them up).
          onHover: (_) {
            if (!padActive.value) _showControls();
          },
          child: Stack(children: [
            // The video itself, with no built-in controls.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _controls ? _hideControls() : _showControls(focusPlay: true),
                // Double-click for full screen on PC only, so taps on the phone stay instant.
                onDoubleTap: isDesktop ? toggleFullScreen : null,
                child: Video(
                  controller: controller,
                  controls: NoVideoControls,
                  fill: Colors.black,
                  // Subtitles are drawn by mpv onto the video itself, so the plain text version is off.
                  subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
                ),
              ),
            ),

            // Loading spinner while the video starts or buffers.
            Positioned.fill(
              child: IgnorePointer(
                child: StreamBuilder<bool>(
                  stream: player.stream.buffering,
                  initialData: true,
                  builder: (_, snap) => snap.data == true
                      ? const Center(
                          child: SizedBox(
                            width: 56,
                            height: 56,
                            child: CircularProgressIndicator(strokeWidth: 3, color: _fg),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),

            // Everything else fades in and out together.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_controls,
                child: AnimatedOpacity(
                  opacity: _controls ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  // Once faded out, the controls are taken off screen entirely, so nothing
                  // (the clock, the progress bar) keeps updating while you watch.
                  onEnd: () {
                    if (!_controls && _chrome && mounted) setState(() => _chrome = false);
                  },
                  child: _chrome
                      ? Stack(children: [
                          _topBar(title, episodeLine),
                          _bottomBar(),
                        ])
                      : const SizedBox.shrink(),
                ),
              ),
            ),

            if (_next != null) _upNextCard(),
            if (_info) _infoBox(),
            if (_panel != _Panel.none) _trackPanel(),
            if (_failure != null) _failureBox(),
          ]),
        ),
      ),
      ),
    );
  }

  Widget _iconButton(IconData icon, VoidCallback onSelect,
      {double size = 46, double iconSize = 24, FocusNode? focusNode, String? label}) {
    return _FocusableWithNode(
      focusNode: focusNode,
      onSelect: onSelect,
      builder: (f) => Tooltip(
        message: label ?? '',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: f ? _fg : _fg.withOpacity(0.12),
          ),
          child: Icon(icon, size: iconSize, color: f ? _bg : _fg),
        ),
      ),
    );
  }

  Widget _topBar(String title, String episodeLine) {
    final quality = _qualityLine(widget.item);
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(48, 36, 56, 80),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withOpacity(0.75), Colors.black.withOpacity(0)],
          ),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          FocusLinks(
            down: () => _go(_barFocus),
            child: _iconButton(Icons.arrow_back_rounded, () => Navigator.of(context).maybePop(),
                label: 'Back', focusNode: _backFocus),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: _display(30), maxLines: 1, overflow: TextOverflow.ellipsis),
              if (episodeLine.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(episodeLine, style: _body(20, color: _soft), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ]),
          ),
          if (quality.isNotEmpty)
            Text(quality, style: _body(18, weight: FontWeight.w600, color: _soft)),
        ]),
      ),
    );
  }

  Widget _bottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: ValueListenableBuilder<bool>(
        valueListenable: padActive,
        // With a controller, the buttons sit a little higher to leave room for the legend.
        builder: (context, pad, child) => DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black.withOpacity(0.85), Colors.black.withOpacity(0)],
            ),
          ),
          child: AnimatedPadding(
            duration: const Duration(milliseconds: 200),
            padding: EdgeInsets.fromLTRB(56, 100, 56, pad ? 100 : 40),
            child: child,
          ),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Time and progress update on their own, without redrawing the rest of the screen.
          StreamBuilder<Duration>(
            stream: player.stream.position,
            initialData: player.state.position,
            builder: (_, snap) {
              final pos = snap.data ?? Duration.zero;
              final dur = player.state.duration;
              final left = dur > pos ? dur - pos : Duration.zero;
              final endsAt = DateTime.now().add(left);
              final endsText =
                  '${endsAt.hour.toString().padLeft(2, '0')}:${endsAt.minute.toString().padLeft(2, '0')}';
              return Column(children: [
                FocusLinks(
                  up: () => _go(_backFocus),
                  down: () => _go(_playFocus),
                  child: _ProgressBar(
                  focusNode: _barFocus,
                  position: pos,
                  duration: dur,
                  buffered: player.state.buffer,
                  onSeek: (to) {
                    _lastSeek = DateTime.now();
                    final room = _room;
                    if (room != null) {
                      room.seek(to.inMicroseconds / 1e6);
                    } else {
                      player.seek(to);
                    }
                    _showControls();
                  },
                  onKeySkip: (forward) => _skip(forward ? _forward : -_back),
                ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Text(_clock(pos), style: _body(18, color: _soft)),
                  const Spacer(),
                  if (dur > Duration.zero) Text('Ends at $endsText', style: _body(18, color: _muted)),
                  const Spacer(),
                  Text('-${_clock(left)}', style: _body(18, color: _soft)),
                ]),
              ]);
            },
          ),
          const SizedBox(height: 10),
          FocusLinks(
            up: () => _go(_barFocus),
            down: () => true, // nothing below the buttons
            child: SizedBox(
            height: 64,
            child: Stack(alignment: Alignment.center, children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _iconButton(Icons.replay_10_rounded, () => _skip(-_back), label: 'Back 10 seconds'),
                const SizedBox(width: 22),
                StreamBuilder<bool>(
                  stream: player.stream.playing,
                  initialData: player.state.playing,
                  builder: (_, snap) => _iconButton(
                    snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    _togglePlay,
                    size: 64,
                    iconSize: 36,
                    focusNode: _playFocus,
                    label: 'Play or pause',
                  ),
                ),
                const SizedBox(width: 22),
                _iconButton(Icons.forward_30_rounded, () => _skip(_forward), label: 'Forward 30 seconds'),
              ]),
              Align(
                alignment: Alignment.centerRight,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _iconButton(Icons.tune_rounded, () => _openPanel(_Panel.playback), label: 'Playback'),
                  const SizedBox(width: 12),
                  _iconButton(Icons.graphic_eq_rounded, () => _openPanel(_Panel.audio), label: 'Audio'),
                  const SizedBox(width: 12),
                  _iconButton(Icons.closed_caption_outlined, () => _openPanel(_Panel.subtitles), label: 'Subtitles'),
                  const SizedBox(width: 12),
                  _iconButton(Icons.info_outline_rounded, _toggleInfo, label: 'Playback info'),
                  if (isDesktop) ...[
                    const SizedBox(width: 12),
                    ValueListenableBuilder<bool>(
                      valueListenable: fullScreen,
                      builder: (_, full, __) => _iconButton(
                        full ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                        toggleFullScreen,
                        label: 'Full screen',
                      ),
                    ),
                  ],
                ]),
              ),
            ]),
          ),
          ),
        ]),
      ),
    );
  }

  Widget _infoBox() {
    return Positioned(
      top: 150,
      right: 56,
      child: IgnorePointer(
        child: Frost(
          radius: 14,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          child: Text(_stats.isEmpty ? 'Reading…' : _stats, style: _body(17, color: _soft).copyWith(height: 1.6)),
        ),
      ),
    );
  }

  // ---------- Audio and subtitle panel ----------

  // ---------- Subtitle style ----------

  Future<void> _loadSubStyle() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _subScale = prefs.getDouble('subScale') ?? 1.0;
      _subPos = prefs.getInt('subPos') ?? 100;
      _subBox = prefs.getBool('subBox') ?? false;
    } catch (_) {}
  }

  Future<void> _applySubStyle({bool save = false}) async {
    final mpv = player.platform;
    if (mpv is! NativePlayer) return;
    Future<void> set(String name, String value) async {
      try {
        await mpv.setProperty(name, value);
      } catch (_) {}
    }

    await set('sub-scale', _subScale.toStringAsFixed(2));
    await set('sub-pos', '$_subPos');
    // Background box: a translucent dark box behind the text (colors are #AARRGGBB).
    await set('sub-border-style', _subBox ? 'background-box' : 'outline-and-shadow');
    await set('sub-back-color', '#B3000000');
    if (save) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('subScale', _subScale);
        await prefs.setInt('subPos', _subPos);
        await prefs.setBool('subBox', _subBox);
      } catch (_) {}
    }
  }

  void _changeSubStyle({double? scale, int? pos, bool? box}) {
    setState(() {
      if (scale != null) _subScale = (scale.clamp(0.5, 2.0) * 10).roundToDouble() / 10;
      if (pos != null) _subPos = pos.clamp(40, 100).toInt();
      if (box != null) _subBox = box;
    });
    _applySubStyle(save: true);
  }

  // Size, position and background controls under the subtitle list. Changes show live.
  List<Widget> _styleSection() {
    Widget stepButton(IconData icon, VoidCallback onSelect, String label) => Focusable(
          onSelect: onSelect,
          builder: (f) => Tooltip(
            message: label,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 44,
              height: 44,
              decoration: BoxDecoration(shape: BoxShape.circle, color: f ? _fg : _fg.withOpacity(0.12)),
              child: Icon(icon, size: 24, color: f ? _bg : _fg),
            ),
          ),
        );

    Widget stepper(String name, String value, VoidCallback less, VoidCallback more, String lessLabel,
            String moreLabel, IconData lessIcon, IconData moreIcon) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(children: [
            Expanded(child: Text(name, style: _body(20))),
            stepButton(lessIcon, less, lessLabel),
            SizedBox(
              width: 76,
              child: Text(value, textAlign: TextAlign.center, style: _body(19, weight: FontWeight.w600, color: _soft)),
            ),
            stepButton(moreIcon, more, moreLabel),
          ]),
        );

    final heightAboveBottom = ((100 - _subPos) / 5).round();

    return [
      const SizedBox(height: 18),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Text('Style', style: _body(16, weight: FontWeight.w700, color: _muted)),
      ),
      stepper('Size', '${(_subScale * 100).round()}%', () => _changeSubStyle(scale: _subScale - 0.1),
          () => _changeSubStyle(scale: _subScale + 0.1), 'Smaller', 'Larger', Icons.remove_rounded, Icons.add_rounded),
      stepper('Position', heightAboveBottom == 0 ? 'Bottom' : '+$heightAboveBottom',
          () => _changeSubStyle(pos: _subPos + 5), () => _changeSubStyle(pos: _subPos - 5), 'Lower', 'Higher',
          Icons.keyboard_arrow_down_rounded, Icons.keyboard_arrow_up_rounded),
      Focusable(
        onSelect: () => _changeSubStyle(box: !_subBox),
        builder: (f) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(color: f ? _fg : Colors.transparent, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Expanded(child: Text('Background box', style: _body(20, color: f ? _bg : _fg))),
            Text(_subBox ? 'On' : 'Off', style: _body(19, weight: FontWeight.w600, color: f ? _bg : _soft)),
          ]),
        ),
      ),
      Focusable(
        onSelect: () => _changeSubStyle(scale: 1.0, pos: 100, box: false),
        builder: (f) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(color: f ? _fg : Colors.transparent, borderRadius: BorderRadius.circular(12)),
          child: Text('Reset style', style: _body(20, color: f ? _bg : _muted)),
        ),
      ),
    ];
  }

  // Switch subtitles, and make sure mpv keeps drawing them after the switch.
  Future<void> _setSubtitle(SubtitleTrack track) async {
    await player.setSubtitleTrack(track);
    final mpv = player.platform;
    if (mpv is NativePlayer && track.id != 'no') {
      await mpv.setProperty('sub-visibility', 'yes');
    }
  }

  // Readable track names: "Japanese · AAC · Stereo", "English · Dolby TrueHD + Dolby Atmos · 7.1".
  // mpv numbers each kind of track 1, 2, 3… in file order, the same order Jellyfin lists them,
  // so Jellyfin's description of the same track is used when it has one.
  String _trackLabel(String id, String? title, String? language, {required String type}) {
    if (id == 'auto') return 'Automatic';
    if (id == 'no') return 'Off';
    final n = int.tryParse(id);
    if (n != null && n > 0) {
      final streams = ((widget.item['MediaStreams'] as List?) ?? [])
          .where((s) => s['Type'] == type && s['IsExternal'] != true)
          .toList();
      if (n <= streams.length) {
        final display = (streams[n - 1]['DisplayTitle'] ?? '').toString();
        if (display.isNotEmpty) {
          return display.split(' - ').where((p) => p.trim() != 'Default').join(' · ');
        }
      }
    }
    final label = [_languageName(language), title].where((s) => s != null && s.isNotEmpty).join(' · ');
    return label.isEmpty ? 'Track $id' : label;
  }

  // The file's own streams of one kind (Audio, Subtitle), as Jellyfin lists them.
  List<dynamic> _streams(String type) =>
      ((widget.item['MediaStreams'] as List?) ?? []).where((s) => s['Type'] == type).toList();

  String _streamLabel(dynamic s) {
    final display = (s['DisplayTitle'] ?? '').toString();
    if (display.isNotEmpty) return display.split(' - ').where((p) => p.trim() != 'Default').join(' · ');
    return _languageName(s['Language']?.toString()) ?? 'Track ${s['Index']}';
  }

  static const _languages = {
    'eng': 'English', 'en': 'English', 'jpn': 'Japanese', 'ja': 'Japanese', 'fre': 'French',
    'fra': 'French', 'fr': 'French', 'spa': 'Spanish', 'es': 'Spanish', 'ger': 'German',
    'deu': 'German', 'de': 'German', 'ita': 'Italian', 'it': 'Italian', 'por': 'Portuguese',
    'pt': 'Portuguese', 'rus': 'Russian', 'ru': 'Russian', 'kor': 'Korean', 'ko': 'Korean',
    'chi': 'Chinese', 'zho': 'Chinese', 'zh': 'Chinese', 'ara': 'Arabic', 'ar': 'Arabic',
    'hin': 'Hindi', 'dut': 'Dutch', 'nld': 'Dutch', 'swe': 'Swedish', 'nor': 'Norwegian',
    'dan': 'Danish', 'fin': 'Finnish', 'pol': 'Polish', 'tur': 'Turkish', 'tha': 'Thai',
    'vie': 'Vietnamese', 'ind': 'Indonesian', 'heb': 'Hebrew', 'gre': 'Greek', 'ell': 'Greek',
    'cze': 'Czech', 'ces': 'Czech', 'hun': 'Hungarian', 'ukr': 'Ukrainian', 'und': 'Unknown language',
  };

  String? _languageName(String? code) => code == null ? null : (_languages[code.toLowerCase()] ?? code);

  Widget _trackPanel() {
    final rows = <Widget>[];
    var first = true;
    void add(String label, bool selected, VoidCallback onSelect) {
      void choose() {
        onSelect();
        _closePanel();
      }

      Widget look(bool f) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: f ? _fg : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _body(20, weight: selected ? FontWeight.w700 : FontWeight.w500, color: f ? _bg : _fg)),
            ),
            if (selected) Icon(Icons.check_rounded, color: f ? _bg : _fg, size: 26),
          ]),
        );

      rows.add(first
          ? _NodeFocusable(node: _panelFirst, onSelect: choose, builder: look)
          : Focusable(onSelect: choose, builder: look));
      first = false;
    }

    if (_panel == _Panel.playback) {
      // Original file or the server's version (see "Original file or the server's version").
      add('Automatic', _mode == 'auto', () => _setMode('auto'));
      add('Original file · best quality', _mode == 'original', () => _setMode('original'));
      add('Converted by the server · smoothest', _mode == 'server', () => _setMode('server'));
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        child: Text(
          _server
              ? 'Now playing the version your server converts on the NAS.'
              : 'Now playing the original file, straight from the NAS.',
          style: _body(17, color: _muted).copyWith(height: 1.4),
        ),
      ));
    } else if (_server && _panel == _Panel.audio) {
      // The server's version: the file's own audio tracks; the server switches to the one picked.
      final audio = _streams('Audio');
      final current = _serverAudio ?? (audio.firstWhere((a) => a['IsDefault'] == true, orElse: () => null)?['Index']);
      for (final a in audio) {
        final index = (a['Index'] ?? -1) as int;
        add(_streamLabel(a), index == current, () => _chooseServerAudio(index));
      }
    } else if (_server && _panel == _Panel.subtitles) {
      add('Off', _serverSub == null && _serverTextSub == null, () => _chooseServerSubtitle(null));
      for (final st in _streams('Subtitle')) {
        final index = (st['Index'] ?? -1) as int;
        final text = st['IsTextSubtitleStream'] == true;
        add('${_streamLabel(st)}${text ? '' : ' · drawn in by the server'}',
            index == _serverSub || index == _serverTextSub, () => _chooseServerSubtitle(st));
      }
      rows.addAll(_styleSection());
    } else if (_panel == _Panel.audio) {
      final current = player.state.track.audio;
      for (final t in player.state.tracks.audio) {
        if (t.id == 'no') continue;
        add(_trackLabel(t.id, t.title, t.language, type: 'Audio'), t == current, () {
          player.setAudioTrack(t);
          _tracks.remember('audio', _describeAudio(t));
        });
      }
    } else {
      final current = player.state.track.subtitle;
      for (final t in player.state.tracks.subtitle) {
        add(_trackLabel(t.id, t.title, t.language, type: 'Subtitle'), t == current, () {
          _setSubtitle(t);
          if (t.id == 'no') {
            _tracks.rememberSubsOff();
          } else if (int.tryParse(t.id) != null) {
            _tracks.remember('sub', _describeSub(t));
          }
        });
      }
      // Subtitles stored as separate files are not inside the video, so add them from Jellyfin.
      final external = ((widget.item['MediaStreams'] as List?) ?? [])
          .where((s) => s['Type'] == 'Subtitle' && s['IsExternal'] == true);
      for (final s in external) {
        add('${s['DisplayTitle'] ?? s['Language'] ?? 'Subtitle'} · separate file', false, () {
          _setSubtitle(_externalTrack(s));
          _tracks.remember('sub', TrackPrefs.describeStream(s));
        });
      }
      rows.addAll(_styleSection());
    }

    return Positioned.fill(
      child: Stack(children: [
        // Clicking outside the panel closes it.
        Positioned.fill(
          child: GestureDetector(
            onTap: _closePanel,
            child: Container(color: Colors.black.withOpacity(0.12)),
          ),
        ),
        // A floating glass card, like the player's buttons.
        Positioned(
          top: 32,
          bottom: 32,
          right: 32,
          width: 460,
          child: Frost(
            radius: 28,
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  _panel == _Panel.playback
                      ? 'Playback'
                      : _panel == _Panel.audio
                          ? 'Audio'
                          : 'Subtitles',
                  style: _display(28)),
              const SizedBox(height: 24),
              // Its own focus scope: arrow keys stay inside the panel while it's open.
              Expanded(
                child: FocusScope(
                  child: rows.isEmpty
                      ? Text('None in this file.', style: _body(20, color: _muted))
                      : ListView(children: rows),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// A round button that can also take a focus node from outside (used to focus Play/Pause).
class _FocusableWithNode extends StatelessWidget {
  const _FocusableWithNode({required this.onSelect, required this.builder, this.focusNode});
  final VoidCallback onSelect;
  final Widget Function(bool focused) builder;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    if (focusNode == null) return Focusable(onSelect: onSelect, builder: builder);
    return _NodeFocusable(node: focusNode!, onSelect: onSelect, builder: builder);
  }
}

class _NodeFocusable extends StatefulWidget {
  const _NodeFocusable({required this.node, required this.onSelect, required this.builder});
  final FocusNode node;
  final VoidCallback onSelect;
  final Widget Function(bool focused) builder;

  @override
  State<_NodeFocusable> createState() => _NodeFocusableState();
}

class _NodeFocusableState extends State<_NodeFocusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: widget.node,
      mouseCursor: SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onSelect();
          return null;
        }),
      },
      onFocusChange: (f) => setState(() => _focused = f),
      onShowHoverHighlight: (h) {
        if (h && !widget.node.hasFocus && !padActive.value) widget.node.requestFocus();
      },
      child: GestureDetector(onTap: widget.onSelect, child: widget.builder(_focused)),
    );
  }
}

// ---------- Progress bar: click or drag with the mouse, ←/→ when it's selected ----------

class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    this.focusNode,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.onSeek,
    required this.onKeySkip,
  });

  final FocusNode? focusNode;
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final void Function(Duration to) onSeek;
  final void Function(bool forward) onKeySkip;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  bool _focused = false;
  bool _hover = false;
  double? _dragFraction;

  double _fraction(Duration d) {
    final total = widget.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (d.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Duration _at(double fraction) =>
      Duration(milliseconds: (widget.duration.inMilliseconds * fraction.clamp(0.0, 1.0)).round());

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hover || _dragFraction != null;
    final played = _dragFraction ?? _fraction(widget.position);
    final buffered = _fraction(widget.buffered);

    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          widget.onKeySkip(false);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          widget.onKeySkip(true);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: LayoutBuilder(builder: (context, box) {
          double toFraction(double dx) => (dx / box.maxWidth).clamp(0.0, 1.0);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => widget.onSeek(_at(toFraction(d.localPosition.dx))),
            onHorizontalDragStart: (d) => setState(() => _dragFraction = toFraction(d.localPosition.dx)),
            onHorizontalDragUpdate: (d) => setState(() => _dragFraction = toFraction(d.localPosition.dx)),
            onHorizontalDragEnd: (_) {
              if (_dragFraction != null) widget.onSeek(_at(_dragFraction!));
              setState(() => _dragFraction = null);
            },
            child: SizedBox(
              height: 28,
              child: Stack(alignment: Alignment.centerLeft, clipBehavior: Clip.none, children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  height: active ? 8 : 5,
                  decoration: BoxDecoration(
                    color: _fg.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: buffered,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    height: active ? 8 : 5,
                    decoration: BoxDecoration(
                      color: _fg.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: played,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    height: active ? 8 : 5,
                    decoration: BoxDecoration(color: _fg, borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                // Handle, shown when the bar is selected, hovered or dragged.
                Positioned(
                  left: played * box.maxWidth - 11,
                  child: AnimatedOpacity(
                    opacity: active ? 1 : 0,
                    duration: const Duration(milliseconds: 140),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: _fg,
                        shape: BoxShape.circle,
                        boxShadow: _focused
                            ? [BoxShadow(color: _fg.withOpacity(0.35), spreadRadius: 6)]
                            : const [],
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          );
        }),
      ),
    );
  }
}
