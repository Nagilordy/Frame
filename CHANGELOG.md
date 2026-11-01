# Changelog

What changed in each version of Frame. Newest first.

## 0.3 (in testing)

### New
- **iPhone: Home made for the phone (stage 1 of the phone design).** Home now has its own touch
  layout in phone sizes instead of the shrunk TV screen, upright and sideways.
  - Upright: artwork at the top with the title, Resume and Watch together, then Continue
    watching and Recently added as rows you swipe through. Library tabs scroll sideways at the top.
  - Sideways: the TV layout re-sized for a phone, artwork across the screen, the first row
    peeking in at the bottom.
  - Pull down to refresh. Every button gives a light tap you can feel.
  - Screens that don't have a phone layout yet (libraries, show and movie pages, profiles)
    turn the phone sideways while they're open. Video always plays sideways.
- **Downloads (step 1: original files).** Watch without the server, on a plane or anywhere.
  - Download on a movie page and on each episode of a show page (phones). Shown only to
    profiles allowed to download ("Allow media downloading" in the Jellyfin dashboard).
    It's a small grey icon, not a button: beside the year and quality lines on a movie, at the
    end of each episode row. An arrow to start, a thin ring while it downloads (tap to pause),
    a tick when it's on the phone. The line next to it adds "· 42%", "· Paused" or "· Downloaded".
  - The original file, in full quality, with its details and artwork. Downloads keep going
    with Frame closed, pause and resume, retry after a dropped connection, and notify when
    done. Wi-Fi only by default (a switch on the Downloads screen).
  - Downloads screen (the download button next to your avatar on Home, and on Home's
    "can't reach the server" message): what's downloading, what's on the phone, space used;
    tap to play, swipe left to remove.
  - Downloads play from the phone even when the server is there. Where you stop is saved and
    sent to Jellyfin the next time it answers, so Continue watching stays right.
- **iPhone: Frame's name and icon** on the home screen, instead of the template's.
- **iPhone: lighter and safer playback.**
  - The picture is drawn at the screen's size instead of the file's: a 4K movie no longer
    makes the phone draw 3840x2160 every frame. Less heat and battery, fewer dropped frames.
  - Leaving Frame while a video plays (home, another app, locking the phone) pauses it and
    stops the picture, since iOS stops apps that draw with the GPU in the background. Coming
    back, it's where you left it. In a watch party the video keeps going for the others.
- **iPhone: the player made for touch (stage 4).** Video still plays sideways.
  - Tap shows or hides the controls. Double-tap the left or right side: back 10 s or forward
    30 s, keep tapping to add more (shown on screen). Double-tap the middle: play or pause.
  - Press and hold: 2× speed while your finger stays down. Swipe down: close the player.
    Pinch: fill the screen or fit the whole picture.
  - Phone-sized controls: Back, title and quality at the top; −10, play/pause, +30 in the
    middle; a timeline you can drag (it grows, shows the time and chapter, and taps at each
    chapter), then Audio, Subtitles, Playback and Info with what's chosen now.
  - Audio, Subtitles and Playback open as a panel from the right. Playback adds speed
    (0.75× to 2×, not in a watch party).
  - Subtitles › Size & position: Bottom, Raised, Higher, size and height sliders and a
    background box, live on the picture. Subtitles can now go much higher than before.
  - Info: the episode, the show and playback info in tabs, with the next episode beside them.
  - Up next: a card over the credits with the next episode's picture, "Play in 10" counting
    down and Watch credits.
- **iPhone: show and movie pages made for the phone (stage 3).** Upright and sideways.
  - Show page: the next episode to watch with Play / Resume, Watch together and Mark season
    watched (tap twice), season pills, and the episodes (a list upright, a row sideways that
    opens on the next one). Tap an episode to play it.
  - Movie page: logo, year, length, rating, quality and genres; Play / Resume across the width,
    Watch together, Mark watched and From the beginning; the summary (tap for all of it),
    director and the cast with their photos.
  - Coming back from a video, the page can turn upright again.
- **iPhone: libraries made for the phone (stage 2).** Upright and sideways.
  - Library tabs scroll at the top; the library's name, how many titles and the current sort
    and filters, with Sort & filter beside it (white while a filter is on).
  - Posters three across upright, seven or so sideways, with watched ticks and progress.
    Scroll with a finger; pull down to refresh.
  - Sort & filter: a sheet from the bottom upright, a panel from the right sideways. Sort by,
    Unwatched only, 4K only and genres; every change applies straight away.
- **iPhone: profile menu and servers made for the phone.** Upright and sideways.
  - Your avatar opens a sheet (a panel from the right when sideways): who you are, the server
    you're on with Change, Start a watch party, Switch profile, Sign out (tap twice). Drag it
    away or tap outside to close.
  - Change server: your servers first, the one in use marked Connected, each with how many
    profiles are signed in; swipe one to the left to forget it and its sign-ins. Then what
    Frame finds on your Wi-Fi.
  - Add a server: one address field with the phone's own keyboard, checked as you type
    ("Found Home Theater · Jellyfin 10.10"), then Connect.
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
  credits start if the server knows, otherwise 20 seconds before the end.
  The next episode starts 10 seconds after the card appears.
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
- **New profile menu (Triangle on Home):** a PS5-style control center that slides up from the
  bottom, with big tiles for Watch party, Switch profile, Server and Sign out.
- **New watch party menu:** a tall card on the right, like the PS5 party panel: what everyone is
  watching, who's in the party, and big buttons to join, pick something or leave.
- **New notifications:** a card that slides in at the top right, under your profile, with a
  white "△ Join" button for invites and a line counting down until it goes.
- **New server screen** (Triangle › Server, and the first screen of a new install): your servers
  as big cards, the one you're on marked Connected, and the address box below.
- **Who's watching, refreshed:** the time at the top right, Home's ring on the selected profile,
  a white Continue / Sign in button under its name, "Add profile" as a dashed circle, and the
  server in a quiet chip next to Change server.
- **Sign in, refreshed:** "Add a profile" with the dashed circle, the two ways in as new-style
  cards, the Quick Connect code with one digit per tile, a running line while it waits, and
  rounded pill fields (also on the server screen).
- **Library sort & filter sheet:** Sort, Unwatched / 4K and Genre together in one sheet that
  slides up from the bottom; choices apply straight away and combine. It replaces the four
  buttons above the grid: one "Sort & filter" button now, lit up while a filter is on.
- **Error screen in the new style:** a centred card over the faded artwork of what you tried to
  play, with Retry (when the server was out of reach) and Back.
- **iPhone (first fixes):**
  - The app fills the whole screen, edge to edge.
  - Typing no longer shrinks and rescales the whole screen when the keyboard opens; the screen
    just slides up enough to keep the field you're typing in above the keyboard.
  - Videos: like on a PC, the original file plays straight from the NAS whenever it can (MKV,
    HEVC, HDR, TrueHD, DTS, every kind of subtitle), with no conversion on the server. Frame
    switches to the server's version by itself only if the original shows no picture within a
    few seconds or stutters. Dolby Vision Profile 5 always uses the server's version on a phone
    (it would otherwise show pink and green).
  - Fix: no picture on iPhone at all ("MissingPluginException … VideoOutputManager.Create"):
    the iPhone build now includes the real video plugin (CocoaPods instead of Swift Package
    Manager).
  - Fix: no picture on iPhone (sound and time running, "No render context set"): playback
    now waits for the picture's drawing surface before opening the video. The read-ahead
    stays in memory on phones (iOS refused mpv's cache file).
  - If a video still hasn't started after 12 seconds, a box over it says what the player is
    doing (source, length, buffering, the player's last messages), to find out why.
- **Show page: full episode summaries.** When you move onto the episodes, the space above the row
  switches to the selected episode: the show's name (small), the episode's name, "S17 · E19 ·
  22 min · Aired Apr 30, 2006 · Ends at 12:26" and the whole summary (up to 6 lines). The cards
  keep just the episode number and name. Going up to the seasons or buttons brings the show back.
- **On-screen keyboard in the new style:** a full-width sheet from the bottom (like the player's
  panel and the PS5 keyboard), the field you're typing in at the top as a pill with the white
  ring, bigger rounded keys, the selected key white with the ring, and Done always lit.
- **Fix (#3):** a selected text field no longer turns solid white and hides what you type; its
  fill is solid now, so the ring stays a ring.
- **Watch party: Join a party and Start a watch party in the new style.** Both use the party
  menu's tall card on the right.
  - Join a party (from the rooms pill on Home): one card per party with whose it is, what's on,
    who's in it and whether it's playing or paused; "Start my own party" at the bottom.
  - Start a watch party (profile menu): says what a party does in three steps, shows any party
    already going so you can join it instead, then Start the party / Not now. Before, the tile
    started a party straight away.
- **Info is now a tab of the player sheet** (Triangle, or Info on the bar), next to Audio,
  Subtitles and Playback. Left: the episode's picture, title, season / episode / year / length,
  when it ends and its summary. Right: video, audio, subtitles, how it's playing (original file
  or converted), decoder, buffered and dropped frames, and your screen. Replaces the small box.
- **Log fix:** "mpv: closed while starting" no longer appears every time you quit the player
  normally; it now only shows when mpv really closed before Frame could connect.
- **New loading screen, like starting a game on PS5:** the show's artwork full screen, the logo
  bottom left where Home shows it, the episode line, chips for the quality (4K, HDR, 5.1...), a
  running line and "Resumes at 14:55" / "Starting". Frame and the player show the same screen,
  and when the video is ready it dips to black and opens on the video.
- **Up next card in the new style:** a rounded card at the bottom right with the next episode's
  picture, title, season / episode and length. The white Play now pill fills up during the
  10-second countdown; "Watch the credits" (Circle) hides it and lets the episode play out.
  In a watch party only the host's countdown moves everyone on.
- **New player controls: one sheet.** The controls now sit on a short dark sheet at the bottom
  (progress bar on top; Audio, Subtitles, Playback and Info on the left with what's in use
  written under each; -10, play, +30 in the middle; button guide on the right). Choosing Audio,
  Subtitles or Playback grows the same sheet upward instead of swapping to a separate menu.
  The sheet is see-through, so the video shows behind it.
- **Player sheet for Audio, Subtitles and Playback,** in the new style, with the progress bar on
  top and the video still visible above it.
  - Tabs for Audio, Subtitles and Playback; L1 / R1 (LB / RB) switch between them.
  - Tracks are big cards in a row (language on top, details underneath), moved with left /
    right. The one in use has a tick and is selected when the sheet opens.
  - Subtitles: Size (Small, Medium, Large), Position (Bottom, Higher) and Background (Off, Box)
    are small choices under the tracks; press down to reach them. They apply straight away
    and the sheet stays open.
  - Works with the mouse too: click a tab, card or choice; click above the sheet to close it.
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
