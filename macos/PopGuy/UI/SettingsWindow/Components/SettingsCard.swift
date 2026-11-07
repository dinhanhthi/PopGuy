// SettingsCard.swift
// PopGuy — UI/SettingsWindow/Components
//
// Shared card container for the Providers and Actions settings tabs.
//
// Unlike GroupBox (whose label floats *above* the box, so consecutive cards
// blur together), the header lives INSIDE the card above a divider — each
// group reads as one clearly bounded unit, System Settings style. An optional
// second header row ("header detail") sits under the title row and stays
// visible while a collapsible card is collapsed.
//
// All spacing follows the shared SettingsMetrics 4pt scale so both tabs and
// every card render identically.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - Settings caption font

extension Font {
    /// Small text in the Settings window: descriptions, warnings and errors,
    /// footers, banners, badges and small button labels. One step above the
    /// system caption (11 pt, not 10) and still below row titles (13 pt).
    static let settingsCaption: Font = .subheadline
}

// MARK: - SettingsMetrics

/// Shared metrics for the settings tabs (4pt base scale).
enum SettingsMetrics {
    /// Corner radius of a settings card (`GlassCard`'s content-card radius).
    static let cardRadius: CGFloat = 14
    /// Inner padding of a card's header and content areas.
    static let cardPadding: CGFloat = 12
    /// Vertical gap between consecutive cards in a tab.
    static let cardSpacing: CGFloat = 16
    /// Vertical gap between rows inside a card's content area.
    static let contentSpacing: CGFloat = 10
    /// Outer padding of a tab's scrollable page.
    static let pagePadding: CGFloat = 20
    /// Extra vertical breathing room between Settings sidebar items.
    static let sidebarItemVerticalPadding: CGFloat = 4
    /// Height of the Settings header row: the band the empty unified NSToolbar
    /// gives the titlebar (traffic lights centered at half of it). Use this, not
    /// the top safe-area inset: AppKit reports a taller inset (66 pt on macOS 27)
    /// than the band the traffic lights are centered in.
    static let headerRowHeight: CGFloat = 52
    /// Where the sidebar card starts, from the window's top. About 8 pt under
    /// the header row's controls: they are centered on the traffic lights
    /// (y = 26) and at most 28–34 pt tall, so they end around y = 41–43. The
    /// detail column's content starts lower, at `contentTopInset`.
    static let bodyTopInset: CGFloat = 48
    /// Where the detail column's content starts, from the window's top: 12 pt
    /// lower than `bodyTopInset` (the sidebar card's top), to leave about 16 pt
    /// under the header row's tabs and buttons. A page's first section or card
    /// lands here, and the detail column's titlebar band is this tall.
    static let contentTopInset: CGFloat = 60
    /// How far a page is pulled toward the sidebar card. Pages pad their
    /// content by `pagePadding` (20 pt); pulling them 8 pt left leaves 12 pt to
    /// the card, like the card's own 12 pt inset from the window edge.
    static let pageContentPullLeading: CGFloat = 8
}

// MARK: - Disabled row label

extension View {
    /// Dims a row's title and caption when the row is `.disabled`, as much as its
    /// `CompactSwitch` dims itself. Apply to the label of a `LabeledContent` row.
    func dimmedWhenDisabled() -> some View {
        modifier(DimmedWhenDisabled())
    }
}

private struct DimmedWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - SettingsCard

/// A card with an in-card header (optional icon badge, title, optional
/// trailing accessory such as a Toggle, optional second "header detail" row),
/// a divider, and caller-supplied content rows below.
struct SettingsCard<Accessory: View, TitleAccessory: View, HeaderDetail: View, Content: View>: View {

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
    /// Optional second header row (e.g. a row of switches), rendered below the
    /// title row and left-aligned with the title/subtitle column. Part of the
    /// header, so it stays visible while the card is collapsed. Taps on it never
    /// toggle expansion. Pass `EmptyView` (the convenience inits do) to omit it.
    @ViewBuilder let headerDetail: () -> HeaderDetail
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        icon: ActionIcon? = nil,
        title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder titleAccessory: @escaping () -> TitleAccessory,
        @ViewBuilder headerDetail: @escaping () -> HeaderDetail,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isExpanded = isExpanded
        self.accessory = accessory
        self.titleAccessory = titleAccessory
        self.headerDetail = headerDetail
        self.content = content
    }

    /// Whether the body content is currently shown. Non-collapsible cards are
    /// always shown.
    private var showsContent: Bool { isExpanded?.wrappedValue ?? true }

    /// Whether a header-detail row was supplied. `EmptyView` means none, so no
    /// row (and no extra padding) is rendered.
    private var hasHeaderDetail: Bool { HeaderDetail.self != EmptyView.self }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if hasHeaderDetail {
                headerDetailRow
            }

            if showsContent {
                Divider()

                VStack(alignment: .leading, spacing: SettingsMetrics.contentSpacing) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SettingsMetrics.cardPadding)
            }
        }
        // Solid surface + 1 pt edge on the single window glass (no material per card).
        .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                    titleAccessory()
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.settingsCaption)
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
                withAnimation(reduceMotion ? nil : Motion.toggle) {
                    isExpanded.wrappedValue.toggle()
                }
            }
        }
    }

    /// Second header row. The leading inset (icon width + header HStack
    /// spacing) aligns it with the title/subtitle column. The empty tap
    /// gesture swallows taps on the row — including on control captions — so
    /// they never toggle card expansion.
    private var headerDetailRow: some View {
        headerDetail()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, icon == nil ? 0 : 20 + 5)
            .padding(.horizontal, SettingsMetrics.cardPadding)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .onTapGesture {}
    }
}

// MARK: - Convenience inits

extension SettingsCard where HeaderDetail == EmptyView {
    /// Card with both header accessories but no header-detail row.
    /// Covers the SettingsView Babylon BGL card.
    init(
        icon: ActionIcon? = nil,
        title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder titleAccessory: @escaping () -> TitleAccessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            icon: icon,
            title: title,
            subtitle: subtitle,
            isExpanded: isExpanded,
            accessory: accessory,
            titleAccessory: titleAccessory,
            headerDetail: { EmptyView() },
            content: content
        )
    }
}

extension SettingsCard where TitleAccessory == EmptyView, HeaderDetail == EmptyView {
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
            headerDetail: { EmptyView() },
            content: content
        )
    }
}

extension SettingsCard where Accessory == EmptyView, TitleAccessory == EmptyView, HeaderDetail == EmptyView {
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
            headerDetail: { EmptyView() },
            content: content
        )
    }
}
