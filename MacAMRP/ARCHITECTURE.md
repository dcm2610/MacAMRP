# MacAMRP — Technical Architecture Reference

This document is a complete technical reference for the MacAMRP codebase. It covers every component, how they connect, and the key decisions and gotchas discovered during development — including hard-won findings about macOS 26/27 platform limitations.

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
│   ├── MusicObserver.swift        # Apple Music observation (notifications + MediaRemote + AppleScript)
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
    │  com.apple.Music.playerInfo (DistributedNotificationCenter)
    │  → immediate: name, artist, album, state, Total Time (duration in ms)
    │  → Player Position omitted on macOS 26/27 for streaming tracks
    ▼
MusicObserver
    │  ① parseNotificationFallback — instant update with notification data
    │  ② MRMediaRemoteGetNowPlayingInfo — attempt accurate position/duration
    │     (returns empty dict on macOS 27 Beta — Operation not permitted, Code=3)
    │  ③ queryPlayerPosition (AppleScript app-level) — reliable position fallback
    │     `player position` is NOT affected by the macOS 26/27 current track bug
    │
    │ onTrackChange: TrackInfo?
    ▼
RichPresenceManager
    │  ├── iTunesArtworkFetcher (async, iTunes Search API → MZStatic CDN URL)
    │  └── builds DiscordActivity → discord.setActivity
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
| `artistAsPresenceName` | `artistAsPresenceName` | `false` | Sets `activity.name` to artist — Discord shows "Listening to [Artist]" |
| `useListeningType` | `useListeningType` | `false` | Activity type 2 vs 0 |
| `hideWhenPaused` | `pauseBehaviour` | `false` | Clears presence when paused |
| `discordClientID` | `discordClientID` | `"1483608868809605140"` | Custom app ID |
| `launchAtLogin` | — | — | `SMAppService.mainApp`, not UserDefaults |

**Track flow:**
1. `MusicObserver.onTrackChange` fires → `handleTrackChange(track)`
2. Artwork cache check: if same track and URL cached → `updatePresence` directly
3. Otherwise: start async `iTunesArtworkFetcher` task, send immediate update with fallback icon, send full update when artwork arrives
4. `updatePresence(for:artworkURL:)` builds `DiscordActivity` and calls `discord.setActivity`

**Presence layout:**
- `details` = track name (line 1)
- `state` = artist name, or `"Artist · Paused"` when paused
- `largeImageText` = album name
- `smallImageText` = `"Apple Music"`
- `activity.name` = artist name (when `artistAsPresenceName` enabled) — overrides the Discord app name in the "Listening to" line

**Timestamp anchoring:**

`lastPositionDate` records the wall-clock time when `playerPosition` was captured. Discord's progress bar is then anchored as:
```
trackStart = lastPositionDate − playerPosition
endTimestamp = trackStart + duration
```
This stays accurate even if `updatePresence` is called seconds after position was captured (e.g. after artwork fetch), because `trackStart` is a fixed point in time.

---

### MusicObserver.swift

**`TrackInfo` struct:**
```swift
struct TrackInfo: Equatable {
    let name: String
    let artist: String
    let album: String
    let duration: TimeInterval?      // seconds; nil for streams where unavailable
    let playerPosition: TimeInterval? // current position in seconds
    let playbackState: PlaybackState  // .playing / .paused / .stopped
}
```

**Three-layer data acquisition (in order):**

#### Layer 1 — `com.apple.Music.playerInfo` distributed notification

Fires on play, pause, stop, and track change. Provides: `Name`, `Artist`, `Album`, `Player State`, `Total Time` (milliseconds — divide by 1000). `Player Position` is included for local/library tracks but **omitted on macOS 26/27 for streaming tracks**.

Called `com.apple.Music.playerInfo` (not the old `iTunes` name) since macOS Catalina.

This layer fires `onTrackChange` immediately so Discord sees the new track with no delay.

#### Layer 2 — `MRMediaRemoteGetNowPlayingInfo` (MediaRemote private framework)

Loaded dynamically via `dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)`. Provides `kMRMediaRemoteNowPlayingInfoElapsedTime` + `kMRMediaRemoteNowPlayingInfoTimestamp` + `kMRMediaRemoteNowPlayingInfoPlaybackRate`, allowing accurate position calculation:

```swift
position = elapsed + Date().timeIntervalSince(mrTimestamp) * playbackRate
```

**⚠️ macOS 27 Beta limitation:** `MRMediaRemoteGetNowPlayingInfo` returns an empty dict with `kMRMediaRemoteFrameworkErrorDomain Code=3 "Operation not permitted"`. This API is gated behind a private entitlement not available to third-party apps on macOS 27 Beta. The callback fires but delivers no data. When this happens, the code falls through to Layer 3.

`MRMediaRemoteRegisterForNowPlayingNotifications` is called as a bonus — if MediaRemote notifications ever become available, they'd trigger `fetchNowPlayingInfo`. Note: MediaRemote notification **constant names** (e.g. `kMRMediaRemoteNowPlayingInfoDidChangeNotification`) are NOT the same as their string values — attempting to register for them by name string doesn't work.

#### Layer 3 — `player position` via AppleScript

The reliable fallback when both layers above fail to provide position:

```applescript
tell application "Music"
    if player state is playing then
        return player position as string
    end if
    return "-1"
end tell
```

**Why this works when other AppleScript fails:** `player position` is an **application-level property** of Music.app, not a property of `current track`. The macOS 26/27 AppleScript bug is specific to `current track` property access on streaming tracks (error -1728 "Can't get"). Application-level properties are unaffected.

Called immediately via `pollPlayerPosition()` when `updateTrack` receives a track with `playerPosition == nil`. Also used by `checkForSeek()` every 5 seconds to detect user seeks.

**Duration fallback chain:**
1. MediaRemote `kMRMediaRemoteNowPlayingInfoDuration` (omitted for streaming on macOS 26/27)
2. `currentTrack?.duration` carry-forward (set from the notification's `Total Time`)
3. Notification `Total Time` / 1000 directly

**Pause/unpause carry-forward:**

On pause and unpause, `parseNotificationFallback` carries forward `duration` and `playerPosition` from `currentTrack` when it's the same track (`isSameTrack` check by name). This prevents the progress bar from disappearing between state transitions while the position poll is in flight.

---

### DiscordIPC.swift

Communicates with the Discord desktop client over a local Unix domain socket.

**Socket path**: Tries `discord-ipc-0` through `discord-ipc-9` under the system temp directory (`$TMPDIR` / `$TMP` / `$TEMP` / `/tmp`).

**Protocol**:
- Each message is a frame: `[opcode: UInt32 LE][length: UInt32 LE][json payload: UTF-8]`
- Opcodes: 0 = handshake, 1 = frame, 2 = close, 3 = ping, 4 = pong

**Connection flow**:
1. Connect to Unix socket
2. Send opcode 0 handshake: `{"v": 1, "client_id": "..."}`
3. Receive opcode 1 READY response → `isConnected = true`
4. Send `SET_ACTIVITY` commands as opcode 1 frames
5. Persistent read loop on a dedicated thread (not `queue`) so `sendFrame` can continue to run on `queue` without deadlock

**`DiscordActivity` struct** (built by `RichPresenceManager`):
```swift
var activityType: Int           // 0 = Playing, 2 = Listening to
var name: String?               // Overrides app name (e.g. "Listening to [Artist]")
var details: String?            // Line 1 (track name)
var state: String?              // Line 2 (artist)
var largeImageURL: String?      // Asset key or external HTTPS URL
var largeImageText: String?     // Tooltip / third line (album name)
var smallImageURL: String?      // Asset key or external HTTPS URL
var smallImageText: String?     // Tooltip on small image
var startTimestamp: Date?       // Progress bar start
var endTimestamp: Date?         // Progress bar end (required for countdown)
var buttons: [...]?
```

**`name` field behaviour:** Discord accepts the `name` field in the `SET_ACTIVITY` payload and uses it to override the application name shown in the presence (e.g. "Listening to Radiohead" instead of "Listening to MacAMRP"). This works as of the current Discord client.

**Progress bar:** Requires BOTH `startTimestamp` AND `endTimestamp`. Discord proxies external image URLs through `mp:external/...` CDN.

**Activity type 2:** "Listening to" — works via plain IPC without OAuth since mid-2024.

**Auto-reconnect:** Schedules a 5-second timer and retries if the socket disconnects.

---

### iTunesArtworkFetcher.swift

Fetches album artwork URLs from the iTunes Search API. Results cached in-memory per album key.

**Three-strategy search (in order):**

1. **Direct catalog lookup** by album ID extracted from `storeURL`: `itunes.apple.com/lookup?id={albumID}&entity=album`. Album ID is the last numeric path component of an Apple Music URL (`music.apple.com/us/album/name/{id}?i={trackID}`). Takes the first result directly since the ID is an exact match.

2. **Album text search**: `itunes.apple.com/search?term={artist}+{album}&entity=album`. Results scored by album name + artist name match. **Requires a positive score** — no blind first-result fallback. Returning the wrong album (e.g. a Bill Withers compilation when searching for an OK Go album) is worse than returning nothing.

3. **Song text search**: `itunes.apple.com/search?term={artist}+{track}&entity=song`. Requires both track name and artist to match. No fallback to first result.

**Scoring (`pickAlbumArtwork`):**
- Exact album name match: +4
- Album name contains query (or vice versa): +1–2
- Artist name contains query (or vice versa): +2
- Score ≤ 0: skip result (don't use)

**`fetchArtistImageURL`**: separate method for artist image lookup, used optionally.

---

### AppIconRenderer.swift

Renders the app icon entirely in code using `CGContext` — no image assets needed at runtime.

**Design**: Pink gradient rounded square with a white SF Symbol music note.

**Rendering approach**:
1. Create a grayscale `CGContext` mask with a white rounded rect on black background
2. Apply mask to main context via `ctx.clip(to: rect, mask: maskImage)` BEFORE drawing
3. Draw pink gradient (`drawLinearGradient` with `.drawsBeforeStartLocation` + `.drawsAfterEndLocation`)
4. Draw gloss overlay
5. Render SF Symbol `"music.note"` into a separate context, composite over

**Key gotcha**: `destinationIn` blend mode does NOT work correctly — produces asymmetric corner transparency due to CGContext's bottom-left coordinate origin. The `clip(to:mask:)` approach is correct.

**`cachedIcon`**: Static property, rendered once at app launch at 1024×1024.

**`writeIconAssets(to:)`**: Generates all 10 PNG sizes for the asset catalog. Run manually when the renderer changes — do NOT run at app startup.

---

### SettingsView.swift

SwiftUI view with three tabs: General, Display, About.

- Uses `@Bindable var manager: RichPresenceManager` for two-way bindings
- Styled with `ultraThinMaterial` background + Liquid Glass effects (`.glassEffect()`, `GlassEffectContainer`)
- Window is 480×540, managed by `SettingsWindowController`

**Display tab cards:**
- **Images**: Large image picker (album art / Apple Music icon / none), Small image picker
- **Text**: Show artist name toggle
- **Activity Type**: "Listening to" toggle, "Show artist as presence name" toggle
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

---

## Key Decisions & Gotchas

### macOS 26/27 Tahoe — AppleScript `current track` Regression

**Apple bug FB19908171.** Introduced in macOS 26.0, present through macOS 27 Beta 4+.

`current track` property access in Music.app's AppleScript dictionary throws **error -1728 ("Can't get")** for any track playing via Apple Music streaming that hasn't been explicitly added to the local library. Affected properties include:
- `duration of current track`
- `name of current track`
- `track number of current track`
- `track count of current track`
- `store URL of current track`

**Unaffected (application-level properties):**
- `player position` — works reliably for all track types
- `player state` — works reliably
- `current playlist` — generally works (playlist-level, not track-level)

**Impact on MacAMRP:**
- Duration: obtained from `Total Time` in the distributed notification instead
- Position: obtained via `player position` AppleScript (app-level, unaffected)
- Store URL / track number: unavailable for streaming tracks; features depending on these have been removed

### macOS 27 Beta — MediaRemote Permission Lock

`MRMediaRemoteGetNowPlayingInfo` (private framework) returns `kMRMediaRemoteFrameworkErrorDomain Code=3 "Operation not permitted"` on macOS 27 Beta. The framework loads successfully via `dlopen` and symbols resolve, but the info callback delivers an empty dict. This API is gated behind a private entitlement not available to third-party apps.

MediaRemote **notification names** (e.g. `kMRMediaRemoteNowPlayingInfoDidChangeNotification`) cannot be used as raw strings — the exported `NSString*` constant values differ from the symbol names. Subscribing to `NotificationCenter.default` using the constant name as a literal string does not receive any events.

### Artwork Fetcher — No Blind First-Result Fallback

The earlier implementation of `pickAlbumArtwork` included `results.first` as a final fallback when no result scored positively. This caused visually wrong artwork (e.g. a Bill Withers compilation appearing for an OK Go album) because the iTunes Search API sometimes returns unrelated results first. The fallback was removed — a miss is better than a wrong result, and the song text search provides a separate fallback strategy.

### Menu Bar App + Dock Visibility

- `LSUIElement = true` hides from Dock permanently
- To show Dock icon temporarily: `NSApp.setActivationPolicy(.regular)` before showing window, `.accessory` after closing
- Must call `window.orderFrontRegardless()` + `makeKeyAndOrderFront(nil)` — neither alone is sufficient for reliable foreground focus

### Apple Events Permission

- `com.apple.security.automation.apple-events` entitlement required
- `NSAppleEventsUsageDescription` in Info.plist required
- Without these, AppleScript silently fails with error -1743

### `@Observable` + Settings

- Settings properties must be stored properties with `didSet` (not computed) for `@Bindable` two-way bindings to work
- Toggling a setting that doesn't call `updatePresence` in its `didSet` won't take effect until the next track change — all settings `didSet` blocks that affect the presence must call `updatePresence(for: currentTrack, artworkURL: lastArtworkURL)`

### Discord Small Image URLs

- External URLs only show on the local Mac client; other Discord users see nothing
- For cross-device visibility: upload image as an asset in the Discord Developer Portal → Rich Presence → Art Assets, use the key name string
- We use `"applemusic"` (pre-uploaded key) for the Apple Music icon

---

## Discord Developer Portal Setup

Application ID: `1483608868809605140`

Required assets uploaded:
- Key: `applemusic` — Apple Music icon (used as small image and large image fallback)

No OAuth required. Rich Presence type 2 ("Listening to") works via plain IPC.

---

## Build & Distribution

No App Store. Personal use / portfolio project.

**Build**: Product → Archive in Xcode  
**Distribute**: Right-click archive in Organiser → Show in Finder → reveal `.app` → drag to `/Applications`

Requires macOS 26+ (Liquid Glass APIs, macOS 27 Beta targeted).

**Version history:**
- `1.0` — initial release
- `1.1` — MediaRemote integration, macOS 26/27 resilience, artwork scorer fix, artist-as-presence-name
