# MacAMRP

A macOS menu bar app that displays your currently playing Apple Music track as Discord Rich Presence.

![macOS](https://img.shields.io/badge/macOS-26%2B-blue) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![License](https://img.shields.io/badge/license-MIT-green) ![Version](https://img.shields.io/badge/version-1.1-brightgreen)

## Features

- **Now Playing** — automatically updates your Discord status with the current track and artist
- **Progress Bar** — real-time playback position, works correctly on macOS 26/27 for streaming tracks
- **Album Art** — fetches artwork via the iTunes Search API with relevance scoring (no wrong covers)
- **Artist as Presence Name** — shows "Listening to [Artist]" instead of the app name
- **Listening to / Playing** — choose between Discord activity types
- **Customisable Images** — pick what appears as the large and small image on the presence card
- **Hide When Paused** — optionally clear the presence while music is paused
- **Launch at Login** — starts automatically when you log in
- **First-launch Onboarding** — guided setup on first run

## Requirements

- macOS 26 Tahoe or later (built targeting macOS 27 Golden Gate Beta)
- [Discord](https://discord.com) desktop app running

## Installation

MacAMRP is built with Xcode and distributed directly — no App Store, no notarisation required for personal use.

1. Clone the repo and open `MacAMRP.xcodeproj` in Xcode
2. Select **Product → Archive**
3. In the Organiser, right-click the archive → **Show in Finder**
4. Right-click `MacAMRP.app` inside the `.xcarchive` → **Show in Finder**, then drag to `/Applications`

On first launch, macOS will ask for permission to control Music.app — this is required for the progress bar.

## How It Works

MacAMRP uses a three-layer approach to get track data from Apple Music:

1. **`com.apple.Music.playerInfo` distributed notifications** — detect track changes and state updates instantly. Provides track name, artist, album, and duration immediately.

2. **MediaRemote private framework** — attempted for accurate playback position using the same source as the Control Center media overlay. Currently locked behind a private entitlement on macOS 27 Beta (`Operation not permitted`), so falls through to layer 3.

3. **AppleScript `player position`** — app-level property query that reliably returns the current playback position. This is **not** affected by the macOS 26/27 regression that breaks `current track` property access for streaming tracks.

Album artwork is fetched from the iTunes Search API using a multi-strategy scorer (direct catalog lookup → album text search → song text search). Results require a positive relevance score — no blind first-result fallback that could show the wrong cover art.

Discord communication happens over a local Unix socket (`/var/folders/.../discord-ipc-0`) using the Discord IPC protocol directly, with no OAuth or bot token required.

## macOS 26/27 Notes

macOS 26 Tahoe introduced a regression (Apple FB19908171) where AppleScript access to `current track` properties (`duration`, `track number`, `store URL`, etc.) throws error -1728 for any Apple Music streaming track not in the local library. MacAMRP works around this by using application-level properties (`player position`) and the distributed notification's `Total Time` field for duration, both of which are unaffected.

## Settings

Open the menu bar icon and click **Settings** to configure:

| Setting | Description |
|---|---|
| Enable Rich Presence | Show/hide your presence entirely |
| Activity type | "Playing" or "Listening to" |
| Show artist as presence name | Replaces the app name with the artist (e.g. "Listening to Radiohead") |
| Show artist name | Display artist on the second line of the presence card |
| Large / small image | Album art, Apple Music icon, or none |
| Show progress bar | Real-time playback position |
| Hide when paused | Clear presence while music is paused |
| Launch at login | Start MacAMRP automatically |
| Discord Client ID | Use your own Discord application |

## Discord Developer Portal

The app uses client ID `1483608868809605140`. To use your own:
1. Create an application at [discord.com/developers](https://discord.com/developers)
2. Under **Rich Presence → Art Assets**, upload an image with the key `applemusic` (used as the small icon)
3. Copy your application ID into Settings → Discord Application → Client ID

## Architecture

See [ARCHITECTURE.md](MacAMRP/ARCHITECTURE.md) for a full technical reference including component design, the macOS 26/27 AppleScript regression findings, MediaRemote investigation notes, and Discord IPC protocol details.

## License

MIT
