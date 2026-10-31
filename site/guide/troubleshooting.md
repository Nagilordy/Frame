# Troubleshooting

## Frame can't reach my server

- Check the server (or NAS) is on and connected, then press **Retry**.
- On another device, open the same address in a browser. If Jellyfin doesn't open there either, the problem is the server or the network.

## A video won't play or stutters

- Under **Playback**, try **Server version**.
- Open **Info** in the player and look at **Dropped frames** and **Buffered**. Include them in a bug report.

## Watch party problems

Check the server settings on the [Watch parties](/guide/watch-party#what-the-server-needs) page: every profile needs SyncPlay access.

## Logs

If Frame crashed or something misbehaves, the latest log file helps a lot:

- **Linux:** `~/.local/share/frame/logs/`
- **Windows:** `%APPDATA%\Frame\logs\`

## Report a problem

Use the [bug report form](https://github.com/Nagilordy/Frame/issues/new?template=bug_report.yml) on GitHub (a free account is needed). It asks for everything needed to fix it. Ideas go in the [feature request form](https://github.com/Nagilordy/Frame/issues/new?template=feature_request.yml).
