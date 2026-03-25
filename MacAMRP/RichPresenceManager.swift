//
//  RichPresenceManager.swift
//  MacAMRP
//
//  Orchestrates Music.app observation -> iTunes artwork fetch -> Discord IPC update.
//

import Foundation
import Observation

// MARK: - Settings Keys

enum SettingsKey {
    static let discordClientID = "discordClientID"
    static let showAlbumArt = "showAlbumArt"
    static let showTimestamp = "showTimestamp"
    static let showArtistInState = "showArtistInState"
    static let enabled = "richPresenceEnabled"
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

    init() {
        let clientID = UserDefaults.standard.string(forKey: SettingsKey.discordClientID)
            ?? defaultClientID
        discord = DiscordIPC(clientID: clientID)

        discord.onConnectionStateChange = { [weak self] connected in
            self?.isDiscordConnected = connected
            if connected, let track = self?.currentTrack {
                // Re-send presence after reconnect
                self?.updatePresence(for: track)
            } else if !connected {
                // Will auto-reconnect via DiscordIPC's timer
            }
        }

        musicObserver.onTrackChange = { [weak self] track in
            self?.currentTrack = track
            self?.handleTrackChange(track)
        }
    }

    // MARK: - Lifecycle

    func start() {
        discord.connect()
        musicObserver.start()
    }

    func stop() {
        artworkTask?.cancel()
        discord.disconnect()
        musicObserver.stop()
    }

    // MARK: - Settings

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKey.enabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.enabled)
            if newValue {
                if let track = currentTrack { updatePresence(for: track) }
            } else {
                discord.clearActivity()
            }
        }
    }

    var showAlbumArt: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKey.showAlbumArt) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.showAlbumArt) }
    }

    var showTimestamp: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKey.showTimestamp) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.showTimestamp) }
    }

    var showArtistInState: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKey.showArtistInState) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.showArtistInState) }
    }

    var discordClientID: String {
        get { UserDefaults.standard.string(forKey: SettingsKey.discordClientID) ?? defaultClientID }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.discordClientID)
            // Reconnect with new client ID
            discord.disconnect()
            discord.connect()
        }
    }

    // MARK: - Track Handling

    private func handleTrackChange(_ track: TrackInfo?) {
        artworkTask?.cancel()

        guard let track else {
            discord.clearActivity()
            return
        }

        guard isEnabled else { return }

        if showAlbumArt {
            artworkTask = Task { [weak self] in
                guard let self else { return }
                let artURL = await artworkFetcher.fetchArtworkURL(
                    track: track.name,
                    artist: track.artist,
                    album: track.album
                )
                guard !Task.isCancelled else { return }
                updatePresence(for: track, artworkURL: artURL)
            }
        } else {
            updatePresence(for: track, artworkURL: nil)
        }
    }

    private func updatePresence(for track: TrackInfo, artworkURL: String? = nil) {
        guard isEnabled else { return }

        var activity = DiscordActivity()

        // Details = track name (top line)
        activity.details = track.name.truncated(to: 128)

        // State = artist name (bottom line) if enabled
        if showArtistInState && !track.artist.isEmpty {
            activity.state = track.artist.truncated(to: 128)
        }

        // Album art
        if showAlbumArt, let url = artworkURL {
            activity.largeImageURL = url
            activity.largeImageText = track.album.isEmpty ? track.name : track.album
        }

        // Timestamps - only when playing
        if showTimestamp && track.isPlaying {
            let now = Date()
            if let position = track.playerPosition {
                // Track started `position` seconds ago
                activity.startTimestamp = now.addingTimeInterval(-position)

                // If we know the duration, also set end time
                if let duration = track.duration {
                    let remaining = duration - position
                    activity.endTimestamp = now.addingTimeInterval(remaining)
                }
            } else {
                activity.startTimestamp = now
            }
        }

        discord.setActivity(activity)
    }
}

// MARK: - Helpers

private let defaultClientID = "1351623959388893234"

private extension String {
    func truncated(to length: Int) -> String {
        count <= length ? self : String(prefix(length - 1)) + "…"
    }
}
