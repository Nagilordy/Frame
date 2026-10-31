# Building Frame

Frame is a [Flutter](https://flutter.dev) app written in Dart. The controls inside the mpv player
are a Lua script (`assets/mpv/frame_ui.lua`).

```bash
flutter pub get
flutter run -d linux --release      # or: -d windows
```

Linux builds need the usual Flutter desktop packages plus `libmpv`. The GitHub Actions workflows
in `.github/workflows` build the Windows installer and the Linux AppImage. Pushing a tag like
`v0.3` attaches both to a release.

## Logs

- `perf-<date>.log`: smoothness, memory and playback stats
- `together-<date>.log`: watch party (SyncPlay) messages

Linux: `~/.local/share/frame/logs/` · Windows: `%APPDATA%\Frame\logs\`
