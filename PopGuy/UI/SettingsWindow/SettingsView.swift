// SettingsView.swift
// PopGuy — UI/SettingsWindow
//
// SwiftUI settings window for PopGuy.
//
// Sections:
//   • Actions: per-action provider and model selection
//   • API Keys: SecureField per provider (writes to KeychainManager)
//   • Ollama: base URL configuration
//   • Translate: default target language
//
// HARD CONSTRAINT: API keys are NEVER stored in SettingsStore / UserDefaults.
// They are written to KeychainManager on commit. The full key is NEVER rendered
// back nor loaded into editable state — only a masked, non-recoverable preview
// (e.g. "sk-proj-sDvg…aoW2WRL8sA") is shown as a reminder of which key is saved.
//
// Isolation: @MainActor throughout (all views are implicitly @MainActor by
// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor). KeychainManager is nonisolated/
// Sendable so it can be called directly from @MainActor view code.

import AppKit
import Combine
import os
import SwiftUI
import UniformTypeIdentifiers

// MARK: - SettingsView

/// Drives the selected Settings sidebar section from outside the view, so the
/// menu bar (or any caller) can open the window on a specific tab — even when
/// the window already exists and is being re-shown.
@MainActor
final class SettingsNavigator: ObservableObject {
    @Published var section: SettingsSection = .general

    /// When non-nil, ActionsView will trigger a plugin import flow for this URL.
    /// Set by AppDelegate when a .popclipext or .json file is opened via Finder
    /// (double-click or drag). Cleared by ActionsView after it has consumed it.
    @Published var pendingPluginImportURL: URL? = nil
}

/// The selectable sections of the Settings window sidebar.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case providers
    case actions
    case history
    case triggers
    case appearance
    case ignoredApps
    case license
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:     return "General"
        case .providers:   return "Providers"
        case .actions:     return "Actions"
        case .history:     return "History"
        case .triggers:    return "Triggers"
        case .appearance:  return "Appearance"
        case .ignoredApps: return "Ignore"
        case .license:     return "License"
        case .about:       return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:     return "gearshape"
        case .providers:   return "key"
        case .actions:     return "wand.and.stars"
        case .history:     return "clock.arrow.circlepath"
        case .triggers:    return "cursorarrow.rays"
        case .appearance:  return "paintbrush"
        case .ignoredApps: return "app.badge"
        case .license:     return "checkmark.seal"
        case .about:       return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let keychain: KeychainManager
    let history: HistoryStore
    @ObservedObject var navigator: SettingsNavigator
    @ObservedObject var licenseGate: LicenseGate
    @ObservedObject var updater: UpdaterController

    /// Local mirror of the selected section that `List(selection:)` binds to.
    /// Binding the list directly to the `@Published` `navigator.section` trips
    /// "Publishing changes from within view updates" because the list writes the
    /// selection back during the SwiftUI update pass. Driving a local `@State`
    /// instead keeps the highlight instant, and the navigator is updated from
    /// `.onChange` (which runs after the update pass). Synced both ways so
    /// external navigation (e.g. opening Settings on a specific tab) still works.
    @State private var selectedSection: SettingsSection? = .general

    /// When non-nil, the Add/Edit Action panel slides in from the right edge
    /// over the whole window. Lifted here (not in ActionsView) so the panel can
    /// cover the sidebar list and footer. Set by ActionsView via a binding.
    @State private var editingAction: CustomAction?

    /// When true, the Action Library gallery panel slides in from the right edge,
    /// matching the Add/Edit Action panel. Lifted here (not in ActionsView) so it
    /// covers the whole window. Set by ActionsView's "Browse Library" button.
    @State private var showingLibrary = false

    private static let galleryLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PopGuy", category: "action-library")

    /// Drives the "toolbar action limit reached" alert raised when saving an
    /// action would exceed the active-toolbar cap (mirrors ActionsView's own).
    @State private var showSaveLimitAlert = false

    /// Shared slide animation for the Action panel (open and dismiss).
    private let panelAnimation: Animation = .easeInOut(duration: 0.28)

    /// Live window width, read from the main content, used to size the slide-over
    /// panel at 2/3 of the window.
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        // A plain fixed-width left column instead of NavigationSplitView:
        // the built-in sidebar can be collapsed by dragging (with no way to
        // bring it back) and offsets the window title by the sidebar width.
        // A normal column avoids both and stays fixed.
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $selectedSection) {
                    ForEach(SettingsSection.allCases) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .padding(.vertical, SettingsMetrics.sidebarItemVerticalPadding)
                            .tag(section)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 160)
                // Push genuine user selections to the navigator AFTER the update
                // pass (deselection falls back to Providers).
                .onChange(of: selectedSection) { newValue in
                    let resolved = newValue ?? .general
                    if navigator.section != resolved { navigator.section = resolved }
                }
                // Sync external navigation back into the list highlight.
                .onChange(of: navigator.section) { newValue in
                    if selectedSection != newValue { selectedSection = newValue }
                }
                .onAppear { selectedSection = navigator.section }

                VStack(spacing: 0) {
                    if updater.updateAvailable {
                        UpdateBanner(version: updater.pendingVersion) {
                            updater.checkForUpdates()
                        }
                    }
                    detailView(for: navigator.section)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            SettingsFooter(updater: updater, licenseGate: licenseGate)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Track the window width so the slide-over panel can size itself to 2/3.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { newWidth in containerWidth = newWidth }
            }
        )

            // Blurred backdrop over the rest of the window behind the panel.
            // Tap to dismiss, mirroring a modal's click-outside.
            if editingAction != nil {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(panelAnimation) { editingAction = nil }
                    }
                    .zIndex(1)
            }

            // Add/Edit Action panel — slides in from the right edge as a 2/3-width
            // slide-over (replaces the former modal sheet so the form gets a smooth
            // slide animation). The background ignores the top safe area to fill
            // behind the transparent titlebar, while the form content respects it
            // so the header clears the traffic lights.
            if let action = editingAction {
                CustomActionEditSheet(
                    action: action,
                    settings: settings,
                    keychain: keychain,
                    licenseGate: licenseGate,
                    onUpgrade: { navigator.section = .license },
                    onSave: { saved in
                        let clamped: Bool
                        if settings.customActions.contains(where: { $0.id == saved.id }) {
                            clamped = settings.updateCustomAction(saved)
                        } else {
                            clamped = settings.addCustomAction(saved)
                        }
                        if clamped { showSaveLimitAlert = true }
                        withAnimation(panelAnimation) { editingAction = nil }
                    },
                    onCancel: {
                        withAnimation(panelAnimation) { editingAction = nil }
                    }
                )
                // Floor at 480 to honour CustomActionEditSheet's own minWidth
                // (avoids horizontal clipping when the window is near its minimum).
                .frame(width: max(containerWidth * 3 / 4, 480))
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
                .shadow(color: .black.opacity(0.22), radius: 12, x: -3, y: 0)
                .transition(.move(edge: .trailing))
                .zIndex(2)
                // Esc dismisses, matching the old modal sheet.
                .onExitCommand {
                    withAnimation(panelAnimation) { editingAction = nil }
                }
            }

            // Blurred backdrop behind the Action Library panel; tap to dismiss.
            if showingLibrary {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(panelAnimation) { showingLibrary = false }
                    }
                    .zIndex(1)
            }

            // Action Library gallery — slides in from the right edge as a 2/3-width
            // slide-over, matching the Add/Edit Action panel. Browsing is free;
            // install routes through sanitizeImported → addCustomAction and counts
            // toward maxCustomActions (the gallery disables Install at the limit).
            if showingLibrary {
                ActionLibraryView(
                    canInstall: settings.customActions.count < licenseGate.entitlements.maxCustomActions,
                    isInstalled: { preset in
                        ActionLibrary.isInstalled(preset, in: settings.customActions)
                    },
                    onInstall: { preset in
                        guard let sanitized = CustomAction.sanitizeImported(
                            preset.make(),
                            cloudAllowed: licenseGate.entitlements.cloudTTSPremiumAllowed
                        ) else {
                            assertionFailure("sanitizeImported returned nil for library preset '\(preset.id)' — the preset violates the import contract")
                            Self.galleryLog.warning("sanitizeImported returned nil for library preset '\(preset.id, privacy: .public)' — preset skipped")
                            return
                        }
                        let clamped = settings.addCustomAction(sanitized)
                        if clamped { showSaveLimitAlert = true }
                    },
                    onClose: {
                        withAnimation(panelAnimation) { showingLibrary = false }
                    }
                )
                // Floor at 560 to honour ActionLibraryView's own minWidth.
                .frame(width: max(containerWidth * 3 / 4, 560))
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
                .shadow(color: .black.opacity(0.22), radius: 12, x: -3, y: 0)
                .transition(.move(edge: .trailing))
                .zIndex(2)
                .onExitCommand {
                    withAnimation(panelAnimation) { showingLibrary = false }
                }
            }
        }
        .frame(minWidth: 680, idealWidth: 740, minHeight: 460, idealHeight: 520)
        .alert("Toolbar Limit Reached", isPresented: $showSaveLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("PopGuy shows at most \(SettingsStore.maxToolbarActions) actions on the toolbar. Turn off another action first.")
        }
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection?) -> some View {
        let section = section ?? .general
        // Each tab gets a fixed header pinned to the top; its own ScrollView /
        // Form scrolls in the area below the header divider.
        let navigateToLicense = { navigator.section = .license }
        SettingsTabScaffold(title: section.title, systemImage: section.systemImage) {
            // Build the (heavy) tab content one runloop turn after a loading
            // placeholder paints, so the panel responds to the tab click instantly.
            // `.id(section)` makes every switch a fresh instance — see the type doc.
            DeferredSectionContent {
                switch section {
                case .general:     GeneralView(settings: settings)
                case .providers:   APIKeysTab(settings: settings, keychain: keychain)
                case .actions:     ActionsView(settings: settings, keychain: keychain, licenseGate: licenseGate, onUpgrade: navigateToLicense, navigator: navigator, editingAction: $editingAction, showingLibrary: $showingLibrary)
                case .history:     HistoryView(history: history, settings: settings, licenseGate: licenseGate, onUpgrade: navigateToLicense)
                case .triggers:    TriggersView(settings: settings, licenseGate: licenseGate, onUpgrade: navigateToLicense)
                case .appearance:  AppearanceView(settings: settings)
                case .ignoredApps: AppsView(settings: settings, licenseGate: licenseGate, onUpgrade: navigateToLicense)
                case .license:     LicenseView(licenseGate: licenseGate)
                case .about:       AboutView(updater: updater)
                }
            }
            .id(section)
        }
    }
}

// MARK: - DeferredSectionContent

/// Defers building a settings tab's content until one runloop turn after a
/// lightweight loading placeholder has been presented.
///
/// Switching tabs rebuilds the selected tab's whole view tree synchronously on
/// the main thread (Actions and History are the heaviest — many cards with menu
/// pickers), which otherwise froze the detail panel for up to a second before
/// anything appeared. Painting the spinner first makes the panel respond to the
/// tab click immediately; the indeterminate `ProgressView` keeps animating on
/// the render server even while the main thread builds the real content.
///
/// The caller MUST attach `.id(section)` so each tab switch creates a fresh
/// instance with `ready == false`. Without it the persisted state would stay
/// `true` and build the heavy content on the switch render, skipping the
/// placeholder entirely.
private struct DeferredSectionContent<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var ready = false

    var body: some View {
        Group {
            if ready {
                content()
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // Flip across a runloop turn (the sleep) so the placeholder frame is
            // presented before the heavy content is built on the main thread.
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000)
                ready = true
            }
        }
    }
}

// MARK: - SettingsFooter

/// Formats the footer version label. Extracted as a free function so the
/// version/build formatting is unit-testable.
func formatVersionLabel(version: String, build: String?) -> String {
    if let build, !build.isEmpty {
        return "PopGuy v\(version) (\(build))"
    }
    return "PopGuy v\(version)"
}

/// Formats a trial end date as `dd-MMM-yyyy` with English month abbreviations,
/// rendered in the given timezone (defaults to the user's local timezone).
///
/// Extracted as a free function so it is unit-testable without touching SwiftUI
/// views, and shared by the footer suffix and the License view date display.
///
/// `endDate` carries the user's first-launch time-of-day (it is NOT a
/// midnight-UTC boundary), so the displayed calendar day is rendered in the
/// user's local timezone to match when the trial actually ends for them.
///
/// - Parameters:
///   - endDate:  The trial end date, as computed by `TrialPolicy` (first-launch
///               instant plus `trialDurationMonths` in a UTC Gregorian calendar).
///   - timeZone: The timezone used to resolve the calendar day. Defaults to
///               `.current` (the user's local timezone). Pass an explicit value
///               in tests for determinism.
/// - Returns: A string of the form `"21-Aug-2026"`.
func trialEndDateString(_ endDate: Date, timeZone: TimeZone = .current) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = timeZone
    fmt.dateFormat = "dd-MMM-yyyy"
    return fmt.string(from: endDate)
}

/// Returns the trial-suffix string appended to the footer version label when a
/// free trial is active. Extracted as a free function so it is unit-testable
/// without touching SwiftUI views.
///
/// The end date is rendered in the user's local timezone so the displayed
/// calendar day matches when the trial ends for them (see `trialEndDateString`).
///
/// - Parameter endDate: The trial end date, as computed by `TrialPolicy`.
/// - Returns: A string of the form `" — Trial use until 21-Aug-2026"`.
func trialFooterSuffix(endDate: Date) -> String {
    " — Trial use until \(trialEndDateString(endDate))"
}

/// A full-width footer pinned to the bottom of the Settings window showing the
/// app version, build number, auto-check toggle, check button, author, and GitHub link.
private struct SettingsFooter: View {
    @ObservedObject var updater: UpdaterController
    @ObservedObject var licenseGate: LicenseGate

    /// Marketing version from the bundle (CFBundleShortVersionString).
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Build number from the bundle (CFBundleVersion).
    private var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    private var versionLabel: String {
        var label = formatVersionLabel(version: version, build: build)
        // Append trial suffix only when a trial is active and no paid license is held.
        if case .active(_, let endDate) = licenseGate.trialState,
           licenseGate.activatedKeyMasked == nil {
            label += trialFooterSuffix(endDate: endDate)
        }
        return label
    }

    private static let authorURL = URL(string: "https://dinhanhthi.com")!
    private static let githubURL = URL(string: "https://github.com/dinhanhthi/PopGuy")!

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text(versionLabel)
                    .foregroundStyle(.secondary)

                Button("Check for Updates") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.plain)
                .disabled(!updater.canCheckForUpdates)

                Spacer(minLength: 0)

                Link("Anh-Thi DINH", destination: Self.authorURL)

                Text("·").foregroundStyle(.secondary)

                Link(destination: Self.githubURL) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("GitHub")
                    }
                }
            }
            .font(.caption)
            .padding(.horizontal, SettingsMetrics.pagePadding)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - SettingsTabScaffold

/// Lays out a fixed tab header (icon + title) pinned to the top, a divider, and
/// the caller-supplied scrollable content below. The content view is expected
/// to provide its own ScrollView / Form so it scrolls under the fixed header.
private struct SettingsTabScaffold<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsMetrics.pagePadding)
            .padding(.top, 14)
            .padding(.bottom, 14)

            Divider()

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The window uses .fullSizeContentView, so the detail column is inset
        // from the top by the (transparent) title bar's safe area. Ignore it so
        // the header sits just below the window's top edge — the traffic lights
        // are over the sidebar, not this column.
        .ignoresSafeArea(.container, edges: .top)
    }
}

// MARK: - APIKeysTab

private struct APIKeysTab: View {
    @ObservedObject var settings: SettingsStore
    let keychain: KeychainManager

    // Segmented control: 0 = AI, 1 = Translation, 2 = Speech, 3 = Dictionary.
    @State private var providerCategory: Int = 0

    // Local draft key state — never persisted until the user commits.
    // The real stored key is NEVER read back into these fields.
    @State private var openAIKey:        String = ""
    @State private var anthropicKey:     String = ""
    @State private var deepLKey:         String = ""
    @State private var googleKey:        String = ""
    @State private var geminiKey:        String = ""
    @State private var glmKey:           String = ""
    @State private var openRouterKey:    String = ""
    @State private var customKey:        String = ""

    // Masked preview of the key committed to Keychain (nil when none saved).
    // Set by refreshSavedIndicators() — only the masked form enters state,
    // never the full key. nil doubles as the "no key saved" flag.
    @State private var openAIPreview:      String? = nil
    @State private var anthropicPreview:   String? = nil
    @State private var deepLPreview:       String? = nil
    @State private var googlePreview:      String? = nil
    @State private var geminiPreview:      String? = nil
    @State private var glmPreview:         String? = nil
    @State private var openRouterPreview:  String? = nil
    @State private var customPreview:      String? = nil

    // TTS per-provider draft key state — keyed by TTSProviderKind.keychainAccount (= rawValue).
    // Never persisted; cleared after a successful save.
    @State private var ttsKeyDrafts:   [String: String] = [:]
    // TTS per-provider masked key preview — set by refreshSavedIndicators().
    // nil/absent means no key saved; only the masked form is stored.
    @State private var ttsKeyPreviews: [String: String] = [:]

    // Babylon .bgl import state.
    @State private var isIndexingBGL = false
    @State private var bglImportError: String?

    var body: some View {
        // Custom SettingsCard cards instead of a grouped Form: a grouped Form
        // column-splits every row (first label, control in a trailing column),
        // which prevents the key field from spanning the full row width.
        VStack(spacing: 0) {
            // Fixed segmented header pinned to the top.
            HStack(spacing: 0) {
                CapsuleSegmentedPicker(
                    selection: $providerCategory,
                    segments: [
                        .init(value: 0, label: "AI"),
                        .init(value: 1, label: "Translation"),
                        .init(value: 2, label: "Speech"),
                        .init(value: 3, label: "Dictionary"),
                    ]
                )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsMetrics.pagePadding)
            .padding(.top, SettingsMetrics.pagePadding)
            .padding(.bottom, SettingsMetrics.cardSpacing)

            // Scrollable provider cards.
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    switch providerCategory {
                    case 0:  aiProviderCards
                    case 1:  translationProviderCards
                    case 2:  speechProviderCards
                    default: dictionaryProviderCards
                    }
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, SettingsMetrics.pagePadding)
            }
        }
        .onAppear {
            refreshSavedIndicators()
        }
    }

    // MARK: - AI cards

    @ViewBuilder
    private var aiProviderCards: some View {
        providerCard(.openAI, "OpenAI") {
            KeyEntryRow(
                draft: $openAIKey,
                isSaved: openAIPreview != nil,
                keyPreview: openAIPreview,
                onCommit: { await validateAndSave(openAIKey, for: .openAI) },
                onClear: { clearKey(for: .openAI, draft: &openAIKey) },
                onVerify: { await verifyKey(for: .openAI) }
            )
        }

        providerCard(.anthropic, "Anthropic") {
            KeyEntryRow(
                draft: $anthropicKey,
                isSaved: anthropicPreview != nil,
                keyPreview: anthropicPreview,
                onCommit: { await validateAndSave(anthropicKey, for: .anthropic) },
                onClear: { clearKey(for: .anthropic, draft: &anthropicKey) },
                onVerify: { await verifyKey(for: .anthropic) }
            )
        }

        providerCard(.gemini, ProviderKind.gemini.displayName) {
            KeyEntryRow(
                draft: $geminiKey,
                isSaved: geminiPreview != nil,
                keyPreview: geminiPreview,
                onCommit: { await validateAndSave(geminiKey, for: .gemini) },
                onClear: { clearKey(for: .gemini, draft: &geminiKey) },
                onVerify: { await verifyKey(for: .gemini) }
            )
        }

        providerCard(.glm, ProviderKind.glm.displayName) {
            KeyEntryRow(
                draft: $glmKey,
                isSaved: glmPreview != nil,
                keyPreview: glmPreview,
                onCommit: { await validateAndSave(glmKey, for: .glm) },
                onClear: { clearKey(for: .glm, draft: &glmKey) },
                onVerify: { await verifyKey(for: .glm) }
            )
        }

        providerCard(.openRouter, ProviderKind.openRouter.displayName) {
            KeyEntryRow(
                draft: $openRouterKey,
                isSaved: openRouterPreview != nil,
                keyPreview: openRouterPreview,
                onCommit: { await validateAndSave(openRouterKey, for: .openRouter) },
                onClear: { clearKey(for: .openRouter, draft: &openRouterKey) },
                onVerify: { await verifyKey(for: .openRouter) }
            )
        }

        providerCard(.ollama, "Ollama") {
            HStack(spacing: 8) {
                Text("Base URL")
                TextField("", text: $settings.ollamaBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }
            Text("Ollama does not require an API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        providerCard(.claudeCLI, ProviderKind.claudeCLI.displayName) {
            HStack(spacing: 8) {
                Text("Path")
                TextField("e.g. ~/.local/bin/claude", text: $settings.claudeCLIPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Button("Detect") {
                    let detected = SettingsStore.detectCLIPath("claude")
                    if !detected.isEmpty { settings.claudeCLIPath = detected }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text("Uses your Claude subscription login — no API key needed. Slower than the API providers.")
                .font(.caption)
                .foregroundStyle(.secondary)
            CLIVerifyButton(kind: .claudeCLI, path: settings.claudeCLIPath)
        }

        providerCard(.codexCLI, ProviderKind.codexCLI.displayName) {
            HStack(spacing: 8) {
                Text("Path")
                TextField("e.g. ~/.nvm/versions/node/.../bin/codex", text: $settings.codexCLIPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Button("Detect") {
                    let detected = SettingsStore.detectCLIPath("codex")
                    if !detected.isEmpty { settings.codexCLIPath = detected }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text("Uses your Codex subscription login — no API key needed. Slower than the API providers.")
                .font(.caption)
                .foregroundStyle(.secondary)
            CLIVerifyButton(kind: .codexCLI, path: settings.codexCLIPath)
        }

        providerCard(.geminiCLI, ProviderKind.geminiCLI.displayName) {
            HStack(spacing: 8) {
                Text("Path")
                TextField("e.g. ~/.nvm/versions/node/.../bin/gemini", text: $settings.geminiCLIPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Button("Detect") {
                    let detected = SettingsStore.detectCLIPath("gemini")
                    if !detected.isEmpty { settings.geminiCLIPath = detected }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text("Uses your Gemini subscription login — no API key needed. Slower than the API providers.")
                .font(.caption)
                .foregroundStyle(.secondary)
            CLIVerifyButton(kind: .geminiCLI, path: settings.geminiCLIPath)
        }

        providerCard(.custom, ProviderKind.custom.displayName) {
            HStack(spacing: 8) {
                Text("Base URL")
                InfoTooltip(text: "OpenAI-compatible endpoint for your custom provider, e.g. \"http://localhost:8080/v1\".")
                TextField("http://localhost:8080/v1", text: $settings.customBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }
            KeyEntryRow(
                draft: $customKey,
                isSaved: customPreview != nil,
                keyPreview: customPreview,
                onCommit: { await validateAndSave(customKey, for: .custom) },
                onClear: { clearKey(for: .custom, draft: &customKey) },
                onVerify: { await verifyKey(for: .custom) }
            )
        }
    }

    // MARK: - Translation cards

    @ViewBuilder
    private var translationProviderCards: some View {
        providerCard(.deepL, "DeepL") {
            KeyEntryRow(
                draft: $deepLKey,
                isSaved: deepLPreview != nil,
                keyPreview: deepLPreview,
                onCommit: { await validateAndSave(deepLKey, for: .deepL) },
                onClear: { clearKey(for: .deepL, draft: &deepLKey) },
                onVerify: { await verifyKey(for: .deepL) }
            )
        }

        providerCard(.googleTranslate, "Google Translate") {
            KeyEntryRow(
                draft: $googleKey,
                isSaved: googlePreview != nil,
                keyPreview: googlePreview,
                onCommit: { await validateAndSave(googleKey, for: .googleTranslate) },
                onClear: { clearKey(for: .googleTranslate, draft: &googleKey) },
                onVerify: { await verifyKey(for: .googleTranslate) }
            )
        }
    }

    // MARK: - Speech cards

    @ViewBuilder
    private var speechProviderCards: some View {
        ForEach(TTSProviderKind.implemented) { kind in
            ttsProviderCard(kind)
        }
    }

    // MARK: - Dictionary cards

    @ViewBuilder
    private var dictionaryProviderCards: some View {
        dictionaryInfoCard(
            .macOSBuiltin,
            "Looks up definitions in the dictionaries installed in macOS. Add or remove dictionaries in the macOS Dictionary app."
        )
        dictionaryInfoCard(
            .minhqnd,
            "Online Vietnamese-focused dictionary via dict.minhqnd.com."
        )
        dictionaryInfoCard(
            .freeDictionaryAPI,
            "Online definitions from the Free Dictionary API (Wiktionary-based)."
        )

        SettingsCard(
            title: DictionaryProviderKind.babylonBGL.displayName,
            accessory: {
                Button {
                    loadBGLDictionaries()
                } label: {
                    HStack(spacing: 5) {
                        if isIndexingBGL {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.85)
                                .frame(width: 11, height: 11)
                        } else {
                            Image(systemName: "plus")
                        }
                        Text(isIndexingBGL ? "Indexing" : "Load")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isIndexingBGL)
            },
            titleAccessory: { EmptyView() }
        ) {
            VStack(alignment: .leading, spacing: SettingsMetrics.contentSpacing) {

                if let bglImportError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(bglImportError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if settings.babylonDictionaries.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                            .foregroundStyle(.secondary)
                        Text("No dictionaries loaded")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                } else {
                    VStack(spacing: 8) {
                        ForEach($settings.babylonDictionaries) { $dictionary in
                            BabylonDictionarySettingsRow(dictionary: $dictionary) {
                                removeBGLDictionary(id: dictionary.id)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Description-only card for a dictionary provider that has no user settings yet
    /// (macOS, minhqnd, Free Dictionary API). Shows what it is, its language coverage,
    /// and whether it needs the network.
    @ViewBuilder
    private func dictionaryInfoCard(_ kind: DictionaryProviderKind, _ description: String) -> some View {
        SettingsCard(title: kind.displayName, subtitle: description) {
            HStack(spacing: 6) {
                Image(systemName: kind.requiresNetwork ? "wifi" : "wifi.slash")
                Text(kind.requiresNetwork ? "Requires internet" : "Works offline")
                Spacer(minLength: 8)
                Text(kind.languageHint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func loadBGLDictionaries() {
        guard !isIndexingBGL else { return }

        let panel = NSOpenPanel()
        panel.title = "Load Babylon Dictionaries"
        panel.allowedContentTypes = [UTType(filenameExtension: "bgl") ?? .data]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        guard !paths.isEmpty else { return }

        bglImportError = nil
        isIndexingBGL = true

        Task { @MainActor in
            var loaded: [BabylonDictionary] = []
            var failed: [String] = []

            for path in paths {
                let url = URL(fileURLWithPath: path)
                var dictionary = BabylonDictionary(
                    displayName: url.deletingPathExtension().lastPathComponent,
                    filePath: path
                )

                do {
                    let index = try await BabylonBGLIndexCache.shared.index(for: dictionary)
                    dictionary.entryCount = index.entryCount
                    loaded.append(dictionary)
                } catch {
                    failed.append("\(url.lastPathComponent): \(Self.bglImportMessage(for: error))")
                }
            }

            if !loaded.isEmpty {
                var current = settings.babylonDictionaries
                let loadedPaths = Set(loaded.map(\.filePath))
                let replacedIDs = current
                    .filter { loadedPaths.contains($0.filePath) }
                    .map(\.id)
                current.removeAll { loadedPaths.contains($0.filePath) }
                current.append(contentsOf: loaded)
                settings.babylonDictionaries = current

                for id in replacedIDs {
                    await BabylonBGLIndexCache.shared.remove(id: id)
                }
            }

            bglImportError = failed.isEmpty ? nil : failed.joined(separator: "\n")
            isIndexingBGL = false
        }
    }

    private func removeBGLDictionary(id: UUID) {
        settings.babylonDictionaries.removeAll { $0.id == id }
        Task {
            await BabylonBGLIndexCache.shared.remove(id: id)
        }
    }

    private static func normalizedLanguageCode(_ raw: String, fallback: String) -> String {
        let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "en" : fallback
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let resolved = trimmed.isEmpty ? fallback.lowercased() : trimmed
        return String(resolved.prefix(20))
    }

    private static func bglImportMessage(for error: Error) -> String {
        if let lookupError = error as? DictionaryLookupError {
            switch lookupError {
            case .decoding(let detail):
                return detail
            case .notFound:
                return "No entries found."
            case .network(let underlying):
                return underlying
            case .rateLimited:
                return "Too many requests."
            }
        }
        return error.localizedDescription
    }

    @ViewBuilder
    private func ttsProviderCard(_ kind: TTSProviderKind) -> some View {
        let cardContent = {
            ttsProviderCardContent(kind)
        }
        if let url = kind.apiKeyURL {
            SettingsCard(
                title: kind.displayName,
                accessory: { GetAPIKeyLink(url: url) },
                content: cardContent
            )
        } else {
            SettingsCard(title: kind.displayName, content: cardContent)
        }
    }

    @ViewBuilder
    private func ttsProviderCardContent(_ kind: TTSProviderKind) -> some View {
        // Region row — Azure only. Required before the key can validate.
        if kind.usesRegion {
            HStack(spacing: 8) {
                Text("Region")
                let regionBinding = Binding<String>(
                    get: { settings.ttsConfig(for: kind).region ?? "" },
                    set: { newValue in
                        var config = settings.ttsConfig(for: kind)
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        config.region = trimmed.isEmpty ? nil : trimmed
                        settings.setTTSConfig(config, for: kind)
                    }
                )
                TextField("e.g. eastus", text: regionBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }
            Text("Azure region, e.g. eastus — required.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // API key row — same pattern as AI provider cards.
        let keyAccount = kind.keychainAccount
        KeyEntryRow(
            draft: Binding(
                get: { ttsKeyDrafts[keyAccount] ?? "" },
                set: { ttsKeyDrafts[keyAccount] = $0 }
            ),
            isSaved: ttsKeyPreviews[keyAccount] != nil,
            keyPreview: ttsKeyPreviews[keyAccount],
            onCommit: { await validateAndSaveTTS(ttsKeyDrafts[keyAccount] ?? "", for: kind) },
            onClear: {
                keychain.deleteKey(account: keyAccount)
                ttsKeyDrafts[keyAccount] = ""
                refreshSavedIndicators()
            }
        )

        // Privacy notice.
        Text("Cloud speech sends the selected text to \(kind.displayName)'s servers. The local System voice keeps everything on-device.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// A SettingsCard with the provider's name as the in-card header. Cloud
    /// providers get an external-link button beside the name that opens the
    /// provider's console where the user can obtain an API key.
    @ViewBuilder
    private func providerCard<Content: View>(
        _ kind: ProviderKind,
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if let url = kind.apiKeyURL {
            SettingsCard(
                title: title,
                accessory: { GetAPIKeyLink(url: url) },
                content: content
            )
        } else {
            SettingsCard(title: title, content: content)
        }
    }

    /// Verify the TTS key against the provider, then save it only if it authenticates.
    /// Returns `nil` on success or a user-facing error message on failure.
    private func validateAndSaveTTS(_ key: String, for kind: TTSProviderKind) async -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            try await TTSProviderValidator.validate(kind: kind, apiKey: trimmed, config: settings.ttsConfig(for: kind))
            keychain.setKey(trimmed, account: kind.keychainAccount)
            refreshSavedIndicators()
            return nil
        } catch {
            return Self.validationMessage(for: error)
        }
    }

    /// Verify the key against the provider, then save it only if it authenticates.
    /// Returns `nil` on success or a user-facing error message on failure
    /// (the key is NOT saved when a message is returned).
    private func validateAndSave(_ key: String, for provider: ProviderKind) async -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            try await ProviderKeyValidator.validate(kind: provider, apiKey: trimmed)
            keychain.setKey(trimmed, for: provider)
            refreshSavedIndicators()
            return nil
        } catch {
            return Self.validationMessage(for: error)
        }
    }

    /// Map a validation failure to a user-facing message, distinguishing an
    /// invalid key (401/403) from a network problem (don't claim "invalid").
    private static func validationMessage(for error: Error) -> String {
        // URLSession surfaces connectivity failures as URLError (HTTPClient
        // does not wrap these), so handle them before the ProviderError cases.
        if error is URLError {
            return "Could not connect to the server. Check your network connection and try again."
        }
        // TTS-specific errors (missingRegion, missingAPIKey) surface before any
        // network call and must be handled before the generic ProviderError branch.
        if let ttsError = error as? TTSProviderError {
            switch ttsError {
            case .missingRegion:
                return "Azure region is required — set it above the API key field."
            case .missingAPIKey:
                return "Enter an API key."
            default:
                return "Could not verify your API key. Please try again."
            }
        }
        guard let providerError = error as? ProviderError else {
            return "Could not verify your API key. Please try again."
        }
        switch providerError {
        // The validation request carries only the key (no body), so a
        // 400/401/403 from it means the key was rejected. Google Translate
        // returns 400 (API_KEY_INVALID); the others return 401/403.
        case .httpError(let code, _) where code == 400 || code == 401 || code == 403:
            return "Invalid API key. Please check and try again."
        case .httpError(let code, _):
            return "Could not verify your API key (HTTP \(code))."
        case .transport:
            return "Could not connect to the server. Check your network connection and try again."
        default:
            return "Could not verify your API key. Please try again."
        }
    }

    /// Test an already-saved key against the live provider.
    /// Reads the key from Keychain, resolves the base URL, and maps the
    /// outcome to `VerifyOutcome` for inline feedback in `KeyEntryRow`.
    private func verifyKey(for provider: ProviderKind) async -> VerifyOutcome {
        let savedKey = keychain.key(for: provider)

        // Resolve base URL: Custom requires a configured endpoint; others pass nil.
        let baseURL: URL?
        let customEndpointMissing: Bool
        if provider == .custom {
            let raw = settings.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || URL(string: raw) == nil {
                customEndpointMissing = true
                baseURL = nil
            } else {
                customEndpointMissing = false
                baseURL = URL(string: raw)
            }
        } else {
            customEndpointMissing = false
            baseURL = nil
        }

        // Bail early (via mapping) if no key is saved or endpoint is missing.
        let hasKey = savedKey != nil
        let earlyOutcome = mapVerifyOutcome(error: nil, hasKey: hasKey, customEndpointMissing: customEndpointMissing)
        guard earlyOutcome == .valid else { return earlyOutcome }

        let key = savedKey! // safe: hasKey is true
        do {
            try await ProviderKeyValidator.validate(kind: provider, apiKey: key, baseURL: baseURL)
            return mapVerifyOutcome(error: nil, hasKey: true, customEndpointMissing: false)
        } catch {
            return mapVerifyOutcome(error: error, hasKey: true, customEndpointMissing: false)
        }
    }

    private func clearKey(for provider: ProviderKind, draft: inout String) {
        keychain.deleteKey(for: provider)
        draft = ""
        refreshSavedIndicators()
    }

    private func refreshSavedIndicators() {
        // Read the key only to derive a masked preview; the full key is masked
        // immediately and never stored — only the masked form enters state.
        openAIPreview      = maskedKeyPreview(keychain.key(for: .openAI))
        anthropicPreview   = maskedKeyPreview(keychain.key(for: .anthropic))
        deepLPreview       = maskedKeyPreview(keychain.key(for: .deepL))
        googlePreview      = maskedKeyPreview(keychain.key(for: .googleTranslate))
        geminiPreview      = maskedKeyPreview(keychain.key(for: .gemini))
        glmPreview         = maskedKeyPreview(keychain.key(for: .glm))
        openRouterPreview  = maskedKeyPreview(keychain.key(for: .openRouter))
        customPreview      = maskedKeyPreview(keychain.key(for: .custom))
        // TTS providers — keyed by account string, not ProviderKind.
        for k in TTSProviderKind.implemented {
            ttsKeyPreviews[k.keychainAccount] = maskedKeyPreview(keychain.key(account: k.keychainAccount))
        }
    }
}

// MARK: - BabylonDictionarySettingsRow

private struct BabylonDictionarySettingsRow: View {
    @Binding var dictionary: BabylonDictionary
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dictionary.resolvedDisplayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(dictionary.filePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Toggle("", isOn: $dictionary.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .hoverTooltip("Remove dictionary")
            }

            Text("\(dictionary.entryCount) entries")
                .font(.caption)
                .foregroundStyle(.secondary)

            // User-declared language mapping. The .bgl header does carry source/target
            // language, but PopGuy doesn't read it, so the user fills these in. Stored
            // for later use (e.g. provider routing); empty means unspecified.
            HStack(spacing: 6) {
                Text("Source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("en", text: languageBinding(\.sourceLanguage))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Target")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("vi", text: languageBinding(\.targetLanguage))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
            }

            Text("Language codes (ISO 639 / BCP-47), e.g. en, vi, fr, zh. Leave empty if unsure.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    /// Two-way binding that normalizes a language code as the user types — lower-cased,
    /// `_`→`-`, capped — while allowing empty (the "unspecified" default).
    private func languageBinding(_ keyPath: WritableKeyPath<BabylonDictionary, String>) -> Binding<String> {
        Binding(
            get: { dictionary[keyPath: keyPath] },
            set: { dictionary[keyPath: keyPath] = Self.normalizedLanguageCode($0) }
        )
    }

    private static func normalizedLanguageCode(_ raw: String) -> String {
        String(
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
                .prefix(20)
        )
    }
}

// MARK: - VoiceTestButton

/// Icon-only play/stop button that previews the voice for a single row in the
/// Speech provider cards (OpenAI, Google Cloud TTS, Azure Speech).
///
/// One `VoiceTestButton` per voice row; all rows share a single `SpeakCoordinator`
/// and a single `activeID` binding so only one row plays at a time.
struct VoiceTestButton: View {

    let kind: TTSProviderKind
    let languageCode: String
    /// Unique identifier for this row, e.g. "openai_tts:voice" or "google_cloud_tts:en-US".
    let rowID: String
    let cloudAllowed: Bool
    @ObservedObject var settings: SettingsStore
    @ObservedObject var coordinator: SpeakCoordinator
    @Binding var activeID: String?
    /// When set, overrides the global `settings.ttsConfig(for:)` lookup.
    /// Pass the custom action's own `ttsConfig` from custom speech cards.
    /// Built-in call sites omit this parameter and get unchanged behaviour.
    var ttsConfigOverride: TTSProviderConfig? = nil

    private var isActive: Bool { activeID == rowID }

    var body: some View {
        Button {
            if isActive && coordinator.phase != .idle {
                coordinator.stop()
                activeID = nil
            } else {
                play()
            }
        } label: {
            if isActive && coordinator.phase == .loading {
                ProgressView()
                    .controlSize(.small)
            } else if isActive && coordinator.phase == .playing {
                Image(systemName: "stop.fill")
            } else {
                Image(systemName: "speaker.wave.2.fill")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(
            coordinator.didFallBackToSystem && isActive
                ? "Cloud voice unavailable — the System voice is being used instead."
                : "Preview this voice"
        )
        .overlay(alignment: .topTrailing) {
            if coordinator.didFallBackToSystem && isActive {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.orange)
                    .offset(x: 6, y: -6)
                    .help("Cloud voice unavailable — the System voice is being used instead.")
                    .accessibilityLabel("Cloud voice unavailable, using System voice")
            }
        }
    }

    private func play() {
        guard cloudAllowed else { return }
        var s = settings.speakSettings
        s.selectedEngine = .cloud(kind)
        let accent = SpeakAccent.allCases.first { $0.bcp47 == languageCode }
            ?? settings.speakSettings.defaultAccent
        let config = ttsConfigOverride ?? settings.ttsConfig(for: kind)
        activeID = rowID
        coordinator.speak(accent.previewSample, accent: accent, settings: s, ttsConfig: config)
    }
}

// MARK: - AppearanceView

/// Settings tab for visual preferences of the floating toolbar.
///
/// Sections:
///   • Toolbar Zoom: global scale for chrome and optionally the result font.
///   • Result text: font size of the result body (small / normal / big).
private struct AppearanceView: View {
    @ObservedObject var settings: SettingsStore

    // The Picker binds to local state, not directly to settings.resultFontSize:
    // a segmented Picker bound straight to an @Published property writes back
    // during the SwiftUI update pass, which trips "Publishing changes from
    // within view updates". Local @State decouples the write; .onChange pushes
    // the value to the store outside the update cycle.
    @State private var fontSize: ResultFontSize = .normal
    @State private var preserveFormatting: Bool = false
    @State private var toolbarZoom: ToolbarZoom = .x1
    @State private var zoomIncludesFontSize: Bool = true

    var body: some View {
        Form {
            Section(header: Text("Toolbar Zoom")) {
                // A setting and its description live in one cell so no divider
                // splits them; the grouped Form still draws a divider between
                // cells (i.e. between settings).
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Zoom level") {
                        CapsuleSegmentedPicker(
                            selection: $toolbarZoom,
                            segments: ToolbarZoom.allCases.map { .init(value: $0, label: $0.displayName) }
                        )
                        .onChange(of: toolbarZoom) { newValue in
                            settings.toolbarZoom = newValue
                        }
                    }

                    Text("Zoom level scales the entire floating toolbar — buttons, icons, and spacing — making it easier to see and click. 1× is the default size; higher levels make everything proportionally larger.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Include font size in zoom", isOn: $zoomIncludesFontSize)
                        .onChange(of: zoomIncludesFontSize) { newValue in
                            settings.zoomIncludesFontSize = newValue
                        }

                    Text("Turn off to keep the result text at its chosen size while everything else grows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Live preview at the toolbar's real on-screen size for the
                // selected zoom (reuses the same ToolbarPreviewView as Actions).
                ToolbarPreviewView(settings: settings)
            }

            Section(header: Text("Result Text")) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Font size") {
                        CapsuleSegmentedPicker(
                            selection: $fontSize,
                            segments: ResultFontSize.allCases.map { .init(value: $0, label: $0.displayName) }
                        )
                        .onChange(of: fontSize) { newValue in
                            settings.resultFontSize = newValue
                        }
                    }

                    // Live preview so the choice is visible without triggering an
                    // action. When "Include font size in zoom" is on, it also
                    // reflects the toolbar zoom; turning the toggle off resets it.
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(fontSize.font(scale: zoomIncludesFontSize ? toolbarZoom.scale : 1))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.easeOut(duration: 0.12), value: toolbarZoom)
                        .animation(.easeOut(duration: 0.12), value: zoomIncludesFontSize)

                    Text("Applies to the result shown in the toolbar after an action runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: Text("Formatting")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Preserve & render formatting", isOn: $preserveFormatting)
                        .onChange(of: preserveFormatting) { newValue in
                            settings.preserveFormatting = newValue
                        }

                    Text("Render Markdown text styles and lists in the result. Bold, italic, strikethrough, inline code, and lists are supported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            fontSize = settings.resultFontSize
            preserveFormatting = settings.preserveFormatting
            toolbarZoom = settings.toolbarZoom
            zoomIncludesFontSize = settings.zoomIncludesFontSize
        }
    }
}

// MARK: - VerifyOutcome

/// Result of a saved-key verification attempt, used by `KeyEntryRow`.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor so
// that Equatable conformance synthesis is also nonisolated and the type
// can be used in nonisolated test code without a concurrency error.
nonisolated enum VerifyOutcome: Equatable {
    /// The key authenticated successfully.
    case valid
    /// The provider rejected the key (HTTP 400, 401, or 403).
    case invalid
    /// The provider was reachable but could not confirm the key (non-auth HTTP error or transport failure).
    case unreachable
    /// The base URL is not configured; cannot reach the provider to verify.
    case noEndpoint
    /// No key is saved in Keychain for this provider.
    case noKey
}

// MARK: - Key masking

/// Produces a short, non-recoverable preview of a stored API key for display,
/// e.g. "sk-proj-sDvg…aoW2WRL8sA" — enough to remind the user which key it is
/// without revealing the secret. Returns nil for a nil/empty key.
///
/// Long keys reveal a head and tail; short keys (≤ head+tail) reveal only a
/// small head so the masked portion always dominates.
nonisolated func maskedKeyPreview(_ key: String?) -> String? {
    guard let key, !key.isEmpty else { return nil }
    let head = 12, tail = 10
    if key.count > head + tail {
        return "\(key.prefix(head))…\(key.suffix(tail))"
    }
    // Too short to reveal both ends safely — show only a small head.
    let shortHead = min(4, key.count)
    return "\(key.prefix(shortHead))…"
}

// MARK: - Verify outcome mapping

/// Maps a raw `ProviderKeyValidator.validate` result to a `VerifyOutcome`.
///
/// Extracted as a free function so the mapping logic is unit-testable without
/// constructing a full SwiftUI view hierarchy.
///
/// - Parameters:
///   - error:                  The error thrown by the validator, or `nil` on success.
///   - hasKey:                 Whether a key was found in Keychain before the call.
///   - customEndpointMissing:  Whether the provider is `.custom` but has no base URL configured.
/// - Returns: The appropriate `VerifyOutcome`.
nonisolated func mapVerifyOutcome(error: Error?, hasKey: Bool, customEndpointMissing: Bool) -> VerifyOutcome {
    guard hasKey else { return .noKey }
    if customEndpointMissing { return .noEndpoint }
    guard let error else { return .valid }
    if let providerError = error as? ProviderError {
        switch providerError {
        case .httpError(let code, _) where code == 400 || code == 401 || code == 403:
            return .invalid
        case .httpError:
            return .unreachable
        default:
            break
        }
    }
    return .unreachable
}

// MARK: - Model check outcome mapping

/// Maps a raw `ProviderModelValidator.validate` result to a `VerifyOutcome`.
///
/// Reuses `VerifyOutcome` values; only the feedback text differs from the key-
/// verify flow. Extracted as a free function so it is unit-testable without a
/// SwiftUI view hierarchy.
///
/// - Parameters:
///   - error:                 The error thrown by the validator, or `nil` on success.
///   - customEndpointMissing: Whether the provider is `.custom` but has no base URL.
/// - Returns: The appropriate `VerifyOutcome`.
nonisolated func mapModelCheckOutcome(error: Error?, customEndpointMissing: Bool) -> VerifyOutcome {
    if customEndpointMissing { return .noEndpoint }
    guard let error else { return .valid }
    if let providerError = error as? ProviderError {
        switch providerError {
        case .httpError(let code, _) where code == 400 || code == 401 || code == 403 || code == 404:
            return .invalid
        case .httpError:
            return .unreachable
        default:
            break
        }
    }
    return .unreachable
}

// MARK: - Reusable sub-views

struct ProviderPicker: View {
    let label: String
    @Binding var selection: ProviderKind
    /// Restrict the picker to these provider kinds. Pass `nil` for all providers.
    var allowed: [ProviderKind]? = nil

    var body: some View {
        LabeledContent(label) {
            Picker("", selection: $selection) {
                let providers = allowed ?? ProviderKind.allCases
                ForEach(providers, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

struct ModelField: View {
    let label: String
    @Binding var model: String
    /// The provider this model belongs to — drives the picker list and info tooltip.
    let providerKind: ProviderKind
    /// Placeholder text shown when the custom text field is empty.
    var placeholder: String = "model identifier"
    /// Settings store — needed to resolve baseURL for custom providers.
    var settings: SettingsStore? = nil
    /// Keychain — needed to read the API key when the user taps Check.
    var keychain: KeychainManager? = nil

    /// Sentinel tag used for the "Custom…" Picker row. Must not collide with
    /// any real model identifier string.
    private static let customSentinel = "__custom__"

    /// True when the current model value is not in the curated list, OR the user
    /// has explicitly chosen "Custom…". Derived from `model` and `providerKind`.
    @State private var isCustomMode: Bool = false

    /// True while the model check call is in flight.
    @State private var isChecking: Bool = false

    /// Result of the most recent model check; nil means no attempt yet (or
    /// cleared because the model string changed).
    @State private var checkOutcome: VerifyOutcome? = nil

    /// Stored so it can be cancelled when a new check starts or the provider changes.
    @State private var checkTask: Task<Void, Never>? = nil

    /// Pending task that auto-clears `checkOutcome` after a short delay.
    @State private var checkDismissTask: Task<Void, Never>? = nil

    // MARK: - Derived helpers

    private var curated: [String] { providerKind.curatedModels }
    private var hasCurated: Bool { !curated.isEmpty }

    /// True when the free-text field is visible (custom mode or no curated list).
    private var freeTextVisible: Bool { isCustomMode || !hasCurated }

    /// The tag value for the Picker: either the current model (if curated) or the
    /// sentinel (if in custom mode or curated list is empty).
    private var pickerSelection: Binding<String> {
        Binding(
            get: {
                if isCustomMode || !hasCurated { return Self.customSentinel }
                return curated.contains(model) ? model : Self.customSentinel
            },
            set: { newValue in
                if newValue == Self.customSentinel {
                    isCustomMode = true
                    // Don't wipe model — preserve any existing free-typed value.
                } else {
                    isCustomMode = false
                    model = newValue
                    checkOutcome = nil
                }
            }
        )
    }

    // MARK: - Body

    var body: some View {
        LabeledContent {
            if hasCurated {
                pickerWithCustomMode
            } else {
                // No curated list (Ollama, Custom…) — always show plain TextField.
                HStack(spacing: 6) {
                    TextField(placeholder, text: $model)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    checkButton
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                InfoTooltip(text: providerKind.modelHint)
            }
        }
        .onAppear { syncCustomMode() }
        .onChange(of: providerKind) { _ in
            checkTask?.cancel()
            checkTask = nil
            isChecking = false
            syncCustomMode()
            checkOutcome = nil
        }
        .onChange(of: model) { _ in
            checkOutcome = nil
        }

        // Inline check feedback shown below the field when a result is available.
        if freeTextVisible, let outcome = checkOutcome {
            modelCheckFeedbackView(outcome)
        }
    }

    // MARK: - Picker + Custom mode

    @ViewBuilder
    private var pickerWithCustomMode: some View {
        HStack(spacing: 6) {
            Picker("", selection: pickerSelection) {
                ForEach(curated, id: \.self) { id in
                    Text(id).tag(id)
                }
                Divider()
                Text("Custom…").tag(Self.customSentinel)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            if isCustomMode {
                TextField(placeholder, text: $model)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                checkButton
            }
        }
    }

    // MARK: - Check button

    /// "Check" button + spinner shown next to the free-text model field.
    /// Only rendered when `settings` and `keychain` are provided (i.e. the caller
    /// wants model verification).
    @ViewBuilder
    private var checkButton: some View {
        if settings != nil && keychain != nil {
            Button("Check") { runCheck() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)

            if isChecking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Check feedback

    @ViewBuilder
    private func modelCheckFeedbackView(_ outcome: VerifyOutcome) -> some View {
        switch outcome {
        case .valid:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Model OK")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .invalid:
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Model not found or key invalid")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        case .unreachable:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Couldn't reach provider")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .noEndpoint:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Set the base URL first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .noKey:
            HStack(spacing: 6) {
                Image(systemName: "key.slash")
                    .foregroundStyle(.secondary)
                Text("No key saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Check action

    private func runCheck() {
        guard let settings, let keychain else { return }
        let modelToCheck = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelToCheck.isEmpty else { return }

        // Cancel any in-flight check before starting a new one.
        checkTask?.cancel()
        checkDismissTask?.cancel()

        isChecking = true
        checkOutcome = nil

        // Capture only Sendable values before the Task so no actor-isolated state
        // is accessed from within the concurrent closure.
        let kind = providerKind
        let savedKey = keychain.key(for: kind)

        // Providers other than Ollama require a key. Short-circuit to .noKey when
        // the key is absent so we don't send an empty bearer token to the network.
        if kind != .ollama && savedKey == nil {
            isChecking = false
            checkOutcome = .noKey
            checkTask = nil
            scheduleCheckDismiss()
            return
        }

        let apiKey = savedKey ?? ""

        // Resolve base URL and detect missing-endpoint condition synchronously on
        // the main actor (settings is @MainActor) before entering the Task.
        let rawCustomURL = (kind == .custom) ? settings.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let customEndpointMissing = (kind == .custom) && (rawCustomURL.isEmpty || URL(string: rawCustomURL) == nil)
        let resolvedBaseURL: URL? = (kind == .custom && !customEndpointMissing) ? URL(string: rawCustomURL) : nil

        checkTask = Task {
            let outcome: VerifyOutcome
            if customEndpointMissing {
                outcome = .noEndpoint
            } else {
                do {
                    try await ProviderModelValidator.validate(
                        kind: kind,
                        apiKey: apiKey,
                        baseURL: resolvedBaseURL,
                        model: modelToCheck
                    )
                    outcome = mapModelCheckOutcome(error: nil, customEndpointMissing: false)
                } catch {
                    outcome = mapModelCheckOutcome(error: error, customEndpointMissing: false)
                }
            }
            // Skip writing if this task was cancelled (provider or model changed mid-flight).
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isChecking = false
                checkOutcome = outcome
                scheduleCheckDismiss()
            }
        }
    }

    /// Auto-clear the model-check feedback after a short delay so it doesn't linger.
    private func scheduleCheckDismiss() {
        checkDismissTask?.cancel()
        checkDismissTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            checkOutcome = nil
        }
    }

    // MARK: - State sync

    /// Derives `isCustomMode` from the current `model` and `providerKind`.
    /// Called on appear and on change of either value so state stays in sync.
    private func syncCustomMode() {
        let curated = providerKind.curatedModels
        let nowCustom = !curated.isEmpty && !curated.contains(model)
        isCustomMode = nowCustom
    }
}

// MARK: - CLIVerifyButton

/// A "Verify" button for CLI provider cards. Spawns the configured CLI once with
/// a tiny probe prompt and reports whether it ran and returned output (i.e. the
/// user's subscription/OAuth login works). Mirrors the API providers' key/model
/// check, but for keyless CLI providers.
struct CLIVerifyButton: View {
    let kind: ProviderKind
    /// Current value of the provider's configured binary path.
    let path: String

    @State private var isVerifying = false
    @State private var outcome: CLIProviderValidator.Outcome?
    @State private var verifyTask: Task<Void, Never>?
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Button("Verify") { run() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifying)

            if isVerifying {
                ProgressView()
                    .controlSize(.small)
                Text("Running…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let outcome {
                feedback(outcome)
            }
        }
        .onDisappear {
            verifyTask?.cancel()
            dismissTask?.cancel()
        }
    }

    @ViewBuilder
    private func feedback(_ outcome: CLIProviderValidator.Outcome) -> some View {
        switch outcome {
        case .working:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Working").font(.caption).foregroundStyle(.secondary)
            }
        case .noPath:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Set the CLI path first").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(message)
            }
        }
    }

    private func run() {
        verifyTask?.cancel()
        dismissTask?.cancel()
        isVerifying = true
        outcome = nil

        // Capture Sendable values before entering the concurrent Task.
        let kind = self.kind
        let path = self.path

        verifyTask = Task {
            let result = await CLIProviderValidator.validate(kind: kind, executablePath: path)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isVerifying = false
                outcome = result
                // Keep a failure visible; auto-clear a success after a moment.
                if case .working = result {
                    dismissTask = Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else { return }
                        outcome = nil
                    }
                }
            }
        }
    }
}

// MARK: - GetAPIKeyLink

/// A small external-link button shown in a provider card header. Opens the
/// provider's console in the default browser so the user can obtain an API key.
struct GetAPIKeyLink: View {
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 4) {
                Text("Get API key")
                Image(systemName: "arrow.up.right.square")
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("Open the provider's website to get an API key")
    }
}

// MARK: - InfoTooltip

/// A small (i) info button whose tooltip is shown in a `.popover` rather than
/// an in-layout overlay. A hovering overlay gets clipped by the ScrollView and
/// the settings sidebar and renders semi-transparent; a popover floats in its
/// own window — fully opaque, never clipped, and correctly positioned.
struct InfoTooltip: View {
    let text: String

    @State private var isHovered = false
    /// Drives the popover. Set a short moment after hover begins so it's near-
    /// instant but doesn't flicker on a passing cursor.
    @State private var showTooltip = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000) // ~120ms
                        if isHovered { showTooltip = true }
                    }
                } else {
                    showTooltip = false
                }
            }
            .popover(isPresented: $showTooltip, arrowEdge: .bottom) {
                Text(text)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
    }
}

/// A three-line entry block for a provider API key.
///
/// Security contract:
/// - The real stored key is NEVER placed in `draft` or any @State; only a
///   masked, non-recoverable preview (`keyPreview`) may be displayed.
/// - When a key is saved, the input field is HIDDEN and the masked preview
///   (or a generic "Key is saved" when no preview) is shown instead. Tapping
///   Edit reveals an EMPTY input field (the real key is never loaded back into
///   it) to enter a replacement.
/// - `onCommit` validates the key against the provider and returns `nil` on
///   success or an error message on failure. The row only collapses to the
///   saved indicator on success; on failure the message is shown and the
///   field stays open so the user can correct the key.
/// - `onVerify` (optional) tests the already-saved key against the live
///   provider and returns a `VerifyOutcome`. Pass `nil` for keyless providers.
private struct KeyEntryRow: View {
    @Binding var draft: String
    let isSaved: Bool
    /// Masked preview of the saved key (e.g. "sk-proj-sDvg…aoW2WRL8sA"), shown
    /// in the saved-key indicator. nil falls back to a generic "Key is saved".
    var keyPreview: String? = nil
    /// Validate + save the current draft. Returns `nil` on success, or a
    /// user-facing error message on failure (the key was not saved).
    let onCommit: () async -> String?
    let onClear: () -> Void
    /// Tests the saved key against the provider. Pass `nil` for keyless
    /// providers (Ollama) — no Verify button is shown when this is nil.
    var onVerify: (() async -> VerifyOutcome)? = nil

    /// When a key is saved, the field stays hidden until the user taps Edit.
    @State private var isEditing = false

    /// True while the key is being verified against the provider.
    @State private var isValidating = false

    /// Validation failure message, shown until the next commit / edit / cancel.
    @State private var errorMessage: String?

    /// True while the saved-key verify call is in flight.
    @State private var isVerifying = false

    /// Result of the most recent verify attempt; nil means no attempt yet.
    @State private var verifyOutcome: VerifyOutcome?

    /// Pending task that auto-clears `verifyOutcome` after a short delay.
    @State private var dismissTask: Task<Void, Never>?

    /// Whether the SecureField should be visible: always when no key is saved,
    /// or when the user has tapped Edit on a saved key.
    private var showsField: Bool { !isSaved || isEditing }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Either the input field, or a "Key is saved" indicator.
            // Explicit HStack so the field spans the rest of the row after the
            // label (the Form's automatic label column leaves a wide gap).
            if showsField {
                HStack(spacing: 8) {
                    Text("API Key")
                    SecureField("", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .disabled(isValidating)
                        .onSubmit { commit() }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let keyPreview {
                        Text(keyPreview)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                    } else {
                        Text("Key is saved")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Validation failure message (cleared on the next commit attempt).
            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            // Line 3: Save (when editing) / Edit + Verify (when saved & not editing),
            // Cancel (when re-editing a saved key), and Clear.
            HStack(spacing: 8) {
                if showsField {
                    Button("Save") { commit() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(draft.isEmpty || isValidating)

                    if isValidating {
                        ProgressView()
                            .controlSize(.small)
                        Text("Verifying…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Edit") {
                        errorMessage = nil
                        verifyOutcome = nil
                        isEditing = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    // Verify button — only shown when an onVerify handler is provided.
                    // Loading spinner sits inside the button, in front of the label.
                    if onVerify != nil {
                        Button { verify() } label: {
                            HStack(spacing: 4) {
                                if isVerifying {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.85)
                                        .frame(width: 11, height: 11)
                                }
                                Text("Verify")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isVerifying)
                    }
                }

                // Cancel — only when re-editing an already-saved key. Exits edit
                // mode without deleting the stored key (Clear is destructive).
                if isSaved && isEditing {
                    Button("Cancel") {
                        draft = ""
                        errorMessage = nil
                        isEditing = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isValidating)
                }

                Button("Clear") {
                    onClear()
                    errorMessage = nil
                    verifyOutcome = nil
                    isEditing = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isSaved || isValidating)

                // Inline verify feedback sits next to the Clear button on the
                // same footer line; auto-dismissed after a short delay.
                if !showsField, let outcome = verifyOutcome {
                    verifyFeedbackView(outcome)
                }
            }
        }
    }

    /// Inline feedback row shown after a verify attempt.
    @ViewBuilder
    private func verifyFeedbackView(_ outcome: VerifyOutcome) -> some View {
        switch outcome {
        case .valid:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Key is valid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .invalid:
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Key invalid")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        case .unreachable:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Couldn't reach provider")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .noEndpoint:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Set the base URL first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .noKey:
            HStack(spacing: 6) {
                Image(systemName: "key.slash")
                    .foregroundStyle(.secondary)
                Text("No key saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Verify the draft, then collapse to the saved indicator on success or
    /// surface the error on failure. The key is only persisted by `onCommit`
    /// when validation passes.
    private func commit() {
        guard !draft.isEmpty, !isValidating else { return }
        isValidating = true
        errorMessage = nil
        Task {
            let error = await onCommit()
            isValidating = false
            if let error {
                errorMessage = error
            } else {
                draft = ""
                errorMessage = nil
                verifyOutcome = nil
                isEditing = false
            }
        }
    }

    /// Test the already-saved key against the live provider.
    private func verify() {
        guard let onVerify, !isVerifying else { return }
        dismissTask?.cancel()
        isVerifying = true
        verifyOutcome = nil
        Task {
            let outcome = await onVerify()
            isVerifying = false
            verifyOutcome = outcome
            scheduleVerifyDismiss()
        }
    }

    /// Auto-clear the verify feedback after a short delay so it doesn't linger.
    private func scheduleVerifyDismiss() {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            verifyOutcome = nil
        }
    }
}

// MARK: - Preview

#Preview("Settings") {
    SettingsView(
        settings: SettingsStore(
            defaults: UserDefaults(suiteName: "preview.PopGuy.SettingsView") ?? .standard
        ),
        keychain: KeychainManager(serviceName: "preview.PopGuy.SettingsView"),
        history: HistoryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("preview.PopGuy.SettingsView.history.json")
        ),
        navigator: SettingsNavigator(),
        licenseGate: LicenseGate(),
        updater: UpdaterController()
    )
    .frame(width: 740, height: 480)
}
