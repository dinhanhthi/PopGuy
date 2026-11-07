// SettingsGroup.swift
// PopGuy — UI/SettingsWindow/Components
//
// The card layout of the form-like Settings pages (General, Triggers,
// Appearance, Ignore): a section title above a solid `GlassCard` holding the
// rows, an optional caption below. Replaces the system grouped `Form`, which
// macOS caps at ~700 pt and centers, so these pages fill the column like the
// card pages (Providers, Actions, History, About).
//
// Rows are separated by `SettingsDivider()`s the caller puts between them (no
// view-children API on macOS 13). `.settingsRow` lays out a `LabeledContent`
// like a grouped Form row: title and caption leading, the control trailing.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - SettingsGroup

/// A titled card of settings rows, with an optional caption under the card.
/// Separate the rows with `SettingsDivider()`.
struct SettingsGroup<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String?, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, SettingsMetrics.cardPadding)
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, SettingsMetrics.cardPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.cardPadding)
            }
        }
    }
}

/// Vertical rhythm of the rows in a `SettingsGroup`.
private enum SettingsRowMetrics {
    /// Space above and below each row (a divider sits in the middle of two rows' padding).
    static let verticalPadding: CGFloat = 10
}

// MARK: - SettingsDivider

/// The divider between two rows of a `SettingsGroup`, inset like the rows.
struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }
}

// MARK: - SettingsRowStyle

/// A grouped-Form-like row for `LabeledContent`: the label (a title, then an
/// optional caption `Text` styled by the caller) leading, the control trailing.
/// The label dims when the row is `.disabled`; controls dim themselves.
struct SettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                configuration.label
            }
            .fixedSize(horizontal: false, vertical: true)
            .dimmedWhenDisabled()

            Spacer(minLength: 12)

            configuration.content
        }
    }
}

extension LabeledContentStyle where Self == SettingsRowStyle {
    /// Title and caption leading, control trailing (see `SettingsRowStyle`).
    static var settingsRow: SettingsRowStyle { SettingsRowStyle() }
}
