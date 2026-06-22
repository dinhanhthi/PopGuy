// SettingsCard.swift
// PopGuy — UI/SettingsWindow/Components
//
// Shared card container for the Providers and Actions settings tabs.
//
// Unlike GroupBox (whose label floats *above* the box, so consecutive cards
// blur together), the header lives INSIDE the card above a divider — each
// group reads as one clearly bounded unit, System Settings style.
//
// All spacing follows the shared SettingsMetrics 4pt scale so both tabs and
// every card render identically.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - SettingsMetrics

/// Shared metrics for the settings tabs (4pt base scale).
enum SettingsMetrics {
    /// Corner radius of a settings card.
    static let cardRadius: CGFloat = 10
    /// Inner padding of a card's header and content areas.
    static let cardPadding: CGFloat = 12
    /// Vertical gap between consecutive cards in a tab.
    static let cardSpacing: CGFloat = 16
    /// Vertical gap between rows inside a card's content area.
    static let contentSpacing: CGFloat = 10
    /// Outer padding of a tab's scrollable page.
    static let pagePadding: CGFloat = 20
    /// Uniform icon-content box for the Actions toolbar icon buttons (export,
    /// import, plugin import). Normalises differently-sized SF Symbols to the same
    /// button size; the narrow width tightens horizontal padding, the taller height
    /// gives a bit more vertical presence so the row lines up with the picker.
    static let toolbarIconWidth: CGFloat = 14
    static let toolbarIconHeight: CGFloat = 18
}

// MARK: - SettingsCard

/// A card with an in-card header (optional icon badge, title, optional
/// trailing accessory such as a Toggle), a divider, and caller-supplied
/// content rows below.
struct SettingsCard<Accessory: View, TitleAccessory: View, Content: View>: View {

    let icon: ActionIcon?
    let title: String
    /// Optional secondary line shown under the title in the header.
    let subtitle: String?
    /// When provided, the card is collapsible: a chevron is shown in the header,
    /// tapping the header (outside the accessory) toggles it, and the divider +
    /// content are hidden while collapsed. When nil, the card is always expanded
    /// and no chevron is shown (default behaviour).
    let isExpanded: Binding<Bool>?
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let titleAccessory: () -> TitleAccessory
    @ViewBuilder let content: () -> Content

    init(
        icon: ActionIcon? = nil,
        title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder titleAccessory: @escaping () -> TitleAccessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isExpanded = isExpanded
        self.accessory = accessory
        self.titleAccessory = titleAccessory
        self.content = content
    }

    /// Whether the body content is currently shown. Non-collapsible cards are
    /// always shown.
    private var showsContent: Bool { isExpanded?.wrappedValue ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if showsContent {
                Divider()

                VStack(alignment: .leading, spacing: SettingsMetrics.contentSpacing) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SettingsMetrics.cardPadding)
            }
        }
        .background(
            // Soft primary wash instead of NSColor.quaternarySystemFill
            // (which is macOS 14+; the deployment target is 13).
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 5) {
            if let icon {
                // Plain icon (no badge), drawn like in the floating toolbar
                // so an action is recognizable across both surfaces. The
                // fixed width keeps titles aligned across stacked cards.
                ActionIconView(icon: icon, font: .system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }

            // Title + optional title-adjacent accessory (e.g. "Built-in" badge),
            // with an optional description line beneath.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                    titleAccessory()
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            accessory()

            // Disclosure chevron, mirroring the History rows. Only shown for
            // collapsible cards.
            if let isExpanded {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, SettingsMetrics.cardPadding)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .onTapGesture {
            // Toggle only when collapsible; the accessory (e.g. a Toggle)
            // intercepts its own taps so flipping it never expands the card.
            if let isExpanded {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            }
        }
    }
}

// MARK: - Convenience inits

extension SettingsCard where TitleAccessory == EmptyView {
    /// Card with a trailing header accessory but no title-adjacent accessory.
    /// Covers HistoryView and SettingsView provider cards (GetAPIKeyLink).
    init(
        icon: ActionIcon? = nil,
        title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            icon: icon,
            title: title,
            subtitle: subtitle,
            isExpanded: isExpanded,
            accessory: accessory,
            titleAccessory: { EmptyView() },
            content: content
        )
    }
}

extension SettingsCard where Accessory == EmptyView, TitleAccessory == EmptyView {
    /// Card without any header accessories.
    init(
        icon: ActionIcon? = nil,
        title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            icon: icon,
            title: title,
            subtitle: subtitle,
            isExpanded: isExpanded,
            accessory: { EmptyView() },
            titleAccessory: { EmptyView() },
            content: content
        )
    }
}
