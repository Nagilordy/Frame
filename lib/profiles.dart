// Who's watching: finding the server, picking a profile, signing in, and the profile menu on
// Home. Same look as the rest of Frame (dark, glass, Sora titles), console-style:
// big round avatars in a row, the selected one grows with a white ring and lights the room
// in its colour.
//
// Each profile signs in once per PC; Frame keeps its login, so after that picking it opens
// Home straight away. Without a password, no sign-in at all. With one: Quick Connect (approve
// a code from Jellyfin on your phone, nothing to type) or the password.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gamepad.dart' show PadHint, PadButton, PadHints;
import 'home.dart' show HomeScreen;
import 'images.dart' show netImage;
import 'keyboard.dart' show TvTextField;
import 'main.dart' show Jellyfin;
import 'phone.dart';
import 'syncplay.dart' show SyncPlay, showPartyMenu, showStartParty;
import 'ui.dart';

// ---------- What Frame remembers ----------

class _Saved {
  _Saved(this.name, this.token, this.tag);
  final String name;
  final String token;
  final String? tag;
}

/// Logins are kept per server, so switching between your NAS and a friend's server keeps
/// both signed in.
class ProfileStore {
  static Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  /// The server Frame opens on.
  static Future<String?> server() async => (await _p).getString('server');

  /// Every server signed in to on this PC, with its name.
  static Future<Map<String, String>> servers() async {
    final p = await _p;
    final out = <String, String>{};
    try {
      final raw = p.getString('servers');
      if (raw != null) (jsonDecode(raw) as Map).forEach((k, v) => out[k.toString()] = v.toString());
    } catch (_) {}
    // Earlier versions kept only one server.
    final one = p.getString('server');
    if (one != null && !out.containsKey(one)) out[one] = p.getString('serverName') ?? 'Jellyfin';
    return out;
  }

  static Future<String?> serverName([String? url]) async {
    final p = await _p;
    final s = url ?? p.getString('server');
    if (s == null) return null;
    final all = await servers();
    final name = all[s];
    return name == 'Jellyfin' && s == p.getString('server') ? (p.getString('serverName') ?? name) : name;
  }

  static Future<void> setServer(String url, String? name) async {
    final p = await _p;
    await p.setString('server', url);
    final all = await servers();
    all[url] = name ?? all[url] ?? 'Jellyfin';
    await p.setString('servers', jsonEncode(all));
    if (name != null) await p.setString('serverName', name);
  }

  // Before logins were kept per server, they sat under plain keys for the one server.
  static Future<bool> _isLegacy(String server) async {
    final p = await _p;
    return p.getString('server') == server && p.getString('profiles@$server') == null;
  }

  static Future<String?> lastUser([String? server]) async {
    final p = await _p;
    final s = server ?? p.getString('server');
    if (s == null) return null;
    return p.getString('lastUser@$s') ?? (await _isLegacy(s) ? p.getString('lastUser') : null);
  }

  static Future<Map<String, _Saved>> profiles([String? server]) async {
    final p = await _p;
    final s = server ?? p.getString('server');
    final out = <String, _Saved>{};
    if (s == null) return out;
    final legacy = await _isLegacy(s);
    try {
      final raw = p.getString('profiles@$s') ?? (legacy ? p.getString('profiles') : null);
      if (raw != null) {
        (jsonDecode(raw) as Map).forEach((id, v) {
          if (v is Map && v['token'] != null) {
            out[id.toString()] = _Saved((v['name'] ?? '').toString(), v['token'].toString(), v['tag']?.toString());
          }
        });
      }
    } catch (_) {}
    // The single login saved by the first versions of Frame.
    final oldToken = p.getString('token'), oldUser = p.getString('userId');
    if (legacy && oldToken != null && oldUser != null && !out.containsKey(oldUser)) {
      out[oldUser] = _Saved('', oldToken, null);
    }
    return out;
  }

  static Future<void> _write(String server, Map<String, _Saved> all) async {
    final p = await _p;
    await p.setString(
        'profiles@$server',
        jsonEncode({
          for (final e in all.entries) e.key: {'name': e.value.name, 'token': e.value.token, 'tag': e.value.tag}
        }));
  }

  static Future<void> remember(Jellyfin jf) async {
    final all = await profiles(jf.server);
    all[jf.userId!] = _Saved(jf.userName ?? '', jf.token!, jf.userImageTag);
    await _write(jf.server, all);
    final p = await _p;
    await p.setString('lastUser@${jf.server}', jf.userId!);
    await p.setString('server', jf.server);
    await p.remove('token');
    await p.remove('userId');
  }

  static Future<void> forget(String userId, [String? server]) async {
    final p = await _p;
    final s = server ?? p.getString('server');
    if (s == null) return;
    final all = await profiles(s);
    all.remove(userId);
    await _write(s, all);
    if (p.getString('userId') == userId) {
      await p.remove('token');
      await p.remove('userId');
    }
    if (p.getString('lastUser@$s') == userId) await p.remove('lastUser@$s');
  }

  /// Removes a saved server and every sign-in kept for it (not the one in use).
  static Future<void> forgetServer(String url) async {
    final p = await _p;
    final all = await servers();
    all.remove(url);
    await p.setString('servers', jsonEncode(all));
    await p.remove('profiles@$url');
    await p.remove('lastUser@$url');
  }

  /// How many profiles are signed in on a server on this device.
  static Future<int> signedIn(String url) async => (await profiles(url)).length;
}

// ---------- Opening Home for a profile ----------

void _openHome(BuildContext context, Jellyfin jf) {
  // Menus, panels and notifications use this profile's colour for their line.
  kAccent = accentFor(jf.userId ?? '').$1;
  ProfileStore.remember(jf).then((_) {}, onError: (_) {});
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => HomeScreen(jf: jf)),
    (_) => false,
  );
}

void _openWho(BuildContext context, String server) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => WhoScreen(server: server)),
    (_) => false,
  );
}

// ---------- Avatars ----------

const _accents = [
  (Color(0xFF6F8CFF), Color(0xFF3A4FB8)), // blue
  (Color(0xFFEE6E90), Color(0xFFA3324F)), // pink
  (Color(0xFF4FD1AE), Color(0xFF237A64)), // teal
  (Color(0xFFF2B05A), Color(0xFFA9661B)), // amber
  (Color(0xFFA884F5), Color(0xFF5B3BB0)), // violet
  (Color(0xFF5FC2EE), Color(0xFF2370A0)), // sky
];

(Color, Color) accentFor(String id) {
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _accents[h % _accents.length];
}

/// A profile's picture from Jellyfin, or its initial on its own colour.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.server, required this.id, required this.name, this.tag, required this.size});
  final String server;
  final String id;
  final String name;
  final String? tag;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (a, b) = accentFor(id);
    final initial = Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: tvDisplay(size * 0.42).copyWith(letterSpacing: 0));
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [a, b]),
      ),
      child: Center(child: initial),
    );
    final px = sizeBucket(tvPx(size));
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: tag == null
            ? fallback
            : netImage(
                '$server/Users/$id/Images/Primary?quality=90&maxWidth=$px&tag=$tag',
                cacheWidth: px,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}

// ---------- Finding servers on the network ----------

/// Asks the local network "who is a Jellyfin server?" (Jellyfin answers on port 7359).
Future<List<({String name, String address})>> discoverServers() async {
  final found = <String, ({String name, String address})>{};
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final done = Completer<void>();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket!.receive();
      if (d == null) return;
      try {
        final m = jsonDecode(utf8.decode(d.data));
        final address = (m['Address'] ?? '').toString().replaceAll(RegExp(r'/+$'), '');
        if (address.isNotEmpty) found[address] = (name: (m['Name'] ?? 'Jellyfin').toString(), address: address);
      } catch (_) {}
    });
    socket.send(utf8.encode('who is JellyfinServer?'), InternetAddress('255.255.255.255'), 7359);
    Timer(const Duration(milliseconds: 2500), () => done.complete());
    await done.future;
  } catch (e) {
    debugPrint('Servers: searching the network failed: $e');
  } finally {
    socket?.close();
  }
  return found.values.toList();
}

String _normalize(String text) {
  var a = text.trim().replaceAll(RegExp(r'/+$'), '');
  if (a.isEmpty) return a;
  if (!a.startsWith('http://') && !a.startsWith('https://')) a = 'http://$a';
  // Jellyfin's usual port when none is given (plain http only; https sites use their own).
  final uri = Uri.tryParse(a);
  if (uri != null && !uri.hasPort && uri.scheme == 'http') a = uri.replace(port: 8096).toString();
  return a.replaceAll(RegExp(r'/+$'), '');
}

// ---------- Shared pieces ----------

/// The outline of "Add profile": a dashed circle.
class _DashedCircle extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = kFg.withOpacity(0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    final r = size.width / 2 - 2;
    final c = Offset(size.width / 2, size.height / 2);
    const dashes = 36;
    for (var i = 0; i < dashes; i++) {
      final a = i * 2 * 3.141592653589793 / dashes;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a, 3.141592653589793 / dashes, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedCircle old) => false;
}

/// The dark room with a soft light in the selected profile's colour, fading between colours.
class _Room extends StatelessWidget {
  const _Room({required this.color, required this.center, required this.child});
  final Color color;
  final Alignment center;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kBg,
      child: Stack(children: [
        Positioned.fill(
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: color),
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOut,
            builder: (_, c, __) => DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: center,
                  radius: 0.75,
                  colors: [(c ?? color).withOpacity(0.30), (c ?? color).withOpacity(0)],
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(child: child),
      ]),
    );
  }
}

Widget _glassPill(String label, {required bool focused, IconData? icon}) => AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 26),
      decoration: BoxDecoration(
        color: focused ? kFg : kFg.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 24, color: focused ? kBg : kFg), const SizedBox(width: 10)],
        Text(label, style: tvBody(22, weight: FontWeight.w700, color: focused ? kBg : kFg)),
      ]),
    );

// Text fields: a button for the controller that opens the on-screen keyboard (keyboard.dart).
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.controller, this.obscure = false, this.autofocus = false, this.onSubmit, this.focusNode});
  final String label;
  final TextEditingController controller;
  final bool obscure;
  final bool autofocus;
  final VoidCallback? onSubmit;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => TvTextField(
        label: label,
        controller: controller,
        obscure: obscure,
        autofocus: autofocus,
        onSubmit: onSubmit,
        focusNode: focusNode,
      );
}

// Back (Escape / Circle) leaves the screen.
Widget _backOnEscape(BuildContext context, Widget child, {VoidCallback? onBack}) => Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
          if (onBack != null) {
            onBack();
          } else if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );

// ---------- Start: which screen to open ----------

class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    String? server;
    Map<String, _Saved> saved = {};
    String? last;
    try {
      server = await ProfileStore.server();
      saved = await ProfileStore.profiles();
      last = await ProfileStore.lastUser();
    } catch (_) {}
    if (!mounted) return;
    if (server == null) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ServerScreen()));
      return;
    }
    // Only one profile, already signed in: straight to Home, like before.
    // The server's profile list from last time decides at once (no wait for a sleeping NAS);
    // it's refreshed in the background for next time.
    final prefs = await SharedPreferences.getInstance();
    final cachedKey = 'publicIds@$server';
    final cached = prefs.getStringList(cachedKey);
    List<dynamic>? public;
    final fetch = Jellyfin(server).publicUsers().then((users) {
      prefs.setStringList(cachedKey, [for (final u in users) u['Id'].toString()]);
      return users;
    });
    if (cached == null) {
      try {
        public = await fetch.timeout(const Duration(seconds: 4));
      } catch (_) {}
    } else {
      fetch.then((_) {}, onError: (_) {});
    }
    if (!mounted) return;
    final ids = {...saved.keys, ...?cached, for (final u in public ?? []) u['Id'].toString()};
    final only = ids.length == 1 ? ids.first : null;
    final pick = only ?? (public == null && cached == null ? last : null); // server unreachable: last profile
    final s = pick == null ? null : saved[pick];
    if (pick != null && s != null) {
      final jf = Jellyfin(server)
        ..token = s.token
        ..userId = pick
        ..userName = s.name
        ..userImageTag = s.tag;
      final user = public?.cast<dynamic>().firstWhere((u) => u['Id'] == pick, orElse: () => null);
      if (user != null) {
        jf.userName = user['Name']?.toString();
        jf.userImageTag = user['PrimaryImageTag']?.toString();
      }
      _openHome(context, jf);
      return;
    }
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => WhoScreen(server: server!, initialUsers: public)));
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: kBg);
}

// ---------- Who's watching ----------

class _Profile {
  _Profile({required this.id, required this.name, this.tag, required this.hasPassword, this.saved});
  final String id;
  final String name;
  final String? tag;
  final bool hasPassword;
  final _Saved? saved;
}

class WhoScreen extends StatefulWidget {
  const WhoScreen({super.key, required this.server, this.initialUsers});
  final String server;
  final List<dynamic>? initialUsers;

  @override
  State<WhoScreen> createState() => _WhoScreenState();
}

class _WhoScreenState extends State<WhoScreen> {
  List<_Profile> _profiles = [];
  bool _loading = true;
  String? _error;
  String? _serverName;
  int _focused = 0;
  bool _busy = false;
  final _nodes = FocusNodeList("Who's watching: Profile");
  final _otherNode = namedNode("Who's watching: Someone else");
  final _serverNode = namedNode("Who's watching: Change server");

  @override
  void initState() {
    super.initState();
    _load(widget.initialUsers);
  }

  @override
  void dispose() {
    _nodes.dispose();
    _otherNode.dispose();
    _serverNode.dispose();
    super.dispose();
  }

  Future<void> _load([List<dynamic>? public]) async {
    final jf = Jellyfin(widget.server);
    final saved = await ProfileStore.profiles(widget.server);
    final last = await ProfileStore.lastUser(widget.server);
    _serverName = await ProfileStore.serverName(widget.server);
    String? error;
    if (public == null) {
      try {
        public = await jf.publicUsers();
      } catch (e) {
        error = errorText(e);
      }
    }
    // The name of the server, for the bottom line (once).
    if (_serverName == null) {
      jf.publicInfo().then((info) {
        final name = info['ServerName']?.toString();
        if (name != null) {
          ProfileStore.setServer(widget.server, name);
          if (mounted) setState(() => _serverName = name);
        }
      }, onError: (_) {});
    }
    final list = <_Profile>[];
    for (final u in public ?? const []) {
      final id = u['Id'].toString();
      list.add(_Profile(
        id: id,
        name: (u['Name'] ?? '').toString(),
        tag: u['PrimaryImageTag']?.toString(),
        hasPassword: u['HasPassword'] == true,
        saved: saved[id],
      ));
    }
    // Profiles signed in here but hidden from Jellyfin's login screen still show.
    for (final e in saved.entries) {
      if (list.any((p) => p.id == e.key)) continue;
      list.add(_Profile(id: e.key, name: e.value.name.isEmpty ? 'Profile' : e.value.name, tag: e.value.tag, hasPassword: true, saved: e.value));
    }
    if (!mounted) return;
    final start = list.indexWhere((p) => p.id == last);
    setState(() {
      _profiles = list;
      _loading = false;
      _error = list.isEmpty ? (error ?? 'No profiles found on this server.') : (public == null ? error : null);
      _focused = start < 0 ? 0 : start;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!focusOn(_profiles.isEmpty ? _otherNode : _nodes[_focused])) focusOn(_serverNode);
    });
  }

  Future<void> _choose(_Profile p) async {
    if (_busy) return;
    final saved = p.saved;
    final jf = Jellyfin(widget.server)
      ..userName = p.name
      ..userImageTag = p.tag;
    if (saved != null) {
      jf
        ..token = saved.token
        ..userId = p.id;
      _openHome(context, jf);
      return;
    }
    if (!p.hasPassword) {
      setState(() => _busy = true);
      try {
        await jf.login(p.name, '');
        if (mounted) _openHome(context, jf);
        return;
      } catch (_) {
        // Fall through to the sign-in screen.
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SignInScreen(server: widget.server, profile: (id: p.id, name: p.name, tag: p.tag))));
  }

  @override
  Widget build(BuildContext context) {
    final glow = _profiles.isEmpty ? const Color(0xFF6F8CFF) : accentFor(_profiles[_focused.clamp(0, _profiles.length - 1)].id).$1;
    return PadHints(
      hints: const [PadHint(PadButton.select, 'Choose')],
      child: Scaffold(
        backgroundColor: kBg,
        body: TvCanvas(
          child: _Room(
            color: glow,
            center: const Alignment(0, -0.05),
            child: Stack(children: [
              Positioned(left: 120, top: 56, child: Text('Frame', style: tvDisplay(34))),
              // The time, top right, like the control center.
              Positioned(
                right: 120,
                top: 62,
                child: StreamBuilder<int>(
                  stream: Stream.periodic(const Duration(seconds: 20), (i) => i),
                  builder: (_, __) {
                    final now = TimeOfDay.now();
                    return Text('${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                        style: tvBody(26, weight: FontWeight.w600, color: kSoft));
                  },
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 220,
                child: Text("Who's watching?", textAlign: TextAlign.center, style: tvDisplay(64)),
              ),
              if (!_loading)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 400,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 1920),
                      child: FocusLinks(
                        down: () => focusOn(_serverNode),
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const SizedBox(width: 120),
                          for (var i = 0; i < _profiles.length; i++) ...[
                            _tile(i),
                            const SizedBox(width: 56),
                          ],
                          _otherTile(),
                          const SizedBox(width: 120),
                        ]),
                      ),
                    ),
                  ),
                ),
              if (_error != null)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 790,
                  child: Text(_error!, textAlign: TextAlign.center, style: tvBody(22, color: kSoft)),
                ),
              Positioned(
                left: 120,
                bottom: 56,
                child: FocusLinks(
                  up: () => _profiles.isEmpty ? focusOn(_otherNode) : focusOn(_nodes[_focused]),
                  child: Row(children: [
                    // The server, in a quiet chip.
                    Container(
                      height: 56,
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      decoration: BoxDecoration(color: kFg.withOpacity(0.06), borderRadius: BorderRadius.circular(999)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _error == null ? const Color(0xFF5FD08A) : const Color(0xFFF0A23B),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(_serverName ?? 'Jellyfin', style: tvBody(22, weight: FontWeight.w600, color: kSoft)),
                        const SizedBox(width: 12),
                        Text(Uri.tryParse(widget.server)?.host ?? widget.server, style: tvBody(22, color: kMuted)),
                      ]),
                    ),
                    const SizedBox(width: 16),
                    Focusable(
                      focusNode: _serverNode,
                      onSelect: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => ServerScreen(current: widget.server))),
                      builder: (f) => _glassPill('Change server', focused: f, icon: Icons.dns_outlined),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _tile(int i) {
    final p = _profiles[i];
    return Focusable(
      focusNode: _nodes[i],
      onFocus: (_) => setState(() => _focused = i),
      onSelect: () => _choose(p),
      builder: (f) => _entrance(
        i,
        SizedBox(
          width: 260,
          child: Column(children: [
            SizedBox(
              height: 260,
              child: Center(
                child: AnimatedScale(
                  scale: f ? 1.0 : 0.83,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: f ? 1 : 0.72,
                    duration: const Duration(milliseconds: 220),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: f
                            ? const [BoxShadow(color: kBg, spreadRadius: 5), BoxShadow(color: kFg, spreadRadius: 11)]
                            : const [],
                      ),
                      child: ProfileAvatar(server: widget.server, id: p.id, name: p.name, tag: p.tag, size: 236),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 26),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (p.hasPassword && p.saved == null) ...[
                Icon(Icons.lock_outline_rounded, size: 22, color: f ? kFg : kMuted),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(p.name,
                    overflow: TextOverflow.ellipsis,
                    style: f
                        ? tvDisplay(34)
                        : tvBody(26, weight: FontWeight.w600, color: kSoft)),
              ),
            ]),
            const SizedBox(height: 16),
            // The selected profile's button: the same white pill as Play on Home.
            AnimatedOpacity(
              opacity: f ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                height: 56,
                padding: const EdgeInsets.fromLTRB(18, 0, 26, 0),
                decoration: BoxDecoration(color: kFg, borderRadius: BorderRadius.circular(999)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(p.saved != null || !p.hasPassword ? Icons.play_arrow_rounded : Icons.lock_open_rounded,
                      size: 28, color: kBg),
                  const SizedBox(width: 10),
                  Text(
                      _busy && f
                          ? 'Signing in…'
                          : (p.saved != null || !p.hasPassword ? 'Continue' : 'Sign in'),
                      style: tvBody(22, weight: FontWeight.w700, color: kBg)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _otherTile() {
    return Focusable(
      focusNode: _otherNode,
      onSelect: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => SignInScreen(server: widget.server))),
      builder: (f) => _entrance(
        _profiles.length,
        SizedBox(
          width: 260,
          child: Column(children: [
            SizedBox(
              height: 260,
              child: Center(
                child: AnimatedScale(
                  scale: f ? 1.0 : 0.83,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: 236,
                    height: 236,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: f ? kFg : Colors.transparent,
                      boxShadow: f ? const [BoxShadow(color: kBg, spreadRadius: 5), BoxShadow(color: kFg, spreadRadius: 11)] : const [],
                    ),
                    child: CustomPaint(
                      painter: f ? null : _DashedCircle(),
                      child: Icon(Icons.add_rounded, size: 72, color: f ? kBg : kFg),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 26),
            Text('Add profile', style: f ? tvDisplay(34) : tvBody(26, weight: FontWeight.w600, color: kSoft)),
          ]),
        ),
      ),
    );
  }

  // Profiles rise in one after the other when the screen opens.
  Widget _entrance(int i, Widget child) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: 380 + i * 70),
        curve: Interval((i * 70) / (380 + i * 70), 1, curve: Curves.easeOutCubic),
        builder: (_, t, c) => Opacity(opacity: t, child: Transform.translate(offset: Offset(0, 30 * (1 - t)), child: c)),
        child: child,
      );
}

// ---------- Signing in ----------

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.server, this.profile});
  final String server;
  final ({String id, String name, String? tag})? profile; // null: "Someone else"

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  late final Jellyfin _jf = Jellyfin(widget.server);
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _passNode = namedNode('Sign in: Password');
  final _backNode = namedNode('Sign in: Back');
  String? _error;
  bool _busy = false;

  // Quick Connect
  bool? _qcOn; // null = checking
  String? _code;
  String? _qcNote;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    if (widget.profile != null) _user.text = widget.profile!.name;
    _startQuickConnect();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _user.dispose();
    _pass.dispose();
    _passNode.dispose();
    _backNode.dispose();
    super.dispose();
  }

  Future<void> _startQuickConnect() async {
    final on = await _jf.quickConnectEnabled();
    if (!mounted) return;
    setState(() => _qcOn = on);
    if (!on) return;
    try {
      final qc = await _jf.quickConnectStart();
      if (!mounted) return;
      setState(() {
        _code = qc.code;
        _qcNote = 'Waiting for approval…';
      });
      _poll?.cancel();
      var asking = false; // one check at a time, even when the server is slow to answer
      var approved = false;
      _poll = Timer.periodic(const Duration(milliseconds: 2500), (_) async {
        if (asking) return;
        asking = true;
        try {
          if (!await _jf.quickConnectApproved(qc.secret)) return;
          _poll?.cancel();
          approved = true;
          if (mounted) setState(() => _qcNote = 'Approved, signing in…');
          await _jf.quickConnectFinish(qc.secret);
          if (mounted) _openHome(context, _jf);
        } catch (e) {
          if (e == 'expired' || approved) {
            // The code expired (after a few minutes), or signing in with it failed: new code.
            _poll?.cancel();
            if (mounted) _startQuickConnect();
          } else if (mounted) {
            // A network hiccup: keep the same code and keep checking.
            setState(() => _qcNote = errorText(e));
          }
        } finally {
          asking = false;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _qcNote = errorText(e));
    }
  }

  Future<void> _signIn() async {
    if (_busy) return;
    final name = _user.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Type the profile name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _jf.login(name, _pass.text);
      if (mounted) _openHome(context, _jf);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _spaced(String code) =>
      code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final glow = p == null ? const Color(0xFF6F8CFF) : accentFor(p.id).$1;
    return PadHints(
      hints: const [PadHint(PadButton.select, 'Select'), PadHint(PadButton.back, 'Back')],
      child: _backOnEscape(
        context,
        Scaffold(
          backgroundColor: kBg,
          body: TvCanvas(
            child: _Room(
              color: glow,
              center: const Alignment(0, -0.65),
              child: Stack(children: [
                Positioned(
                  left: 120,
                  top: 52,
                  child: Focusable(
                    focusNode: _backNode,
                    onSelect: () => Navigator.of(context).maybePop(),
                    builder: (f) => AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: f ? kFg : kFg.withOpacity(0.12),
                        boxShadow: f ? const [BoxShadow(color: kBg, spreadRadius: 3), BoxShadow(color: kFg, spreadRadius: 7)] : const [],
                      ),
                      child: Icon(Icons.arrow_back_rounded, size: 26, color: f ? kBg : kFg),
                    ),
                  ),
                ),
                // The time, top right, like Who's watching.
                Positioned(
                  right: 120,
                  top: 62,
                  child: StreamBuilder<int>(
                    stream: Stream.periodic(const Duration(seconds: 20), (i) => i),
                    builder: (_, __) {
                      final now = TimeOfDay.now();
                      return Text('${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                          style: tvBody(26, weight: FontWeight.w600, color: kSoft));
                    },
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 110,
                  child: Column(children: [
                    if (p != null)
                      ProfileAvatar(server: widget.server, id: p.id, name: p.name, tag: p.tag, size: 150)
                    else
                      // The same dashed circle as "Add profile" on Who's watching.
                      SizedBox.square(
                        dimension: 146,
                        child: CustomPaint(
                          painter: _DashedCircle(),
                          child: const Icon(Icons.add_rounded, size: 52, color: kFg),
                        ),
                      ),
                    const SizedBox(height: 22),
                    Text(p?.name ?? 'Add a profile', style: tvDisplay(52)),
                    const SizedBox(height: 12),
                    Text('Sign in once. Frame remembers this profile on this PC.', style: tvBody(24, color: kMuted)),
                  ]),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 440,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _card(
                      icon: Icons.smartphone_rounded,
                      title: 'Use your phone',
                      tag: 'Easiest',
                      children: _qcOn == false
                          ? [
                              Text('Quick Connect is off on your server.', style: tvBody(26, weight: FontWeight.w600)),
                              const SizedBox(height: 14),
                              Text('Turn it on once in Jellyfin: Dashboard › General › Quick Connect. Then you can sign in here without typing.',
                                  style: tvBody(22, color: kSoft, height: 1.45)),
                            ]
                          : [
                              // One digit per tile, in two groups of three: readable from the couch.
                              Row(children: [
                                for (var i = 0; i < 6; i++) ...[
                                  if (i == 3) const SizedBox(width: 22),
                                  Container(
                                    width: 82,
                                    height: 112,
                                    margin: EdgeInsets.only(right: i == 2 || i == 5 ? 0 : 10),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(color: kFg.withOpacity(0.08), borderRadius: BorderRadius.circular(20)),
                                    child: Text(
                                        _code != null && i < _code!.replaceAll(' ', '').length
                                            ? _code!.replaceAll(' ', '')[i]
                                            : '·',
                                        style: tvDisplay(68)),
                                  ),
                                ],
                              ]),
                              const SizedBox(height: 30),
                              Text('In the Jellyfin app or website, open your profile, choose Quick Connect and enter this code.',
                                  style: tvBody(23, color: kSoft, height: 1.45)),
                              const Spacer(),
                              Text(_qcNote ?? 'Getting a code…', style: tvBody(21, color: kMuted)),
                              const SizedBox(height: 12),
                              // A thin running line while Frame waits for the approval.
                              ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  minHeight: 4,
                                  backgroundColor: kFg.withOpacity(0.10),
                                  color: widget.profile == null ? kAccent : accentFor(widget.profile!.id).$1,
                                ),
                              ),
                            ],
                    ),
                    const SizedBox(width: 40),
                    _card(
                      icon: Icons.lock_outline_rounded,
                      title: 'Use a password',
                      children: [
                        if (p == null) ...[
                          _Field(label: 'Profile name', controller: _user, autofocus: true, onSubmit: () => _passNode.requestFocus()),
                          const SizedBox(height: 18),
                        ],
                        _Field(
                          label: 'Password',
                          controller: _pass,
                          obscure: true,
                          focusNode: _passNode,
                          autofocus: p != null,
                          onSubmit: _signIn,
                        ),
                        const Spacer(),
                        Row(children: [
                          Focusable(
                            onSelect: _signIn,
                            builder: (f) => _glassPill(_busy ? 'Signing in…' : 'Sign in', focused: f),
                          ),
                          const SizedBox(width: 20),
                          if (_error != null)
                            Expanded(child: Text(_error!, maxLines: 2, style: tvBody(20, color: const Color(0xFFFF9A8A)))),
                        ]),
                      ],
                      tall: p == null,
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // One way in: the new style's card (dark, see-through, big corners), no coloured top line.
  Widget _card({required IconData icon, required String title, required List<Widget> children, bool tall = false, String? tag}) {
    return Container(
      width: 700,
      height: 540,
      padding: const EdgeInsets.fromLTRB(48, 44, 48, 44),
      decoration: BoxDecoration(
        color: const Color(0xEB12151B),
        borderRadius: BorderRadius.circular(36),
        border: Border.all(color: kFg.withOpacity(0.08)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 30, color: kFg),
          const SizedBox(width: 14),
          Text(title, style: tvBody(30, weight: FontWeight.w700)),
          const Spacer(),
          if (tag != null)
            Text(tag.toUpperCase(), style: tvBody(18, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1.4)),
        ]),
        const SizedBox(height: 36),
        ...children,
      ]),
    );
  }
}

// ---------- Finding the server ----------

class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key, this.current});
  final String? current; // when changing server from Who's watching

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  final _address = TextEditingController();
  List<({String name, String address})>? _found;
  // Phones show these apart: servers saved on this device, and what the network answered.
  List<({String name, String address})> _saved = [];
  List<({String name, String address})>? _network;
  final Map<String, int> _signedIn = {};
  String? _error;
  bool _busy = false;
  final _cards = FocusNodeList('Server');

  @override
  void initState() {
    super.initState();
    if (widget.current != null) _address.text = widget.current!;
    _search();
  }

  @override
  void dispose() {
    _address.dispose();
    _cards.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _found = null;
      _network = null;
    });
    // Servers already signed in to on this PC first (yours, a friend's), then what the
    // network answers.
    final saved = await ProfileStore.servers();
    final list = <({String name, String address})>[
      for (final e in saved.entries) (name: e.value, address: e.key),
    ];
    for (final s in list) {
      _signedIn[s.address] = await ProfileStore.signedIn(s.address);
    }
    if (mounted) setState(() => _saved = List.of(list));
    final network = <({String name, String address})>[];
    for (final s in await discoverServers()) {
      if (!list.any((x) => x.address == s.address)) {
        list.add(s);
        network.add(s);
      }
    }
    if (!mounted) return;
    setState(() {
      _found = list;
      _network = network;
    });
    if (list.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => focusOn(_cards[0]));
  }

  Future<void> _connect(String text) async {
    final address = _normalize(text);
    if (address.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final info = await Jellyfin(address).publicInfo();
      await ProfileStore.setServer(address, info['ServerName']?.toString());
      if (mounted) _openWho(context, address);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // One server: a big card like a poster on Home, white and lifted when selected. The one
  // you're using is marked Connected.
  Widget _card(int i, ({String name, String address}) server, bool current) => Focusable(
        focusNode: _cards[i],
        onSelect: () => _connect(server.address),
        builder: (f) => AnimatedScale(
          scale: f ? 1.04 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 520,
            height: 230,
            padding: const EdgeInsets.all(30),
            decoration: BoxDecoration(
              color: f ? kFg : kFg.withOpacity(0.08),
              borderRadius: BorderRadius.circular(30),
              boxShadow: f ? const [BoxShadow(color: kBg, spreadRadius: 4), BoxShadow(color: kFg, spreadRadius: 9)] : const [],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.dns_outlined, size: 46, color: f ? kBg : kFg),
                const Spacer(),
                if (current)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(color: f ? kBg : kFg, borderRadius: BorderRadius.circular(999)),
                    child: Text('Connected', style: tvBody(18, weight: FontWeight.w700, color: f ? kFg : kBg)),
                  ),
              ]),
              const Spacer(),
              Text(server.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tvBody(30, weight: f ? FontWeight.w700 : FontWeight.w600, color: f ? kBg : kFg)),
              const SizedBox(height: 4),
              Text(server.address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tvBody(20, color: f ? kBg.withOpacity(0.7) : kMuted)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (isPhone(context)) return _phoneBuild(context);
    final searching = _found == null;
    final found = _found ?? const <({String name, String address})>[];
    final first = widget.current == null; // Frame's very first screen
    return PadHints(
      hints: [const PadHint(PadButton.select, 'Select'), if (!first) const PadHint(PadButton.back, 'Back')],
      child: _backOnEscape(
        context,
        Scaffold(
          backgroundColor: kBg,
          body: TvCanvas(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(120, 96, 120, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Title, and what Frame is doing.
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(first ? 'WELCOME TO FRAME' : 'SERVER',
                        style: tvBody(20, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1.6)),
                    const SizedBox(height: 10),
                    Text("Where's your library?", style: tvDisplay(64)),
                  ]),
                  const Spacer(),
                  if (searching)
                    Row(children: [
                      const Icon(Icons.wifi_rounded, size: 26, color: kSoft),
                      const SizedBox(width: 12),
                      Text('Looking on your network…', style: tvBody(22, color: kSoft)),
                    ])
                  else
                    Focusable(
                      onSelect: _search,
                      builder: (f) => _glassPill('Search again', focused: f, icon: Icons.refresh_rounded),
                    ),
                ]),
                const SizedBox(height: 56),
                // Servers: yours first, then what the network answered.
                Text(
                    searching
                        ? ' '
                        : found.isEmpty
                            ? 'None found on this network: type its address below.'
                            : 'Your servers',
                    style: tvBody(22, weight: FontWeight.w700, color: kSoft)),
                const SizedBox(height: 20),
                SizedBox(
                  height: 250,
                  child: found.isEmpty
                      ? const SizedBox.shrink()
                      : FocusTraversalGroup(
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            clipBehavior: Clip.none,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            itemCount: found.length,
                            separatorBuilder: (_, __) => const SizedBox(width: 30),
                            itemBuilder: (_, i) => _card(i, found[i], found[i].address == widget.current),
                          ),
                        ),
                ),
                const SizedBox(height: 40),
                // Or type an address.
                Text('Or enter an address', style: tvBody(22, weight: FontWeight.w700, color: kSoft)),
                const SizedBox(height: 8),
                SizedBox(
                  width: 1100,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: _Field(
                        label: 'For example 192.168.1.10:8096',
                        controller: _address,
                        autofocus: false,
                        onSubmit: () => _connect(_address.text),
                      ),
                    ),
                    const SizedBox(width: 20),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Focusable(
                        onSelect: () => _connect(_address.text),
                        builder: (f) => _glassPill(_busy ? 'Connecting…' : 'Connect', focused: f, icon: Icons.arrow_forward_rounded),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 14),
                Text(_error ?? 'Selecting the box opens the on-screen keyboard. Your profiles on each server are kept.',
                    style: tvBody(20, color: _error != null ? const Color(0xFFFF9A8A) : kMuted)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- Phone layout ----------
  //
  // Upright: your servers (the one in use white and marked Connected, the others to switch
  // to, swipe left to forget one), then what Frame finds on the Wi-Fi, and Add for an address.
  // Sideways: the title and Add on the left, the lists on the right.

  bool _phoneRotationSet = false;

  Future<void> _forgetServer(String address) async {
    setState(() {
      _saved.removeWhere((s) => s.address == address);
      _found?.removeWhere((s) => s.address == address);
    });
    try {
      await ProfileStore.forgetServer(address);
    } catch (_) {}
  }

  Future<void> _phoneAdd() async {
    final address = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF151920),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => const _PhoneAddServer(),
    );
    if (address != null && mounted) _connect(address);
  }

  Widget _phoneLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: phoneText(12, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1)),
      );

  Widget _phoneServerRow(({String name, String address}) s, {required bool saved, required bool upright}) {
    final current = s.address == widget.current;
    final host = Uri.tryParse(s.address)?.authority ?? s.address;
    final count = _signedIn[s.address] ?? 0;
    final sub = saved ? '$host · ${count == 1 ? '1 profile' : '$count profiles'} signed in' : host;
    final fg = current ? kBg : kFg;
    final card = Material(
      color: current ? kFg : (saved ? const Color(0xFF20252E) : const Color(0xB32C313B)),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _busy
            ? null
            : () {
                phoneTap();
                _connect(s.address);
              },
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: upright ? 14 : 12),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: current ? kBg : const Color(0xBF4A4E57),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(saved ? Icons.dns_outlined : Icons.wifi_rounded, size: 22, color: kFg),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: phoneText(17, weight: FontWeight.w700, color: fg)),
                const SizedBox(height: 2),
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: phoneText(13, color: current ? const Color(0xFF3B414C) : kMuted)),
              ]),
            ),
            const SizedBox(width: 10),
            if (current)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(999)),
                child: Text('Connected', style: phoneText(12, weight: FontWeight.w700)),
              )
            else
              Text(saved ? 'Switch' : 'Connect', style: phoneText(15, weight: FontWeight.w700)),
          ]),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      // Swipe a saved server (not the one in use) to the left to forget it and its sign-ins.
      child: saved && !current
          ? Dismissible(
              key: ValueKey('server ${s.address}'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                decoration: BoxDecoration(color: const Color(0xFF8A2E2E), borderRadius: BorderRadius.circular(18)),
                child: Text('Forget', style: phoneText(15, weight: FontWeight.w700)),
              ),
              onDismissed: (_) {
                HapticFeedback.mediumImpact();
                _forgetServer(s.address);
              },
              child: card,
            )
          : card,
    );
  }

  Widget _phoneBuild(BuildContext context) {
    if (!_phoneRotationSet) {
      _phoneRotationSet = true;
      phoneAnyOrientation();
    }
    final upright = isUpright(context);
    final pad = MediaQuery.paddingOf(context);
    final m = phoneMargins(context, min: upright ? 20 : 44);
    final first = widget.current == null; // Frame's very first screen
    final canBack = !first && Navigator.of(context).canPop();
    final searching = _network == null;
    final network = _network ?? const <({String name, String address})>[];

    final back = Semantics(
      button: true,
      label: 'Back',
      child: GestureDetector(
        onTap: () {
          phoneTap();
          Navigator.of(context).pop();
        },
        child: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(color: Color(0x8C4A4E57), shape: BoxShape.circle),
          child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: kFg),
        ),
      ),
    );
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(first ? 'WELCOME TO FRAME' : 'SERVER',
          style: phoneText(12, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1.2)),
      const SizedBox(height: 6),
      Text("Where's your library?", style: phoneTitle(upright ? 30 : 28)),
    ]);
    final note = Text('Each server keeps its own sign-ins, so switching back is instant.',
        style: phoneText(13, weight: FontWeight.w500, color: kMuted, height: 1.5));

    final lists = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_saved.isNotEmpty) ...[
        _phoneLabel('YOUR SERVERS'),
        for (final s in _saved) _phoneServerRow(s, saved: true, upright: upright),
        const SizedBox(height: 12),
      ],
      Row(children: [
        Expanded(child: _phoneLabel('ON YOUR NETWORK')),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: searching
              ? Row(children: [
                  const SizedBox(
                      width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kMuted)),
                  const SizedBox(width: 8),
                  Text('Looking…', style: phoneText(13, color: kMuted)),
                ])
              : GestureDetector(
                  onTap: () {
                    phoneTap();
                    _search();
                  },
                  child: Text('Search again', style: phoneText(13, weight: FontWeight.w700)),
                ),
        ),
      ]),
      if (!searching && network.isEmpty)
        Text('Nothing else found on this Wi-Fi. Add a server by its address.',
            style: phoneText(14, weight: FontWeight.w500, color: kMuted, height: 1.4)),
      for (final s in network) _phoneServerRow(s, saved: false, upright: upright),
      if (_busy) ...[
        const SizedBox(height: 8),
        Text('Connecting…', style: phoneText(14, color: kSoft)),
      ],
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: phoneText(14, weight: FontWeight.w500, color: const Color(0xFFFF9A8A), height: 1.4)),
      ],
    ]);

    if (upright) {
      return Scaffold(
        backgroundColor: kBg,
        body: ListView(
          padding: EdgeInsets.fromLTRB(m.left, pad.top + 10, m.right, pad.bottom + 28),
          children: [
            Row(children: [
              if (canBack) back,
              const Spacer(),
              PhoneButton(label: 'Add', icon: Icons.add_rounded, height: 44, onTap: _phoneAdd),
            ]),
            const SizedBox(height: 22),
            title,
            const SizedBox(height: 26),
            lists,
            const SizedBox(height: 20),
            note,
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: kBg,
      body: Padding(
        padding: EdgeInsets.fromLTRB(m.left, pad.top + 16, m.right, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 270,
            child: Padding(
              padding: EdgeInsets.only(bottom: pad.bottom + 18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (canBack) back,
                const SizedBox(height: 18),
                title,
                const SizedBox(height: 12),
                note,
                const Spacer(),
                PhoneButton(label: 'Add a server', icon: Icons.add_rounded, height: 44, onTap: _phoneAdd),
              ]),
            ),
          ),
          const SizedBox(width: 28),
          Expanded(
            child: ListView(
              padding: EdgeInsets.only(top: 6, bottom: pad.bottom + 20),
              children: [lists],
            ),
          ),
        ]),
      ),
    );
  }
}

/// Phones: the Add a server sheet. One address field (the phone's own keyboard), checked as
/// you type, and Connect. Pops with the address to connect to.
class _PhoneAddServer extends StatefulWidget {
  const _PhoneAddServer();

  @override
  State<_PhoneAddServer> createState() => _PhoneAddServerState();
}

class _PhoneAddServerState extends State<_PhoneAddServer> {
  final _text = TextEditingController();
  Timer? _check;
  String? _found; // "Home Theater · Jellyfin 10.10.3" once the address answers
  bool _checking = false;
  bool _noAnswer = false;

  @override
  void dispose() {
    _check?.cancel();
    _text.dispose();
    super.dispose();
  }

  // A moment after typing stops, see whether a Jellyfin server answers there.
  void _changed(String value) {
    _check?.cancel();
    setState(() {
      _found = null;
      _noAnswer = false;
      _checking = false;
    });
    final address = _normalize(value);
    if (address.length < 10) return;
    _check = Timer(const Duration(milliseconds: 700), () async {
      if (!mounted) return;
      setState(() => _checking = true);
      try {
        final info = await Jellyfin(address).publicInfo().timeout(const Duration(seconds: 5));
        if (!mounted || _normalize(_text.text) != address) return;
        final version = info['Version']?.toString();
        setState(() {
          _found = '${info['ServerName'] ?? 'Jellyfin'} · Jellyfin${version == null ? '' : ' $version'}';
          _checking = false;
        });
      } catch (_) {
        if (!mounted || _normalize(_text.text) != address) return;
        setState(() {
          _noAnswer = true;
          _checking = false;
        });
      }
    });
  }

  void _submit() {
    final address = _normalize(_text.text);
    if (address.isEmpty) return;
    phoneTap();
    Navigator.of(context).pop(address);
  }

  @override
  Widget build(BuildContext context) {
    final ready = _text.text.trim().isNotEmpty;
    return ValueListenableBuilder<double>(
      // The app takes the keyboard out of the layout (see _phoneFrame); keep the sheet above it.
      valueListenable: keyboardInset,
      builder: (context, inset, _) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 10, 20, 20 + inset),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Center(
            child: Container(
              width: 40,
              height: 5,
              decoration: BoxDecoration(color: const Color(0x4DF4F5F7), borderRadius: BorderRadius.circular(3)),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: phoneText(16, color: kSoft)),
            ),
            Expanded(child: Center(child: Text('Add a server', style: phoneTitle(18)))),
            Opacity(
              opacity: ready ? 1 : 0.4,
              child: PhoneButton(primary: true, label: 'Connect', height: 40, onTap: ready ? _submit : () {}),
            ),
          ]),
          const SizedBox(height: 16),
          Text('ADDRESS', style: phoneText(12, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1)),
          const SizedBox(height: 8),
          TextField(
            controller: _text,
            autofocus: true,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.go,
            onChanged: _changed,
            onSubmitted: (_) => _submit(),
            cursorColor: kFg,
            style: phoneText(17),
            decoration: InputDecoration(
              hintText: '192.168.1.10:8096 or jellyfin.example.com',
              hintStyle: phoneText(16, weight: FontWeight.w500, color: kDim),
              filled: true,
              fillColor: const Color(0xFF0E1116),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: Color(0x40F4F5F7), width: 2),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: kFg, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('With or without http://. Port 8096 if you leave it out.',
              style: phoneText(13, weight: FontWeight.w500, color: kMuted)),
          const SizedBox(height: 14),
          if (_checking)
            Row(children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kMuted)),
              const SizedBox(width: 10),
              Text('Checking…', style: phoneText(14, color: kMuted)),
            ])
          else if (_found != null)
            Row(children: [
              const Icon(Icons.check_circle_outline_rounded, size: 20, color: Color(0xFF3FCFA6)),
              const SizedBox(width: 10),
              Expanded(child: Text('Found $_found', style: phoneText(14, weight: FontWeight.w700))),
            ])
          else if (_noAnswer)
            Text('No Jellyfin server answers there yet. Check the address, or connect anyway.',
                style: phoneText(14, weight: FontWeight.w500, color: const Color(0xFFFF9A8A), height: 1.4)),
        ]),
      ),
    );
  }
}

// ---------- The profile chip and menu on Home ----------

/// Top right of Home, like a console: small avatar, name, server. Triangle / Y or a click
/// opens the menu.
class ProfileChip extends StatelessWidget {
  const ProfileChip({super.key, required this.jf, required this.serverName, this.focusNode});
  final Jellyfin jf;
  final String? serverName;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      focusNode: focusNode,
      onSelect: () => showProfileMenu(context, jf),
      builder: (f) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.fromLTRB(4, 4, 20, 4),
        decoration: BoxDecoration(
          color: f ? kPillFill : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: f ? kBg : Colors.transparent, spreadRadius: 3),
                BoxShadow(color: f ? kFg : kFg.withOpacity(0.22), spreadRadius: f ? 6 : 2),
              ],
            ),
            child: ProfileAvatar(server: jf.server, id: jf.userId ?? '', name: jf.userName ?? '', tag: jf.userImageTag, size: 48),
          ),
          const SizedBox(width: 14),
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(jf.userName?.isNotEmpty == true ? jf.userName! : 'Profile', style: tvBody(22, weight: FontWeight.w700)),
            if (serverName != null) Text(serverName!, style: tvBody(16, color: kDim)),
          ]),
        ]),
      ),
    );
  }
}

Future<void> showProfileMenu(BuildContext context, Jellyfin jf) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: const Color(0x9E06080B),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (ctx, _, __) => _ProfileMenu(jf: jf, home: context),
    // Slides up from the bottom, like the PS5's control center.
    transitionBuilder: (ctx, a, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: const Interval(0, 0.6, curve: Curves.easeOut)),
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.18), end: Offset.zero)
            .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );
}

class _ProfileMenu extends StatefulWidget {
  const _ProfileMenu({required this.jf, required this.home});
  final Jellyfin jf;
  final BuildContext home; // the screen behind (banners and the party menu open there)

  @override
  State<_ProfileMenu> createState() => _ProfileMenuState();
}

class _ProfileMenuState extends State<_ProfileMenu> {
  String? _serverName;
  bool _confirmSignOut = false;

  @override
  void initState() {
    super.initState();
    ProfileStore.serverName(jf.server).then((n) {
      if (mounted) setState(() => _serverName = n);
    }, onError: (_) {});
  }

  Jellyfin get jf => widget.jf;

  // Another profile or signing out ends this profile's party first.
  void _switch() {
    SyncPlay.of(jf).leave();
    _openWho(context, jf.server);
  }

  void _party() {
    final ctx = widget.home;
    Navigator.of(context).pop();
    if (SyncPlay.of(jf).inParty) {
      showPartyMenu(ctx, jf);
    } else {
      showStartParty(ctx, jf);
    }
  }

  void _server() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServerScreen(current: jf.server)));
  }

  Future<void> _signOut() async {
    if (!_confirmSignOut) {
      setState(() => _confirmSignOut = true);
      return;
    }
    // End the login on the server too, so it no longer works anywhere.
    try {
      await jf.postPath('/Sessions/Logout').timeout(const Duration(seconds: 4));
    } catch (_) {}
    await SyncPlay.of(jf).leave();
    if (jf.userId != null) await ProfileStore.forget(jf.userId!, jf.server);
    if (mounted) _openWho(context, jf.server);
  }

  // One big tile of the control center: white and slightly lifted when selected, like a poster
  // on Home (a ring of spread-only shadows: no blur, cheap to draw at any size).
  Widget _tile(IconData icon, String label, VoidCallback onSelect, {bool autofocus = false, bool warn = false}) {
    return Focusable(
      autofocus: autofocus,
      onSelect: onSelect,
      builder: (f) => AnimatedScale(
        scale: f ? 1.06 : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 240,
          height: 200,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: f ? kFg : kFg.withOpacity(0.08),
            borderRadius: BorderRadius.circular(28),
            boxShadow: f
                ? const [BoxShadow(color: _sheet, spreadRadius: 4), BoxShadow(color: kFg, spreadRadius: 9)]
                : const [],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 44, color: f ? kBg : (warn ? const Color(0xFFEE6E90) : kFg)),
            const Spacer(),
            Text(label,
                maxLines: 2,
                style: tvBody(26, weight: f ? FontWeight.w700 : FontWeight.w600, color: f ? kBg : kFg, height: 1.15)),
          ]),
        ),
      ),
    );
  }

  static const _sheet = Color(0xFF12151B);

  // Phones: a sheet from the bottom (upright) or a panel from the right (sideways), in phone
  // sizes. Who you are, the server you're on with Change, then the actions. Drag it away or
  // tap outside to close.
  Widget _phoneMenu(BuildContext context, String name, bool inParty) {
    final upright = isUpright(context);
    final pad = MediaQuery.paddingOf(context);
    final server = _serverName ?? 'Jellyfin';
    final host = Uri.tryParse(jf.server)?.host ?? '';
    const divider = Divider(height: 1, thickness: 1, color: Color(0x14F4F5F7));

    Widget action(IconData icon, String label, VoidCallback onTap, {bool warn = false}) {
      final color = warn ? const Color(0xFFFF9A8A) : kFg;
      return InkWell(
        onTap: () {
          phoneTap();
          onTap();
        },
        child: SizedBox(
          height: upright ? 56 : 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(width: 14),
              Expanded(child: Text(label, style: phoneText(16, color: color))),
            ]),
          ),
        ),
      );
    }

    final content = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (upright) ...[
        Center(
          child: Container(
            width: 40,
            height: 5,
            decoration: BoxDecoration(color: const Color(0x4DF4F5F7), borderRadius: BorderRadius.circular(3)),
          ),
        ),
        const SizedBox(height: 16),
      ],
      Row(children: [
        ProfileAvatar(server: jf.server, id: jf.userId ?? '', name: name, tag: jf.userImageTag, size: upright ? 56 : 48),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: phoneTitle(upright ? 22 : 20)),
            const SizedBox(height: 2),
            Text('$server · $host',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: phoneText(13, color: kMuted)),
          ]),
        ),
      ]),
      SizedBox(height: upright ? 18 : 12),
      // The server you're on, with Change: opens Change server.
      Material(
        color: const Color(0xD92C313B),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            phoneTap();
            _server();
          },
          child: Padding(
            padding: EdgeInsets.all(upright ? 14 : 10),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: const Color(0xBF4A4E57), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.dns_outlined, size: 20, color: kFg),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('SERVER', style: phoneText(11, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 0.8)),
                  const SizedBox(height: 2),
                  Text(server,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: phoneText(16, weight: FontWeight.w700)),
                ]),
              ),
              Text('Change', style: phoneText(14, weight: FontWeight.w700)),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded, size: 20, color: kFg),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Material(
          color: const Color(0x8C2C313B),
          child: Column(children: [
            action(Icons.groups_rounded, inParty ? 'Your watch party' : 'Start a watch party', _party),
            divider,
            action(Icons.switch_account_rounded, 'Switch profile', _switch),
            divider,
            action(Icons.logout_rounded, _confirmSignOut ? 'Tap again to sign out' : 'Sign out', _signOut,
                warn: _confirmSignOut),
          ]),
        ),
      ),
    ]);

    final close = () => Navigator.of(context).pop();
    if (upright) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: GestureDetector(
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) > 300) close();
          },
          child: Material(
            color: const Color(0xFF151920),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 10, 20, pad.bottom + 20),
              child: content,
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onHorizontalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) close();
        },
        child: Material(
          color: const Color(0xFF151920),
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(24)),
          child: SizedBox(
            width: 400 + pad.right,
            height: double.infinity,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(24, pad.top + 20, pad.right > 24 ? pad.right : 24, pad.bottom + 18),
              child: content,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = jf.userName?.isNotEmpty == true ? jf.userName! : 'Profile';
    final now = TimeOfDay.now();
    final clock = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final inParty = SyncPlay.of(jf).inParty;
    if (isPhone(context)) return _phoneMenu(context, name, inParty);
    return PadHints(
      hints: const [PadHint(PadButton.select, 'Select'), PadHint(PadButton.back, 'Close')],
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent &&
              (e.logicalKey == LogicalKeyboardKey.contextMenu || e.logicalKey == LogicalKeyboardKey.escape)) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TvCanvas(
          child: Stack(children: [
            // The control center: a sheet across the bottom of the screen.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  height: 470,
                  padding: const EdgeInsets.fromLTRB(120, 40, 120, 0),
                  decoration: BoxDecoration(
                    color: _sheet.withOpacity(0.97),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(36)),
                    border: Border(top: BorderSide(color: kFg.withOpacity(0.08))),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Who you are, and the time.
                    Row(children: [
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [const BoxShadow(color: _sheet, spreadRadius: 3), BoxShadow(color: kAccent, spreadRadius: 6)],
                        ),
                        child: ProfileAvatar(server: jf.server, id: jf.userId ?? '', name: name, tag: jf.userImageTag, size: 72),
                      ),
                      const SizedBox(width: 22),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(name, style: tvDisplay(32)),
                          const SizedBox(height: 4),
                          Text('${_serverName ?? 'Jellyfin'} · ${Uri.tryParse(jf.server)?.host ?? ''}',
                              overflow: TextOverflow.ellipsis, style: tvBody(22, color: kMuted)),
                        ]),
                      ),
                      Text(clock, style: tvBody(26, weight: FontWeight.w600, color: kSoft)),
                    ]),
                    const SizedBox(height: 40),
                    // The actions: big tiles in one row.
                    FocusTraversalGroup(
                      child: Row(children: [
                        _tile(Icons.groups_rounded, inParty ? 'Your watch party' : 'Start a watch party', _party,
                            autofocus: true),
                        const SizedBox(width: 28),
                        _tile(Icons.switch_account_rounded, 'Switch profile', _switch),
                        const SizedBox(width: 28),
                        _tile(Icons.dns_outlined, 'Server', _server),
                        const SizedBox(width: 28),
                        _tile(Icons.logout_rounded, _confirmSignOut ? 'Press again to sign out' : 'Sign out', _signOut,
                            warn: _confirmSignOut),
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
