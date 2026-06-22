// UpgradePrompt.swift
// PopGuy — UI/SettingsWindow/Components
//
// Reusable upgrade-prompt card and Pro badge used across gated surfaces.
//
// Usage:
//   UpgradePromptView(message: "Free plan is limited to 3 custom actions.") {
//       // onUpgrade callback — route to License tab in Phase 3
//   }
//
//   ProBadge()   // small "PRO" capsule for inline labelling
//
// Styling follows SettingsCard (SettingsMetrics, Color.primary.opacity(0.05/0.07)).
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - Pro accent color

extension Color {
    /// Gold accent used for all Pro badges and Pro-related decoration.
    static let proGold = Color(red: 0.83, green: 0.64, blue: 0.13)
}

// MARK: - UpgradePromptView

/// An inline card shown when a Pro-gated feature's limit is reached.
/// Displays `message` and a "Get Pro" button that calls `onUpgrade`.
struct UpgradePromptView: View {
    let message: String
    let onUpgrade: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Color.proGold)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if ProConfig.purchaseEnabled {
                Button("Get Pro") {
                    onUpgrade()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.proGold)
            } else {
                Text("Coming soon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - ProBadge

/// A small crown icon for labelling locked features inline.
struct ProBadge: View {
    var body: some View {
        Image(systemName: "crown")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.proGold)
    }
}

// MARK: - UpgradeNagView

/// Soft nag popup shown when free-tier act count triggers a nag milestone.
///
/// Wraps `UpgradePromptView` and adds a **Close** button so the user can
/// dismiss and keep using the app without upgrading. English only.
struct UpgradeNagView: View {
    let actCount: Int
    let onClose: () -> Void
    let onGetPro: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            UpgradePromptView(
                message: "You've run \(actCount) actions — enjoying PopGuy? Unlock Pro for unlimited custom actions, cloud voices, and more.",
                onUpgrade: onGetPro
            )

            HStack {
                Spacer()
                Button("Close") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

// MARK: - Previews

#Preview("UpgradeNagView") {
    UpgradeNagView(actCount: 101, onClose: {}, onGetPro: {})
        .padding()
}

#Preview("UpgradePromptView") {
    UpgradePromptView(message: "Free plan is limited to 3 custom actions. Upgrade to Pro for unlimited actions.") {
        // no-op in preview
    }
    .frame(width: 500)
    .padding()
}

#Preview("ProIcon") {
    HStack(spacing: 8) {
        Text("Cloud TTS")
        ProBadge()
    }
    .padding()
}
