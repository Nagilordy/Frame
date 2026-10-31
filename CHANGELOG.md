# Changelog

What changed in each version of Frame. Newest first.

## 0.3 (in testing)

### New
- **Watch parties.** A room that stays together between videos.
  - Start one from the Triangle menu on Home: "Start a watch party". Nothing has to play yet.
  - Friends get an invite on their Home and join with Triangle.
  - While you're in a party, Play on anything (Home, a library, a show or movie page) plays it
    for everyone. Their players open by themselves, on whatever screen they're on.
  - When a video ends or someone backs out, everyone stays in the party.
  - A party pill at the top right of Home shows who's in it, with "Join what everyone is
    watching" and "Leave party".
  - You only leave when you choose Leave party, switch profile or sign out.
- **Up next.** Near the end of an episode, a card shows the next one. It appears where the
  credits start if the server knows, otherwise 30 seconds before the end.
  - Cross plays it now, Circle hides the card.
  - At the end, or when you skip past the end, the next episode starts by itself, across
    seasons, without leaving the player.
  - In a party, everyone moves on together.
- **Movie page.** Artwork, logo, year, length, age rating, score, quality, genres, tagline,
  summary, cast and director.
  - Buttons: Play / Resume, From the beginning, Watch together, Mark watched (toggles).
  - Opens from a library and from Recently added on Home. Continue watching still resumes
    straight away.
- README for the GitHub page.

- **Windows plays in mpv too**, like Linux: real HDR (with Windows HDR on), Dolby Vision and
  TrueHD. The installer now includes mpv. Without it, Frame falls back to its built-in player.

### Improved
- **New app icon** on Linux (AppImage) and Windows (taskbar, Start menu, installer).
- **Continue watching shows your next episode.** Finish an episode and the next one waits at
  the front of the row, mixed with what you stopped part-way, newest first.
- **Faster launch:** Frame no longer waits to check its video player before opening its window.
- **The selection stays on the same title** when Home refreshes a second after opening (or
  after a video), instead of landing on whatever moved into that spot.
- **A sleeping server doesn't greet you with an error:** Home says "Connecting to …" and
  keeps trying for about 20 seconds first.
- **Starting a video stays inside Frame.** Pressing Play turns the page into a loading screen:
  the artwork dims away and the title logo settles in the centre. The player opens on exactly
  the same screen, logo included, then fades into the video. In full screen, Frame no longer
  minimizes behind the player, so leaving a video returns straight to the page with no
  animation. (In a window, Frame still steps aside as before.)
- **Back during a video takes two presses:** the first brings the controls back, the second
  leaves. One stray press no longer ends the video.
- **Controller legend in the player** no longer disappears on some videos, or when a resting
  mouse pointer or a light Steam trackpad touch is detected.
- **Smoother motion** for 25 and 23.976 fps videos on a 60 Hz screen. The player times playback
  to the screen and blends the odd frame, instead of alternating 2 and 3 refreshes.
- **Performance log:** each line now records the window size and full-screen state, and nothing
  is recorded while Frame is hidden behind a video.
- **Watch together log:** instant mode now records what it sends and receives.

### Fixed
- **Subtitle files next to a video** (movie.fr.srt, .ass, .vtt, .sup) now show up in the player
  on Linux and Windows. Before, only subtitles inside the video file were offered.
- **Disc images and disc folders** (ISO, Blu-ray BDMV, DVD VIDEO_TS) play: they use the
  server's version automatically, since they can't be streamed as one file.
- **Server off when you press Play:** Frame says "Can't reach your Jellyfin server" within a
  few seconds, with Retry and Back, instead of loading for half a minute and blaming the video.
- **A video that won't open is retried with the server's version** from the same moment,
  instead of ending on an error. If that fails too, Frame says so.
- **Resume is exact:** a video picks up exactly where you stopped, not a few seconds earlier
  at the previous keyframe. Skipping stays as quick as before.
- **Interlaced videos** (TV recordings, DVDs) are deinterlaced: no more combing on movement.
- **Windows keeps HDR and Dolby Vision** even if the bundled mpv can't report its version.
- **Playback info (Triangle) shows in the Windows player** again. The box failed to draw.
- Going from one video to the next no longer turns off full screen control in the new player.
- **The player shows PlayStation buttons with a PlayStation controller.** Its legend always
  drew Xbox letters (A, B, LB, RB), even when Frame's own screens showed PlayStation symbols.
- **"mpv closed while starting" on Linux is gone.** Frame now runs its mpv from an unpacked copy,
  so a video cut short can no longer leave mpv unable to start (and videos open a bit faster).
- **Controller legend comes back in the player** when you pick the controller up again after
  using the mouse or keyboard.
- **Frame no longer drops out of full screen** when you leave a video.
- **No more crash message** when the controller is touched just as the player closes.

## 0.2

### New
- **L2 / R2 switch tabs:** libraries from Home, and seasons on a show page.
- **Windows player remembers audio and subtitle choices** per show, like the Linux player.
- **Performance log:** `perf-<date>.log` in Frame's log folder.
- **Watch together log:** `together-<date>.log`, to compare with the server's log.

### Fixed
- **Watch together pause/play loops:**
  - short hiccups are ignored;
  - jumps are exact;
  - one "ready" per jump, with the true position;
  - "press play to start anyway" when the room is stuck.
- **Holding skip:** adds up properly, in rooms and in the Windows player.
- **Circle:** on Home and in libraries, it goes back to the top first.
- **L2 / R2** no longer also move the selection (a PS5 controller quirk on Linux).
- **Faster startup:** the mpv version is remembered, and no waiting on a sleeping server.
- **No false "mpv closed right away" error** when backing out quickly.
- **Quick Connect** keeps the same code through network hiccups.
- **Sign out** also ends the login on the server.
- **Show pages** refresh right after watching from Home.
- **Triangle** shows playback info in the Windows player.
