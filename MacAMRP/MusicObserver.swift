//
//  MusicObserver.swift
//  MacAMRP
//
//  Observes the native Apple Music app via DistributedNotificationCenter.
//  Music.app posts "com.apple.iTunes.playerInfo" on play, pause, and track changes.
//  This approach works on macOS 26 Tahoe where ScriptingBridge's currentTrack is broken.
//

import Foundation

// MARK: - Track Info

struct TrackInfo: Equatable {
    let name: String
    let artist: String
    let album: String
    let duration: TimeInterval?    // seconds, may be absent for streaming tracks
    let playerPosition: TimeInterval? // current playback position in seconds
    let playbackState: PlaybackState

    enum PlaybackState {
        case playing
        case paused
        case stopped
    }

    var isPlaying: Bool { playbackState == .playing }
}

// MARK: - MusicObserver

/// Listens for Music.app distributed notifications and publishes track changes.
final class MusicObserver {
    /// Called on the main queue whenever playback state or track changes.
    var onTrackChange: ((TrackInfo?) -> Void)?

    private(set) var currentTrack: TrackInfo?
    private var observer: NSObjectProtocol?

    init() {}

    deinit {
        stop()
    }

    func start() {
        guard observer == nil else { return }

        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.iTunes.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleNotification(notification)
        }
    }

    func stop() {
        if let obs = observer {
            DistributedNotificationCenter.default().removeObserver(obs)
            observer = nil
        }
    }

    // MARK: - Notification Handling

    private func handleNotification(_ notification: Notification) {
        guard let info = notification.userInfo else {
            updateTrack(nil)
            return
        }

        let playerState = info["Player State"] as? String ?? ""

        switch playerState {
        case "Playing":
            let track = parseTrackInfo(from: info, state: .playing)
            updateTrack(track)

        case "Paused":
            // Keep the track info but update state to paused
            let track = parseTrackInfo(from: info, state: .paused)
            updateTrack(track)

        case "Stopped":
            updateTrack(nil)

        default:
            // Unknown state - try to parse anyway
            let track = parseTrackInfo(from: info, state: .playing)
            updateTrack(track)
        }
    }

    private func parseTrackInfo(from info: [AnyHashable: Any], state: TrackInfo.PlaybackState) -> TrackInfo? {
        // Name is required - if absent, treat as no track
        guard let name = info["Name"] as? String, !name.isEmpty else { return nil }

        let artist = info["Artist"] as? String ?? ""
        let album = info["Album"] as? String ?? ""
        let duration = info["Total Time"] as? TimeInterval  // milliseconds from notification
        let playerPosition = info["Player Position"] as? TimeInterval // seconds

        // Total Time in the notification is in milliseconds; convert to seconds
        let durationSeconds = duration.map { $0 / 1000.0 }

        return TrackInfo(
            name: name,
            artist: artist,
            album: album,
            duration: durationSeconds,
            playerPosition: playerPosition,
            playbackState: state
        )
    }

    private func updateTrack(_ track: TrackInfo?) {
        guard track != currentTrack else { return }
        currentTrack = track
        onTrackChange?(track)
    }
}
