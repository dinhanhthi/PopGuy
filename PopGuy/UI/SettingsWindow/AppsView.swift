// AppsView.swift
// PopGuy — UI/SettingsWindow
//
// Settings tab for ignored-apps and ignored-domains configuration.
//
// Sections:
//   • Ignored Apps: list of bundle IDs with friendly name + icon; remove button.
//     An "Add App…" button opens NSOpenPanel to pick a .app bundle.
//   • Ignored Domains: an "Enable Ignored Domains" toggle (default off) gates the
//     whole feature — while off, PopGuy never reads any browser URL and macOS
//     never prompts for Automation permission. When on, a permission warning plus
//     a domain list + text-field/Add button are shown.
//     Works in Safari, Chrome, Brave, Edge, Arc. Desktop apps use Ignored Apps instead.
//
// Bundle-ID resolution (UI concern only — not in SettingsStore):
//   NSWorkspace.urlForApplication(withBundleIdentifier:) → app URL
//   Bundle(url:).infoDictionary → CFBundleDisplayName / CFBundleName
//   NSWorkspace.icon(forFile:) → NSImage icon
//   Fallback: raw bundle ID string + SF Symbol "app.dashed"
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - AppsView

struct AppsView: View {

    @ObservedObject var settings: SettingsStore
    @ObservedObject var licenseGate: LicenseGate
    var onUpgrade: () -> Void = {}

    @State private var newDomain = ""
    @State private var domainValidationError: String? = nil

    private var atIgnoredAppLimit: Bool {
        !licenseGate.entitlements.isPro
            && settings.ignoredAppBundleIDs.count >= licenseGate.entitlements.maxIgnoredApps
    }

    private var atIgnoredDomainLimit: Bool {
        !licenseGate.entitlements.isPro
            && settings.ignoredDomains.count >= licenseGate.entitlements.maxIgnoredDomains
    }

    var body: some View {
        Form {
            Section {
                if settings.ignoredAppBundleIDs.isEmpty {
                    Text("No ignored apps.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(settings.ignoredAppBundleIDs, id: \.self) { bundleID in
                        IgnoredAppRow(bundleID: bundleID) {
                            settings.removeIgnoredApp(bundleID: bundleID)
                        }
                    }
                }

                Button {
                    addApp()
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(atIgnoredAppLimit)
                .padding(.vertical, 4)

                if atIgnoredAppLimit {
                    UpgradePromptView(
                        message: "Free plan is limited to \(licenseGate.entitlements.maxIgnoredApps) ignored apps. Upgrade to Pro for unlimited ignored apps.",
                        onUpgrade: onUpgrade
                    )
                }

            } header: {
                Text("Ignored Apps")
            } footer: {
                Text("The toolbar will not appear when you select text in these apps.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable Ignored Domains", isOn: $settings.ignoredDomainsEnabled)
                    .padding(.vertical, 2)

                if settings.ignoredDomainsEnabled {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("To match these domains, PopGuy reads the address of your current browser tab. macOS will ask permission to control each browser the first time — choose Allow. While this is off, PopGuy never reads any browser URL.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    if settings.ignoredDomains.isEmpty {
                        Text("No ignored domains.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(settings.ignoredDomains, id: \.self) { domain in
                            HStack {
                                Image(systemName: "globe")
                                    .frame(width: 20, height: 20)
                                    .foregroundStyle(.secondary)
                                Text(domain)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    settings.removeIgnoredDomain(domain)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .hoverTooltip("Remove")
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    HStack {
                        TextField("", text: $newDomain)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .onSubmit { commitNewDomain() }
                            .onChange(of: newDomain) { _ in domainValidationError = nil }
                        Button("Add") { commitNewDomain() }
                            .buttonStyle(.bordered)
                    }
                    .disabled(atIgnoredDomainLimit)
                    .padding(.vertical, 4)

                    if let err = domainValidationError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if atIgnoredDomainLimit {
                        UpgradePromptView(
                            message: "Free plan is limited to \(licenseGate.entitlements.maxIgnoredDomains) ignored domains. Upgrade to Pro for unlimited ignored domains.",
                            onUpgrade: onUpgrade
                        )
                    }
                }
            } header: {
                Text("Ignored Domains")
            } footer: {
                Text("Hide the toolbar on these websites. Works in Safari, Chrome, Brave, Edge, Arc. Desktop apps use Ignored Apps instead.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Domain helpers

    private func commitNewDomain() {
        let trimmed = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !atIgnoredDomainLimit else { return }
        let countBefore = settings.ignoredDomains.count
        settings.addIgnoredDomain(trimmed)
        if settings.ignoredDomains.count > countBefore {
            newDomain = ""
            domainValidationError = nil
        } else {
            domainValidationError = "Invalid domain — try \"example.com\"."
        }
    }

    // MARK: - Add via NSOpenPanel

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        settings.addIgnoredApp(bundleID: bundleID)
    }
}

// MARK: - IgnoredAppRow

/// A single row in the ignored-apps list.
/// Resolves bundle ID → friendly name + icon synchronously at init (lightweight for a small list).
private struct IgnoredAppRow: View {

    let bundleID: String
    let onRemove: () -> Void

    // Resolved lazily at init (synchronous, no async needed).
    private let appName: String
    private let appIcon: NSImage?
    private let appURL: URL?

    init(bundleID: String, onRemove: @escaping () -> Void) {
        self.bundleID = bundleID
        self.onRemove = onRemove
        let (name, icon, url) = Self.resolveApp(bundleID: bundleID)
        self.appName = name
        self.appIcon = icon
        self.appURL  = url
    }

    var body: some View {
        HStack(spacing: 8) {
            // Icon
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }

            // Name + bundle ID
            VStack(alignment: .leading, spacing: 1) {
                Text(appName)
                    .lineLimit(1)
                // Show bundle ID as secondary caption when we have a friendly name.
                if appName != bundleID {
                    Text(bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Remove button
            Button {
                onRemove()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .hoverTooltip("Remove")
        }
        .padding(.vertical, 2)
    }

    // MARK: Resolution helper

    /// Resolves a bundle ID to (displayName, icon, appURL).
    /// Returns (bundleID, nil, nil) when the app is not found / not installed.
    private static func resolveApp(bundleID: String) -> (String, NSImage?, URL?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil, nil)
        }

        let name: String = {
            guard let info = Bundle(url: url)?.infoDictionary else { return bundleID }
            return (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"]        as? String)
                ?? bundleID
        }()

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return (name, icon, url)
    }
}
