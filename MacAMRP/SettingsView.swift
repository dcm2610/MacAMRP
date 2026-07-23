//
//  SettingsView.swift
//  MacAMRP
//
//  Custom settings window with Liquid Glass styling.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var manager: RichPresenceManager
    @Environment(\.dismiss) private var dismiss

    @State private var clientIDInput: String = ""
    @State private var editingClientID = false
    @State private var selectedTab: SettingsTab = .general
    @Namespace private var tabNamespace

    var body: some View {

        ZStack {
            // Full-bleed vibrancy background — blurs and tints whatever is behind the window
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                header

                // Tab bar
                tabBar

                // Content
                ZStack {
                    switch selectedTab {
                    case .general:
                        generalTab
                    case .display:
                        displayTab
                    case .about:
                        aboutTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: selectedTab)
            }
        }
        .frame(width: 480, height: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .glassEffect(.regular.tint(.pink).interactive(), in: .rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Music Rich Presence")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Discord presence for Apple Music")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            // Connection pill
            statusPill
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(manager.isDiscordConnected ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(manager.isDiscordConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(in: .capsule)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(SettingsTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(4)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        Button {
            withAnimation(.spring(duration: 0.3)) {
                selectedTab = tab
            }
        } label: {
            Label(tab.title, systemImage: tab.icon)
                .font(.subheadline)
                .fontWeight(selectedTab == tab ? .semibold : .regular)
                .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(selectedTab == tab ? .regular.tint(.white.opacity(0.15)).interactive() : .regular.interactive(),
                     in: .capsule)
        .glassEffectID(tab.id, in: tabNamespace)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                settingsCard(title: "Rich Presence", icon: "antenna.radiowaves.left.and.right") {
                    settingsRow(
                        label: "Enable Rich Presence",
                        description: "Show your currently playing track on Discord"
                    ) {
                        Toggle("", isOn: $manager.isEnabled).labelsHidden()
                    }
                    settingsRow(
                        label: "Launch at login",
                        description: "Start MacAMRP automatically when you log in"
                    ) {
                        Toggle("", isOn: $manager.launchAtLogin).labelsHidden()
                    }
                }

                settingsCard(title: "When Paused", icon: "pause.circle") {
                    settingsRow(
                        label: "Hide presence when paused",
                        description: "When off, shows the track with a \"Paused\" indicator"
                    ) {
                        Toggle("", isOn: $manager.hideWhenPaused).labelsHidden()
                    }
                }

                settingsCard(title: "Discord Application", icon: "app.connected.to.app.below.fill") {
                    settingsRow(label: "Client ID", description: "Your Discord application ID") {
                        if editingClientID {
                            TextField("Client ID", text: $clientIDInput)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 180)
                                .onSubmit {
                                    if !clientIDInput.isEmpty {
                                        manager.discordClientID = clientIDInput
                                    }
                                    editingClientID = false
                                }
                        } else {
                            HStack(spacing: 8) {
                                Text(manager.discordClientID)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                                Button("Edit") {
                                    clientIDInput = manager.discordClientID
                                    editingClientID = true
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Display Tab

    private var displayTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                settingsCard(title: "Images", icon: "photo") {
                    settingsRow(
                        label: "Large image",
                        description: "Main image shown on the presence card"
                    ) {
                        Picker("", selection: $manager.largeImageMode) {
                            Text("Album art").tag("albumart")
                            Text("Apple Music icon").tag("applemusic")
                            Text("None").tag("none")
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    settingsRow(
                        label: "Small image",
                        description: "Corner pip shown on the presence card"
                    ) {
                        Picker("", selection: $manager.smallImageMode) {
                            Text("Apple Music icon").tag("applemusic")
                            Text("None").tag("none")
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }

                settingsCard(title: "Text", icon: "textformat") {
                    settingsRow(
                        label: "Show artist name",
                        description: "Display artist as the second line of your presence"
                    ) {
                        Toggle("", isOn: $manager.showArtistInState).labelsHidden()
                    }
                }

                settingsCard(title: "Activity Type", icon: "headphones") {
                    settingsRow(
                        label: "Show as \"Listening to\"",
                        description: "Show your presence as \"Listening to\" instead of \"Playing\""
                    ) {
                        Toggle("", isOn: $manager.useListeningType)
                            .labelsHidden()
                    }
                    settingsRow(
                        label: "Show artist as presence name",
                        description: "Replaces \"Apple Music\" with the artist name (e.g. \"Listening to Radiohead\")"
                    ) {
                        Toggle("", isOn: $manager.artistAsPresenceName)
                            .labelsHidden()
                    }
                }

                settingsCard(title: "Timestamps", icon: "timer") {
                    settingsRow(
                        label: "Show progress bar",
                        description: "Show a real-time progress bar on your presence"
                    ) {
                        Toggle("", isOn: $manager.showTimestamp)
                            .labelsHidden()
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "music.note.house.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.85))

            VStack(spacing: 6) {
                Text("MacAMRP")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                Text("Apple Music Rich Presence for macOS")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                Text("Version 1.1")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }

            if let track = manager.currentTrack {
                HStack(spacing: 10) {
                    Image(systemName: track.isPlaying ? "play.fill" : "pause.fill")
                        .foregroundStyle(.white.opacity(0.7))
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if !track.artist.isEmpty {
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(in: .rect(cornerRadius: 12))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Reusable Components

    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .kerning(0.8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            content()
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 16))
    }

    private func settingsRow<Control: View>(
        label: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body)
                    .foregroundStyle(.white)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Tab Model

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, display, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .display: return "Display"
        case .about:   return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .display: return "paintbrush"
        case .about:   return "info.circle"
        }
    }
}

#Preview {
    SettingsView(manager: RichPresenceManager())
}
