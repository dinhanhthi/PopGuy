// AboutView.swift
// PopGuy — UI/SettingsWindow
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import AppKit
import SwiftUI

struct AboutView: View {

    @ObservedObject var updater: UpdaterController

    // MARK: - Bundle metadata

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }
    private var releaseDate: String? {
        Bundle.main.infoDictionary?["PGReleaseDate"] as? String
    }

    // MARK: - Static URLs

    private static let websiteURL     = URL(string: "https://pg.dinhanhthi.com")!
    private static let authorURL      = URL(string: "https://dinhanhthi.com")!
    private static let emailURL       = URL(string: "mailto:me@dinhanhthi.com")!
    private static let discussionsURL = URL(string: "https://github.com/dinhanhthi/PopGuy/discussions")!
    private static let githubURL      = URL(string: "https://github.com/dinhanhthi/PopGuy")!

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                headerCard
                updatesCard
                linksCard
            }
            .padding(SettingsMetrics.pagePadding)
        }
    }

    // MARK: - Header card (logo + version)

    private var headerCard: some View {
        SettingsCard(title: "PopGuy") {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 4) {
                    Text("PopGuy")
                        .font(.title2.weight(.semibold))
                    Text(versionLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Link("github.com/dinhanhthi/PopGuy", destination: Self.githubURL)
                        .font(.callout)
                }
            }
        }
    }

    static func makeVersionLine(version: String, build: String?, releaseDate: String?) -> String {
        var parts = ["v\(version)"]
        if let b = build, !b.isEmpty { parts.append("(\(b))") }
        if let d = releaseDate, !d.isEmpty { parts.append("· \(d)") }
        return parts.joined(separator: " ")
    }

    private var versionLine: String {
        Self.makeVersionLine(version: version, build: build, releaseDate: releaseDate)
    }

    // MARK: - Updates card

    private var updatesCard: some View {
        SettingsCard(title: "Updates") {
            VStack(alignment: .leading, spacing: SettingsMetrics.contentSpacing) {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                    .toggleStyle(.checkbox)

                HStack(spacing: 8) {
                    Button("Check for Updates\u{2026}") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)

                    if updater.updateAvailable {
                        Label(
                            updater.pendingVersion.map { "Update available — v\($0)" } ?? "Update available",
                            systemImage: "arrow.down.circle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.tint)
                    } else {
                        Text("You're on the latest version.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Links card

    private var linksCard: some View {
        SettingsCard(title: "Info") {
            VStack(alignment: .leading, spacing: SettingsMetrics.contentSpacing) {
                row(label: "Author") {
                    Link("Anh-Thi DINH", destination: Self.authorURL)
                }
                row(label: "Website") {
                    Link("pg.dinhanhthi.com", destination: Self.websiteURL)
                }
                row(label: "Contact") {
                    Link("me@dinhanhthi.com", destination: Self.emailURL)
                }
                row(label: "Discussions") {
                    Link("GitHub Discussions", destination: Self.discussionsURL)
                }
            }
        }
    }

    @ViewBuilder
    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

// MARK: - Preview

#Preview {
    AboutView(updater: UpdaterController())
        .frame(width: 580, height: 400)
}
