// LicenseView.swift
// PopGuy — UI/SettingsWindow
//
// License tab: shows current tier (Free / Pro), handles key activation,
// and provides a link to purchase Pro.
//
// If no validator is injected (Previews/tests), `activate` returns
// `.invalid(reason:)` immediately — displayed as a calm informational note,
// not an error.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - LicenseConfig

/// Checkout URL alias — the value lives in `ProConfig` (single source of truth).
enum LicenseConfig {
    static let checkoutURL = ProConfig.checkoutURL
}

// MARK: - LicenseView

struct LicenseView: View {
    @ObservedObject var licenseGate: LicenseGate

    // Key-entry field draft (only used in the free state).
    @State private var keyDraft: String = ""

    // True while the activate network/async call is in flight.
    @State private var isActivating: Bool = false

    // The result message from the most recent activation attempt.
    @State private var activationMessage: String? = nil

    // True when the activation message is informational (not a success banner).
    @State private var activationMessageIsInfo: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                statusCard
                if !licenseGate.entitlements.isPro {
                    activateCard
                }
            }
            .padding(SettingsMetrics.pagePadding)
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        SettingsCard(title: "Plan") {
            if licenseGate.activatedKeyMasked != nil {
                // Paid Pro license is active.
                proStatus
            } else if case .active(let daysLeft, let endDate) = licenseGate.trialState {
                // Free trial is active (no paid license).
                trialStatus(daysLeft: daysLeft, endDate: endDate)
            } else {
                freeStatus
            }
        }
    }

    @ViewBuilder
    private var proStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.proGold)
            Text("PopGuy Pro — Active")
                .font(.headline)
        }

        if let masked = licenseGate.activatedKeyMasked {
            HStack(spacing: 6) {
                Text("License key:")
                    .foregroundStyle(.secondary)
                Text(masked)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }

        Button("Deactivate", role: .destructive) {
            licenseGate.deactivate()
            activationMessage = nil
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .foregroundStyle(.red)
    }

    @ViewBuilder
    private func trialStatus(daysLeft: Int, endDate: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hourglass")
                .foregroundStyle(.tint)
            Text("Free trial — \(daysLeft) \(daysLeft == 1 ? "day" : "days") left (until \(trialEndDateString(endDate)))")
                .font(.headline)
        }

        Text("Buy Pro to keep unlimited actions, cloud TTS voices, unlimited history, and more after the trial ends.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        purchaseButton(title: "Get Pro")
    }

    @ViewBuilder
    private var freeStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.circle")
                .foregroundStyle(.secondary)
            Text("Free plan")
                .font(.headline)
        }

        Text("Upgrade to Pro to unlock unlimited custom actions, cloud TTS voices, unlimited history, import/export, and more.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        purchaseButton(title: "Buy Pro")
    }

    // MARK: - Purchase button

    /// Renders the purchase CTA. When `ProConfig.purchaseEnabled` is true, a Link
    /// opens the checkout URL. While the store is pending approval, the Link is
    /// replaced with a disabled button (no URL — checkout stays unreachable) plus
    /// a "coming soon" note.
    @ViewBuilder
    private func purchaseButton(title: String) -> some View {
        if ProConfig.purchaseEnabled {
            Link(destination: LicenseConfig.checkoutURL) {
                Label(title, systemImage: "cart")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(.proGold)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    // No-op: purchases are unavailable while the store is pending approval.
                } label: {
                    Label(title, systemImage: "cart")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(.proGold)
                .disabled(true)

                Text(ProConfig.purchaseComingSoonNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Activate card

    private var activateCard: some View {
        SettingsCard(title: "Activate License") {
            Text("Already purchased? Enter your license key below.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("XXXX-XXXX-XXXX-XXXX", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .disabled(isActivating)
                    .onSubmit { attemptActivate() }

                Button("Activate") {
                    attemptActivate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)

                if isActivating {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let message = activationMessage {
                HStack(spacing: 6) {
                    Image(systemName: activationMessageIsInfo ? "info.circle" : "xmark.circle.fill")
                        .foregroundStyle(activationMessageIsInfo ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(activationMessageIsInfo ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Activation action

    private func attemptActivate() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isActivating else { return }
        isActivating = true
        activationMessage = nil

        Task {
            let status = await licenseGate.activate(licenseKey: trimmed)
            isActivating = false
            switch status {
            case .valid:
                // LicenseGate already updated entitlements to .pro.
                // Clear the draft; status card will switch to the Pro view.
                keyDraft = ""
                activationMessage = nil
            case .invalid(let reason):
                // Display the server's rejection reason calmly as an informational note.
                activationMessage = reason
                activationMessageIsInfo = true
            case .offlineUnverified:
                activationMessage = "Could not reach the license server. Check your connection and try again."
                activationMessageIsInfo = false
            }
        }
    }
}

// MARK: - Preview

#Preview("License — Free") {
    LicenseView(licenseGate: LicenseGate())
        .frame(width: 580, height: 400)
}
