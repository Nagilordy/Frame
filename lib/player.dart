// Player screen: full-screen video with controls that fade away while watching.
// Keyboard: Space play/pause · ←/→ skip (when controls are hidden) · arrows + Enter on buttons
// · Escape hides the controls, or leaves the player when they're already hidden.
// Mouse: moving shows the controls, click buttons, click or drag the progress bar.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui.dart' show Focusable;
import 'main.dart' show Jellyfin;

// ---------- Look (same palette as the home screen) ----------

const _bg = Color(0xFF06080B);
const _fg = Color(0xFFF4F5F7);
const _muted = Color(0xFFB9C0CB);
const _soft = Color(0xFFD3D8E0);

TextStyle _body(double size, {FontWeight weight = FontWeight.w500, Color color = _fg}) =>
    GoogleFonts.getFont('Hanken Grotesk', fontSize: size, fontWeight: weight, color: color);

TextStyle _display(double size) => GoogleFonts.getFont('Sora',
    fontSize: size, fontWeight: FontWeight.w700, color: _fg, letterSpacing: -0.02 * size, height: 1.1);

const _back = Duration(seconds: 10);
const _forward = Duration(seconds: 30);

String _clock(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

String _qualityLine(dynamic item) {
  final streams = (item['MediaStreams'] as List?) ?? [];
  final video = streams.cast<dynamic>().firstWhere((s) => s['Type'] == 'Video', orElse: () => null);
  final audio = streams.cast<dynamic>().firstWhere((s) => s['Type'] == 'Audio', orElse: () => null);
  final parts = <String>[];
  if (video != null) {
    final w = (video['Width'] ?? 0) as int;
    parts.add(w >= 3200 ? '4K' : w >= 1800 ? '1080p' : w >= 1200 ? '720p' : 'SD');
    final range = (video['VideoRangeType'] ?? '').toString();
    if (range.startsWith('DOVI')) {
      parts.add('Dolby Vision');
    } else if (range == 'HDR10Plus') {
      parts.add('HDR10+');
    } else if (range == 'HDR10' || range == 'HLG') {
      parts.add(range);
    }
  }
  if (audio != null) {
    final ch = audio['Channels'] ?? 0;
    parts.add(ch >= 8 ? '7.1' : ch >= 6 ? '5.1' : 'Stereo');
  }
  return parts.join(' · ');
}

// ---------- The screen ----------

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.jf, required this.item});
  final Jellyfin jf;
  final dynamic item;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

enum _Panel { none, audio, subtitles }

class _PlayerScreenState extends State<PlayerScreen> {
  // A larger buffer keeps more of the file ready, which helps smoothness and seeking over the network.
  late final Player player = Player(
    configuration: const PlayerConfiguration(bufferSize: 256 * 1024 * 1024),
  );
  late final VideoController controller = VideoController(
    player,
    configuration: const VideoControllerConfiguration(enableHardwareAcceleration: true),
  );

  final _rootFocus = FocusNode();
  final _playFocus = FocusNode();
  final _panelFirst = FocusNode();

  bool _controls = true;
  bool _info = false;

  // Subtitle style, remembered between videos.
  double _subScale = 1.0;
  int _subPos = 100; // 100 = bottom of the picture, lower numbers = higher up
  bool _subBox = false;
  _Panel _panel = _Panel.none;
  String _stats = '';

  Timer? _hideTimer;
  Timer? _statsTimer;
  Timer? _syncTimer;
  final _subs = <StreamSubscription>[];

  String get _id => widget.item['Id'];
  int get _resumeTicks => (widget.item['UserData']?['PlaybackPositionTicks'] ?? 0) as int;
  int get _ticksNow => player.state.position.inMicroseconds * 10;

  @override
  void initState() {
    super.initState();
    // Controls hide on their own only while playing; pausing keeps them up.
    _subs.add(player.stream.playing.listen((playing) {
      if (!mounted) return;
      if (playing) {
        _scheduleHide();
      } else {
        _hideTimer?.cancel();
        if (!_controls) setState(() => _controls = true);
      }
    }));
    // Close the player when the video ends.
    _subs.add(player.stream.completed.listen((done) {
      if (done && mounted) Navigator.of(context).maybePop();
    }));
    _start();
  }

  Future<void> _start() async {
    final mpv = player.platform;
    if (mpv is NativePlayer) {
      // Decode on the GPU when the hardware supports the codec, otherwise fall back safely.
      await mpv.setProperty('hwdec', 'auto-safe');
      // HDR to SDR conversion, without per-frame brightness measuring (heavy on small GPUs).
      await mpv.setProperty('tone-mapping', 'bt.2446a');
      await mpv.setProperty('hdr-compute-peak', 'no');
      // Wait for a little data before the first frame, so the start doesn't stutter.
      await mpv.setProperty('cache-pause-initial', 'yes');
      await mpv.setProperty('cache-pause-wait', '1');
      // Read ahead over the network so seeks inside the buffer are instant.
      await mpv.setProperty('cache', 'yes');
      await mpv.setProperty('demuxer-max-bytes', '256MiB');
      await mpv.setProperty('demuxer-max-back-bytes', '128MiB');
      await mpv.setProperty('demuxer-readahead-secs', '60');
      // Jump to the nearest keyframe: much faster seeks.
      await mpv.setProperty('hr-seek', 'no');
      // mpv draws subtitles straight onto the video. This handles every kind, including
      // image subtitles from Blu-rays (PGS) and styled anime subtitles (ASS), with their own styling.
      await mpv.setProperty('sub-visibility', 'yes');
      // Keep styled subtitles' own look, but let the size setting apply to them too.
      await mpv.setProperty('sub-ass-override', 'scale');
      await _loadSubStyle();
      await _applySubStyle();
      // Resume where I stopped last time (Jellyfin counts time in ticks of 100 nanoseconds).
      if (_resumeTicks > 0) {
        await mpv.setProperty('start', (_resumeTicks / 10000000).toStringAsFixed(1));
      }
    }
    await player.open(Media(widget.jf.directStreamUrl(_id)));
    widget.jf.reportStart(_id, _resumeTicks);
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      widget.jf.reportProgress(_id, _ticksNow, !player.state.playing);
    });
    if (mounted) _playFocus.requestFocus();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _hideTimer?.cancel();
    _statsTimer?.cancel();
    _syncTimer?.cancel();
    widget.jf.reportStopped(_id, _ticksNow);
    player.dispose();
    _rootFocus.dispose();
    _playFocus.dispose();
    _panelFirst.dispose();
    super.dispose();
  }

  // ---------- Showing and hiding the controls ----------

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && player.state.playing && _panel == _Panel.none) {
        setState(() => _controls = false);
        _rootFocus.requestFocus();
      }
    });
  }

  void _showControls({bool focusPlay = false}) {
    if (!_controls) {
      setState(() => _controls = true);
      if (focusPlay) _playFocus.requestFocus();
    }
    _scheduleHide();
  }

  void _hideControls() {
    _hideTimer?.cancel();
    setState(() {
      _controls = false;
      _panel = _Panel.none;
    });
    _rootFocus.requestFocus();
  }

  // ---------- Actions ----------

  void _togglePlay() {
    player.playOrPause();
    _showControls();
  }

  void _skip(Duration by) {
    final duration = player.state.duration;
    var target = player.state.position + by;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    player.seek(target);
    _showControls();
  }

  void _openPanel(_Panel panel) {
    _hideTimer?.cancel();
    setState(() => _panel = panel);
    // Select the first choice once the panel is on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _panelFirst.context != null) _panelFirst.requestFocus();
    });
  }

  void _closePanel() {
    setState(() => _panel = _Panel.none);
    _playFocus.requestFocus();
    _scheduleHide();
  }

  void _toggleInfo() {
    setState(() => _info = !_info);
    _statsTimer?.cancel();
    if (_info) {
      _readStats();
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _readStats());
    }
    _showControls();
  }

  // Live numbers: decoder, dropped frames, buffered time.
  Future<void> _readStats() async {
    final mpv = player.platform;
    if (mpv is! NativePlayer || !mounted) return;
    Future<String> p(String name) async {
      try {
        return await mpv.getProperty(name);
      } catch (_) {
        return '?';
      }
    }

    final hw = await p('hwdec-current');
    final dropped = await p('frame-drop-count');
    final decoderDropped = await p('decoder-frame-drop-count');
    final cache = await p('demuxer-cache-duration');
    final cacheSecs = double.tryParse(cache)?.toStringAsFixed(0) ?? cache;
    if (!mounted) return;
    setState(() => _stats = 'Decoder  ${hw.isEmpty || hw == 'no' ? 'CPU' : 'GPU ($hw)'}\n'
        'Dropped frames  $dropped / $decoderDropped\n'
        'Buffered  ${cacheSecs}s\n'
        'Direct play from the original file');
  }

  // ---------- Keyboard ----------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // Space always plays or pauses.
    if (key == LogicalKeyboardKey.space) {
      _togglePlay();
      return KeyEventResult.handled;
    }

    if (_panel != _Panel.none) {
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) {
        _closePanel();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // arrows + Enter move inside the panel
    }

    if (!_controls) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _skip(-_back);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _skip(_forward);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) {
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      }
      // Any other key brings the controls back, with Play/Pause selected.
      _showControls(focusPlay: true);
      return KeyEventResult.handled;
    }

    // Controls are visible: keys move between buttons, and keep the controls up.
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) {
      _hideControls();
      return KeyEventResult.handled;
    }
    _scheduleHide();
    return KeyEventResult.ignored;
  }

  // ---------- Building ----------

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isEpisode = item['Type'] == 'Episode';
    final title = (isEpisode ? item['SeriesName'] : item['Name'])?.toString() ?? '';
    final episodeLine = isEpisode
        ? [
            if (item['ParentIndexNumber'] != null) 'S${item['ParentIndexNumber']}',
            if (item['IndexNumber'] != null) 'E${item['IndexNumber']}',
            item['Name'] ?? '',
          ].join(' · ')
        : (item['ProductionYear']?.toString() ?? '');

    return Focus(
      focusNode: _rootFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: MouseRegion(
          cursor: _controls ? SystemMouseCursors.basic : SystemMouseCursors.none,
          onHover: (_) => _showControls(),
          child: Stack(children: [
            // The video itself, with no built-in controls.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _controls ? _hideControls() : _showControls(focusPlay: true),
                child: Video(
                  controller: controller,
                  controls: NoVideoControls,
                  fill: Colors.black,
                  // Subtitles are drawn by mpv onto the video itself, so the plain text version is off.
                  subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
                ),
              ),
            ),

            // Loading spinner while the video starts or buffers.
            Positioned.fill(
              child: IgnorePointer(
                child: StreamBuilder<bool>(
                  stream: player.stream.buffering,
                  initialData: true,
                  builder: (_, snap) => snap.data == true
                      ? const Center(
                          child: SizedBox(
                            width: 56,
                            height: 56,
                            child: CircularProgressIndicator(strokeWidth: 3, color: _fg),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),

            // Everything else fades in and out together.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_controls,
                child: AnimatedOpacity(
                  opacity: _controls ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  child: Stack(children: [
                    _topBar(title, episodeLine),
                    _bottomBar(),
                  ]),
                ),
              ),
            ),

            if (_info) _infoBox(),
            if (_panel != _Panel.none) _trackPanel(),
          ]),
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon, VoidCallback onSelect,
      {double size = 46, double iconSize = 24, FocusNode? focusNode, String? label}) {
    return _FocusableWithNode(
      focusNode: focusNode,
      onSelect: onSelect,
      builder: (f) => Tooltip(
        message: label ?? '',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: f ? _fg : _fg.withOpacity(0.12),
          ),
          child: Icon(icon, size: iconSize, color: f ? _bg : _fg),
        ),
      ),
    );
  }

  Widget _topBar(String title, String episodeLine) {
    final quality = _qualityLine(widget.item);
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(48, 36, 56, 80),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withOpacity(0.75), Colors.black.withOpacity(0)],
          ),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          _iconButton(Icons.arrow_back_rounded, () => Navigator.of(context).maybePop(), label: 'Back'),
          const SizedBox(width: 24),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: _display(30), maxLines: 1, overflow: TextOverflow.ellipsis),
              if (episodeLine.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(episodeLine, style: _body(20, color: _soft), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ]),
          ),
          if (quality.isNotEmpty)
            Text(quality, style: _body(18, weight: FontWeight.w600, color: _soft)),
        ]),
      ),
    );
  }

  Widget _bottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(56, 100, 56, 40),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withOpacity(0.85), Colors.black.withOpacity(0)],
          ),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Time and progress update on their own, without redrawing the rest of the screen.
          StreamBuilder<Duration>(
            stream: player.stream.position,
            initialData: player.state.position,
            builder: (_, snap) {
              final pos = snap.data ?? Duration.zero;
              final dur = player.state.duration;
              final left = dur > pos ? dur - pos : Duration.zero;
              final endsAt = DateTime.now().add(left);
              final endsText =
                  '${endsAt.hour.toString().padLeft(2, '0')}:${endsAt.minute.toString().padLeft(2, '0')}';
              return Column(children: [
                _ProgressBar(
                  position: pos,
                  duration: dur,
                  buffered: player.state.buffer,
                  onSeek: (to) {
                    player.seek(to);
                    _showControls();
                  },
                  onKeySkip: (forward) => _skip(forward ? _forward : -_back),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Text(_clock(pos), style: _body(18, color: _soft)),
                  const Spacer(),
                  if (dur > Duration.zero) Text('Ends at $endsText', style: _body(18, color: _muted)),
                  const Spacer(),
                  Text('-${_clock(left)}', style: _body(18, color: _soft)),
                ]),
              ]);
            },
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 64,
            child: Stack(alignment: Alignment.center, children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _iconButton(Icons.replay_10_rounded, () => _skip(-_back), label: 'Back 10 seconds'),
                const SizedBox(width: 22),
                StreamBuilder<bool>(
                  stream: player.stream.playing,
                  initialData: player.state.playing,
                  builder: (_, snap) => _iconButton(
                    snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    _togglePlay,
                    size: 64,
                    iconSize: 36,
                    focusNode: _playFocus,
                    label: 'Play or pause',
                  ),
                ),
                const SizedBox(width: 22),
                _iconButton(Icons.forward_30_rounded, () => _skip(_forward), label: 'Forward 30 seconds'),
              ]),
              Align(
                alignment: Alignment.centerRight,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _iconButton(Icons.graphic_eq_rounded, () => _openPanel(_Panel.audio), label: 'Audio'),
                  const SizedBox(width: 12),
                  _iconButton(Icons.closed_caption_outlined, () => _openPanel(_Panel.subtitles), label: 'Subtitles'),
                  const SizedBox(width: 12),
                  _iconButton(Icons.info_outline_rounded, _toggleInfo, label: 'Playback info'),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _infoBox() {
    return Positioned(
      top: 150,
      right: 56,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          decoration: BoxDecoration(
            color: _bg.withOpacity(0.82),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(_stats.isEmpty ? 'Reading…' : _stats, style: _body(17, color: _soft).copyWith(height: 1.6)),
        ),
      ),
    );
  }

  // ---------- Audio and subtitle panel ----------

  // ---------- Subtitle style ----------

  Future<void> _loadSubStyle() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _subScale = prefs.getDouble('subScale') ?? 1.0;
      _subPos = prefs.getInt('subPos') ?? 100;
      _subBox = prefs.getBool('subBox') ?? false;
    } catch (_) {}
  }

  Future<void> _applySubStyle({bool save = false}) async {
    final mpv = player.platform;
    if (mpv is! NativePlayer) return;
    Future<void> set(String name, String value) async {
      try {
        await mpv.setProperty(name, value);
      } catch (_) {}
    }

    await set('sub-scale', _subScale.toStringAsFixed(2));
    await set('sub-pos', '$_subPos');
    // Background box: a translucent dark box behind the text (colors are #AARRGGBB).
    await set('sub-border-style', _subBox ? 'background-box' : 'outline-and-shadow');
    await set('sub-back-color', '#B3000000');
    if (save) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('subScale', _subScale);
        await prefs.setInt('subPos', _subPos);
        await prefs.setBool('subBox', _subBox);
      } catch (_) {}
    }
  }

  void _changeSubStyle({double? scale, int? pos, bool? box}) {
    setState(() {
      if (scale != null) _subScale = (scale.clamp(0.5, 2.0) * 10).roundToDouble() / 10;
      if (pos != null) _subPos = pos.clamp(40, 100).toInt();
      if (box != null) _subBox = box;
    });
    _applySubStyle(save: true);
  }

  // Size, position and background controls under the subtitle list. Changes show live.
  List<Widget> _styleSection() {
    Widget stepButton(IconData icon, VoidCallback onSelect, String label) => Focusable(
          onSelect: onSelect,
          builder: (f) => Tooltip(
            message: label,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 44,
              height: 44,
              decoration: BoxDecoration(shape: BoxShape.circle, color: f ? _fg : _fg.withOpacity(0.12)),
              child: Icon(icon, size: 24, color: f ? _bg : _fg),
            ),
          ),
        );

    Widget stepper(String name, String value, VoidCallback less, VoidCallback more, String lessLabel,
            String moreLabel, IconData lessIcon, IconData moreIcon) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(children: [
            Expanded(child: Text(name, style: _body(20))),
            stepButton(lessIcon, less, lessLabel),
            SizedBox(
              width: 76,
              child: Text(value, textAlign: TextAlign.center, style: _body(19, weight: FontWeight.w600, color: _soft)),
            ),
            stepButton(moreIcon, more, moreLabel),
          ]),
        );

    final heightAboveBottom = ((100 - _subPos) / 5).round();

    return [
      const SizedBox(height: 18),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Text('Style', style: _body(16, weight: FontWeight.w700, color: _muted)),
      ),
      stepper('Size', '${(_subScale * 100).round()}%', () => _changeSubStyle(scale: _subScale - 0.1),
          () => _changeSubStyle(scale: _subScale + 0.1), 'Smaller', 'Larger', Icons.remove_rounded, Icons.add_rounded),
      stepper('Position', heightAboveBottom == 0 ? 'Bottom' : '+$heightAboveBottom',
          () => _changeSubStyle(pos: _subPos + 5), () => _changeSubStyle(pos: _subPos - 5), 'Lower', 'Higher',
          Icons.keyboard_arrow_down_rounded, Icons.keyboard_arrow_up_rounded),
      Focusable(
        onSelect: () => _changeSubStyle(box: !_subBox),
        builder: (f) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(color: f ? _fg : Colors.transparent, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Expanded(child: Text('Background box', style: _body(20, color: f ? _bg : _fg))),
            Text(_subBox ? 'On' : 'Off', style: _body(19, weight: FontWeight.w600, color: f ? _bg : _soft)),
          ]),
        ),
      ),
      Focusable(
        onSelect: () => _changeSubStyle(scale: 1.0, pos: 100, box: false),
        builder: (f) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(color: f ? _fg : Colors.transparent, borderRadius: BorderRadius.circular(12)),
          child: Text('Reset style', style: _body(20, color: f ? _bg : _muted)),
        ),
      ),
    ];
  }

  // Switch subtitles, and make sure mpv keeps drawing them after the switch.
  Future<void> _setSubtitle(SubtitleTrack track) async {
    await player.setSubtitleTrack(track);
    final mpv = player.platform;
    if (mpv is NativePlayer && track.id != 'no') {
      await mpv.setProperty('sub-visibility', 'yes');
    }
  }

  String _trackLabel(String id, String? title, String? language) {
    if (id == 'auto') return 'Automatic';
    if (id == 'no') return 'Off';
    final label = [language, title].where((s) => s != null && s.isNotEmpty).join(' · ');
    return label.isEmpty ? 'Track $id' : label;
  }

  Widget _trackPanel() {
    final rows = <Widget>[];
    var first = true;
    void add(String label, bool selected, VoidCallback onSelect) {
      void choose() {
        onSelect();
        _closePanel();
      }

      Widget look(bool f) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: f ? _fg : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _body(20, weight: selected ? FontWeight.w700 : FontWeight.w500, color: f ? _bg : _fg)),
            ),
            if (selected) Icon(Icons.check_rounded, color: f ? _bg : _fg, size: 26),
          ]),
        );

      rows.add(first
          ? _NodeFocusable(node: _panelFirst, onSelect: choose, builder: look)
          : Focusable(onSelect: choose, builder: look));
      first = false;
    }

    if (_panel == _Panel.audio) {
      final current = player.state.track.audio;
      for (final t in player.state.tracks.audio) {
        if (t.id == 'no') continue;
        add(_trackLabel(t.id, t.title, t.language), t == current, () => player.setAudioTrack(t));
      }
    } else {
      final current = player.state.track.subtitle;
      for (final t in player.state.tracks.subtitle) {
        add(_trackLabel(t.id, t.title, t.language), t == current, () => _setSubtitle(t));
      }
      // Subtitles stored as separate files are not inside the video, so add them from Jellyfin.
      final external = ((widget.item['MediaStreams'] as List?) ?? [])
          .where((s) => s['Type'] == 'Subtitle' && s['IsExternal'] == true);
      for (final s in external) {
        add('${s['DisplayTitle'] ?? s['Language'] ?? 'Subtitle'} · separate file', false, () {
          _setSubtitle(SubtitleTrack.uri(
            widget.jf.externalSubtitleUrl(_id, s['Index'], (s['Codec'] ?? 'srt').toString()),
            title: s['DisplayTitle'],
            language: s['Language'],
          ));
        });
      }
      rows.addAll(_styleSection());
    }

    return Positioned.fill(
      child: Stack(children: [
        // Clicking outside the panel closes it.
        Positioned.fill(
          child: GestureDetector(
            onTap: _closePanel,
            child: Container(color: Colors.black.withOpacity(0.35)),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: 460,
          child: Container(
            color: _bg.withOpacity(0.94),
            padding: const EdgeInsets.fromLTRB(28, 48, 28, 28),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_panel == _Panel.audio ? 'Audio' : 'Subtitles', style: _display(28)),
              const SizedBox(height: 24),
              // Its own focus scope: arrow keys stay inside the panel while it's open.
              Expanded(
                child: FocusScope(
                  child: rows.isEmpty
                      ? Text('None in this file.', style: _body(20, color: _muted))
                      : ListView(children: rows),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// A round button that can also take a focus node from outside (used to focus Play/Pause).
class _FocusableWithNode extends StatelessWidget {
  const _FocusableWithNode({required this.onSelect, required this.builder, this.focusNode});
  final VoidCallback onSelect;
  final Widget Function(bool focused) builder;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    if (focusNode == null) return Focusable(onSelect: onSelect, builder: builder);
    return _NodeFocusable(node: focusNode!, onSelect: onSelect, builder: builder);
  }
}

class _NodeFocusable extends StatefulWidget {
  const _NodeFocusable({required this.node, required this.onSelect, required this.builder});
  final FocusNode node;
  final VoidCallback onSelect;
  final Widget Function(bool focused) builder;

  @override
  State<_NodeFocusable> createState() => _NodeFocusableState();
}

class _NodeFocusableState extends State<_NodeFocusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: widget.node,
      mouseCursor: SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onSelect();
          return null;
        }),
      },
      onFocusChange: (f) => setState(() => _focused = f),
      onShowHoverHighlight: (h) {
        if (h && !widget.node.hasFocus) widget.node.requestFocus();
      },
      child: GestureDetector(onTap: widget.onSelect, child: widget.builder(_focused)),
    );
  }
}

// ---------- Progress bar: click or drag with the mouse, ←/→ when it's selected ----------

class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.onSeek,
    required this.onKeySkip,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final void Function(Duration to) onSeek;
  final void Function(bool forward) onKeySkip;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  bool _focused = false;
  bool _hover = false;
  double? _dragFraction;

  double _fraction(Duration d) {
    final total = widget.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (d.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Duration _at(double fraction) =>
      Duration(milliseconds: (widget.duration.inMilliseconds * fraction.clamp(0.0, 1.0)).round());

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hover || _dragFraction != null;
    final played = _dragFraction ?? _fraction(widget.position);
    final buffered = _fraction(widget.buffered);

    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          widget.onKeySkip(false);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          widget.onKeySkip(true);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: LayoutBuilder(builder: (context, box) {
          double toFraction(double dx) => (dx / box.maxWidth).clamp(0.0, 1.0);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => widget.onSeek(_at(toFraction(d.localPosition.dx))),
            onHorizontalDragStart: (d) => setState(() => _dragFraction = toFraction(d.localPosition.dx)),
            onHorizontalDragUpdate: (d) => setState(() => _dragFraction = toFraction(d.localPosition.dx)),
            onHorizontalDragEnd: (_) {
              if (_dragFraction != null) widget.onSeek(_at(_dragFraction!));
              setState(() => _dragFraction = null);
            },
            child: SizedBox(
              height: 28,
              child: Stack(alignment: Alignment.centerLeft, clipBehavior: Clip.none, children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  height: active ? 8 : 5,
                  decoration: BoxDecoration(
                    color: _fg.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: buffered,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    height: active ? 8 : 5,
                    decoration: BoxDecoration(
                      color: _fg.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: played,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    height: active ? 8 : 5,
                    decoration: BoxDecoration(color: _fg, borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                // Handle, shown when the bar is selected, hovered or dragged.
                Positioned(
                  left: played * box.maxWidth - 11,
                  child: AnimatedOpacity(
                    opacity: active ? 1 : 0,
                    duration: const Duration(milliseconds: 140),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: _fg,
                        shape: BoxShape.circle,
                        boxShadow: _focused
                            ? [BoxShadow(color: _fg.withOpacity(0.35), spreadRadius: 6)]
                            : const [],
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          );
        }),
      ),
    );
  }
}
