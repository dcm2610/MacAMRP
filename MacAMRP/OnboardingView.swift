//
//  OnboardingView.swift
//  MacAMRP
//
//  First-launch welcome screen shown once when the app is opened for the first time.
//

import SwiftUI
import AppKit

// MARK: - Window Controller

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to MacAMRP"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(manager: RichPresenceManager) {
        guard let window else { return }

        // Mark as launched immediately so a restart before closing doesn't re-show onboarding
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")

        NSApp.applicationIconImage = AppIconRenderer.cachedIcon
        window.contentViewController = NSHostingController(rootView: OnboardingView(manager: manager))
        window.center()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - View

struct OnboardingView: View {
    let manager: RichPresenceManager

    var body: some View {
        ZStack {
            // Full-bleed background
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 48)

                // App icon — corners are baked into the rendered image (transparent pixels)
                Image(nsImage: AppIconRenderer.cachedIcon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)

                Spacer().frame(height: 24)

                // Title
                Text("Welcome to MacAMRP")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                Spacer().frame(height: 12)

                // Subtitle
                Text("Discord Rich Presence for Apple Music")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))

                Spacer().frame(height: 40)

                // Feature list
                VStack(alignment: .leading, spacing: 16) {
                    featureRow(icon: "music.note", title: "Now Playing", description: "Automatically shows your current track on Discord")
                    featureRow(icon: "chart.bar.fill", title: "Progress Bar", description: "Real-time playback progress synced with Apple Music")
                    featureRow(icon: "photo", title: "Album Art", description: "Fetches artwork directly from the iTunes Search API")
                    featureRow(icon: "gearshape.fill", title: "Customisable", description: "Control what's shown from the menu bar Settings")
                }
                .padding(.horizontal, 40)

                Spacer().frame(height: 40)

                // Permission note
                Text("MacAMRP will ask for permission to control Music.app — this is required for the progress bar.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 48)

                Spacer().frame(height: 24)

                // Get Started button
                Button {
                    OnboardingWindowController.shared.window?.close()
                } label: {
                    Text("Get Started")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 0.98, green: 0.40, blue: 0.60).opacity(0.85))
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)

                Spacer().frame(height: 32)
            }
        }
        .frame(width: 480, height: 620)
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()
        }
    }
}
