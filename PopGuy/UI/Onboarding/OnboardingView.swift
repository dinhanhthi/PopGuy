// OnboardingView.swift
// PopGuy — First-launch onboarding
//
// Shown ONCE on first launch (guarded by SettingsStore.hasOnboarded).
// Steps:
//   0. Welcome — what PopGuy does (trial-aware).
//   1. Accessibility permission.
//   2. Provider setup — placeholder until the functional page lands.
//   3. Triggers — placeholder.
//   4. Actions — placeholder.
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
///   - `onOpenSettings`: closure that opens the existing Settings window.
///   - `onGetPro`: closure that opens the checkout URL (trial-ineligible variant only).
///   - `onFinish`: closure called when the user taps "Get Started" (or the window closes).
@MainActor
struct OnboardingView: View {

    @ObservedObject var axPermission: AccessibilityPermission
    @ObservedObject var settings: SettingsStore
    let keychain: KeychainManager
    let trialState: TrialState
    let onOpenSettings: () -> Void
    let onGetPro: () -> Void
    let onFinish: () -> Void

    @State private var page: Int = 0

    @State private var launchAtLogin = false
    @State private var loginItemError: String? = nil

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
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else if page < pageCount - 1 {
                    Button("Next") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { onFinish() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 560)
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
                subtitle: "PopGuy supports OpenAI, Anthropic (Claude), Ollama / LM Studio, DeepL, and Google Translate. Enter an API key for at least one provider to use AI actions."
            )

            Button("Open Settings\u{2026}") {
                onOpenSettings()
            }
            .buttonStyle(.bordered)

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

            Text("Free accounts can keep up to five actions active. You can change this later in Settings → Actions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

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
