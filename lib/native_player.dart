// Playback on the PC in a real mpv window (the way Jellyfin's own PC app works).
//
// Frame's in-app player draws the video twice (mpv, then Flutter on top), which is heavy on
// small PCs and can't output real HDR or handle Dolby Vision natively. Here mpv plays in its
// own full-screen window with its newer drawing engine (gpu-next): the video is drawn once,
// straight to the screen. Frame's controls are drawn inside mpv by assets/mpv/frame_ui.lua in
// the same design, and Frame stays in charge in the background: it starts mpv, sends it the
// controller's buttons, picks the original file or the server's version, and tells Jellyfin
// what you watched.
//
// If no mpv is found (bundled with Frame, or installed), the in-app player is used instead.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'gamepad.dart' show padActive, padStyle, PadStyle, PadHint, PadButton, PadHints, GamepadInput;
import 'main.dart' show Jellyfin;
import 'player.dart' show PlayerScreen;
import 'syncplay.dart' show SyncPlay, RoomLink;
import 'perf.dart' show perfLog;
import 'tracks.dart';
import 'ui.dart';

// ---------- Which player to use ----------

String? _mpvPath;
double _mpvVersion = 0; // e.g. 0.41; 0 when unknown

/// Where Frame keeps its own copy of mpv (downloaded once, used by every launch).
String get _home => Platform.environment['HOME'] ?? '.';
String get _ownMpvDir => '$_home/.local/share/frame/mpv';
String get _ownMpv => '$_ownMpvDir/mpv.AppImage';

/// mpv 0.40 and newer can hand HDR and Dolby Vision to KDE as real HDR.
bool get _mpvHasHdr => _mpvVersion >= 0.40;

/// Frame's own mpv AppImage must never stop to ask about updates.
const _mpvEnv = {'DISABLE_AUTO_UPDATES': '1'};

Future<double> _versionOf(String path) async {
  try {
    final r = await Process.run(path, ['--version'], environment: _mpvEnv)
        .timeout(const Duration(seconds: 90)); // the first run of an AppImage can be slow
    final m = RegExp(r'mpv v?(\d+)\.(\d+)').firstMatch(r.stdout.toString());
    if (m != null) return int.parse(m.group(1)!) + int.parse(m.group(2)!) / 100;
    final why = '${r.stdout}\n${r.stderr}'.trim();
    debugPrint('Player: $path --version gave (code ${r.exitCode}): '
        '${why.length > 400 ? why.substring(why.length - 400) : why}');
  } catch (e) {
    debugPrint('Player: could not run $path: $e');
  }
  return 0;
}

/// mpv's version, remembered per file (path, size, date): asking a self-contained AppImage for
/// its version means starting it, which takes a second or two, on every launch otherwise.
Future<double> _cachedVersionOf(String path) async {
  String? key;
  try {
    final stat = await File(path).stat();
    key = 'mpvVersion|$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    final prefs = await SharedPreferences.getInstance();
    final known = prefs.getDouble(key);
    if (known != null && known > 0) return known;
    final v = await _versionOf(path);
    if (v > 0) {
      // Forget versions of older files, then remember this one.
      for (final k in prefs.getKeys().where((k) => k.startsWith('mpvVersion|')).toList()) {
        await prefs.remove(k);
      }
      await prefs.setDouble(key, v);
    }
    return v;
  } catch (_) {
    if (key == null) return 0;
    return await _versionOf(path);
  }
}

/// Looks for mpv once at startup: Frame's own copy first, then one bundled next to Frame,
/// then the system's. If the best one is too old for HDR, Frame fetches a current mpv in the
/// background and switches to it as soon as it's ready (no install, nothing to set up).
Future<void> findMpv() async {
  if (!Platform.isLinux) return;
  // A finished download whose check didn't complete last time: check it again now.
  final leftover = File('$_ownMpv.part');
  if (!await File(_ownMpv).exists() && await leftover.exists() && await _versionOf(leftover.path) >= 0.40) {
    await leftover.rename(_ownMpv);
  }
  final dir = File(Platform.resolvedExecutable).parent.path;
  for (final p in [_ownMpv, '$dir/mpv/mpv', '$dir/mpv/mpv.AppImage', '$dir/mpv.AppImage']) {
    if (await File(p).exists()) {
      _mpvPath = p;
      break;
    }
  }
  if (_mpvPath == null) {
    try {
      final r = await Process.run('which', ['mpv']);
      final p = r.stdout.toString().trim();
      if (r.exitCode == 0 && p.isNotEmpty) _mpvPath = p;
    } catch (_) {}
  }
  if (_mpvPath != null) _mpvVersion = await _cachedVersionOf(_mpvPath!);
  debugPrint(_mpvPath == null
      ? 'Player: no mpv found, using the in-app player for now'
      : 'Player: videos play in mpv ${_mpvVersion.toStringAsFixed(2)} ($_mpvPath)'
          '${_mpvHasHdr ? ', HDR on' : ''}');
  if (!_mpvHasHdr) unawaited(_fetchMpv());
}

/// Downloads a current mpv (a self-contained AppImage that runs on any Linux) into Frame's
/// folder. Kept between launches; only fetched again if it goes missing.
Future<void> _fetchMpv() async {
  if (Platform.version.contains('arm') || !Platform.isLinux) return;
  final client = HttpClient()..userAgent = 'Frame';
  try {
    debugPrint('Player: getting a current mpv for HDR and Dolby Vision...');
    final req = await client.getUrl(Uri.parse('https://api.github.com/repos/pkgforge-dev/mpv-AppImage/releases/latest'));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close();
    if (res.statusCode != 200) throw 'release list answered ${res.statusCode}';
    final release = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    final assets = (release['assets'] as List).cast<Map<String, dynamic>>();
    final asset = assets.firstWhere(
      (a) {
        final n = (a['name'] as String).toLowerCase();
        return n.contains('x86_64') && n.endsWith('.appimage');
      },
      orElse: () => throw 'no x86_64 AppImage in ${release['tag_name']}',
    );
    await Directory(_ownMpvDir).create(recursive: true);
    final part = File('$_ownMpv.part');
    final dl = await (await client.getUrl(Uri.parse(asset['browser_download_url'] as String))).close();
    if (dl.statusCode != 200) throw 'download answered ${dl.statusCode}';
    await dl.pipe(part.openWrite());
    await Process.run('chmod', ['+x', part.path]);
    final version = await _versionOf(part.path);
    if (version < 0.40) throw 'the downloaded mpv did not run (version $version)';
    await part.rename(_ownMpv);
    _mpvPath = _ownMpv;
    _mpvVersion = version;
    debugPrint('Player: mpv ${version.toStringAsFixed(2)} ready, HDR and Dolby Vision on from the next video');
  } catch (e) {
    debugPrint('Player: could not get a current mpv ($e); staying on the one found');
  } finally {
    client.close();
  }
}

/// The screen that plays a video: the mpv window on the PC when mpv is available, otherwise
/// the in-app player.
/// With [sync], the video plays in a Watch together room: play, pause and seek go through the
/// room, so everyone stays together.
Widget playerScreen(Jellyfin jf, dynamic item, {SyncPlay? sync, String? playlistItemId, int? startTicks}) =>
    _mpvPath != null
        ? NativePlayerScreen(jf: jf, item: item, sync: sync, playlistItemId: playlistItemId, startTicks: startTicks)
        : PlayerScreen(jf: jf, item: item, sync: sync, playlistItemId: playlistItemId, startTicks: startTicks);

// ---------- Talking to mpv ----------

final _statusLine = RegExp(r'^\s*(\((Paused|Buffering)\)\s*)?(AV|A|V):\s');

class _Mpv {
  Process? _process;
  Socket? _socket;
  String? _socketPath;
  int _next = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;
  Future<int> get exitCode => _process?.exitCode ?? Future.value(-1);

  Future<void> start(String mpv, List<String> args) async {
    final socketPath = '${Directory.systemTemp.path}/frame-mpv-$pid-${DateTime.now().millisecondsSinceEpoch}.sock';
    _socketPath = socketPath;
    _process = await Process.start(mpv, [...args, '--input-ipc-server=$socketPath'], environment: _mpvEnv);
    var exited = false;
    _process!.exitCode.then((_) {
      exited = true;
      // Tidy up mpv's control socket file.
      File(socketPath).delete().then((_) {}, onError: (_) {});
    });
    for (final stream in [_process!.stdout, _process!.stderr]) {
      stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        // Skip mpv's once-per-frame status line; keep everything else.
        if (line.trim().isEmpty || _statusLine.hasMatch(line)) return;
        debugPrint('mpv: $line');
      });
    }
    // mpv opens its control socket a moment after starting.
    for (var i = 0; i < 100 && _socket == null && !exited; i++) {
      try {
        _socket = await Socket.connect(InternetAddress(socketPath, type: InternetAddressType.unix), 0);
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    if (_socket == null) throw exited ? 'mpv closed while starting.' : 'mpv did not start.';
    _socket!.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine,
        onError: (_) {}, onDone: () => _events.add({'event': 'closed'}));
  }

  void _onLine(String line) {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = m['request_id'];
    if (id is int && _pending.containsKey(id)) {
      final c = _pending.remove(id)!;
      if (m['error'] == 'success') {
        c.complete(m['data']);
      } else {
        c.completeError(m['error'] ?? 'error');
      }
    } else if (m['event'] != null) {
      _events.add(m);
    }
  }

  Future<dynamic> command(List<dynamic> cmd) {
    final socket = _socket;
    if (socket == null) return Future.error('mpv is not running');
    final id = _next++;
    final c = Completer<dynamic>();
    _pending[id] = c;
    try {
      socket.write('${jsonEncode({'command': cmd, 'request_id': id})}\n');
    } catch (e) {
      _pending.remove(id);
      return Future.error(e);
    }
    return c.future.timeout(const Duration(seconds: 5), onTimeout: () {
      _pending.remove(id);
      throw 'mpv did not answer';
    });
  }

  Future<void> set(String name, dynamic value) async {
    try {
      await command(['set_property', name, value]);
    } catch (e) {
      debugPrint('mpv: could not set $name: $e');
    }
  }

  /// Like [set] but reports whether mpv accepted it, without logging.
  Future<bool> trySet(String name, dynamic value) async {
    try {
      await command(['set_property', name, value]);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<dynamic> get(String name) async {
    try {
      return await command(['get_property', name]);
    } catch (_) {
      return null;
    }
  }

  void observe(int id, String name) => command(['observe_property', id, name]).then((_) {}, onError: (_) {});

  Future<void> close() async {
    try {
      await command(['quit']);
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));
    _process?.kill();
    try {
      await _socket?.close();
    } catch (_) {}
    final path = _socketPath;
    if (path != null) File(path).delete().then((_) {}, onError: (_) {});
  }
}

// ---------- The screen ----------

class NativePlayerScreen extends StatefulWidget {
  const NativePlayerScreen({super.key, required this.jf, required this.item, this.sync, this.playlistItemId, this.startTicks});
  final Jellyfin jf;
  final dynamic item;
  final SyncPlay? sync; // a Watch together room, or null
  final String? playlistItemId; // the room's id for this video
  final int? startTicks; // where the room starts (instead of your resume point)

  @override
  State<NativePlayerScreen> createState() => _NativePlayerScreenState();
}

class _NativePlayerScreenState extends State<NativePlayerScreen> {
  final _mpv = _Mpv();
  final _focus = FocusNode();
  StreamSubscription? _eventsSub;
  Timer? _syncTimer;
  Timer? _adaptTimer;

  String get _id => widget.item['Id'];
  dynamic _fresh; // the latest details from the server, when they arrived in time
  dynamic get _item => _fresh ?? widget.item;

  double _pos = 0; // seconds
  // One app: the player takes Frame's place on screen (same size, or full screen) and Frame
  // steps aside until you come back, so there's only ever one Frame window.
  bool _handedOff = false;
  bool _mpvFull = false;
  bool _paused = false;
  bool _ended = false;
  String? _error;

  // Original file or the server's version (same choices and steps as the in-app player).
  String _mode = 'auto';
  int _level = 0;
  int _levelAtStart = 0;
  bool _eased = false;
  bool _server = false;
  String? _session;
  bool _switching = false;
  int? _serverAudio;
  int? _serverSub; // image subtitle drawn in by the server
  int? _serverTextSub;
  final Map<int, String> _serverSubUrls = {};
  int _lastDrops = -1;
  int _cleanSeconds = 0;
  DateTime _lastSeek = DateTime(0);
  int _lastRequest = 0;

  // Subtitle style, shared with the in-app player.
  double _subScale = 1.0;
  int _subPos = 100;
  bool _subBox = false;
  bool _hasBorderStyle = true;

  int get _ticksNow => (_pos * 10000000).round();
  int get _resumeTicks => widget.startTicks ?? (_item['UserData']?['PlaybackPositionTicks'] ?? 0) as int;

  bool get _isDolbyVisionOnly {
    final video = _streams('Video').cast<dynamic>().firstWhere((_) => true, orElse: () => null);
    return video != null && video['VideoRangeType'] == 'DOVI';
  }

  // Learned separately from the in-app player (which is much heavier), and per mpv version,
  // so a better mpv starts again at full quality and only eases off if it really has to.
  String get _levelKey =>
      'mpvStep-${_mpvVersion.toStringAsFixed(2)}-${_isDolbyVisionOnly ? 'dv' : 'other'}';
  // With mpv's own engine, Dolby Vision needs no extra conversion step, so both kinds go
  // full quality -> simpler scaling -> the server's version.
  int get _serverStep => 2;
  int get _maxLevel => _mode == 'original' ? 1 : 2;

  List<dynamic> _streams(String type) =>
      ((_item['MediaStreams'] as List?) ?? []).where((s) => s['Type'] == type).toList();

  String _label(dynamic s) {
    final display = (s['DisplayTitle'] ?? '').toString();
    if (display.isNotEmpty) return display.split(' - ').where((p) => p.trim() != 'Default').join(' · ');
    return (s['Language'] ?? 'Track ${s['Index']}').toString();
  }

  @override
  void initState() {
    super.initState();
    // While mpv is open, full screen (touchpad / Create / F11) applies to the mpv window.
    fullScreenOverride = () => _mpv.command(['cycle', 'fullscreen']).then((_) {}, onError: (_) {});
    padActive.addListener(_sendPad);
    padStyle.addListener(_sendPad);
    GamepadInput.keyOverride = _forward;
    _start();
  }

  @override
  void dispose() {
    _takeBack();
    fullScreenOverride = null;
    if (GamepadInput.keyOverride == _forward) GamepadInput.keyOverride = null;
    padActive.removeListener(_sendPad);
    padStyle.removeListener(_sendPad);
    _eventsSub?.cancel();
    _syncTimer?.cancel();
    _adaptTimer?.cancel();
    _focus.dispose();
    if (!_ended) {
      widget.jf.reportStopped(_id, _ticksNow, session: _session);
      _mpv.close();
    }
    _saveLearnedLevel();
    _endTogether();
    super.dispose();
  }

  // ---------- Starting ----------

  Future<String> _scriptPath() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/mpv');
    await dir.create(recursive: true);
    final file = File('${dir.path}/frame_ui.lua');
    await file.writeAsString(await rootBundle.loadString('assets/mpv/frame_ui.lua'));
    return file.path;
  }

  // mpv draws the controls with the system's fonts: make Frame's two fonts available to it.
  Future<void> _installFonts() async {
    try {
      final home = Platform.environment['HOME'];
      if (home == null) return;
      final dir = Directory('$home/.local/share/fonts/frame');
      await dir.create(recursive: true);
      for (final name in [
        'HankenGrotesk-400.ttf', 'HankenGrotesk-500.ttf', 'HankenGrotesk-600.ttf',
        'HankenGrotesk-700.ttf', 'HankenGrotesk-800.ttf', 'Sora-600.ttf', 'Sora-700.ttf',
      ]) {
        final f = File('${dir.path}/$name');
        if (await f.exists()) continue;
        final data = await rootBundle.load('assets/fonts/$name');
        await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
    } catch (e) {
      debugPrint('Player: fonts for mpv could not be installed: $e');
    }
  }

  Future<void> _start() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _mode = prefs.getString('playbackMode') ?? 'auto';
      _level = (prefs.getInt(_levelKey) ?? 0).clamp(0, _maxLevel).toInt();
      _subScale = prefs.getDouble('subScale') ?? 1.0;
      _subPos = prefs.getInt('subPos') ?? 100;
      _subBox = prefs.getBool('subBox') ?? false;
    } catch (_) {}
    _levelAtStart = _level;
    // The card's details can be minutes old (or from the saved home screen): ask for the
    // current resume point and tracks, without making you wait more than a moment.
    try {
      _fresh = await widget.jf.item(_id, fresh: true).timeout(const Duration(seconds: 3));
    } catch (_) {}
    await _loadTrackPrefs();

    String url = widget.jf.directStreamUrl(_id);
    final wantServer = _mode == 'server' || (_mode == 'auto' && _level >= _serverStep);
    if (wantServer) {
      _presetServerTracks();
      final server = await _serverStream();
      if (server != null) url = server;
    }

    await _installFonts();
    final script = await _scriptPath();
    final window = await _windowArgs();
    final resume = _resumeTicks > 0 ? _resumeTicks / 10000000 : 0.0;
    final args = <String>[
      ...window,
      '--title=Frame',
      // Shown as Frame (not as a separate mpv app) by KDE.
      if (_mpvHasHdr) '--wayland-app-id=frame',
      if (_mpvHasHdr) '--background-color=#06080B',
      '--force-window=immediate',
      '--keep-open=no',
      '--idle=no',
      '--osc=no',
      '--osd-bar=no',
      '--ytdl=no',
      // In a room, only Frame's controls (which go through the room) may pause or seek.
      '--input-default-bindings=${widget.sync == null ? 'yes' : 'no'}',
      if (widget.sync != null) '--pause',
      '--cursor-autohide=1500',
      // mpv's newer engine: Dolby Vision handled natively, real HDR where the system supports it.
      '--vo=gpu-next',
      '--hwdec=auto-safe',
      '--tone-mapping=bt.2446a',
      '--hdr-compute-peak=no',
      // Newer mpv: tell KDE the picture is HDR so the screen shows it as HDR (KDE turns this
      // into SDR itself when HDR is off). Older mpv converts to SDR with the setting above.
      if (_mpvHasHdr) '--target-colorspace-hint=yes',
      '--cache=yes',
      '--demuxer-max-bytes=256MiB',
      '--demuxer-max-back-bytes=128MiB',
      '--demuxer-readahead-secs=60',
      '--cache-pause-initial=yes',
      '--cache-pause-wait=1',
      // After a long pause, the server may have closed the idle connection: reconnect quietly
      // instead of stalling when you press play again.
      '--stream-lavf-o-append=reconnect=1',
      '--stream-lavf-o-append=reconnect_on_network_error=1',
      '--stream-lavf-o-append=reconnect_delay_max=4',
      '--hr-seek=no',
      '--sub-ass-override=scale',
      '--script=$script',
      if (resume > 0) '--start=${resume.toStringAsFixed(1)}',
      url,
    ];
    if (!mounted) return; // closed while getting ready
    try {
      await _mpv.start(_mpvPath!, args);
    } catch (e) {
      if (mounted) setState(() => _error = "mpv couldn't start: ${errorText(e)}");
      return;
    }
    if (!mounted) {
      // Back was pressed while mpv was opening: don't leave it playing on its own.
      _mpv.close();
      return;
    }
    _eventsSub = _mpv.events.listen(_onEvent);
    _mpv.observe(1, 'time-pos');
    _mpv.observe(3, 'pause');
    _mpv.observe(5, 'fullscreen');
    if (widget.sync != null) {
      _mpv.observe(6, 'paused-for-cache');
      _mpv.observe(7, 'duration');
      _startTogether();
    }
    unawaited(_handOff());
    _mpv.observe(4, 'user-data/frame/request');
    await _applyLevel();
    await _applySubStyle();
    await _sendInfo();
    _sendPad();
    // In case mpv finished opening the file before Frame was listening.
    Timer(const Duration(seconds: 3), () {
      if (_loadedSeen || _ended) return;
      if (_server) {
        final text = _serverTextSub;
        if (text != null) _showServerTextSub(text);
      } else {
        _applyTrackPrefs();
      }
      _link?.ready(); // the room is waiting for this player
    });
    widget.jf.reportStart(_id, _resumeTicks, session: _session);
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_switching) widget.jf.reportProgress(_id, _ticksNow, _paused, session: _session);
    });
    _lastSeek = DateTime.now();
    _adaptTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkSmoothness());
    // mpv closed (the video ended, or Back): report and go back. If it closed straight away
    // without playing anything, say so instead of silently going back.
    final started = DateTime.now();
    _mpv.exitCode.then((code) {
      _takeBack();
      // (Code 0 is a normal quit: you went back before it started, which is fine.)
      if (code != 0 && _pos == 0 && DateTime.now().difference(started) < const Duration(seconds: 5)) {
        _ended = true;
        if (mounted) {
          setState(() => _error = "mpv closed right away (code $code). The terminal lines starting with 'mpv:' say why.");
        }
        return;
      }
      _finished();
    });
    if (mounted) _focus.requestFocus();
  }

  // The player opens exactly where Frame is: full screen if Frame is, otherwise the same size
  // (or maximized). KDE places it; Wayland doesn't let apps choose the position.
  Future<List<String>> _windowArgs() async {
    try {
      _mpvFull = fullScreen.value;
      if (_mpvFull) return ['--fs'];
      if (await windowManager.isMaximized()) return ['--window-maximized=yes'];
      final size = await windowManager.getSize();
      final display = WidgetsBinding.instance.platformDispatcher.displays.first;
      final w = size.width * display.devicePixelRatio / display.size.width * 100;
      final h = size.height * display.devicePixelRatio / display.size.height * 100;
      if (w > 0 && h > 0 && w <= 100 && h <= 100) {
        return ['--geometry=${w.round()}%x${h.round()}%'];
      }
    } catch (e) {
      debugPrint('Player: window size unknown ($e)');
    }
    return ['--fs'];
  }

  // Once mpv's window is up, Frame's own window steps aside.
  Future<void> _handOff() async {
    await Future.delayed(const Duration(milliseconds: 500));
    if (_ended || !mounted) return;
    try {
      await windowManager.hide();
      _handedOff = true;
    } catch (_) {}
  }

  // When the video ends or you go back, Frame comes back the way you left the player: if you
  // switched the player to full screen, Frame is full screen too, and the other way round.
  Future<void> _takeBack() async {
    if (!_handedOff) return;
    _handedOff = false;
    try {
      await windowManager.show();
      await windowManager.focus();
      await setFullScreen(_mpvFull);
    } catch (e) {
      debugPrint('Player: Frame window could not come back: $e');
    }
  }

  void _finished() {
    if (_ended) return;
    _ended = true;
    widget.jf.reportStopped(_id, _ticksNow, session: _session);
    if (mounted) Navigator.of(context).maybePop();
  }

  void _onEvent(Map<String, dynamic> e) {
    if (e['event'] == 'property-change') {
      final data = e['data'];
      switch (e['name']) {
        case 'time-pos':
          if (data is num) _pos = data.toDouble();
        case 'pause':
          if (data is bool) _paused = data;
        case 'fullscreen':
          if (data is bool) _mpvFull = data;
        case 'paused-for-cache':
          if (data is bool) _onStall(data);
        case 'duration':
          if (data is num) _duration = data.toDouble();
        case 'user-data/frame/request':
          if (data is Map) _onRequest(data);
      }
    } else if (e['event'] == 'seek') {
      _lastSeek = DateTime.now();
    } else if (e['event'] == 'file-loaded') {
      _loadedSeen = true;
      Timer(const Duration(seconds: 2), () {
        if (!_ended) _logPlayback('opened');
      });
      if (_server) {
        // The server's stream carries no text subtitles: add the chosen one now.
        final text = _serverTextSub;
        if (text != null) _showServerTextSub(text);
      } else {
        _applyTrackPrefs();
      }
      _link?.ready();
    }
  }

  // ---------- What the controls inside mpv ask Frame to do ----------

  Future<void> _onRequest(Map data) async {
    final n = data['n'];
    if (n is! int || n <= _lastRequest) return;
    _lastRequest = n;
    final value = data['value'];
    switch (data['action']) {
      case 'mode':
        await _setMode(value.toString());
      case 'audio':
        if (value is int && value != _serverAudio) {
          _serverAudio = value;
          _rememberStream('audio', value);
          await _reopen(server: true);
        }
      case 'sub':
        final index = value is int ? value : -1;
        if (index < 0) {
          _rememberTrack('sub', const {'off': true});
        } else {
          _rememberStream('sub', index);
        }
        await _chooseServerSubtitle(index);
      case 'picked':
        await _rememberMpvTrack(value.toString());
      case 'sync':
        if (value is Map) await _togetherRequest(value);
      case 'style':
        if (value is Map) {
          _subScale = ((value['scale'] ?? _subScale) as num).toDouble();
          _subPos = ((value['pos'] ?? _subPos) as num).toInt();
          _subBox = value['box'] == true;
          await _applySubStyle(save: true);
        }
    }
    await _sendInfo();
  }

  // Everything the controls show that only Frame knows.
  Future<void> _sendInfo() async {
    final isEpisode = _item['Type'] == 'Episode';
    final subtitleLine = isEpisode
        ? [
            if (_item['ParentIndexNumber'] != null) 'S${_item['ParentIndexNumber']}',
            if (_item['IndexNumber'] != null) 'E${_item['IndexNumber']}',
            _item['Name'] ?? '',
          ].join(' · ')
        : (_item['ProductionYear']?.toString() ?? '');
    final audio = _streams('Audio');
    final subs = _streams('Subtitle');
    final defaultAudio = audio.cast<dynamic>().firstWhere((a) => a['IsDefault'] == true, orElse: () => null)?['Index'];
    await _mpv.set('user-data/frame/info', {
      'title': titleOf(_item),
      'subtitle': subtitleLine,
      'quality': qualityLine(_item),
      'mode': _mode,
      'server': _server,
      'step': _level,
      // Jellyfin's names for the file's own tracks, in order (the original file's track list).
      'audio_names': [for (final a in audio.where((a) => a['IsExternal'] != true)) _label(a)],
      'sub_names': [for (final s in subs.where((s) => s['IsExternal'] != true)) _label(s)],
      // With the server's version: what can be picked (the server switches to it).
      'server_audio': [
        for (final a in audio)
          {'index': a['Index'], 'label': _label(a), 'selected': (a['Index'] == (_serverAudio ?? defaultAudio))}
      ],
      'server_subs': [
        for (final s in subs)
          {
            'index': s['Index'],
            'label': '${_label(s)}${s['IsTextSubtitleStream'] == true ? '' : ' · drawn in by the server'}',
            'selected': s['Index'] == _serverSub || s['Index'] == _serverTextSub,
          }
      ],
      if (_room != null) 'group': _room,
      // Your profile colour for the panels' line (mpv writes colours blue-green-red).
      'accent': [kAccent.blue, kAccent.green, kAccent.red].map((c) => c.toRadixString(16).padLeft(2, '0')).join().toUpperCase(),
      'sub_scale': _subScale,
      'sub_pos': _subPos,
      'sub_box': _subBox,
    });
  }

  // ---------- The controller, the legend ----------

  void _sendPad() {
    final style = !padActive.value ? 'none' : (padStyle.value == PadStyle.playstation ? 'ps' : 'xbox');
    _mpv.command(['script-message-to', 'frame_ui', 'pad', style]).then((_) {}, onError: (_) {});
  }

  // Frame still reads the controller while mpv is in front, and passes the buttons on.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    return _forward(event.logicalKey) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool _forward(LogicalKeyboardKey key) {
    final keys = {
      LogicalKeyboardKey.arrowUp: 'up',
      LogicalKeyboardKey.arrowDown: 'down',
      LogicalKeyboardKey.arrowLeft: 'left',
      LogicalKeyboardKey.arrowRight: 'right',
      LogicalKeyboardKey.enter: 'select',
      LogicalKeyboardKey.escape: 'back',
      LogicalKeyboardKey.backspace: 'back',
      LogicalKeyboardKey.space: 'playpause',
      LogicalKeyboardKey.mediaPlayPause: 'playpause',
      LogicalKeyboardKey.mediaRewind: 'rew',
      LogicalKeyboardKey.mediaFastForward: 'ff',
      LogicalKeyboardKey.contextMenu: 'info', // Triangle / Y
    };
    final k = keys[key];
    if (k == null) return false;
    if (_error != null || _ended) {
      if ((k == 'back' || k == 'select') && mounted) Navigator.of(context).maybePop();
      return true;
    }
    _mpv.command(['script-message-to', 'frame_ui', 'key', k]).then((_) {}, onError: (_) {});
    return true;
  }

  // ---------- Remembering audio and subtitle choices ----------
  //
  // Like Infuse: the audio and subtitles you pick are remembered for the show (and become the
  // default for everything else), described by language and kind (forced, SDH, audio
  // description), so the next episode picks the same kind of track even if it sits elsewhere.

  late final TrackPrefs _tracks = TrackPrefs(_item);
  bool _loadedSeen = false;

  Future<void> _loadTrackPrefs() => _tracks.load();

  void _rememberTrack(String kind, Map<String, dynamic> pref) => _tracks.remember(kind, pref);

  void _rememberStream(String kind, int index) => _tracks.rememberStream(kind, index);

  // A pick made in the original file's track list (mpv's own tracks).
  Future<void> _rememberMpvTrack(String kind) async {
    final list = await _mpv.get('track-list');
    if (list is! List) return;
    final type = kind == 'audio' ? 'audio' : 'sub';
    final picked = list.cast<Map>().where((t) => t['type'] == type && t['selected'] == true).toList();
    if (picked.isEmpty) {
      if (kind == 'sub') await _tracks.rememberSubsOff();
      return;
    }
    await _tracks.remember(kind, TrackPrefs.describeMpv(picked.first));
  }

  // Original file: when mpv has opened it, switch to the remembered kind of tracks.
  Future<void> _applyTrackPrefs() async {
    final audio = _tracks.audio, sub = _tracks.sub;
    if (_server || (audio == null && sub == null)) return;
    final list = await _mpv.get('track-list');
    if (list is! List) return;
    final tracks = list.cast<Map>();
    int? best(String type, Map<String, dynamic> pref) => TrackPrefs.best<int?>(pref, [
          for (final t in tracks.where((t) => t['type'] == type)) (t['id'] as int?, TrackPrefs.describeMpv(t)),
        ]);
    if (audio != null) {
      final id = best('audio', audio);
      if (id != null) await _mpv.set('aid', id);
    }
    if (sub != null) {
      if (sub['off'] == true) {
        await _mpv.set('sid', 'no');
      } else {
        final id = best('sub', sub);
        if (id != null) {
          await _mpv.set('sid', id);
          await _mpv.set('sub-visibility', true);
        }
      }
    }
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

  // ---------- Watch together ----------
  //
  // Your play, pause and seek go to the room (Jellyfin's SyncPlay); the room then tells
  // everyone, Frame included, what to do and when. Frame acts at that exact moment on the
  // server's clock, reports when it's still loading, and stays in step by playing a few percent
  // faster or slower for a moment instead of jumping.

  SyncPlay? get _sync => widget.sync;
  Map<String, dynamic>? _room; // for the controls: name, people, state
  double _duration = 0;
  bool _handingOver = false;
  String? _myName;

  String get _playlistItemId => widget.playlistItemId ?? '';

  // Frame's instant channel (when the room uses it): the shared follower in syncplay.dart.
  RoomLink? _link;

  void _startTogether() {
    final sync = _sync!;
    _myName = widget.jf.userName;
    _link = RoomLink.create(
      sync: sync,
      playlistItemId: _playlistItemId,
      itemId: _id,
      myName: _myName,
      position: () => _pos,
      isPaused: () => _paused,
      // Exact seeks always: the room only accepts a position within half a second of its own.
      seekTo: (sec) => _mpv.command(['seek', sec, 'absolute+exact']).then((_) {}, onError: (_) {}),
      setPaused: (paused) {
        _paused = paused;
        return _mpv.set('pause', paused);
      },
      setSpeed: (speed) => _mpv.set('speed', speed),
      notice: _notice,
      onStop: () => _mpv.command(['quit']).then((_) {}, onError: (_) {}),
      onNewVideo: (now) {
        if (mounted) _switchRoomVideo(now);
      },
      settled: () async {
        try {
          final seeking = await _mpv.get('seeking');
          final loading = await _mpv.get('paused-for-cache');
          return seeking != true && loading != true;
        } catch (_) {
          return true;
        }
      },
      exactPosition: () async {
        try {
          final v = await _mpv.get('time-pos');
          if (v is num) return _pos = v.toDouble();
        } catch (_) {}
        return _pos;
      },
      duration: () => _duration,
    )..start();
    sync.group.addListener(_onRoomChanged);
    _onRoomChanged();
  }

  void _endTogether() {
    final sync = _sync;
    if (sync == null) return;
    sync.group.removeListener(_onRoomChanged);
    final link = _link;
    _link = null;
    if (link != null) {
      link.handingOver = _handingOver;
      link.dispose(); // leaves the room unless it moved on to another video
    }
  }

  void _onRoomChanged() {
    final g = _sync?.group.value;
    _room = g == null
        ? null
        : {
            'name': g.name,
            'people': g.people,
            'state': g.state,
          };
    if (!_ended) _sendInfo();
  }

  void _notice(String text) =>
      _mpv.command(['script-message-to', 'frame_ui', 'notice', text]).then((_) {}, onError: (_) {});

  Future<void> _togetherRequest(Map value) async {
    final link = _link;
    if (link == null) return;
    switch (value['op']) {
      case 'toggle':
      case 'pause':
      case 'unpause':
        link.togglePause();
      case 'seek':
        final pos = (value['pos'] as num?)?.toDouble();
        if (pos != null) link.seek(pos);
    }
  }

  Future<void> _switchRoomVideo(({String itemId, String playlistItemId, int startTicks, bool playing}) now) async {
    try {
      final item = await widget.jf.item(now.itemId, fresh: true);
      if (!mounted) return;
      _ended = true; // this screen hands over; the room continues
      _handingOver = true;
      widget.jf.reportStopped(_id, _ticksNow, session: _session);
      _endTogether(); // hands over: the room stays
      await _mpv.close();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => NativePlayerScreen(
              jf: widget.jf, item: item, sync: _sync, playlistItemId: now.playlistItemId, startTicks: now.startTicks)));
    } catch (e) {
      debugPrint('Together: could not open the room\'s new video: $e');
    }
  }

  // mpv ran out of video to show (slow network): the follower decides whether that's news.
  void _onStall(bool stalled) {
    if (!_ended) _link?.stalled(stalled);
  }



  // ---------- Original file or the server's version ----------

  Future<String?> _serverStream() async {
    try {
      final s = await widget.jf.serverStream(_id, audioIndex: _serverAudio, subtitleIndex: _serverSub);
      _session = s.session;
      _serverSubUrls
        ..clear()
        ..addEntries(s.subtitles.map((x) => MapEntry(x.index, x.url)));
      _server = true;
      return s.url;
    } catch (e) {
      debugPrint('Player: the server could not provide its version: $e');
      return null;
    }
  }

  // Opens the original file or the server's version at the current moment.
  Future<void> _reopen({required bool server}) async {
    if (_switching) return;
    _switching = true;
    final at = _pos;
    final oldSession = _session;
    try {
      String? url;
      if (server) {
        url = await _serverStream();
        if (url == null) return;
      } else {
        url = widget.jf.directStreamUrl(_id);
        _server = false;
        _session = null;
      }
      await _mpv.set('start', at.toStringAsFixed(1));
      await _mpv.command(['loadfile', url, 'replace']);
      widget.jf.reportStopped(_id, (at * 10000000).round(), session: oldSession);
      widget.jf.reportStart(_id, (at * 10000000).round(), session: _session);
      // A text subtitle that was on comes back when the new stream has loaded (file-loaded).
      debugPrint('Player: playing ${_server ? "the server's version" : 'the original file'}');
    } catch (e) {
      debugPrint('Player: switching failed: $e');
    } finally {
      _switching = false;
      _lastSeek = DateTime.now();
      _lastDrops = -1;
      await _sendInfo();
      // Later files start from the beginning unless told otherwise.
      Timer(const Duration(seconds: 3), () => _mpv.set('start', 'none'));
    }
  }

  Future<void> _showServerTextSub(int index) async {
    final url = _serverSubUrls[index];
    if (url == null) return;
    try {
      await _mpv.command(['sub-add', url, 'select']);
      await _mpv.set('sub-visibility', true);
    } catch (e) {
      debugPrint('Player: subtitle could not be added: $e');
    }
  }

  Future<void> _chooseServerSubtitle(int index) async {
    if (index < 0) {
      _serverTextSub = null;
      await _mpv.set('sid', 'no');
      if (_serverSub != null) {
        _serverSub = null;
        await _reopen(server: true);
      }
      return;
    }
    final stream = _streams('Subtitle').cast<dynamic>().firstWhere((s) => s['Index'] == index, orElse: () => null);
    if (stream == null) return;
    if (stream['IsTextSubtitleStream'] == true && _serverSubUrls[index] != null) {
      _serverTextSub = index;
      if (_serverSub != null) {
        _serverSub = null;
        await _reopen(server: true);
      } else {
        await _showServerTextSub(index);
      }
    } else {
      _serverTextSub = null;
      await _mpv.set('sid', 'no');
      _serverSub = index;
      await _reopen(server: true);
    }
  }

  Future<void> _setMode(String mode) async {
    _mode = mode;
    try {
      await (await SharedPreferences.getInstance()).setString('playbackMode', mode);
    } catch (_) {}
    if (mode == 'server' && !_server) await _reopen(server: true);
    if (mode == 'original' && _server) {
      _level = _level.clamp(0, _maxLevel).toInt();
      await _reopen(server: false);
    }
  }

  // ---------- Adapting to this device (same rules as the in-app player) ----------

  Future<void> _applyLevel() async {
    if (_level < 1 || _server) return;
    for (final p in {
      'scale': 'bilinear',
      'dscale': 'bilinear',
      'cscale': 'bilinear',
      'dither-depth': 'no',
      'correct-downscaling': false,
      'linear-downscaling': false,
      'sigmoid-upscaling': false,
      'deband': false,
    }.entries) {
      await _mpv.set(p.key, p.value);
    }
  }

  // Once a minute while playing, and when a file opens: how playback is going, for the
  // performance log (perf.dart).
  int _statsTicks = 0;
  Future<void> _logPlayback(String when) async {
    Future<String> p(String name) async => '${await _mpv.get(name) ?? '?'}';
    final params = await _mpv.get('video-params');
    final target = await _mpv.get('video-target-params');
    final size = params is Map ? '${params['w']}x${params['h']} ${params['gamma'] ?? ''}' : '?';
    final out = target is Map ? '${target['gamma'] ?? '?'}' : '?';
    perfLog('mpv $when: ${titleOf(_item)} · $size -> $out · ${_server ? 'server version' : 'original file'}'
        ' · decoder ${await p('hwdec-current')} · fps ${await p('estimated-vf-fps')} on ${await p('display-fps')} Hz'
        ' · dropped ${await p('frame-drop-count')} (decoder ${await p('decoder-frame-drop-count')})'
        ' · mistimed ${await p('mistimed-frame-count')} · delayed ${await p('vo-delayed-frame-count')}'
        ' · buffered ${await p('demuxer-cache-duration')} s · step $_level');
  }

  Future<void> _checkSmoothness() async {
    if (_switching || _ended) return;
    if (++_statsTicks % 6 == 0 && !_paused) unawaited(_logPlayback('playing'));
    final raw = await _mpv.get('frame-drop-count');
    if (raw is! num) return;
    final drops = raw.toInt();
    final previous = _lastDrops;
    _lastDrops = drops;
    if (previous < 0 || drops < previous) return;
    if (_paused || DateTime.now().difference(_lastSeek) < const Duration(seconds: 12)) return;
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
      await _reopen(server: true);
    } else {
      await _applyLevel();
      await _sendInfo();
    }
    _lastDrops = -1;
    _lastSeek = DateTime.now();
  }

  void _saveLearnedLevel() {
    if (_eased || _levelAtStart == 0 || _level != _levelAtStart || _cleanSeconds < 600) return;
    final key = _levelKey;
    final next = _level - 1;
    SharedPreferences.getInstance().then((p) => p.setInt(key, next)).then((_) {}, onError: (_) {});
  }

  Future<void> _applySubStyle({bool save = false}) async {
    await _mpv.set('sub-scale', _subScale);
    await _mpv.set('sub-pos', _subPos);
    // mpv 0.38+ has sub-border-style. Older mpv draws the box whenever the
    // background colour is not fully transparent, so switch the colour instead.
    if (_hasBorderStyle && await _mpv.trySet('sub-border-style', _subBox ? 'background-box' : 'outline-and-shadow')) {
      await _mpv.set('sub-back-color', '#B3000000');
    } else {
      _hasBorderStyle = false;
      await _mpv.set('sub-back-color', _subBox ? '#B3000000' : '#00000000');
    }
    if (save) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('subScale', _subScale);
        await prefs.setInt('subPos', _subPos);
        await prefs.setBool('subBox', _subBox);
      } catch (_) {}
    }
  }

  // ---------- What Frame's own window shows behind mpv ----------

  @override
  Widget build(BuildContext context) {
    return PadHints(
      // The legend is drawn inside mpv; only the error screen here needs one.
      hints: _error != null ? const [PadHint(PadButton.back, 'Back')] : const [],
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_error ?? 'Playing ${titleOf(_item)}', style: tvBody(26, color: kMuted)),
              if (_error != null) ...[
                const SizedBox(height: 24),
                Focusable(
                  autofocus: true,
                  onSelect: () => Navigator.of(context).maybePop(),
                  builder: (f) => tvPill('Back', focused: f, icon: Icons.arrow_back_rounded),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
