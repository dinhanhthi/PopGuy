// AppsView.swift
// PopGuy — UI/SettingsWindow
//
// Settings tab for ignored-apps and ignored-domains configuration.
//
// Sections (one header-row tab each, the page shows the selected one's card):
//   • Ignored Apps: an "Enable Ignored Apps" toggle (default on) gates the whole
//     feature — while off, the list is not applied and the toolbar's "Ignore this
//     app" button is hidden (the saved list is kept). When on, a list of bundle IDs
//     with friendly name + icon; remove button. An "Add App…" button opens
//     NSOpenPanel to pick a .app bundle.
//     When on, a toggle can hide just the toolbar's "Ignore this app" button (list still applies).
//   • Ignored Domains: an "Enable Ignored Domains" toggle (default off) gates the
//     whole feature — while off, PopGuy never reads any browser URL and macOS
//     never prompts for Automation permission. When on, a permission warning plus
//     a domain list + text-field/Add button are shown.
//     When on, a toggle can hide just the toolbar's "Ignore this site" button (list still applies).
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

    @State private var newDomain = ""
    @State private var domainValidationError: String? = nil
    /// The section the header-row tabs show.
    @State private var tab: IgnoreTab = .apps

    var body: some View {
        // The page builds its own layout so its tabs paint in the click's
        // frame; only the body below waits for the deferred turn. The tab is
        // read here and passed down so the body depends on it explicitly
        // (DeferredSectionContent builds its content in this body anyway).
        let tab = tab
        return SettingsPageLayout(leading: {
            CapsuleTabs(selection: $tab, tabs: IgnoreTab.allCases, title: { Text($0.title) })
                .fixedSize()
        }) {
            DeferredSectionContent { pageBody(tab) }
        }
        #if DEBUG
        .onAppear(perform: applyDebugTab)
        #endif
    }

    #if DEBUG
    /// DEBUG-only QA hook: `--ignore-tab=apps|domains` selects a tab when the
    /// page appears, for screenshots from a shell. `--ignore-domain-draft=<text>`
    /// prefills the domain field; `--ignore-commit-draft` then submits it 0.5 s
    /// later (after the deferred body is up), to show the validation message.
    private func applyDebugTab() {
        let args = ProcessInfo.processInfo.arguments
        let prefix = "--ignore-tab="
        if let arg = args.first(where: { $0.hasPrefix(prefix) }),
           let value = IgnoreTab(rawValue: String(arg.dropFirst(prefix.count))) {
            tab = value
        }
        let draftPrefix = "--ignore-domain-draft="
        if let arg = args.first(where: { $0.hasPrefix(draftPrefix) }) {
            newDomain = String(arg.dropFirst(draftPrefix.count))
        }
        if args.contains("--ignore-commit-draft") {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                commitNewDomain()
            }
        }
    }
    #endif

    private func pageBody(_ tab: IgnoreTab) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                switch tab {
                case .apps:    appsSection
                case .domains: domainsSection
                }
            }
            .padding(SettingsMetrics.pagePadding)
        }
        .labeledContentStyle(.settingsRow)
    }

    private var appsSection: some View {
        // No title: the header-row tab already names the section.
        SettingsGroup(
            nil,
            description: "The toolbar will not appear when you select text in these apps. Turning this off also removes the \"Ignore this app\" button from the toolbar."
        ) {
            LabeledContent {
                Toggle("Enable Ignored Apps", isOn: $settings.ignoredAppsEnabled)
                    .toggleStyle(CompactSwitch())
                    .labelsHidden()
            } label: {
                Text("Enable Ignored Apps")
            }

            if settings.ignoredAppsEnabled {
                SettingsDivider()

                LabeledContent {
                    Toggle("Show \"Ignore this app\" button on toolbar", isOn: $settings.showToolbarIgnoreAppButton)
                        .toggleStyle(CompactSwitch())
                        .labelsHidden()
                } label: {
                    Text("Show \"Ignore this app\" button on toolbar")
                    Text("Hides only the toolbar button; the ignored list keeps working.")
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                if settings.ignoredAppBundleIDs.isEmpty {
                    Text("No ignored apps.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.ignoredAppBundleIDs, id: \.self) { bundleID in
                        if bundleID != settings.ignoredAppBundleIDs.first {
                            SettingsDivider()
                        }
                        IgnoredAppRow(bundleID: bundleID) {
                            settings.removeIgnoredApp(bundleID: bundleID)
                        }
                    }
                }

                SettingsDivider()

                Button {
                    addApp()
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
                .buttonStyle(RowTextButtonStyle(formRow: true))
            }
        }
    }

    private var domainsSection: some View {
        // No title: the header-row tab already names the section.
        SettingsGroup(
            nil,
            description: "Hide the toolbar on these websites. Works in Safari, Chrome, Brave, Edge, Arc. Desktop apps use Ignored Apps instead."
        ) {
            LabeledContent {
                Toggle("Enable Ignored Domains", isOn: $settings.ignoredDomainsEnabled)
                    .toggleStyle(CompactSwitch())
                    .labelsHidden()
            } label: {
                Text("Enable Ignored Domains")
            }

            if settings.ignoredDomainsEnabled {
                SettingsDivider()

                LabeledContent {
                    Toggle("Show \"Ignore this site\" button on toolbar", isOn: $settings.showToolbarIgnoreSiteButton)
                        .toggleStyle(CompactSwitch())
                        .labelsHidden()
                } label: {
                    Text("Show \"Ignore this site\" button on toolbar")
                    Text("Hides only the toolbar button; the ignored list keeps working.")
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("To match these domains, PopGuy reads the address of your current browser tab. macOS will ask permission to control each browser the first time — choose Allow. While this is off, PopGuy never reads any browser URL.")
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsDivider()

                if settings.ignoredDomains.isEmpty {
                    Text("No ignored domains.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.ignoredDomains, id: \.self) { domain in
                        if domain != settings.ignoredDomains.first {
                            SettingsDivider()
                        }
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
                            .buttonStyle(RowIconButtonStyle())
                            .hoverTooltip("Remove")
                        }
                    }
                }

                SettingsDivider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("", text: $newDomain)
                            .textFieldStyle(.settings)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .onSubmit { commitNewDomain() }
                            .onChange(of: newDomain) { _ in domainValidationError = nil }
                        Button("Add") { commitNewDomain() }
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                    }

                    if let err = domainValidationError {
                        Text(err)
                            .font(.settingsCaption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Domain helpers

    private func commitNewDomain() {
        let trimmed = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
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

// MARK: - IgnoreTab

/// The Ignore page's tabs, one per section.
private enum IgnoreTab: String, CaseIterable {
    case apps, domains

    var title: String {
        switch self {
        case .apps:    "Ignored apps"
        case .domains: "Ignored domains"
        }
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
                        .font(.settingsCaption)
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
            .buttonStyle(RowIconButtonStyle())
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
