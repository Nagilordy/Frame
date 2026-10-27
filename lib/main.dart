// Frame: the app's start (window, controller, login) and the connection to Jellyfin.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, SocketException;
import 'dart:isolate' show Isolate;
import 'dart:math' show Random;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'banners.dart' show bannerHandlesKey;
import 'gamepad.dart';
import 'images.dart' show tidyArtworkCache;
import 'native_player.dart' show findMpv;
import 'profiles.dart' show StartScreen;
import 'ui.dart' show isDesktop, toggleFullScreen;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('Frame');
  }
  await Jellyfin.loadDeviceIdentity();
  await findMpv();
  tidyArtworkCache();
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
    if (event is KeyDownEvent && bannerHandlesKey(event.logicalKey)) return true;
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.f2) {
      setState(() => _meter = !_meter);
      return true;
    }
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.f11) {
      toggleFullScreen();
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    GamepadInput.start();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  final _navigator = GlobalKey<NavigatorState>();
  final _routes = PadRouteWatcher();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
          textTheme: ThemeData.dark(useMaterial3: true).textTheme.apply(fontFamily: 'Hanken Grotesk'),
          // Hover labels (mouse only) in the app's own style, not Flutter's default grey box.
          tooltipTheme: TooltipThemeData(
            decoration: BoxDecoration(
              color: const Color(0xE61E2228),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0x24F4F5F7)),
            ),
            textStyle: const TextStyle(
                fontFamily: 'Hanken Grotesk', fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFF4F5F7)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            waitDuration: const Duration(milliseconds: 500),
          ),
          // A short plain fade between screens on every device, instead of Flutter's default
          // zoom (which takes a full-screen snapshot of both screens on every frame: heavy at 4K).
          pageTransitionsTheme: PageTransitionsTheme(builders: {
            for (final platform in TargetPlatform.values) platform: const _QuickFade(),
          })),
      debugShowCheckedModeBanner: false,
      showPerformanceOverlay: _meter,
      navigatorKey: _navigator,
      navigatorObservers: [_routes],
      // The controller legend floats above every screen.
      builder: (context, child) => Stack(children: [
        if (child != null) child,
        // While the controller is in use, the mouse is switched off inside the app: the
        // pointer is hidden and can't hover or click anything (so the controller's touchpad
        // can't interfere). A real click, the wheel, or moving the mouse a good distance
        // switches back to the mouse; that first click is only used to wake it up.
        Positioned.fill(
          child: ValueListenableBuilder<bool>(
            valueListenable: padActive,
            builder: (_, pad, __) => pad
                ? const MouseRegion(
                    cursor: SystemMouseCursors.none,
                    opaque: true,
                    child: AbsorbPointer(child: SizedBox.expand()),
                  )
                : const SizedBox.shrink(),
          ),
        ),
        Positioned.fill(child: PadLegend(navigatorKey: _navigator)),
      ]),
      home: const StartScreen(),
    );
  }
}

// The new screen fades in over the first 60% of the transition (about 180 ms), then costs
// nothing extra: a fully visible screen is drawn normally.
class _QuickFade extends PageTransitionsBuilder {
  const _QuickFade();

  @override
  Widget buildTransitions<T>(Route<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: const Interval(0, 0.6, curve: Curves.easeOut)),
      child: child,
    );
  }
}

// ---------- Talking to Jellyfin ----------

class Jellyfin {
  Jellyfin(this.server);

  final String server; // e.g. http://10.0.0.33:8096
  String? token;
  String? userId;
  String? userName;
  String? userImageTag; // the profile picture's version, when the profile has one

  // Each install has its own ID, so Jellyfin sees the PC and the iPhone as two devices
  // (with one shared ID, signing in on one signs the other out). Named after the computer.
  static String _deviceId = 'frame';
  static String _deviceName = 'Frame';
  static String get deviceId => _deviceId;

  static Future<void> loadDeviceIdentity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString('deviceId');
      if (id == null) {
        final r = Random.secure();
        id = 'frame-${List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join()}';
        await prefs.setString('deviceId', id);
      }
      _deviceId = id;
      _deviceName = Platform.localHostname.isEmpty ? 'Frame' : Platform.localHostname;
    } catch (_) {}
  }

  static String get _client =>
      'MediaBrowser Client="Frame", Device="$_deviceName", DeviceId="$_deviceId", Version="0.1"';

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization':
            token == null ? _client : '$_client, Token="$token"',
      };

  // Every request gives up after a few seconds, so a sleeping NAS shows an error and a Retry
  // button instead of "Loading…" for two minutes.
  // 15 seconds leaves room for the NAS waking its drives (the first request in the morning).
  static const _timeout = Duration(seconds: 15);

  // One connection to the server, reused for every request (opening a new one each time
  // adds a round trip to every screen).
  static final http.Client _http = http.Client();
  static http.Client get client => _http;

  // Big replies (a page of 100 titles with all their audio and subtitle details) are read on
  // a background thread, so scrolling never stutters while the next page arrives.
  // If the background thread ever fails, the reply is simply read here instead.
  static Future<dynamic> _decode(List<int> bytes) async {
    if (bytes.length < 20000) return jsonDecode(utf8.decode(bytes));
    try {
      final copy = Uint8List.fromList(bytes);
      return await Isolate.run(() => jsonDecode(utf8.decode(copy)));
    } catch (e) {
      debugPrint('Reading a reply in the background failed ($e), reading it here instead');
      return jsonDecode(utf8.decode(bytes));
    }
  }

  static const unreachable = "Can't reach your Jellyfin server. Check that the NAS is on.";

  Future<http.Response> _send(Future<http.Response> request) async {
    try {
      return await request.timeout(_timeout);
    } on TimeoutException {
      throw unreachable;
    } on SocketException {
      throw unreachable;
    } on http.ClientException {
      throw unreachable;
    }
  }

  Future<void> login(String username, String password) async {
    final res = await _send(_http.post(
      Uri.parse('$server/Users/AuthenticateByName'),
      headers: _headers,
      body: jsonEncode({'Username': username, 'Pw': password}),
    ));
    if (res.statusCode == 401) throw 'Wrong username or password.';
    if (res.statusCode != 200) {
      throw 'Login failed (${res.statusCode}). Check the address, username and password.';
    }
    _signedIn(jsonDecode(res.body));
  }

  void _signedIn(dynamic data) {
    token = data['AccessToken'];
    userId = data['User']['Id'];
    userName = data['User']['Name']?.toString();
    userImageTag = data['User']['PrimaryImageTag']?.toString();
  }

  // ---------- Plain calls (Watch together and other features) ----------

  /// The sign-in header, for connections made outside this class (the live connection).
  Map<String, String> get authHeaders => _headers;

  /// POSTs JSON to a Jellyfin path; returns the reply (or null when empty). Errors throw.
  Future<dynamic> postPath(String path, [Object? body]) async {
    final res = await _send(_http.post(Uri.parse('$server$path'),
        headers: _headers, body: body == null ? null : jsonEncode(body)));
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw res.statusCode == 403 ? 'Not allowed on this server.' : 'Your login has expired. Sign in again.';
    }
    if (res.statusCode < 200 || res.statusCode >= 300) throw 'Jellyfin answered with an error (${res.statusCode}).';
    if (res.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  /// GETs JSON from a Jellyfin path. Errors throw.
  Future<dynamic> getPath(String path) async {
    final res = await _send(_http.get(Uri.parse('$server$path'), headers: _headers));
    if (res.statusCode == 403) throw 'Not allowed on this server.';
    if (res.statusCode != 200) throw 'Jellyfin answered with an error (${res.statusCode}).';
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  // ---------- Profiles (Who's watching) ----------

  // The profiles Jellyfin shows on its own login screen (not the hidden ones), with whether
  // each has a password and its picture.
  Future<List<dynamic>> publicUsers() async {
    final res = await _send(_http.get(Uri.parse('$server/Users/Public'), headers: _headers));
    if (res.statusCode != 200) throw 'Jellyfin answered with an error (${res.statusCode}).';
    return jsonDecode(utf8.decode(res.bodyBytes)) as List;
  }

  String userImage(String id, String? tag, {int maxWidth = 400}) =>
      '$server/Users/$id/Images/Primary?quality=90&maxWidth=$maxWidth${tag != null ? '&tag=$tag' : ''}';

  // The server's name and version: also confirms an address really is a Jellyfin server.
  Future<Map<String, dynamic>> publicInfo() async {
    final res = await _send(_http.get(Uri.parse('$server/System/Info/Public'), headers: _headers));
    if (res.statusCode != 200) throw 'No Jellyfin server answered at this address.';
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is! Map || data['Id'] == null) throw 'No Jellyfin server answered at this address.';
    return data.cast<String, dynamic>();
  }

  // Quick Connect: Frame shows a short code, you approve it from Jellyfin on your phone,
  // and Frame is signed in without typing a password on the TV.
  Future<bool> quickConnectEnabled() async {
    try {
      final res = await _send(_http.get(Uri.parse('$server/QuickConnect/Enabled'), headers: _headers));
      return res.statusCode == 200 && res.body.trim() == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<({String secret, String code})> quickConnectStart() async {
    final uri = Uri.parse('$server/QuickConnect/Initiate');
    var res = await _send(_http.post(uri, headers: _headers));
    if (res.statusCode == 405 || res.statusCode == 404) res = await _send(_http.get(uri, headers: _headers));
    if (res.statusCode != 200) throw 'Quick Connect could not start (${res.statusCode}).';
    final data = jsonDecode(res.body);
    return (secret: data['Secret'].toString(), code: data['Code'].toString());
  }

  Future<bool> quickConnectApproved(String secret) async {
    final res = await _send(_http.get(
        Uri.parse('$server/QuickConnect/Connect').replace(queryParameters: {'secret': secret}),
        headers: _headers));
    if (res.statusCode != 200) throw 'expired';
    return jsonDecode(res.body)['Authenticated'] == true;
  }

  Future<void> quickConnectFinish(String secret) async {
    final res = await _send(_http.post(Uri.parse('$server/Users/AuthenticateWithQuickConnect'),
        headers: _headers, body: jsonEncode({'Secret': secret})));
    if (res.statusCode != 200) throw 'Quick Connect sign-in failed (${res.statusCode}).';
    _signedIn(jsonDecode(res.body));
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
    final res = await _http.get(uri, headers: _headers);
    if (res.statusCode != 200) throw 'Could not load the library (${res.statusCode}).';
    return jsonDecode(res.body)['Items'];
  }

  Future<List<dynamic>> episodes(String seriesId) async {
    final uri = Uri.parse('$server/Shows/$seriesId/Episodes').replace(queryParameters: {
      'UserId': userId!,
      'Fields': 'MediaStreams',
    });
    final res = await _http.get(uri, headers: _headers);
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
      final res = await _http.get(uri, headers: _headers);
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
    Object? lastError;
    for (final uri in candidates) {
      // Each address gets two tries: a reused connection the server already closed fails
      // once and works straight away on a new one.
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final res = await _send(_http.get(uri, headers: _headers));
          if (res.statusCode == 200) return await _decode(res.bodyBytes);
          status = res.statusCode;
          debugPrint('Jellyfin: ${uri.path} answered $status');
          break; // a real answer: no point asking the same address again
        } catch (e) {
          lastError = e;
          debugPrint('Jellyfin: ${uri.path} failed: $e');
        }
      }
    }
    if (status == 401) throw 'Your login has expired. Sign in again.';
    if (status == 0 && lastError != null) throw lastError;
    throw 'Jellyfin answered with an error ($status).';
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

  // Checks a saved login still works. Returns null when the server can't be reached at all,
  // so the app can open anyway and offer Retry, instead of asking to log in again.
  Future<bool?> isValid() async {
    try {
      final res = await _send(_http.get(Uri.parse('$server/Users/$userId'), headers: _headers));
      return res.statusCode == 200;
    } catch (_) {
      return null;
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
      // Only what the grid shows (the summary isn't shown there, so it isn't downloaded).
      'Fields': 'MediaStreams,ProductionYear',
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

  // Show pages are kept in memory for a few minutes, and the same request is never sent twice
  // at once. Combined with fetching a show while its card is selected (prefetchShow), opening
  // a show or going back to a season you already looked at is instant.
  final Map<String, (DateTime, Future<dynamic>)> _memo = {};
  static const _memoFor = Duration(minutes: 5);

  Future<T> _cached<T>(String key, bool fresh, Future<T> Function() load) {
    final hit = _memo[key];
    if (!fresh && hit != null && DateTime.now().difference(hit.$1) < _memoFor) return hit.$2 as Future<T>;
    final future = load();
    _memo[key] = (DateTime.now(), future);
    // A failed request isn't kept, so the next try asks the server again.
    future.then((_) {}, onError: (_) {
      if (identical(_memo[key]?.$2, future)) _memo.remove(key);
    });
    return future;
  }

  bool isCached(String key) {
    final hit = _memo[key];
    return hit != null && DateTime.now().difference(hit.$1) < _memoFor;
  }

  // After watching or marking something, a show's saved pages are out of date.
  void forgetShow(String seriesId) => _memo.removeWhere((k, _) => k.contains(seriesId));

  Future<dynamic> item(String id, {bool fresh = false}) => _cached('item:$id', fresh, () => _getJson([
        Uri.parse('$server/Items/$id').replace(queryParameters: {'userId': userId!}),
        Uri.parse('$server/Users/$userId/Items/$id'),
      ]));

  Future<List<dynamic>> seasons(String seriesId, {bool fresh = false}) =>
      _cached('seasons:$seriesId', fresh, () async {
        final data = await _getJson([
          Uri.parse('$server/Shows/$seriesId/Seasons').replace(queryParameters: {'userId': userId!}),
        ]);
        return data['Items'] as List;
      });

  static String episodesKey(String seriesId, String seasonId) => 'eps:$seriesId:$seasonId';

  Future<List<dynamic>> seasonEpisodes(String seriesId, String seasonId, {bool fresh = false}) =>
      _cached(episodesKey(seriesId, seasonId), fresh, () async {
        final data = await _getJson([
          Uri.parse('$server/Shows/$seriesId/Episodes').replace(queryParameters: {
            'userId': userId!,
            'seasonId': seasonId,
            'Fields': 'MediaStreams,Overview',
          }),
        ]);
        return data['Items'] as List;
      });

  // The episode to watch next in a show, or null.
  Future<dynamic> nextUp(String seriesId, {bool fresh = false}) => _cached('next:$seriesId', fresh, () async {
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
      });

  // Called when a show's card has been selected for a moment: fetches its page in the
  // background (details, seasons, next episode and that season's episodes), so opening it
  // shows everything at once. Errors are ignored here; the show page handles them.
  void prefetchShow(dynamic item) {
    if (item == null) return;
    final String? id = item['Type'] == 'Series' ? item['Id'] : item['SeriesId'];
    if (id == null || isCached('next:$id')) return;
    void quiet(Future<dynamic> f) => f.then((_) {}, onError: (_) {});
    quiet(this.item(id));
    quiet(seasons(id));
    quiet(nextUp(id).then((next) {
      final seasonId = next?['SeasonId'];
      if (seasonId != null) quiet(seasonEpisodes(id, seasonId));
    }));
  }

  // Marks an episode, season or show as watched.
  Future<void> markPlayed(String id) async {
    for (final uri in [
      Uri.parse('$server/UserPlayedItems/$id').replace(queryParameters: {'userId': userId!}),
      Uri.parse('$server/Users/$userId/PlayedItems/$id'),
    ]) {
      try {
        final res = await _send(_http.post(uri, headers: _headers));
        if (res.statusCode >= 200 && res.statusCode < 300) return;
      } catch (_) {}
    }
    throw "Couldn't mark it as watched.";
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
  // Asked for as PNG: without it, Jellyfin may send a JPEG, which can't be see-through,
  // and the logo shows as a black box.
  String? logoFor(dynamic item) {
    final tags = item['ImageTags'] as Map?;
    if (tags != null && tags['Logo'] != null) return '${image(item['Id'], 'Logo', maxWidth: 900)}&format=Png';
    final parent = item['ParentLogoItemId'] ?? item['SeriesId'];
    return parent == null ? null : '${image(parent, 'Logo', maxWidth: 900)}&format=Png';
  }

  // 16:9 card image: an episode's own still, otherwise the title's backdrop.
  String thumbFor(dynamic item, {int maxWidth = 640}) {
    if (item['Type'] == 'Episode') return image(item['Id'], 'Primary', maxWidth: maxWidth);
    final tags = item['ImageTags'] as Map?;
    if (tags != null && tags['Thumb'] != null) return image(item['Id'], 'Thumb', maxWidth: maxWidth);
    return backdropFor(item, maxWidth: maxWidth);
  }

  // ---------- Telling Jellyfin what I watched, so Continue Watching stays in sync ----------

  Future<void> _post(String path, Map<String, dynamic> body) async {
    try {
      await _send(_http.post(Uri.parse('$server$path'), headers: _headers, body: jsonEncode(body)));
    } catch (_) {}
  }

  // session: when Jellyfin is converting the video (see serverStream), its play session.
  Future<void> reportStart(String id, int ticks, {String? session}) => _post('/Sessions/Playing', {
        'ItemId': id,
        'PositionTicks': ticks,
        'PlayMethod': session == null ? 'DirectPlay' : 'Transcode',
        'CanSeek': true,
        if (session != null) 'PlaySessionId': session,
        if (session != null) 'MediaSourceId': id,
      });

  Future<void> reportProgress(String id, int ticks, bool paused, {String? session}) =>
      _post('/Sessions/Playing/Progress', {
        'ItemId': id,
        'PositionTicks': ticks,
        'IsPaused': paused,
        'PlayMethod': session == null ? 'DirectPlay' : 'Transcode',
        if (session != null) 'PlaySessionId': session,
        if (session != null) 'MediaSourceId': id,
      });

  Future<void> reportStopped(String id, int ticks, {String? session}) async {
    await _post('/Sessions/Playing/Stopped', {
      'ItemId': id,
      'PositionTicks': ticks,
      if (session != null) 'PlaySessionId': session,
      if (session != null) 'MediaSourceId': id,
    });
    // Tell the NAS to stop converting, so it isn't left working after the video is closed.
    if (session != null) {
      try {
        await _send(_http.delete(
            Uri.parse('$server/Videos/ActiveEncodings')
                .replace(queryParameters: {'deviceId': _deviceId, 'playSessionId': session}),
            headers: _headers));
      } catch (_) {}
    }
  }

  // ---------- Letting the NAS convert a video ----------
  //
  // For a device that can't keep up with a file (or can't fix Dolby Vision Profile 5 colours
  // fast enough), Jellyfin converts it on the NAS's graphics chip into a plain 4K stream with
  // normal colours, and this device just plays that. Text subtitles come along as separate
  // files. Returns the stream address, the play session, and the subtitles.
  // audioIndex / subtitleIndex: Jellyfin's stream numbers for the chosen audio and subtitles.
  // Image subtitles (Blu-ray PGS, DVD) are drawn into the picture by the server.
  Future<({String url, String session, List<({String url, String label, String? language, int index})> subtitles})>
      serverStream(String itemId, {int? audioIndex, int? subtitleIndex}) async {
    const maxBitrate = 120000000;
    final profile = {
      'Name': 'Frame',
      'MaxStreamingBitrate': maxBitrate,
      'MaxStaticBitrate': maxBitrate,
      'DirectPlayProfiles': [],
      'TranscodingProfiles': [
        {
          'Container': 'mp4',
          'Type': 'Video',
          'VideoCodec': 'hevc,h264',
          'AudioCodec': 'eac3,ac3,aac',
          'Protocol': 'hls',
          'Context': 'Streaming',
          'MaxAudioChannels': '6',
          'MinSegments': 1,
          'BreakOnNonKeyFrames': true,
        }
      ],
      // Normal colours only: Jellyfin fixes Dolby Vision and HDR on the NAS.
      'CodecProfiles': [
        for (final codec in ['hevc', 'h264'])
          {
            'Type': 'Video',
            'Codec': codec,
            'Conditions': [
              {'Condition': 'EqualsAny', 'Property': 'VideoRangeType', 'Value': 'SDR', 'IsRequired': false}
            ],
          }
      ],
      'SubtitleProfiles': [
        for (final f in ['srt', 'subrip', 'ass', 'ssa', 'vtt', 'webvtt']) {'Format': f, 'Method': 'External'},
        for (final f in ['pgssub', 'pgs', 'dvdsub', 'dvbsub', 'vobsub']) {'Format': f, 'Method': 'Encode'},
      ],
      'ContainerProfiles': [],
      'ResponseProfiles': [],
    };
    final res = await _send(_http.post(
      Uri.parse('$server/Items/$itemId/PlaybackInfo').replace(queryParameters: {'userId': userId!}),
      headers: _headers,
      body: jsonEncode({
        'UserId': userId,
        'MediaSourceId': itemId,
        'DeviceProfile': profile,
        'MaxStreamingBitrate': maxBitrate,
        'EnableDirectPlay': false,
        'EnableDirectStream': false,
        'EnableTranscoding': true,
        'AllowVideoStreamCopy': false,
        'AllowAudioStreamCopy': true,
        'AutoOpenLiveStream': false,
        if (audioIndex != null) 'AudioStreamIndex': audioIndex,
        if (subtitleIndex != null) 'SubtitleStreamIndex': subtitleIndex,
      }),
    ));
    if (res.statusCode != 200) throw 'The server could not convert this video (${res.statusCode}).';
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final source = (data['MediaSources'] as List).first;
    final path = source['TranscodingUrl'] as String?;
    if (path == null) throw 'The server did not offer a converted version of this video.';
    String full(String p) {
      final url = p.startsWith('http') ? p : '$server$p';
      return url.toLowerCase().contains('api_key=') || url.contains('ApiKey=')
          ? url
          : '$url${url.contains('?') ? '&' : '?'}ApiKey=$token';
    }

    final subs = <({String url, String label, String? language, int index})>[];
    for (final st in (source['MediaStreams'] as List? ?? [])) {
      if (st['Type'] == 'Subtitle' && st['DeliveryMethod'] == 'External' && st['DeliveryUrl'] != null) {
        subs.add((
          url: full(st['DeliveryUrl']),
          label: (st['DisplayTitle'] ?? st['Language'] ?? 'Subtitle').toString(),
          language: st['Language']?.toString(),
          index: (st['Index'] ?? -1) as int,
        ));
      }
    }
    return (url: full(path), session: data['PlaySessionId'].toString(), subtitles: subs);
  }

  // A subtitle stored as a separate file next to the video (e.g. movie.fr.srt).
  String externalSubtitleUrl(String itemId, int index, String codec) {
    final ext = codec == 'subrip' ? 'srt' : codec;
    return '$server/Videos/$itemId/$itemId/Subtitles/$index/Stream.$ext?ApiKey=$token';
  }

  // static=true asks Jellyfin for the original file: no transcoding on the NAS.
  String directStreamUrl(String itemId) =>
      '$server/Videos/$itemId/stream?static=true&ApiKey=$token';
}
