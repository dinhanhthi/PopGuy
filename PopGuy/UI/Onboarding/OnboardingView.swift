// OnboardingView.swift
// PopGuy — First-launch onboarding
//
// Shown ONCE on first launch (guarded by SettingsStore.hasOnboarded).
// Steps:
//   1. Welcome — what PopGuy does.
//   2. Accessibility permission — reuses AccessibilityPermission from Phase 1.
//   3. Provider setup hint — opens the Settings window.
//   4. Feature tour — brief description of core gestures.
//
// Isolation: @MainActor — all UI.
// Plain static text only; no untrusted external content is rendered here.

import SwiftUI

// MARK: - OnboardingView

/// Multi-step first-launch onboarding presented in a plain NSWindow host.
///
/// Callers inject:
///   - `axPermission`: the shared `AccessibilityPermission` object (do NOT create a new one).
///   - `trialState`: the current trial state computed by `LicenseGate.bootstrapTrial()` before
///     onboarding is shown. Determines which welcome-page variant is rendered.
///   - `onOpenSettings`: closure that opens the existing Settings window.
///   - `onGetPro`: closure that opens the checkout URL (trial-ineligible variant only).
///   - `onFinish`: closure called when the user taps "Get Started" (or the window closes).
@MainActor
struct OnboardingView: View {

    @ObservedObject var axPermission: AccessibilityPermission
    let trialState: TrialState
    let onOpenSettings: () -> Void
    let onGetPro: () -> Void
    let onFinish: () -> Void

    @State private var page: Int = 0

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            Group {
                switch page {
                case 0: welcomePage
                case 1: accessibilityPage
                case 2: providerPage
                default: tourPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)

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
        .frame(width: 480, height: 340)
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
                    Button("Get Pro\u{2026}") {
                        onGetPro()
                    }
                    .buttonStyle(.bordered)
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

    private var tourPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            OnboardingHeader(
                systemImage: "sparkles",
                title: "How to Use PopGuy",
                subtitle: "You're all set. Here's a quick reference:"
            )

            VStack(alignment: .leading, spacing: 8) {
                TourRow(icon: "selection.pin.in.out", text: "Select text in any app — the toolbar appears automatically near your selection.")
                TourRow(icon: "wand.and.stars", text: "Tap Improve to rewrite selected text with AI; a diff shows what changed before you apply.")
                TourRow(icon: "globe", text: "Tap Translate to convert text to your target language.")
                TourRow(icon: "command", text: "Press Cmd+C+C (double-tap) to trigger the Improve action without using the toolbar.")
                TourRow(icon: "slider.horizontal.3", text: "Create custom AI actions in Settings with your own system prompt.")
            }

            Spacer()
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
