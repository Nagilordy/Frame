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
import 'perf.dart' show AppLog;
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

  // ---------- The party (a room that outlives each video) ----------
  //
  // You stay in the room until you choose Leave party. Closing a video only takes you out of
  // that video: Jellyfin is told not to wait for you ("ignore wait") until you watch again.
  // When anyone in the party starts something, it opens here by itself if you're not already
  // watching.

  /// Frame's navigator, so a video someone starts can open from any screen (set in main).
  static GlobalKey<NavigatorState>? navigator;

  int _playersOpen = 0; // room players open right now on this PC
  bool _opening = false; // this PC is opening the room's video itself
  String? _followed; // the room's video (playlist item) this PC already opened

  bool get inParty => group.value != null;

  void playerOpened(String? playlistItemId) {
    _playersOpen++;
    if (playlistItemId != null) _followed = playlistItemId;
    setIgnoreWait(false);
  }

  void playerClosed() {
    _playersOpen--;
    if (_playersOpen <= 0) {
      _playersOpen = 0;
      if (inParty) setIgnoreWait(true);
    }
  }

  Future<void> setIgnoreWait(bool ignore) => jf
      .postPath('/SyncPlay/SetIgnoreWait', {'IgnoreWait': ignore})
      .then((_) {}, onError: (e) => log('ignore-wait failed: $e'));

  // Someone started a video in the party and this PC isn't watching: open it.
  void _maybeFollow() {
    final now = nowPlaying;
    final nav = navigator?.currentState;
    if (!inParty || now == null || nav == null || _playersOpen > 0 || _opening) return;
    if (now.playlistItemId == _followed) return; // already opened (or closed on purpose)
    _followed = now.playlistItemId;
    isHost = false;
    log('the party started ${now.itemId}: opening it');
    _opening = true;
    _pushRoomPlayer(nav, jf, this).whenComplete(() => _opening = false);
  }

  // ---------- Frame's own instant channel ----------
  //
  // Frames in a room send each other short messages through Jellyfin's live connection
  // ("SendString" commands between sessions). No server-side waiting: whoever presses play,
  // pause or seek sees it at once, and the other screens follow within a few milliseconds.
  // It needs "Allow remote control of other users" on each profile (Jellyfin's rule for
  // sending anything to another person's session). Without it, rooms use Jellyfin's
  // Watch Together (SyncPlay) as before.

  static const directTag = ' (Frame)';
  static const _prefix = 'frame-together:';
  bool direct = false; // this room uses Frame's channel
  bool isHost = false; // this Frame opened the room (it keeps time)
  String? _mySession;
  List<String> _peers = [];
  DateTime _peersAt = DateTime(0);
  final _directIn = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get directMessages => _directIn.stream;

  /// Whether this profile may send to other people's sessions on this server.
  Future<bool> canDirect() async {
    try {
      final me = await jf.getPath('/Users/${jf.userId}');
      final policy = me['Policy'] as Map?;
      return policy?['EnableRemoteControlOfOtherUsers'] == true || policy?['IsAdministrator'] == true;
    } catch (_) {
      return false;
    }
  }

  // Tell Jellyfin this Frame can receive messages (needed to be reachable at all).
  Future<void> _announce() async {
    try {
      await jf.postPath('/Sessions/Capabilities/Full', {
        'PlayableMediaTypes': ['Video'],
        'SupportedCommands': ['SendString', 'DisplayMessage'],
        'SupportsMediaControl': true,
      });
      final mine = await jf.getPath('/Sessions?deviceId=${Uri.encodeQueryComponent(Jellyfin.deviceId)}');
      if (mine is List && mine.isNotEmpty) _mySession = mine.first['Id']?.toString();
    } catch (e) {
      debugPrint('Together: could not announce this Frame: $e');
    }
  }

  // The other Frames in this room (their sessions), refreshed every few seconds.
  Future<List<String>> _roomPeers({bool fresh = false}) async {
    if (!fresh && DateTime.now().difference(_peersAt) < const Duration(seconds: 8)) return _peers;
    final people = group.value?.people.toSet() ?? <String>{};
    try {
      final list = await jf.getPath('/Sessions?controllableByUserId=${jf.userId}&activeWithinSeconds=900');
      _peers = [
        for (final s in (list as List))
          if (s['Client'] == 'Frame' &&
              s['Id']?.toString() != _mySession &&
              s['DeviceId']?.toString() != Jellyfin.deviceId &&
              people.contains(s['UserName']?.toString()))
            s['Id'].toString(),
      ];
      _peersAt = DateTime.now();
    } catch (e) {
      debugPrint('Together: could not find the other Frames: $e');
    }
    return _peers;
  }

  /// Sends a message to every other Frame in the room.
  Future<void> sendDirect(Map<String, dynamic> message, {bool freshPeers = false}) async {
    final peers = await _roomPeers(fresh: freshPeers);
    final body = {
      'Name': 'SendString',
      'Arguments': {'String': '$_prefix${jsonEncode(message)}'},
    };
    for (final id in peers) {
      jf.postPath('/Sessions/$id/Command', body).then((_) {}, onError: (e) {
        debugPrint('Together: message not delivered: $e');
        _peersAt = DateTime(0); // look the peers up again next time
      });
    }
  }

  /// Server time in milliseconds (all Frames agree on it within a few ms).
  int serverMs() => serverNow().millisecondsSinceEpoch;

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
    await _announce();
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
      case 'GeneralCommand':
        final d = m['Data'];
        final args = d is Map ? d['Arguments'] : null;
        final text = args is Map ? args['String']?.toString() : null;
        if (text != null && text.startsWith(_prefix)) {
          try {
            final msg = (jsonDecode(text.substring(_prefix.length)) as Map).cast<String, dynamic>();
            _directIn.add(msg);
          } catch (_) {}
        }
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
        _peersAt = DateTime(0);
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
        // Let the players see it first (they switch videos themselves), then follow if needed.
        scheduleMicrotask(_maybeFollow);
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
    if (direct) await sendDirect({'t': 'bye', 'by': jf.userName ?? 'Someone'});
    group.value = null;
    queue = null;
    _followed = null;
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

  // Requests the room already satisfies aren't sent (the server would just echo them).
  Future<void> pause() async {
    lastOwnRequest = DateTime.now();
    log('sent Pause');
    await jf.postPath('/SyncPlay/Pause').then((_) {}, onError: (e) => log('pause failed: $e'));
  }

  Future<void> unpause() async {
    if (group.value?.state == 'Playing') return;
    lastOwnRequest = DateTime.now();
    log('sent Unpause (room ${group.value?.state})');
    await jf.postPath('/SyncPlay/Unpause').then((_) {}, onError: (e) => log('play failed: $e'));
  }

  Future<void> seek(int ticks) async {
    lastOwnRequest = DateTime.now();
    log('sent Seek pos=${(ticks / 10000000).toStringAsFixed(3)}');
    await jf.postPath('/SyncPlay/Seek', {'PositionTicks': ticks}).then((_) {}, onError: (e) => log('seek failed: $e'));
  }

  Future<void> buffering(int ticks, bool playing, String playlistItemId, {String why = ''}) =>
      _report('Buffering', ticks, playing, playlistItemId, why);

  Future<void> ready(int ticks, bool playing, String playlistItemId, {String why = ''}) =>
      _report('Ready', ticks, playing, playlistItemId, why);

  Future<void> _report(String kind, int ticks, bool playing, String playlistItemId, String why) {
    final when = _now();
    log('sent $kind pos=${(ticks / 10000000).toStringAsFixed(3)} playing=$playing when=$when '
        'offset=${_offset.inMilliseconds} ms because: $why');
    return jf.postPath('/SyncPlay/$kind', {
      'When': when,
      'PositionTicks': ticks,
      'IsPlaying': playing,
      'PlaylistItemId': playlistItemId,
    }).then((_) {}, onError: (e) => log('$kind failed: $e'));
  }

  // ---------- Debug log (for comparing with the server's log) ----------
  // together-YYYY-MM-DD.log in Frame's log folder (see perf.dart).
  static final AppLog _log = AppLog('together');
  void log(String message) => _log(message);
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

/// Starts a watch party with nothing playing yet: whatever anyone in it plays next plays for
/// everyone. Others see it on their Home (an invite, and the pill at the top right).
Future<void> startParty(BuildContext context, Jellyfin jf) async {
  final sync = SyncPlay.of(jf);
  if (sync.inParty) {
    _toast(context, "You're already in a party.");
    return;
  }
  _toast(context, 'Starting a watch party…');
  try {
    final direct = await sync.canDirect();
    await sync.create('${jf.userName ?? 'Frame'} · Watch party${direct ? SyncPlay.directTag : ''}');
    sync.direct = direct;
    sync.isHost = true;
    await sync.setIgnoreWait(true); // nobody is watching yet
    if (context.mounted) _toast(context, 'Party started. Anything you play now plays for everyone.');
  } catch (e) {
    await sync.leave();
    if (context.mounted) _toast(context, _friendly(e), problem: true);
  }
}

/// Leaves the party (the others carry on without you).
Future<void> leaveParty(BuildContext context, Jellyfin jf) async {
  await SyncPlay.of(jf).leave();
  if (context.mounted) _toast(context, 'You left the party.');
}

/// Play from any title: for the party when you're in one, otherwise just for you.
/// [startTicks]: where to start (0 = from the beginning); by default, where you left off.
Future<void> playOrParty(BuildContext context, Jellyfin jf, dynamic item, {int? startTicks}) async {
  final sync = SyncPlay.of(jf);
  if (sync.inParty) return _playForParty(context, jf, item, startTicks: startTicks);
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => playerScreen(jf, item, startTicks: startTicks)));
}

Future<void> _playForParty(BuildContext context, Jellyfin jf, dynamic item, {int? startTicks}) async {
  final sync = SyncPlay.of(jf);
  sync._opening = true;
  try {
    sync.isHost = true; // whoever picks the video keeps time for it
    final resume = startTicks ?? (item['UserData']?['PlaybackPositionTicks'] ?? 0) as int;
    await sync.play(item['Id'].toString(), resume);
    if (!context.mounted) return;
    await _openRoomPlayer(context, jf, sync);
  } catch (e) {
    if (context.mounted) _toast(context, _friendly(e), problem: true);
  } finally {
    sync._opening = false;
  }
}

/// Watch together from a title: plays it for your party, or opens a party with it.
Future<void> startWatchTogether(BuildContext context, Jellyfin jf, dynamic item) async {
  if (item == null) return;
  final sync = SyncPlay.of(jf);
  if (sync.inParty) return _playForParty(context, jf, item);
  _toast(context, 'Opening a room…');
  sync._opening = true;
  try {
    final title = item['Type'] == 'Episode'
        ? '${item['SeriesName'] ?? ''} S${item['ParentIndexNumber'] ?? '?'} E${item['IndexNumber'] ?? '?'}'
        : (item['Name'] ?? 'a movie').toString();
    // Frame's instant channel when this profile is allowed to use it; otherwise Jellyfin's.
    final direct = await sync.canDirect();
    await sync.create('${jf.userName ?? 'Frame'} · $title${direct ? SyncPlay.directTag : ''}');
    sync.direct = direct;
    sync.isHost = true;
    if (!direct) debugPrint("Together: using Jellyfin's Watch Together (this profile can't use Frame's instant channel)");
    final resume = (item['UserData']?['PlaybackPositionTicks'] ?? 0) as int;
    await sync.play(item['Id'].toString(), resume);
    if (!context.mounted) return;
    await _openRoomPlayer(context, jf, sync);
  } catch (e) {
    await sync.leave();
    if (context.mounted) _toast(context, _friendly(e), problem: true);
  } finally {
    sync._opening = false;
  }
}

Future<void> joinWatchTogether(BuildContext context, Jellyfin jf, String groupId) async {
  final sync = SyncPlay.of(jf);
  _toast(context, 'Joining…');
  sync._opening = true;
  try {
    if (sync.group.value?.id != groupId) {
      await sync.leave();
      await sync.join(groupId);
    }
    final name = sync.group.value?.name ?? '';
    sync.isHost = false;
    sync.direct = name.endsWith(SyncPlay.directTag);
    if (sync.direct && !await sync.canDirect()) {
      throw "This room uses Frame's instant sync. Ask the server's admin to allow "
          '"remote control of other users" for your profile (Dashboard › Users).';
    }
    // Nothing playing yet (a party waiting for someone to pick): stay here, it opens by
    // itself when someone starts something.
    try {
      await sync.awaitQueue(timeout: const Duration(seconds: 3));
    } catch (_) {}
    if (sync.nowPlaying == null) {
      await sync.setIgnoreWait(true);
      if (context.mounted) _toast(context, "You're in the party. When someone plays something, it opens here.");
      return;
    }
    if (!context.mounted) return;
    await _openRoomPlayer(context, jf, sync);
  } catch (e) {
    await sync.leave();
    if (context.mounted) _toast(context, _friendly(e), problem: true);
  } finally {
    sync._opening = false;
  }
}

Future<void> _openRoomPlayer(BuildContext context, Jellyfin jf, SyncPlay sync) =>
    _pushRoomPlayer(Navigator.of(context), jf, sync);

Future<void> _pushRoomPlayer(NavigatorState nav, Jellyfin jf, SyncPlay sync) async {
  final now = sync.nowPlaying;
  if (now == null) return;
  sync._followed = now.playlistItemId;
  final item = await jf.item(now.itemId, fresh: true);
  await nav.push(MaterialPageRoute(
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
    // Only while Home is in front: no requests during a video or on other screens.
    if (ModalRoute.of(context)?.isCurrent == false) return;
    try {
      final rooms = await SyncPlay.of(widget.jf).list();
      if (!mounted) return;
      // Redraw only when something changed.
      if (jsonEncode(rooms) != jsonEncode(_rooms)) setState(() => _rooms = rooms);
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
    final sync = SyncPlay.of(widget.jf);
    return ValueListenableBuilder<SyncGroup?>(
      valueListenable: sync.group,
      builder: (context, group, _) => group != null ? _partyPill(sync, group) : _roomsPill(),
    );
  }

  // In a party: who's in it. Select it for Rejoin / Leave.
  Widget _partyPill(SyncPlay sync, SyncGroup group) {
    final others = group.people.where((p) => p != widget.jf.userName).toList();
    final label = others.isEmpty ? 'Party · waiting for friends' : 'Party with ${others.join(', ')}';
    return Padding(
      padding: const EdgeInsets.only(right: 18),
      child: Focusable(
        focusNode: widget.focusNode,
        onSelect: () => showPartyMenu(context, widget.jf),
        builder: (f) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(color: f ? kFg : kPillFill, borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.groups_rounded, size: 26, color: f ? kBg : kAccent),
            const SizedBox(width: 12),
            Text(label, style: tvBody(20, weight: FontWeight.w700, color: f ? kBg : kFg)),
          ]),
        ),
      ),
    );
  }

  Widget _roomsPill() {
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

/// Your party: who's in it, rejoin what's playing, or leave. A tall card on the right of the
/// screen, like the PS5's party panel.
Future<void> showPartyMenu(BuildContext context, Jellyfin jf) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: const Color(0x9906080B),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (ctx, _, __) => _PartyMenu(jf: jf, home: context),
    // Slides in from the right.
    transitionBuilder: (ctx, a, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: const Interval(0, 0.6, curve: Curves.easeOut)),
      child: SlideTransition(
        position: Tween(begin: const Offset(0.06, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );
}

class _PartyMenu extends StatelessWidget {
  const _PartyMenu({required this.jf, required this.home});
  final Jellyfin jf;
  final BuildContext home;

  static const _card = Color(0xFF12151B);
  static const _colors = [Color(0xFF6F8CFF), Color(0xFFEE6E90), Color(0xFF4FD1AE), Color(0xFFF2B05A), Color(0xFFA884F5)];

  // A friend's colour, always the same for the same name.
  static Color _colorOf(String name) => _colors[name.codeUnits.fold<int>(0, (a, c) => a + c) % _colors.length];

  // A big pill button, white with a ring when selected (like Play on Home).
  static Widget _pill(IconData icon, String label, VoidCallback onSelect, {bool autofocus = false}) => Focusable(
        autofocus: autofocus,
        onSelect: onSelect,
        builder: (f) => AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 76,
          padding: const EdgeInsets.symmetric(horizontal: 30),
          decoration: BoxDecoration(
            color: f ? kFg : kFg.withOpacity(0.08),
            borderRadius: BorderRadius.circular(999),
            boxShadow: f ? const [BoxShadow(color: _card, spreadRadius: 4), BoxShadow(color: kFg, spreadRadius: 9)] : const [],
          ),
          child: Row(children: [
            Icon(icon, size: 30, color: f ? kBg : kFg),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: tvBody(26, weight: f ? FontWeight.w700 : FontWeight.w600, color: f ? kBg : kFg)),
            ),
          ]),
        ),
      );

  Widget _person(String name, String note, {bool you = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          Container(
            width: 60,
            height: 60,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: you ? kAccent : _colorOf(name)),
            child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(), style: tvDisplay(26).copyWith(color: kBg)),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(you ? '$name (you)' : name, overflow: TextOverflow.ellipsis, style: tvBody(26, weight: FontWeight.w600)),
              if (note.isNotEmpty) Text(note, style: tvBody(20, color: kMuted)),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final sync = SyncPlay.of(jf);
    final group = sync.group.value;
    final playing = sync.nowPlaying;
    final me = jf.userName ?? '';
    final people = group?.people ?? const <String>[];
    final others = people.where((p) => p != me).toList();
    final state = group?.state ?? '';
    final doing = playing == null
        ? 'On Home'
        : state == 'Playing'
            ? 'Watching'
            : state == 'Paused'
                ? 'Paused'
                : 'Getting ready';
    final count = people.isEmpty ? 1 : people.length;
    return PadHints(
      hints: const [PadHint(PadButton.select, 'Select'), PadHint(PadButton.back, 'Close')],
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
              top: 48,
              right: 48,
              bottom: 48,
              width: 660,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  padding: const EdgeInsets.all(44),
                  decoration: BoxDecoration(
                    color: _card.withOpacity(0.97),
                    borderRadius: BorderRadius.circular(36),
                    border: Border.all(color: kFg.withOpacity(0.08)),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    // What the party is up to.
                    Row(children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF4FD1AE)),
                      ),
                      const SizedBox(width: 12),
                      Text('WATCH PARTY · $count ${count == 1 ? 'PERSON' : 'PEOPLE'}',
                          style: tvBody(20, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1.6)),
                    ]),
                    const SizedBox(height: 10),
                    if (playing == null) ...[
                      Text('Nothing playing yet', style: tvDisplay(44)),
                      const SizedBox(height: 6),
                      Text('Pick something and it opens for everyone.', style: tvBody(24, color: kSoft)),
                    ] else
                      FutureBuilder<dynamic>(
                        future: jf.item(playing.itemId),
                        builder: (context, snap) {
                          final item = snap.data;
                          final title = item == null ? '' : titleOf(item);
                          final line = item == null ? '' : episodeLine(item);
                          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(title.isEmpty ? 'Watching together' : 'Watching $title',
                                maxLines: 2, overflow: TextOverflow.ellipsis, style: tvDisplay(44)),
                            const SizedBox(height: 6),
                            Text([if (line.isNotEmpty) line, doing].join('  ·  '), style: tvBody(24, color: kSoft)),
                          ]);
                        },
                      ),
                    const SizedBox(height: 30),
                    // Who's here.
                    _person(me.isEmpty ? 'You' : me, sync.inParty && sync._playersOpen > 0 ? doing : 'On Home', you: true),
                    for (final p in others) _person(p, playing == null ? 'In the party' : doing),
                    if (others.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('Waiting for friends: they get an invite on their Home.', style: tvBody(20, color: kMuted)),
                      ),
                    const Spacer(),
                    // What you can do.
                    FocusTraversalGroup(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        if (playing != null) ...[
                          _pill(Icons.play_arrow_rounded, 'Join what everyone is watching', () {
                            Navigator.of(context).pop();
                            sync._opening = true;
                            _openRoomPlayer(home, jf, sync).whenComplete(() => sync._opening = false);
                          }, autofocus: true),
                          const SizedBox(height: 14),
                        ],
                        _pill(Icons.grid_view_rounded, 'Pick something for everyone', () => Navigator.of(context).pop(),
                            autofocus: playing == null),
                        const SizedBox(height: 14),
                        _pill(Icons.logout_rounded, 'Leave party', () {
                          Navigator.of(context).pop();
                          leaveParty(home, jf);
                        }),
                      ]),
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

// ---------- Join a party / Start a watch party ----------
//
// Both use the party menu's tall card on the right (like the PS5's party / game base), so
// everything about watch parties looks like one family.

Future<void> _showSideCard(BuildContext context, Widget Function(BuildContext ctx) builder) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: const Color(0x9906080B),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (ctx, _, __) => builder(ctx),
    // Slides in from the right.
    transitionBuilder: (ctx, a, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: const Interval(0, 0.6, curve: Curves.easeOut)),
      child: SlideTransition(
        position: Tween(begin: const Offset(0.06, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );
}

Widget _sideCard(BuildContext context, {required List<PadHint> hints, required Widget child}) => PadHints(
      hints: hints,
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
              top: 48,
              right: 48,
              bottom: 48,
              width: 660,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  padding: const EdgeInsets.all(44),
                  decoration: BoxDecoration(
                    color: _PartyMenu._card.withOpacity(0.97),
                    borderRadius: BorderRadius.circular(36),
                    border: Border.all(color: kFg.withOpacity(0.08)),
                  ),
                  child: child,
                ),
              ),
            ),
          ]),
        ),
      ),
    );

Widget _cardHeader(String small, String big) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(small.toUpperCase(), style: tvBody(20, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1.6)),
      const SizedBox(height: 8),
      Text(big, style: tvDisplay(44)),
    ]);

Widget _avatar(String name, double size, {Color? ring}) => Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _PartyMenu._colorOf(name),
        border: ring == null ? null : Border.all(color: ring, width: 3),
      ),
      child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: tvDisplay(size * 0.43).copyWith(color: kBg)),
    );

// A room's starter and what it's watching, from its name ("Sam · Frieren · S1 · E4").
(String host, String what) _roomParts(dynamic room) {
  final people = ((room['Participants'] as List?) ?? []).map((p) => p.toString()).toList();
  var name = (room['GroupName'] ?? '').toString();
  if (name.endsWith(SyncPlay.directTag)) name = name.substring(0, name.length - SyncPlay.directTag.length);
  final cut = name.indexOf(' · ');
  final host = cut > 0 ? name.substring(0, cut) : (people.isEmpty ? 'Someone' : people.first);
  var what = cut > 0 ? name.substring(cut + 3) : '';
  if (what == 'Watch party') what = '';
  return (host, what);
}

/// The rooms open on this server, to join one.
Future<void> showRooms(BuildContext context, Jellyfin jf, List<dynamic> rooms) =>
    _showSideCard(context, (ctx) => _Rooms(jf: jf, rooms: rooms, home: context));

class _Rooms extends StatelessWidget {
  const _Rooms({required this.jf, required this.rooms, required this.home});
  final Jellyfin jf;
  final List<dynamic> rooms;
  final BuildContext home; // the screen behind, which opens the player

  Widget _room(BuildContext context, dynamic room, {bool autofocus = false}) {
    final people = ((room['Participants'] as List?) ?? []).map((p) => p.toString()).toList();
    final state = (room['State'] ?? '').toString();
    final (host, what) = _roomParts(room);
    final playing = state == 'Playing';
    final stateLabel = playing ? 'Playing' : state == 'Paused' ? 'Paused' : 'Getting ready';
    return Focusable(
      autofocus: autofocus,
      onSelect: () {
        Navigator.of(context).pop();
        joinWatchTogether(home, jf, room['GroupId'].toString());
      },
      builder: (f) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
        decoration: BoxDecoration(
          color: f ? kFg : kFg.withOpacity(0.06),
          borderRadius: BorderRadius.circular(28),
          boxShadow: f
              ? const [BoxShadow(color: _PartyMenu._card, spreadRadius: 4), BoxShadow(color: kFg, spreadRadius: 9)]
              : const [],
        ),
        child: Row(children: [
          _avatar(host, 64),
          const SizedBox(width: 20),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("$host's party",
                  overflow: TextOverflow.ellipsis, style: tvBody(26, weight: FontWeight.w700, color: f ? kBg : kFg)),
              if (what.isNotEmpty)
                Text(what,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tvBody(21, color: f ? const Color(0xFF3B4250) : kMuted)),
              const SizedBox(height: 10),
              Row(children: [
                if (people.isNotEmpty)
                  SizedBox(
                    width: 40 + 28.0 * (people.length.clamp(1, 6) - 1),
                    height: 40,
                    child: Stack(children: [
                      for (var i = 0; i < people.length && i < 6; i++)
                        Positioned(left: 28.0 * i, child: _avatar(people[i], 40, ring: f ? kFg : _PartyMenu._card)),
                    ]),
                  ),
                const SizedBox(width: 12),
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle, color: playing ? const Color(0xFF4FD1AE) : const Color(0xFFF2B05A)),
                ),
                const SizedBox(width: 8),
                Text(stateLabel,
                    style: tvBody(19, weight: FontWeight.w600, color: f ? const Color(0xFF3B4250) : kMuted)),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _sideCard(
      context,
      hints: const [PadHint(PadButton.select, 'Join'), PadHint(PadButton.back, 'Close')],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _cardHeader('Watch parties', 'Join a party'),
        const SizedBox(height: 28),
        Expanded(
          child: FocusTraversalGroup(
            child: ListView(padding: const EdgeInsets.all(10), clipBehavior: Clip.none, children: [
              for (var i = 0; i < rooms.length; i++) _room(context, rooms[i], autofocus: i == 0),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        _PartyMenu._pill(Icons.add_rounded, 'Start my own party', () {
          Navigator.of(context).pop();
          showStartParty(home, jf);
        }, autofocus: rooms.isEmpty),
      ]),
    );
  }
}

/// "Start a watch party" from the profile menu: what a party does and who gets invited,
/// any party already going (to join it instead), then Start the party.
Future<void> showStartParty(BuildContext context, Jellyfin jf) =>
    _showSideCard(context, (ctx) => _StartParty(jf: jf, home: context));

class _StartParty extends StatelessWidget {
  const _StartParty({required this.jf, required this.home});
  final Jellyfin jf;
  final BuildContext home;

  Widget _step(int n, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: kFg.withOpacity(0.10)),
            child: Text('$n', style: tvBody(20, weight: FontWeight.w700)),
          ),
          const SizedBox(width: 18),
          Expanded(child: Text(text, style: tvBody(22))),
        ]),
      );

  Widget _going(BuildContext context, dynamic room) {
    final people = ((room['Participants'] as List?) ?? []).length;
    final (host, what) = _roomParts(room);
    return Focusable(
      onSelect: () {
        Navigator.of(context).pop();
        joinWatchTogether(home, jf, room['GroupId'].toString());
      },
      builder: (f) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: f ? kFg : kFg.withOpacity(0.06),
          borderRadius: BorderRadius.circular(24),
          boxShadow: f
              ? const [BoxShadow(color: _PartyMenu._card, spreadRadius: 4), BoxShadow(color: kFg, spreadRadius: 9)]
              : const [],
        ),
        child: Row(children: [
          _avatar(host, 48),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("$host's party", style: tvBody(22, weight: FontWeight.w700, color: f ? kBg : kFg)),
              Text([if (what.isNotEmpty) what, '$people ${people == 1 ? 'person' : 'people'}'].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tvBody(19, color: f ? const Color(0xFF3B4250) : kMuted)),
            ]),
          ),
          Text('Join', style: tvBody(20, weight: FontWeight.w600, color: f ? kBg : kSoft)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _sideCard(
      context,
      hints: const [PadHint(PadButton.select, 'Select'), PadHint(PadButton.back, 'Close')],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _cardHeader('Watch party', 'Watch together'),
        const SizedBox(height: 10),
        Text('Anything you play plays for everyone in the party, in sync. Pause, skip or go back and it happens for all of you.',
            style: tvBody(23, color: kSoft, height: 1.45)),
        const SizedBox(height: 26),
        _step(1, 'Start the party'),
        _step(2, 'Friends on your server get an invite on their Home'),
        _step(3, 'Press Play on anything, and it opens for everyone'),
        // Already going: so you join instead of starting a second one.
        FutureBuilder<List<dynamic>>(
          future: SyncPlay.of(jf).list().catchError((_) => <dynamic>[]),
          builder: (context, snap) {
            final rooms = snap.data ?? const [];
            if (rooms.isEmpty) return const SizedBox.shrink();
            return FocusTraversalGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SizedBox(height: 8),
                Text('ALREADY WATCHING', style: tvBody(20, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1.6)),
                for (final r in rooms.take(2)) _going(context, r),
              ]),
            );
          },
        ),
        const Spacer(),
        FocusTraversalGroup(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _PartyMenu._pill(Icons.groups_rounded, 'Start the party', () {
              Navigator.of(context).pop();
              startParty(home, jf);
            }, autofocus: true),
            const SizedBox(height: 14),
            _PartyMenu._pill(Icons.close_rounded, 'Not now', () => Navigator.of(context).pop()),
          ]),
        ),
      ]),
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
  var what = name.contains(' · ') ? name.substring(name.indexOf(' · ') + 3) : name;
  if (what.endsWith(SyncPlay.directTag)) what = what.substring(0, what.length - SyncPlay.directTag.length);
  final (a, b) = _accentOf(who);
  showBanner(
    context,
    picture: bannerInitial(who, a, b),
    who: 'Watch party',
    text: '$who started a watch party',
    detail: what.isEmpty || what == 'Watch party' ? null : what,
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

/// What a player needs from a room, whichever way the room keeps in sync.
abstract class RoomLink {
  bool handingOver = false;
  void start();
  void dispose();
  void togglePause();
  void seek(double seconds);
  Future<void> ready();
  void stalled(bool stalled);

  /// Frame's instant channel when the room uses it, Jellyfin's Watch Together otherwise.
  static RoomLink create({
    required SyncPlay sync,
    required String playlistItemId,
    required String itemId,
    required String? myName,
    required double Function() position,
    required bool Function() isPaused,
    required Future<void> Function(double seconds) seekTo,
    required Future<void> Function(bool paused) setPaused,
    required Future<void> Function(double speed) setSpeed,
    required void Function(String text) notice,
    required VoidCallback onStop,
    required void Function(RoomVideo now) onNewVideo,
    required Future<bool> Function() settled,
    required Future<double> Function() exactPosition,
    required double Function() duration,
  }) =>
      sync.direct
          ? DirectFollower(
              sync: sync,
              itemId: itemId,
              myName: myName,
              position: position,
              isPaused: isPaused,
              seekTo: seekTo,
              setPaused: setPaused,
              setSpeed: setSpeed,
              notice: notice,
              onStop: onStop,
              onNewVideo: onNewVideo,
              settled: settled,
              duration: duration)
          : RoomFollower(
              sync: sync,
              playlistItemId: playlistItemId,
              itemId: itemId,
              myName: myName,
              position: position,
              isPaused: isPaused,
              seekTo: seekTo,
              setPaused: setPaused,
              setSpeed: setSpeed,
              notice: notice,
              onStop: onStop,
              onNewVideo: onNewVideo,
              settled: settled,
              exactPosition: exactPosition,
              duration: duration);
}

// When to tell the room "my video stopped" (Buffer), following what testing showed:
//  - only a stall that lasts 0.7 s or more counts; shorter ones fix themselves
//  - stalls Frame caused itself (a jump to obey the room) don't count, for a moment after the
//    jump and while a Ready is on its way
//  - at most one Buffer a second, and the Ready never follows it back to back
//  - the last half second of a video never counts
// Reporting every hiccup is what made rooms stop and start twice a second.
class StallGate {
  StallGate({required this.onBuffer, required this.onRecovered, required this.nearEnd, required this.isPaused});

  final void Function() onBuffer;
  final void Function() onRecovered;
  final bool Function() nearEnd;
  final bool Function() isPaused;

  static const _lasts = Duration(milliseconds: 700);
  static const _gap = Duration(seconds: 1);

  Timer? _timer;
  bool reported = false; // a Buffer went out and its Ready hasn't yet
  bool _stalled = false;
  bool hold = false; // a jump Frame made is settling: its Ready is coming anyway
  DateTime _muteUntil = DateTime(0);
  DateTime _lastBuffer = DateTime(0);

  /// Frame is about to jump or change speed itself: the stall that follows isn't news.
  void selfAction([Duration quiet = const Duration(milliseconds: 1500)]) {
    final until = DateTime.now().add(quiet);
    if (until.isAfter(_muteUntil)) _muteUntil = until;
  }

  /// A Ready went out some other way (after a jump): nothing left to recover from.
  void readySent() {
    reported = false;
    if (!_stalled) _timer?.cancel();
  }

  void update(bool stalled) {
    _stalled = stalled;
    _timer?.cancel();
    if (stalled) {
      _timer = Timer(_lasts, _maybeBuffer);
    } else if (reported) {
      final wait = _gap - DateTime.now().difference(_lastBuffer);
      _timer = Timer(wait.isNegative ? Duration.zero : wait, () {
        if (_stalled || !reported) return;
        reported = false;
        onRecovered();
      });
    }
  }

  void _maybeBuffer() {
    if (!_stalled || reported || hold || isPaused() || nearEnd()) return;
    final now = DateTime.now();
    var wait = _muteUntil.difference(now);
    final sinceLast = _gap - now.difference(_lastBuffer);
    if (sinceLast > wait) wait = sinceLast;
    if (wait > Duration.zero) {
      // Still stalled once the quiet moment is over: then it's real.
      _timer = Timer(wait + _lasts, _maybeBuffer);
      return;
    }
    reported = true;
    _lastBuffer = now;
    onBuffer();
  }

  void dispose() => _timer?.cancel();
}

class RoomFollower extends RoomLink {
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
    required this.settled,
    required this.exactPosition,
    required this.duration,
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
  final Future<bool> Function() settled; // not jumping, not loading
  final Future<double> Function() exactPosition; // asked from the player right now
  final double Function() duration;

  StreamSubscription? _commands;
  StreamSubscription? _updates;
  Timer? _drift;
  Timer? _scheduled;
  Timer? _seekSend;
  Timer? _recoverWatch;
  ({DateTime when, double pos})? _expected;
  bool _nudged = false;
  bool _done = false;
  int _readyRun = 0; // only the newest Ready attempt sends: exactly one Ready per command
  final List<({DateTime at, double pos})> _jumps = []; // the room's Seeks, to spot correction loops
  DateTime _stuckNotice = DateTime(0);

  late final StallGate _gate = StallGate(
    isPaused: isPaused,
    nearEnd: () {
      final d = duration();
      return d > 0 && d - position() < 0.5;
    },
    onBuffer: () {
      sync.buffering(_ticksOf(position()), !isPaused(), playlistItemId, why: 'stalled 0.7 s+');
      // Whatever happens, a Ready follows as soon as the player can play (no group left stuck).
      _recoverWatch?.cancel();
      _recoverWatch = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (_done || !_gate.reported) {
          _recoverWatch?.cancel();
          return;
        }
        if (await settled()) _gate.update(false);
      });
    },
    onRecovered: () {
      _recoverWatch?.cancel();
      _sendReady('recovered from stall');
    },
  );

  static int _ticksOf(double sec) => (sec * 10000000).round();

  @override
  void start() {
    _commands = sync.commands.listen(_onCommand);
    _updates = sync.updates.listen(_onUpdate);
    _drift = Timer.periodic(const Duration(seconds: 1), (_) => _keepInStep());
  }

  @override
  void dispose() {
    _done = true;
    _gate.dispose();
    _commands?.cancel();
    _updates?.cancel();
    _drift?.cancel();
    _scheduled?.cancel();
    _seekSend?.cancel();
    _recoverWatch?.cancel();
    // Closing the video doesn't leave the party (see SyncPlay.playerClosed).
  }

  // ----- what you do -----

  @override
  void togglePause() {
    final state = sync.group.value?.state;
    if (state == 'Waiting' && isPaused()) {
      // The room is waiting on someone: play means "start anyway" (the server allows it).
      sync.log('you pressed play while the room waits: start anyway');
      sync.unpause();
    } else if (isPaused()) {
      if (state == 'Playing') {
        // The room already plays: just catch up here, no request needed.
        _catchUp();
      } else {
        sync.unpause();
      }
    } else {
      sync.pause();
    }
  }

  Future<void> _catchUp() async {
    final exp = _expected;
    if (exp != null) {
      _gate.selfAction();
      await seekTo(exp.pos + sync.serverNow().difference(exp.when).inMicroseconds / 1e6);
    }
    await setPaused(false);
  }

  /// Jumps show here at once (so holding the skip button adds up), and the room hears about
  /// it once you stop: one Seek per drag or burst of presses, not twenty.
  @override
  void seek(double seconds) {
    final to = seconds < 0 ? 0.0 : seconds;
    _expected = null; // don't pull back to the old spot meanwhile
    _gate.selfAction();
    seekTo(to);
    _seekSend?.cancel();
    _seekSend = Timer(const Duration(milliseconds: 450), () {
      if (!_done) sync.seek(_ticksOf(to));
    });
  }

  /// The video is open: tell the room once it has settled.
  @override
  Future<void> ready() => _sendReady('video opened');

  /// Waits for the player to finish jumping and loading, makes sure it's really at [target]
  /// (the room only accepts a Ready within half a second of its spot), then sends one Ready
  /// with the player's true position.
  Future<void> _sendReady(String why, {double? target}) async {
    final run = ++_readyRun;
    bool stale() => _done || run != _readyRun;
    var reseeked = false;
    for (var i = 0; i < 120; i++) {
      if (stale()) return;
      if (await settled()) {
        if (target == null) break;
        final at = await exactPosition();
        if ((at - target).abs() <= 0.2) break;
        // Settled in the wrong place (a keyframe, or the jump hadn't started yet): once, after
        // giving it a second, jump again exactly.
        if (i >= 10 && !reseeked) {
          reseeked = true;
          sync.log('landed at ${at.toStringAsFixed(3)} instead of ${target.toStringAsFixed(3)}: seeking again');
          _gate.selfAction();
          await seekTo(target);
        }
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (stale()) return;
    final pos = await exactPosition();
    if (stale()) return;
    _gate.hold = false;
    _gate.readySent();
    _recoverWatch?.cancel();
    await sync.ready(_ticksOf(pos), !isPaused(), playlistItemId,
        why: target == null ? why : '$why (target ${target.toStringAsFixed(3)})');
  }

  /// Ran out of video to show (slow network), or recovered.
  @override
  void stalled(bool stalled) {
    if (!_done) _gate.update(stalled);
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

  // How many times the room has sent us to this same spot in the last 10 s. 2 or more means the
  // server is correcting us (it didn't accept our Ready).
  int _repeatsOf(double pos) {
    final now = DateTime.now();
    _jumps.removeWhere((j) => now.difference(j.at) > const Duration(seconds: 10));
    final n = _jumps.where((j) => (j.pos - pos).abs() < 0.6).length;
    _jumps.add((at: now, pos: pos));
    return n;
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
    sync.log('got $cmd pos=${pos?.toStringAsFixed(3)} when=${c['When']} in ${delay.inMilliseconds} ms; '
        'player at ${position().toStringAsFixed(3)} ${isPaused() ? 'paused' : 'playing'}');
    _scheduled?.cancel();
    final who = _who();
    switch (cmd) {
      case 'Unpause':
        _scheduled = Timer(delay, () async {
          if (_done) return;
          final late = DateTime.now().toUtc().difference(local).inMicroseconds / 1e6;
          final target = (pos ?? position()) + (late > 0 ? late : 0);
          if ((target - position()).abs() > 1.0) {
            _gate.selfAction();
            await seekTo(target);
          }
          await setPaused(false);
          _expected = (when: when, pos: pos ?? position());
          sync.log('did Unpause: at ${position().toStringAsFixed(3)}');
          if (who != 'You') notice('$who pressed play');
        });
      case 'Pause':
        _scheduled = Timer(delay, () async {
          if (_done) return;
          await setPaused(true);
          _expected = null;
          await _resetSpeed();
          if (pos != null && (pos - position()).abs() > 0.5) {
            _gate.selfAction();
            await seekTo(pos);
          }
          sync.log('did Pause: at ${position().toStringAsFixed(3)}');
          if (who != 'You') notice('$who paused');
        });
      case 'Seek':
        _expected = null;
        final target = pos ?? position();
        final repeats = _repeatsOf(target);
        _gate.hold = true; // our Ready is coming: no Buffer in between
        _gate.selfAction();
        () async {
          await setPaused(true);
          await _resetSpeed();
          await seekTo(target);
          if (repeats == 0 && who != 'You') notice('$who jumped to ${_clock(target)}');
          if (repeats >= 2) {
            // The server keeps sending us back: give the player a moment before answering, and
            // offer the way out instead of making everyone wait for its 30 s timeout.
            sync.log('corrected $repeats times to ${target.toStringAsFixed(3)}: backing off');
            if (DateTime.now().difference(_stuckNotice) > const Duration(seconds: 10)) {
              _stuckNotice = DateTime.now();
              notice('Having trouble lining up: press play to start anyway');
            }
            await Future.delayed(Duration(milliseconds: 600 * repeats.clamp(1, 4)));
          }
          await _sendReady('after Seek', target: target);
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
      sync.log('drifted ${behind.toStringAsFixed(2)} s: jumping to the room');
      await _resetSpeed();
      _gate.selfAction();
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

// ---------- Frame's instant sync ----------
//
// No waiting on the server. Rules:
//  - Your press acts on your screen at once, then goes to the others with the exact moment
//    (server clock) and position, so they land on the same frame, not a jump back.
//  - The newest press wins everywhere (if two people press at once).
//  - The host (who opened the room) sends where it is 4 times a second while playing; the
//    others close any gap by playing up to 5% faster or slower, which nobody can see.
//  - Someone's video loading: the others pause for them ("Waiting for Bob") and carry on
//    together when it's ready.
//  - Subtitles, audio and full screen stay each person's own.

class DirectFollower extends RoomLink {
  DirectFollower({
    required this.sync,
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
    required this.settled,
    required this.duration,
  });

  final SyncPlay sync;
  final String itemId;
  final String? myName;
  final double Function() position;
  final bool Function() isPaused;
  final Future<void> Function(double seconds) seekTo;
  final Future<void> Function(bool paused) setPaused;
  final Future<void> Function(double speed) setSpeed;
  final void Function(String text) notice;
  final VoidCallback onStop;
  final void Function(RoomVideo now) onNewVideo;
  final Future<bool> Function() settled;
  final double Function() duration;

  StreamSubscription? _in;
  Timer? _seekSend;
  late final StallGate _gate = StallGate(
    isPaused: () => !_playing,
    nearEnd: () {
      final d = duration();
      return d > 0 && d - position() < 0.5;
    },
    onBuffer: () {
      sync.log('instant: my video is loading, asking the others to wait');
      sync.sendDirect({'t': 'wait', 'by': _me, 'on': true});
    },
    onRecovered: () {
      sync.log('instant: loaded again');
      sync.sendDirect({'t': 'wait', 'by': _me, 'on': false});
    },
  );
  StreamSubscription? _updates;
  Timer? _tick;
  Timer? _drift;
  bool _done = false;

  // The room's agreed state: playing or not, and where, as of a moment on the server clock.
  bool _playing = false;
  double _pos = 0;
  int _at = 0;
  final Set<String> _waitingFor = {};
  bool _nudged = false;
  bool _settled = false; // our video is open and ready

  String get _me => myName ?? 'Someone';

  // Where the room is right now.
  double get _roomPos => _playing ? _pos + (sync.serverMs() - _at) / 1000 : _pos;

  @override
  void start() {
    _in = sync.directMessages.listen(_onMessage);
    _updates = sync.updates.listen(_onUpdate);
    _drift = Timer.periodic(const Duration(milliseconds: 500), (_) => _keepInStep());
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (sync.isHost && _settled && _playing && _waitingFor.isEmpty && !isPaused()) {
        sync.sendDirect({'t': 'tick', 'pos': position(), 'at': sync.serverMs()});
      }
    });
  }

  @override
  void dispose() {
    _done = true;
    _gate.dispose();
    _seekSend?.cancel();
    _in?.cancel();
    _updates?.cancel();
    _tick?.cancel();
    _drift?.cancel();
    _hostTimer?.cancel();
    // Closing the video doesn't leave the party. If this Frame kept time, someone still
    // watching takes over.
    if (!handingOver && sync.isHost) sync.sendDirect({'t': 'away', 'by': _me});
  }

  // ----- your presses: instant here, then to everyone -----

  void _announce(String what) {
    _at = sync.serverMs();
    sync.log('instant: sent $what at ${_pos.toStringAsFixed(2)} s (${_playing ? 'playing' : 'paused'})');
    sync.sendDirect({'t': 'state', 'playing': _playing, 'pos': _pos, 'at': _at, 'by': _me, 'what': what});
  }

  @override
  void togglePause() {
    final pos = position();
    _pos = pos;
    _playing = isPaused();
    setPaused(!_playing);
    if (!_playing) _resetSpeed();
    _announce(_playing ? 'play' : 'pause');
  }

  @override
  void seek(double seconds) {
    final to = seconds < 0 ? 0.0 : seconds;
    _pos = to;
    _at = sync.serverMs();
    _gate.selfAction();
    seekTo(to);
    // Holding skip or dragging: everyone else jumps once, where you stop.
    _seekSend?.cancel();
    _seekSend = Timer(const Duration(milliseconds: 350), () {
      if (!_done) _announce('seek');
    });
  }

  @override
  Future<void> ready() async {
    for (var i = 0; i < 100 && !_done; i++) {
      if (await settled()) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_done) return;
    if (_settled) {
      // Opened again mid-room (switched to the server's version, another audio track):
      // just line up with the room again, don't restart it.
      await _apply();
      return;
    }
    _settled = true;
    if (sync.isHost) {
      // The host starts the room playing from where it opened.
      _pos = position();
      _playing = true;
      await setPaused(false);
      _announce('play');
    } else {
      // Ask the room where it is; whoever keeps time answers with the current state. Nobody
      // answering in 4 s (everyone else closed the video): this Frame keeps time from here.
      sync.sendDirect({'t': 'hello', 'by': _me}, freshPeers: true);
      _hostTimer = Timer(const Duration(seconds: 4), () async {
        if (_done || _heard) return;
        sync.log('instant: nobody answered, keeping time here');
        sync.isHost = true;
        _selfElected = true;
        _pos = position();
        _playing = true;
        await setPaused(false);
        _announce('play');
      });
    }
  }

  Timer? _hostTimer;
  bool _heard = false; // got the room's state from someone
  bool _selfElected = false; // took over keeping time because nobody answered

  @override
  void stalled(bool stalled) {
    if (_done || !_settled) return;
    _gate.update(stalled);
  }

  // Loop breaker: if someone keeps stalling, stop pausing everyone for them; they catch up on
  // their own (a jump) instead of the whole room stopping and starting over and over.
  final Map<String, List<DateTime>> _stalls = {};
  final Set<String> _notWaitingFor = {};

  bool _shouldWaitFor(String by) {
    if (_notWaitingFor.contains(by)) return false;
    final now = DateTime.now();
    final list = (_stalls[by] ??= [])..add(now);
    list.removeWhere((t) => now.difference(t) > const Duration(seconds: 60));
    if (list.length >= 3) {
      _notWaitingFor.add(by);
      notice("$by's connection is slow: carrying on without waiting");
      Timer(const Duration(minutes: 5), () => _notWaitingFor.remove(by));
      return false;
    }
    return true;
  }

  // ----- what the others say -----

  void _onMessage(Map<String, dynamic> m) {
    if (_done) return;
    if (m['t'] != 'tick') {
      sync.log('instant: got ${m['t']} from ${m['by'] ?? '?'}'
          '${m['pos'] is num ? ' at ${(m['pos'] as num).toStringAsFixed(2)} s' : ''}'
          '${m['what'] != null ? ' (${m['what']})' : ''}');
    }
    switch (m['t']) {
      case 'state':
        _heard = true;
        // Two Frames opened at the same moment and both started keeping time: the one that
        // took over by itself steps back.
        if (_selfElected && sync.isHost) {
          sync.isHost = false;
          _selfElected = false;
        }
        final at = (m['at'] as num?)?.toInt() ?? 0;
        if (at < _at) return; // an older press than the one we already follow
        final wasPos = _roomPos;
        _playing = m['playing'] == true;
        _pos = (m['pos'] as num?)?.toDouble() ?? _pos;
        _at = at;
        _apply();
        final by = (m['by'] ?? 'Someone').toString();
        switch (m['what']) {
          case 'play':
            notice('$by pressed play');
          case 'pause':
            notice('$by paused');
          case 'seek':
            if ((_pos - wasPos).abs() > 3) notice('$by jumped to ${RoomFollower._clock(_pos)}');
        }
      case 'tick':
        if (sync.isHost || (_seekSend?.isActive ?? false)) return; // mid-jump: ours wins
        final at = (m['at'] as num?)?.toInt() ?? 0;
        if (at < _at) return;
        _pos = (m['pos'] as num?)?.toDouble() ?? _pos;
        _at = at;
        _playing = true;
      case 'hello':
        if (sync.isHost && _settled) {
          _pos = position();
          _announce('sync');
          notice('${m['by']} joined');
        }
      case 'wait':
        final by = (m['by'] ?? 'Someone').toString();
        if (m['on'] == true) {
          if (!_shouldWaitFor(by)) return;
          if (_waitingFor.add(by)) notice('Waiting for $by');
          if (_playing) {
            setPaused(true);
            _resetSpeed();
          }
        } else {
          _waitingFor.remove(by);
          if (_waitingFor.isEmpty) _apply();
        }
      case 'away':
        // The one keeping time closed the video: the first (by name) still watching takes over.
        final by = (m['by'] ?? '').toString();
        final watching = (sync.group.value?.people ?? const <String>[]).where((p) => p != by).toList()..sort();
        if (_settled && watching.isNotEmpty && watching.first == _me) {
          sync.isHost = true;
          sync.log('instant: $by stopped watching, keeping time here');
        }
      case 'bye':
        _waitingFor.remove(m['by']?.toString());
        notice('${m['by']} left');
        // Alone or the host left: this Frame keeps time from now on.
        if ((sync.group.value?.people.length ?? 1) <= 2) sync.isHost = true;
        if (_waitingFor.isEmpty) _apply();
    }
  }

  // Make this screen match the room: right place, playing or paused.
  Future<void> _apply() async {
    if (!_settled) return;
    final target = _roomPos;
    if ((target - position()).abs() > 0.3) {
      _gate.selfAction();
      await seekTo(target);
    }
    if (_playing && _waitingFor.isEmpty) {
      await setPaused(false);
    } else {
      await setPaused(true);
      await _resetSpeed();
    }
  }

  void _onUpdate(Map<String, dynamic> u) {
    if (_done) return;
    switch (u['Type']) {
      case 'GroupDoesNotExist':
      case 'NotInGroup':
      case 'GroupLeft':
        notice('The room has closed');
      case 'PlayQueue':
        final now = sync.nowPlaying;
        if (now != null && now.itemId != itemId) onNewVideo(now);
    }
  }

  Future<void> _keepInStep() async {
    if (_done || !_settled || sync.isHost || !_playing || _waitingFor.isNotEmpty || isPaused()) return;
    final behind = _roomPos - position();
    if (behind.abs() > 1.5) {
      await _resetSpeed();
      _gate.selfAction();
      await seekTo(_roomPos);
    } else if (behind.abs() > 0.06) {
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

