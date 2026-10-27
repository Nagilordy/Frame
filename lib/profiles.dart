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
    List<dynamic>? public;
    try {
      public = await Jellyfin(server).publicUsers().timeout(const Duration(seconds: 4));
    } catch (_) {}
    if (!mounted) return;
    final ids = {...saved.keys, for (final u in public ?? []) u['Id'].toString()};
    final only = ids.length == 1 ? ids.first : null;
    final pick = only ?? (public == null ? last : null); // server unreachable: last profile
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
              Positioned(
                left: 0,
                right: 0,
                top: 230,
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
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _error == null ? const Color(0xFF5FD08A) : const Color(0xFFF0A23B),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Text(_serverName ?? 'Jellyfin', style: tvBody(22, weight: FontWeight.w600, color: kSoft)),
                    const SizedBox(width: 12),
                    Text(Uri.tryParse(widget.server)?.host ?? widget.server, style: tvBody(22, color: kDim)),
                    const SizedBox(width: 20),
                    Focusable(
                      focusNode: _serverNode,
                      onSelect: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => ServerScreen(current: widget.server))),
                      builder: (f) => _glassPill('Change server', focused: f),
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
                            ? const [
                                BoxShadow(color: kBg, spreadRadius: 6),
                                BoxShadow(color: kFg, spreadRadius: 11),
                                BoxShadow(color: Color(0x99000000), blurRadius: 80, offset: Offset(0, 30), spreadRadius: 11),
                              ]
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
                    style: tvBody(f ? 32 : 26, weight: f ? FontWeight.w700 : FontWeight.w500, color: f ? kFg : kMuted)),
              ),
            ]),
            const SizedBox(height: 10),
            AnimatedOpacity(
              opacity: f ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Text(
                _busy && f ? 'Signing in…' : (p.saved != null ? 'Signed in on this PC' : (p.hasPassword ? 'Sign in' : '')),
                style: tvBody(20, color: kDim),
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
                      color: kFg.withOpacity(f ? 0.22 : 0.10),
                      border: f ? Border.all(color: kFg, width: 5) : null,
                    ),
                    child: Icon(Icons.add_rounded, size: 72, color: f ? kFg : kMuted),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 26),
            Text('Someone else', style: tvBody(f ? 32 : 26, weight: f ? FontWeight.w700 : FontWeight.w500, color: f ? kFg : kMuted)),
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
      _poll = Timer.periodic(const Duration(milliseconds: 2500), (_) async {
        try {
          if (!await _jf.quickConnectApproved(qc.secret)) return;
          _poll?.cancel();
          if (mounted) setState(() => _qcNote = 'Approved, signing in…');
          await _jf.quickConnectFinish(qc.secret);
          if (mounted) _openHome(context, _jf);
        } catch (e) {
          // The code expired (after a few minutes): get a new one.
          _poll?.cancel();
          if (mounted) _startQuickConnect();
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
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: f ? kFg : kFg.withOpacity(0.12)),
                      child: Icon(Icons.arrow_back_rounded, size: 26, color: f ? kBg : kFg),
                    ),
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
                      Container(
                        width: 150,
                        height: 150,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: kFg.withOpacity(0.10)),
                        child: const Icon(Icons.person_outline_rounded, size: 64, color: kMuted),
                      ),
                    const SizedBox(height: 20),
                    Text(p?.name ?? 'Sign in', style: tvDisplay(48)),
                    const SizedBox(height: 14),
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
                      children: _qcOn == false
                          ? [
                              Text('Quick Connect is off on your server.', style: tvBody(26, weight: FontWeight.w600)),
                              const SizedBox(height: 14),
                              Text('Turn it on once in Jellyfin: Dashboard › General › Quick Connect. Then you can sign in here without typing.',
                                  style: tvBody(22, color: kSoft, height: 1.45)),
                            ]
                          : [
                              Text(_code == null ? '··· ···' : _spaced(_code!),
                                  style: tvDisplay(92).copyWith(letterSpacing: 92 * 0.12)),
                              const SizedBox(height: 22),
                              Text('In the Jellyfin app or website, open your profile, choose Quick Connect and enter this code.',
                                  style: tvBody(23, color: kSoft, height: 1.45)),
                              const Spacer(),
                              Row(children: [
                                Container(
                                    width: 10,
                                    height: 10,
                                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFF0A23B))),
                                const SizedBox(width: 12),
                                Text(_qcNote ?? 'Getting a code…', style: tvBody(21, color: kDim)),
                              ]),
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

  Widget _card({required IconData icon, required String title, required List<Widget> children, bool tall = false}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        width: 660,
        height: tall ? 520 : 420,
        padding: const EdgeInsets.fromLTRB(48, 44, 48, 40),
        // The same solid surface as menus and panels, with the profile's colour on top.
        decoration: BoxDecoration(
          color: kSurface,
          border: Border(top: BorderSide(color: widget.profile == null ? kAccent : accentFor(widget.profile!.id).$1, width: 4)),
          boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 80, offset: Offset(0, 30))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 30, color: kFg),
            const SizedBox(width: 14),
            Text(title, style: tvBody(30, weight: FontWeight.w700)),
          ]),
          const SizedBox(height: 26),
          ...children,
        ]),
      ),
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
    setState(() => _found = null);
    // Servers already signed in to on this PC first (yours, a friend's), then what the
    // network answers.
    final saved = await ProfileStore.servers();
    final list = <({String name, String address})>[
      for (final e in saved.entries) (name: e.value, address: e.key),
    ];
    for (final s in await discoverServers()) {
      if (!list.any((x) => x.address == s.address)) list.add(s);
    }
    if (!mounted) return;
    setState(() => _found = list);
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

  @override
  Widget build(BuildContext context) {
    final searching = _found == null;
    final found = _found ?? const <({String name, String address})>[];
    return PadHints(
      hints: [const PadHint(PadButton.select, 'Select'), if (widget.current != null) const PadHint(PadButton.back, 'Back')],
      child: _backOnEscape(
        context,
        Scaffold(
          backgroundColor: kBg,
          body: TvCanvas(
            child: _Room(
              color: const Color(0xFF6F8CFF),
              center: const Alignment(0, -0.4),
              child: Stack(children: [
                Positioned(left: 120, top: 56, child: Text('Frame', style: tvDisplay(34))),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 200,
                  child: Column(children: [
                    Text('Find your Jellyfin server', style: tvDisplay(60)),
                    const SizedBox(height: 18),
                    Text(searching ? 'Looking on your network…' : (found.isEmpty ? 'None found on this network. Type its address below.' : 'Your servers'),
                        style: tvBody(24, color: kMuted)),
                  ]),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 380,
                  child: Wrap(alignment: WrapAlignment.center, spacing: 32, runSpacing: 24, children: [
                    for (var i = 0; i < found.length; i++)
                      Focusable(
                        focusNode: _cards[i],
                        onSelect: () => _connect(found[i].address),
                        builder: (f) => AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          width: 520,
                          padding: const EdgeInsets.all(32),
                          decoration: BoxDecoration(
                            color: f ? kFg : kFg.withOpacity(0.10),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Row(children: [
                            Icon(Icons.dns_rounded, size: 40, color: f ? kBg : kFg),
                            const SizedBox(width: 22),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(found[i].name, style: tvBody(28, weight: FontWeight.w700, color: f ? kBg : kFg)),
                                const SizedBox(height: 6),
                                Text(found[i].address, style: tvBody(20, color: f ? kBg.withOpacity(0.7) : kDim)),
                              ]),
                            ),
                          ]),
                        ),
                      ),
                  ]),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 640,
                  child: Center(
                    child: SizedBox(
                      width: 860,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Expanded(
                            child: _Field(
                              label: 'Or type its address (for example 10.0.0.33:8096)',
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
                              builder: (f) => _glassPill(_busy ? 'Connecting…' : 'Connect', focused: f),
                            ),
                          ),
                        ]),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Text(_error!, style: tvBody(22, color: const Color(0xFFFF9A8A))),
                        ],
                      ]),
                    ),
                  ),
                ),
                Positioned(
                  left: 120,
                  bottom: 56,
                  child: Focusable(
                    onSelect: _search,
                    builder: (f) => _glassPill('Search again', focused: f, icon: Icons.refresh_rounded),
                  ),
                ),
              ]),
            ),
          ),
        ),
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
    barrierColor: const Color(0x8C06080B),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, __) => _ProfileMenu(jf: jf),
    transitionBuilder: (ctx, a, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween(begin: const Offset(0, -0.015), end: Offset.zero)
            .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );
}

class _ProfileMenu extends StatefulWidget {
  const _ProfileMenu({required this.jf});
  final Jellyfin jf;

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

  void _switch() => _openWho(context, jf.server);

  void _server() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServerScreen(current: jf.server)));
  }

  Future<void> _signOut() async {
    if (!_confirmSignOut) {
      setState(() => _confirmSignOut = true);
      return;
    }
    if (jf.userId != null) await ProfileStore.forget(jf.userId!, jf.server);
    if (mounted) _openWho(context, jf.server);
  }

  Widget _item(IconData icon, String label, VoidCallback onSelect, {bool autofocus = false, bool quiet = false}) {
    return Focusable(
      autofocus: autofocus,
      onSelect: onSelect,
      builder: (f) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: surfaceRow(label, focused: f, icon: icon, quiet: quiet),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = jf.userName?.isNotEmpty == true ? jf.userName! : 'Profile';
    return PadHints(
      hints: const [PadHint(PadButton.select, 'Select'), PadHint(PadButton.menu, 'Close')],
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
            Positioned(
              right: 120,
              top: 128,
              child: Material(
                type: MaterialType.transparency,
                child: Surface(
                    width: 520,
                    padding: const EdgeInsets.all(18),
                    child: FocusTraversalGroup(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                          child: Row(children: [
                            ProfileAvatar(server: jf.server, id: jf.userId ?? '', name: name, tag: jf.userImageTag, size: 72),
                            const SizedBox(width: 18),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(name, style: tvDisplay(30)),
                                const SizedBox(height: 6),
                                Row(children: [
                                  Container(
                                      width: 9,
                                      height: 9,
                                      decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF5FD08A))),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                        '${_serverName ?? 'Jellyfin'} · ${Uri.tryParse(jf.server)?.host ?? ''}',
                                        overflow: TextOverflow.ellipsis,
                                        style: tvBody(19, color: kMuted)),
                                  ),
                                ]),
                              ]),
                            ),
                          ]),
                        ),
                        _item(Icons.people_outline_rounded, 'Switch profile', _switch, autofocus: true),
                        _item(Icons.dns_outlined, 'Server', _server),
                        const SizedBox(height: 8),
                        _item(Icons.logout_rounded, _confirmSignOut ? 'Press again to sign out' : 'Sign out of $name', _signOut,
                            quiet: !_confirmSignOut),
                      ]),
                    ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
