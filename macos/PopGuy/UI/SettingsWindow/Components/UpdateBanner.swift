// UpdateBanner.swift
// PopGuy — UI/SettingsWindow/Components
//
// Compact accent-tinted banner shown at the top of the Settings detail column
// when a new version is available. Presentation-only — accepts version string
// and action closure; has no dependency on UpdaterController.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - UpdateBanner

/// Accent-tinted banner that announces an available update and offers a one-tap
/// action to start the install / show the Sparkle update sheet.
struct UpdateBanner: View {
    /// The pending version string to display (e.g. "1.4.2"), or nil when unknown.
    let version: String?
    /// Called when the user taps "Update now".
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)

            // Two defenses keep this interpolation safe:
            // (1) Swift resolves this as a verbatim `String` (NOT a `LocalizedStringKey`),
            //     so no markdown is interpreted; (2) the version string was already sanitized
            //     by `UpdaterController.sanitizedVersion` (ASCII allow-list, strips markdown
            //     metacharacters). A future change that types this as LocalizedStringKey, or
            //     weakens the sanitizer, would re-open markdown interpretation.
            Text(version.map { v in "Version \(v) is available" } ?? "An update is available")
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Button("Update now") {
                action()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .fontWeight(.medium)
        }
        .font(.caption)
        .padding(.horizontal, SettingsMetrics.pagePadding)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
