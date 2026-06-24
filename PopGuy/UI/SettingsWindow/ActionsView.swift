// ActionsView.swift
// PopGuy — UI/SettingsWindow
//
// Card-based unified Actions settings tab.
// Each action (Improve, Translate, and each custom action) gets its own
// card with an enabled toggle, shortcut row, provider settings, and optional
// custom prompt.
//
// T4.1: scaffold — container + ActionCard component + one Improve stub card.
// T4.2: full Improve card (provider picker, model field, custom prompt, shortcut).
// T4.3: full Translate card (provider picker, model field, language picker, shortcut).
// T4.4: custom action cards + Add button + modal.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import AppKit
import AVFoundation
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ActionTypeFilter

/// Filter for the Actions list: show all actions or only one type.
private enum ActionTypeFilter: String, CaseIterable, Identifiable {
    case all
    case ai
    case translation
    case speech
    case dictionary
    case openURL
    case runShortcut
    case appleScript
    case shellScript
    case fromPlugin

    var id: String { rawValue }

    /// User-visible label for the filter menu.
    var displayName: String {
        switch self {
        case .all:         return "All Types"
        case .ai:          return "AI"
        case .translation: return "Translation"
        case .speech:      return "Speech"
        case .dictionary:  return "Dictionary"
        case .openURL:     return "Open URL"
        case .runShortcut: return "Run Shortcut"
        case .appleScript: return "AppleScript"
        case .shellScript: return "Shell Script"
        case .fromPlugin:  return "From Plugin"
        }
    }
}

// MARK: - ActionsView

struct ActionsView: View {

    @ObservedObject var settings: SettingsStore
    let keychain: KeychainManager
    @ObservedObject var licenseGate: LicenseGate
    var onUpgrade: () -> Void = {}

    /// Optional navigator — used to consume `pendingPluginImportURL` set by
    /// AppDelegate when a .popclipext/.json file is opened via Finder.
    var navigator: SettingsNavigator? = nil

    /// Shared recording state — only one row records at a time across the entire tab.
    @State private var recordingID: ActionIdentifier?

    /// When non-nil, the edit panel is presented for this action.
    /// Add flow: set to a fresh CustomAction (new UUID, empty fields).
    /// Edit flow: set to an existing CustomAction (preserves id).
    /// Owned by SettingsView so the panel can slide over the whole window.
    @Binding var editingAction: CustomAction?

    /// Drives the Action Library gallery panel. Owned by SettingsView so the
    /// panel slides over the whole window, matching the Add/Edit Action panel.
    @Binding var showingLibrary: Bool

    /// Drives the "toolbar action limit reached" alert.
    @State private var showLimitAlert = false

    /// Drives the "toolbar layout zone full" alert when principal/burger caps block a move.
    @State private var showPrincipalLimitAlert = false

    /// Filters the action list by type. `.all` shows every action.
    @State private var typeFilter: ActionTypeFilter = .all

    /// Free-text search query matched against action titles.
    @State private var searchQuery = ""

    /// Drives the import error alert.
    @State private var importError: String? = nil
    @State private var showImportError = false

    /// Drives the import-capped informational alert (free cap reached mid-import).
    @State private var importCappedCount: Int = 0
    @State private var showImportCappedAlert = false

    /// Drives the import-skipped alert (actions with disallowed providers were dropped).
    @State private var importSkippedCount: Int = 0
    @State private var showImportSkippedAlert = false

    /// Drives the export-failed alert.
    @State private var exportError: String? = nil
    @State private var showExportError = false

    // MARK: - Plugin Import state

    /// Pending consent result — set by any import path; consent sheet reads it.
    /// The pending import result; non-nil drives the consent sheet via `.sheet(item:)`.
    @State private var pendingConsent: PluginImportResult?

    /// Drives the plugin-import source menu (Choose file / Paste snippet).

    /// Controls presentation of the Paste Snippet sheet.
    @State private var showSnippetSheet = false

    /// Text entered in the Paste Snippet sheet.
    @State private var snippetText = ""

    /// Holds the parsed snippet result until the snippet sheet dismisses, so the
    /// consent sheet can be presented after the race window closes.
    @State private var snippetParsedResult: PluginImportResult? = nil

    // MARK: - Language list (mirrors TranslateTab)

    private let languages: [(name: String, bcp47: String)] = [
        ("English",             "en"),
        ("Vietnamese",          "vi"),
        ("French",              "fr"),
        ("Spanish",             "es"),
        ("German",              "de"),
        ("Japanese",            "ja"),
        ("Chinese (Simplified)","zh"),
        ("Korean",              "ko"),
        ("Portuguese",          "pt"),
        ("Italian",             "it"),
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // MARK: Fixed header (toolbar preview + Add Custom Action row)
            VStack(spacing: SettingsMetrics.cardSpacing) {

                ToolbarLayoutEditorView(settings: settings)

                // MARK: Add Custom Action button
                let atCustomActionLimit = !licenseGate.entitlements.isPro
                    && settings.customActions.count >= licenseGate.entitlements.maxCustomActions

                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            editingAction = CustomAction(title: "", systemPrompt: "")
                        }
                    } label: {
                        Text("Add Action")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(atCustomActionLimit)

                    Text("\(settings.principalActionCount)/\(ProConfig.maxPrincipalActions) toolbar · \(settings.overflowActionCount)/\(ProConfig.maxBurgerActions) More")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Export / Import — Pro-gated, icon-only with hover tooltip
                    let importExportAllowed = licenseGate.entitlements.importExportAllowed
                    if importExportAllowed {
                        Button {
                            exportActions()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: SettingsMetrics.toolbarIconWidth, height: SettingsMetrics.toolbarIconHeight)
                        }
                        .buttonStyle(ToolbarIconButtonStyle())
                        .disabled(settings.customActions.isEmpty)
                        .hoverTooltip("Export custom actions")

                        Button {
                            importActions()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .frame(width: SettingsMetrics.toolbarIconWidth, height: SettingsMetrics.toolbarIconHeight)
                        }
                        .buttonStyle(ToolbarIconButtonStyle())
                        .hoverTooltip("Import custom actions")
                    } else {
                        Button {
                            onUpgrade()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                ProBadge()
                            }
                            .frame(height: SettingsMetrics.toolbarIconHeight)
                        }
                        .buttonStyle(ToolbarIconButtonStyle())
                        .hoverTooltip("Export custom actions — Pro feature")

                        Button {
                            onUpgrade()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.down")
                                ProBadge()
                            }
                            .frame(height: SettingsMetrics.toolbarIconHeight)
                        }
                        .buttonStyle(ToolbarIconButtonStyle())
                        .hoverTooltip("Import custom actions — Pro feature")
                    }

                    // Import Plugin — available to all users (free + Pro)
                    let pluginImportAllowed = licenseGate.entitlements.pluginImportAllowed
                    if pluginImportAllowed {
                        SettingsInlineMenu(borderedToolbarTrigger: true) {
                            Image(systemName: "puzzlepiece.extension")
                                .frame(width: SettingsMetrics.toolbarIconWidth, height: SettingsMetrics.toolbarIconHeight)
                        } menuContent: {
                            Button {
                                importPluginFromFile()
                            } label: {
                                Label("Choose file\u{2026}", systemImage: "folder")
                            }
                            Button {
                                snippetText = ""
                                showSnippetSheet = true
                            } label: {
                                Label("Paste snippet\u{2026}", systemImage: "doc.on.clipboard")
                            }
                        }
                        .hoverTooltip("Import plugin")
                    } else {
                        Button {
                            onUpgrade()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "puzzlepiece.extension")
                                ProBadge()
                            }
                            .frame(height: SettingsMetrics.toolbarIconHeight)
                        }
                        .buttonStyle(ToolbarIconButtonStyle())
                        .hoverTooltip("Import plugin — Pro feature")
                    }

                    // Browse Library — always available (free + Pro); install is gated inside.
                    // Slides the gallery panel in from the right (owned by SettingsView).
                    Button {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            showingLibrary = true
                        }
                    } label: {
                        Image(systemName: "books.vertical")
                            .frame(width: SettingsMetrics.toolbarIconWidth, height: SettingsMetrics.toolbarIconHeight)
                    }
                    .buttonStyle(ToolbarIconButtonStyle())
                    .hoverTooltip("Browse Action Library")
                }

                // MARK: Search + type filter bar
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search actions\u{2026}", text: $searchQuery)
                            .textFieldStyle(.plain)
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )

                    SettingsInlinePickerMenu(
                        selection: $typeFilter,
                        displayTitle: typeFilter.displayName,
                        options: ActionTypeFilter.allCases.map { ($0, $0.displayName) },
                        tooltip: "Filter actions by type"
                    )
                }

                if atCustomActionLimit {
                    UpgradePromptView(
                        message: "Free plan is limited to \(licenseGate.entitlements.maxCustomActions) custom actions and shows \(licenseGate.entitlements.maxActiveActions) actions in the toolbar. Upgrade to Pro for unlimited actions.",
                        onUpgrade: onUpgrade
                    )
                }
            }
            .padding(.horizontal, SettingsMetrics.pagePadding)
            .padding(.top, SettingsMetrics.pagePadding)
            .padding(.bottom, SettingsMetrics.cardSpacing)

            // MARK: Scrollable action cards — rendered in actionOrder
            ScrollView {
                VStack(spacing: SettingsMetrics.cardSpacing) {
                    ForEach(filteredActionOrder, id: \.self) { id in
                        card(for: id)
                    }
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, SettingsMetrics.pagePadding)
            }
        }
        .alert("Toolbar Limit Reached", isPresented: $showLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("PopGuy supports at most \(SettingsStore.maxToolbarActions) enabled actions (\(ProConfig.maxPrincipalActions) on the toolbar and \(ProConfig.maxBurgerActions) in the More menu). Turn off another action first.")
        }
        .alert("Toolbar Layout Full", isPresented: $showPrincipalLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The toolbar row holds up to \(ProConfig.maxPrincipalActions) actions and the More menu holds up to \(ProConfig.maxBurgerActions). Free a slot in that zone before moving this action.")
        }
        .alert("Import Failed", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "The file could not be imported.")
        }
        .alert("Import Complete", isPresented: $showImportCappedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            let cappedMsg = "Imported \(importCappedCount) action\(importCappedCount == 1 ? "" : "s"). The free plan limit was reached — upgrade to Pro to import more actions."
            let skippedMsg = importSkippedCount > 0
                ? " Also skipped \(importSkippedCount) action\(importSkippedCount == 1 ? "" : "s") whose provider is not valid for its action type."
                : ""
            Text(cappedMsg + skippedMsg)
        }
        .alert("Unsupported Provider", isPresented: $showImportSkippedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Skipped \(importSkippedCount) action\(importSkippedCount == 1 ? "" : "s") whose provider is not valid for its action type.")
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Could not write the file.")
        }
        // Paste Snippet sheet
        .sheet(isPresented: $showSnippetSheet, onDismiss: {
            // Present consent after snippet sheet fully dismisses (avoids SwiftUI
            // sheet-layering race when two sheets open in the same cycle).
            if let result = snippetParsedResult {
                snippetParsedResult = nil
                presentConsent(for: result)
            }
        }) {
            SnippetInputSheet(
                snippetText: $snippetText,
                onSubmit: { text in
                    do {
                        let config = try PopClipExtensionReader.read(snippet: text)
                        let result = PopClipToPopGuyAdapter.adapt(config)
                        snippetParsedResult = result
                    } catch {
                        importError = error.localizedDescription
                        showImportError = true
                    }
                    showSnippetSheet = false
                },
                onCancel: {
                    showSnippetSheet = false
                }
            )
        }
        // Consent sheet — presented by all import paths (file, snippet, native JSON).
        // Use `.sheet(item:)` so the result is guaranteed non-nil when the sheet
        // renders (an `isPresented` + optional pattern can race and show an empty sheet).
        .sheet(item: $pendingConsent) { result in
            PluginImportConsentView(
                result: result,
                onConfirm: { actions in
                    pendingConsent = nil
                    handleConsentConfirm(actions)
                },
                onCancel: {
                    pendingConsent = nil
                }
            )
        }
        // Consume a pending plugin import URL delivered by AppDelegate (Finder open-file).
        // Checked on appear and whenever the navigator publishes a new URL.
        .onAppear {
            consumePendingImportURL()
        }
        .onChange(of: navigator?.pendingPluginImportURL) { _ in
            consumePendingImportURL()
        }
        .onDisappear {
            // Cancel any in-progress recording when the view disappears.
            recordingID = nil
        }
    }

    /// Consumes `navigator.pendingPluginImportURL` if set, running the same
    /// dispatch logic as `importPluginFromFile()` but without a panel.
    private func consumePendingImportURL() {
        guard let url = navigator?.pendingPluginImportURL else { return }
        // Clear immediately to avoid re-triggering.
        navigator?.pendingPluginImportURL = nil

        // Pro-gate: plugin import is a Pro-gated feature.
        guard licenseGate.entitlements.pluginImportAllowed else {
            onUpgrade()
            return
        }

        let ext = url.pathExtension.lowercased()
        if ext == "popclipext" {
            do {
                let config = try PopClipExtensionReader.read(bundleURL: url)
                let result = PopClipToPopGuyAdapter.adapt(config)
                presentConsent(for: result)
            } catch {
                importError = error.localizedDescription
                showImportError = true
            }
        } else if ext == "json" {
            guard let data = try? Data(contentsOf: url) else {
                importError = "The file could not be read."
                showImportError = true
                return
            }
            guard data.count <= 2 * 1024 * 1024 else {
                importError = "The file is too large to import."
                showImportError = true
                return
            }
            let decoded: [CustomAction]
            do {
                decoded = try JSONDecoder().decode([CustomAction].self, from: data)
            } catch {
                importError = "The file does not contain a valid list of custom actions."
                showImportError = true
                return
            }
            let safeSlice = Array(decoded.prefix(100))
            let sourceName = url.deletingPathExtension().lastPathComponent
            let result = PluginImportResult(sourceName: sourceName, imported: safeSlice, skipped: [])
            presentConsent(for: result)
        }
        // Unknown extensions are silently ignored (Finder document type registration
        // should prevent non-matching files from reaching here).
    }

    // MARK: - Export / Import

    /// Export all custom actions to a user-chosen JSON file via NSSavePanel.
    private func exportActions() {
        let actions = settings.customActions
        guard !actions.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(actions)
        } catch {
            exportError = "Could not encode the actions: \(error.localizedDescription)"
            showExportError = true
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Custom Actions"
        panel.nameFieldStringValue = "popguy-actions.json"
        panel.allowedContentTypes = [UTType.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            exportError = "Could not write the file: \(error.localizedDescription)"
            showExportError = true
        }
    }

    /// Import custom actions from a user-chosen JSON file via NSOpenPanel.
    ///
    /// Security: the file is treated as untrusted — it must decode to [CustomAction]
    /// or the import is aborted. Import is capped at 100 items per operation. Actions
    /// are previewed in the consent sheet before being added; sanitizeImported runs on
    /// confirm (in handleConsentConfirm).
    private func importActions() {
        let panel = NSOpenPanel()
        panel.title = "Import Custom Actions"
        panel.allowedContentTypes = [UTType.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let data = try? Data(contentsOf: url) else {
            importError = "The file could not be read."
            showImportError = true
            return
        }

        guard data.count <= 2 * 1024 * 1024 else {
            importError = "The file is too large to import."
            showImportError = true
            return
        }

        let decoded: [CustomAction]
        do {
            decoded = try JSONDecoder().decode([CustomAction].self, from: data)
        } catch {
            importError = "The file does not contain a valid list of custom actions."
            showImportError = true
            return
        }

        // Safety cap: never import more than 100 actions per operation.
        let safeSlice = Array(decoded.prefix(100))

        // Route through consent sheet so the user can review actions before they are added.
        // sanitizeImported + free-cap enforcement run in handleConsentConfirm on confirm.
        let sourceName = url.deletingPathExtension().lastPathComponent
        let result = PluginImportResult(sourceName: sourceName, imported: safeSlice, skipped: [])
        presentConsent(for: result)
    }

    // MARK: - Plugin import (file + snippet paths)

    /// Opens an NSOpenPanel accepting `.popclipext` packages/directories and `.json` files.
    /// Dispatches to the PopClip reader or JSON decoder, then presents the consent sheet.
    private func importPluginFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Plugin"
        panel.message = "Choose a PopGuy plugin (.json) or a PopClip extension (.popclipext)."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true      // .popclipext may be a package OR a plain folder
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        // No allowedContentTypes filter on purpose: a `.popclipext` bundle appears
        // either as a registered package (a "file") or as a plain folder, depending
        // on whether a PopClip-aware app is installed / Launch Services has registered
        // our imported type. Filtering by UTType disables one of those representations
        // and triggers a slow synchronous Launch Services lookup (the spinning cursor).
        // We accept any selection and validate it by extension below.

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ext = url.pathExtension.lowercased()

        // Dispatch by extension (or directory with .popclipext extension)
        if ext == "popclipext" || url.hasDirectoryPath && ext.isEmpty {
            // PopClip bundle path
            do {
                let config = try PopClipExtensionReader.read(bundleURL: url)
                let result = PopClipToPopGuyAdapter.adapt(config)
                presentConsent(for: result)
            } catch {
                importError = error.localizedDescription
                showImportError = true
            }
        } else {
            // Native JSON path — same 2 MiB cap + decode as importActions()
            guard let data = try? Data(contentsOf: url) else {
                importError = "The file could not be read."
                showImportError = true
                return
            }
            guard data.count <= 2 * 1024 * 1024 else {
                importError = "The file is too large to import."
                showImportError = true
                return
            }
            let decoded: [CustomAction]
            do {
                decoded = try JSONDecoder().decode([CustomAction].self, from: data)
            } catch {
                importError = "The file does not contain a valid list of custom actions."
                showImportError = true
                return
            }
            // Safety cap: never import more than 100 actions per operation.
            let safeSlice = Array(decoded.prefix(100))
            let sourceName = url.deletingPathExtension().lastPathComponent
            let result = PluginImportResult(sourceName: sourceName, imported: safeSlice, skipped: [])
            presentConsent(for: result)
        }
    }

    /// Presents the consent sheet by setting the pending result (drives `.sheet(item:)`).
    private func presentConsent(for result: PluginImportResult) {
        pendingConsent = result
    }

    /// Processes the confirmed import: sanitize → free-cap check → addCustomAction.
    /// Single site shared by all import paths (native JSON, PopClip bundle, snippet).
    private func handleConsentConfirm(_ actions: [CustomAction]) {
        let isPro = licenseGate.entitlements.isPro
        let maxAllowed = licenseGate.entitlements.maxCustomActions
        let cloudAllowed = licenseGate.entitlements.cloudTTSPremiumAllowed
        var importedCount = 0
        var skippedCount = 0

        for action in actions {
            guard var fresh = CustomAction.sanitizeImported(action, cloudAllowed: cloudAllowed) else {
                skippedCount += 1
                continue
            }
            if !isPro && settings.customActions.count >= maxAllowed {
                importCappedCount = importedCount
                importSkippedCount = skippedCount   // 0 when nothing was skipped
                showImportCappedAlert = true
                return
            }
            // Mark as plugin-imported so the action shows a "From plugin" badge.
            fresh.isFromPlugin = true
            _ = settings.addCustomAction(fresh)
            importedCount += 1
        }

        if skippedCount > 0 {
            importSkippedCount = skippedCount
            showImportSkippedAlert = true
        }
    }

    // MARK: - Type filter

    /// The action order narrowed to the selected type filter.
    private var filteredActionOrder: [ActionIdentifier] {
        let byType: [ActionIdentifier]
        switch typeFilter {
        case .all:         byType = settings.actionOrder
        case .ai:          byType = settings.actionOrder.filter { actionType(for: $0) == .ai }
        case .translation: byType = settings.actionOrder.filter { actionType(for: $0) == .translation }
        case .speech:      byType = settings.actionOrder.filter { actionType(for: $0) == .speech }
        case .dictionary:  byType = settings.actionOrder.filter { actionType(for: $0) == .dictionary }
        case .openURL:     byType = settings.actionOrder.filter { actionType(for: $0) == .openURL }
        case .runShortcut: byType = settings.actionOrder.filter { actionType(for: $0) == .runShortcut }
        case .appleScript: byType = settings.actionOrder.filter { actionType(for: $0) == .appleScript }
        case .shellScript: byType = settings.actionOrder.filter { actionType(for: $0) == .shellScript }
        case .fromPlugin:  byType = settings.actionOrder.filter { isFromPlugin($0) }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return byType }
        return byType.filter { displayTitle(for: $0).localizedCaseInsensitiveContains(q) }
    }

    private func displayTitle(for id: ActionIdentifier) -> String {
        switch id {
        case .builtin(.improve):   return "Improve"
        case .builtin(.shorten):   return "Shorten"
        case .builtin(.proofread): return "Proofread"
        case .builtin(.prompt):    return "Prompt"
        case .builtin(.translate): return "Translate"
        case .speak:               return "Speak"
        case .dictionary:          return "Dictionary"
        case .custom(let uuid):
            return settings.customActions.first(where: { $0.id == uuid })?.title ?? ""
        }
    }

    /// Whether an action identifier resolves to a plugin-imported custom action.
    /// Built-ins are never from a plugin.
    private func isFromPlugin(_ id: ActionIdentifier) -> Bool {
        guard case .custom(let uuid) = id else { return false }
        return settings.customActions.first(where: { $0.id == uuid })?.isFromPlugin ?? false
    }

    /// Maps any action identifier (built-in or custom) to its action type.
    /// Built-ins: Translate → translation, Speak → speech, all other built-ins
    /// (Improve/Shorten/Proofread/Prompt) → ai. Custom actions carry their own type.
    private func actionType(for id: ActionIdentifier) -> CustomActionType {
        switch id {
        case .builtin(.translate): return .translation
        case .builtin:             return .ai
        case .speak:               return .speech
        case .dictionary:          return .dictionary
        case .custom(let uuid):
            return settings.customActions.first(where: { $0.id == uuid })?.type ?? .ai
        }
    }

    // MARK: - Principal / enable bindings

    private func principalBinding(for id: ActionIdentifier) -> Binding<Bool> {
        Binding(
            get: { settings.isPrincipal(id) },
            set: { newValue in
                if !settings.setPrincipal(id, newValue) {
                    showPrincipalLimitAlert = true
                }
            }
        )
    }

    // MARK: - Ordered card dispatcher

    @ViewBuilder
    private func card(for id: ActionIdentifier) -> some View {
        switch id {
        case .builtin(.improve):
            aiActionCard(
                kind: .improve,
                icon: "wand.and.stars",
                title: "Improve",
                subtitle: "Fix grammar and improve clarity while preserving the original meaning and tone.",
                enabled: guardedEnableBinding(for: $settings.improveEnabled),
                isPrincipal: principalBinding(for: id),
                config: $settings.improveConfig,
                showsTone: true
            )

        case .builtin(.shorten):
            aiActionCard(
                kind: .shorten,
                icon: "text.badge.minus",
                title: "Shorten",
                subtitle: "Make the selected text more concise and simpler without losing the main ideas.",
                enabled: guardedEnableBinding(for: $settings.shortenEnabled),
                isPrincipal: principalBinding(for: id),
                config: $settings.shortenConfig,
                showsTone: true
            )

        case .builtin(.proofread):
            aiActionCard(
                kind: .proofread,
                icon: "checkmark.bubble",
                title: "Proofread",
                subtitle: "Fix spelling, grammar, and punctuation without changing the meaning or tone.",
                enabled: guardedEnableBinding(for: $settings.proofreadEnabled),
                isPrincipal: principalBinding(for: id),
                config: $settings.proofreadConfig
            )

        case .builtin(.prompt):
            aiActionCard(
                kind: .prompt,
                icon: "bubble.and.pencil",
                title: "Prompt",
                subtitle: "Type a one-off prompt for the selected text. Use {{text}} to place the selection; it's added automatically if omitted.",
                enabled: guardedEnableBinding(for: $settings.promptEnabled),
                isPrincipal: principalBinding(for: id),
                config: $settings.promptConfig,
                showsTone: false,
                showsPrompt: false
            )

        case .builtin(.translate):
            translateCard(isPrincipal: principalBinding(for: id))

        case .speak:
            SpeakCardView(
                settings: settings,
                keychain: keychain,
                licenseGate: licenseGate,
                onUpgrade: onUpgrade,
                enabled: guardedEnableBinding(for: $settings.speakEnabled),
                isPrincipal: principalBinding(for: id),
                recordingID: $recordingID
            )

        case .dictionary:
            DictionaryCardView(
                settings: settings,
                licenseGate: licenseGate,
                onUpgrade: onUpgrade,
                enabled: guardedEnableBinding(for: $settings.dictionaryConfig.isEnabled),
                isPrincipal: principalBinding(for: id)
            )

        case .custom(let uuid):
            if let action = settings.customActions.first(where: { $0.id == uuid }) {
                customActionCard(
                    action: action,
                    isPrincipal: principalBinding(for: id)
                )
            }
        }
    }

    // MARK: - Cap-guarded enable binding

    /// Returns a Binding<Bool> that intercepts enable (off→on) attempts.
    ///
    /// When turning ON and `enabledToolbarActionCount` is already at the cap,
    /// the write is rejected and `showLimitAlert` is set to true so the user
    /// sees a warning. Turning OFF is always allowed.
    private func guardedEnableBinding(for binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                if newValue && settings.enabledToolbarActionCount >= SettingsStore.maxToolbarActions {
                    showLimitAlert = true
                } else {
                    binding.wrappedValue = newValue
                }
            }
        )
    }

    // MARK: - Tone picker

    /// Menu picker over all `TranslateTone` cases, shared by the Improve,
    /// Shorten, and Translate cards.
    @ViewBuilder
    private func tonePicker(tone: Binding<TranslateTone>) -> some View {
        LabeledContent("Tone") {
            Picker("", selection: tone) {
                ForEach(TranslateTone.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: - Translate card

    @ViewBuilder
    private func translateCard(
        isPrincipal: Binding<Bool>
    ) -> some View {
        ActionCard(
            icon: .sfSymbol("character.bubble"),
            title: "Translate",
            subtitle: "Translate the selected text into your chosen language.",
            enabled: guardedEnableBinding(for: $settings.translateEnabled),
            isPrincipal: isPrincipal,
            isBuiltin: true
        ) {
            // Provider picker (all 5 providers).
            // Reconstruct via init (id/provider/model are immutable) but
            // preserve customPrompt and tone so changing the provider
            // doesn't wipe them.
            ProviderPicker(
                label: "Provider",
                selection: Binding(
                    get: { settings.translateConfig.providerKind },
                    set: { newKind in
                        let c = settings.translateConfig
                        settings.translateConfig = ActionConfig(
                            id: .translate,
                            providerKind: newKind,
                            model: c.model,
                            customPrompt: c.customPrompt,
                            tone: c.tone
                        )
                    }
                ),
                allowed: ActionKind.translate.allowedProviders
            )
            latencyNote(for: settings.translateConfig.providerKind)

            // Model field — hidden for translation-native providers
            // (DeepL, Google), which have no model identifier.
            if settings.translateConfig.providerKind.usesModel {
                ModelField(
                    label: "Model",
                    model: Binding(
                        get: { settings.translateConfig.model },
                        set: { newModel in
                            let c = settings.translateConfig
                            settings.translateConfig = ActionConfig(
                                id: .translate,
                                providerKind: c.providerKind,
                                model: newModel,
                                customPrompt: c.customPrompt,
                                tone: c.tone
                            )
                        }
                    ),
                    providerKind: settings.translateConfig.providerKind,
                    placeholder: "Model",
                    settings: settings,
                    keychain: keychain
                )
            }

            // Default target language picker
            LabeledContent("Default Target Language") {
                Picker("", selection: $settings.defaultTargetLanguage) {
                    ForEach(languages, id: \.bcp47) { lang in
                        Text(lang.name).tag(lang.bcp47)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            // Tone picker — steers the output register. Meaningful for
            // AI/LLM providers (via the prompt) and for DeepL (mapped to
            // its `formality` parameter, e.g. "tu" vs "vous" in French).
            // Hidden only for Google Translate, which offers no register
            // control.
            if settings.translateConfig.providerKind.usesModel
                || settings.translateConfig.providerKind == .deepL {
                tonePicker(tone: Binding(
                    get: { settings.translateConfig.tone ?? .neutral },
                    set: { newTone in
                        var c = settings.translateConfig
                        c.tone = newTone
                        settings.translateConfig = c
                    }
                ))
            }

            // Additional prompt is only meaningful for AI/LLM providers.
            // DeepL and Google Translate ignore the system prompt entirely
            // (they translate via the target language code alone), so it
            // is hidden for them.
            if settings.translateConfig.providerKind.usesModel {
                // Additive: layered on top of the built-in (invisible)
                // translate prompt, not a replacement.
                customPromptField(
                    text: Binding(
                        get: { settings.translateConfig.customPrompt ?? "" },
                        set: { newValue in
                            var c = settings.translateConfig
                            c.customPrompt = newValue.isEmpty ? nil : newValue
                            settings.translateConfig = c
                        }
                    ),
                    label: "Additional prompt",
                    infoText: "Extra instructions applied on top of translating to your chosen language and tone. The selected language and tone keep priority, but a conflicting instruction here may still influence the result.",
                    caption: "Added on top of the default translation prompt.",
                    allowsPredefined: true
                )
            }

            // Shortcut
            ShortcutRecorderRow(
                actionID: .builtin(.translate),
                settings: settings,
                recordingID: $recordingID
            )
        }
    }

    // MARK: - AI rewrite card builder (Shorten, Proofread, Prompt)

    /// Card for a built-in AI rewrite action whose settings mirror Improve:
    /// AI-only provider picker, model field, custom prompt with a predefined
    /// fallback, and a shortcut row.
    @ViewBuilder
    private func aiActionCard(
        kind: ActionKind,
        icon: String,
        title: String,
        subtitle: String,
        enabled: Binding<Bool>,
        isPrincipal: Binding<Bool>,
        config: Binding<ActionConfig>,
        showsTone: Bool = false,
        showsPrompt: Bool = true
    ) -> some View {
        ActionCard(
            icon: .sfSymbol(icon),
            title: title,
            subtitle: subtitle,
            enabled: enabled,
            isPrincipal: isPrincipal,
            isBuiltin: true
        ) {
            // Provider picker (AI-only)
            ProviderPicker(
                label: "Provider",
                selection: Binding(
                    get: { config.wrappedValue.providerKind },
                    set: { newKind in
                        let c = config.wrappedValue
                        config.wrappedValue = ActionConfig(
                            id: kind,
                            providerKind: newKind,
                            model: c.model,
                            customPrompt: c.customPrompt,
                            tone: c.tone
                        )
                    }
                ),
                allowed: kind.allowedProviders
            )
            latencyNote(for: config.wrappedValue.providerKind)

            // Model field
            ModelField(
                label: "Model",
                model: Binding(
                    get: { config.wrappedValue.model },
                    set: { newModel in
                        let c = config.wrappedValue
                        config.wrappedValue = ActionConfig(
                            id: kind,
                            providerKind: c.providerKind,
                            model: newModel,
                            customPrompt: c.customPrompt,
                            tone: c.tone
                        )
                    }
                ),
                providerKind: config.wrappedValue.providerKind,
                placeholder: "Model",
                settings: settings,
                keychain: keychain
            )

            // Tone picker — steers the output register (Shorten only; Proofread
            // preserves the author's tone, so it opts out via showsTone: false).
            if showsTone {
                tonePicker(tone: Binding(
                    get: { config.wrappedValue.tone ?? .neutral },
                    set: { newTone in
                        var c = config.wrappedValue
                        c.tone = newTone
                        config.wrappedValue = c
                    }
                ))
            }

            // Custom prompt field (predefined fallback, like Improve)
            if showsPrompt {
                customPromptField(
                    text: Binding(
                        get: { config.wrappedValue.customPrompt ?? "" },
                        set: { newValue in
                            var c = config.wrappedValue
                            c.customPrompt = newValue.isEmpty ? nil : newValue
                            config.wrappedValue = c
                        }
                    ),
                    allowsPredefined: true
                )
            }

            // Shortcut
            ShortcutRecorderRow(
                actionID: .builtin(kind),
                settings: settings,
                recordingID: $recordingID
            )
        }
    }

    // MARK: - Custom action card builder

    @ViewBuilder
    private func customActionCard(
        action: CustomAction,
        isPrincipal: Binding<Bool>
    ) -> some View {
        let id = action.id
        let rawEnabledBinding = Binding(
            get: { settings.customActions.first(where: { $0.id == id })?.isEnabled ?? true },
            set: { newValue in
                guard var c = settings.customActions.first(where: { $0.id == id }) else { return }
                c.isEnabled = newValue
                settings.updateCustomAction(c)
            }
        )
        ActionCard(
            icon: action.icon,
            title: action.title.isEmpty ? "(untitled)" : action.title,
            subtitle: action.actionDescription,
            enabled: guardedEnableBinding(for: rawEnabledBinding),
            isPrincipal: isPrincipal,
            isBuiltin: false,
            isFromPlugin: action.isFromPlugin,
            onEdit: {
                if let current = settings.customActions.first(where: { $0.id == id }) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        editingAction = current
                    }
                }
            },
            onDelete: {
                settings.deleteCustomAction(id: id)
            }
        ) {
            // Per-type fields — only the type-relevant controls are shown.
            switch action.type {

            case .ai:
                // Provider picker (AI providers only)
                ProviderPicker(
                    label: "Provider",
                    selection: Binding(
                        get: { settings.customActions.first(where: { $0.id == id })?.providerKind ?? .anthropic },
                        set: { newKind in
                            guard var c = settings.customActions.first(where: { $0.id == id }) else { return }
                            c.providerKind = newKind
                            settings.updateCustomAction(c)
                        }
                    ),
                    allowed: CustomAction.allowedProviders(for: .ai)
                )
                latencyNote(for: settings.customActions.first(where: { $0.id == id })?.providerKind ?? .anthropic)

                // Model field
                ModelField(
                    label: "Model",
                    model: Binding(
                        get: { settings.customActions.first(where: { $0.id == id })?.model ?? "" },
                        set: { newModel in
                            guard var c = settings.customActions.first(where: { $0.id == id }) else { return }
                            c.model = newModel
                            settings.updateCustomAction(c)
                        }
                    ),
                    providerKind: settings.customActions.first(where: { $0.id == id })?.providerKind ?? .anthropic,
                    placeholder: "Model",
                    settings: settings,
                    keychain: keychain
                )

                // System prompt field (required for AI)
                customPromptField(
                    text: Binding(
                        get: { settings.customActions.first(where: { $0.id == id })?.systemPrompt ?? "" },
                        set: { newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            guard var c = settings.customActions.first(where: { $0.id == id }) else { return }
                            c.systemPrompt = newValue
                            settings.updateCustomAction(c)
                        }
                    ),
                    placeholder: "Required — system prompt for this action"
                )

            case .translation:
                // Provider picker (translation providers)
                ProviderPicker(
                    label: "Provider",
                    selection: Binding(
                        get: { settings.customActions.first(where: { $0.id == id })?.providerKind ?? .deepL },
                        set: { newKind in
                            guard var c = settings.customActions.first(where: { $0.id == id }) else { return }
                            c.providerKind = newKind
                            settings.updateCustomAction(c)
                        }
                    ),
                    allowed: CustomAction.allowedProviders(for: .translation)
                )
                latencyNote(for: settings.customActions.first(where: { $0.id == id })?.providerKind ?? .deepL)

                // Model field — hidden for translation-native providers (DeepL, Google).
                let translationProvider = settings.customActions.first(where: { $0.id == id })?.providerKind ?? .deepL
                if translationProvider.usesModel {
                    ModelField(
                        label: "Model",
                        model: Binding(
                            get: { settings.customActions.first(where: { $0.id == id })?.model ?? "" },
                            set: { newModel in
                                guard var c = settings.customActions.first(where: { $0.id == id }) else { return }
                                c.model = newModel
                                settings.updateCustomAction(c)
                            }
                        ),
                        providerKind: translationProvider,
                        placeholder: "Model",
                        settings: settings,
                        keychain: keychain
                    )
                }

                // Default Target Language picker
                LabeledContent("Default Target Language") {
                    Picker("", selection: Binding(
                        get: { settings.customActions.first(where: { $0.id == id })?.targetLanguage ?? "en" },
                        set: { newLang in
                            guard var c = settings.customActions.first(where: { $0.id == id }) else { return }
                            c.targetLanguage = newLang
                            settings.updateCustomAction(c)
                        }
                    )) {
                        ForEach(languages, id: \.bcp47) { lang in
                            Text(lang.name).tag(lang.bcp47)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                // Tone picker — for AI providers and DeepL (formality parameter).
                if translationProvider.usesModel || translationProvider == .deepL {
                    tonePicker(tone: Binding(
                        get: { settings.customActions.first(where: { $0.id == id })?.tone ?? .neutral },
                        set: { newTone in
                            guard var c = settings.customActions.first(where: { $0.id == id }) else { return }
                            c.tone = newTone
                            settings.updateCustomAction(c)
                        }
                    ))
                }

                // Additional prompt — optional, for AI providers only.
                if translationProvider.usesModel {
                    customPromptField(
                        text: Binding(
                            get: { settings.customActions.first(where: { $0.id == id })?.systemPrompt ?? "" },
                            set: { newValue in
                                guard var c = settings.customActions.first(where: { $0.id == id }) else { return }
                                c.systemPrompt = newValue
                                settings.updateCustomAction(c)
                            }
                        ),
                        label: "Additional prompt",
                        infoText: "Extra instructions applied on top of translating to your chosen language and tone.",
                        caption: "Added on top of the default translation prompt.",
                        allowsPredefined: true
                    )
                }

            case .speech:
                CustomSpeechFields(
                    actionID: id,
                    settings: settings,
                    keychain: keychain,
                    licenseGate: licenseGate,
                    onUpgrade: onUpgrade
                )

            case .dictionary:
                DictionaryConfigFields(
                    config: Binding(
                        get: { settings.customActions.first(where: { $0.id == id })?.dictionaryConfig ?? .default },
                        set: { newConfig in
                            guard var c = settings.customActions.first(where: { $0.id == id }) else { return }
                            c.dictionaryConfig = newConfig
                            settings.updateCustomAction(c)
                        }
                    ),
                    licenseGate: licenseGate,
                    onUpgrade: onUpgrade
                )

            case .openURL, .runShortcut, .appleScript, .shellScript:
                // TODO(scriptable-actions phase 4): per-type inline fields (script preview, URL template, etc.)
                EmptyView()
            }

            // Shortcut — shared across all types.
            ShortcutRecorderRow(
                actionID: .custom(id),
                settings: settings,
                recordingID: $recordingID
            )
        }
    }


    // MARK: - Latency warning

    /// Inline latency warning shown when a CLI provider is selected.
    /// Data-driven off `ProviderKind.latencyWarning` — auto-covers future CLI kinds.
    @ViewBuilder
    private func latencyNote(for kind: ProviderKind) -> some View {
        if let warning = kind.latencyWarning {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Shared sub-views

    /// Multi-line custom prompt field with {{text}} hint caption.
    ///
    /// - `allowsPredefined: true` (Improve): when the prompt is empty, the input
    ///   is hidden and "Predefined prompt is being used" + an Edit button is shown.
    ///   Tapping Edit reveals the input so the user can write a custom prompt.
    /// - `allowsPredefined: false` (custom actions): the prompt is required, so
    ///   the input is always visible.
    private func customPromptField(
        text: Binding<String>,
        label: String = "Prompt",
        infoText: String? = nil,
        placeholder: String = "Custom prompt",
        caption: String = "Use {{text}} for the selected text.",
        allowsPredefined: Bool = false
    ) -> some View {
        CustomPromptField(
            text: text,
            label: label,
            infoText: infoText,
            placeholder: placeholder,
            caption: caption,
            allowsPredefined: allowsPredefined
        )
    }
}

// MARK: - CustomPromptField

private struct CustomPromptField: View {
    @Binding var text: String
    /// Label shown above the field.
    let label: String
    /// Optional (i) tooltip text shown next to the label.
    let infoText: String?
    let placeholder: String
    /// Hint caption shown under the input field.
    let caption: String
    let allowsPredefined: Bool

    /// When `allowsPredefined`, the input stays hidden (predefined in use) until Edit.
    @State private var isEditing = false

    /// Drives the Reset confirmation dialog (Improve only).
    @State private var isShowingResetConfirmation = false

    /// Show the text input when the prompt is required, has content, or the user
    /// tapped Edit. Hide it only for an empty Improve prompt that hasn't been edited.
    private var showsInput: Bool {
        !allowsPredefined || !text.isEmpty || isEditing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Label on its own line above the (multi-line) field, matching the
            // "Provider"/"Model" labels while leaving the field full-width.
            HStack(spacing: 4) {
                Text(label)
                if let infoText {
                    InfoTooltip(text: infoText)
                }
            }

            if showsInput {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                HStack {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Reset — only when a predefined fallback exists (Improve).
                    // Confirms first, then clears the custom prompt back to the
                    // predefined one and collapses to the "Predefined prompt" state.
                    if allowsPredefined {
                        Button("Reset") { isShowingResetConfirmation = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            } else {
                HStack {
                    Text("Predefined prompt is being used")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                    Button("Edit") { isEditing = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .confirmationDialog(
            "Reset to predefined prompt?",
            isPresented: $isShowingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                text = ""
                isEditing = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your custom prompt will be discarded and PopGuy will use the predefined prompt again.")
        }
    }
}

// MARK: - BuiltinBadge

/// A subtle capsule badge that marks built-in actions in the Actions settings panel.
private struct BuiltinBadge: View {
    var body: some View {
        Text("Built-in")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

// MARK: - FromPluginBadge

/// A subtle capsule badge that marks actions added via plugin/extension import.
/// Mirrors `BuiltinBadge` styling.
private struct FromPluginBadge: View {
    var body: some View {
        Text("From plugin")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

// MARK: - ActionCard

/// A card container for a single action's settings.
///
/// In-card header: icon badge + title (with optional Built-in badge) on the
/// left; principal checkbox + enabled toggle on the right. Body: the
/// caller-supplied content rows below the header divider.
private struct ActionCard<Content: View>: View {

    let icon: ActionIcon
    let title: String
    /// Optional description shown under the title.
    var subtitle: String? = nil
    @Binding var enabled: Bool
    @Binding var isPrincipal: Bool
    /// When true, a "Built-in" badge appears next to the title.
    var isBuiltin: Bool = false
    /// When true (and not built-in), a "From plugin" badge appears next to the title.
    var isFromPlugin: Bool = false
    /// When non-nil, an Edit icon button appears in the header accessory.
    var onEdit: (() -> Void)? = nil
    /// When non-nil, a Delete icon button (with confirmation) appears in the header accessory.
    var onDelete: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    /// Collapsed by default — the card shows only its header until tapped,
    /// mirroring the History rows.
    @State private var isExpanded = false

    /// Drives the delete confirmation dialog.
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        SettingsCard(
            icon: icon,
            title: title,
            subtitle: subtitle,
            isExpanded: $isExpanded,
            accessory: {
                HStack(spacing: 12) {
                    // Edit / Delete — icon-only with hover tooltips, sitting to
                    // the left of the drag handle. Only present for custom actions.
                    if let onEdit {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .hoverTooltip("Edit")
                    }
                    if let onDelete {
                        Button { isShowingDeleteConfirmation = true } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .hoverTooltip("Delete")
                        .confirmationDialog(
                            "Delete this action?",
                            isPresented: $isShowingDeleteConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Delete", role: .destructive) { onDelete() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This custom action will be permanently removed.")
                        }
                    }

                    Toggle(isOn: $isPrincipal) {
                        Text("Toolbar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .hoverTooltip("Show in the main toolbar (off = in the More menu)")

                    // Enable toggle
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            },
            titleAccessory: {
                if isBuiltin {
                    BuiltinBadge()
                } else if isFromPlugin {
                    FromPluginBadge()
                }
            },
            content: {
                content()
            }
        )
    }
}

// MARK: - DictionaryCardView

private struct DictionaryCardView: View {

    @ObservedObject var settings: SettingsStore
    @ObservedObject var licenseGate: LicenseGate
    var onUpgrade: () -> Void = {}
    @Binding var enabled: Bool
    @Binding var isPrincipal: Bool

    var body: some View {
        ActionCard(
            icon: .sfSymbol("character.book.closed"),
            title: "Look up",
            subtitle: "Look up definitions, phonetics, and examples across every dictionary provider.",
            enabled: $enabled,
            isPrincipal: $isPrincipal,
            isBuiltin: true
        ) {
            DictionaryConfigFields(
                config: $settings.dictionaryConfig,
                licenseGate: licenseGate,
                onUpgrade: onUpgrade
            )
        }
    }
}

// MARK: - DictionaryConfigFields

/// Binding-based Dictionary settings template reused by the built-in
/// Look up card, custom Dictionary action cards, and the edit sheet.
struct DictionaryConfigFields: View {

    @Binding var config: DictionaryConfig
    @ObservedObject var licenseGate: LicenseGate
    var onUpgrade: () -> Void = {}

    private var cloudAllowed: Bool {
        licenseGate.entitlements.cloudTTSPremiumAllowed
    }

    var body: some View {
        let voices = VoiceCatalog.voices(for: config.accent)
        let engineBinding = Binding<SpeakEngineSelection>(
            get: {
                let engine = config.speakSettings.selectedEngine
                if case .cloud = engine, !cloudAllowed { return .system }
                return engine
            },
            set: { newEngine in
                guard cloudAllowed || newEngine == .system else { return }
                config.speakSettings.selectedEngine = newEngine
            }
        )

        VStack(alignment: .leading, spacing: 16) {
            LabeledContent("Default target language") {
                // Bind through TargetLanguage so an off-list/legacy BCP-47 code
                // (e.g. "en-GB") coerces to a valid selection instead of rendering
                // a blank menu — mirrors the toolbar's TargetLanguage(bcp47:) coercion.
                Picker("", selection: Binding(
                    get: { TargetLanguage(bcp47: config.definitionLanguage) },
                    set: { config.definitionLanguage = $0.bcp47 }
                )) {
                    ForEach(TargetLanguage.allCases) { lang in
                        Text(lang.rawValue).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            .hoverTooltip("Target language used by online providers (e.g. English, Vietnamese, French). The offline macOS dictionary ignores this value.")

            Divider()

            Text("Pronunciation / speech")
                .font(.headline)

            LabeledContent("Speech engine") {
                Picker("", selection: engineBinding) {
                    Text(SpeakEngineSelection.system.displayName).tag(SpeakEngineSelection.system)
                    Divider()
                    ForEach(TTSProviderKind.implemented.map { SpeakEngineSelection.cloud($0) }) { engine in
                        HStack(spacing: 4) {
                            Text(engine.displayName)
                            if !cloudAllowed { ProBadge() }
                        }
                        .tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            if !cloudAllowed {
                UpgradePromptView(
                    message: "Cloud TTS voices require a Pro plan. System voice and source-native dictionary audio remain available for free.",
                    onUpgrade: onUpgrade
                )
            }

            LabeledContent("Accent") {
                Picker("", selection: Binding(
                    get: { config.accent },
                    set: { newAccent in
                        if newAccent != config.accent { config.speakSettings.defaultVoiceID = nil }
                        config.accent = newAccent
                        config.speakSettings.defaultAccent = newAccent
                    }
                )) {
                    ForEach(SpeakAccent.allCases) { accent in
                        Text(accent.displayName).tag(accent)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            LabeledContent("System voice") {
                if voices.isEmpty {
                    Text("No voices installed")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: Binding(
                        get: { config.speakSettings.defaultVoiceID as String? },
                        set: { newValue in config.speakSettings.defaultVoiceID = newValue }
                    )) {
                        Text("Default (best available)").tag(nil as String?)
                        ForEach(voices) { voice in
                            Text("\(voice.displayName) — \(voice.qualityLabel)")
                                .tag(voice.id as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Toggle("Use dictionary audio before TTS", isOn: $config.speakSettings.dictionaryAudioEnabled)
                .hoverTooltip("When no native source audio is available, try Free Dictionary API pronunciation before falling back to the selected TTS engine.")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(speakLevel(forRate: config.speakSettings.rate)) / 10")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(speakLevel(forRate: config.speakSettings.rate)) },
                        set: { newLevel in config.speakSettings.rate = speakRate(forLevel: Int(newLevel)) }
                    ),
                    in: 1...10,
                    step: 1
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pitch")
                    Spacer()
                    Text("\(speakLevel(forPitch: config.speakSettings.pitch)) / 10")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(speakLevel(forPitch: config.speakSettings.pitch)) },
                        set: { newLevel in config.speakSettings.pitch = speakPitch(forLevel: Int(newLevel)) }
                    ),
                    in: 1...10,
                    step: 1
                )
            }
        }
    }
}

// MARK: - SpeakCardView

/// Extracted Speak card view with one shared `SpeakCoordinator` so the main
/// preview and per-voice test buttons can't play at the same time.
private struct SpeakCardView: View {

    @ObservedObject var settings: SettingsStore
    @ObservedObject var licenseGate: LicenseGate
    var onUpgrade: () -> Void = {}
    @Binding var enabled: Bool
    @Binding var isPrincipal: Bool
    @Binding var recordingID: ActionIdentifier?

    @StateObject private var coordinator: SpeakCoordinator
    @State private var activeVoicePreviewID: String?

    // Cloud model custom-entry flag — keyed by TTSProviderKind.keychainAccount.
    @State private var isModelCustom: [String: Bool] = [:]

    // Selected language for the two-dropdown per-language voice section.
    @State private var selectedVoiceLanguage: SpeakAccent

    init(
        settings: SettingsStore,
        keychain: KeychainManager,
        licenseGate: LicenseGate,
        onUpgrade: @escaping () -> Void = {},
        enabled: Binding<Bool>,
        isPrincipal: Binding<Bool>,
        recordingID: Binding<ActionIdentifier?>
    ) {
        self.settings = settings
        self.licenseGate = licenseGate
        self.onUpgrade = onUpgrade
        self._enabled = enabled
        self._isPrincipal = isPrincipal
        self._recordingID = recordingID
        _coordinator = StateObject(wrappedValue: SpeakCoordinator(keychain: keychain))
        _selectedVoiceLanguage = State(initialValue: settings.speakSettings.defaultAccent)
    }

    // Speed/pitch helpers are file-scope (speakRate/speakLevel/speakPitch).

    var body: some View {
        let voices = VoiceCatalog.voices(for: settings.speakSettings.defaultAccent)

        ActionCard(
            icon: .sfSymbol("speaker.wave.2"),
            title: "Speak",
            subtitle: "Read the selected text aloud using the system speech synthesiser.",
            enabled: $enabled,
            isPrincipal: $isPrincipal,
            isBuiltin: true
        ) {
            VStack(alignment: .leading, spacing: 16) {

            // Speech engine picker
            // When not Pro, cloud engines are disabled with a ProBadge.
            // If a cloud engine is already selected and the user is not Pro,
            // fall back to .system so audio never silently routes to a locked engine.
            let cloudAllowed = licenseGate.entitlements.cloudTTSPremiumAllowed
            let engineBinding = Binding<SpeakEngineSelection>(
                get: {
                    let engine = settings.speakSettings.selectedEngine
                    if case .cloud = engine, !cloudAllowed { return .system }
                    return engine
                },
                set: { newEngine in
                    guard cloudAllowed || newEngine == .system else { return }
                    var s = settings.speakSettings
                    s.selectedEngine = newEngine
                    settings.speakSettings = s
                }
            )
            LabeledContent("Speech engine") {
                Picker("", selection: engineBinding) {
                    Text(SpeakEngineSelection.system.displayName).tag(SpeakEngineSelection.system)
                    Divider()
                    ForEach(TTSProviderKind.implemented.map { SpeakEngineSelection.cloud($0) }) { engine in
                        HStack(spacing: 4) {
                            Text(engine.displayName)
                            if !cloudAllowed { ProBadge() }
                        }
                        .tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                // Cloud enforcement is via the binding set-guard (line above) and ProBadge.
            }
            if !cloudAllowed {
                UpgradePromptView(
                    message: "Cloud TTS voices (OpenAI, Google, Azure) require a Pro plan. System voice and dictionary audio remain available for free.",
                    onUpgrade: onUpgrade
                )
            }
            if case .cloud = engineBinding.wrappedValue {
                Text("Falls back to the System voice when the cloud key is missing, offline, or the text exceeds the cloud limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Cloud Model / Voice / Language section — gated on selected cloud engine.
            if case .cloud(let kind) = engineBinding.wrappedValue {
                let keyAccount = kind.keychainAccount

                // Model row — only for providers that expose a user-facing model selector.
                if kind.usesModel {
                    HStack(spacing: 8) {
                        Text("Model")
                        let curated = kind.curatedModels
                        let modelBinding = Binding<String>(
                            get: { settings.ttsConfig(for: kind).model ?? kind.defaultModel ?? "" },
                            set: { newValue in
                                var config = settings.ttsConfig(for: kind)
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                config.model = trimmed.isEmpty ? nil : newValue
                                let effectiveModel = trimmed.isEmpty ? (kind.defaultModel ?? "") : trimmed
                                config = config.clearingInvalidDefaultVoice(
                                    forModel: effectiveModel,
                                    validVoices: kind.curatedVoices(forModel: effectiveModel)
                                )
                                settings.setTTSConfig(config, for: kind)
                            }
                        )
                        if curated.isEmpty {
                            TextField(kind.defaultModel ?? "model identifier", text: modelBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                        } else {
                            let pickerBinding = Binding<String>(
                                get: {
                                    if isModelCustom[keyAccount] ?? false { return "__custom__" }
                                    let effective = settings.ttsConfig(for: kind).model
                                        ?? kind.defaultModel ?? ""
                                    return curated.contains(effective) ? effective : "__custom__"
                                },
                                set: { newValue in
                                    if newValue == "__custom__" {
                                        isModelCustom[keyAccount] = true
                                    } else {
                                        isModelCustom[keyAccount] = false
                                        var config = settings.ttsConfig(for: kind)
                                        config.model = newValue
                                        config = config.clearingInvalidDefaultVoice(
                                            forModel: newValue,
                                            validVoices: kind.curatedVoices(forModel: newValue)
                                        )
                                        settings.setTTSConfig(config, for: kind)
                                    }
                                }
                            )
                            HStack(spacing: 6) {
                                Picker("", selection: pickerBinding) {
                                    ForEach(curated, id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    Divider()
                                    Text("Custom…").tag("__custom__")
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .fixedSize()

                                if isModelCustom[keyAccount] ?? false {
                                    TextField(kind.defaultModel ?? "model identifier", text: modelBinding)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 200)
                                }
                            }
                        }
                    }
                }

                // Single Voice row — for providers with a model-level voice list (OpenAI).
                let currentModel = settings.ttsConfig(for: kind).model ?? kind.defaultModel ?? ""
                let modelVoices = kind.curatedVoices(forModel: currentModel)
                if !modelVoices.isEmpty {
                    HStack(spacing: 8) {
                        Text("Voice")
                        let voiceBinding = Binding<String?>(
                            get: { settings.ttsConfig(for: kind).defaultVoice },
                            set: { newVoice in
                                var config = settings.ttsConfig(for: kind)
                                config.defaultVoice = newVoice
                                settings.setTTSConfig(config, for: kind)
                            }
                        )
                        Picker("", selection: voiceBinding) {
                            Text("Default (alloy)").tag(nil as String?)
                            ForEach(modelVoices, id: \.self) { voice in
                                if voice == "marin" || voice == "cedar" {
                                    Text("\(voice) — recommended").tag(voice as String?)
                                } else {
                                    Text(voice).tag(voice as String?)
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        VoiceTestButton(
                            kind: kind,
                            languageCode: settings.speakSettings.defaultAccent.bcp47,
                            rowID: "\(kind.rawValue):voice",
                            cloudAllowed: cloudAllowed,
                            settings: settings,
                            coordinator: coordinator,
                            activeID: $activeVoicePreviewID
                        )
                    }
                }

                // Two-dropdown per-language voice section (Google, Azure).
                // OpenAI returns [] for forLanguage: so this block is safely skipped.
                if !kind.curatedVoices(forLanguage: "en-US").isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Voices")
                            .font(.headline)
                            .padding(.top, 4)

                        HStack(spacing: 8) {
                            // Language dropdown
                            Picker("", selection: $selectedVoiceLanguage) {
                                ForEach(SpeakAccent.allCases) { accent in
                                    Text(accent.displayName).tag(accent)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()

                            // Voice dropdown — reacts to selectedVoiceLanguage
                            let bcp47 = selectedVoiceLanguage.bcp47
                            let langVoices = kind.curatedVoices(forLanguage: bcp47)
                            let langVoiceBinding = Binding<String?>(
                                get: { settings.ttsConfig(for: kind).voiceOverrides[bcp47] },
                                set: { newVoice in
                                    var config = settings.ttsConfig(for: kind)
                                    if let v = newVoice {
                                        config.voiceOverrides[bcp47] = v
                                    } else {
                                        config.voiceOverrides.removeValue(forKey: bcp47)
                                    }
                                    settings.setTTSConfig(config, for: kind)
                                }
                            )
                            Picker("", selection: langVoiceBinding) {
                                Text("Default").tag(nil as String?)
                                ForEach(langVoices, id: \.self) { voice in
                                    Text(voice).tag(voice as String?)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()

                            VoiceTestButton(
                                kind: kind,
                                languageCode: bcp47,
                                rowID: "\(kind.rawValue):\(bcp47)",
                                cloudAllowed: cloudAllowed,
                                settings: settings,
                                coordinator: coordinator,
                                activeID: $activeVoicePreviewID
                            )
                        }
                        Text("Each language uses its own voice; Default picks the best available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Default accent picker
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Default Accent") {
                    Picker("", selection: Binding(
                        get: { settings.speakSettings.defaultAccent },
                        set: { newAccent in
                            var s = settings.speakSettings
                            if newAccent != s.defaultAccent { s.defaultVoiceID = nil }
                            s.defaultAccent = newAccent
                            settings.speakSettings = s
                        }
                    )) {
                        ForEach(SpeakAccent.allCases) { accent in
                            Text(accent.displayName).tag(accent)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                Text("The accent used to read text aloud by default. Switch accents on the fly from the toolbar's accent menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // System voice picker
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("System voice") {
                    if voices.isEmpty {
                        EmptyView()
                    } else {
                        Picker("", selection: Binding(
                            get: { settings.speakSettings.defaultVoiceID as String? },
                            set: { newID in
                                var s = settings.speakSettings
                                s.defaultVoiceID = newID
                                settings.speakSettings = s
                            }
                        )) {
                            Text("Default (best available)").tag(nil as String?)
                            ForEach(voices) { voice in
                                Text("\(voice.displayName) — \(voice.bcp47) (\(voice.qualityLabel))")
                                    .tag(voice.id as String?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if voices.isEmpty {
                    Text("Download more voices in System Settings → Accessibility → Spoken Content.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if engineBinding.wrappedValue != .system {
                    Label {
                        Text("The System voice is still used as a fallback when the cloud voice is unavailable — missing API key, offline, or text longer than the cloud limit.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            // Speed slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(speakLevel(forRate: settings.speakSettings.rate)) / 10")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(speakLevel(forRate: settings.speakSettings.rate)) },
                        set: { newLevel in
                            var s = settings.speakSettings
                            s.rate = speakRate(forLevel: Int(newLevel))
                            settings.speakSettings = s
                        }
                    ),
                    in: 1...10,
                    step: 1
                )
                .disabled(!engineBinding.wrappedValue.supportsSpeed)
                if engineBinding.wrappedValue.supportsSpeed {
                    Text("How fast synthesized speech plays. Lower is slower — useful for hearing each sound clearly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The selected engine doesn't support a speed override; speech plays at the provider's default rate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Pitch slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pitch")
                    Spacer()
                    Text("\(speakLevel(forPitch: settings.speakSettings.pitch)) / 10")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(speakLevel(forPitch: settings.speakSettings.pitch)) },
                        set: { newLevel in
                            var s = settings.speakSettings
                            s.pitch = speakPitch(forLevel: Int(newLevel))
                            settings.speakSettings = s
                        }
                    ),
                    in: 1...10,
                    step: 1
                )
                .disabled(!engineBinding.wrappedValue.supportsPitch)
                if engineBinding.wrappedValue.supportsPitch {
                    Text("The system voice's pitch. 1.0 is its natural tone; higher sounds brighter, lower sounds deeper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The selected engine doesn't support a pitch override; speech plays at the provider's natural pitch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Preview — shares the card coordinator so voice tests and preview
            // can't play at the same time.
            SpeakPreviewRow(settings: settings, coordinator: coordinator, licenseGate: licenseGate)

            // Shortcut
            ShortcutRecorderRow(
                actionID: .speak,
                settings: settings,
                recordingID: $recordingID
            )
            } // end VStack(spacing: 16)
        }
        .onAppear {
            // Seed isModelCustom from the persisted model value so existing
            // custom models show the text field on load.
            for k in TTSProviderKind.implemented {
                let curated = k.curatedModels
                guard !curated.isEmpty else { continue }
                let storedModel = settings.ttsConfig(for: k).model ?? k.defaultModel ?? ""
                isModelCustom[k.keychainAccount] = !curated.contains(storedModel)
            }
        }
        .onChange(of: coordinator.phase) { phase in
            if phase == .idle { activeVoicePreviewID = nil }
        }
        .onDisappear {
            coordinator.stop()
        }
    }

}

// MARK: - SpeakPreviewRow

/// A row in the Speak card that lets the user preview the currently configured
/// engine, voice, and accent on an editable sample sentence.
///
/// Takes an injected `SpeakCoordinator` from `SpeakCardView` so voice test
/// buttons and the preview button share a single coordinator (only one plays
/// at a time; `SpeakCoordinator.speak()` calls `stop()` first).
private struct SpeakPreviewRow: View {

    @ObservedObject var settings: SettingsStore
    @ObservedObject var coordinator: SpeakCoordinator
    @ObservedObject var licenseGate: LicenseGate
    @State private var sampleText: String

    init(settings: SettingsStore, coordinator: SpeakCoordinator, licenseGate: LicenseGate) {
        self.settings = settings
        self.coordinator = coordinator
        self.licenseGate = licenseGate
        _sampleText = State(initialValue: settings.speakSettings.defaultAccent.previewSample)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview")

            TextField("Sample text", text: $sampleText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                if coordinator.phase == .idle {
                    Button {
                        play()
                    } label: {
                        Label("Preview", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        coordinator.stop()
                    } label: {
                        HStack(spacing: 4) {
                            // While loading, the spinner replaces the stop icon
                            // inside the button (no separate leading spinner).
                            if coordinator.phase == .loading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "stop.fill")
                            }
                            Text("Stop")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if coordinator.didFallBackToSystem && coordinator.phase != .idle {
                Text("Cloud voice unavailable — previewing with the System voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: settings.speakSettings.defaultAccent) { newAccent in
            sampleText = newAccent.previewSample
        }
        // Lifecycle of the shared coordinator is owned by SpeakCardView, which
        // stops it on its own .onDisappear — don't stop the injected one here.
    }

    private func play() {
        let s = settings.speakSettings
            .resolvingCloudGate(cloudAllowed: licenseGate.entitlements.cloudTTSPremiumAllowed)
        let accent = s.defaultAccent
        let ttsConfig: TTSProviderConfig
        if case .cloud(let kind) = s.selectedEngine {
            ttsConfig = settings.ttsConfig(for: kind)
        } else {
            ttsConfig = .default
        }
        coordinator.speak(sampleText, accent: accent, settings: s, ttsConfig: ttsConfig)
    }
}

// MARK: - Speak slider helpers (file scope — shared by SpeakCardView and CustomSpeechFields)

private let speakSpeedMin = AVSpeechUtteranceMinimumSpeechRate
private let speakSpeedDefault = AVSpeechUtteranceDefaultSpeechRate
private let speakSpeedMax = AVSpeechUtteranceMaximumSpeechRate

/// Maps slider level 1...10 to a system `AVSpeechUtterance` rate. Level 5 is
/// pinned to `AVSpeechUtteranceDefaultSpeechRate` so the slider's midpoint is
/// the natural speaking rate. Below 5 the rate scales linearly to
/// `AVSpeechUtteranceMinimumSpeechRate`; above 5 it scales linearly to
/// `AVSpeechUtteranceMaximumSpeechRate`.
private func speakRate(forLevel level: Int) -> Float {
    let l = min(max(level, 1), 10)
    if l <= 5 {
        return speakSpeedMin + Float(l - 1) / 4 * (speakSpeedDefault - speakSpeedMin)
    } else {
        return speakSpeedDefault + Float(l - 5) / 5 * (speakSpeedMax - speakSpeedDefault)
    }
}

/// Inverse of `speakRate(forLevel:)`: maps a system rate back to slider level
/// 1...10, rounding to the nearest level.
private func speakLevel(forRate rate: Float) -> Int {
    let raw: Float
    if rate <= speakSpeedDefault {
        raw = ((rate - speakSpeedMin) / (speakSpeedDefault - speakSpeedMin)) * 4 + 1
    } else {
        raw = ((rate - speakSpeedDefault) / (speakSpeedMax - speakSpeedDefault)) * 5 + 5
    }
    return min(max(Int(raw.rounded()), 1), 10)
}

private func speakPitch(forLevel level: Int) -> Float {
    0.5 + Float(level - 1) / 9 * 1.5
}

private func speakLevel(forPitch pitch: Float) -> Int {
    let raw = Int((((pitch - 0.5) / 1.5) * 9).rounded()) + 1
    return min(max(raw, 1), 10)
}

// MARK: - CustomSpeechFields

/// Speech-type fields for a custom action card.
///
/// Owns the `SpeakCoordinator` for the preview row. Every write goes through
/// `settings.updateCustomAction(_:)` using a copy-mutate-store pattern, because
/// `action` is a value type fetched from `settings.customActions`.
private struct CustomSpeechFields: View {

    let actionID: UUID
    @ObservedObject var settings: SettingsStore
    @ObservedObject var licenseGate: LicenseGate
    var onUpgrade: () -> Void = {}

    @StateObject private var coordinator: SpeakCoordinator

    // Cloud model custom-entry flag — keyed by TTSProviderKind.keychainAccount.
    @State private var isModelCustom: [String: Bool] = [:]
    // Shared active-row ID for voice-test buttons; nil = none playing.
    @State private var activeVoicePreviewID: String? = nil

    init(
        actionID: UUID,
        settings: SettingsStore,
        keychain: KeychainManager,
        licenseGate: LicenseGate,
        onUpgrade: @escaping () -> Void = {}
    ) {
        self.actionID = actionID
        self.settings = settings
        self.licenseGate = licenseGate
        self.onUpgrade = onUpgrade
        _coordinator = StateObject(wrappedValue: SpeakCoordinator(keychain: keychain))
    }

    // MARK: - Helpers

    /// Returns the current action from the store, or nil when it has been deleted.
    private func currentAction() -> CustomAction? {
        settings.customActions.first(where: { $0.id == actionID })
    }

    /// Mutates the custom action via a closure and persists the update.
    private func mutate(_ body: (inout CustomAction) -> Void) {
        guard var action = currentAction() else { return }
        body(&action)
        settings.updateCustomAction(action)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let cloudAllowed = licenseGate.entitlements.cloudTTSPremiumAllowed
            let speakSettings = currentAction()?.speakSettings ?? .default
            let ttsConfig = currentAction()?.ttsConfig ?? .default

            // Engine picker: System + cloud options (Pro-gated).
            let engineBinding = Binding<SpeakEngineSelection>(
                get: {
                    let engine = (currentAction()?.speakSettings ?? .default).selectedEngine
                    if case .cloud = engine, !cloudAllowed { return .system }
                    return engine
                },
                set: { newEngine in
                    guard cloudAllowed || newEngine == .system else { return }
                    mutate { $0.speakSettings.selectedEngine = newEngine }
                }
            )
            LabeledContent("Speech engine") {
                Picker("", selection: engineBinding) {
                    Text(SpeakEngineSelection.system.displayName).tag(SpeakEngineSelection.system)
                    Divider()
                    ForEach(TTSProviderKind.implemented.map { SpeakEngineSelection.cloud($0) }) { engine in
                        HStack(spacing: 4) {
                            Text(engine.displayName)
                            if !cloudAllowed { ProBadge() }
                        }
                        .tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            if !cloudAllowed {
                UpgradePromptView(
                    message: "Cloud TTS voices (OpenAI, Google, Azure) require a Pro plan. System voice remains available for free.",
                    onUpgrade: onUpgrade
                )
            }
            if case .cloud = engineBinding.wrappedValue {
                Text("Falls back to the System voice when the cloud key is missing or offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Cloud Model / Voice rows — shown only when a cloud engine is selected.
            if case .cloud(let kind) = engineBinding.wrappedValue {
                let keyAccount = kind.keychainAccount

                // Model row — only for providers that expose a user-facing model selector.
                if kind.usesModel {
                    HStack(spacing: 8) {
                        Text("Model")
                        let curated = kind.curatedModels
                        let modelBinding = Binding<String>(
                            get: { ttsConfig.model ?? kind.defaultModel ?? "" },
                            set: { newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                var config = currentAction()?.ttsConfig ?? .default
                                config.model = trimmed.isEmpty ? nil : newValue
                                let effectiveModel = trimmed.isEmpty ? (kind.defaultModel ?? "") : trimmed
                                config = config.clearingInvalidDefaultVoice(
                                    forModel: effectiveModel,
                                    validVoices: kind.curatedVoices(forModel: effectiveModel)
                                )
                                mutate { $0.ttsConfig = config }
                            }
                        )
                        if curated.isEmpty {
                            TextField(kind.defaultModel ?? "model identifier", text: modelBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                        } else {
                            let pickerBinding = Binding<String>(
                                get: {
                                    if isModelCustom[keyAccount] ?? false { return "__custom__" }
                                    let effective = ttsConfig.model ?? kind.defaultModel ?? ""
                                    return curated.contains(effective) ? effective : "__custom__"
                                },
                                set: { newValue in
                                    if newValue == "__custom__" {
                                        isModelCustom[keyAccount] = true
                                    } else {
                                        isModelCustom[keyAccount] = false
                                        var config = currentAction()?.ttsConfig ?? .default
                                        config.model = newValue
                                        config = config.clearingInvalidDefaultVoice(
                                            forModel: newValue,
                                            validVoices: kind.curatedVoices(forModel: newValue)
                                        )
                                        mutate { $0.ttsConfig = config }
                                    }
                                }
                            )
                            HStack(spacing: 6) {
                                Picker("", selection: pickerBinding) {
                                    ForEach(curated, id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    Divider()
                                    Text("Custom…").tag("__custom__")
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .fixedSize()

                                if isModelCustom[keyAccount] ?? false {
                                    TextField(kind.defaultModel ?? "model identifier", text: modelBinding)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 200)
                                }
                            }
                        }
                    }
                }

                // Single Voice row — for providers with a model-level voice list (OpenAI).
                let currentModel = ttsConfig.model ?? kind.defaultModel ?? ""
                let modelVoices = kind.curatedVoices(forModel: currentModel)
                if !modelVoices.isEmpty {
                    HStack(spacing: 8) {
                        Text("Voice")
                        let voiceBinding = Binding<String?>(
                            get: { ttsConfig.defaultVoice },
                            set: { newVoice in
                                var config = currentAction()?.ttsConfig ?? .default
                                config.defaultVoice = newVoice
                                mutate { $0.ttsConfig = config }
                            }
                        )
                        Picker("", selection: voiceBinding) {
                            Text("Default (alloy)").tag(nil as String?)
                            ForEach(modelVoices, id: \.self) { voice in
                                if voice == "marin" || voice == "cedar" {
                                    Text("\(voice) — recommended").tag(voice as String?)
                                } else {
                                    Text(voice).tag(voice as String?)
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        VoiceTestButton(
                            kind: kind,
                            languageCode: speakSettings.defaultAccent.bcp47,
                            rowID: "\(actionID.uuidString):\(kind.rawValue):voice",
                            cloudAllowed: cloudAllowed,
                            settings: settings,
                            coordinator: coordinator,
                            activeID: $activeVoicePreviewID,
                            ttsConfigOverride: ttsConfig
                        )
                    }
                }
            }

            // Default Accent picker.
            LabeledContent("Default Accent") {
                Picker("", selection: Binding(
                    get: { speakSettings.defaultAccent },
                    set: { newAccent in
                        mutate {
                            if newAccent != $0.speakSettings.defaultAccent {
                                $0.speakSettings.defaultVoiceID = nil
                            }
                            $0.speakSettings.defaultAccent = newAccent
                        }
                    }
                )) {
                    ForEach(SpeakAccent.allCases) { accent in
                        Text(accent.displayName).tag(accent)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            // Speed slider.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(speakLevel(forRate: speakSettings.rate)) / 10")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(speakLevel(forRate: (currentAction()?.speakSettings ?? .default).rate)) },
                        set: { newLevel in mutate { $0.speakSettings.rate = speakRate(forLevel: Int(newLevel)) } }
                    ),
                    in: 1...10,
                    step: 1
                )
                .disabled(!engineBinding.wrappedValue.supportsSpeed)
                if engineBinding.wrappedValue.supportsSpeed {
                    Text("How fast the system voice speaks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The selected engine doesn't support a speed override; speech plays at the provider's default rate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Pitch slider.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pitch")
                    Spacer()
                    Text("\(speakLevel(forPitch: speakSettings.pitch)) / 10")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(speakLevel(forPitch: (currentAction()?.speakSettings ?? .default).pitch)) },
                        set: { newLevel in mutate { $0.speakSettings.pitch = speakPitch(forLevel: Int(newLevel)) } }
                    ),
                    in: 1...10,
                    step: 1
                )
                .disabled(!engineBinding.wrappedValue.supportsPitch)
                if engineBinding.wrappedValue.supportsPitch {
                    Text("The system voice's pitch. 1.0 is its natural tone; higher sounds brighter, lower sounds deeper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The selected engine doesn't support a pitch override; speech plays at the provider's natural pitch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Preview row.
            CustomSpeechPreviewRow(
                actionID: actionID,
                settings: settings,
                coordinator: coordinator,
                licenseGate: licenseGate
            )
        }
        .onAppear {
            // Seed isModelCustom from the persisted ttsConfig value.
            let config = currentAction()?.ttsConfig ?? .default
            for k in TTSProviderKind.implemented {
                let curated = k.curatedModels
                guard !curated.isEmpty else { continue }
                let storedModel = config.model ?? k.defaultModel ?? ""
                isModelCustom[k.keychainAccount] = !curated.contains(storedModel)
            }
        }
        .onChange(of: coordinator.phase) { phase in
            if phase == .idle { activeVoicePreviewID = nil }
        }
        .onDisappear {
            coordinator.stop()
        }
    }
}

// MARK: - DraftSpeechFields

/// Speech fields for the New/Edit Action modal.
///
/// Binding-based counterpart to `CustomSpeechFields` (which routes all writes
/// through the SettingsStore). Here every write goes directly to the caller's
/// `@State draft`, so no store is involved.
///
/// Owns a `@StateObject SpeakCoordinator` for the preview row; must be a
/// separate view type so the coordinator is not re-created on type-switch.
struct DraftSpeechFields: View {

    @Binding var speakSettings: SpeakSettings
    @Binding var ttsConfig: TTSProviderConfig
    @ObservedObject var settings: SettingsStore
    let keychain: KeychainManager
    @ObservedObject var licenseGate: LicenseGate
    var onUpgrade: () -> Void = {}

    @StateObject private var coordinator: SpeakCoordinator

    // Cloud model custom-entry flag — keyed by TTSProviderKind.keychainAccount.
    @State private var isModelCustom: [String: Bool] = [:]
    // Shared active-row ID for voice-test buttons; nil = none playing.
    @State private var activeVoicePreviewID: String? = nil

    init(
        speakSettings: Binding<SpeakSettings>,
        ttsConfig: Binding<TTSProviderConfig>,
        settings: SettingsStore,
        keychain: KeychainManager,
        licenseGate: LicenseGate,
        onUpgrade: @escaping () -> Void = {}
    ) {
        _speakSettings = speakSettings
        _ttsConfig = ttsConfig
        self.settings = settings
        self.keychain = keychain
        self.licenseGate = licenseGate
        self.onUpgrade = onUpgrade
        _coordinator = StateObject(wrappedValue: SpeakCoordinator(keychain: keychain))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let cloudAllowed = licenseGate.entitlements.cloudTTSPremiumAllowed

            // Engine picker: System + cloud options (Pro-gated).
            let engineBinding = Binding<SpeakEngineSelection>(
                get: {
                    let engine = speakSettings.selectedEngine
                    if case .cloud = engine, !cloudAllowed { return .system }
                    return engine
                },
                set: { newEngine in
                    guard cloudAllowed || newEngine == .system else { return }
                    speakSettings.selectedEngine = newEngine
                }
            )
            LabeledContent("Speech engine") {
                Picker("", selection: engineBinding) {
                    Text(SpeakEngineSelection.system.displayName).tag(SpeakEngineSelection.system)
                    Divider()
                    ForEach(TTSProviderKind.implemented.map { SpeakEngineSelection.cloud($0) }) { engine in
                        HStack(spacing: 4) {
                            Text(engine.displayName)
                            if !cloudAllowed { ProBadge() }
                        }
                        .tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            if !cloudAllowed {
                UpgradePromptView(
                    message: "Cloud TTS voices (OpenAI, Google, Azure) require a Pro plan. System voice remains available for free.",
                    onUpgrade: onUpgrade
                )
            }
            if case .cloud = engineBinding.wrappedValue {
                Text("Falls back to the System voice when the cloud key is missing or offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Cloud Model / Voice rows — shown only when a cloud engine is selected.
            if case .cloud(let kind) = engineBinding.wrappedValue {
                let keyAccount = kind.keychainAccount

                // Model row — only for providers that expose a user-facing model selector.
                if kind.usesModel {
                    HStack(spacing: 8) {
                        Text("Model")
                        let curated = kind.curatedModels
                        let modelBinding = Binding<String>(
                            get: { ttsConfig.model ?? kind.defaultModel ?? "" },
                            set: { newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                ttsConfig.model = trimmed.isEmpty ? nil : newValue
                                let effectiveModel = trimmed.isEmpty ? (kind.defaultModel ?? "") : trimmed
                                ttsConfig = ttsConfig.clearingInvalidDefaultVoice(
                                    forModel: effectiveModel,
                                    validVoices: kind.curatedVoices(forModel: effectiveModel)
                                )
                            }
                        )
                        if curated.isEmpty {
                            TextField(kind.defaultModel ?? "model identifier", text: modelBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                        } else {
                            let pickerBinding = Binding<String>(
                                get: {
                                    if isModelCustom[keyAccount] ?? false { return "__custom__" }
                                    let effective = ttsConfig.model ?? kind.defaultModel ?? ""
                                    return curated.contains(effective) ? effective : "__custom__"
                                },
                                set: { newValue in
                                    if newValue == "__custom__" {
                                        isModelCustom[keyAccount] = true
                                    } else {
                                        isModelCustom[keyAccount] = false
                                        ttsConfig.model = newValue
                                        ttsConfig = ttsConfig.clearingInvalidDefaultVoice(
                                            forModel: newValue,
                                            validVoices: kind.curatedVoices(forModel: newValue)
                                        )
                                    }
                                }
                            )
                            HStack(spacing: 6) {
                                Picker("", selection: pickerBinding) {
                                    ForEach(curated, id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    Divider()
                                    Text("Custom…").tag("__custom__")
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .fixedSize()

                                if isModelCustom[keyAccount] ?? false {
                                    TextField(kind.defaultModel ?? "model identifier", text: modelBinding)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 200)
                                }
                            }
                        }
                    }
                }

                // Single Voice row — for providers with a model-level voice list (OpenAI).
                let currentModel = ttsConfig.model ?? kind.defaultModel ?? ""
                let modelVoices = kind.curatedVoices(forModel: currentModel)
                if !modelVoices.isEmpty {
                    HStack(spacing: 8) {
                        Text("Voice")
                        let voiceBinding = Binding<String?>(
                            get: { ttsConfig.defaultVoice },
                            set: { newVoice in ttsConfig.defaultVoice = newVoice }
                        )
                        Picker("", selection: voiceBinding) {
                            Text("Default (alloy)").tag(nil as String?)
                            ForEach(modelVoices, id: \.self) { voice in
                                if voice == "marin" || voice == "cedar" {
                                    Text("\(voice) — recommended").tag(voice as String?)
                                } else {
                                    Text(voice).tag(voice as String?)
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        VoiceTestButton(
                            kind: kind,
                            languageCode: speakSettings.defaultAccent.bcp47,
                            rowID: "draft:\(kind.rawValue):voice",
                            cloudAllowed: cloudAllowed,
                            settings: settings,
                            coordinator: coordinator,
                            activeID: $activeVoicePreviewID,
                            ttsConfigOverride: ttsConfig
                        )
                    }
                }
            }

            // Default Accent picker.
            LabeledContent("Default Accent") {
                Picker("", selection: Binding(
                    get: { speakSettings.defaultAccent },
                    set: { newAccent in
                        if newAccent != speakSettings.defaultAccent {
                            speakSettings.defaultVoiceID = nil
                        }
                        speakSettings.defaultAccent = newAccent
                    }
                )) {
                    ForEach(SpeakAccent.allCases) { accent in
                        Text(accent.displayName).tag(accent)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            // Speed slider.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(speakLevel(forRate: speakSettings.rate)) / 10")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(speakLevel(forRate: speakSettings.rate)) },
                        set: { newLevel in speakSettings.rate = speakRate(forLevel: Int(newLevel)) }
                    ),
                    in: 1...10,
                    step: 1
                )
                .disabled(!engineBinding.wrappedValue.supportsSpeed)
                if engineBinding.wrappedValue.supportsSpeed {
                    Text("How fast the system voice speaks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The selected engine doesn't support a speed override; speech plays at the provider's default rate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Pitch slider.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pitch")
                    Spacer()
                    Text("\(speakLevel(forPitch: speakSettings.pitch)) / 10")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(speakLevel(forPitch: speakSettings.pitch)) },
                        set: { newLevel in speakSettings.pitch = speakPitch(forLevel: Int(newLevel)) }
                    ),
                    in: 1...10,
                    step: 1
                )
                .disabled(!engineBinding.wrappedValue.supportsPitch)
                if engineBinding.wrappedValue.supportsPitch {
                    Text("The system voice's pitch. 1.0 is its natural tone; higher sounds brighter, lower sounds deeper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The selected engine doesn't support a pitch override; speech plays at the provider's natural pitch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Preview row.
            DraftSpeechPreviewRow(
                speakSettings: speakSettings,
                ttsConfig: ttsConfig,
                coordinator: coordinator,
                cloudAllowed: cloudAllowed
            )
        }
        .onAppear {
            // Seed isModelCustom from the draft ttsConfig value.
            for k in TTSProviderKind.implemented {
                let curated = k.curatedModels
                guard !curated.isEmpty else { continue }
                let storedModel = ttsConfig.model ?? k.defaultModel ?? ""
                isModelCustom[k.keychainAccount] = !curated.contains(storedModel)
            }
        }
        .onChange(of: coordinator.phase) { phase in
            if phase == .idle { activeVoicePreviewID = nil }
        }
        .onDisappear {
            coordinator.stop()
        }
    }
}

// MARK: - DraftSpeechPreviewRow

/// Preview row for draft speech actions (modal).
///
/// Reads from the binding values passed directly (not the store), so it
/// works on the `@State draft` in `CustomActionEditSheet`.
private struct DraftSpeechPreviewRow: View {

    let speakSettings: SpeakSettings
    let ttsConfig: TTSProviderConfig
    @ObservedObject var coordinator: SpeakCoordinator
    let cloudAllowed: Bool
    @State private var sampleText: String

    init(
        speakSettings: SpeakSettings,
        ttsConfig: TTSProviderConfig,
        coordinator: SpeakCoordinator,
        cloudAllowed: Bool
    ) {
        self.speakSettings = speakSettings
        self.ttsConfig = ttsConfig
        self.coordinator = coordinator
        self.cloudAllowed = cloudAllowed
        _sampleText = State(initialValue: speakSettings.defaultAccent.previewSample)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview")

            TextField("Sample text", text: $sampleText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                if coordinator.phase == .idle {
                    Button {
                        play()
                    } label: {
                        Label("Preview", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        coordinator.stop()
                    } label: {
                        HStack(spacing: 4) {
                            if coordinator.phase == .loading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "stop.fill")
                            }
                            Text("Stop")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if coordinator.didFallBackToSystem && coordinator.phase != .idle {
                Text("Cloud voice unavailable — previewing with the System voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: speakSettings.defaultAccent) { newAccent in
            sampleText = newAccent.previewSample
        }
    }

    private func play() {
        let gated = speakSettings.resolvingCloudGate(cloudAllowed: cloudAllowed)
        let accent = gated.defaultAccent
        let resolvedConfig: TTSProviderConfig
        if case .cloud = gated.selectedEngine {
            resolvedConfig = ttsConfig
        } else {
            resolvedConfig = .default
        }
        coordinator.speak(sampleText, accent: accent, settings: gated, ttsConfig: resolvedConfig)
    }
}

// MARK: - CustomSpeechPreviewRow

/// Preview row for speech-type custom actions.
///
/// Parallel to SpeakPreviewRow but reads from the custom action's own
/// `speakSettings` / `ttsConfig` instead of the global speak settings.
private struct CustomSpeechPreviewRow: View {

    let actionID: UUID
    @ObservedObject var settings: SettingsStore
    @ObservedObject var coordinator: SpeakCoordinator
    @ObservedObject var licenseGate: LicenseGate
    @State private var sampleText: String

    init(actionID: UUID, settings: SettingsStore, coordinator: SpeakCoordinator, licenseGate: LicenseGate) {
        self.actionID = actionID
        self.settings = settings
        self.coordinator = coordinator
        self.licenseGate = licenseGate
        let speakSettings = settings.customActions.first(where: { $0.id == actionID })?.speakSettings ?? .default
        _sampleText = State(initialValue: speakSettings.defaultAccent.previewSample)
    }

    var body: some View {
        let speakSettings = settings.customActions.first(where: { $0.id == actionID })?.speakSettings ?? .default

        VStack(alignment: .leading, spacing: 4) {
            Text("Preview")

            TextField("Sample text", text: $sampleText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                if coordinator.phase == .idle {
                    Button {
                        play(speakSettings: speakSettings)
                    } label: {
                        Label("Preview", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        coordinator.stop()
                    } label: {
                        HStack(spacing: 4) {
                            if coordinator.phase == .loading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "stop.fill")
                            }
                            Text("Stop")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if coordinator.didFallBackToSystem && coordinator.phase != .idle {
                Text("Cloud voice unavailable — previewing with the System voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: speakSettings.defaultAccent) { newAccent in
            sampleText = newAccent.previewSample
        }
    }

    private func play(speakSettings: SpeakSettings) {
        let gated = speakSettings.resolvingCloudGate(
            cloudAllowed: licenseGate.entitlements.cloudTTSPremiumAllowed
        )
        let accent = gated.defaultAccent
        let ttsConfig: TTSProviderConfig
        if case .cloud = gated.selectedEngine,
           let action = settings.customActions.first(where: { $0.id == actionID }) {
            ttsConfig = action.ttsConfig
        } else {
            ttsConfig = .default
        }
        coordinator.speak(sampleText, accent: accent, settings: gated, ttsConfig: ttsConfig)
    }
}

// MARK: - SnippetInputSheet

/// A sheet where the user pastes a PopClip snippet (YAML/JSON/#popclip format).
///
/// Calls `onSubmit` with the raw text; parsing happens in the caller.
/// Calls `onCancel` when the user dismisses without submitting.
private struct SnippetInputSheet: View {

    @Binding var snippetText: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste PopClip Snippet")
                .font(.headline)
            Text("Paste a PopClip snippet in YAML, JSON, or the #popclip header format.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $snippetText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Import\u{2026}") {
                    let trimmed = snippetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSubmit(trimmed)
                }
                .buttonStyle(.borderedProminent)
                .disabled(snippetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
    }
}
