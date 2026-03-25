# MacAMRP

A macOS menu bar app that displays your currently playing Apple Music track as Discord Rich Presence.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Now Playing** — automatically updates your Discord status with the current track and artist
- **Progress Bar** — real-time playback position synced with Apple Music
- **Album Art** — fetches artwork via the iTunes Search API
- **Listening to / Playing** — choose between Discord activity types
- **Customisable Images** — pick what appears as the large and small image on the presence card
- **Launch at Login** — starts automatically when you log in
- **First-launch Onboarding** — guided setup on first run

## Requirements

- macOS 13 Ventura or later
- [Discord](https://discord.com) desktop app running

## Installation

MacAMRP is built with Xcode and distributed directly — no App Store, no notarisation required for personal use.

1. Clone the repo and open `MacAMRP.xcodeproj` in Xcode
2. Select **Product → Archive**
3. In the Organiser, right-click the archive → **Show in Finder**
4. Right-click `MacAMRP.app` inside the `.xcarchive` → **Show in Finder**, then drag to `/Applications`

On first launch, macOS may ask for permission to control Music.app — this is required for the progress bar.

## How It Works

- Listens for `com.apple.Music.playerInfo` notifications to detect track changes
- Fetches playback position and duration via AppleScript
- Looks up album artwork from the iTunes Search API
- Communicates with the Discord desktop client over a local Unix socket using the Discord IPC protocol

## Settings

Open the menu bar icon and click **Settings** to configure:

| Setting | Options |
|---|---|
| Rich Presence | Enable/disable, activity type (Playing / Listening to), show timestamps |
| Images | Large image (album art / Apple Music icon / none), small image (Apple Music icon / none) |
| General | Launch at login |

## License

MIT
