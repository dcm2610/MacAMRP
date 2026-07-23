//
//  MusicObserver.swift
//  MacAMRP
//
//  Hybrid approach:
//  - com.apple.Music.playerInfo distributed notifications detect track/state changes
//    (reliable on all macOS versions including 26/27)
//  - MRMediaRemoteGetNowPlayingInfo supplies position and duration when the
//    notification fires, bypassing the macOS 26/27 AppleScript bug entirely.
//

import Foundation

// MARK: - Track Info

struct TrackInfo: Equatable {
    let name: String
    let artist: String
    let album: String
    let duration: TimeInterval?
    let playerPosition: TimeInterval?
    let playbackState: PlaybackState

    enum PlaybackState {
        case playing, paused, stopped
    }

    var isPlaying: Bool { playbackState == .playing }
}

// MARK: - MediaRemote Types (private framework, loaded dynamically)

private typealias MRGetNowPlayingInfoFn        = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
private typealias MRRegisterForNotificationsFn = @convention(c) (DispatchQueue) -> Void

private enum MRKey {
    static let title        = "kMRMediaRemoteNowPlayingInfoTitle"
    static let artist       = "kMRMediaRemoteNowPlayingInfoArtist"
    static let album        = "kMRMediaRemoteNowPlayingInfoAlbum"
    static let duration     = "kMRMediaRemoteNowPlayingInfoDuration"
    static let elapsedTime  = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    static let timestamp    = "kMRMediaRemoteNowPlayingInfoTimestamp"
    static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
}

// MARK: - MusicObserver

final class MusicObserver {
    var onTrackChange: ((TrackInfo?) -> Void)?
    private(set) var currentTrack: TrackInfo?

    // MediaRemote
    private var mrHandle: UnsafeMutableRawPointer?
    private var mrGetNowPlayingInfo: MRGetNowPlayingInfoFn?
    private var mrRegisterForNotifications: MRRegisterForNotificationsFn?

    // Distributed notification observer
    private var distributedObserver: NSObjectProtocol?

    // Seek detection — polls MediaRemote every 5 s while playing to catch user seeks
    private var seekPollTimer: Timer?
    private var lastUpdateDate: Date = Date()

    init() {}
    deinit { stop() }

    // MARK: - Lifecycle

    func start() {
        loadMediaRemote()
        // Register for push notifications if available (bonus; not relied upon)
        mrRegisterForNotifications?(DispatchQueue.main)
        registerDistributedNotifications()
        // Fetch current state immediately so we don't wait for a track change
        fetchNowPlayingInfo()
    }

    func stop() {
        stopSeekPolling()
        if let obs = distributedObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            distributedObserver = nil
        }
    }

    func repoll() {
        fetchNowPlayingInfo()
    }

    // MARK: - MediaRemote Loading

    private func loadMediaRemote() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        mrHandle = dlopen(path, RTLD_NOW)
        guard mrHandle != nil else {
            print("[MusicObserver] MediaRemote.framework not available")
            return
        }
        if let s = dlsym(mrHandle, "MRMediaRemoteGetNowPlayingInfo") {
            mrGetNowPlayingInfo = unsafeBitCast(s, to: MRGetNowPlayingInfoFn.self)
        }
        if let s = dlsym(mrHandle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            mrRegisterForNotifications = unsafeBitCast(s, to: MRRegisterForNotificationsFn.self)
        }
        print("[MusicObserver] MediaRemote loaded — getNowPlayingInfo=\(mrGetNowPlayingInfo != nil)")
    }

    // MARK: - Distributed Notifications (track change detection)

    private func registerDistributedNotifications() {
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleMusicNotification(notification)
        }
        print("[MusicObserver] Listening for com.apple.Music.playerInfo notifications")
    }

    private func handleMusicNotification(_ notification: Notification) {
        let state = notification.userInfo?["Player State"] as? String ?? ""
        print("[MusicObserver] playerInfo notification: state=\(state)")

        if state == "Stopped" {
            updateTrack(nil)
            return
        }
        // Parse the notification immediately so Discord sees the new track right away
        // and we have duration (Total Time) stored in currentTrack before MediaRemote
        // responds — MediaRemote omits duration for streaming tracks on macOS 26/27.
        parseNotificationFallback(notification)
        // Then enrich with MediaRemote's accurate position (bypasses the AppleScript bug).
        fetchNowPlayingInfo(fallbackNotification: notification)
    }

    // MARK: - MediaRemote Info Fetch

    private func fetchNowPlayingInfo(fallbackNotification: Notification? = nil) {
        guard let getInfo = mrGetNowPlayingInfo else {
            // MediaRemote not available — use notification data as best-effort
            if let notification = fallbackNotification {
                parseNotificationFallback(notification)
            }
            return
        }

        getInfo(DispatchQueue.main) { [weak self] info in
            self?.parseMediaRemoteInfo(info, fallbackNotification: fallbackNotification)
        }
    }

    private func parseMediaRemoteInfo(_ info: [String: Any], fallbackNotification: Notification?) {
        // If MediaRemote returns no title, use the notification as fallback
        guard let name = info[MRKey.title] as? String, !name.isEmpty else {
            if let notification = fallbackNotification {
                parseNotificationFallback(notification)
            } else {
                updateTrack(nil)
            }
            return
        }

        let artist   = info[MRKey.artist]   as? String       ?? ""
        let album    = info[MRKey.album]    as? String       ?? ""
        let elapsed  = info[MRKey.elapsedTime]  as? TimeInterval ?? 0
        let mrTime   = info[MRKey.timestamp]    as? Date        ?? Date()
        let rate     = info[MRKey.playbackRate] as? Double      ?? 0

        // Current position = elapsed at reference timestamp, advanced by real time × rate.
        let position = max(0, elapsed + Date().timeIntervalSince(mrTime) * rate)
        let state: TrackInfo.PlaybackState = rate > 0 ? .playing : .paused

        // Duration: MediaRemote omits this for streaming tracks on macOS 26/27.
        // Fall back to the notification's Total Time (already parsed into currentTrack),
        // or carry it forward if the same track is still playing.
        let duration: TimeInterval? = info[MRKey.duration] as? TimeInterval
            ?? (currentTrack?.name == name ? currentTrack?.duration : nil)
            ?? (fallbackNotification?.userInfo?["Total Time"] as? TimeInterval).map { $0 / 1000 }

        print("[MusicObserver] MediaRemote: \(name) pos=\(String(format: "%.1f", position))s dur=\(duration.map { String(format: "%.1f", $0) } ?? "nil")s rate=\(rate)")

        let track = TrackInfo(
            name: name, artist: artist, album: album,
            duration: duration, playerPosition: position,
            playbackState: state
        )
        lastUpdateDate = Date()
        updateTrack(track)
    }

    // Fallback when MediaRemote is unavailable — use the notification's values directly
    private func parseNotificationFallback(_ notification: Notification) {
        guard let info = notification.userInfo,
              let name = info["Name"] as? String, !name.isEmpty else {
            updateTrack(nil)
            return
        }
        let artist    = info["Artist"] as? String ?? ""
        let album     = info["Album"]  as? String ?? ""
        let durationMs = info["Total Time"] as? TimeInterval
        let position  = info["Player Position"] as? TimeInterval
        let stateStr  = info["Player State"] as? String ?? ""
        let state: TrackInfo.PlaybackState = stateStr == "Playing" ? .playing : .paused

        let track = TrackInfo(
            name: name, artist: artist, album: album,
            duration: durationMs.map { $0 / 1000 },
            playerPosition: position,
            playbackState: state
        )
        lastUpdateDate = Date()
        updateTrack(track)
    }

    // MARK: - Player Position (AppleScript fallback)

    // MRMediaRemoteGetNowPlayingInfo is locked behind a private entitlement on macOS 27 Beta
    // and returns an empty dict. We fall back to `player position` via AppleScript — this is
    // an application-level property (not `current track`) so it is NOT affected by the
    // macOS 26/27 streaming track bug and works reliably.

    /// Polls `player position` via AppleScript and updates currentTrack if it has no position yet.
    private func pollPlayerPosition() {
        guard let current = currentTrack, current.isPlaying,
              current.playerPosition == nil else { return }
        queryPlayerPosition { [weak self] actual in
            guard let self, let current = self.currentTrack,
                  current.isPlaying, current.playerPosition == nil else { return }
            let updated = TrackInfo(
                name: current.name, artist: current.artist, album: current.album,
                duration: current.duration, playerPosition: actual,
                playbackState: current.playbackState
            )
            self.lastUpdateDate = Date()
            self.updateTrack(updated)
        }
    }

    /// Runs the lightweight `player position` AppleScript (app-level, not current track).
    private func queryPlayerPosition(completion: @escaping (TimeInterval) -> Void) {
        let script = """
        tell application "Music"
            if player state is playing then
                return player position as string
            end if
            return "-1"
        end tell
        """
        DispatchQueue.global(qos: .utility).async {
            var error: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else { return }
            let result = appleScript.executeAndReturnError(&error)
            guard error == nil,
                  let posStr = result.stringValue,
                  let pos = TimeInterval(posStr), pos >= 0 else { return }
            DispatchQueue.main.async { completion(pos) }
        }
    }

    // MARK: - Seek Detection

    private func startSeekPolling() {
        stopSeekPolling()
        seekPollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkForSeek()
        }
    }

    private func stopSeekPolling() {
        seekPollTimer?.invalidate()
        seekPollTimer = nil
    }

    private func checkForSeek() {
        guard let current = currentTrack, current.isPlaying else { return }

        guard let knownPos = current.playerPosition else {
            pollPlayerPosition()
            return
        }

        let expectedPos = knownPos + Date().timeIntervalSince(lastUpdateDate)
        queryPlayerPosition { [weak self] actual in
            guard let self, let current = self.currentTrack, current.isPlaying,
                  abs(actual - expectedPos) > 5.0 else { return }
            print("[MusicObserver] Seek detected — expected \(String(format: "%.1f", expectedPos))s got \(String(format: "%.1f", actual))s")
            let updated = TrackInfo(
                name: current.name, artist: current.artist, album: current.album,
                duration: current.duration, playerPosition: actual,
                playbackState: current.playbackState
            )
            self.lastUpdateDate = Date()
            self.updateTrack(updated)
        }
    }

    // MARK: - Track Update

    private func updateTrack(_ track: TrackInfo?) {
        guard track != currentTrack else { return }
        currentTrack = track
        lastUpdateDate = Date()
        onTrackChange?(track)

        if track?.isPlaying == true {
            startSeekPolling()
            // If we have no position yet (MediaRemote locked, notification omitted it),
            // immediately poll via AppleScript which is reliable on macOS 27.
            if track?.playerPosition == nil {
                pollPlayerPosition()
            }
        } else {
            stopSeekPolling()
        }
    }
}
