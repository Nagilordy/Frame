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
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'gamepad.dart' show padActive, padStyle, PadStyle, PadHint, PadButton, PadHints, GamepadInput;
import 'main.dart' show Jellyfin;
import 'player.dart' show PlayerScreen;
import 'syncplay.dart' show SyncPlay, RoomLink;
import 'images.dart' show netImage, LogoImage, logoNeedsMatte;
import 'perf.dart' show perfLog, PerfRecorder;
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
/// Frame's window opens without waiting for this: it finishes in the background (asking mpv
/// its version can take seconds right after mpv was updated). A video started before it's done
/// waits for it (see playerScreen).
final _mpvSearch = Completer<void>();

Future<void> findMpv() async {
  try {
    await _findMpv();
  } finally {
    if (!_mpvSearch.isCompleted) _mpvSearch.complete();
  }
}

Future<void> _findMpv() async {
  if (Platform.isWindows) {
    // Bundled by the installer (see .github/workflows/windows.yml) next to Frame.
    final exe = '${File(Platform.resolvedExecutable).parent.path}\\mpv\\mpv.exe';
    if (await File(exe).exists()) {
      _mpvPath = exe;
      _mpvVersion = await _cachedVersionOf(exe);
      // The installer always brings a current mpv. If it couldn't say its version (it prints
      // nothing in some setups), don't lose HDR, Dolby Vision and the newer options over that.
      if (_mpvVersion == 0) _mpvVersion = 0.40;
    }
    debugPrint(_mpvPath == null
        ? 'Player: no mpv next to Frame, using the in-app player'
        : 'Player: videos play in mpv ${_mpvVersion.toStringAsFixed(2)} ($_mpvPath)');
    return;
  }
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
  // Frame's own AppImage runs from an unpacked copy (see _unpacked).
  if (_mpvPath == _ownMpv) _mpvPath = await _unpacked(_ownMpv) ?? _ownMpv;
  if (_mpvPath != null) _mpvVersion = await _cachedVersionOf(_mpvPath!);
  debugPrint(_mpvPath == null
      ? 'Player: no mpv found, using the in-app player for now'
      : 'Player: videos play in mpv ${_mpvVersion.toStringAsFixed(2)} ($_mpvPath)'
          '${_mpvHasHdr ? ', HDR on' : ''}');
  if (!_mpvHasHdr) unawaited(_fetchMpv());
}

/// Frame's mpv AppImage, unpacked once into its own folder, and run from there.
///
/// Run as an AppImage, mpv mounts itself in /tmp on every start. A start that's cut short (mpv
/// closed at the end of a video, the computer put to sleep) can leave that mount behind, and
/// every later start then refuses to reuse it and quits at once, without a word ("mpv closed
/// while starting"). Unpacked, there's nothing to mount: no such failure, and a quicker start.
/// Unpacked again only when the AppImage changes. Returns null (use the AppImage) if it fails.
Future<String?> _unpacked(String appImage) async {
  try {
    final dir = Directory('$_ownMpvDir/unpacked');
    final run = File('${dir.path}/squashfs-root/AppRun');
    final stamp = File('${dir.path}/from.txt');
    final stat = await File(appImage).stat();
    final from = '${stat.size} ${stat.modified.millisecondsSinceEpoch}';
    if (await run.exists() && await stamp.exists() && (await stamp.readAsString()) == from) return run.path;
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final r = await Process.run(appImage, ['--appimage-extract'], workingDirectory: dir.path, environment: _mpvEnv)
        .timeout(const Duration(minutes: 2));
    if (r.exitCode != 0 || !await run.exists()) {
      debugPrint('Player: could not unpack mpv (code ${r.exitCode}), using the AppImage as it is');
      return null;
    }
    await stamp.writeAsString(from);
    debugPrint('Player: mpv unpacked into ${dir.path}');
    return run.path;
  } catch (e) {
    debugPrint('Player: could not unpack mpv ($e), using the AppImage as it is');
    return null;
  }
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
    _mpvPath = await _unpacked(_ownMpv) ?? _ownMpv;
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
Widget playerScreen(Jellyfin jf, dynamic item, {SyncPlay? sync, String? playlistItemId, int? startTicks}) {
  if (!_mpvSearch.isCompleted) {
    // Play pressed in the first moments after launch: wait for the player to be found.
    return FutureBuilder<void>(
      future: _mpvSearch.future,
      builder: (context, snap) => snap.connectionState == ConnectionState.done
          ? _playerScreen(jf, item, sync: sync, playlistItemId: playlistItemId, startTicks: startTicks)
          : const ColoredBox(color: kBg),
    );
  }
  return _playerScreen(jf, item, sync: sync, playlistItemId: playlistItemId, startTicks: startTicks);
}

Widget _playerScreen(Jellyfin jf, dynamic item, {SyncPlay? sync, String? playlistItemId, int? startTicks}) =>
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

  // Windows: no socket (see assets/mpv/frame_bridge.lua). Commands go into a small file the
  // bridge script reads; replies and events come back on mpv's output.
  RandomAccessFile? _commandFile;
  String? _commandPath;

  Future<void> _startBridge(String mpv, List<String> args, String bridgeScript) async {
    final path = '${Directory.systemTemp.path}\\frame-mpv-$pid-${DateTime.now().millisecondsSinceEpoch}.txt';
    _commandPath = path;
    _commandFile = File(path).openSync(mode: FileMode.write);
    final ready = Completer<void>();
    _process = await Process.start(
        mpv,
        [
          ...args,
          '--script=$bridgeScript',
          '--script-opts-append=frame_bridge-commands=$path',
          '--msg-level=frame_bridge=info', // its messages must reach Frame even if mpv is told to be quiet
        ],
        environment: _mpvEnv);
    var exited = false;
    _process!.exitCode.then((_) {
      exited = true;
      _events.add({'event': 'closed'});
      if (!ready.isCompleted) ready.completeError('mpv closed while starting.');
    });
    for (final stream in [_process!.stdout, _process!.stderr]) {
      stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final at = line.indexOf('[frame_bridge] ');
        if (at >= 0) {
          final json = line.substring(at + 15);
          if (json.contains('"bridge-ready"')) {
            if (!ready.isCompleted) ready.complete();
            return;
          }
          _onLine(json);
          return;
        }
        if (line.trim().isEmpty || _statusLine.hasMatch(line)) return;
        debugPrint('mpv: $line');
      });
    }
    await ready.future.timeout(const Duration(seconds: 15), onTimeout: () {
      throw exited ? 'mpv closed while starting.' : 'mpv did not start.';
    });
  }

  Future<void> start(String mpv, List<String> args, {String? bridgeScript}) async {
    if (Platform.isWindows && bridgeScript != null) return _startBridge(mpv, args, bridgeScript);
    final socketPath = '${Directory.systemTemp.path}/frame-mpv-$pid-${DateTime.now().millisecondsSinceEpoch}.sock';
    _socketPath = socketPath;
    _process = await Process.start(mpv, [...args, '--input-ipc-server=$socketPath'], environment: _mpvEnv);
    var exited = false;
    var connected = false; // (the socket is cleared again when mpv quits, so it can't tell)
    _process!.exitCode.then((code) {
      exited = true;
      // Closed before Frame could connect: say how, since mpv may not have printed anything.
      if (!connected) debugPrint('mpv: closed while starting, exit code $code ($mpv)');
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
        connected = true;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    if (_socket == null) throw exited ? 'mpv closed while starting.' : 'mpv did not start.';
    final socket = _socket!;
    // Once mpv is gone, writes to its socket fail later, outside any try ("Broken pipe"): catch
    // that here, and stop writing to it at all.
    socket.done.then((_) {}, onError: (_) {});
    socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine,
        onError: (_) {}, onDone: () {
      if (identical(_socket, socket)) _socket = null;
      socket.destroy();
      _events.add({'event': 'closed'});
    });
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
    final file = _commandFile;
    if (socket == null && file == null) return Future.error('mpv is not running');
    final id = _next++;
    final c = Completer<dynamic>();
    _pending[id] = c;
    try {
      final line = '${jsonEncode({'command': cmd, 'request_id': id})}\n';
      if (socket != null) {
        socket.write(line);
      } else {
        file!.writeStringSync(line);
      }
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
    try {
      _commandFile?.closeSync();
    } catch (_) {}
    _commandFile = null;
    final cmd = _commandPath;
    if (cmd != null) File(cmd).delete().then((_) {}, onError: (_) {});
  }
}

// ---------- The screen ----------

class NativePlayerScreen extends StatefulWidget {
  const NativePlayerScreen(
      {super.key, required this.jf, required this.item, this.sync, this.playlistItemId, this.startTicks, this.continued = false});
  final Jellyfin jf;
  final dynamic item;
  final SyncPlay? sync; // a Watch together room, or null
  final String? playlistItemId; // the room's id for this video
  final int? startTicks; // where the room starts (instead of your resume point)
  final bool continued; // opened by the previous episode (Frame's window is already hidden)

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
  bool _fileEnding = false; // between a video's end and the next one loading
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

  /// A disc image or a disc folder (ISO, Blu-ray BDMV, DVD VIDEO_TS): the original can't be
  /// streamed as one file, so the server's version is used for it.
  bool get _isDisc {
    final type = (_item['VideoType'] ?? 'VideoFile').toString();
    final container = (_item['Container'] ?? '').toString().toLowerCase();
    return type != 'VideoFile' || container == 'iso' || container == 'bluray' || container == 'dvd';
  }

  bool _triedServer = false; // the original failed to open, and the server's version was tried

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
    fullScreenOverride = _cycleFullScreen;
    padActive.addListener(_sendPad);
    padStyle.addListener(_sendPad);
    GamepadInput.keyOverride = _forward;
    widget.sync?.playerOpened(widget.playlistItemId); // watching the party's video
    _start();
  }

  @override
  void dispose() {
    _takeBack();
    if (fullScreenOverride == _cycleFullScreen) fullScreenOverride = null;
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
    widget.sync?.playerClosed(); // still in the party, just not watching
    super.dispose();
  }

  Future<void> _cycleFullScreen() => _mpv.command(['cycle', 'fullscreen']).then((_) {}, onError: (_) {});

  // ---------- The loading screen, on both sides of the switch ----------
  //
  // Frame's screen (build, below) and the player's (frame_ui.lua) are drawn the same: the
  // title logo centred in a box 900 x 160 at y = 500 of the 1080-high design, the episode line
  // at y = 620, a thin line at y = 680. The player can't draw pictures in its controls, so
  // Frame hands it the logo as an overlay at exactly that place, and removes it when the video
  // starts.

  bool _logoShown = false;
  bool _logoFailed = false; // no logo after all: the player writes the title instead
  bool _videoStarted = false; // the player said the loading screen is over ('loaded')

  /// The line under the title on both loading screens.
  String get _loadingLine =>
      _item['Type'] == 'Episode' ? episodeLine(_item) : (_item['ProductionYear']?.toString() ?? '');

  // The loading screen's shading over the artwork (same in Frame and in the player's picture):
  // dark on the left where the text is, and dark along the bottom.
  static final _loadingShades = [
    (from: const Offset(0, 0.5), to: const Offset(1, 0.5),
        colors: [kBg.withOpacity(0.85), kBg.withOpacity(0.35), kBg.withOpacity(0.10)], stops: const [0.0, 0.55, 1.0]),
    (from: const Offset(0.5, 1), to: const Offset(0.5, 0),
        colors: [kBg.withOpacity(0.85), kBg.withOpacity(0)], stops: const [0.0, 0.5]),
  ];

  bool _pictureHasLogo = false; // the logo is part of the picture (else the player writes the title)

  /// Chips under the episode line: how it plays (quality, HDR, sound).
  List<String> get _loadingChips =>
      qualityLine(_item).split(' · ').where((x) => x.trim().isNotEmpty).toList();

  /// Under the running line: where it starts.
  String get _loadingStatus {
    final ticks = _resumeTicks;
    if (ticks <= 0) return 'Starting';
    final secs = ticks ~/ 10000000;
    final h = secs ~/ 3600, m = (secs % 3600) ~/ 60, sec = secs % 60;
    final at = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}' : '$m:${sec.toString().padLeft(2, '0')}';
    return 'Resumes at $at';
  }

  // The loading screen's artwork, shading and logo as one picture the size of the player's
  // window, placed underneath the player's own drawing (frame_ui.lua draws the text, chips
  // and line on top, at the same places as _loadingView). Name kept from when it was only
  // the logo.
  Future<void> _showLogoInPlayer() async {
    try {
      // The player window's size, once it's up.
      Map? osd;
      for (var i = 0; i < 40 && !_ended; i++) {
        final d = await _mpv.get('osd-dimensions');
        if (d is Map && (d['w'] ?? 0) > 0 && (d['h'] ?? 0) > 0) {
          osd = d;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (osd == null || _ended) return;
      final ow = (osd['w'] as num).round(), oh = (osd['h'] as num).round();
      final s = oh / 1080;

      Future<ui.Image?> fetch(String? url, {int? width, int? height}) async {
        if (url == null) return null;
        try {
          final res = await Jellyfin.client.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
          if (res.statusCode != 200) return null;
          final codec = await ui.instantiateImageCodec(res.bodyBytes, targetWidth: width, targetHeight: height);
          return (await codec.getNextFrame()).image;
        } catch (_) {
          return null;
        }
      }

      final logoUrl = widget.jf.logoFor(_item);
      final results = await Future.wait([
        fetch(widget.jf.backdropFor(_item, maxWidth: ow.clamp(1280, 3840)), width: ow),
        fetch(logoUrl, height: (150 * s).round()),
      ]);
      final backdrop = results[0];
      var logo = results[1];
      if (logo != null && logoUrl != null && await logoNeedsMatte(logoUrl, logo)) logo = null;
      if (_ended || _videoStarted) return;

      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder);
      final full = Rect.fromLTWH(0, 0, ow.toDouble(), oh.toDouble());
      c.drawRect(full, Paint()..color = kBg);
      if (backdrop != null) {
        // cover: fill the window, cropping the middle
        final iw = backdrop.width.toDouble(), ih = backdrop.height.toDouble();
        final scale = (ow / iw) > (oh / ih) ? ow / iw : oh / ih;
        final sw = ow / scale, sh = oh / scale;
        c.drawImageRect(backdrop, Rect.fromLTWH((iw - sw) / 2, (ih - sh) / 2, sw, sh), full,
            Paint()..filterQuality = FilterQuality.medium);
      }
      for (final g in _loadingShades) {
        c.drawRect(
            full,
            Paint()
              ..shader = ui.Gradient.linear(
                  Offset(g.from.dx * ow, g.from.dy * oh), Offset(g.to.dx * ow, g.to.dy * oh), g.colors, g.stops));
      }
      _pictureHasLogo = false;
      if (logo != null) {
        // contain in the 760 x 150 box at (120, 430), bottom left
        final box = Size(760 * s, 150 * s);
        final k = [box.width / logo.width, box.height / logo.height, 1.0].reduce((a, b) => a < b ? a : b);
        final w = logo.width * k, h = logo.height * k;
        c.drawImageRect(logo, Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
            Rect.fromLTWH(120 * s, (430 + 150) * s - h, w, h), Paint()..filterQuality = FilterQuality.medium);
        _pictureHasLogo = true;
      }
      final image = await recorder.endRecording().toImage(ow, oh);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null || _ended || _videoStarted) return; // too late: the video is already on
      // mpv wants blue-green-red-alpha: swap red and blue, four bytes at a time
      final px = data.buffer.asUint32List(data.offsetInBytes, data.lengthInBytes ~/ 4);
      for (var i = 0; i < px.length; i++) {
        final v = px[i];
        px[i] = (v & 0xFF00FF00) | ((v & 0xFF) << 16) | ((v >> 16) & 0xFF);
      }
      final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}frame-logo-$pid.bgra');
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      if (_ended || _videoStarted) return;
      // Marked shown before the command goes out, so a 'loaded' arriving meanwhile still
      // removes it (the removal is sent after the add, and mpv runs them in order).
      _logoShown = true;
      await _mpv.command(['overlay-add', 0, 0, 0, file.path, 0, 'bgra', ow, oh, ow * 4]);
      if (_videoStarted) _removeLogoFromPlayer();
    } catch (e) {
      debugPrint('Player: picture for the loading screen unavailable ($e)');
    } finally {
      if (!_logoShown) _logoFailed = true;
      if (!_ended && !_videoStarted) await _sendInfo(); // picture up, or the title as text instead
    }
  }

  void _removeLogoFromPlayer() {
    if (!_logoShown) return;
    _logoShown = false;
    _logoFailed = true; // the logo was for the first video only
    _mpv.command(['overlay-remove', 0]).then((_) {}, onError: (_) {});
  }

  // ---------- Up next ----------
  //
  // For episodes: near the end a card offers the next one (from where the credits start when
  // the server knows, otherwise 20 s before the end); the next one starts 10 s later. Cross
  // plays it now, Circle hides the card. When the episode ends (or you skip past the end), the next one starts by itself, in
  // the same full screen, without going back to Frame. In a Watch together room, the room
  // moves on together.

  dynamic _next; // the next episode, or null (movies, last episode)
  double? _creditsAt; // seconds
  bool _nextDismissed = false;
  bool _continuing = false; // handing the screen over to the next episode

  Future<void> _findNext() async {
    if (_item['Type'] != 'Episode') return;
    try {
      final results = await Future.wait([
        widget.jf.episodeAfter(_item),
        widget.jf.creditsStart(_id),
      ]).timeout(const Duration(seconds: 4));
      _next = results[0];
      _creditsAt = results[1] as double?;
      if (_next != null) debugPrint('Player: up next is ${episodeLine(_next)}');
      if (!_ended) await _sendInfo();
      if (_next != null) unawaited(_loadNextPicture());
    } catch (e) {
      debugPrint('Player: next episode unknown ($e)');
    }
  }

  // The next episode's picture for the Up next card, downloaded once while this one plays.
  // The player's controls cut a hole in the card and ask for it with 'next_image'.
  Uint8List? _nextPicture;

  Future<void> _loadNextPicture() async {
    final next = _next;
    if (next == null) return;
    try {
      final res = await Jellyfin.client
          .get(Uri.parse(widget.jf.thumbFor(next, maxWidth: 640)))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty || _ended) return;
      _nextPicture = res.bodyBytes;
      await _sendInfo(); // the card now leaves room for it
    } catch (e) {
      debugPrint('Player: no picture for up next ($e)');
    }
  }

  // Pictures the player's controls ask for (Up next = 1, Info = 2), placed in a hole the
  // controls cut for them, since mpv draws pictures underneath its controls.
  final Map<int, String> _picturesShown = {}; // id -> "x,y,w,h" on screen now

  Future<void> _showNextPicture(Map value) => _placePicture(1, _nextPicture, value);

  // x, y, w, h are in the controls' 1920 x 1080 space.
  Future<void> _placePicture(int id, Uint8List? bytes, Map value) async {
    if (value['show'] != true) {
      if (_picturesShown.remove(id) != null) _mpv.command(['overlay-remove', id]).then((_) {}, onError: (_) {});
      return;
    }
    if (bytes == null) return;
    try {
      final d = await _mpv.get('osd-dimensions');
      if (d is! Map) return;
      final ow = ((d['w'] ?? 0) as num).toDouble(), oh = ((d['h'] ?? 0) as num).toDouble();
      if (ow <= 0 || oh <= 0) return;
      // the controls keep 1080 units of height and widen to the window's shape
      final s = oh / 1080;
      final x = ((value['x'] as num) * s).round(), y = ((value['y'] as num) * s).round();
      final w = ((value['w'] as num) * s).round(), h = ((value['h'] as num) * s).round();
      final key = '$x,$y,$w,$h';
      if (_picturesShown[id] == key) return;
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: w, targetHeight: h);
      final image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba); // premultiplied
      if (data == null || _ended) return;
      final px = data.buffer.asUint8List();
      final r = 16 * s; // round corners, like the cards in Frame
      for (var j = 0; j < h; j++) {
        for (var i = 0; i < w; i++) {
          final o = (j * w + i) * 4;
          final t = px[o];
          px[o] = px[o + 2]; // mpv wants blue-green-red-alpha
          px[o + 2] = t;
          final cx = i < r ? r - i : (i >= w - r ? i - (w - 1 - r) : 0.0);
          final cy = j < r ? r - j : (j >= h - r ? j - (h - 1 - r) : 0.0);
          if (cx > 0 && cy > 0 && cx * cx + cy * cy > r * r) {
            px[o] = px[o + 1] = px[o + 2] = px[o + 3] = 0;
          }
        }
      }
      final file = '${Directory.systemTemp.path}${Platform.pathSeparator}frame-pic-$id-$pid.bgra';
      await File(file).writeAsBytes(px, flush: true);
      if (_ended) return;
      _picturesShown[id] = key;
      await _mpv.command(['overlay-add', id, x, y, file, 0, 'bgra', w, h, w * 4]);
    } catch (e) {
      debugPrint('Player: picture $id not shown ($e)');
    }
  }

  // Info (Triangle): this video's picture, downloaded once.
  Uint8List? _infoPicture;

  Future<void> _loadInfoPicture() async {
    try {
      final res = await Jellyfin.client
          .get(Uri.parse(widget.jf.thumbFor(_item, maxWidth: 640)))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty || _ended) return;
      _infoPicture = res.bodyBytes;
      await _sendInfo();
    } catch (e) {
      debugPrint('Player: no picture for Info ($e)');
    }
  }

  /// Info's line under the title: S17 · E19 · 2006 · 22 min (or year · length for a movie).
  String get _aboutLine {
    final parts = <String>[
      if (_item['ParentIndexNumber'] != null) 'S${_item['ParentIndexNumber']}',
      if (_item['IndexNumber'] != null && _item['Type'] == 'Episode') 'E${_item['IndexNumber']}',
      if (_item['ProductionYear'] != null) '${_item['ProductionYear']}',
      if (_item['RunTimeTicks'] is num) '${((_item['RunTimeTicks'] as num) / 600000000).round()} min',
    ];
    return parts.join(' · ');
  }

  // The file reached its end (mpv holds the last picture): next episode, or close.
  void _onEnded() {
    if (_ended || _continuing) return;
    final sync = _sync;
    if (_next != null && !_nextDismissed) {
      // In a room only the one who opened it moves everyone on (so it happens once).
      if (sync == null || sync.isHost) {
        _playNext();
        return;
      }
      _notice('Waiting for the next episode…');
      return;
    }
    _mpv.command(['quit']).then((_) {}, onError: (_) {});
  }

  Future<void> _playNext() async {
    final next = _next;
    if (next == null || _continuing || _ended) return;
    final sync = _sync;
    if (sync != null) {
      // The room's new video reaches everyone (this player too) and each one switches.
      try {
        await sync.play(next['Id'].toString(), 0);
      } catch (e) {
        _notice("Couldn't start the next episode");
      }
      return;
    }
    _continuing = true;
    _ended = true;
    widget.jf.reportStopped(_id, _ticksNow, session: _session);
    final series = _item['SeriesId'];
    if (series != null) widget.jf.forgetShow(series.toString());
    // The next player opens the way this one is (full screen or not); Frame stays hidden.
    fullScreen.value = _mpvFull;
    await _mpv.close();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => NativePlayerScreen(jf: widget.jf, item: next, continued: true)));
  }

  // ---------- Starting ----------

  Future<String> _scriptPath([String name = 'frame_ui.lua']) async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}mpv');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(await rootBundle.loadString('assets/mpv/$name'));
    return file.path;
  }

  // Windows: Frame's two fonts in a folder mpv is pointed at (--osd-fonts-dir), since there's
  // no per-user font folder it reads by itself.
  Future<String?> _fontsDir() async {
    if (!Platform.isWindows) return null;
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}\\fonts');
      await dir.create(recursive: true);
      for (final name in [
        'HankenGrotesk-400.ttf', 'HankenGrotesk-500.ttf', 'HankenGrotesk-600.ttf',
        'HankenGrotesk-700.ttf', 'HankenGrotesk-800.ttf', 'Sora-600.ttf', 'Sora-700.ttf',
      ]) {
        final f = File('${dir.path}\\$name');
        if (await f.exists()) continue;
        final data = await rootBundle.load('assets/fonts/$name');
        await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      return dir.path;
    } catch (e) {
      debugPrint('Player: fonts for mpv could not be prepared: $e');
      return null;
    }
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
    } catch (e) {
      // The server is plainly off (not just slow): say so now, instead of opening the player
      // on a file it can't get.
      if (e.toString() == Jellyfin.unreachable && !await _serverAnswers()) {
        _showUnreachable();
        return;
      }
    }
    await _loadTrackPrefs();

    String url = widget.jf.directStreamUrl(_id);
    final wantServer = _isDisc || _mode == 'server' || (_mode == 'auto' && _level >= _serverStep);
    if (wantServer) {
      _presetServerTracks();
      final server = await _serverStream();
      if (server != null) url = server;
    }

    await _installFonts();
    final fonts = await _fontsDir();
    final script = await _scriptPath();
    final bridge = Platform.isWindows ? await _scriptPath('frame_bridge.lua') : null;
    final window = await _windowArgs();
    final resume = _resumeTicks > 0 ? _resumeTicks / 10000000 : 0.0;
    final args = <String>[
      ...window,
      '--title=Frame',
      // Shown as Frame (not as a separate mpv app) by KDE.
      if (_mpvHasHdr && Platform.isLinux) '--wayland-app-id=frame',
      if (fonts != null) '--osd-fonts-dir=$fonts',
      if (_mpvHasHdr) '--background-color=#06080B',
      '--force-window=immediate',
      // At the end, mpv holds the last picture and Frame decides: next episode, or close.
      '--keep-open=yes',
      // A file that fails to open leaves mpv waiting instead of closing, so Frame can try the
      // server's version of it (see _onLoadFailed). Leaving still closes it as usual.
      '--idle=yes',
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
      // 25 or 23.976 fps on a 60 Hz screen can't be shown evenly (frames would alternate between
      // 2 and 3 refreshes: judder in slow pans). Timing playback to the screen and blending the
      // odd frame keeps motion even; it costs very little. Turned off again on a device that
      // struggles (see "Adapting to this device").
      '--video-sync=display-resample',
      '--interpolation=yes',
      '--tscale=oversample',
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
      // Resume points (and switching to the server's version) land exactly; skips stay quick, on
      // the nearest keyframe.
      '--hr-seek=absolute',
      // TV recordings and DVDs are often interlaced (combing on movement): mpv 0.38+ smooths
      // only the frames marked interlaced and leaves everything else untouched.
      if (_mpvVersion >= 0.38) '--deinterlace=auto',
      '--sub-ass-override=scale',
      '--script=$script',
      if (resume > 0) '--start=${resume.toStringAsFixed(1)}',
      url,
    ];
    if (!mounted) return; // closed while getting ready
    try {
      await _mpv.start(_mpvPath!, args, bridgeScript: bridge);
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
    _mpv.observe(7, 'duration');
    _mpv.observe(8, 'eof-reached');
    if (widget.sync != null) {
      _mpv.observe(6, 'paused-for-cache');
      _startTogether();
    }
    unawaited(_findNext());
    unawaited(_loadInfoPicture());
    unawaited(_handOff());
    unawaited(_showLogoInPlayer());
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
        _addExternalSubs().whenComplete(_applyTrackPrefs);
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
  // In full screen, Frame simply stays where it is, under the player, showing the same loading
  // screen the player opens on: no minimize and restore animations, so starting and leaving a
  // video feels like part of the app. In a window (where the player can't be placed exactly
  // over Frame) Frame steps aside as before.
  bool _underneath = false;

  Future<void> _handOff() async {
    await Future.delayed(const Duration(milliseconds: 500));
    if (_ended || !mounted) return;
    PerfRecorder.hidden = true; // covered either way
    if (fullScreen.value) {
      _underneath = true;
      return;
    }
    try {
      await windowManager.hide();
      _handedOff = true;
    } catch (_) {}
  }

  // When the video ends or you go back, Frame comes back the way you left the player: if you
  // switched the player to full screen, Frame is full screen too, and the other way round.
  Future<void> _takeBack() async {
    if (_underneath && !_continuing) {
      _underneath = false;
      PerfRecorder.hidden = false;
      try {
        await windowManager.focus();
        if (_mpvFull != fullScreen.value) await setFullScreen(_mpvFull);
      } catch (_) {}
      return;
    }
    if (!_handedOff || _continuing) return;
    _handedOff = false;
    PerfRecorder.hidden = false;
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
          // (ignored while a video is ending: the player leaves full screen as its window
          // closes, which isn't a choice to carry back to Frame)
          if (data is bool && !_fileEnding) _mpvFull = data;
        case 'paused-for-cache':
          if (data is bool) _onStall(data);
        case 'duration':
          if (data is num) _duration = data.toDouble();
        case 'eof-reached':
          if (data == true) _onEnded();
        case 'user-data/frame/request':
          if (data is Map) _onRequest(data);
      }
    } else if (e['event'] == 'end-file' || e['event'] == 'shutdown') {
      _fileEnding = true;
      if (e['event'] == 'end-file' && e['reason'] == 'error') _onLoadFailed(e['file_error']?.toString());
    } else if (e['event'] == 'seek') {
      _lastSeek = DateTime.now();
    } else if (e['event'] == 'playback-restart') {
      // The video is on screen. Normally the player asks for the logo to go ('loaded'); this
      // is the backup, after its fade, so the logo can never stay over the video.
      if (!_videoStarted) {
        Timer(const Duration(milliseconds: 700), () {
          _videoStarted = true;
          _removeLogoFromPlayer();
        });
      }
    } else if (e['event'] == 'file-loaded') {
      _fileEnding = false;
      _loadedSeen = true;
      Timer(const Duration(seconds: 2), () {
        if (!_ended) _logPlayback('opened');
      });
      if (_server) {
        // The server's stream carries no text subtitles: add the chosen one now.
        final text = _serverTextSub;
        if (text != null) _showServerTextSub(text);
      } else {
        _addExternalSubs().whenComplete(_applyTrackPrefs);
      }
      _link?.ready();
    }
  }

  // Subtitles kept as separate files next to the video (movie.fr.srt, .ass, .vtt, .sup): the
  // original file doesn't contain them, so they're added to the player from the server.
  bool _externalSubsAdded = false;

  Future<void> _addExternalSubs() async {
    if (_externalSubsAdded || _server) return;
    _externalSubsAdded = true;
    const ext = {'subrip': 'srt', 'srt': 'srt', 'ass': 'ass', 'ssa': 'ssa', 'webvtt': 'vtt', 'vtt': 'vtt', 'pgssub': 'sup', 'sup': 'sup'};
    for (final s in _streams('Subtitle').where((s) => s['IsExternal'] == true)) {
      final format = ext[(s['Codec'] ?? '').toString().toLowerCase()];
      final index = s['Index'];
      if (format == null || index is! int) continue; // (an .idx/.sub pair needs both files: not supported)
      final url = widget.jf.externalSubtitleUrl(_id, index, format);
      final title = (s['Title'] ?? s['DisplayTitle'] ?? '').toString();
      final lang = (s['Language'] ?? '').toString();
      try {
        await _mpv.command(['sub-add', url, 'auto', title, lang]);
      } catch (e) {
        debugPrint('Player: subtitle file ${s['DisplayTitle']} could not be added: $e');
      }
    }
  }

  // The original file wouldn't open (a format the player can't read from a stream, a disc
  // image, a damaged file): try the server's version once, from the same moment. If that
  // fails too, say so plainly.
  Future<void> _onLoadFailed(String? why) async {
    if (_ended) return;
    if (_videoStarted) {
      // It played, then broke off (the connection dropped for good): close as before, rather
      // than leave the player waiting on a black screen.
      perfLog('mpv stopped with an error during playback (${why ?? 'unknown error'})');
      unawaited(_mpv.close());
      return;
    }
    // The server itself is gone (NAS off, network down): no point asking it for its version.
    if (!await _serverAnswers()) {
      perfLog('mpv could not open the video: the server is not answering');
      _ended = true;
      _showUnreachable();
      unawaited(_mpv.close());
      return;
    }
    if (!_server && !_triedServer) {
      _triedServer = true;
      perfLog('mpv could not open the original (${why ?? 'unknown error'}): trying the server version');
      _presetServerTracks();
      await _reopen(server: true, at: _pos > 0 ? _pos : (_resumeTicks > 0 ? _resumeTicks / 10000000 : 0));
      if (_server) return;
    }
    perfLog('mpv could not open ${_server ? 'the server version' : 'the original'} (${why ?? 'unknown error'})');
    _ended = true;
    if (mounted) {
      setState(() => _error = "The file wouldn't open${why != null ? ' ($why)' : ''}, "
          "and the server couldn't provide a playable version either.");
    }
    unawaited(_mpv.close());
  }

  /// A quick "are you there?" to the server (its public info), 3 seconds at most.
  Future<bool> _serverAnswers() async {
    try {
      await widget.jf.publicInfo().timeout(const Duration(seconds: 3));
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _unreachable = false; // the error is "server off": offer Retry

  void _showUnreachable() {
    _ended = true;
    if (!mounted) return;
    setState(() {
      _unreachable = true;
      _error = Jellyfin.unreachable;
    });
  }

  // Retry after the server was off: the same video, opened afresh.
  void _retry() {
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => NativePlayerScreen(
          jf: widget.jf, item: widget.item, sync: widget.sync, playlistItemId: widget.playlistItemId, startTicks: widget.startTicks),
    ));
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
      case 'next':
        // The card's countdown ran out: in a room, only the one who opened it moves everyone
        // on (pressing Play now still works for anyone).
        final room = _sync;
        if (value == 'auto' && room != null && !room.isHost) return;
        await _playNext();
        return;
      case 'next_image':
        if (value is Map) await _showNextPicture(value);
        return;
      case 'info_image':
        if (value is Map) await _placePicture(2, _infoPicture, value);
        return;
      case 'loaded':
        _videoStarted = true;
        _removeLogoFromPlayer(); // the loading screen fades into the video
        return;
      case 'next_dismiss':
        _nextDismissed = true;
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
      'logo': _logoShown && _pictureHasLogo,
      'backdrop': _logoShown,
      'logo_coming': !_logoFailed && widget.jf.logoFor(_item) != null,
      'loading_line': _loadingLine,
      'loading_chips': _loadingChips,
      'loading_status': _loadingStatus,
      // Info (Triangle)
      'about_title': (_item['Type'] == 'Episode' ? _item['Name'] : titleOf(_item))?.toString() ?? '',
      'about_line': _aboutLine,
      'overview': (_item['Overview'] ?? '').toString(),
      'info_thumb': _infoPicture != null,
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
      // Up next: what, and from when (the credits, or 20 s before the end).
      if (_next != null && !_nextDismissed)
        'next': {
          'title': episodeLine(_next),
          'name': (_next['Name'] ?? '').toString(),
          'line': [
            if (_next['ParentIndexNumber'] != null) 'S${_next['ParentIndexNumber']}',
            if (_next['IndexNumber'] != null) 'E${_next['IndexNumber']}',
          ].join(' · '),
          if (_next['IndexNumber'] != null) 'number': 'E${_next['IndexNumber']}',
          if (_next['RunTimeTicks'] is num) 'minutes': ((_next['RunTimeTicks'] as num) / 600000000).round(),
          'thumb': _nextPicture != null,
          if (_creditsAt != null) 'at': _creditsAt, // otherwise the controls use 20 s before the end
        },
      // Your profile colour for the panels' line (mpv writes colours blue-green-red).
      'accent': [kAccent.blue, kAccent.green, kAccent.red].map((c) => c.toRadixString(16).padLeft(2, '0')).join().toUpperCase(),
      'sub_scale': _subScale,
      'sub_pos': _subPos,
      'sub_box': _subBox,
    });
  }

  // ---------- The controller, the legend ----------

  // Kept in a property (not a one-off message), so the controls pick it up even when they
  // load after Frame has sent it: the legend no longer goes missing on some videos.
  void _sendPad() {
    final style = !padActive.value ? 'none' : (padStyle.value == PadStyle.playstation ? 'ps' : 'xbox');
    _mpv.set('user-data/frame/pad', style);
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
      _continuing = true; // straight into the next video, without showing Frame in between
      fullScreen.value = _mpvFull;
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
  Future<void> _reopen({required bool server, double? at}) async {
    if (_switching) return;
    _switching = true;
    at ??= _pos;
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
      _externalSubsAdded = false; // the new stream needs them again (original only)
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
      'interpolation': false,
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
      hints: _error != null
          ? const [PadHint(PadButton.select, 'Select'), PadHint(PadButton.back, 'Back')]
          : const [PadHint(PadButton.back, 'Cancel')],
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: kBg,
          body: TvCanvas(child: _error != null ? _errorView() : _loadingView()),
        ),
      ),
    );
  }

  // Play pressed: like starting a game on PS5, the artwork full screen with the logo bottom
  // left, the episode line, chips, a running line and where it starts. The player opens on the
  // same screen (frame_ui.lua draws it at the same places), so the switch can't be seen.
  Widget _loadingView() {
    final logo = widget.jf.logoFor(_item);
    final title = Text(titleOf(_item), style: tvDisplay(84), maxLines: 1, overflow: TextOverflow.ellipsis);
    final line = _loadingLine;
    final now = DateTime.now();
    final clock = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return Stack(children: [
      Positioned.fill(
        child: netImage(
          widget.jf.backdropFor(_item, maxWidth: sizeBucket(tvPx(1920)).clamp(1280, 2560)),
          cacheWidth: sizeBucket(tvPx(1920)).clamp(1280, 2560),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ),
      for (final g in _loadingShades)
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(g.from.dx * 2 - 1, g.from.dy * 2 - 1),
                end: Alignment(g.to.dx * 2 - 1, g.to.dy * 2 - 1),
                colors: g.colors,
                stops: g.stops,
              ),
            ),
          ),
        ),
      Positioned(right: 56, top: 48, child: Text(clock, style: tvBody(26, weight: FontWeight.w600, color: kSoft))),
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
        Positioned(left: 120, top: 604, right: 120, child: Text(line, maxLines: 1, style: tvBody(28, color: kSoft))),
      Positioned(
        left: 120,
        top: 660,
        child: Row(children: [
          for (final chip in _loadingChips)
            Container(
              height: 40,
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: kFg.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
              child: Text(chip, style: tvBody(19, weight: FontWeight.w600)),
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
          child: LinearProgressIndicator(backgroundColor: kFg.withOpacity(0.16), color: kFg),
        ),
      ),
      Positioned(left: 120, top: 764, child: Text(_loadingStatus, style: tvBody(21, color: kMuted))),
    ]);
  }

  // Something went wrong: a centred card (like the other new menus) over the faded artwork of
  // what you tried to play, so you know what failed. Retry when the server was out of reach.
  Widget _errorView() {
    final title = _unreachable ? "Can't reach your Jellyfin server" : "This video couldn't be played";
    final what = [titleOf(_item), episodeLine(_item)].where((x) => x.isNotEmpty).join(' · ');
    final body = _unreachable
        ? 'Check that the NAS is on and connected, then try again.${what.isEmpty ? '' : ' $what will start where you left off.'}'
        : _error!;
    Widget pill(String label, IconData icon, VoidCallback onSelect, {bool autofocus = false}) => Focusable(
          autofocus: autofocus,
          onSelect: onSelect,
          builder: (f) => AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 68,
            padding: const EdgeInsets.fromLTRB(26, 0, 34, 0),
            decoration: BoxDecoration(
              color: f ? kFg : kFg.withOpacity(0.08),
              borderRadius: BorderRadius.circular(999),
              boxShadow: f
                  ? const [BoxShadow(color: Color(0xFF12151B), spreadRadius: 4), BoxShadow(color: kFg, spreadRadius: 9)]
                  : const [],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 28, color: f ? kBg : kFg),
              const SizedBox(width: 12),
              Text(label, style: tvBody(26, weight: f ? FontWeight.w700 : FontWeight.w600, color: f ? kBg : kFg)),
            ]),
          ),
        );
    final art = sizeBucket(tvPx(1920)).clamp(1280, 2560);
    return Stack(children: [
      Positioned.fill(
        child: netImage(widget.jf.backdropFor(_item, maxWidth: art),
            cacheWidth: art, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
      ),
      Positioned.fill(child: ColoredBox(color: kBg.withOpacity(0.78))),
      Center(
        child: Container(
          width: 860,
          padding: const EdgeInsets.all(56),
          decoration: BoxDecoration(
            color: const Color(0xF712151B),
            borderRadius: BorderRadius.circular(36),
            border: Border.all(color: kFg.withOpacity(0.08)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(shape: BoxShape.circle, color: kFg.withOpacity(0.08)),
              child: Icon(_unreachable ? Icons.cloud_off_rounded : Icons.error_outline_rounded, size: 48, color: kFg),
            ),
            const SizedBox(height: 26),
            Text(title, textAlign: TextAlign.center, style: tvDisplay(44)),
            const SizedBox(height: 18),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 660),
              child: Text(body, textAlign: TextAlign.center, style: tvBody(26, color: kSoft, height: 1.45)),
            ),
            const SizedBox(height: 36),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (_unreachable) ...[
                pill('Retry', Icons.refresh_rounded, _retry, autofocus: true),
                const SizedBox(width: 16),
              ],
              pill('Back', Icons.arrow_back_rounded, () => Navigator.of(context).maybePop(), autofocus: !_unreachable),
            ]),
          ]),
        ),
      ),
    ]);
  }
}
