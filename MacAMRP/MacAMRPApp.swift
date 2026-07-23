//
//  MacAMRPApp.swift
//  MacAMRP
//
//  Created by Dan Morgan on 17/03/2026.
//

import SwiftUI
import AppKit

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
        .onChange(of: true, initial: true) {
            if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
                // Small delay so NSApp is fully ready before presenting the window
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    OnboardingWindowController.shared.show(manager: manager)
                }
            }
        }

        // Settings window is managed by SettingsWindowController (see ContentView.swift)
    }

}
