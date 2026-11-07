// Player screen: full-screen video with controls that fade away while watching.
// Keyboard: Space play/pause · ←/→ skip (when controls are hidden) · arrows + Enter on buttons
// · Escape hides the controls, or leaves the player when they're already hidden.
// Mouse: moving shows the controls, click buttons, click or drag the progress bar.

import 'dart:async';
import 'dart:math' as math;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gamepad.dart' show PadHint, PadHints, PadButton, padActive, fullScreenHint;
import 'ui.dart'
    show Focusable, FocusLinks, focusOn, isDesktop, toggleFullScreen, tvBody, tvDisplay,
        phoneSidewaysOnly, kFg, kSoft, kPlaceholder, runtimeMinutes, TvCanvas, titleOf, episodeLine, sizeBucket, tvPx;
import 'images.dart' show netImage, LogoImage;
import 'main.dart' show Jellyfin;
import 'banners.dart' show showPartyNotice;
import 'syncplay.dart' show SyncPlay, SyncGroup, RoomLink, RoomVideo;
import 'party_notice.dart' show partyColorOf;
import 'perf.dart' show perfLog;
import 'tracks.dart';
import 'phone.dart';
import 'playback_rules.dart';
import 'gaming_mode.dart' show inGamingMode;
import 'package:frame_video/frame_video.dart';
import 'video_surface.dart' show surfaceWanted, surfacePlayerSkipped;
import 'crash_reports.dart' show reportProblem;
import 'downloads.dart' show Downloads;

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

/// The screen that plays a video. Every video plays in Frame's own player.
/// With [sync], the video plays in a Watch together room: play, pause and seek go through the
/// room, so everyone stays together.
Widget playerScreen(Jellyfin jf, dynamic item, {SyncPlay? sync, String? playlistItemId, int? startTicks}) =>
    PlayerScreen(jf: jf, item: item, sync: sync, playlistItemId: playlistItemId, startTicks: startTicks);

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

enum _Panel { none, playback, audio, subtitles, info }

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  // A larger buffer keeps more of the file ready, which helps smoothness and seeking over the network.
  late final Player player = Player(
    configuration: PlayerConfiguration(
      bufferSize: _phone ? 64 * 1024 * 1024 : 256 * 1024 * 1024,
      // Phones: mpv's warnings too, for the "Why isn't it playing?" box below.
      // (Through the video surface: the engine's info messages too, such as which video and
      // sound outputs it opened, to find problems on new systems.)
      logLevel: _surface ? MPVLogLevel.info : (_phone ? MPVLogLevel.warn : MPVLogLevel.error),
      // Windows and Linux (X11): mpv's best renderer, drawing into the video surface under
      // Frame's window (its "wid" is set before the video opens). See "Full quality" below.
      vo: _surface ? 'gpu-next' : null,
      libass: _surface,
    ),
  );
  static final bool _phone = Platform.isIOS || Platform.isAndroid;

  // ---------- Full quality: the video surface (Windows, Linux X11) ----------
  //
  // Instead of handing each frame to Flutter as a normal picture (no HDR), the engine draws
  // with mpv's best renderer (gpu-next: real HDR, Dolby Vision, smooth motion, 4K) into a
  // window kept just under Frame's (packages/frame_video), and this screen is see-through, so
  // the controls sit on top of the picture: one app, one window. If the surface can't be made,
  // the player falls back to drawing inside Frame's window (normal picture).
  bool _surface = !_phone && surfaceWanted;
  // Which commit this app was built from (set by the iPhone build workflow), to tell builds apart.
  static const String _build = String.fromEnvironment('FRAME_BUILD', defaultValue: 'dev');
  final List<String> _phoneLog = []; // the last few things mpv said (phones only)
  bool _showPhoneLog = false;
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
  int get _serverStep => serverStepFor(widget.item);
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
        final stream = await widget.jf.serverStream(_id,
            audioIndex: _serverAudio, subtitleIndex: _serverSub, phone: Platform.isIOS || Platform.isAndroid);
        url = stream.url;
        session = stream.session;
        subtitles = stream.subtitles;
      } catch (e) {
        debugPrint('Player: the server could not provide its version: $e');
        return false;
      }
    } else {
      // Downloaded to this device: the file here, no server needed.
      url = Downloads.instance.localFile(_id) ?? widget.jf.directStreamUrl(_id);
    }
    if (mpv is NativePlayer) {
      // Exact seeks (not the nearest keyframe, which can be seconds away): Watch together
      // only accepts a position within half a second of the room's.
      if (widget.sync != null) await mpv.setProperty('hr-seek', 'yes');
      if (server) {
        // The server already fixed the colours: no conversion on this device.
        await mpv.setProperty('vf', '');
        await mpv.setProperty('hwdec', 'auto-safe');
      } else if (_isDolbyVisionOnly && !_surface) {
        // (Through the video surface, gpu-next applies Dolby Vision's colours itself.)
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
  bool get _isDolbyVisionOnly => isDolbyVisionOnly(widget.item);
  // Phones: if the original file shows no picture within a few seconds, switch to the server's
  // version by itself, at the same moment.
  Future<void> _phoneFallback(Duration? at) async {
    // Give the original file a few seconds to show its first picture.
    for (var i = 0; i < 16; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted || _server) return;
      if ((player.state.width ?? 0) > 0 && player.state.duration > Duration.zero) return;
    }
    if (!mounted || _server) return;
    debugPrint('Player: the original file did not open on this phone; trying the server\'s version');
    _switching = true;
    try {
      await _openSource(server: true, at: at);
    } finally {
      _switching = false;
    }
  }

  // (The rules themselves are in playback_rules.dart.)
  // iPhone / iPad (and Android), like the PC version: the original file straight from the NAS
  // whenever possible (MKV, HEVC, HDR, TrueHD, DTS, every kind of subtitle), and the server's
  // version only when the original can't work here:
  // - it doesn't show a picture within a few seconds (see _phoneFallback), or
  // - it stutters (see "Adapting to this device": the last step is the server's version), or
  // - it's Dolby Vision Profile 5, which would play but in pink and green without the
  //   server's colour conversion (the phone's player can't do it, unlike mpv on a PC).

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

  // PC and TV: a rounded card at the bottom right (above the bar when the controls are up),
  // with the next episode's picture. Play now fills up like a timer; when it's full the next
  // episode starts. "Watch the credits" hides the card and lets this one play to the end.
  Widget _upNextCard() => Positioned.fill(
        child: TvCanvas(
          child: Stack(clipBehavior: Clip.none, children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              right: 56,
              bottom: _controls ? 274 : 56,
              width: 720,
              child: StreamBuilder<Duration>(
                stream: player.stream.position,
                initialData: player.state.position,
                builder: (_, snap) {
                  final at = _upNextAt(snap.data ?? Duration.zero);
                  final next = _next;
                  if (at == null || next == null || _panel != _Panel.none) return const SizedBox.shrink();
                  final (left, span) = at;
                  final fill = (1 - left / span).clamp(0.0, 1.0);
                  final thumb = sizeBucket(tvPx(240));
                  final mins = runtimeMinutes(next);
                  final line = [
                    if (next['ParentIndexNumber'] != null) 'S${next['ParentIndexNumber']}',
                    if (next['IndexNumber'] != null) 'E${next['IndexNumber']}',
                    if (mins > 0) '$mins min',
                  ].join(' · ');
                  return Container(
                    height: 257,
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: _sheet.withOpacity(0.89),
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 40, offset: Offset(0, 16))],
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: SizedBox(
                            width: 240,
                            height: 135,
                            child: netImage(widget.jf.image(next['Id'].toString(), 'Primary', maxWidth: thumb),
                                cacheWidth: thumb,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => ColoredBox(color: _fg.withOpacity(0.13))),
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const SizedBox(height: 8),
                            Text('UP NEXT · IN ${left.ceil()} S',
                                style: _body(18, weight: FontWeight.w700, color: _muted).copyWith(letterSpacing: 1)),
                            const SizedBox(height: 12),
                            Text((next['Name'] ?? 'Next episode').toString(),
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: _display(28)),
                            if (line.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(line, style: _body(21, color: _soft)),
                            ],
                          ]),
                        ),
                      ]),
                      const SizedBox(height: 20),
                      Row(children: [
                        // Selected while the controls are hidden, since Select / Enter then plays it.
                        Focusable(
                          onSelect: _playNext,
                          builder: (f) => Container(
                            height: 58,
                            padding: const EdgeInsets.fromLTRB(18, 0, 26, 0),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(29),
                              boxShadow: f || !_controls ? _ringOn : const [],
                              gradient: LinearGradient(
                                colors: const [_fg, _fg, Color(0xD1F4F5F7), Color(0xD1F4F5F7)],
                                stops: [0, fill, fill, 1],
                              ),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.play_arrow_rounded, size: 30, color: _bg),
                              const SizedBox(width: 8),
                              Text('Play now', style: _body(22, weight: FontWeight.w700, color: _bg)),
                            ]),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Focusable(
                          onSelect: () => setState(() => _nextDismissed = true),
                          builder: (f) => AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            height: 58,
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: f ? _fg : _fg.withOpacity(0.10),
                              borderRadius: BorderRadius.circular(29),
                              boxShadow: f ? _ringOn : const [],
                            ),
                            child: Text('Watch the credits',
                                style: _body(22, weight: f ? FontWeight.w700 : FontWeight.w600, color: f ? _bg : _fg)),
                          ),
                        ),
                      ]),
                    ]),
                  );
                },
              ),
            ),
          ]),
        ),
      );

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
        if (mounted) showPartyNotice(context, text, watching: widget.sync?.group.value?.people.length);
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
    // Phones: video always plays sideways (the screen it came from sets its own again on return).
    if (_phone) phoneSidewaysOnly();
    if (_phone) {
      // Leaving the app pauses the video (see "Leaving the app").
      WidgetsBinding.instance.addObserver(this);
      // Draw the picture at the screen's size, not the file's (see "Drawing at screen size").
      _subs.add(player.stream.width.listen((_) => _fitOutput()));
      _subs.add(player.stream.height.listen((_) => _fitOutput()));
    }
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
    // PC and TV: the loading screen goes once the video is on.
    _subs.add(player.stream.buffering.listen((_) => _checkLoaded()));
    _subs.add(player.stream.duration.listen((_) => _checkLoaded()));
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
    // Phones: collect what mpv says, and after 12 s with no picture show it on screen.
    if (_phone) {
      _subs.add(player.stream.log.listen((l) {
        _phoneLog.add('[${l.level}] ${l.prefix}: ${l.text.trim()}');
        if (_phoneLog.length > 14) _phoneLog.removeAt(0);
        if (_showPhoneLog && mounted) setState(() {});
        if (l.text.contains('No render context set')) unawaited(_retryAfterSurface());
      }));
      _subs.add(player.stream.error.listen((e) {
        _phoneLog.add('[error] $e');
        if (_phoneLog.length > 14) _phoneLog.removeAt(0);
      }));
      Timer(const Duration(seconds: 12), () {
        if (mounted && (player.state.width ?? 0) == 0) setState(() => _showPhoneLog = true);
      });
    }
    // Still nothing after 25 seconds: say so instead of spinning forever.
    _openTimer = Timer(const Duration(seconds: 25), () {
      if (player.state.duration == Duration.zero) {
        _fail("The server isn't sending the video. Check that the NAS is on.");
      }
    });
    unawaited(_startWhenVideoReady());
  }

  // The picture's drawing surface has to exist before the video opens, or mpv has nowhere to
  // draw ("No render context set": sound and time run, but no picture, on iPhone). The
  // controller is created here (it's lazy) and playback starts once it's ready.
  Future<void> _startWhenVideoReady() async {
    if (_surface) {
      // Step by step in the terminal, to find problems on new systems.
      debugPrint('Player: asking for the video surface');
      final id = await FrameVideo.open();
      debugPrint('Player: video surface ${id ?? 'not available'}');
      // The engine's own warnings, in the terminal too.
      _subs.add(player.stream.log.listen((l) => debugPrint('Player mpv: [${l.level}] ${l.prefix}: ${l.text.trim()}')));
      final mpv = player.platform;
      if (id != null && mpv is NativePlayer) {
        Future<void> set(String k, String v) async {
          try {
            await mpv.setProperty(k, v);
          } catch (e) {
            debugPrint('Player: $k=$v not accepted ($e)');
          }
        }

        await set('wid', '$id');
        debugPrint('Player: engine told to draw in the surface');
        if (Platform.isWindows) {
          await set('gpu-api', 'd3d11');
          await set('gpu-context', 'd3d11');
        }
        // HDR: tell the screen the video's real colours and brightness.
        await set('target-colorspace-hint', 'yes');
        // Smooth motion: frames timed to the screen, with light blending between them.
        await set('video-sync', 'display-resample');
        await set('interpolation', 'yes');
        await set('tscale', 'oversample');
        await set('background-color', '#000000');
        _note('drawing through the video surface (gpu-next)');
        // A few seconds in: what the engine is drawing with, and how big (for the terminal).
        Timer(const Duration(seconds: 6), () async {
          if (!mounted) return;
          Future<String> p(String k) async {
            try {
              return await mpv.getProperty(k);
            } catch (_) {
              return '?';
            }
          }

          debugPrint('Player: after 6 s: vo=${await p('current-vo')} '
              'video=${await p('video-params/w')}x${await p('video-params/h')} '
              'window=${await p('osd-width')}x${await p('osd-height')} '
              'hwdec=${await p('hwdec-current')} ao=${await p('current-ao')} '
              'paused=${await p('pause')} time=${await p('time-pos')}');
        });
        if (mounted) _start();
        return;
      }
      // No surface: draw inside Frame's window instead (normal picture).
      _note('no video surface; drawing inside the window');
      surfacePlayerSkipped.value = "full-quality video couldn't start on this system, so HDR is off";
      if (mounted) setState(() => _surface = false);
      if (mpv is NativePlayer) {
        try {
          await mpv.setProperty('vo', 'libmpv');
        } catch (_) {}
      }
    }
    final watch = Stopwatch()..start();
    try {
      await controller.platform.future.timeout(const Duration(seconds: 10));
      _note('video surface ready after ${watch.elapsedMilliseconds} ms');
    } catch (e) {
      _note('video surface NOT ready after ${watch.elapsedMilliseconds} ms ($e); starting anyway');
      reportProblem('Video surface not ready', details: {'error': '$e'.split('\n').first});
      if ('$e'.contains('MissingPluginException')) {
        _note('this copy of Frame was built without its video player part (build $_build): '
            'no picture for any video, original or server. Install the newest build.');
      }
    }
    if (mounted) _start();
  }

  // A line of our own in the phone diagnostics box (and the debug console).
  void _note(String text) {
    debugPrint('Player: $text');
    if (!_phone) return;
    _phoneLog.add('[frame] $text');
    if (_phoneLog.length > 14) _phoneLog.removeAt(0);
    if (_showPhoneLog && mounted) setState(() {});
  }

  // mpv gave up on the picture because its drawing surface wasn't there yet ("No render
  // context set"): sound and time keep running, but mpv won't retry the picture for this
  // file. Once the surface exists, open the same video again at the same moment (once).
  bool _surfaceRetried = false;
  Future<void> _retryAfterSurface() async {
    if (_surfaceRetried) return;
    _surfaceRetried = true;
    try {
      await controller.platform.future.timeout(const Duration(seconds: 15));
    } catch (e) {
      _note('video surface still missing ($e); not retrying');
      return;
    }
    // Let the earlier open finish before replacing it.
    while (mounted && _switching) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted || (player.state.width ?? 0) > 0) return;
    final at = player.state.position > Duration.zero ? player.state.position : null;
    _note('reopening now that the video surface exists');
    _switching = true;
    try {
      await _openSource(server: _server, at: at);
    } catch (e) {
      _note('reopen failed: $e');
    } finally {
      _switching = false;
    }
  }

  String? _failure;
  Timer? _openTimer;

  void _fail(String message) {
    if (!mounted || _failure != null || _switching) return;
    _openTimer?.cancel();
    debugPrint('Playback failed: $message');
    reportProblem('Playback failed: $message', details: {
      'source': _server ? 'server' : 'original',
      'mode': _mode,
      'dolby_vision_5': _isDolbyVisionOnly,
      'container': widget.item['Container'],
      'quality': _qualityLine(widget.item),
      'downloaded': Downloads.instance.localFile(_id) != null,
      'mpv_log': _phoneLog.isEmpty ? null : _phoneLog.last,
    });
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
      // Phones: keep the read-ahead in memory (iOS doesn't let mpv create its cache file).
      if (_phone) await mpv.setProperty('cache-on-disk', 'no');
      // (phones get a smaller read-ahead: iOS stops apps that use too much memory)
      await mpv.setProperty('demuxer-max-bytes', _phone ? '64MiB' : '256MiB');
      await mpv.setProperty('demuxer-max-back-bytes', _phone ? '32MiB' : '128MiB');
      await mpv.setProperty('demuxer-readahead-secs', '60');
      // Wi-Fi drops or a NAS waking up: reconnect and carry on instead of stopping the video
      // (reconnects on Wi-Fi drops).
      // (Each in its own try: an older libmpv that doesn't know a value mustn't stop the rest.)
      try {
        await mpv.setProperty('stream-lavf-o', 'reconnect=1,reconnect_on_network_error=1,reconnect_delay_max=4');
      } catch (_) {}
      // Old interlaced DVD and TV rips: remove the comb lines automatically (only when the
      // file is interlaced; other videos are untouched). "auto" needs mpv 0.38 or newer.
      if (!_phone) {
        try {
          await mpv.setProperty('deinterlace', 'auto');
        } catch (_) {}
      }
      // Seeks: exact on the PC (the timeline lands where you point, exact);
      // nearest keyframe on phones, which is much faster on a small CPU.
      await mpv.setProperty('hr-seek', _phone ? 'no' : 'absolute');
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
    final local = Downloads.instance.localFile(_id) != null; // downloaded: always the file here
    // Phones, and Gaming Mode on SteamOS, can't fix Dolby Vision 5's colours in this player the
    // usual way: on Automatic they use the server's version for those files.
    final wantServer =
        startWithServer(
            item: item, downloaded: local, mode: _mode, phone: (_phone || inGamingMode) && !_surface, level: _level);
    if (wantServer && _phone && _isDolbyVisionOnly && _mode == 'auto') {
      debugPrint('Player: Dolby Vision Profile 5 on a phone: using the server\'s version');
    }
    if (wantServer) _presetServerTracks();
    // Resume where I stopped last time (Jellyfin counts time in ticks of 100 nanoseconds).
    final resume = _resumeTicks > 0 ? Duration(microseconds: _resumeTicks ~/ 10) : null;
    try {
      _switching = true;
      final ok = await _openSource(server: wantServer, at: resume);
      if (!ok) await _openSource(server: false, at: resume); // server unavailable: original
      // A phone that couldn't open the original file: the server's version instead.
      if (!wantServer && (Platform.isIOS || Platform.isAndroid)) unawaited(_phoneFallback(resume));
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
    // A download: keep where you stopped on this device too (sent to the server when it answers).
    if (Downloads.instance.localFile(_id) != null && _ticksNow > 0) Downloads.instance.savePosition(_id, _ticksNow);
    if (_phone) WidgetsBinding.instance.removeObserver(this);
    _tapTimer?.cancel();
    // Stop the engine before its surface goes, then make Frame's window solid again.
    final hadSurface = _surface;
    player.dispose().whenComplete(() {
      if (hadSurface) FrameVideo.close();
    });
    _rootFocus.dispose();
    _playFocus.dispose();
    _backFocus.dispose();
    _barFocus.dispose();
    _panelFirst.dispose();
    for (final n in _tabFocus) {
      n.dispose();
    }
    _cardsScroll.dispose();
    _cardsEdges.dispose();
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
    if (!_info) _statsTimer?.cancel();
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

  void _skip(Duration by, {bool show = true}) {
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
    if (show) _showControls();
  }

  // Jumps between the Back button, progress bar and buttons, keeping the controls up.
  bool _go(FocusNode node) {
    _scheduleHide();
    return focusOn(node);
  }

  void _openPanel(_Panel panel) {
    _hideTimer?.cancel();
    setState(() {
      _panel = panel;
      _controls = true;
      _chrome = true;
    });
    _statsTimer?.cancel();
    if (panel == _Panel.info) {
      _readStats();
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _readStats());
    }
    // Select what's in use (or the first choice) once the panel is on screen; Info selects
    // its tab.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tab = _tvTabs.indexOf(panel);
      if (panel != _Panel.info && _panelFirst.context != null) {
        _panelFirst.requestFocus();
      } else if (tab >= 0 && _tabFocus[tab].context != null) {
        _tabFocus[tab].requestFocus();
      }
    });
  }

  void _closePanel() {
    setState(() => _panel = _Panel.none);
    if (!_info) _statsTimer?.cancel();
    // The bar is rebuilt this frame; select Play once it's there.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playFocus.requestFocus();
    });
    _scheduleHide();
  }

  void _toggleInfo() {
    // PC and TV: Info is a tab of the sheet.
    if (!_phone) {
      if (_panel == _Panel.info) {
        _closePanel();
      } else {
        _openPanel(_Panel.info);
      }
      return;
    }
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
    // PC and TV: the same, as rows for the Info tab.
    final details = _phone ? const <(String, String)>[] : await _readDetails(p, hw, dropped, cache);
    if (!mounted) return;
    if (!_phone) _details = details;
    setState(() => _stats = 'Decoder  ${hw.isEmpty || hw == 'no' ? 'CPU' : 'GPU ($hw)'}\n'
        'Dropped frames  $dropped / $decoderDropped\n'
        'Buffered  ${cacheSecs}s\n'
        'Source  ${_server ? 'converted by your server (NAS)' : 'original file, direct play'}'
        '${_isDolbyVisionOnly && !_server ? '\nDolby Vision P5: colours converted by libplacebo' : ''}'
        '${!_server && _level > 0 ? '\nPicture  eased for this device (step $_level)' : ''}'
        '\nPlayback choice  ${_mode == 'auto' ? 'Automatic' : _mode == 'server' ? 'Server' : 'Original file'}');
  }

  // Info's rows: the video, sound, subtitles, where it comes from, the decoder, the buffer and
  // the screen.
  Future<List<(String, String)>> _readDetails(
      Future<String> Function(String) p, String hw, String dropped, String cache) async {
    final w = int.tryParse(await p('video-params/w')) ?? 0;
    final h = int.tryParse(await p('video-params/h')) ?? 0;
    final gamma = await p('video-params/gamma');
    final codec = await p('video-format');
    final fps = double.tryParse(await p('container-fps')) ?? 0;
    final targetGamma = await p('video-target-params/gamma');
    final hz = double.tryParse(await p('display-fps')) ?? 0;
    final ow = int.tryParse(await p('osd-width')) ?? 0;
    final oh = int.tryParse(await p('osd-height')) ?? 0;
    final quality = _qualityLine(widget.item);
    String fpsText(double f) => '${f.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')} fps';
    final video = [
      if (h > 0)
        (w >= 3200 || h >= 2000)
            ? '4K'
            : (w >= 1800 || h >= 1000)
                ? '1080p'
                : (w >= 1200 || h >= 700)
                    ? '720p'
                    : '${h}p',
      if (codec.isNotEmpty && codec != '?') codec.toUpperCase(),
      if (fps > 0) fpsText(fps),
      quality.contains('Dolby')
          ? 'Dolby Vision'
          : (gamma == 'pq' || gamma == 'hlg' || quality.contains('HDR'))
              ? 'HDR'
              : 'SDR',
    ].join(' · ');
    final secs = double.tryParse(cache) ?? 0;
    final buffered = secs >= 60 ? '${secs ~/ 60} min ${(secs % 60).floor()} s' : '${secs.floor()} s';
    final drops = int.tryParse(dropped) ?? 0;
    return [
      ('Video', video),
      ('Audio', _tabValue(_Panel.audio)),
      ('Subtitles', _tabValue(_Panel.subtitles)),
      ('Playing', _server ? 'Converted by your server' : 'Original file · direct play'),
      ('Decoder', hw.isEmpty || hw == 'no' || hw == '?' ? 'CPU' : 'GPU · ${hw[0].toUpperCase()}${hw.substring(1)}'),
      ('Buffered', '$buffered · $drops ${drops == 1 ? 'dropped frame' : 'dropped frames'}'),
      (
        'Your screen',
        [
          (targetGamma == 'pq' || targetGamma == 'hlg') ? 'HDR' : 'SDR',
          if (hz > 0) '${hz.round()} Hz',
          if (ow > 0) '$ow × $oh',
        ].join(' · ')
      ),
      if (!_server && _level > 0) ('Picture', 'Eased for this device (step $_level)'),
    ];
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

    // PC and TV, while the loading screen shows: Back cancels.
    if (!_phone && !_loaded && (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace)) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }

    // Space (or Options on the controller) always plays or pauses.
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    // Triangle / Y: playback info, like in the mpv player.
    if (key == LogicalKeyboardKey.contextMenu && (_panel == _Panel.none || _panel == _Panel.info)) {
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
      // PC and TV: L1 / R1 switch between the sheet's tabs.
      if (!_phone && (key == LogicalKeyboardKey.mediaRewind || key == LogicalKeyboardKey.mediaFastForward)) {
        final i = _tvTabs.indexOf(_panel);
        final n = (i + (key == LogicalKeyboardKey.mediaFastForward ? 1 : -1)).clamp(0, _tvTabs.length - 1);
        _switchTab(_tvTabs[n]);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) focusOn(_tabFocus[n]);
        });
        return KeyEventResult.handled;
      }
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
        : !_phone && !_loaded
        ? const [PadHint(PadButton.back, 'Cancel')]
        : _panel != _Panel.none
        ? [
            const PadHint(PadButton.select, 'Select'),
            if (!_phone) const PadHint(PadButton.skip, 'Switch'),
            const PadHint(PadButton.back, 'Close'),
          ]
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
        // See-through over the video surface (the picture is drawn behind Frame's window).
        backgroundColor: _surface ? Colors.transparent : Colors.black,
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
              child: _phone
                  ? _phoneGestures(_video())
                  : GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _controls ? _hideControls() : _showControls(focusPlay: true),
                      // Double-click for full screen on PC only, so taps on the phone stay instant.
                      onDoubleTap: isDesktop ? toggleFullScreen : null,
                      child: _video(),
                    ),
            ),

            // Phones: when a video doesn't start, what the player is doing (to fix it).
            if (_showPhoneLog)
              Positioned(
                left: 40,
                right: 40,
                bottom: 40,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: const Color(0xE612151B), borderRadius: BorderRadius.circular(20)),
                    child: Text(
                      [
                        "Why isn't it playing? (screenshot this) · build $_build",
                        '${_server ? "Server's version" : 'Original file'} · '
                            '${(widget.item['Container'] ?? '?')} · '
                            'length ${player.state.duration.inSeconds}s · '
                            'picture ${player.state.width ?? 0}x${player.state.height ?? 0} · '
                            'buffering ${player.state.buffering} · playing ${player.state.playing} · '
                            'buffered ${player.state.buffer.inSeconds}s',
                        ..._phoneLog,
                      ].join('\n'),
                      style: const TextStyle(fontSize: 22, height: 1.35, color: Color(0xFFD3D8E0), fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ),

            // Loading spinner while the video starts or buffers.
            Positioned.fill(
              child: IgnorePointer(
                child: StreamBuilder<bool>(
                  stream: player.stream.buffering,
                  initialData: true,
                  builder: (_, snap) => snap.data == true && (_phone || _loadingGone)
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
                  child: !_chrome
                      ? const SizedBox.shrink()
                      : _phone
                          ? Stack(children: [
                              _phoneTopBar(title, episodeLine),
                              _phoneCenter(),
                              _phoneBottomBar(),
                            ])
                          // PC and TV: hidden under the loading screen until the video is on.
                          : !_loaded
                              ? const SizedBox.shrink()
                              : TvCanvas(
                                  child: Stack(clipBehavior: Clip.none, children: [
                                    _tvTop(title, episodeLine),
                                    if (_panel == _Panel.none) _tvBar() else _tvSheet(),
                                  ]),
                                ),
                ),
              ),
            ),

            if (_phone) ..._phoneOverlays(),
            if (_next != null) _phone ? _phoneUpNext() : _upNextCard(),
            if (_phone && _info) _phoneInfo(),
            if (_phone && _panel != _Panel.none) _phonePanel(),
            if (_subEdit) _phoneSubEdit(),
            if (!_phone && !_loadingGone) _tvLoading(),
            if (_failure != null) _failureBox(),
          ]),
        ),
      ),
      ),
    );
  }

  // The video itself, with no built-in controls. Pinch on a phone fills the screen.
  Widget _video() => _surface
      ? const SizedBox.expand()
      : Video(
        controller: controller,
        controls: NoVideoControls,
        fill: Colors.black,
        fit: _fill ? BoxFit.cover : BoxFit.contain,
        // Subtitles are drawn by mpv onto the video itself, so the plain text version is off.
        subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
      );

  // ---------- Phones: drawing at screen size ----------
  //
  // mpv draws each frame at the size it's asked for, which is the file's size by default: a 4K
  // movie is drawn at 3840x2160 every frame, though an iPhone screen sideways is about
  // 2556x1179. Asking for the screen's size instead (keeping the video's shape, just covering
  // the screen so a pinch to fill stays sharp) cuts the drawing work by more than half for 4K:
  // less heat, less battery, fewer dropped frames. Smaller videos are left as they are.

  int? _outW, _outH;

  Future<void> _fitOutput() async {
    final vw = player.state.width, vh = player.state.height;
    if (vw == null || vh == null || vw <= 0 || vh <= 0) return;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final sw = math.max(view.physicalSize.width, view.physicalSize.height);
    final sh = math.min(view.physicalSize.width, view.physicalSize.height);
    if (sw <= 0 || sh <= 0) return;
    final scale = math.min(1.0, math.max(sw / vw, sh / vh));
    if (scale > 0.97) return; // already about the screen's size
    final w = (vw * scale).round() & ~1, h = (vh * scale).round() & ~1;
    if (w == _outW && h == _outH) return;
    _outW = w;
    _outH = h;
    try {
      final out = await controller.platform.future;
      await out.setSize(width: w, height: h);
      _note('drawing at ${w}x$h for this screen (the video is ${vw}x$vh)');
    } catch (e) {
      _note('could not draw at screen size ($e)');
    }
  }

  // ---------- Phones: leaving the app ----------
  //
  // iOS doesn't let an app draw with the GPU (OpenGL, which mpv uses) while it's in the
  // background, and stops apps that try. So when Frame leaves the screen (home, another app,
  // the phone locked), the video pauses and mpv stops decoding the picture. Coming back, the
  // picture returns where it was, paused, with the controls up. In a watch party the video
  // isn't paused (that would pause everyone); only the picture stops while you're away.

  bool _away = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_phone) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _leaveApp();
    } else if (state == AppLifecycleState.resumed) {
      _backToApp();
    }
  }

  Future<void> _leaveApp() async {
    if (_away) return;
    _away = true;
    if (_held) _phoneHold(false);
    try {
      if (_room == null && player.state.playing) await player.pause();
      final mpv = player.platform;
      if (mpv is NativePlayer) await mpv.setProperty('vid', 'no');
    } catch (_) {}
  }

  Future<void> _backToApp() async {
    if (!_away) return;
    _away = false;
    try {
      final mpv = player.platform;
      if (mpv is NativePlayer) await mpv.setProperty('vid', 'auto');
    } catch (_) {}
    if (mounted) _showControls();
  }

  // ---------- Phones: touch and phone-sized controls ----------
  //
  // Tap shows or hides the controls. Double-tap the left or right third to go back 10 s or
  // forward 30 s (keep tapping to add more), the middle to play or pause. Press and hold for
  // 2× speed while held. Swipe down to close. Pinch to fill the screen or fit the video.
  // The controls, menus, info and Up next card are sized for a phone held sideways.

  bool _fill = false;
  double _speed = 1.0;
  bool _held = false; // 2× while the finger stays down
  int _tapSide = 0; // -1 left, 1 right: the double-tap skip showing right now
  int _tapTotal = 0;
  Timer? _tapTimer;
  Offset? _doubleTapAt;
  double _dragDown = 0;
  bool _pinching = false;
  bool _subEdit = false; // Size & position for subtitles, over the video
  int _infoTab = 0; // 0 episode, 1 the show, 2 playback info
  dynamic _series;

  EdgeInsets get _phonePad {
    final p = MediaQuery.paddingOf(context);
    return EdgeInsets.fromLTRB(p.left > 44 ? p.left : 44, p.top, p.right > 44 ? p.right : 44, p.bottom);
  }

  Widget _phoneGestures(Widget video) => LayoutBuilder(builder: (context, box) {
        int sideOf(Offset p) => p.dx < box.maxWidth / 3 ? -1 : (p.dx > box.maxWidth * 2 / 3 ? 1 : 0);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            // While a double-tap skip shows, more taps on the same side add more.
            final side = sideOf(d.localPosition);
            if (_tapTimer?.isActive == true && side != 0 && side == _tapSide) {
              _phoneSkipTap(side);
              return;
            }
            _controls ? _hideControls() : _showControls();
          },
          onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
          onDoubleTap: () {
            final side = sideOf(_doubleTapAt ?? Offset(box.maxWidth / 2, 0));
            if (side == 0) {
              _togglePlay();
            } else {
              _phoneSkipTap(side);
            }
          },
          onLongPressStart: (_) => _phoneHold(true),
          onLongPressEnd: (_) => _phoneHold(false),
          onScaleStart: (d) {
            _dragDown = 0;
            _pinching = d.pointerCount > 1;
          },
          onScaleUpdate: (d) {
            if (d.pointerCount > 1) {
              _pinching = true;
              if (d.scale > 1.15 && !_fill) {
                HapticFeedback.selectionClick();
                setState(() => _fill = true);
              } else if (d.scale < 0.87 && _fill) {
                HapticFeedback.selectionClick();
                setState(() => _fill = false);
              }
            } else if (!_pinching) {
              _dragDown += d.focalPointDelta.dy;
            }
          },
          onScaleEnd: (_) {
            if (!_pinching && _dragDown > 120) Navigator.of(context).maybePop();
            _pinching = false;
            _dragDown = 0;
          },
          child: video,
        );
      });

  void _phoneSkipTap(int side) {
    HapticFeedback.selectionClick();
    final step = side < 0 ? _back : _forward;
    final adding = _tapTimer?.isActive == true && _tapSide == side;
    setState(() {
      _tapTotal = adding ? _tapTotal + step.inSeconds : step.inSeconds;
      _tapSide = side;
    });
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _tapSide = 0);
    });
    _skip(side < 0 ? -step : step, show: false);
  }

  // Press and hold: 2× while held (not in a watch party, where speed is shared).
  void _phoneHold(bool on) {
    if (_room != null || _held == on) return;
    if (on) HapticFeedback.mediumImpact();
    setState(() => _held = on);
    player.setRate(on ? 2.0 : _speed);
  }

  void _setSpeed(double speed) {
    setState(() => _speed = speed);
    player.setRate(speed);
  }

  // The double-tap ripple on one side, and the 2× pill while holding.
  List<Widget> _phoneOverlays() => [
        if (_tapSide != 0)
          Positioned(
            top: 0,
            bottom: 0,
            left: _tapSide < 0 ? 0 : null,
            right: _tapSide > 0 ? 0 : null,
            width: MediaQuery.sizeOf(context).width * 0.38,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0x24F4F5F7),
                  borderRadius: _tapSide < 0
                      ? const BorderRadius.horizontal(right: Radius.circular(400))
                      : const BorderRadius.horizontal(left: Radius.circular(400)),
                ),
                alignment: Alignment.center,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_tapSide < 0 ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded, size: 36, color: _fg),
                  const SizedBox(height: 6),
                  Text('${_tapSide < 0 ? '−' : '+'}$_tapTotal s', style: phoneText(16, weight: FontWeight.w700)),
                ]),
              ),
            ),
          ),
        if (_held)
          Positioned(
            top: _phonePad.top + 16,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(color: const Color(0xD9151920), borderRadius: BorderRadius.circular(18)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.fast_forward_rounded, size: 18, color: _fg),
                    const SizedBox(width: 6),
                    Text('2×', style: phoneText(15, weight: FontWeight.w700)),
                  ]),
                ),
              ),
            ),
          ),
      ];

  Widget _round(IconData icon, VoidCallback onTap, String label, {double size = 44, bool white = false}) => Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          onTap: () {
            phoneTap();
            onTap();
          },
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: white ? const Color(0xEBF4F5F7) : const Color(0x7306080B), shape: BoxShape.circle),
            child: Icon(icon, size: size * 0.48, color: white ? _bg : _fg),
          ),
        ),
      );

  Widget _phoneTopBar(String title, String episodeLine) {
    final m = _phonePad;
    final quality = _qualityLine(widget.item);
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(m.left, m.top + 14, m.right, 40),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withOpacity(0.75), Colors.black.withOpacity(0)],
          ),
        ),
        child: Row(children: [
          _round(Icons.arrow_back_ios_new_rounded, () => Navigator.of(context).maybePop(), 'Back'),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: phoneTitle(17)),
              if (episodeLine.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(episodeLine,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: phoneText(13, weight: FontWeight.w500, color: _soft)),
              ],
            ]),
          ),
          if (quality.isNotEmpty) ...[
            const SizedBox(width: 12),
            Text(quality, style: phoneText(12, color: _soft)),
          ],
        ]),
      ),
    );
  }

  Widget _phoneCenter() => Positioned.fill(
        child: Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _round(Icons.replay_10_rounded, () => _skip(-_back), 'Back 10 seconds', size: 56),
            const SizedBox(width: 40),
            StreamBuilder<bool>(
              stream: player.stream.playing,
              initialData: player.state.playing,
              builder: (_, snap) => _round(snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  _togglePlay, snap.data == true ? 'Pause' : 'Play',
                  size: 76, white: true),
            ),
            const SizedBox(width: 40),
            _round(Icons.forward_30_rounded, () => _skip(_forward), 'Forward 30 seconds', size: 56),
          ]),
        ),
      );

  // What's chosen now, for the buttons under the timeline.
  String _audioNow() {
    try {
      final t = player.state.track.audio;
      if (_server || t.id == 'auto' || t.id == 'no') return '';
      return _trackLabel(t.id, t.title, t.language, type: 'Audio').split(' · ').first;
    } catch (_) {
      return '';
    }
  }

  String _subsNow() {
    try {
      if (_server) return (_serverSub == null && _serverTextSub == null) ? 'Off' : '';
      final t = player.state.track.subtitle;
      if (t.id == 'no') return 'Off';
      if (t.id == 'auto') return '';
      return _trackLabel(t.id, t.title, t.language, type: 'Subtitle').split(' · ').first;
    } catch (_) {
      return '';
    }
  }

  Widget _phonePill(String label, String value, VoidCallback onTap) => GestureDetector(
        onTap: () {
          phoneTap();
          onTap();
        },
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(color: const Color(0xD92C313B), borderRadius: BorderRadius.circular(22)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: phoneText(13)),
            if (value.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 130),
                child: Text(' · $value',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: phoneText(13, weight: FontWeight.w500, color: _muted)),
              ),
          ]),
        ),
      );

  Widget _phoneBottomBar() {
    final m = _phonePad;
    final chapters = ((widget.item['Chapters'] as List?) ?? const [])
        .map((c) => (
              at: Duration(microseconds: ((c['StartPositionTicks'] ?? 0) as int) ~/ 10),
              name: (c['Name'] ?? '').toString(),
            ))
        .toList();
    final playback = _mode == 'auto' ? 'Automatic' : (_mode == 'server' ? 'Server' : 'Original');
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(m.left, 60, m.right, m.bottom + 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withOpacity(0.85), Colors.black.withOpacity(0)],
          ),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          StreamBuilder<Duration>(
            stream: player.stream.position,
            initialData: player.state.position,
            builder: (_, snap) {
              final pos = snap.data ?? Duration.zero;
              final dur = player.state.duration;
              final left = dur > pos ? dur - pos : Duration.zero;
              return Row(children: [
                SizedBox(width: 54, child: Text(_clock(pos), style: phoneText(13, color: _soft))),
                Expanded(
                  child: _PhoneScrubber(
                    position: pos,
                    duration: dur,
                    chapters: chapters,
                    onDrag: () => _hideTimer?.cancel(),
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
                  ),
                ),
                SizedBox(
                  width: 62,
                  child: Text('-${_clock(left)}', textAlign: TextAlign.right, style: phoneText(13, color: _soft)),
                ),
              ]);
            },
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _phonePill('Audio', _audioNow(), () => _openPanel(_Panel.audio)),
              const SizedBox(width: 8),
              _phonePill('Subtitles', _subsNow(), () => _openPanel(_Panel.subtitles)),
              const SizedBox(width: 8),
              _phonePill('Playback', _speed == 1.0 ? playback : '$playback · ${_speedText(_speed)}',
                  () => _openPanel(_Panel.playback)),
              const SizedBox(width: 8),
              _phonePill('Info', '', _toggleInfo),
            ]),
          ),
        ]),
      ),
    );
  }

  static String _speedText(double s) => '${s == s.roundToDouble() ? s.toInt() : s}×';

  // The choices in the Audio, Subtitles and Playback menus (same as the TV panel).
  List<({String label, String note, bool selected, VoidCallback onSelect})> _choices([_Panel? which]) {
    final panel = which ?? _panel;
    final out = <({String label, String note, bool selected, VoidCallback onSelect})>[];
    void add(String label, bool selected, VoidCallback onSelect, {String note = ''}) =>
        out.add((label: label, note: note, selected: selected, onSelect: onSelect));

    if (panel == _Panel.playback) {
      add('Automatic', _mode == 'auto', () => _setMode('auto'),
          note: "The original, the server's version if it struggles");
      add('Original file · best quality', _mode == 'original', () => _setMode('original'));
      add('Converted by the server · smoothest', _mode == 'server', () => _setMode('server'));
    } else if (_server && panel == _Panel.audio) {
      final audio = _streams('Audio');
      final current = _serverAudio ?? (audio.firstWhere((a) => a['IsDefault'] == true, orElse: () => null)?['Index']);
      for (final a in audio) {
        final index = (a['Index'] ?? -1) as int;
        add(_streamLabel(a), index == current, () => _chooseServerAudio(index));
      }
    } else if (_server && panel == _Panel.subtitles) {
      add('Off', _serverSub == null && _serverTextSub == null, () => _chooseServerSubtitle(null));
      for (final st in _streams('Subtitle')) {
        final index = (st['Index'] ?? -1) as int;
        final text = st['IsTextSubtitleStream'] == true;
        add(_streamLabel(st), index == _serverSub || index == _serverTextSub, () => _chooseServerSubtitle(st),
            note: text ? '' : 'Drawn in by the server');
      }
    } else if (panel == _Panel.audio) {
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
      final external = ((widget.item['MediaStreams'] as List?) ?? [])
          .where((s) => s['Type'] == 'Subtitle' && s['IsExternal'] == true);
      for (final s in external) {
        add('${s['DisplayTitle'] ?? s['Language'] ?? 'Subtitle'}', false, () {
          _setSubtitle(_externalTrack(s));
          _tracks.remember('sub', TrackPrefs.describeStream(s));
        }, note: 'Separate file');
      }
    }
    return out;
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: () {
          phoneTap();
          onTap();
        },
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? _fg : const Color(0xBF4A4E57),
            borderRadius: BorderRadius.circular(17),
          ),
          child: Text(label, style: phoneText(13, weight: FontWeight.w700, color: on ? _bg : _fg)),
        ),
      );

  // Audio, Subtitles or Playback: a panel from the right. Tap a choice to use it.
  Widget _phonePanel() {
    final m = _phonePad;
    final choices = _choices();
    final title = _panel == _Panel.playback ? 'Playback' : (_panel == _Panel.audio ? 'Audio' : 'Subtitles');
    return Positioned.fill(
      child: Stack(children: [
        Positioned.fill(
          child: GestureDetector(onTap: _closePanel, child: Container(color: Colors.black.withOpacity(0.35))),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: 360 + m.right,
          child: GestureDetector(
            onHorizontalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) > 300) _closePanel();
            },
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0xF7151920),
                borderRadius: BorderRadius.horizontal(left: Radius.circular(24)),
              ),
              padding: EdgeInsets.fromLTRB(22, m.top + 16, m.right, m.bottom + 12),
              child: Material(
                type: MaterialType.transparency,
                child: ListView(padding: EdgeInsets.zero, children: [
                  Row(children: [
                    Expanded(child: Text(title, style: phoneTitle(20))),
                    if (_panel == _Panel.subtitles)
                      _chip('Size & position', false, () {
                        setState(() {
                          _panel = _Panel.none;
                          _subEdit = true;
                          _controls = false;
                        });
                      }),
                  ]),
                  if (_panel == _Panel.playback) ...[
                    const SizedBox(height: 4),
                    Text(_server ? 'Now: the version your server converts' : 'Now: the original file, straight from the NAS',
                        style: phoneText(12, color: _muted)),
                  ],
                  const SizedBox(height: 14),
                  if (choices.isEmpty)
                    Text('None in this file.', style: phoneText(15, color: _muted))
                  else
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: ColoredBox(
                        color: const Color(0x8C2C313B),
                        child: Column(children: [
                          for (final c in choices)
                            InkWell(
                              onTap: () {
                                phoneTap();
                                c.onSelect();
                                _closePanel();
                              },
                              child: Container(
                                color: c.selected ? _fg : Colors.transparent,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                child: Row(children: [
                                  Expanded(
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(c.label,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: phoneText(15,
                                              weight: c.selected ? FontWeight.w700 : FontWeight.w600,
                                              color: c.selected ? _bg : _fg)),
                                      if (c.note.isNotEmpty)
                                        Text(c.note,
                                            style: phoneText(12, color: c.selected ? const Color(0xFF3B414C) : _muted)),
                                    ]),
                                  ),
                                  if (c.selected) const Icon(Icons.check_rounded, size: 20, color: _bg),
                                ]),
                              ),
                            ),
                        ]),
                      ),
                    ),
                  if (_panel == _Panel.playback && _room == null) ...[
                    const SizedBox(height: 18),
                    Text('SPEED', style: phoneText(11, weight: FontWeight.w700, color: _muted).copyWith(letterSpacing: 1)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final s in const [0.75, 1.0, 1.25, 1.5, 2.0])
                        _chip(_speedText(s), _speed == s, () => _setSpeed(s)),
                    ]),
                  ],
                  if (_panel != _Panel.playback) ...[
                    const SizedBox(height: 12),
                    Text('Your choice is remembered for the whole show.', style: phoneText(12, color: _muted)),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  // Subtitles: size and position over the video, changes show live on the picture.
  Widget _phoneSubEdit() {
    final m = _phonePad;
    void done() => setState(() => _subEdit = false);
    final height = 100 - _subPos; // 0 = bottom of the picture
    return Positioned(
      left: m.left,
      right: m.right,
      top: m.top + 12,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          decoration: BoxDecoration(color: const Color(0xF0151920), borderRadius: BorderRadius.circular(18)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: Text('Subtitle size & position', style: phoneTitle(16))),
              _chip('Reset', false, () => _changeSubStyle(scale: 1.0, pos: 100, box: false)),
              const SizedBox(width: 8),
              _chip('Done', true, done),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              _chip('Bottom', _subPos == 100, () => _changeSubStyle(pos: 100)),
              const SizedBox(width: 6),
              _chip('Raised', _subPos == 92, () => _changeSubStyle(pos: 92)),
              const SizedBox(width: 6),
              _chip('Higher', _subPos == 80, () => _changeSubStyle(pos: 80)),
              const SizedBox(width: 6),
              _chip('Box', _subBox, () => _changeSubStyle(box: !_subBox)),
            ]),
            Row(children: [
              SizedBox(width: 54, child: Text('Size', style: phoneText(13, color: _muted))),
              Expanded(
                child: Slider(
                  value: _subScale.clamp(0.5, 2.0).toDouble(),
                  min: 0.5,
                  max: 2.0,
                  divisions: 15,
                  activeColor: _fg,
                  inactiveColor: const Color(0x40F4F5F7),
                  onChanged: (v) => _changeSubStyle(scale: v),
                ),
              ),
              SizedBox(width: 44, child: Text('${(_subScale * 100).round()}%', style: phoneText(13))),
            ]),
            Row(children: [
              SizedBox(width: 54, child: Text('Height', style: phoneText(13, color: _muted))),
              Expanded(
                child: Slider(
                  value: height.clamp(0, 80).toDouble(),
                  min: 0,
                  max: 80,
                  divisions: 80,
                  activeColor: _fg,
                  inactiveColor: const Color(0x40F4F5F7),
                  onChanged: (v) => _changeSubStyle(pos: 100 - v.round()),
                ),
              ),
              SizedBox(width: 44, child: Text(height == 0 ? 'Bottom' : '+$height', style: phoneText(13))),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _loadSeries() async {
    final id = widget.item['SeriesId'];
    if (id == null || _series != null) return;
    try {
      final s = await widget.jf.item(id.toString());
      if (mounted) setState(() => _series = s);
    } catch (_) {}
  }

  // About this episode: the episode, the show, playback info; the next episode on the right.
  Widget _phoneInfo() {
    final m = _phonePad;
    final item = widget.item;
    final isEpisode = item['Type'] == 'Episode';
    if (isEpisode && _infoTab == 1) _loadSeries();
    final tabs = [isEpisode ? 'Episode' : 'About', if (isEpisode) 'The show', 'Playback info'];
    final tab = _infoTab.clamp(0, tabs.length - 1);
    final techTab = tab == tabs.length - 1;
    final mins = runtimeMinutes(item);
    final aired = DateTime.tryParse((item['PremiereDate'] ?? '').toString());
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

    Widget body;
    if (techTab) {
      body = Text(_stats.isEmpty ? 'Reading…' : _stats, style: phoneText(13, weight: FontWeight.w500, color: _soft, height: 1.6));
    } else if (tab == 1) {
      final s = _series ?? const {};
      final genres = ((s['Genres'] as List?) ?? const []).take(3).join(', ');
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(item['SeriesName']?.toString() ?? '', style: phoneTitle(22)),
        const SizedBox(height: 4),
        Text([s['ProductionYear']?.toString() ?? '', s['OfficialRating']?.toString() ?? '', genres]
                .where((x) => x.isNotEmpty)
                .join(' · '),
            style: phoneText(13, color: _muted)),
        const SizedBox(height: 8),
        Text((s['Overview'] ?? (_series == null ? 'Loading…' : '')).toString(),
            style: phoneText(14, weight: FontWeight.w400, color: const Color(0xFFC3C9D3), height: 1.5)),
      ]);
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (isEpisode)
          Text('${item['SeriesName'] ?? ''} · ${_episodeTitle(item).split(' · ').take(2).join(' · ')}',
              style: phoneTitle(14).copyWith(color: _soft)),
        const SizedBox(height: 4),
        Text(item['Name']?.toString() ?? '', style: phoneTitle(22)),
        const SizedBox(height: 4),
        Text(
            [
              if (mins > 0) '$mins min',
              if (aired != null) 'Aired ${months[aired.month - 1]} ${aired.day}, ${aired.year}',
            ].join(' · '),
            style: phoneText(13, color: _muted)),
        const SizedBox(height: 8),
        Text((item['Overview'] ?? '').toString(),
            style: phoneText(14, weight: FontWeight.w400, color: const Color(0xFFC3C9D3), height: 1.5)),
      ]);
    }

    final next = _next;
    return Positioned.fill(
      child: GestureDetector(
        onTap: _toggleInfo,
        child: Container(
          color: const Color(0xD106080B),
          padding: EdgeInsets.fromLTRB(m.left, m.top + 16, m.right, m.bottom + 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  for (var i = 0; i < tabs.length; i++) ...[
                    _chip(tabs[i], i == tab, () => setState(() => _infoTab = i)),
                    const SizedBox(width: 6),
                  ],
                  const Spacer(),
                  _round(Icons.close_rounded, _toggleInfo, 'Close', size: 34),
                ]),
                const SizedBox(height: 12),
                // Taps inside the text don't close the info.
                Expanded(child: GestureDetector(onTap: () {}, child: SingleChildScrollView(child: body))),
              ]),
            ),
            if (next != null) ...[
              const SizedBox(width: 24),
              SizedBox(
                width: 200,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const SizedBox(height: 44),
                  Text('NEXT EPISODE', style: phoneText(11, weight: FontWeight.w700, color: _muted).copyWith(letterSpacing: 1)),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 200,
                      height: 112,
                      child: netImage(widget.jf.image(next['Id'].toString(), 'Primary', maxWidth: phoneDecode(context, 200)),
                          cacheWidth: phoneDecode(context, 200),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const ColoredBox(color: kPlaceholder)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(_episodeTitle(next), maxLines: 2, overflow: TextOverflow.ellipsis, style: phoneText(14, weight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  PhoneButton(label: 'Play next', height: 36, onTap: _playNext),
                ]),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  // Up next over the credits: the next episode, Play in N (it starts by itself at the end),
  // and Watch credits to hide the card.
  Widget _phoneUpNext() {
    final m = _phonePad;
    return Positioned(
      right: m.right,
      bottom: m.bottom + (_controls ? 120 : 20),
      child: StreamBuilder<Duration>(
        stream: player.stream.position,
        initialData: player.state.position,
        builder: (_, snap) {
          final at = _upNextAt(snap.data ?? Duration.zero);
          final next = _next;
          if (at == null || next == null || _panel != _Panel.none) return const SizedBox.shrink();
          final (left, _) = at;
          final thumbW = phoneDecode(context, 132);
          return Container(
            width: 380,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xF2151920),
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 40, offset: Offset(0, 16))],
            ),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 132,
                  height: 74,
                  child: netImage(widget.jf.image(next['Id'].toString(), 'Primary', maxWidth: thumbW),
                      cacheWidth: thumbW,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const ColoredBox(color: kPlaceholder)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('UP NEXT · ${_episodeTitle(next).split(' · ').take(2).join(' · ')}',
                      style: phoneText(11, weight: FontWeight.w700, color: _muted).copyWith(letterSpacing: 0.8)),
                  const SizedBox(height: 2),
                  Text(next['Name']?.toString() ?? '',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: phoneText(15, weight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Row(children: [
                    PhoneButton(primary: true, label: 'Play in ${left.ceil()}', icon: Icons.play_arrow_rounded, height: 36, onTap: _playNext),
                    const SizedBox(width: 8),
                    Flexible(
                      child: PhoneButton(
                          label: 'Watch credits', height: 36, onTap: () => setState(() => _nextDismissed = true)),
                    ),
                  ]),
                ]),
              ),
            ]),
          );
        },
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

  // ---------- PC and TV: the controls ----------
  //
  // The design from the canvas, drawn on a 1920 × 1080 canvas (TvCanvas) so it looks the same
  // at any window size:
  // - Top: Back, the title and episode; on the right how it plays, when it ends and who's
  //   watching together.
  // - Bottom: the bar, a dark sheet folded down: the timeline with the times either side, the
  //   Audio / Subtitles / Playback / Info tabs on the left (each with what's in use under it)
  //   and −10, play, +30 in the middle.
  // - Choosing a tab opens the sheet further: the same tabs along the top (L1 / R1 switch),
  //   the choices as big cards in a row, small pills for subtitle style or speed, and for Info
  //   the episode and how it's playing.

  static const _sheet = Color(0xFF12151B);
  static const _cardInk = Color(0xFF3B4250); // second line on a selected (white) card
  // Selected: a dark gap, then a white ring, like everything selected in Frame.
  static const _ringOn = [BoxShadow(color: _sheet, spreadRadius: 4), BoxShadow(color: _fg, spreadRadius: 9)];
  static const _tvTabs = [_Panel.audio, _Panel.subtitles, _Panel.playback, _Panel.info];
  final _tabFocus = [for (var i = 0; i < 4; i++) FocusNode()];

  static String _tabName(_Panel p) => switch (p) {
        _Panel.audio => 'Audio',
        _Panel.subtitles => 'Subtitles',
        _Panel.playback => 'Playback',
        _Panel.info => 'Info',
        _Panel.none => '',
      };

  // What's in use, under each tab on the bar.
  String _tabValue(_Panel p) {
    switch (p) {
      case _Panel.info:
        return _qualityLine(widget.item);
      case _Panel.playback:
        final mode = _mode == 'auto' ? 'Automatic' : (_mode == 'server' ? 'Server version' : 'Original');
        return _speed == 1.0 ? mode : '$mode · ${_speedText(_speed)}';
      case _Panel.audio:
      case _Panel.subtitles:
        final chosen = _choices(p).where((c) => c.selected).toList();
        if (chosen.isEmpty) return p == _Panel.subtitles ? 'Off' : '';
        return chosen.first.label.split(' · ').take(2).join(' · ');
      case _Panel.none:
        return '';
    }
  }

  // "Ends at 21:40" (taking the playback speed into account).
  String _endsAt(Duration pos) {
    final dur = player.state.duration;
    if (dur <= Duration.zero) return '';
    final left = dur > pos ? dur - pos : Duration.zero;
    final speed = _speed <= 0 ? 1.0 : _speed;
    final t = DateTime.now().add(Duration(milliseconds: (left.inMilliseconds / speed).round()));
    return 'Ends at ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  // A round button: faint glass, white with the ring when selected.
  Widget _tvRound(bool f, double size, Widget child) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: f ? _fg : _fg.withOpacity(0.12),
          boxShadow: f ? _ringOn : const [],
        ),
        child: child,
      );

  Widget _tvTop(String title, String episodeLine) {
    final quality = _qualityLine(widget.item);
    final group = widget.sync?.group;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: 230,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xB8000000), Color(0x00000000)],
          ),
        ),
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(
            left: 48,
            top: 40,
            child: FocusLinks(
              down: () => _go(_barFocus),
              child: Focusable(
                focusNode: _backFocus,
                onSelect: () => Navigator.of(context).maybePop(),
                builder: (f) => _tvRound(f, 52, Icon(Icons.arrow_back_rounded, size: 28, color: f ? _bg : _fg)),
              ),
            ),
          ),
          Positioned(
            left: 124,
            top: 36,
            right: 720,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _display(34)),
              if (episodeLine.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(episodeLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: _body(22, color: _soft)),
              ],
            ]),
          ),
          Positioned(
            right: 56,
            top: 52,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (quality.isNotEmpty) Text(quality, style: _body(20, weight: FontWeight.w600, color: _soft)),
              StreamBuilder<Duration>(
                stream: player.stream.position,
                initialData: player.state.position,
                builder: (_, snap) {
                  final ends = _endsAt(snap.data ?? Duration.zero);
                  if (ends.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(ends, style: _body(20, color: _muted)),
                  );
                },
              ),
              // Watch together: who's in the room, each in their colour.
              if (group != null)
                ValueListenableBuilder<SyncGroup?>(
                  valueListenable: group,
                  builder: (_, g, __) {
                    final people = g?.people ?? const <String>[];
                    if (people.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('Watching together', style: _body(19, weight: FontWeight.w600, color: _soft)),
                        const SizedBox(width: 6),
                        for (final p in people)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Container(
                              width: 36,
                              height: 36,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: Color(partyColorOf(p))),
                              child: Text(p.isEmpty ? '?' : p.characters.first.toUpperCase(),
                                  style: _display(17).copyWith(color: _bg)),
                            ),
                          ),
                      ]),
                    );
                  },
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  // The timeline with the times either side: the real one on the bar, a plain one on the open
  // sheet (so you never lose your place).
  Widget _tvTimeline({required bool interactive}) => StreamBuilder<Duration>(
        stream: player.stream.position,
        initialData: player.state.position,
        builder: (_, snap) {
          final pos = snap.data ?? Duration.zero;
          final dur = player.state.duration;
          final left = dur > pos ? dur - pos : Duration.zero;
          final timeStyle = _body(22, weight: FontWeight.w600, color: _soft);
          final Widget bar;
          if (interactive) {
            bar = FocusLinks(
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
            );
          } else {
            final played = dur.inMilliseconds <= 0 ? 0.0 : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
            bar = Container(
              height: 6,
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(color: _fg.withOpacity(0.18), borderRadius: BorderRadius.circular(3)),
              child: FractionallySizedBox(
                widthFactor: played,
                child: Container(decoration: BoxDecoration(color: _fg, borderRadius: BorderRadius.circular(3))),
              ),
            );
          }
          return Row(children: [
            SizedBox(width: 94, child: Text(_clock(pos), style: timeStyle)),
            Expanded(child: bar),
            SizedBox(width: 94, child: Text('-${_clock(left)}', textAlign: TextAlign.right, style: timeStyle)),
          ]);
        },
      );

  // The bar: the same sheet as Audio / Subtitles, folded down.
  Widget _tvBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: 330,
      child: Stack(clipBehavior: Clip.none, children: [
        // A soft shade behind it, so it reads over bright scenes.
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xB8000000), Color(0x00000000)],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 250,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _sheet.withOpacity(0.58),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(36)),
            ),
            child: Stack(clipBehavior: Clip.none, children: [
              // The handle: the sheet opens further.
              Positioned(
                top: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    width: 64,
                    height: 5,
                    decoration: BoxDecoration(color: _fg.withOpacity(0.25), borderRadius: BorderRadius.circular(3)),
                  ),
                ),
              ),
              Positioned(left: 56, right: 56, top: 54 - 22, height: 44, child: _tvTimeline(interactive: true)),
              Positioned(
                left: 56,
                right: 56,
                top: 160 - 46,
                height: 92,
                child: FocusLinks(
                  up: () => _go(_barFocus),
                  down: () => true, // nothing below the buttons
                  child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        for (final p in _tvTabs) Padding(padding: const EdgeInsets.only(right: 6), child: _tvBarTab(p)),
                      ]),
                    ),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Focusable(
                        onSelect: () => _skip(-_back),
                        builder: (f) => _tvRound(f, 64, Text('−10', style: _body(18, weight: FontWeight.w800, color: f ? _bg : _fg))),
                      ),
                      const SizedBox(width: 26),
                      StreamBuilder<bool>(
                        stream: player.stream.playing,
                        initialData: player.state.playing,
                        builder: (_, snap) => Focusable(
                          focusNode: _playFocus,
                          onSelect: _togglePlay,
                          builder: (f) => _tvRound(
                            f,
                            84,
                            Icon(snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                size: 44, color: f ? _bg : _fg),
                          ),
                        ),
                      ),
                      const SizedBox(width: 26),
                      Focusable(
                        onSelect: () => _skip(_forward),
                        builder: (f) => _tvRound(f, 64, Text('+30', style: _body(18, weight: FontWeight.w800, color: f ? _bg : _fg))),
                      ),
                    ]),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  // A tab on the bar: its name, and what's in use underneath.
  Widget _tvBarTab(_Panel p) {
    final value = _tabValue(p);
    return Focusable(
      onSelect: () {
        if (p == _Panel.info) {
          _toggleInfo();
        } else {
          _openPanel(p);
        }
      },
      builder: (f) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 76,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: f ? _fg : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          boxShadow: f ? _ringOn : const [],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_tabName(p), style: _body(23, weight: FontWeight.w700, color: f ? _bg : _fg)),
            if (value.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(value,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: _body(18, color: f ? _cardInk : _muted)),
              ),
          ],
        ),
      ),
    );
  }

  // The open sheet: Audio, Subtitles, Playback or Info.
  Widget _tvSheet() {
    final p = _panel;
    final info = p == _Panel.info;
    final choices = info ? const <({String label, String note, bool selected, VoidCallback onSelect})>[] : _choices();
    final speed = p == _Panel.playback && _room == null;
    final height = (info || p == _Panel.subtitles || speed) ? 600.0 : 500.0;
    var focusIdx = choices.indexWhere((c) => c.selected);
    if (focusIdx < 0) focusIdx = 0;
    return Positioned.fill(
      child: Stack(clipBehavior: Clip.none, children: [
        // Dims the video; clicking it closes the sheet.
        Positioned.fill(
          child: GestureDetector(onTap: _closePanel, child: const ColoredBox(color: Color(0x40000000))),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: height,
          child: GestureDetector(
            onTap: () {}, // empty parts of the sheet do nothing
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _sheet.withOpacity(0.69),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(36)),
              ),
              // Its own focus scope: arrows stay inside the sheet while it's open.
              child: FocusScope(
                child: Stack(clipBehavior: Clip.none, children: [
                  Positioned(left: 56, right: 56, top: 54 - 22, height: 44, child: _tvTimeline(interactive: false)),
                  Positioned(
                    left: 56,
                    top: 110,
                    height: 56,
                    // Down goes to what's in use, not just the card under the tab.
                    child: FocusLinks(
                      down: () => _panel != _Panel.info && focusOn(_panelFirst),
                      child: Row(children: [
                        for (var i = 0; i < _tvTabs.length; i++)
                          Padding(padding: const EdgeInsets.only(right: 10), child: _tvSheetTab(i)),
                      ]),
                    ),
                  ),
                  if (info)
                    ..._tvInfo()
                  else ...[
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 200 - 12,
                      height: 150 + 24,
                      child: choices.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.fromLTRB(56, 52, 56, 0),
                              child: Text(
                                  p == _Panel.audio ? 'This video has no sound tracks.' : 'Nothing to choose here.',
                                  style: _body(24, color: _muted)),
                            )
                          : _tvCardRow(choices, focusIdx),
                    ),
                    if (p == _Panel.playback)
                      Positioned(
                        left: 56,
                        top: 200 + 150 + 30,
                        child: Text(
                          _server
                              ? 'Now playing the version your server converts on the NAS.'
                              : 'Now playing the original file, straight from the NAS.',
                          style: _body(20, color: _muted),
                        ),
                      ),
                    if (p == _Panel.subtitles)
                      Positioned(
                        left: 56,
                        right: 56,
                        top: 200 + 150 + 56,
                        child: _tvPillGroups([
                          (
                            'Size',
                            [
                              for (final (label, v) in const [('Small', 0.8), ('Medium', 1.0), ('Large', 1.3)])
                                (label, (_subScale - v).abs() < 0.05, () => _changeSubStyle(scale: v)),
                            ]
                          ),
                          (
                            'Position',
                            [
                              ('Bottom', _subPos >= 99, () => _changeSubStyle(pos: 100)),
                              ('Higher', _subPos < 99, () => _changeSubStyle(pos: 88)),
                            ]
                          ),
                          (
                            'Background',
                            [
                              ('Off', !_subBox, () => _changeSubStyle(box: false)),
                              ('Box', _subBox, () => _changeSubStyle(box: true)),
                            ]
                          ),
                        ]),
                      ),
                    if (speed)
                      Positioned(
                        left: 56,
                        right: 56,
                        top: 200 + 150 + 84,
                        child: _tvPillGroups([
                          (
                            'Speed',
                            [
                              for (final s in const [0.75, 1.0, 1.25, 1.5, 2.0])
                                (_speedText(s), _speed == s, () => _setSpeed(s)),
                            ]
                          ),
                        ]),
                      ),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  // The row of cards. The controller and keyboard scroll it by moving onto a card; with a
  // mouse, the wheel or a touchpad scrolls it sideways, and arrows at an edge (where there are
  // more cards that way) scroll it by a few cards. The row fades at those edges.
  final _cardsScroll = ScrollController();
  final _cardsEdges = ValueNotifier<(bool, bool)>((false, false)); // more to the left, to the right

  void _cardsMoved(ScrollMetrics m) {
    final edges = (m.pixels > m.minScrollExtent + 1, m.pixels < m.maxScrollExtent - 1);
    if (_cardsEdges.value != edges) _cardsEdges.value = edges;
  }

  void _scrollCards(double by, {bool animate = true}) {
    if (!_cardsScroll.hasClients) return;
    final pos = _cardsScroll.position;
    final to = (pos.pixels + by).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (animate) {
      _cardsScroll.animateTo(to, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
    } else {
      _cardsScroll.jumpTo(to);
    }
  }

  Widget _tvCardRow(List<({String label, String note, bool selected, VoidCallback onSelect})> choices, int focusIdx) {
    final list = ListView.separated(
      controller: _cardsScroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 12),
      clipBehavior: Clip.none,
      cacheExtent: 4000, // every card exists, so the chosen one can be selected
      itemCount: choices.length,
      separatorBuilder: (_, __) => const SizedBox(width: 24),
      itemBuilder: (_, i) => _tvCard(choices[i], i == focusIdx ? _panelFirst : null),
    );
    Widget arrow(bool left) => Positioned(
          left: left ? 16 : null,
          right: left ? null : 16,
          top: 0,
          bottom: 0,
          child: Center(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _scrollCards(left ? -648 : 648), // about two cards
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xF21A1E25),
                    border: Border.all(color: _fg.withOpacity(0.14)),
                    boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 6))],
                  ),
                  child: Icon(left ? Icons.chevron_left_rounded : Icons.chevron_right_rounded, size: 34, color: _fg),
                ),
              ),
            ),
          ),
        );
    // Up goes back to this sheet's own tab (moving onto another tab would switch to it).
    return FocusLinks(
      up: () => focusOn(_tabFocus[_tvTabs.indexOf(_panel)]),
      child: Listener(
        // A mouse wheel only scrolls up and down; here that moves the row sideways.
        onPointerSignal: (e) {
          if (e is! PointerScrollEvent) return;
          final d = e.scrollDelta.dy;
          if (d == 0 || e.scrollDelta.dx != 0) return; // sideways swipes scroll the row by themselves
          GestureBinding.instance.pointerSignalResolver.register(e, (_) => _scrollCards(d * 2, animate: false));
        },
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) {
            _cardsMoved(n.metrics);
            return false;
          },
          child: NotificationListener<ScrollUpdateNotification>(
            onNotification: (n) {
              _cardsMoved(n.metrics);
              return false;
            },
            child: ValueListenableBuilder<(bool, bool)>(
              valueListenable: _cardsEdges,
              child: list,
              builder: (_, edges, list) {
                final (moreLeft, moreRight) = edges;
                return Stack(clipBehavior: Clip.none, children: [
                  Positioned.fill(
                    child: ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (r) => LinearGradient(
                        colors: [
                          moreLeft ? const Color(0x00000000) : const Color(0xFF000000),
                          const Color(0xFF000000),
                          const Color(0xFF000000),
                          moreRight ? const Color(0x00000000) : const Color(0xFF000000),
                        ],
                        stops: const [0, 0.06, 0.94, 1],
                      ).createShader(r),
                      child: list,
                    ),
                  ),
                  if (moreLeft) arrow(true),
                  if (moreRight) arrow(false),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }

  // A tab along the top of the open sheet. Moving onto it with the controller switches to it.
  Widget _tvSheetTab(int i) {
    final p = _tvTabs[i];
    final on = _panel == p;
    return Focusable(
      key: ValueKey('sheet tab $i'),
      focusNode: _tabFocus[i],
      onFocus: (viaMouse) {
        if (!viaMouse) _switchTab(p);
      },
      onSelect: () => _switchTab(p),
      builder: (f) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: f ? _fg : (on ? _fg.withOpacity(0.16) : Colors.transparent),
          borderRadius: BorderRadius.circular(28),
          boxShadow: f ? _ringOn : const [],
        ),
        child: Text(_tabName(p),
            style: _body(24, weight: on || f ? FontWeight.w700 : FontWeight.w600, color: f ? _bg : (on ? _fg : _soft))),
      ),
    );
  }

  void _switchTab(_Panel p) {
    if (_panel == p || !mounted) return;
    if (_cardsScroll.hasClients) _cardsScroll.jumpTo(0);
    setState(() => _panel = p);
    _statsTimer?.cancel();
    if (p == _Panel.info) {
      _readStats();
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _readStats());
    }
  }

  // A choice: a big card. The first part of its name large, the rest along the bottom.
  // Choosing a track or a mode uses it and closes the sheet.
  Widget _tvCard(({String label, String note, bool selected, VoidCallback onSelect}) c, FocusNode? node) {
    final parts = c.label.split(' · ');
    final rest = [...parts.skip(1), if (c.note.isNotEmpty) c.note].join(' · ');
    void choose() {
      c.onSelect();
      _closePanel();
    }

    return Focusable(
      focusNode: node,
      onSelect: choose,
      builder: (f) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 300,
        height: 150,
        padding: const EdgeInsets.fromLTRB(24, 22, 20, 20),
        decoration: BoxDecoration(
          color: f ? _fg : _fg.withOpacity(c.selected ? 0.18 : 0.08),
          borderRadius: BorderRadius.circular(26),
          boxShadow: f ? _ringOn : const [],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(parts.first,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: _body(26, weight: f || c.selected ? FontWeight.w700 : FontWeight.w600, color: f ? _bg : _fg)),
            ),
            if (c.selected) Icon(Icons.check_rounded, size: 30, color: f ? _bg : _fg),
          ]),
          const Spacer(),
          if (rest.isNotEmpty)
            Text(rest, maxLines: 1, overflow: TextOverflow.ellipsis, style: _body(20, color: f ? _cardInk : _muted)),
        ]),
      ),
    );
  }

  // Small choices in named groups ("Size: Small Medium Large"). They stay open, so you can see
  // the change on the picture.
  Widget _tvPillGroups(List<(String, List<(String, bool, VoidCallback)>)> groups) => Wrap(
        runSpacing: 18,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (name, pills) in groups)
            Padding(
              padding: const EdgeInsets.only(right: 30),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(name, style: _body(21, color: _muted)),
                const SizedBox(width: 16),
                for (final (label, on, act) in pills)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Focusable(
                      onSelect: act,
                      builder: (f) => AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: f ? _fg : _fg.withOpacity(on ? 0.23 : 0.08),
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: f ? _ringOn : const [],
                        ),
                        child: Text(label,
                            style: _body(21, weight: f || on ? FontWeight.w700 : FontWeight.w600, color: f ? _bg : _fg)),
                      ),
                    ),
                  ),
              ]),
            ),
        ],
      );

  // Info: the episode on the left (picture, title, line, summary), the details on the right.
  List<(String, String)> _details = const [];

  List<Widget> _tvInfo() {
    final item = widget.item;
    final isEpisode = item['Type'] == 'Episode';
    final mins = runtimeMinutes(item);
    final line = [
      if (isEpisode && item['ParentIndexNumber'] != null) 'S${item['ParentIndexNumber']}',
      if (isEpisode && item['IndexNumber'] != null) 'E${item['IndexNumber']}',
      if (item['ProductionYear'] != null) '${item['ProductionYear']}',
      if (mins > 0) '$mins min',
    ].join(' · ');
    final pic = sizeBucket(tvPx(300));
    return [
      Positioned(
        left: 56,
        top: 206,
        width: 300,
        height: 169,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: netImage(widget.jf.thumbFor(item, maxWidth: pic),
              cacheWidth: pic,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => ColoredBox(color: _fg.withOpacity(0.13))),
        ),
      ),
      Positioned(
        left: 384,
        top: 200,
        width: 500,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text((item['Name'] ?? '').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: _display(30)),
          const SizedBox(height: 8),
          StreamBuilder<Duration>(
            stream: player.stream.position,
            initialData: player.state.position,
            builder: (_, snap) => Text(
              [line, _endsAt(snap.data ?? Duration.zero)].where((x) => x.isNotEmpty).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _body(21, color: _soft),
            ),
          ),
          const SizedBox(height: 14),
          Text((item['Overview'] ?? '').toString(),
              maxLines: 4, overflow: TextOverflow.ellipsis, style: _body(21, color: _muted).copyWith(height: 1.45)),
        ]),
      ),
      Positioned(
        left: 940,
        right: 56,
        top: 196,
        child: Column(children: [
          for (final (name, value) in _details)
            Container(
              height: 46,
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _fg.withOpacity(0.08)))),
              child: Row(children: [
                SizedBox(width: 190, child: Text(name, style: _body(21, color: _muted))),
                Expanded(
                  child: Text(value.isEmpty ? '—' : value,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: _body(21, weight: FontWeight.w600)),
                ),
              ]),
            ),
          if (_details.isEmpty)
            Align(alignment: Alignment.centerLeft, child: Text('Reading…', style: _body(21, color: _muted))),
        ]),
      ),
    ];
  }

  // ---------- PC and TV: the loading screen ----------
  //
  // Like starting a game on PS5: the show's artwork full screen with its logo, the episode
  // line, chips for how it plays, a running line and where it starts. It fades away once the
  // video is on screen.
  bool _loaded = false; // the video has started
  bool _loadingGone = false; // the loading screen has faded out

  void _checkLoaded() {
    if (_loaded || !mounted) return;
    if (player.state.duration > Duration.zero && !player.state.buffering) setState(() => _loaded = true);
  }

  static final _loadingShades = [
    (
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [_bg.withOpacity(0.85), _bg.withOpacity(0.35), _bg.withOpacity(0.10)],
      stops: const [0.0, 0.55, 1.0]
    ),
    (
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [_bg.withOpacity(0.85), _bg.withOpacity(0)],
      stops: const [0.0, 0.5]
    ),
  ];

  Widget _tvLoading() {
    final item = widget.item;
    final logo = widget.jf.logoFor(item);
    final title = Text(titleOf(item), style: _display(84), maxLines: 1, overflow: TextOverflow.ellipsis);
    final line = item['Type'] == 'Episode' ? episodeLine(item) : (item['ProductionYear']?.toString() ?? '');
    final chips = _qualityLine(item).split(' · ').where((x) => x.trim().isNotEmpty).toList();
    final art = sizeBucket(tvPx(1920)).clamp(1280, 2560);
    final ticks = _resumeTicks;
    final status = ticks <= 0 ? 'Starting' : 'Resumes at ${_clock(Duration(microseconds: ticks ~/ 10))}';
    final now = DateTime.now();
    final clock = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: _loaded,
        child: AnimatedOpacity(
          opacity: _loaded ? 0 : 1,
          duration: const Duration(milliseconds: 350),
          onEnd: () {
            if (_loaded && mounted) setState(() => _loadingGone = true);
          },
          child: ColoredBox(
            color: _bg,
            child: TvCanvas(
              child: Stack(children: [
                Positioned.fill(
                  child: netImage(widget.jf.backdropFor(item, maxWidth: art),
                      cacheWidth: art, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                ),
                for (final g in _loadingShades)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(begin: g.begin, end: g.end, colors: g.colors, stops: g.stops),
                      ),
                    ),
                  ),
                Positioned(right: 56, top: 48, child: Text(clock, style: _body(26, weight: FontWeight.w600, color: _soft))),
                Positioned(
                  left: 120,
                  top: 430,
                  width: 760,
                  height: 150,
                  child: logo == null
                      ? Align(alignment: Alignment.bottomLeft, child: title)
                      : LogoImage(
                          url: logo,
                          height: 150,
                          cacheHeight: tvPx(150),
                          alignment: Alignment.bottomLeft,
                          fallback: Align(alignment: Alignment.bottomLeft, child: title)),
                ),
                if (line.isNotEmpty)
                  Positioned(
                    left: 120,
                    top: 604,
                    right: 120,
                    child: Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: _body(28, color: _soft)),
                  ),
                Positioned(
                  left: 120,
                  top: 660,
                  child: Row(children: [
                    for (final chip in chips)
                      Container(
                        height: 40,
                        margin: const EdgeInsets.only(right: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: _fg.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                        child: Text(chip, style: _body(19, weight: FontWeight.w600)),
                      ),
                  ]),
                ),
                Positioned(
                  left: 120,
                  top: 742,
                  width: 420,
                  height: 4,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(backgroundColor: _fg.withOpacity(0.16), color: _fg),
                  ),
                ),
                Positioned(left: 120, top: 764, child: Text(status, style: _body(21, color: _muted))),
                // Cancel, bottom right (Back / Esc / Circle does the same).
                Positioned(
                  right: 56,
                  bottom: 40,
                  child: Focusable(
                    onSelect: () => Navigator.of(context).maybePop(),
                    builder: (f) => AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      height: 52,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: f ? _fg : _fg.withOpacity(0.10),
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: Text('Cancel', style: _body(22, weight: FontWeight.w600, color: f ? _bg : _soft)),
                    ),
                  ),
                ),
              ]),
            ),
          ),
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
      if (pos != null) _subPos = pos.clamp(20, 100).toInt();
      if (box != null) _subBox = box;
    });
    _applySubStyle(save: true);
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
  double? _hoverX; // where the pointer is over the bar, for the time pill above it
  double? _dragFraction;

  static String _time(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';
  }

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
        onExit: (_) => setState(() {
          _hover = false;
          _hoverX = null;
        }),
        onHover: (e) => setState(() => _hoverX = e.localPosition.dx),
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
                  height: active ? 10 : 6,
                  decoration: BoxDecoration(
                    color: _fg.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: buffered,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    height: active ? 10 : 6,
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
                    height: active ? 10 : 6,
                    decoration: BoxDecoration(color: _fg, borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                // Hovering: a little pill with the time under the pointer.
                if (_hoverX != null && widget.duration > Duration.zero && _dragFraction == null)
                  Positioned(
                    left: (_hoverX!.clamp(0.0, box.maxWidth) - 50).clamp(-20.0, box.maxWidth - 80),
                    top: -44,
                    child: IgnorePointer(
                      child: Container(
                        width: 100,
                        height: 38,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: const Color(0xFF1A1E25), borderRadius: BorderRadius.circular(19)),
                        child: Text(_time(_at(toFraction(_hoverX!))), style: _body(20, weight: FontWeight.w700)),
                      ),
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

// ---------- Phones: the timeline you drag with a finger ----------
//
// Tap anywhere on it to jump there, or drag: it grows thicker, a bubble above your finger shows
// the time and chapter, and you feel a light tap at each chapter mark. Seeks when you let go.

class _PhoneScrubber extends StatefulWidget {
  const _PhoneScrubber({
    required this.position,
    required this.duration,
    required this.chapters,
    required this.onSeek,
    this.onDrag,
  });

  final Duration position;
  final Duration duration;
  final List<({Duration at, String name})> chapters;
  final void Function(Duration to) onSeek;
  final VoidCallback? onDrag;

  @override
  State<_PhoneScrubber> createState() => _PhoneScrubberState();
}

class _PhoneScrubberState extends State<_PhoneScrubber> {
  double? _drag; // 0..1 while the finger is down
  int _chapter = -1;

  double get _played {
    final total = widget.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (widget.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Duration _at(double f) => Duration(milliseconds: (widget.duration.inMilliseconds * f.clamp(0.0, 1.0)).round());

  int _chapterAt(Duration d) {
    var found = -1;
    for (var i = 0; i < widget.chapters.length; i++) {
      if (widget.chapters[i].at <= d) found = i;
    }
    return found;
  }

  void _move(double f) {
    final c = _chapterAt(_at(f));
    if (_drag != null && c != _chapter) HapticFeedback.selectionClick();
    _chapter = c;
    setState(() => _drag = f);
    widget.onDrag?.call();
  }

  static String _clock(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final dragging = _drag != null;
    final f = _drag ?? _played;
    final total = widget.duration.inMilliseconds;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      double toF(double dx) => (dx / w).clamp(0.0, 1.0);
      final chapter = dragging ? _chapterAt(_at(f)) : -1;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => widget.onSeek(_at(toF(d.localPosition.dx))),
        onHorizontalDragStart: (d) {
          HapticFeedback.selectionClick();
          _chapter = _chapterAt(_at(toF(d.localPosition.dx)));
          _move(toF(d.localPosition.dx));
        },
        onHorizontalDragUpdate: (d) => _move(toF(d.localPosition.dx)),
        onHorizontalDragEnd: (_) {
          final to = _drag;
          setState(() => _drag = null);
          if (to != null) widget.onSeek(_at(to));
        },
        child: SizedBox(
          height: 44,
          child: Stack(clipBehavior: Clip.none, alignment: Alignment.centerLeft, children: [
            // Track, played part and chapter marks.
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: dragging ? 8 : 4,
              decoration: BoxDecoration(color: const Color(0x40F4F5F7), borderRadius: BorderRadius.circular(4)),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: w * f,
              height: dragging ? 8 : 4,
              decoration: BoxDecoration(color: kFg, borderRadius: BorderRadius.circular(4)),
            ),
            if (total > 0)
              for (final c in widget.chapters)
                if (c.at > Duration.zero)
                  Positioned(
                    left: w * (c.at.inMilliseconds / total).clamp(0.0, 1.0) - 1,
                    child: Container(width: 2, height: dragging ? 8 : 4, color: const Color(0x9906080B)),
                  ),
            // The thumb.
            Positioned(
              left: w * f - (dragging ? 14 : 7),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: dragging ? 28 : 14,
                height: dragging ? 28 : 14,
                decoration: BoxDecoration(
                  color: kFg,
                  shape: BoxShape.circle,
                  boxShadow: dragging ? const [BoxShadow(color: Color(0x33F4F5F7), spreadRadius: 8)] : const [],
                ),
              ),
            ),
            // Time (and chapter) above the finger while dragging.
            if (dragging)
              Positioned(
                left: (w * f - 80).clamp(-40.0, w - 120).toDouble(),
                bottom: 40,
                child: Container(
                  width: 160,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(color: const Color(0xF2151920), borderRadius: BorderRadius.circular(12)),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_clock(_at(f)), style: phoneText(18, weight: FontWeight.w700)),
                    if (chapter >= 0 && widget.chapters[chapter].name.isNotEmpty)
                      Text(widget.chapters[chapter].name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: phoneText(12, color: kSoft)),
                  ]),
                ),
              ),
          ]),
        ),
      );
    });
  }
}
