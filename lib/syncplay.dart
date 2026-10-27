// Watch together, built on Jellyfin's own SyncPlay, so a Frame user and someone on the
// Jellyfin website or app can share the same room.
//
// How it works: rooms ("groups") live on the Jellyfin server. Everyone asks the server to
// play, pause or seek; the server tells everyone what to do and exactly when (in server time),
// so the pictures stay together. Frame keeps a clock offset to the server (like NTP) to act at
// the right moment, and gently nudges its speed to stay in step (see native_player.dart).
//
// Frame adds what Jellyfin's version lacks: a Watch together button next to Play, rooms you
// can see and join from Home, who's in the room on screen, and notes like "Bob paused".

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'banners.dart';
import 'gamepad.dart' show PadHint, PadButton, PadHints;
import 'main.dart' show Jellyfin;
import 'native_player.dart' show playerScreen;
import 'ui.dart';

class SyncGroup {
  SyncGroup({required this.id, required this.name, required this.people, required this.state});
  final String id;
  final String name;
  final List<String> people; // user names
  final String state; // Idle | Waiting | Paused | Playing
  SyncGroup copyWith({List<String>? people, String? state}) =>
      SyncGroup(id: id, name: name, people: people ?? this.people, state: state ?? this.state);
}

/// Reads Jellyfin's dates (which can have 7 decimals) as UTC.
DateTime parseServerTime(String s) {
  final m = RegExp(r'^(.*?\.\d{1,6})\d*(Z|[+-]\d\d:?\d\d)?$').firstMatch(s);
  final t = m == null ? s : '${m.group(1)}${m.group(2) ?? 'Z'}';
  return DateTime.parse(t).toUtc();
}

class SyncPlay {
  SyncPlay._(this.jf);
  final Jellyfin jf;

  static final Map<String, SyncPlay> _all = {};
  static SyncPlay of(Jellyfin jf) => _all.putIfAbsent('${jf.server}|${jf.userId}', () => SyncPlay._(jf));

  WebSocket? _ws;
  StreamSubscription? _sub;
  Timer? _keepAlive;
  Timer? _clock;
  Future<void>? _connecting;
  Duration _offset = Duration.zero; // server clock minus this PC's clock
  int _rttMs = 0;

  final ValueNotifier<SyncGroup?> group = ValueNotifier(null);
  Map<String, dynamic>? queue; // the room's play queue (what's playing)
  final _commands = StreamController<Map<String, dynamic>>.broadcast();
  final _updates = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get commands => _commands.stream;
  Stream<Map<String, dynamic>> get updates => _updates.stream;

  /// When this PC asked for play/pause/seek last (to tell your own actions from others').
  DateTime lastOwnRequest = DateTime(0);

  DateTime serverNow() => DateTime.now().toUtc().add(_offset);
  DateTime localTimeOf(DateTime serverTime) => serverTime.subtract(_offset);
  String _now() => serverNow().toIso8601String();

  // ---------- Live connection ----------

  Future<void> connect() => _connecting ??= _connect().whenComplete(() => _connecting = null);

  Future<void> _connect() async {
    if (_ws != null) return;
    final base = Uri.parse(jf.server);
    // The sign-in goes in the address as well as the header, the way Jellyfin's own website
    // connects (some servers only accept it there for this connection).
    final url = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/socket',
      queryParameters: {'ApiKey': jf.token ?? '', 'deviceId': Jellyfin.deviceId},
    );
    WebSocket ws;
    try {
      ws = await WebSocket.connect(url.toString(), headers: {'Authorization': jf.authHeaders['Authorization']!})
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Together: live connection failed: $e');
      throw "Couldn't open the live connection to the server, so rooms can't stay in sync.";
    }
    _ws = ws;
    _sub = ws.listen(_onMessage, onDone: _closed, onError: (_) => _closed(), cancelOnError: true);
    _keepAlive = Timer.periodic(const Duration(seconds: 30), (_) => _send({'MessageType': 'KeepAlive'}));
    await syncClock();
    _clock = Timer.periodic(const Duration(seconds: 60), (_) => syncClock());
    debugPrint('Together: connected (clock ${_offset.inMilliseconds} ms off, ${_rttMs} ms round trip)');
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  void _closed() {
    _keepAlive?.cancel();
    _clock?.cancel();
    _sub?.cancel();
    _ws = null;
    // Still in a room: reconnect, so the room's commands keep arriving.
    if (group.value != null) {
      Timer(const Duration(seconds: 2), () {
        if (group.value != null) connect().then((_) {}, onError: (_) {});
      });
    }
  }

  /// Measures the clock difference with the server a few times and keeps the most precise one.
  Future<void> syncClock() async {
    Duration? best;
    var bestRtt = 1 << 30;
    for (var i = 0; i < 5; i++) {
      try {
        final t0 = DateTime.now().toUtc();
        final r = await jf.getPath('/GetUtcTime');
        final t3 = DateTime.now().toUtc();
        final t1 = parseServerTime(r['RequestReceptionTime'].toString());
        final t2 = parseServerTime(r['ResponseTransmissionTime'].toString());
        final rtt = t3.difference(t0).inMicroseconds - t2.difference(t1).inMicroseconds;
        if (rtt < bestRtt) {
          bestRtt = rtt;
          best = Duration(microseconds: (t1.difference(t0).inMicroseconds + t2.difference(t3).inMicroseconds) ~/ 2);
        }
      } catch (_) {}
    }
    if (best != null) {
      _offset = best;
      _rttMs = bestRtt ~/ 1000;
      if (group.value != null) jf.postPath('/SyncPlay/Ping', {'Ping': _rttMs}).then((_) {}, onError: (_) {});
    }
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (m['MessageType']) {
      case 'ForceKeepAlive':
        _send({'MessageType': 'KeepAlive'});
      case 'SyncPlayCommand':
        final d = m['Data'];
        if (d is Map) _commands.add(d.cast<String, dynamic>());
      case 'SyncPlayGroupUpdate':
        final d = m['Data'];
        if (d is Map) _onUpdate(d.cast<String, dynamic>());
    }
  }

  void _onUpdate(Map<String, dynamic> u) {
    final data = u['Data'];
    final g = group.value;
    switch (u['Type']) {
      case 'GroupJoined':
        if (data is Map) {
          group.value = SyncGroup(
            id: (data['GroupId'] ?? u['GroupId']).toString(),
            name: (data['GroupName'] ?? 'Watch together').toString(),
            people: [for (final p in (data['Participants'] as List? ?? [])) p.toString()],
            state: (data['State'] ?? 'Idle').toString(),
          );
        }
      case 'UserJoined':
        if (g != null && data != null) group.value = g.copyWith(people: [...g.people, data.toString()]);
      case 'UserLeft':
        if (g != null && data != null) {
          final people = [...g.people];
          people.remove(data.toString());
          group.value = g.copyWith(people: people);
        }
      case 'StateUpdate':
        if (g != null && data is Map) group.value = g.copyWith(state: (data['State'] ?? g.state).toString());
      case 'PlayQueue':
        if (data is Map) queue = data.cast<String, dynamic>();
      case 'GroupLeft':
      case 'NotInGroup':
      case 'GroupDoesNotExist':
        group.value = null;
        queue = null;
    }
    debugPrint('Together: ${u['Type']}');
    _updates.add(u);
  }

  // ---------- Rooms ----------

  Future<List<dynamic>> list() async => (await jf.getPath('/SyncPlay/List') as List?) ?? const [];

  Future<void> _awaitGroup() async {
    if (group.value != null) return;
    final c = Completer<void>();
    void check() {
      if (group.value != null && !c.isCompleted) c.complete();
    }

    group.addListener(check);
    try {
      await c.future.timeout(const Duration(seconds: 8), onTimeout: () => throw "The server didn't open the room.");
    } finally {
      group.removeListener(check);
    }
  }

  Future<void> create(String name) async {
    await connect();
    await jf.postPath('/SyncPlay/New', {'GroupName': name});
    await _awaitGroup();
  }

  Future<void> join(String groupId) async {
    await connect();
    await jf.postPath('/SyncPlay/Join', {'GroupId': groupId});
    await _awaitGroup();
  }

  Future<void> leave() async {
    if (group.value == null) return;
    group.value = null;
    queue = null;
    try {
      await jf.postPath('/SyncPlay/Leave');
    } catch (_) {}
  }

  /// What the room plays now: (item, its place in the room's list, where to start).
  ({String itemId, String playlistItemId, int startTicks, bool playing})? get nowPlaying {
    final q = queue;
    if (q == null) return null;
    final list = (q['Playlist'] as List?) ?? const [];
    final i = (q['PlayingItemIndex'] ?? 0) as int;
    if (i < 0 || i >= list.length) return null;
    return (
      itemId: list[i]['ItemId'].toString(),
      playlistItemId: list[i]['PlaylistItemId'].toString(),
      startTicks: (q['StartPositionTicks'] ?? 0) as int,
      playing: q['IsPlaying'] == true,
    );
  }

  Future<void> awaitQueue({Duration timeout = const Duration(seconds: 10)}) async {
    if (nowPlaying != null) return;
    await updates
        .firstWhere((u) => u['Type'] == 'PlayQueue' && nowPlaying != null)
        .timeout(timeout, onTimeout: () => throw 'Nothing is playing in this room yet.');
  }

  Future<void> play(String itemId, int startTicks) async {
    queue = null;
    await jf.postPath('/SyncPlay/SetNewQueue', {
      'PlayingQueue': [itemId],
      'PlayingItemPosition': 0,
      'StartPositionTicks': startTicks,
    });
    await awaitQueue();
  }

  // ---------- Playback requests (the server answers with commands for everyone) ----------

  Future<void> pause() {
    lastOwnRequest = DateTime.now();
    return jf.postPath('/SyncPlay/Pause').then((_) {}, onError: (e) => debugPrint('Together: pause failed: $e'));
  }

  Future<void> unpause() {
    lastOwnRequest = DateTime.now();
    return jf.postPath('/SyncPlay/Unpause').then((_) {}, onError: (e) => debugPrint('Together: play failed: $e'));
  }

  Future<void> seek(int ticks) {
    lastOwnRequest = DateTime.now();
    return jf
        .postPath('/SyncPlay/Seek', {'PositionTicks': ticks})
        .then((_) {}, onError: (e) => debugPrint('Together: seek failed: $e'));
  }

  Future<void> buffering(int ticks, bool playing, String playlistItemId) => jf.postPath('/SyncPlay/Buffering', {
        'When': _now(),
        'PositionTicks': ticks,
        'IsPlaying': playing,
        'PlaylistItemId': playlistItemId,
      }).then((_) {}, onError: (_) {});

  Future<void> ready(int ticks, bool playing, String playlistItemId) => jf.postPath('/SyncPlay/Ready', {
        'When': _now(),
        'PositionTicks': ticks,
        'IsPlaying': playing,
        'PlaylistItemId': playlistItemId,
      }).then((_) {}, onError: (_) {});
}

// ---------- Starting and joining ----------

String _friendly(Object e) {
  final t = errorText(e);
  if (t.contains('Not allowed')) {
    return "Watch together isn't allowed for this profile. In Jellyfin: Dashboard › Users › your profile › SyncPlay access.";
  }
  return t;
}

void _toast(BuildContext context, String text, {bool problem = false}) => showBanner(
      context,
      picture: bannerIcon(problem ? Icons.error_outline_rounded : Icons.groups_rounded,
          color: problem ? const Color(0xFFF0A23B) : kFg),
      who: problem ? "Couldn't watch together" : 'Watch together',
      text: text,
      line: problem ? const Color(0xFFF0A23B) : kFg,
      duration: Duration(seconds: problem ? 7 : 3),
    );

/// Watch together from a title: opens a room named after it, starts it at your resume point,
/// and plays it. Others see the room on their Home (Frame) or in Jellyfin's SyncPlay menu.
Future<void> startWatchTogether(BuildContext context, Jellyfin jf, dynamic item) async {
  if (item == null) return;
  final sync = SyncPlay.of(jf);
  _toast(context, 'Opening a room…');
  try {
    await sync.leave();
    final title = item['Type'] == 'Episode'
        ? '${item['SeriesName'] ?? ''} S${item['ParentIndexNumber'] ?? '?'} E${item['IndexNumber'] ?? '?'}'
        : (item['Name'] ?? 'a movie').toString();
    await sync.create('${jf.userName ?? 'Frame'} · $title');
    final resume = (item['UserData']?['PlaybackPositionTicks'] ?? 0) as int;
    await sync.play(item['Id'].toString(), resume);
    if (!context.mounted) return;
    await _openRoomPlayer(context, jf, sync);
  } catch (e) {
    await sync.leave();
    if (context.mounted) _toast(context, _friendly(e), problem: true);
  }
}

Future<void> joinWatchTogether(BuildContext context, Jellyfin jf, String groupId) async {
  final sync = SyncPlay.of(jf);
  _toast(context, 'Joining…');
  try {
    if (sync.group.value?.id != groupId) {
      await sync.leave();
      await sync.join(groupId);
    }
    await sync.awaitQueue(timeout: const Duration(seconds: 15));
    if (!context.mounted) return;
    await _openRoomPlayer(context, jf, sync);
  } catch (e) {
    await sync.leave();
    if (context.mounted) _toast(context, _friendly(e), problem: true);
  }
}

Future<void> _openRoomPlayer(BuildContext context, Jellyfin jf, SyncPlay sync) async {
  final now = sync.nowPlaying;
  if (now == null) return;
  final item = await jf.item(now.itemId, fresh: true);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => playerScreen(jf, item, sync: sync, playlistItemId: now.playlistItemId, startTicks: now.startTicks),
  ));
}

// ---------- On Home: rooms open right now ----------

/// A quiet pill next to your profile, only while someone has a room open on this server.
class TogetherPill extends StatefulWidget {
  const TogetherPill({super.key, required this.jf, this.focusNode});
  final Jellyfin jf;
  final FocusNode? focusNode;

  @override
  State<TogetherPill> createState() => _TogetherPillState();
}

class _TogetherPillState extends State<TogetherPill> {
  List<dynamic> _rooms = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // Rooms already offered on this server, so each invite shows once.
  static final Set<String> _invited = {};

  Future<void> _refresh() async {
    try {
      final rooms = await SyncPlay.of(widget.jf).list();
      if (!mounted) return;
      setState(() => _rooms = rooms);
      _maybeInvite(rooms);
    } catch (_) {
      // No SyncPlay access, or the server is unreachable: show nothing.
      if (mounted && _rooms.isNotEmpty) setState(() => _rooms = []);
    }
  }

  // Someone opened a room (in Frame or in Jellyfin): invite card on Home, once per room.
  void _maybeInvite(List<dynamic> rooms) {
    final me = widget.jf.userName;
    for (final r in rooms) {
      final id = '${widget.jf.server}|${r['GroupId']}';
      final people = ((r['Participants'] as List?) ?? []).map((p) => p.toString()).toList();
      if (_invited.contains(id)) continue;
      _invited.add(id);
      if (people.contains(me) || SyncPlay.of(widget.jf).group.value != null) continue;
      // Only while Home is what you're looking at (not during a video or another page).
      if (ModalRoute.of(context)?.isCurrent != true) continue;
      showInvite(context, widget.jf, r);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_rooms.isEmpty) return const SizedBox.shrink();
    final people = <String>{for (final r in _rooms) ...((r['Participants'] as List?) ?? []).map((p) => p.toString())};
    final label = _rooms.length == 1
        ? '${people.isEmpty ? 'Someone' : people.first} is watching'
        : '${_rooms.length} rooms open';
    return Padding(
      padding: const EdgeInsets.only(right: 18),
      child: Focusable(
        focusNode: widget.focusNode,
        onSelect: () => showRooms(context, widget.jf, _rooms),
        builder: (f) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: f ? kFg : kPillFill,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF5FD08A)),
            ),
            const SizedBox(width: 12),
            Text(label, style: tvBody(20, weight: FontWeight.w700, color: f ? kBg : kFg)),
            const SizedBox(width: 10),
            Text('Join', style: tvBody(20, weight: FontWeight.w600, color: f ? kBg.withOpacity(0.7) : kMuted)),
          ]),
        ),
      ),
    );
  }
}

/// The rooms open on this server, to join one.
Future<void> showRooms(BuildContext context, Jellyfin jf, List<dynamic> rooms) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: const Color(0x8C06080B),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, __) => _Rooms(jf: jf, rooms: rooms, home: context),
    transitionBuilder: (ctx, a, _, child) =>
        FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOut), child: child),
  );
}

class _Rooms extends StatelessWidget {
  const _Rooms({required this.jf, required this.rooms, required this.home});
  final Jellyfin jf;
  final List<dynamic> rooms;
  final BuildContext home; // the screen behind, which opens the player

  @override
  Widget build(BuildContext context) {
    return PadHints(
      hints: const [PadHint(PadButton.select, 'Join'), PadHint(PadButton.back, 'Close')],
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TvCanvas(
          child: Stack(children: [
            Positioned(
              right: 120,
              top: 128,
              child: Material(
                type: MaterialType.transparency,
                child: Surface(
                  width: 600,
                  padding: const EdgeInsets.all(18),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      child: Text('Watching together now', style: tvDisplay(30)),
                    ),
                    for (var i = 0; i < rooms.length; i++)
                      Focusable(
                        autofocus: i == 0,
                        onSelect: () {
                          Navigator.of(context).pop();
                          joinWatchTogether(home, jf, rooms[i]['GroupId'].toString());
                        },
                        builder: (f) {
                          final people = ((rooms[i]['Participants'] as List?) ?? []).map((p) => p.toString()).toList();
                          final state = (rooms[i]['State'] ?? '').toString();
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
                            margin: const EdgeInsets.only(top: 8),
                            decoration: BoxDecoration(
                                color: f ? kFg : kFg.withOpacity(0.08), borderRadius: BorderRadius.circular(40)),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text((rooms[i]['GroupName'] ?? 'Room').toString(),
                                  style: tvBody(24, weight: FontWeight.w700, color: f ? kBg : kFg)),
                              const SizedBox(height: 4),
                              Text(
                                  '${people.join(', ')}${state.isEmpty ? '' : '  ·  ${state == 'Playing' ? 'playing' : state == 'Paused' ? 'paused' : 'getting ready'}'}',
                                  style: tvBody(19, color: f ? kBg.withOpacity(0.7) : kMuted)),
                            ]),
                          );
                        },
                      ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The "Watch together" button next to Play.
Widget watchTogetherButton(bool focused) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: 64,
      padding: const EdgeInsets.only(left: 24, right: 30),
      decoration: BoxDecoration(
        color: focused ? kFg : kPillFill,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.groups_rounded, size: 30, color: focused ? kBg : kFg),
        const SizedBox(width: 12),
        Text('Watch together', style: tvBody(24, weight: FontWeight.w600, color: focused ? kBg : kFg)),
      ]),
    );

// ---------- Invite card ----------

/// A card that slides in at the top left: who started watching what, with Join. It closes
/// by itself after a few seconds; Circle / Back dismisses it.
void showInvite(BuildContext context, Jellyfin jf, dynamic room) {
  final people = ((room['Participants'] as List?) ?? []).map((p) => p.toString()).toList();
  final who = people.isEmpty ? 'Someone' : people.first;
  // Room names from Frame read "Name · Title": show the title part.
  final name = (room['GroupName'] ?? '').toString();
  final what = name.contains(' · ') ? name.substring(name.indexOf(' · ') + 3) : name;
  final (a, b) = _accentOf(who);
  showBanner(
    context,
    picture: bannerInitial(who, a, b),
    who: who,
    text: what.isEmpty ? 'Started watching together' : 'Started watching $what',
    line: a,
    action: 'Join',
    onAction: () => joinWatchTogether(context, jf, room['GroupId'].toString()),
    duration: const Duration(seconds: 12),
  );
}

// Same colours as profile avatars, chosen from the name (rooms list people by name).
(Color, Color) _accentOf(String name) {
  const accents = [
    (Color(0xFF6F8CFF), Color(0xFF3A4FB8)),
    (Color(0xFFEE6E90), Color(0xFFA3324F)),
    (Color(0xFF4FD1AE), Color(0xFF237A64)),
    (Color(0xFFF2B05A), Color(0xFFA9661B)),
    (Color(0xFFA884F5), Color(0xFF5B3BB0)),
    (Color(0xFF5FC2EE), Color(0xFF2370A0)),
  ];
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return accents[h % accents.length];
}


// ---------- Following a room, for any player ----------
//
// The same rules as the mpv window player (native_player.dart), for Frame's built-in player
// (used on Windows, and wherever the mpv window isn't available): your play, pause and seek
// go to the room; the room's commands are carried out at the exact moment on the server's
// clock; small drift is closed by playing up to 5% faster or slower.

typedef RoomVideo = ({String itemId, String playlistItemId, int startTicks, bool playing});

class RoomFollower {
  RoomFollower({
    required this.sync,
    required this.playlistItemId,
    required this.itemId,
    required this.myName,
    required this.position,
    required this.isPaused,
    required this.seekTo,
    required this.setPaused,
    required this.setSpeed,
    required this.notice,
    required this.onStop,
    required this.onNewVideo,
  });

  final SyncPlay sync;
  final String playlistItemId;
  final String itemId;
  final String? myName;
  final double Function() position; // seconds
  final bool Function() isPaused;
  final Future<void> Function(double seconds) seekTo;
  final Future<void> Function(bool paused) setPaused;
  final Future<void> Function(double speed) setSpeed;
  final void Function(String text) notice;
  final VoidCallback onStop;
  final void Function(RoomVideo now) onNewVideo;

  StreamSubscription? _commands;
  StreamSubscription? _updates;
  Timer? _drift;
  Timer? _scheduled;
  ({DateTime when, double pos})? _expected;
  bool _nudged = false;
  bool _done = false;
  bool handingOver = false;

  int get _ticks => (position() * 10000000).round();

  void start() {
    _commands = sync.commands.listen(_onCommand);
    _updates = sync.updates.listen(_onUpdate);
    _drift = Timer.periodic(const Duration(seconds: 1), (_) => _keepInStep());
  }

  void dispose() {
    _done = true;
    _commands?.cancel();
    _updates?.cancel();
    _drift?.cancel();
    _scheduled?.cancel();
    if (!handingOver) sync.leave();
  }

  // ----- what you do -----

  void togglePause() => isPaused() ? sync.unpause() : sync.pause();

  void seek(double seconds) => sync.seek((seconds.clamp(0, double.infinity) * 10000000).round());

  /// The video is open and settled at its place: tell the room.
  Future<void> ready() => sync.ready(_ticks, !isPaused(), playlistItemId);

  /// Ran out of video to show (slow network), or recovered.
  void stalled(bool stalled) {
    if (_done) return;
    if (stalled) {
      sync.buffering(_ticks, !isPaused(), playlistItemId);
    } else {
      sync.ready(_ticks, !isPaused(), playlistItemId);
    }
  }

  // ----- what the room says -----

  String _who() {
    if (DateTime.now().difference(sync.lastOwnRequest) < const Duration(seconds: 3)) return 'You';
    final others = (sync.group.value?.people ?? const <String>[]).where((p) => p != myName).toSet().toList();
    return others.length == 1 ? others.first : 'Someone';
  }

  static String _clock(double sec) {
    final s = sec.floor();
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
    return h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}'
        : '$m:${r.toString().padLeft(2, '0')}';
  }

  void _onCommand(Map<String, dynamic> c) {
    if (_done) return;
    final cmd = c['Command']?.toString();
    final when = c['When'] == null ? sync.serverNow() : parseServerTime(c['When'].toString());
    final ticks = c['PositionTicks'] as int?;
    final pos = ticks == null ? null : ticks / 10000000;
    final local = sync.localTimeOf(when);
    var delay = local.difference(DateTime.now().toUtc());
    if (delay.isNegative) delay = Duration.zero;
    _scheduled?.cancel();
    final who = _who();
    switch (cmd) {
      case 'Unpause':
        _scheduled = Timer(delay, () async {
          final late = DateTime.now().toUtc().difference(local).inMicroseconds / 1e6;
          final target = (pos ?? position()) + (late > 0 ? late : 0);
          if ((target - position()).abs() > 0.4) await seekTo(target);
          await setPaused(false);
          _expected = (when: when, pos: pos ?? position());
          if (who != 'You') notice('$who pressed play');
        });
      case 'Pause':
        _scheduled = Timer(delay, () async {
          await setPaused(true);
          _expected = null;
          await _resetSpeed();
          if (pos != null && (pos - position()).abs() > 0.15) await seekTo(pos);
          if (who != 'You') notice('$who paused');
        });
      case 'Seek':
        _expected = null;
        () async {
          await setPaused(true);
          await _resetSpeed();
          if (pos != null) await seekTo(pos);
          if (who != 'You') notice('$who jumped to ${_clock(pos ?? position())}');
          await Future.delayed(const Duration(milliseconds: 600));
          if (!_done) await ready();
        }();
      case 'Stop':
        notice('The room stopped playing');
        onStop();
    }
  }

  void _onUpdate(Map<String, dynamic> u) {
    if (_done) return;
    switch (u['Type']) {
      case 'UserJoined':
        notice('${u['Data']} joined');
      case 'UserLeft':
        notice('${u['Data']} left');
      case 'GroupDoesNotExist':
      case 'NotInGroup':
      case 'GroupLeft':
        notice('The room has closed');
      case 'LibraryAccessDenied':
        notice("Someone in the room can't open this video");
      case 'PlayQueue':
        final now = sync.nowPlaying;
        if (now != null && now.itemId != itemId) onNewVideo(now);
    }
  }

  Future<void> _keepInStep() async {
    final exp = _expected;
    if (_done || exp == null || isPaused()) return;
    final roomPos = exp.pos + sync.serverNow().difference(exp.when).inMicroseconds / 1e6;
    final behind = roomPos - position();
    if (behind.abs() > 2.0) {
      await _resetSpeed();
      await seekTo(roomPos);
    } else if (behind.abs() > 0.08) {
      await setSpeed(1 + (behind * 0.5).clamp(-0.05, 0.05));
      _nudged = true;
    } else if (_nudged) {
      await _resetSpeed();
    }
  }

  Future<void> _resetSpeed() async {
    if (!_nudged) return;
    _nudged = false;
    await setSpeed(1.0);
  }
}
