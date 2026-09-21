// NowFreeAnnouncementView.swift
// PopGuy — One-time “now free” announcement
//
// Shown ONCE for users who already completed onboarding (they updated).
// Fresh installs skip it (SettingsStore.hasSeenNowFreeAnnouncement is set
// before first-run onboarding so this never appears later).
//
// Isolation: @MainActor — all UI.
// Plain static text only; no untrusted external content is rendered here.

import SwiftUI

// MARK: - NowFreeAnnouncementView

/// Good-news window: every feature is unlocked; no license or Pro plan.
///
/// Callers inject `onContinue`, which should close the hosting window.
/// The persist flag is set before this view appears.
@MainActor
struct NowFreeAnnouncementView: View {

    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text("PopGuy is now free")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Every feature is unlocked. No license, no Pro plan — this is the last time we will mention it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Continue") {
                onContinue()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(width: 420)
    }
}
