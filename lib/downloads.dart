// Downloads: the original file from the NAS, kept on this device to watch without the server.
//
// Uses background_downloader, so a download keeps going with Frame closed (iOS background
// transfers), pauses and resumes, and retries after a dropped connection. Each download keeps
// the episode's or movie's details and artwork beside the file, so it shows and plays with
// no server at all. Where you stop in a download is saved here and sent to Jellyfin the next
// time the server answers, so Continue watching stays right everywhere.
//
// Only profiles allowed to download ("Allow media downloading" in the Jellyfin dashboard)
// see the Download buttons.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'main.dart' show Jellyfin;
import 'phone.dart';
import 'player.dart' show PlayerScreen;
import 'ui.dart';

// ---------- What's downloaded ----------

class Download {
  Download({
    required this.id,
    required this.item,
    required this.server,
    required this.userId,
    required this.file,
    this.status = 'queued',
    this.progress = 0,
    this.bytes = 0,
    this.positionTicks,
    this.pendingSync = false,
    this.added,
  });

  final String id;
  final Map<String, dynamic> item; // Jellyfin's details, as when it was downloaded
  final String server;
  final String userId;
  final String file; // file name inside the downloads folder
  String status; // queued, running, paused, done, failed
  double progress; // 0..1
  int bytes; // file size (expected while downloading)
  int? positionTicks; // where you stopped watching it on this device
  bool pendingSync; // that position hasn't reached the server yet
  DateTime? added;

  bool get done => status == 'done';
  String get taskId => 'frame-$id';
  String get title => (item['Type'] == 'Episode' ? item['SeriesName'] : item['Name'])?.toString() ?? 'Untitled';

  Map<String, dynamic> toJson() => {
        'id': id,
        'item': item,
        'server': server,
        'userId': userId,
        'file': file,
        'status': status,
        'progress': progress,
        'bytes': bytes,
        'positionTicks': positionTicks,
        'pendingSync': pendingSync,
        'added': added?.toIso8601String(),
      };

  static Download fromJson(Map<String, dynamic> j) => Download(
        id: j['id'].toString(),
        item: Map<String, dynamic>.from(j['item'] as Map),
        server: j['server'].toString(),
        userId: j['userId'].toString(),
        file: j['file'].toString(),
        status: (j['status'] ?? 'queued').toString(),
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        positionTicks: (j['positionTicks'] as num?)?.toInt(),
        pendingSync: j['pendingSync'] == true,
        added: DateTime.tryParse((j['added'] ?? '').toString()),
      );
}

class Downloads extends ChangeNotifier {
  Downloads._();
  static final Downloads instance = Downloads._();

  final Map<String, Download> _all = {};
  Directory? _dir;
  Future<void>? _starting;

  /// The folder downloads live in (inside the app; iOS doesn't back it up to iCloud).
  Directory get dir => _dir!;
  String pathOf(Download d) => '${dir.path}/${d.file}';

  /// Call once at startup: loads the list and picks up downloads that finished or moved on
  /// while Frame was closed.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    final support = await getApplicationSupportDirectory();
    _dir = Directory('${support.path}/downloads');
    await _dir!.create(recursive: true);
    try {
      final index = File('${_dir!.path}/index.json');
      if (await index.exists()) {
        final list = jsonDecode(await index.readAsString()) as List;
        for (final j in list) {
          final d = Download.fromJson(Map<String, dynamic>.from(j as Map));
          _all[d.id] = d;
        }
      }
    } catch (e) {
      debugPrint('Downloads: could not read the list ($e)');
    }
    FileDownloader().configureNotification(
      running: const TaskNotification('Downloading', '{displayName}'),
      complete: const TaskNotification('Downloaded', '{displayName} is ready to watch'),
      error: const TaskNotification('Download failed', '{displayName}'),
      paused: const TaskNotification('Download paused', '{displayName}'),
      progressBar: true,
    );
    FileDownloader().updates.listen(_onUpdate);
    await FileDownloader().start();
    // A file that finished while the list wasn't watching.
    for (final d in _all.values) {
      if (!d.done && File(pathOf(d)).existsSync()) {
        final task = await FileDownloader().taskForId(d.taskId);
        if (task == null) _finish(d);
      }
    }
    notifyListeners();
  }

  List<Download> get all {
    final list = _all.values.toList();
    list.sort((a, b) => (b.added ?? DateTime(0)).compareTo(a.added ?? DateTime(0)));
    return list;
  }

  Download? of(String id) => _all[id];

  /// The downloaded file to play, if it's complete and still on this device.
  String? localFile(String id) {
    final d = _all[id];
    if (d == null || !d.done || _dir == null) return null;
    final path = pathOf(d);
    return File(path).existsSync() ? path : null;
  }

  int get usedBytes => _all.values.where((d) => d.done).fold(0, (sum, d) => sum + d.bytes);

  static Future<bool> wifiOnly() async {
    try {
      return (await SharedPreferences.getInstance()).getBool('downloadWifiOnly') ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setWifiOnly(bool on) async {
    try {
      await (await SharedPreferences.getInstance()).setBool('downloadWifiOnly', on);
    } catch (_) {}
  }

  /// Starts downloading [item]'s original file.
  Future<void> add(Jellyfin jf, dynamic item) async {
    await start();
    final id = item['Id'].toString();
    final existing = _all[id];
    if (existing != null && existing.status != 'failed') return;
    // Keep the file's own extension (mkv, mp4…), so players recognise it.
    final path = (item['Path'] ?? '').toString();
    final dot = path.lastIndexOf('.');
    var ext = dot >= 0 && path.length - dot <= 6 ? path.substring(dot + 1).toLowerCase() : '';
    if (ext.isEmpty) ext = (item['Container'] ?? 'mkv').toString().split(',').first.trim();
    final d = Download(
      id: id,
      item: Map<String, dynamic>.from(item as Map),
      server: jf.server,
      userId: jf.userId ?? '',
      file: '$id.$ext',
      added: DateTime.now(),
    );
    _all[id] = d;
    _changed();
    try {
      await FileDownloader().permissions.request(PermissionType.notifications);
    } catch (_) {}
    unawaited(_saveArt(jf, d));
    final title = d.item['Type'] == 'Episode'
        ? '${d.title} · ${episodeLine(d.item).split(' · ').take(2).join(' · ')}'
        : d.title;
    final ok = await FileDownloader().enqueue(DownloadTask(
      taskId: d.taskId,
      url: jf.downloadUrl(id),
      urlQueryParameters: {'ApiKey': jf.token ?? ''},
      headers: {'Authorization': 'MediaBrowser Token="${jf.token}"', 'X-Emby-Token': jf.token ?? ''},
      filename: d.file,
      directory: 'downloads',
      baseDirectory: BaseDirectory.applicationSupport,
      updates: Updates.statusAndProgress,
      requiresWiFi: await wifiOnly(),
      allowPause: true,
      retries: 3,
      displayName: title,
    ));
    if (!ok) {
      d.status = 'failed';
      _changed();
    }
  }

  // The poster, picture and backdrop, so the Downloads screen works with no server.
  Future<void> _saveArt(Jellyfin jf, Download d) async {
    final kinds = {'thumb': jf.thumbFor(d.item, maxWidth: 640), 'backdrop': jf.backdropFor(d.item, maxWidth: 1280)};
    for (final e in kinds.entries) {
      try {
        final res = await http.get(Uri.parse(e.value)).timeout(const Duration(seconds: 20));
        if (res.statusCode == 200) await File('${dir.path}/${d.id}-${e.key}.jpg').writeAsBytes(res.bodyBytes);
      } catch (_) {}
    }
    notifyListeners();
  }

  File? art(Download d, String kind) {
    if (_dir == null) return null;
    final f = File('${dir.path}/${d.id}-$kind.jpg');
    return f.existsSync() ? f : null;
  }

  void _onUpdate(TaskUpdate u) {
    final id = u.task.taskId.startsWith('frame-') ? u.task.taskId.substring(6) : null;
    final d = id == null ? null : _all[id];
    if (d == null) return;
    if (u is TaskStatusUpdate) {
      switch (u.status) {
        case TaskStatus.complete:
          _finish(d);
          return;
        case TaskStatus.running:
          d.status = 'running';
        case TaskStatus.paused:
          d.status = 'paused';
        case TaskStatus.enqueued:
        case TaskStatus.waitingToRetry:
          d.status = 'queued';
        case TaskStatus.failed:
        case TaskStatus.notFound:
        case TaskStatus.canceled:
          d.status = 'failed';
        default:
          break;
      }
      _changed();
    } else if (u is TaskProgressUpdate) {
      if (u.progress >= 0) d.progress = u.progress.clamp(0.0, 1.0);
      if (u.expectedFileSize > 0) d.bytes = u.expectedFileSize;
      if (d.status != 'running' && u.progress >= 0 && u.progress < 1) d.status = 'running';
      notifyListeners(); // progress isn't worth writing to disk every time
    }
  }

  void _finish(Download d) {
    d.status = 'done';
    d.progress = 1;
    try {
      d.bytes = File(pathOf(d)).lengthSync();
    } catch (_) {}
    _changed();
  }

  Future<void> pause(String id) async {
    final task = await FileDownloader().taskForId('frame-$id');
    if (task is DownloadTask) await FileDownloader().pause(task);
  }

  Future<void> resume(String id) async {
    final task = await FileDownloader().taskForId('frame-$id');
    if (task is DownloadTask) {
      await FileDownloader().resume(task);
    } else {
      // Nothing to resume (failed, or cleared by the system): start it again.
      final d = _all[id];
      if (d != null) d.status = 'failed';
    }
  }

  Future<void> remove(String id) async {
    final d = _all.remove(id);
    if (d == null) return;
    try {
      await FileDownloader().cancelTaskWithId(d.taskId);
    } catch (_) {}
    for (final f in [File(pathOf(d)), File('${dir.path}/$id-thumb.jpg'), File('${dir.path}/$id-backdrop.jpg')]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _changed();
  }

  /// Where you stopped in a downloaded video (sent to the server later, see [syncPositions]).
  void savePosition(String id, int ticks) {
    final d = _all[id];
    if (d == null) return;
    d.positionTicks = ticks;
    d.pendingSync = true;
    d.item['UserData'] = {...?(d.item['UserData'] as Map?), 'PlaybackPositionTicks': ticks};
    _changed();
  }

  /// Sends positions saved while offline, once the server answers again.
  Future<void> syncPositions(Jellyfin jf) async {
    await start();
    for (final d in _all.values.where((d) => d.pendingSync && d.server == jf.server && d.userId == jf.userId)) {
      if (await jf.syncPosition(d.id, d.positionTicks ?? 0)) {
        d.pendingSync = false;
        _changed();
      }
    }
  }

  Timer? _saveTimer;
  void _changed() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _save);
  }

  Future<void> _save() async {
    if (_dir == null) return;
    try {
      final index = File('${dir.path}/index.json');
      final tmp = File('${index.path}.part');
      await tmp.writeAsString(jsonEncode([for (final d in _all.values) d.toJson()]));
      await tmp.rename(index.path);
    } catch (e) {
      debugPrint('Downloads: could not save the list ($e)');
    }
  }
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return '${v >= 100 || u == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[u]}';
}

// ---------- The Download button (show and movie pages) ----------

/// Download / Downloading 42% / Downloaded. Shows nothing for profiles not allowed to download.
class DownloadButton extends StatefulWidget {
  const DownloadButton({super.key, required this.jf, required this.item, this.compact = false, this.height = 48});
  final Jellyfin jf;
  final dynamic item;
  final bool compact; // a round icon only (episode rows)
  final double height;

  @override
  State<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<DownloadButton> {
  bool? _allowed;

  @override
  void initState() {
    super.initState();
    Downloads.instance.start();
    widget.jf.canDownload().then((ok) {
      if (mounted) setState(() => _allowed = ok);
    });
  }

  Future<void> _tap(Download? d) async {
    phoneTap();
    final store = Downloads.instance;
    if (d == null || d.status == 'failed') {
      await store.add(widget.jf, widget.item);
    } else if (d.status == 'running' || d.status == 'queued') {
      await store.pause(d.id);
    } else if (d.status == 'paused') {
      await store.resume(d.id);
    } else if (d.done && mounted) {
      final remove = await _confirmRemove(context, d);
      if (remove) await store.remove(d.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_allowed != true) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Downloads.instance,
      builder: (context, _) {
        final d = Downloads.instance.of(widget.item['Id'].toString());
        final status = d?.status;
        final IconData icon;
        final String label;
        if (d == null || status == 'failed') {
          icon = Icons.download_rounded;
          label = status == 'failed' ? 'Try again' : 'Download';
        } else if (d.done) {
          icon = Icons.download_done_rounded;
          label = 'Downloaded';
        } else if (status == 'paused') {
          icon = Icons.play_arrow_rounded;
          label = 'Paused · ${(d.progress * 100).round()}%';
        } else {
          icon = Icons.pause_rounded;
          label = status == 'queued' ? 'Waiting…' : '${(d.progress * 100).round()}%';
        }
        if (widget.compact) {
          final running = status == 'running' || status == 'queued';
          return Semantics(
            button: true,
            label: label,
            child: GestureDetector(
              onTap: () => _tap(d),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Stack(alignment: Alignment.center, children: [
                  if (running || status == 'paused')
                    SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(
                        value: d!.progress > 0 ? d.progress : null,
                        strokeWidth: 2.5,
                        color: kFg,
                        backgroundColor: const Color(0x33F4F5F7),
                      ),
                    ),
                  Icon(icon, size: running || status == 'paused' ? 16 : 22, color: d?.done == true ? kFg : kSoft),
                ]),
              ),
            ),
          );
        }
        return PhoneButton(label: label, icon: icon, height: widget.height, onTap: () => _tap(d));
      },
    );
  }
}

Future<bool> _confirmRemove(BuildContext context, Download d) async {
  final answer = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: const Color(0xFF151920),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Remove the download?', style: phoneTitle(20)),
          const SizedBox(height: 6),
          Text('${d.title} · ${formatBytes(d.bytes)} will be deleted from this phone. It stays on your server.',
              style: phoneText(14, weight: FontWeight.w500, color: kMuted, height: 1.4)),
          const SizedBox(height: 18),
          PhoneButton(primary: true, label: 'Remove download', height: 48, onTap: () => Navigator.of(sheet).pop(true)),
          const SizedBox(height: 8),
          PhoneButton(label: 'Keep it', height: 48, onTap: () => Navigator.of(sheet).pop(false)),
        ]),
      ),
    ),
  );
  return answer == true;
}

// ---------- The Downloads screen ----------

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key, required this.jf});
  final Jellyfin jf;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  bool _wifiOnly = true;

  @override
  void initState() {
    super.initState();
    phoneAnyOrientation();
    Downloads.instance.start();
    Downloads.wifiOnly().then((v) {
      if (mounted) setState(() => _wifiOnly = v);
    });
  }

  Future<void> _play(Download d) async {
    final item = Map<String, dynamic>.from(d.item);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(jf: widget.jf, item: item)));
    if (mounted) phoneAnyOrientation();
    // Back online? Send where you stopped.
    unawaited(Downloads.instance.syncPositions(widget.jf));
  }

  Widget _row(Download d) {
    final store = Downloads.instance;
    final thumb = store.art(d, 'thumb');
    final ep = episodeLine(d.item).split(' · ');
    final what = d.item['Type'] == 'Episode'
        ? '${ep.take(2).join(' · ')}${ep.length > 2 ? ' · ${ep.skip(2).join(' · ')}' : ''}'
        : (d.item['ProductionYear']?.toString() ?? '');
    final String state;
    switch (d.status) {
      case 'done':
        state = formatBytes(d.bytes);
      case 'paused':
        state = 'Paused · ${(d.progress * 100).round()}%';
      case 'failed':
        state = 'Failed · tap to try again';
      case 'queued':
        state = _wifiOnly ? 'Waiting for Wi-Fi…' : 'Waiting…';
      default:
        state = '${(d.progress * 100).round()}% of ${formatBytes(d.bytes)}';
    }
    final progress = d.done ? 0.0 : d.progress;

    final tile = InkWell(
      onTap: () {
        phoneTap();
        if (d.done) {
          _play(d);
        } else if (d.status == 'failed') {
          store.add(widget.jf, d.item);
        } else if (d.status == 'paused') {
          store.resume(d.id);
        } else {
          store.pause(d.id);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 132,
              height: 74,
              child: Stack(fit: StackFit.expand, children: [
                thumb != null
                    ? Image.file(thumb, fit: BoxFit.cover, cacheWidth: phoneDecode(context, 132))
                    : const ColoredBox(color: kPlaceholder),
                if (!d.done)
                  Center(
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(color: Color(0xB306080B), shape: BoxShape.circle),
                      child: Icon(
                        d.status == 'paused' || d.status == 'failed' ? Icons.download_rounded : Icons.pause_rounded,
                        size: 18,
                        color: kFg,
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: phoneText(15, weight: FontWeight.w700)),
              if (what.isNotEmpty)
                Text(what, maxLines: 1, overflow: TextOverflow.ellipsis, style: phoneText(13, weight: FontWeight.w500, color: kSoft)),
              const SizedBox(height: 4),
              Text(state,
                  style: phoneText(12, color: d.status == 'failed' ? const Color(0xFFFF9A8A) : kMuted)),
              if (!d.done && d.status != 'failed') ...[
                const SizedBox(height: 6),
                PhoneProgress(value: progress, height: 3),
              ],
            ]),
          ),
          if (d.done) const Icon(Icons.play_circle_outline_rounded, size: 26, color: kSoft),
        ]),
      ),
    );

    return Dismissible(
      key: ValueKey('download ${d.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(color: const Color(0xFF8A2E2E), borderRadius: BorderRadius.circular(14)),
        child: Text('Remove', style: phoneText(15, weight: FontWeight.w700)),
      ),
      onDismissed: (_) {
        HapticFeedback.mediumImpact();
        store.remove(d.id);
      },
      child: tile,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final upright = isUpright(context);
    final m = phoneMargins(context, min: upright ? 20 : 44);
    return Scaffold(
      backgroundColor: kBg,
      body: ListenableBuilder(
        listenable: Downloads.instance,
        builder: (context, _) {
          final store = Downloads.instance;
          final list = store.all;
          final active = list.where((d) => !d.done).toList();
          final done = list.where((d) => d.done).toList();
          return ListView(
            padding: EdgeInsets.fromLTRB(m.left, pad.top + 10, m.right, pad.bottom + 28),
            children: [
              Row(children: [
                Semantics(
                  button: true,
                  label: 'Back',
                  child: GestureDetector(
                    onTap: () {
                      phoneTap();
                      Navigator.of(context).maybePop();
                    },
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(color: Color(0x8C4A4E57), shape: BoxShape.circle),
                      child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: kFg),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 18),
              Text('Downloads', style: phoneTitle(30)),
              const SizedBox(height: 4),
              Text(
                  list.isEmpty
                      ? 'Nothing downloaded yet.'
                      : '${done.length} ready to watch offline${store.usedBytes > 0 ? ' · ${formatBytes(store.usedBytes)} used' : ''}',
                  style: phoneText(13, color: kMuted)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: Text('Download on Wi-Fi only', style: phoneText(15))),
                Switch.adaptive(
                  value: _wifiOnly,
                  activeColor: kAccent,
                  onChanged: (v) {
                    phoneTap();
                    setState(() => _wifiOnly = v);
                    Downloads.setWifiOnly(v);
                  },
                ),
              ]),
              if (list.isEmpty) ...[
                const SizedBox(height: 24),
                Text('Use Download on a movie or an episode to watch it here without the server, '
                    'on a plane or anywhere. Downloads are the original files, in full quality.',
                    style: phoneText(14, weight: FontWeight.w500, color: kMuted, height: 1.5)),
              ],
              if (active.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('DOWNLOADING', style: phoneText(12, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1)),
                for (final d in active) _row(d),
              ],
              if (done.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('ON THIS PHONE', style: phoneText(12, weight: FontWeight.w700, color: kMuted).copyWith(letterSpacing: 1)),
                for (final d in done) _row(d),
                const SizedBox(height: 10),
                Text('Swipe a download to the left to remove it from this phone.', style: phoneText(12, color: kMuted)),
              ],
            ],
          );
        },
      ),
    );
  }
}
