//
//  RichPresenceManager.swift
//  MacAMRP
//
//  Orchestrates Music.app observation -> iTunes artwork fetch -> Discord IPC update.
//

import Foundation
import Observation
import ServiceManagement

// MARK: - Settings Keys

enum SettingsKey {
    static let discordClientID = "discordClientID"
    static let largeImageMode = "largeImageMode"  // "albumart", "applemusic", "none"
    static let showTimestamp = "showTimestamp"
    static let showArtistInState = "showArtistInState"
    static let enabled = "richPresenceEnabled"
    static let useListeningType = "useListeningType"
    static let pauseBehaviour = "pauseBehaviour"
    static let smallImageMode = "smallImageMode"  // "none", "artist"
    static let artistAsPresenceName = "artistAsPresenceName"
}

// MARK: - RichPresenceManager

@Observable
final class RichPresenceManager {
    // Connection state
    private(set) var isDiscordConnected = false
    private(set) var currentTrack: TrackInfo?

    // Dependencies
    private let discord: DiscordIPC
    private let musicObserver = MusicObserver()
    private let artworkFetcher = iTunesArtworkFetcher()

    // Artwork fetch task - cancel previous if track changes mid-fetch
    private var artworkTask: Task<Void, Never>?
    private var lastArtworkTrackName: String?
    private var lastArtworkURL: String?

    // Records when currentTrack.playerPosition was last captured so timestamps
    // can be anchored correctly even when updatePresence is called seconds later.
    private var lastPositionDate: Date = Date()



    init() {
        // Register defaults first so all reads below have correct fallback values
        UserDefaults.standard.register(defaults: [
            SettingsKey.enabled: true,
            SettingsKey.largeImageMode: "albumart",
            SettingsKey.showTimestamp: true,
            SettingsKey.showArtistInState: true,
            SettingsKey.useListeningType: false,
            SettingsKey.pauseBehaviour: false,
            SettingsKey.smallImageMode: "applemusic",
            SettingsKey.artistAsPresenceName: false
        ])

        let ud = UserDefaults.standard
        isEnabled        = ud.bool(forKey: SettingsKey.enabled)
        largeImageMode   = ud.string(forKey: SettingsKey.largeImageMode) ?? "albumart"
        showTimestamp    = ud.bool(forKey: SettingsKey.showTimestamp)
        showArtistInState = ud.bool(forKey: SettingsKey.showArtistInState)
        useListeningType = ud.bool(forKey: SettingsKey.useListeningType)
        hideWhenPaused   = ud.bool(forKey: SettingsKey.pauseBehaviour)
        smallImageMode   = ud.string(forKey: SettingsKey.smallImageMode) ?? "applemusic"
        artistAsPresenceName = ud.bool(forKey: SettingsKey.artistAsPresenceName)
        discordClientID      = ud.string(forKey: SettingsKey.discordClientID) ?? defaultClientID

        discord = DiscordIPC(clientID: ud.string(forKey: SettingsKey.discordClientID) ?? defaultClientID)

        discord.onConnectionStateChange = { [weak self] connected in
            self?.isDiscordConnected = connected
            if connected {
                // Give the music observer a moment to populate currentTrack,
                // then send whatever we have (or re-poll if still nil).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let self else { return }
                    if let track = self.currentTrack {
                        self.handleTrackChange(track)
                    } else {
                        // No track yet - force a re-poll
                        self.musicObserver.repoll()
                    }
                }
            }
        }

        musicObserver.onTrackChange = { [weak self] track in
            self?.currentTrack = track
            if track?.playerPosition != nil {
                self?.lastPositionDate = Date()
            }
            self?.handleTrackChange(track)
        }

        discord.connect()
        musicObserver.start()
    }

    func stop() {
        artworkTask?.cancel()
        discord.disconnect()
        musicObserver.stop()
    }

    // MARK: - Settings (stored properties for @Bindable support)

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: SettingsKey.enabled)
            if isEnabled {
                if let track = currentTrack { updatePresence(for: track) }
            } else {
                discord.clearActivity()
            }
        }
    }

    var largeImageMode: String {
        didSet {
            UserDefaults.standard.set(largeImageMode, forKey: SettingsKey.largeImageMode)
            if let track = currentTrack { handleTrackChange(track) }
        }
    }

    var showTimestamp: Bool {
        didSet {
            UserDefaults.standard.set(showTimestamp, forKey: SettingsKey.showTimestamp)
            if let track = currentTrack { updatePresence(for: track, artworkURL: lastArtworkURL) }
        }
    }

    var showArtistInState: Bool {
        didSet {
            UserDefaults.standard.set(showArtistInState, forKey: SettingsKey.showArtistInState)
            if let track = currentTrack { updatePresence(for: track, artworkURL: lastArtworkURL) }
        }
    }

    var useListeningType: Bool {
        didSet {
            UserDefaults.standard.set(useListeningType, forKey: SettingsKey.useListeningType)
            if let track = currentTrack { updatePresence(for: track) }
        }
    }

    var hideWhenPaused: Bool {
        didSet {
            UserDefaults.standard.set(hideWhenPaused, forKey: SettingsKey.pauseBehaviour)
            if let track = currentTrack { handleTrackChange(track) }
        }
    }

    var smallImageMode: String {
        didSet {
            UserDefaults.standard.set(smallImageMode, forKey: SettingsKey.smallImageMode)
            if let track = currentTrack { handleTrackChange(track) }
        }
    }

    var artistAsPresenceName: Bool {
        didSet {
            UserDefaults.standard.set(artistAsPresenceName, forKey: SettingsKey.artistAsPresenceName)
            if let track = currentTrack { updatePresence(for: track, artworkURL: lastArtworkURL) }
        }
    }

    /// Whether the app is registered as a login item. Backed by SMAppService, not UserDefaults.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[LaunchAtLogin] Failed: \(error)")
            }
        }
    }

    var discordClientID: String {
        didSet {
            UserDefaults.standard.set(discordClientID, forKey: SettingsKey.discordClientID)
            discord.disconnect()
            discord.connect()
        }
    }

    // MARK: - Track Handling

    private func handleTrackChange(_ track: TrackInfo?) {
        guard let track else {
            artworkTask?.cancel()
            artworkTask = nil
            lastArtworkTrackName = nil
            lastArtworkURL = nil
            print("[RichPresence] No track - clearing activity")
            discord.clearActivity()
            return
        }

        print("[RichPresence] handleTrackChange: \(track.name) by \(track.artist), position=\(track.playerPosition.map { String($0) } ?? "nil"), duration=\(track.duration.map { String($0) } ?? "nil")")

        guard isEnabled else { return }

        // Handle pause behaviour
        if !track.isPlaying && hideWhenPaused {
            discord.clearActivity()
            return
        }

        // If this is the same track and artwork is already cached, skip the fetch
        if largeImageMode == "albumart" && track.name == lastArtworkTrackName {
            updatePresence(for: track, artworkURL: lastArtworkURL)
            return
        }

        // New track - cancel any in-flight fetch and start a fresh one
        artworkTask?.cancel()
        artworkTask = nil

        if largeImageMode == "albumart" {
            lastArtworkTrackName = track.name
            lastArtworkURL = nil
            // Send an immediate update with the fallback icon so Discord shows the
            // new track (with bar near 0) straight away, rather than waiting 1-3 s
            // for fetchDuration + artwork to arrive.
            updatePresence(for: track, artworkURL: nil)
            artworkTask = Task { [weak self] in
                guard let self else { return }
                // Read storeURL from currentTrack at execution time — by the time the Swift
                // cooperative thread pool runs this task, fetchDuration has almost certainly
                // completed and populated currentTrack.storeURL for Apple Music tracks.
                let artURL = await artworkFetcher.fetchArtworkURL(
                    track: track.name, artist: track.artist, album: track.album
                )
                guard !Task.isCancelled else { return }
                guard let current = currentTrack, current.name == track.name else { return }
                lastArtworkURL = artURL
                updatePresence(for: current, artworkURL: artURL)
            }
        } else {
            updatePresence(for: track, artworkURL: nil)
        }
    }

    private func updatePresence(for track: TrackInfo, artworkURL: String? = nil) {
        print("[RichPresence] updatePresence called, isEnabled=\(isEnabled), isConnected=\(isDiscordConnected)")
        guard isEnabled else { return }

        var activity = DiscordActivity()
        activity.activityType = useListeningType ? 2 : 0

        // Override the app name with the artist so Discord shows e.g. "Listening to [Artist]"
        if artistAsPresenceName && !track.artist.isEmpty {
            activity.name = track.artist.truncated(to: 128)
        }

        // Details = track name (top line)
        activity.details = track.name.truncated(to: 128)

        // Album name used as large image tooltip and third line
        let albumText = track.album.isEmpty ? track.name : track.album

        // State = artist (second line)
        let pausedSuffix = track.isPlaying ? "" : " · Paused"
        if !track.isPlaying {
            activity.state = showArtistInState && !track.artist.isEmpty
                ? "\(track.artist.truncated(to: 120))\(pausedSuffix)"
                : "Paused"
        } else if showArtistInState && !track.artist.isEmpty {
            activity.state = track.artist.truncated(to: 128)
        }

        // Large image
        switch largeImageMode {
        case "albumart":
            activity.largeImageURL = artworkURL ?? appleMusicIconURL
            activity.largeImageText = albumText
        case "applemusic":
            activity.largeImageURL = appleMusicIconURL
            activity.largeImageText = albumText
        default:
            break
        }

        // Small image
        switch smallImageMode {
        case "applemusic":
            activity.smallImageURL = appleMusicIconURL
            activity.smallImageText = "Apple Music"
        default:
            break
        }

        // Timestamps - only when playing
        // We anchor startTimestamp to (lastPositionDate - position) rather than
        // (now - position).  This keeps the bar correct when updatePresence is
        // called seconds after the position was captured (e.g. after an artwork
        // fetch): the fixed trackStart is always "when the track was at position 0",
        // so Discord's live elapsed-time calculation is always accurate.
        if showTimestamp && track.isPlaying {
            if let position = track.playerPosition, let duration = track.duration {
                let trackStart = lastPositionDate.addingTimeInterval(-position)
                activity.startTimestamp = trackStart
                activity.endTimestamp = trackStart.addingTimeInterval(duration)
            } else if let position = track.playerPosition {
                // Have position but no duration - can only show elapsed
                activity.startTimestamp = lastPositionDate.addingTimeInterval(-position)
            }
            // else: no position data yet — fetchDuration will fire another update shortly
        }

        discord.setActivity(activity)
    }
}

// MARK: - Helpers

private let defaultClientID = "1483608868809605140"
private let appleMusicIconURL = "applemusic"

private extension String {
    func truncated(to length: Int) -> String {
        count <= length ? self : String(prefix(length - 1)) + "…"
    }
}
