# MacAMRP — Technical Architecture Reference

This document is a complete technical reference for the MacAMRP codebase. It covers every component, how they connect, and the key decisions and gotchas discovered during development.

---

## What the App Does

MacAMRP is a macOS menu bar app that reads the currently playing track from Apple Music and sends it to Discord as Rich Presence. It runs entirely in the background as a menu bar extra with no Dock icon (except when the Settings or Onboarding windows are open).

---

## Project Structure

```
MacAMRP/
├── AppIconRenderer.swift          # Programmatic app icon (CGContext)
├── MacAMRP/
│   ├── MacAMRPApp.swift           # App entry point, menu bar extra, first-launch trigger
│   ├── ContentView.swift          # MenuBarView + SettingsWindowController
│   ├── RichPresenceManager.swift  # Central coordinator (settings, track→presence logic)
│   ├── MusicObserver.swift        # Apple Music observation + AppleScript queries
│   ├── DiscordIPC.swift           # Discord Unix socket IPC protocol
│   ├── iTunesArtworkFetcher.swift # iTunes Search API for album artwork URLs
│   ├── SettingsView.swift         # Settings window UI (SwiftUI, tabbed)
│   ├── OnboardingView.swift       # First-launch splash screen
│   ├── Info.plist                 # NSAppleEventsUsageDescription, LSApplicationCategoryType
│   └── MacAMRP.entitlements       # com.apple.security.automation.apple-events
```

---

## Architecture Overview

```
Apple Music
    │  com.apple.iTunes.playerInfo (DistributedNotificationCenter)
    ▼
MusicObserver ──AppleScript──► fetchDuration (position, duration, playlist, track number)
    │
    │ onTrackChange: TrackInfo?
    ▼
RichPresenceManager
    │  ├── iTunesArtworkFetcher (async, iTunes Search API)
    │  └── builds DiscordActivity
    ▼
DiscordIPC ──Unix socket──► Discord desktop client
                             /var/folders/.../discord-ipc-0
```

---

## Components

### MacAMRPApp.swift

- `@main` SwiftUI App with a single `MenuBarExtra` scene (`.menuBarExtraStyle(.menu)`)
- `LSUIElement = true` in Info.plist suppresses the Dock icon by default
- On first launch (`!UserDefaults.standard.bool(forKey: "hasLaunchedBefore")`), shows `OnboardingWindowController` after a 0.3s delay
- **No `Window` scene** — settings window is managed manually by `SettingsWindowController`

---

### ContentView.swift

Contains two things:

**`MenuBarView`** — the dropdown menu shown when clicking the menu bar icon:
- Enable/disable toggle
- "Connected to Discord" / "Discord not connected" status (uses `.symbolRenderingMode(.palette)` to show green dot — required because menu bar strips `.foregroundStyle()` colors)
- Settings button → calls `SettingsWindowController.shared.open(manager:)`

**`SettingsWindowController`** — singleton `NSWindowController + NSWindowDelegate`:
- Opens a floating settings window
- On open: `NSApp.setActivationPolicy(.regular)` + `NSApp.activate(ignoringOtherApps: true)` + `window.orderFrontRegardless()` + `window.makeKeyAndOrderFront(nil)` — all needed for reliable focus
- On close (`windowWillClose`): reverts to `NSApp.setActivationPolicy(.accessory)`
- Sets `NSApp.applicationIconImage = AppIconRenderer.cachedIcon` so the custom icon appears in the Dock while settings is open

---

### RichPresenceManager.swift

The central `@Observable` class that owns all state. All settings are stored properties with `didSet` that write to `UserDefaults.standard`.

**Settings:**
| Property | Key | Default | Notes |
|---|---|---|---|
| `isEnabled` | `richPresenceEnabled` | `true` | Clears activity when disabled |
| `largeImageMode` | `largeImageMode` | `"albumart"` | `"albumart"` / `"applemusic"` / `"none"` |
| `smallImageMode` | `smallImageMode` | `"applemusic"` | `"applemusic"` / `"none"` |
| `showTimestamp` | `showTimestamp` | `true` | Progress bar via start+end timestamps |
| `showArtistInState` | `showArtistInState` | `true` | Artist name on second line |
| `showTrackNumber` | `showTrackNumber` | `false` | Track position on second/third line |
| `useListeningType` | `useListeningType` | `false` | Activity type 2 vs 0 |
| `hideWhenPaused` | `pauseBehaviour` | `false` | Clears presence when paused |
| `discordClientID` | `discordClientID` | `"1483608868809605140"` | Custom app ID |
| `launchAtLogin` | — | — | `SMAppService.mainApp`, not UserDefaults |

**Track flow:**
1. `MusicObserver.onTrackChange` fires → `handleTrackChange(track)`
2. Queue position counter updated (increments per new track, resets on playlist change)
3. Artwork cache check: if same track and URL cached → `updatePresence` directly
4. Otherwise: start async `iTunesArtworkFetcher` task, call `updatePresence` when done
5. `updatePresence(for:artworkURL:)` builds `DiscordActivity` and calls `discord.setActivity`

**Presence layout logic:**

For "Playing" (type 0):
- `details` = track name
- `state` = artist name
- `largeImageText` = track number (if enabled) OR album name
- Progress bar via timestamps

For "Listening to" (type 2):
- `details` = track name
- `state` = `"Artist • Track X of Y"` (combined, because largeImageText must be album name for progress bar)
- `largeImageText` = album name (MUST stay as album name for Discord to render the progress bar — changing it breaks the bar)
- Progress bar via start+end timestamps

**Track number logic:**
- **User playlist**: shows `"Track {queuePosition} of {playlistSize}"` where `queuePosition` is our own counter (not shuffle-aware from AppleScript — we count songs played sequentially in the same playlist context)
- **Album**: shows `"Track {trackNumber} of {albumTrackCount}"` from file metadata
- **Single / no metadata**: falls back to album name

**Small image text:**
- If in a user playlist: `"Playlist: {playlistName}"`
- Otherwise: `"Apple Music"`

---

### MusicObserver.swift

Listens for `com.apple.iTunes.playerInfo` via `DistributedNotificationCenter`. This notification fires on play, pause, stop, and track changes.

**`TrackInfo` struct:**
```swift
struct TrackInfo: Equatable {
    let name: String
    let artist: String
    let album: String
    let duration: TimeInterval?
    let playerPosition: TimeInterval?
    let playbackState: PlaybackState  // .playing / .paused / .stopped
    let playlist: String?             // nil if playing from library view
    let playlistSize: Int?            // total tracks in user playlist
    let trackNumber: Int?             // album track number (metadata)
    let albumTrackCount: Int?         // total tracks on album (metadata)
}
```

**Two data sources:**

1. **Notification userInfo** (`parseTrackInfo`): provides name, artist, album, duration (in ms — must divide by 1000), playerPosition. Fast but position can be stale.

2. **AppleScript** (`fetchDuration`): always called after every notification to get fresh position + duration + playlist info + track metadata. Runs on background thread, fires `onTrackChange` again when done.

**`fetchDuration` AppleScript** returns: `duration|||position|||playlistName|||trackNumber|||trackCount|||playlistSize`
- Playlist name and size only populated when `special kind` is `"none"` or `"Genius"` (user playlists, not library views like Songs/Albums/Recently Added)
- Uses `track number of current track` and `track count of current track` for album metadata
- `count (tracks of current playlist)` for playlist size

**`pollCurrentTrack`**: One-shot query on launch to populate initial state without waiting for the next notification. Same data as `fetchDuration` but includes player state.

**Important entitlement**: `com.apple.security.automation.apple-events` in MacAMRP.entitlements + `NSAppleEventsUsageDescription` in Info.plist are required. Without them, AppleScript silently fails with error -1743 "Not authorized to send Apple events to Music."

---

### DiscordIPC.swift

Communicates with the Discord desktop client over a local Unix domain socket.

**Socket path**: `/var/folders/.../discord-ipc-0` (uses `FileManager` to find the temp directory)

**Protocol**:
- Each message is a frame: `[opcode: UInt32 LE][length: UInt32 LE][json payload: UTF-8]`
- Opcodes: 0 = handshake, 1 = frame, 2 = close, 3 = ping, 4 = pong

**Connection flow**:
1. Connect to Unix socket
2. Send opcode 0 handshake: `{"v": 1, "client_id": "..."}`
3. Receive opcode 1 READY response → `isConnected = true`
4. Send `SET_ACTIVITY` commands as opcode 1 frames

**`DiscordActivity` struct** (built by `RichPresenceManager`):
```swift
var activityType: Int           // 0 = Playing, 2 = Listening to
var details: String?            // Line 1 (track name)
var state: String?              // Line 2 (artist / artist+track number)
var largeImageURL: String?      // Asset key or external URL
var largeImageText: String?     // Line 3 — visible text below state in presence card
var smallImageURL: String?      // Asset key or external URL
var smallImageText: String?     // Tooltip on small image
var startTimestamp: Date?       // For progress bar start
var endTimestamp: Date?         // For progress bar end
var buttons: [...]?
```

**Progress bar**: Requires BOTH `startTimestamp` AND `endTimestamp`. `start = now - position`, `end = now + remaining`.

**Asset keys vs URLs**: Discord asset keys (strings like `"applemusic"`) must be pre-uploaded in the Discord Developer Portal under Rich Presence → Art Assets for the application. External URLs work but only reliably on the local client — other users/devices may not see them. We use the `"applemusic"` asset key (uploaded to the portal) for the Apple Music icon.

**Activity type 2**: "Listening to" — works via plain IPC without OAuth since ~mid-2024. No special permissions needed. Progress bar works with both timestamps set.

**Auto-reconnect**: `DiscordIPC` polls the socket path and reconnects automatically if Discord is restarted.

---

### iTunesArtworkFetcher.swift

Fetches album artwork URLs from the iTunes Search API:
```
https://itunes.apple.com/search?term={track}+{artist}&entity=song&limit=5
```

Returns a `600x600bb.jpg` URL from MZStatic CDN. These are public, stable URLs that work as Discord `largeImageURL` values and are converted to `mp:external/...` by Discord's proxy. Results are not cached between tracks (a fresh fetch runs per track change, with the URL cached in `RichPresenceManager.lastArtworkURL` for position updates on the same track).

---

### AppIconRenderer.swift

Renders the app icon entirely in code using `CGContext` — no image assets.

**Design**: Pink gradient rounded square with a white SF Symbol music note.

**Rendering approach**:
1. Create a grayscale `CGContext` mask with a white rounded rect on black background
2. Apply mask to main context via `ctx.clip(to: rect, mask: maskImage)` BEFORE drawing
3. Draw pink gradient (`drawLinearGradient` with `.drawsBeforeStartLocation` + `.drawsAfterEndLocation`)
4. Draw gloss overlay
5. Render SF Symbol `"music.note"` into a separate context, composite over

**Key gotcha**: `destinationIn` blend mode (the alternative approach) does NOT work correctly — produces asymmetric corner transparency due to CGContext's bottom-left coordinate origin. The `clip(to:mask:)` approach is the correct one.

**`cachedIcon`**: Static property, rendered once at app launch at 1024×1024.

**`writeIconAssets(to:)`**: Generates all 10 PNG sizes for the asset catalog (16px through 1024px). Run via `ExecuteSnippet` when the renderer changes — do NOT run at app startup as it writes to the bundle.

---

### SettingsView.swift

SwiftUI view with three tabs: General, Display, About.

- Uses `@Bindable var manager: RichPresenceManager` for two-way bindings
- Styled with `ultraThinMaterial` background + glass effects (`GlassEffect` / `.glassEffect()`)
- Window is 480×540, managed by `SettingsWindowController`

**Display tab cards:**
- **Images**: Large image picker (album art / Apple Music icon / none), Small image picker
- **Text**: Show artist name toggle, Show track number toggle
- **Activity Type**: "Listening to" toggle
- **Timestamps**: Show progress bar toggle

**General tab:**
- Rich Presence enable/disable
- Hide when paused toggle
- Launch at login toggle (`SMAppService.mainApp`)
- Discord Client ID edit field

---

### OnboardingView.swift

First-launch splash screen shown once.

**`OnboardingWindowController`** — singleton `NSWindowController + NSWindowDelegate`:
- 480×620 window with `hiddenTitleBar` + `fullSizeContentView`
- `show()`: sets `hasLaunchedBefore = true` immediately (so restarts don't re-show), then activates
- `windowWillClose()`: reverts `NSApp.setActivationPolicy(.accessory)`

**`OnboardingView`**: ultraThinMaterial background, app icon (96×96 with `clipShape(RoundedRectangle(cornerRadius: 25))` to cleanly clip anti-aliased edges), title, 4 feature rows, permission note, "Get Started" button.

---

## Key Decisions & Gotchas

### Menu bar app + Dock visibility
- `LSUIElement = true` hides from Dock permanently
- To show Dock icon temporarily (settings/onboarding): `NSApp.setActivationPolicy(.regular)` before showing window, `.accessory` after closing
- Must call `window.orderFrontRegardless()` + `makeKeyAndOrderFront(nil)` — neither alone is sufficient for reliable foreground focus

### Apple Events permission
- Without `com.apple.security.automation.apple-events` entitlement, `fetchDuration` silently fails with error -1743
- This breaks the progress bar entirely since `duration` and `position` stay nil

### Progress bar (type 2 specific)
- Discord's "Listening to" (type 2) renders a song progress bar when both `start` and `end` timestamps are set
- `largeImageText` for type 2 MUST be the album name — changing it (e.g. to track number) causes Discord to drop the progress bar
- Workaround: for type 2, keep `largeImageText = album name` and put track number in `state` field instead

### App icon rendering
- `NSBitmapImageRep(cgImage:)` correctly reads at pixel size without Retina doubling
- `lockFocus` on `NSImage` renders at screen scale (2x on Retina) — don't use for fixed-pixel PNGs
- Asset catalog PNGs must be exact pixel sizes (16, 32, 64, 128, 256, 512, 1024)

### UserDefaults in sandboxed app
- Archived/distributed app uses container: `~/Library/Containers/danielmorgan.MacAMRP/Data/Library/Preferences/`
- Cannot `rm` these files even with sudo — must use `UserDefaults.standard.removeObject(forKey:)` in code or reset via System Settings

### @Observable + settings
- Settings properties must be stored properties with `didSet` (not computed) for `@Bindable` two-way bindings to work
- Computed properties backed by UserDefaults do not trigger SwiftUI observation

### Discord small image URLs
- External URLs (Wikipedia, etc.) only show on the local Mac client
- For cross-device/cross-user visibility: upload image as an asset in Discord Developer Portal → Rich Presence → Art Assets, use the key name string

---

## Discord Developer Portal Setup

Application ID: `1483608868809605140`

Required asset uploaded:
- Key: `applemusic` — Apple Music icon (used as small image)

No OAuth required. Rich Presence type 2 ("Listening to") works via plain IPC.

---

## Build & Distribution

No App Store. Personal use only.

**Build**: Product → Archive in Xcode
**Distribute**: Right-click archive in Organiser → Show in Finder → reveal `.app` inside → drag to `/Applications`

Requires macOS 13+ (uses `SMAppService`, `@Observable`, SwiftUI `.onChange(of:initial:)`).
