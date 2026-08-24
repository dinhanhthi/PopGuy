// OnboardingView.swift
// PopGuy — First-launch onboarding
//
// Shown ONCE on first launch (guarded by SettingsStore.hasOnboarded).
// Steps:
//   0. Welcome — what PopGuy does (trial-aware).
//   1. Accessibility permission.
//   2. Provider setup — Local AI vs Cloud API key chooser.
//   3. Triggers — Cmd+C+C chord + optional replacement + show-on-select.
//   4. Actions — pick built-in toolbar actions (free-tier cap).
//   5. Finish — launch at login + feature tour.
//
// Isolation: @MainActor — all UI.
// Plain static text only; no untrusted external content is rendered here.

import ServiceManagement
import SwiftUI

// MARK: - OnboardingView

/// Multi-step first-launch onboarding presented in a plain NSWindow host.
///
/// Callers inject:
///   - `axPermission`: the shared `AccessibilityPermission` object (do NOT create a new one).
///   - `settings`: the shared `SettingsStore` (do NOT create a new one).
///   - `keychain`: the shared `KeychainManager` (API keys stay in Keychain only).
///   - `trialState`: the current trial state computed by `LicenseGate.bootstrapTrial()` before
///     onboarding is shown. Determines which welcome-page variant is rendered.
///   - `isPro`: `LicenseGate.entitlements.isPro` (true for Pro and an active trial).
///     Used only to gate the free active-action cap on the Choose Actions page.
///   - `onOpenSettings`: closure that opens the existing Settings window.
///   - `onGetPro`: closure that opens the checkout URL (trial-ineligible variant only).
///   - `onFinish`: closure called when the user taps "Get Started" (or the window closes).
@MainActor
struct OnboardingView: View {

    @ObservedObject var axPermission: AccessibilityPermission
    @ObservedObject var settings: SettingsStore
    let keychain: KeychainManager
    let trialState: TrialState
    let isPro: Bool
    let onOpenSettings: () -> Void
    let onGetPro: () -> Void
    let onFinish: () -> Void

    @State private var page: Int = 0

    /// Owned here so Back/Next does not reset Local vs Cloud, and so
    /// already-installed local-action mapping can run after the provider page
    /// is off-screen. In-flight download mapping is owned by SettingsStore.
    @State private var providerMode: ProviderMode = MLXCapability.isSupported ? .local : .cloud

    @State private var launchAtLogin = false
    @State private var loginItemError: String? = nil

    /// Lifted so the footer can drop `.keyboardShortcut(.defaultAction)` while
    /// the Triggers page is recording a chord replacement (bare Return would
    /// otherwise fire Next and skip the page).
    @State private var isRecordingChord = false

    private let pageCount = 6

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            ScrollView {
                Group {
                    switch page {
                    case 0: welcomePage
                    case 1: accessibilityPage
                    case 2: providerPage
                    case 3: triggersPage
                    case 4: actionsPage
                    default: finishPage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation footer
            HStack {
                // Step indicator
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                if page > 0 {
                    Button("Back") { page -= 1 }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }

                if page == 0 {
                    // Welcome page: trial-aware label, prominent style.
                    Button(welcomePrimaryLabel) { page += 1 }
                        .modifier(OnboardingDefaultActionModifier(enabled: !isRecordingChord))
                        .buttonStyle(.borderedProminent)
                } else if page < pageCount - 1 {
                    Button("Next") { page += 1 }
                        .modifier(OnboardingDefaultActionModifier(enabled: !isRecordingChord))
                } else {
                    Button("Get Started") { onFinish() }
                        .modifier(OnboardingDefaultActionModifier(enabled: !isRecordingChord))
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            // While recording, Return/Enter cancels instead of advancing.
            // Hidden so it does not steal layout; `.defaultAction` still fires.
            .background {
                if isRecordingChord {
                    Button("Cancel recording") {
                        isRecordingChord = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(width: 560, height: 560)
        .task {
            await settings.refreshInstalledLocalModels()
            pointAIActionsAtLocalIfReady()
        }
        .onChange(of: settings.installedLocalModels) { _ in
            pointAIActionsAtLocalIfReady()
        }
        .onChange(of: providerMode) { newMode in
            switch newMode {
            case .cloud:
                settings.clearPendingOnboardingLocalMap()
            case .local:
                if let modelID = freeLocalModelID,
                   settings.activeLocalModelDownloadID == modelID {
                    settings.markPendingOnboardingLocalMap(modelID: modelID)
                }
            }
            pointAIActionsAtLocalIfReady()
        }
    }

    /// Label for the footer's primary advance button.
    ///
    /// On the welcome page (page 0): varies by trial variant.
    /// On all other pages: "Next" (standard label).
    private var welcomePrimaryLabel: String {
        guard page == 0 else { return "Next" }
        return trialState.isActive ? "Start free trial" : "Get started"
    }

    // MARK: - Pages

    private var welcomePage: some View {
        Group {
            if trialState.isActive {
                // Trial-active variant: user is eligible and trial is already running.
                VStack(alignment: .leading, spacing: 16) {
                    OnboardingHeader(
                        systemImage: "sparkles",
                        title: "Welcome to PopGuy",
                        subtitle: "All Pro features are free for 2 months."
                    )
                    Text("When it ends, your settings revert to the Free limits.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                // Ineligible variant: post-cutoff or kill-switch off.
                VStack(alignment: .leading, spacing: 16) {
                    OnboardingHeader(
                        systemImage: "text.cursor",
                        title: "Welcome to PopGuy",
                        subtitle: "Free to use with limits on custom actions, history, and active toolbar slots. Upgrade to Pro for unlimited."
                    )
                    if ProConfig.purchaseEnabled {
                        Button("Get Pro\u{2026}") {
                            onGetPro()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Get Pro\u{2026}") {}
                            .buttonStyle(.bordered)
                            .disabled(true)
                        Text(ProConfig.purchaseComingSoonNote)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var accessibilityPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(
                systemImage: "hand.raised.fill",
                title: "Accessibility Permission",
                subtitle: "PopGuy reads selected text via the macOS Accessibility API and installs a keyboard event tap for the Cmd+C+C chord. Both require this permission."
            )

            if axPermission.isTrusted {
                Label("Accessibility is granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.weight(.medium))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Accessibility is not yet granted", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline.weight(.medium))

                    Text("Click the button below, then enable PopGuy in:\nSystem Settings → Privacy & Security → Accessibility")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Grant Accessibility\u{2026}") {
                        axPermission.requestPermission()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer()
        }
    }

    private var providerPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(
                systemImage: "key.fill",
                title: "Set Up a Provider",
                subtitle: "Choose Local AI to run privately on your Mac, or a Cloud API key for the best quality."
            )

            OnboardingProviderPage(
                settings: settings,
                keychain: keychain,
                mode: $providerMode
            )

            Spacer()
        }
    }

    private var triggersPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(
                systemImage: "command",
                title: "How PopGuy Appears",
                subtitle: "Trigger PopGuy with Cmd+C+C, or show the toolbar when you select text."
            )

            OnboardingTriggersPage(settings: settings, isRecordingChord: $isRecordingChord)

            Text("You can change these anytime in Settings → Triggers.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var actionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(
                systemImage: "slider.horizontal.3",
                title: "Choose Your Actions",
                subtitle: "Pick which actions appear on the toolbar."
            )

            OnboardingActionsPage(settings: settings, isPro: isPro)

            Spacer()
        }
    }

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(
                systemImage: "sparkles",
                title: "You're All Set",
                subtitle: "Launch at login so PopGuy is always ready. You can change anything later in Settings."
            )

            Toggle("Launch PopGuy at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    applyOnboardingLoginItem(newValue)
                }
                .font(.subheadline)

            if let error = loginItemError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("You can change this later in Settings → General.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                TourRow(icon: "selection.pin.in.out", text: "Select text in any app — the toolbar appears automatically near your selection.")
                TourRow(icon: "wand.and.stars", text: "Tap Improve to rewrite selected text with AI; a diff shows what changed before you apply.")
                TourRow(icon: "globe", text: "Tap Translate to convert text to your target language.")
                TourRow(icon: "command", text: "Press Cmd+C+C (double-tap) to trigger the Improve action without using the toolbar.")
                TourRow(icon: "slider.horizontal.3", text: "Create custom AI actions in Settings with your own system prompt.")
            }

            Spacer()
        }
        .onAppear {
            let status = SMAppService.mainApp.status
            launchAtLogin = status == .enabled || status == .requiresApproval
        }
    }

    private func applyOnboardingLoginItem(_ enable: Bool) {
        let status = SMAppService.mainApp.status
        let isActive = status == .enabled || status == .requiresApproval
        guard isActive != enable else { return }
        loginItemError = nil
        do {
            if enable {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    loginItemError = "Pending approval — open Login Items in System Settings to allow it."
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enable
            loginItemError = "Could not \(enable ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
    }

    // MARK: - Local AI action mapping

    /// Free-tier catalog entry offered in onboarding (`ProConfig.freeLocalModelIDs`).
    private var freeLocalModelID: String? {
        LocalModelCatalog.all.first { ProConfig.freeLocalModelIDs.contains($0.id) }?.id
    }

    /// Point Improve / Shorten / Proofread / Prompt at the free local model.
    /// Translate is left untouched. No-op unless Local is selected and the model is installed.
    private func pointAIActionsAtLocalIfReady() {
        guard providerMode == .local else { return }
        guard let modelID = freeLocalModelID else { return }
        guard settings.installedLocalModels.contains(modelID) else { return }
        settings.pointAIActionsAtLocalModel(modelID)
    }
}

// MARK: - Supporting views

@MainActor
private struct OnboardingHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Applies Return/Enter as the window default action, unless a chord
/// replacement is being recorded (bare Return must not fire Next).
private struct OnboardingDefaultActionModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}

@MainActor
private struct OnboardingTriggersPage: View {
    @ObservedObject var settings: SettingsStore

    /// Whether the chord-replacement recorder is active. Owned by `OnboardingView`
    /// so the footer can disable `.keyboardShortcut(.defaultAction)` while recording.
    @Binding var isRecordingChord: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chordCard
            selectCard
        }
        .onChange(of: settings.triggerChordEnabled) { enabled in
            if !enabled { isRecordingChord = false }
        }
        .onDisappear {
            isRecordingChord = false
        }
    }

    private var chordCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show toolbar with Cmd+C+C", isOn: $settings.triggerChordEnabled)
                .font(.subheadline)

            Text("Press Cmd+C twice quickly on selected text to show the toolbar.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Use a different shortcut")
                    .font(.subheadline)
                    .foregroundStyle(settings.triggerChordEnabled ? .primary : .secondary)

                Spacer()

                chordShortcutEditor
            }
            .disabled(!settings.triggerChordEnabled)

            Text("You can pick a different shortcut instead of Cmd+C+C (for example ⌘⇧Space).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var chordShortcutEditor: some View {
        if isRecordingChord {
            ShortcutRecorder(
                onCapture: { shortcut in
                    settings.chordReplacementShortcut = shortcut
                    isRecordingChord = false
                },
                onCancel: {
                    isRecordingChord = false
                }
            )
        } else {
            if let shortcut = settings.chordReplacementShortcut {
                ShortcutBadge(text: shortcut.displayString)

                Button {
                    settings.chordReplacementShortcut = nil
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .hoverTooltip("Clear — revert to Cmd+C+C")
                .disabled(!settings.triggerChordEnabled)
            } else {
                ShortcutBadge(text: "⌘C+C")
            }

            Button {
                isRecordingChord = true
            } label: {
                Image(systemName: "record.circle")
            }
            .buttonStyle(.borderless)
            .hoverTooltip("Record a replacement shortcut (e.g. ⌘⇧Space)")
            .disabled(!settings.triggerChordEnabled)
        }
    }

    private var selectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show toolbar when text is selected", isOn: $settings.triggerOnSelectEnabled)
                .font(.subheadline)

            Text("Shows the toolbar the moment you select text. That can feel busy, so it's off by default.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("May not work well in some editors (for example Cursor, VS Code, or Notion). Use Cmd+C+C there instead.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - Choose actions

private struct OnboardingBuiltinAction: Identifiable {
    var id: ActionIdentifier { identifier }
    let identifier: ActionIdentifier
    let icon: String
    let title: String
    let description: String
}

@MainActor
private struct OnboardingActionsPage: View {
    @ObservedObject var settings: SettingsStore
    let isPro: Bool

    @State private var capLimitNote: String?

    private static let builtins: [OnboardingBuiltinAction] = [
        .init(identifier: .builtin(.improve), icon: "wand.and.stars", title: "Improve",
              description: "Fix grammar and improve clarity"),
        .init(identifier: .builtin(.shorten), icon: "text.badge.minus", title: "Shorten",
              description: "Make the text more concise"),
        .init(identifier: .builtin(.proofread), icon: "checkmark.bubble", title: "Proofread",
              description: "Fix spelling and grammar"),
        .init(identifier: .builtin(.translate), icon: "character.bubble", title: "Translate",
              description: "Translate into your chosen language"),
        .init(identifier: .builtin(.prompt), icon: "bubble.and.pencil", title: "Prompt",
              description: "Type a one-off prompt for the selected text"),
        .init(identifier: .speak, icon: "speaker.wave.2", title: "Speak",
              description: "Speak the selected text"),
        .init(identifier: .dictionary, icon: "character.book.closed", title: "Dictionary",
              description: "Look up the selected word"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isPro
                 ? "You can enable all of these. You can change this later in Settings → Actions."
                 : "Free accounts can keep up to \(ProConfig.freeMaxActiveActions) actions active. You can change this later in Settings → Actions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.builtins) { item in
                    Toggle(isOn: enabledBinding(for: item.identifier)) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(.tint)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline)
                                Text(item.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )

            if let capLimitNote {
                Text(capLimitNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func enabledBinding(for id: ActionIdentifier) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(id) },
            set: { setEnabled(id, $0) }
        )
    }

    /// Persist the toggle. Turning off is always allowed. Turning on is rejected
    /// for free users already at `ProConfig.freeMaxActiveActions`.
    ///
    /// `setPrincipal` is best-effort after a successful enable — a false return
    /// means the principal row is full, not the free cap.
    private func setEnabled(_ id: ActionIdentifier, _ enabled: Bool) {
        if enabled {
            if !settings.isEnabled(id),
               !isPro,
               settings.enabledToolbarActionCount >= ProConfig.freeMaxActiveActions {
                capLimitNote = "Free plan shows up to \(ProConfig.freeMaxActiveActions) actions — turn one off first, or upgrade to Pro"
                return
            }
            writeEnabled(id, true)
            settings.setPrincipal(id, true)
            capLimitNote = nil
        } else {
            writeEnabled(id, false)
            capLimitNote = nil
        }
    }

    private func writeEnabled(_ id: ActionIdentifier, _ enabled: Bool) {
        switch id {
        case .builtin(.improve):   settings.improveEnabled = enabled
        case .builtin(.shorten):   settings.shortenEnabled = enabled
        case .builtin(.proofread): settings.proofreadEnabled = enabled
        case .builtin(.translate): settings.translateEnabled = enabled
        case .builtin(.prompt):    settings.promptEnabled = enabled
        case .speak:               settings.speakEnabled = enabled
        case .dictionary:
            var config = settings.dictionaryConfig
            config.isEnabled = enabled
            settings.dictionaryConfig = config
        case .custom:
            break
        }
    }
}

@MainActor
private struct TourRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
