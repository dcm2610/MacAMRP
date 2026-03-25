//
//  MacAMRPApp.swift
//  MacAMRP
//
//  Created by Dan Morgan on 17/03/2026.
//

import SwiftUI

@main
struct MacAMRPApp: App {
    @State private var manager = RichPresenceManager()

    var body: some Scene {
        // Menu bar icon + dropdown menu
        MenuBarExtra {
            MenuBarView()
                .environment(manager)
        } label: {
            Image(systemName: "music.note")
        }
        .menuBarExtraStyle(.menu)

        // Settings window - opened via "Settings..." menu item
        Settings {
            SettingsView()
                .environment(manager)
        }
    }

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.enabled: true,
            SettingsKey.showAlbumArt: true,
            SettingsKey.showTimestamp: true,
            SettingsKey.showArtistInState: true
        ])
    }
}
