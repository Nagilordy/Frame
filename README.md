# Frame

A couch-first app for watching your **Jellyfin** library, with a controller, a mouse or a keyboard.
Frame talks to your existing Jellyfin server and plays the original files directly, in the best
quality your screen can show, including real HDR and Dolby Vision on Linux.

> **Status:** early test builds (pre-release). Expect rough edges.

## Features

- **Console-style home screen.** Full-screen artwork, Continue watching, Recently added, and one tab
  per library (Movies, Shows, Anime…).
- **Who's watching.** Profiles like a console, with Quick Connect sign-in (approve a code from your
  phone, nothing to type) or a password, and an on-screen keyboard for the controller.
- **Best-quality playback.**
  - Plays the original file straight from your server.
  - On Linux, plays in mpv with real HDR and Dolby Vision.
  - Switches to the server's converted version automatically if a device can't keep up.
- **Remembers your audio and subtitles** per show, like Infuse (language, forced, SDH).
- **Watch together.** Watch in sync with friends on the same server. Everyone can play, pause and
  skip, and keeps their own subtitles and audio. Rooms show up on Home with an invite.
- **Made for controllers.** PlayStation, Xbox and Steam controllers work out of the box, with a
  button legend that matches your controller.
- **Several servers.** Your own and a friend's, each staying signed in.

## Download

Get the latest build from the [Releases](../../releases) page:

| System | File | How to install |
|---|---|---|
| Windows 10/11 | `FrameSetup.exe` | Run it. Updates install over the old version, and your settings stay. |
| Linux | `Frame-x86_64.AppImage` | Make it executable (right-click > Properties > allow running as a program), then open it. |

On Linux, Frame downloads its own copy of mpv the first time it plays a video, for HDR and Dolby
Vision. Nothing else to install.

## What you need

- A **Jellyfin** server (10.9 or newer recommended) on your network or reachable over the internet.
- For **Watch together**:
  - Every profile needs SyncPlay access: Jellyfin Dashboard > Users > *profile* > SyncPlay access.
  - Frame's instant sync mode also needs "Allow remote control of other users" for each profile
    that uses it.
- For **Quick Connect**: turn it on once in Jellyfin (Dashboard > General > Quick Connect).

## Controller

| Button (PlayStation / Xbox) | Does |
|---|---|
| Cross / A | Select |
| Circle / B | Back. On Home and in libraries, goes back to the top first |
| Triangle / Y | Profile menu on Home · playback info in the player · Join from an invite |
| Square / X | Delete a letter on the keyboard |
| L2 / R2 (LT / RT) | Previous / next tab (Home, libraries; seasons on a show page) |
| L1 / R1 (LB / RB) | Skip back 10 s / forward 30 s in the player |
| Options / Menu | Play / pause |
| Create / View | Full screen on or off |

Keyboard: arrows, Enter, Escape, Space, Page Up / Page Down, F11.

## Building from source

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

If something goes wrong, these files help find out why:

- Linux: `~/.local/share/frame/logs/`
- Windows: `%APPDATA%\Frame\logs\`

There are two kinds of log:
- `perf-<date>.log` covers smoothness, memory and playback stats.
- `together-<date>.log` covers Watch together messages.

## Known limitations

- **Windows:** plays inside the app window, so there's no HDR passthrough yet.
- **Fire Stick, iPhone and Apple TV** builds aren't available yet.
- **Watch together with official Jellyfin apps:** works, but those apps can still cause their own
  sync loops. Frame-to-Frame rooms are the smoothest.

## Credits

Built on [Jellyfin](https://jellyfin.org), [mpv](https://mpv.io),
[media_kit](https://github.com/media-kit/media-kit) and [Flutter](https://flutter.dev).
Fonts: Hanken Grotesk and Sora (SIL Open Font License).
