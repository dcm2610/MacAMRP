//
//  MenuBarView.swift
//  MacAMRP
//
//  SwiftUI view that populates the MenuBarExtra dropdown menu.
//

import SwiftUI
import AppKit

// Manages the settings window lifecycle, including Dock icon visibility.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var manager: RichPresenceManager?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func open(manager: RichPresenceManager) {
        self.manager = manager

        guard let window else { return }

        // Set our custom icon
        NSApp.applicationIconImage = AppIconRenderer.cachedIcon

        if !(window.contentViewController is NSHostingController<SettingsView>) {
            window.contentViewController = NSHostingController(rootView: SettingsView(manager: manager))
        }

        // Switch to regular activation policy so the app appears in the Dock,
        // then immediately bring the window to front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Return to accessory (menu-bar-only) mode when settings is closed
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarView: View {
    @Environment(RichPresenceManager.self) private var manager

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

        // Discord connection status — use palette-coloured symbol since
        // .foregroundStyle() is stripped by macOS in menu bar items.
        Label {
            Text(manager.isDiscordConnected ? "Connected to Discord" : "Discord not connected")
        } icon: {
            Image(systemName: manager.isDiscordConnected ? "circle.fill" : "circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(manager.isDiscordConnected ? Color.green : Color.secondary)
        }
        .disabled(true)

        Divider()

        Button(manager.isEnabled ? "Disable Rich Presence" : "Enable Rich Presence") {
            manager.isEnabled.toggle()
        }

        Divider()

        Button("Settings...") {
            SettingsWindowController.shared.open(manager: manager)
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit MacAMRP") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
