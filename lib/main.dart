// Player test: log into Jellyfin, list titles, play one directly with mpv.
// Nothing here is styled on purpose. This only checks that playback works.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home.dart';
import 'player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Keep more artwork in memory so going back to a card shows it instantly.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 * 1024 * 1024;
  runApp(const TestApp());
}

class TestApp extends StatefulWidget {
  const TestApp({super.key});

  @override
  State<TestApp> createState() => _TestAppState();
}

class _TestAppState extends State<TestApp> {
  bool _meter = false;

  // F2 shows or hides Flutter's performance meter: two graphs of how long each frame takes.
  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.f2) {
      setState(() => _meter = !_meter);
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Player test',
      theme: ThemeData.dark(useMaterial3: true),
      debugShowCheckedModeBanner: false,
      showPerformanceOverlay: _meter,
      home: const LoginScreen(),
    );
  }
}

// ---------- Talking to Jellyfin ----------

class Jellyfin {
  Jellyfin(this.server);

  final String server; // e.g. http://10.0.0.33:8096
  String? token;
  String? userId;

  static const _client =
      'MediaBrowser Client="PlayerTest", Device="SteamOS", DeviceId="player-test-1", Version="0.1"';

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization':
            token == null ? _client : '$_client, Token="$token"',
      };

  Future<void> login(String username, String password) async {
    final res = await http.post(
      Uri.parse('$server/Users/AuthenticateByName'),
      headers: _headers,
      body: jsonEncode({'Username': username, 'Pw': password}),
    );
    if (res.statusCode != 200) {
      throw 'Login failed (${res.statusCode}). Check the address, username and password.';
    }
    final data = jsonDecode(res.body);
    token = data['AccessToken'];
    userId = data['User']['Id'];
  }

  Future<List<dynamic>> items(String type) async {
    final uri = Uri.parse('$server/Users/$userId/Items').replace(queryParameters: {
      'IncludeItemTypes': type,
      'Recursive': 'true',
      'SortBy': 'DateCreated',
      'SortOrder': 'Descending',
      'Limit': '60',
      'Fields': 'MediaStreams',
    });
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode != 200) throw 'Could not load the library (${res.statusCode}).';
    return jsonDecode(res.body)['Items'];
  }

  Future<List<dynamic>> episodes(String seriesId) async {
    final uri = Uri.parse('$server/Shows/$seriesId/Episodes').replace(queryParameters: {
      'UserId': userId!,
      'Fields': 'MediaStreams',
    });
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode != 200) throw 'Could not load episodes (${res.statusCode}).';
    return jsonDecode(res.body)['Items'];
  }

  // Every movie and episode, with its streams, fetched in pages.
  Future<List<dynamic>> allVideos() async {
    final all = <dynamic>[];
    var start = 0;
    const page = 500;
    while (true) {
      final uri = Uri.parse('$server/Users/$userId/Items').replace(queryParameters: {
        'IncludeItemTypes': 'Movie,Episode',
        'Recursive': 'true',
        'Fields': 'MediaStreams,Path',
        'EnableImages': 'false',
        'StartIndex': '$start',
        'Limit': '$page',
      });
      final res = await http.get(uri, headers: _headers);
      if (res.statusCode != 200) throw 'Could not scan the library (${res.statusCode}).';
      final items = jsonDecode(res.body)['Items'] as List;
      all.addAll(items);
      if (items.length < page) break;
      start += page;
    }
    return all;
  }

  // Tries the current Jellyfin address first, then the older one, so both server versions work.
  Future<dynamic> _getJson(List<Uri> candidates) async {
    var status = 0;
    for (final uri in candidates) {
      final res = await http.get(uri, headers: _headers);
      if (res.statusCode == 200) return jsonDecode(res.body);
      status = res.statusCode;
    }
    throw 'Jellyfin answered $status.';
  }

  static const _homeFields = 'MediaStreams,Overview,ProductionYear';

  // What I was watching: Continue Watching.
  Future<List<dynamic>> resume() async {
    final q = {'Limit': '16', 'MediaTypes': 'Video', 'Fields': _homeFields};
    final data = await _getJson([
      Uri.parse('$server/UserItems/Resume').replace(queryParameters: {...q, 'userId': userId!}),
      Uri.parse('$server/Users/$userId/Items/Resume').replace(queryParameters: q),
    ]);
    return data['Items'] as List;
  }

  // Recently added movies and shows.
  Future<List<dynamic>> latest() async {
    final q = {'Limit': '20', 'IncludeItemTypes': 'Movie,Series', 'Fields': _homeFields};
    final data = await _getJson([
      Uri.parse('$server/Items/Latest').replace(queryParameters: {...q, 'userId': userId!}),
      Uri.parse('$server/Users/$userId/Items/Latest').replace(queryParameters: q),
    ]);
    return data as List;
  }

  // Checks a saved login still works.
  Future<bool> isValid() async {
    try {
      final res = await http.get(Uri.parse('$server/Users/$userId'), headers: _headers);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ---------- Libraries ----------

  // My Jellyfin libraries that hold video (Movies, Shows, Anime...), in the order set in Jellyfin.
  Future<List<dynamic>> views() async {
    final data = await _getJson([
      Uri.parse('$server/UserViews').replace(queryParameters: {'userId': userId!}),
      Uri.parse('$server/Users/$userId/Views'),
    ]);
    const video = {'movies', 'tvshows', 'mixed', 'homevideos', null};
    return (data['Items'] as List).where((v) => video.contains(v['CollectionType'])).toList();
  }

  // One page of a library, sorted and filtered. Returns the items and the total count.
  Future<({List<dynamic> items, int total})> libraryPage({
    required String parentId,
    required String sortBy,
    required String sortOrder,
    int start = 0,
    int limit = 100,
    bool unwatched = false,
    bool only4k = false,
    String? genre,
    String? nameLessThan,
  }) async {
    final q = <String, String>{
      'ParentId': parentId,
      'Recursive': 'true',
      'IncludeItemTypes': 'Movie,Series',
      'SortBy': sortBy,
      'SortOrder': sortOrder,
      'StartIndex': '$start',
      'Limit': '$limit',
      'Fields': 'MediaStreams,ProductionYear,Overview',
      'EnableTotalRecordCount': 'true',
      if (unwatched) 'Filters': 'IsUnplayed',
      if (only4k) 'Is4K': 'true',
      if (genre != null) 'Genres': genre,
      if (nameLessThan != null) 'NameLessThan': nameLessThan,
    };
    final data = await _getJson([Uri.parse('$server/Users/$userId/Items').replace(queryParameters: q)]);
    return (items: data['Items'] as List<dynamic>, total: (data['TotalRecordCount'] ?? 0) as int);
  }

  Future<List<String>> genres(String parentId) async {
    final data = await _getJson([
      Uri.parse('$server/Genres').replace(queryParameters: {'ParentId': parentId, 'userId': userId!}),
    ]);
    return (data['Items'] as List).map((g) => g['Name'].toString()).toList();
  }

  // ---------- Shows ----------

  Future<dynamic> item(String id) => _getJson([
        Uri.parse('$server/Items/$id').replace(queryParameters: {'userId': userId!}),
        Uri.parse('$server/Users/$userId/Items/$id'),
      ]);

  Future<List<dynamic>> seasons(String seriesId) async {
    final data = await _getJson([
      Uri.parse('$server/Shows/$seriesId/Seasons').replace(queryParameters: {'userId': userId!}),
    ]);
    return data['Items'] as List;
  }

  Future<List<dynamic>> seasonEpisodes(String seriesId, String seasonId) async {
    final data = await _getJson([
      Uri.parse('$server/Shows/$seriesId/Episodes').replace(queryParameters: {
        'userId': userId!,
        'seasonId': seasonId,
        'Fields': 'MediaStreams,Overview',
      }),
    ]);
    return data['Items'] as List;
  }

  // The episode to watch next in a show, or null.
  Future<dynamic> nextUp(String seriesId) async {
    try {
      final data = await _getJson([
        Uri.parse('$server/Shows/NextUp').replace(queryParameters: {
          'userId': userId!,
          'seriesId': seriesId,
          'Fields': 'MediaStreams,Overview',
        }),
      ]);
      final items = data['Items'] as List;
      return items.isEmpty ? null : items.first;
    } catch (_) {
      return null;
    }
  }

  // Marks an episode, season or show as watched.
  Future<void> markPlayed(String id) async {
    for (final uri in [
      Uri.parse('$server/UserPlayedItems/$id').replace(queryParameters: {'userId': userId!}),
      Uri.parse('$server/Users/$userId/PlayedItems/$id'),
    ]) {
      try {
        final res = await http.post(uri, headers: _headers);
        if (res.statusCode >= 200 && res.statusCode < 300) return;
      } catch (_) {}
    }
  }

  // ---------- Artwork ----------

  String image(String id, String type, {int? maxWidth}) =>
      '$server/Items/$id/Images/$type?quality=90${maxWidth != null ? '&maxWidth=$maxWidth' : ''}';

  // Full-screen backdrop. Episodes use their show's backdrop.
  String backdropFor(dynamic item, {int maxWidth = 1920}) {
    final own = (item['BackdropImageTags'] as List?)?.isNotEmpty ?? false;
    final id = own ? item['Id'] : (item['ParentBackdropItemId'] ?? item['SeriesId'] ?? item['Id']);
    return image(id, 'Backdrop', maxWidth: maxWidth);
  }

  // Title logo art, or null when there is none (the screen then shows the title as text).
  String? logoFor(dynamic item) {
    final tags = item['ImageTags'] as Map?;
    if (tags != null && tags['Logo'] != null) return image(item['Id'], 'Logo', maxWidth: 900);
    final parent = item['ParentLogoItemId'] ?? item['SeriesId'];
    return parent == null ? null : image(parent, 'Logo', maxWidth: 900);
  }

  // 16:9 card image: an episode's own still, otherwise the title's backdrop.
  String thumbFor(dynamic item) {
    if (item['Type'] == 'Episode') return image(item['Id'], 'Primary', maxWidth: 640);
    final tags = item['ImageTags'] as Map?;
    if (tags != null && tags['Thumb'] != null) return image(item['Id'], 'Thumb', maxWidth: 640);
    return backdropFor(item, maxWidth: 640);
  }

  // ---------- Telling Jellyfin what I watched, so Continue Watching stays in sync ----------

  Future<void> _post(String path, Map<String, dynamic> body) async {
    try {
      await http.post(Uri.parse('$server$path'), headers: _headers, body: jsonEncode(body));
    } catch (_) {}
  }

  Future<void> reportStart(String id, int ticks) => _post('/Sessions/Playing',
      {'ItemId': id, 'PositionTicks': ticks, 'PlayMethod': 'DirectPlay', 'CanSeek': true});

  Future<void> reportProgress(String id, int ticks, bool paused) => _post('/Sessions/Playing/Progress',
      {'ItemId': id, 'PositionTicks': ticks, 'IsPaused': paused, 'PlayMethod': 'DirectPlay'});

  Future<void> reportStopped(String id, int ticks) =>
      _post('/Sessions/Playing/Stopped', {'ItemId': id, 'PositionTicks': ticks});

  // A subtitle stored as a separate file next to the video (e.g. movie.fr.srt).
  String externalSubtitleUrl(String itemId, int index, String codec) {
    final ext = codec == 'subrip' ? 'srt' : codec;
    return '$server/Videos/$itemId/$itemId/Subtitles/$index/Stream.$ext?ApiKey=$token';
  }

  // static=true asks Jellyfin for the original file: no transcoding on the NAS.
  String directStreamUrl(String itemId) =>
      '$server/Videos/$itemId/stream?static=true&ApiKey=$token';
}

// Short description of the video and audio, e.g. "HEVC · 3840x2160 · DOVI · TRUEHD 7.1"
String describe(dynamic item) {
  final streams = (item['MediaStreams'] as List?) ?? [];
  final video = streams.cast<dynamic>().firstWhere(
      (s) => s['Type'] == 'Video', orElse: () => null);
  final audio = streams.cast<dynamic>().firstWhere(
      (s) => s['Type'] == 'Audio', orElse: () => null);
  final parts = <String>[];
  if (video != null) {
    parts.add((video['Codec'] ?? '?').toString().toUpperCase());
    if (video['Width'] != null) parts.add('${video['Width']}x${video['Height']}');
    final range = video['VideoRangeType'] ?? video['VideoRange'];
    if (range != null) parts.add(range.toString());
  }
  if (audio != null) {
    parts.add('${(audio['Codec'] ?? '?').toString().toUpperCase()} ${audio['Channels'] ?? ''}ch');
  }
  return parts.join(' · ');
}

// ---------- Screens ----------

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController(text: 'http://10.0.0.33:8096');
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _checkingSaved = true;

  @override
  void initState() {
    super.initState();
    _trySavedLogin();
  }

  // Skips the login screen when a saved login still works.
  Future<void> _trySavedLogin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final server = prefs.getString('server');
      final token = prefs.getString('token');
      final userId = prefs.getString('userId');
      if (server != null && token != null && userId != null) {
        _server.text = server;
        final jf = Jellyfin(server)
          ..token = token
          ..userId = userId;
        if (await jf.isValid()) {
          _open(jf);
          return;
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _checkingSaved = false);
  }

  void _open(Jellyfin jf) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => HomeScreen(jf: jf)));
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final jf = Jellyfin(_server.text.trim().replaceAll(RegExp(r'/+$'), ''));
    try {
      await jf.login(_user.text.trim(), _pass.text);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server', jf.server);
      await prefs.setString('token', jf.token!);
      await prefs.setString('userId', jf.userId!);
      _open(jf);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSaved) {
      return const Scaffold(backgroundColor: Color(0xFF06080B), body: SizedBox.shrink());
    }
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Connect to Jellyfin', style: TextStyle(fontSize: 26)),
              const SizedBox(height: 24),
              TextField(controller: _server, decoration: const InputDecoration(labelText: 'Server address')),
              TextField(controller: _user, decoration: const InputDecoration(labelText: 'Username')),
              TextField(
                controller: _pass,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
                onSubmitted: (_) => _login(),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _login,
                child: Text(_busy ? 'Connecting…' : 'Connect'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class TestLibraryScreen extends StatelessWidget {
  const TestLibraryScreen({super.key, required this.jf});
  final Jellyfin jf;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Library'),
          bottom: const TabBar(tabs: [Tab(text: 'Movies'), Tab(text: 'Shows'), Tab(text: 'Formats')]),
        ),
        body: TabBarView(children: [
          ItemList(jf: jf, load: () => jf.items('Movie')),
          ItemList(jf: jf, load: () => jf.items('Series')),
          FormatsScreen(jf: jf),
        ]),
      ),
    );
  }
}

class ItemList extends StatelessWidget {
  const ItemList({super.key, required this.jf, required this.load});
  final Jellyfin jf;
  final Future<List<dynamic>> Function() load;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      future: load(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text(snap.error.toString()));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final items = snap.data!;
        if (items.isEmpty) return const Center(child: Text('Nothing here.'));
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            final isSeries = item['Type'] == 'Series';
            return ListTile(
              title: Text(item['Name'] ?? 'Untitled'),
              subtitle: isSeries ? Text('${item['ProductionYear'] ?? ''}') : Text(describe(item)),
              trailing: Icon(isSeries ? Icons.chevron_right : Icons.play_arrow),
              onTap: () {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => isSeries
                      ? Scaffold(
                          appBar: AppBar(title: Text(item['Name'] ?? '')),
                          body: ItemList(jf: jf, load: () => jf.episodes(item['Id'])),
                        )
                      : PlayerScreen(jf: jf, item: item),
                ));
              },
            );
          },
        );
      },
    );
  }
}

// ---------- Formats: every kind of file in the library, with one sample of each ----------

class FormatGroup {
  FormatGroup(this.label, this.sample);
  final String label;
  final dynamic sample;
  int count = 0;
}

class FormatsScreen extends StatelessWidget {
  const FormatsScreen({super.key, required this.jf});
  final Jellyfin jf;

  static String _resolution(dynamic v) {
    final w = (v['Width'] ?? 0) as int;
    if (w >= 3200) return '4K';
    if (w >= 1800) return '1080p';
    if (w >= 1200) return '720p';
    return 'SD';
  }

  static Map<String, List<FormatGroup>> _group(List<dynamic> items) {
    final sections = <String, Map<String, FormatGroup>>{
      'Containers': {},
      'Video': {},
      'Audio': {},
      'Subtitles': {},
    };
    void add(String section, String label, dynamic item) {
      final g = sections[section]!.putIfAbsent(label, () => FormatGroup(label, item));
      g.count++;
    }

    for (final item in items) {
      final path = (item['Path'] ?? '').toString();
      final dot = path.lastIndexOf('.');
      if (dot != -1) add('Containers', path.substring(dot + 1).toUpperCase(), item);

      final streams = (item['MediaStreams'] as List?) ?? [];
      for (final s in streams) {
        final codec = (s['Codec'] ?? '?').toString().toUpperCase();
        switch (s['Type']) {
          case 'Video':
            final range = s['VideoRangeType'] ?? s['VideoRange'] ?? 'SDR';
            final interlaced = s['IsInterlaced'] == true ? ' · interlaced' : '';
            add('Video', '$codec · ${_resolution(s)} · $range$interlaced', item);
            break;
          case 'Audio':
            add('Audio', '$codec · ${s['Channels'] ?? '?'}ch', item);
            break;
          case 'Subtitle':
            final where = s['IsExternal'] == true ? ' · separate file' : ' · inside the video';
            add('Subtitles', '$codec$where', item);
            break;
        }
      }
    }
    return sections.map((k, v) {
      final list = v.values.toList()..sort((a, b) => b.count.compareTo(a.count));
      return MapEntry(k, list);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      future: jf.allVideos(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text(snap.error.toString()));
        if (!snap.hasData) {
          return const Center(child: Text('Scanning every movie and episode…'));
        }
        final sections = _group(snap.data!);
        final rows = <Widget>[
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('${snap.data!.length} files scanned. Play the sample of each line once to confirm it works.'),
          ),
        ];
        sections.forEach((title, groups) {
          rows.add(Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ));
          for (final g in groups) {
            rows.add(ListTile(
              title: Text(g.label),
              subtitle: Text('${g.count} file${g.count == 1 ? '' : 's'} · sample: ${g.sample['SeriesName'] != null ? '${g.sample['SeriesName']} – ' : ''}${g.sample['Name']}'),
              trailing: const Icon(Icons.play_arrow),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PlayerScreen(jf: jf, item: g.sample))),
            ));
          }
        });
        return ListView(children: rows);
      },
    );
  }
}

