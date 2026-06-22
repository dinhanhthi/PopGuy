// TrialExpiryWarningView.swift
// PopGuy — UI/Onboarding
//
// One-time modal shown on first launch after the free trial expires.
// Presented in an NSWindow (isReleasedWhenClosed=false) by AppDelegate.
// Acknowledgement is written to Keychain before the window appears, so a
// crash-before-dismiss never triggers a second presentation.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - TrialExpiryWarningView

/// One-time post-trial warning modal.
///
/// Callers inject:
///   - `onGetPro`: opens the checkout URL and closes the window.
///   - `onContinue`: closes the window and continues on the Free plan.
struct TrialExpiryWarningView: View {
    let onGetPro: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Your free trial has ended.")
                        .font(.title3.weight(.semibold))
                    Text("Anything beyond the Free limits is paused until you upgrade to Pro. Nothing was deleted.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !ProConfig.purchaseEnabled {
                Text(ProConfig.purchaseComingSoonNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack {
                Button("Continue on Free") {
                    onContinue()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Get Pro") {
                    onGetPro()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.proGold)
                .disabled(!ProConfig.purchaseEnabled)
            }
        }
        .padding(28)
        .frame(width: 420)
    }
}

// MARK: - Preview

#Preview("TrialExpiryWarningView") {
    TrialExpiryWarningView(onGetPro: {}, onContinue: {})
}
