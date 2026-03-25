//
//  MenuBarView.swift
//  MacAMRP
//
//  SwiftUI view that populates the MenuBarExtra dropdown menu.
//

import SwiftUI

struct MenuBarView: View {
    @Environment(RichPresenceManager.self) private var manager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Current track info (non-interactive)
        if let track = manager.currentTrack {
            let icon = track.isPlaying ? "▶" : "⏸"
            Text("\(icon) \(track.name)")
                .disabled(true)
            if !track.artist.isEmpty {
                Text(track.artist)
                    .foregroundStyle(.secondary)
                    .disabled(true)
            }
        } else {
            Text("Not playing")
                .foregroundStyle(.secondary)
                .disabled(true)
        }

        Divider()

        // Discord connection status
        Label(
            manager.isDiscordConnected ? "Connected to Discord" : "Discord not connected",
            systemImage: manager.isDiscordConnected ? "circle.fill" : "circle"
        )
        .foregroundStyle(manager.isDiscordConnected ? .green : .secondary)
        .disabled(true)

        Divider()

        Button(manager.isEnabled ? "Disable Rich Presence" : "Enable Rich Presence") {
            manager.isEnabled.toggle()
        }

        Divider()

        Button("Settings...") {
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit MacAMRP") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
