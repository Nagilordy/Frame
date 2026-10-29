// Remembering audio and subtitle choices, shared by both players.
//
// Like Infuse: the audio and subtitles you pick are remembered for the show (and become the
// default for everything else), described by language and kind (forced, SDH, audio
// description), so the next episode picks the same kind of track even if it sits elsewhere.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TrackPrefs {
  TrackPrefs(this.item);

  final dynamic item; // the video's details from Jellyfin

  Map<String, dynamic>? audio;
  Map<String, dynamic>? sub; // {'off': true} when subtitles were turned off

  String? get _showKey => item['SeriesId'] != null ? 'tracks-show-${item['SeriesId']}' : null;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      Map<String, dynamic>? read(String? key) {
        final raw = key == null ? null : prefs.getString(key);
        return raw == null ? null : (jsonDecode(raw) as Map).cast<String, dynamic>();
      }

      final show = read(_showKey);
      final all = read('tracks-default');
      final a = show?['audio'] ?? all?['audio'];
      final s = show?['sub'] ?? all?['sub'];
      audio = a is Map ? a.cast<String, dynamic>() : null;
      sub = s is Map ? s.cast<String, dynamic>() : null;
    } catch (e) {
      debugPrint('Player: saved track choices could not be read: $e');
    }
  }

  Future<void> remember(String kind, Map<String, dynamic> pref) async {
    if (kind == 'audio') {
      audio = pref;
    } else {
      sub = pref;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in [_showKey, 'tracks-default']) {
        if (key == null) continue;
        final raw = prefs.getString(key);
        final m = raw == null ? <String, dynamic>{} : (jsonDecode(raw) as Map).cast<String, dynamic>();
        m[kind] = pref;
        await prefs.setString(key, jsonEncode(m));
      }
      debugPrint('Player: remembering $kind ${jsonEncode(pref)}');
    } catch (_) {}
  }

  Future<void> rememberSubsOff() => remember('sub', const {'off': true});

  /// Remembers one of Jellyfin's streams (by its index) as the choice for [kind].
  Future<void> rememberStream(String kind, int index) async {
    final s = streams(kind == 'audio' ? 'Audio' : 'Subtitle')
        .cast<dynamic>()
        .firstWhere((x) => x['Index'] == index, orElse: () => null);
    if (s != null) await remember(kind, describeStream(s));
  }

  List<dynamic> streams(String type) =>
      ((item['MediaStreams'] as List?) ?? []).where((s) => s['Type'] == type).toList();

  // ----- describing tracks the same way, wherever they come from -----

  static bool _isDescription(String title) {
    final t = title.toLowerCase();
    return RegExp(r'\bad\b').hasMatch(t) || t.contains('descri') || t.contains('commentary') || t.contains('commentaire');
  }

  static bool _isSdh(String title) {
    final t = title.toLowerCase();
    return t.contains('sdh') || t.contains('hearing') || t.contains('malentendant') || RegExp(r'\bcc\b').hasMatch(t);
  }

  static Map<String, dynamic> describe({String? lang, String? title, bool forced = false, bool hi = false, bool vi = false}) {
    final t = title ?? '';
    return {
      'lang': (lang ?? '').toLowerCase(),
      'forced': forced || t.toLowerCase().contains('forced') || t.toLowerCase().contains('forcé'),
      'sdh': hi || _isSdh(t),
      'ad': vi || _isDescription(t),
      'title': t.toLowerCase(),
    };
  }

  /// A Jellyfin stream.
  static Map<String, dynamic> describeStream(dynamic s) => describe(
        lang: s['Language']?.toString(),
        title: (s['Title'] ?? '').toString(),
        forced: s['IsForced'] == true,
        hi: s['IsHearingImpaired'] == true,
      );

  /// One of mpv's own tracks (track-list).
  static Map<String, dynamic> describeMpv(Map t) => describe(
        lang: t['lang']?.toString(),
        title: t['title']?.toString(),
        forced: t['forced'] == true,
        hi: t['hearing-impaired'] == true,
        vi: t['visual-impaired'] == true,
      );

  /// How well a track matches what was picked before (0 = not the same language).
  static int score(Map<String, dynamic> pref, Map<String, dynamic> track) {
    if ((pref['lang'] ?? '') != '' && pref['lang'] != track['lang']) return 0;
    var score = 10;
    for (final k in ['forced', 'sdh', 'ad']) {
      if ((pref[k] == true) == (track[k] == true)) score += 3;
    }
    if (pref['title'] != null && pref['title'] == track['title']) score += 1;
    return score;
  }

  /// The best match among [candidates] (each described), or null when none shares the language.
  static T? best<T>(Map<String, dynamic> pref, Iterable<(T, Map<String, dynamic>)> candidates) {
    T? pick;
    var top = 0;
    for (final (value, described) in candidates) {
      final sc = score(pref, described);
      if (sc > top) {
        top = sc;
        pick = value;
      }
    }
    return pick;
  }

  /// The Jellyfin stream index that best matches the remembered choice for [type].
  int? bestStreamIndex(String type, Map<String, dynamic> pref) =>
      best<int?>(pref, [for (final s in streams(type)) (s['Index'] as int?, describeStream(s))]);
}
