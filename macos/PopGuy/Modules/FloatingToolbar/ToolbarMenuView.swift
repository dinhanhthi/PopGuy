// ToolbarMenuView.swift
// PopGuy
//
// SwiftUI views for the "Menu" toolbar style: the idle toolbar shown as a
// native-looking context menu inside the toolbar card (ToolbarMenuList), and
// the hover "More actions" submenu card hosted in its own child panel
// (ToolbarSubmenuList). Rows never take focus: the panel is non-activating, so
// the menu has no keyboard navigation.

import AppKit
import SwiftUI

// MARK: - Row metrics

/// Layout values shared by the menu and submenu rows (unzoomed points).
private enum ToolbarMenuMetrics {
    static let rowHeight: CGFloat = 24
    static let rowHorizontalPadding: CGFloat = 8
    static let iconSlot: CGFloat = 18
    static let iconTitleSpacing: CGFloat = 6
    static let maxTitleWidth: CGFloat = 260
    static let chevronGap: CGFloat = 16
    /// Horizontal inset of the rows from the card edge.
    static let cardHorizontalPadding: CGFloat = 5
}

// MARK: - ToolbarMenuRow

/// One menu row: a fixed-width icon slot, a single-line title and an optional
/// trailing chevron. Hover draws an accent-colored rounded highlight with white
/// content, like a native macOS menu item. Disabled rows are dimmed and inert.
struct ToolbarMenuRow: View {
    let icon: ActionIcon
    let title: String
    var showsChevron: Bool = false
    var isDisabled: Bool = false
    /// Keeps the highlight on without hover (the More actions row while its
    /// submenu is open).
    var forceHighlighted: Bool = false
    let zoom: CGFloat
    /// Called when the pointer enters the row (never on exit).
    var onHoverEnter: (() -> Void)?
    let action: () -> Void

    @State private var isHovered = false

    private var isHighlighted: Bool { !isDisabled && (isHovered || forceHighlighted) }

    /// Chrome font: the body text style's point size scaled by the zoom.
    private var font: Font {
        .system(size: NSFont.preferredFont(forTextStyle: .body).pointSize * zoom)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: ToolbarMenuMetrics.iconTitleSpacing * zoom) {
                ActionIconView(icon: icon, font: font)
                    .frame(
                        width: ToolbarMenuMetrics.iconSlot * zoom,
                        height: ToolbarMenuMetrics.iconSlot * zoom
                    )
                Text(title)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: ToolbarMenuMetrics.maxTitleWidth * zoom, alignment: .leading)
                if showsChevron {
                    Spacer(minLength: ToolbarMenuMetrics.chevronGap * zoom)
                    Image(systemName: "chevron.right")
                        .font(.system(
                            size: NSFont.preferredFont(forTextStyle: .body).pointSize * 0.8 * zoom,
                            weight: .semibold
                        ))
                        .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
                }
            }
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .padding(.horizontal, ToolbarMenuMetrics.rowHorizontalPadding * zoom)
            .frame(height: ToolbarMenuMetrics.rowHeight * zoom)
            // Every row stretches to the widest one, so all highlights match.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: highlightRadius, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarMenuRowStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        // No hover animation: native menus switch the highlight instantly.
        .onHover { inside in
            isHovered = inside
            if inside { onHoverEnter?() }
        }
        .accessibilityLabel(title)
    }

    /// Concentric with the card: card radius minus the row inset.
    private var highlightRadius: CGFloat {
        ToolbarMetrics(zoom: zoom).cardRadius - ToolbarMenuMetrics.cardHorizontalPadding * zoom
    }
}

/// Passthrough button style: the row draws its own highlight, and native menu
/// items show no pressed treatment.
private struct ToolbarMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Shared row content

private extension ToolbarViewModel {
    /// Icon for an action's menu row: the custom action's own icon (as in the
    /// bar), else the built-in SF Symbol. nil for a custom action that no
    /// longer exists (its row is skipped).
    func menuRowIcon(for id: ActionIdentifier) -> ActionIcon? {
        if case .custom(let uuid) = id {
            return customActions.first(where: { $0.id == uuid })?.icon
        }
        return .sfSymbol(menuTitleAndSymbol(for: id).1)
    }
}

/// A menu row for one action; nothing when the action no longer exists.
@ViewBuilder
private func actionRow(
    for id: ActionIdentifier,
    viewModel: ToolbarViewModel,
    zoom: CGFloat,
    onHoverEnter: (() -> Void)?
) -> some View {
    if let icon = viewModel.menuRowIcon(for: id) {
        ToolbarMenuRow(
            icon: icon,
            title: viewModel.menuTitleAndSymbol(for: id).0,
            isDisabled: viewModel.isMenuItemDisabled(for: id),
            zoom: zoom,
            onHoverEnter: onHoverEnter,
            action: { viewModel.onMenuPick?(id) }
        )
    }
}

// MARK: - ToolbarMenuList

/// The Menu style's main menu, rendered inside the toolbar card: the toolbar
/// actions, a "More actions" row opening the submenu on hover, then the system
/// rows (Ignore this site / app, Settings) below a separator.
struct ToolbarMenuList: View {
    @ObservedObject var viewModel: ToolbarViewModel
    let onIgnoreSite: () -> Void
    let onIgnoreApp: () -> Void
    let onOpenSettings: () -> Void

    /// The More actions row's frame in global space, measured via
    /// GeometryReader + onAppear/onChange (preference changes do not fire under
    /// the panel's intrinsic-sizing hosting view).
    @State private var moreRowFrame: CGRect = .zero

    private var zoom: CGFloat { viewModel.toolbarZoom.scale }

    private var hasSystemRows: Bool {
        viewModel.showsIgnoreSite || viewModel.showsIgnoreAppButton || viewModel.showsSettingsButton
    }

    /// Any row other than More actions closes the submenu when hovered.
    private func closeSubmenu() {
        viewModel.onMenuSubmenuHover?(nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(viewModel.orderedActions, id: \.self) { id in
                actionRow(for: id, viewModel: viewModel, zoom: zoom, onHoverEnter: closeSubmenu)
            }

            if viewModel.hasOverflow {
                moreRow
            }

            if hasSystemRows {
                Divider()
                    .padding(.horizontal, ToolbarMenuMetrics.rowHorizontalPadding * zoom)
                    .padding(.vertical, 5 * zoom)
                systemRows
            }
        }
        .padding(.vertical, submenuTopOffset * zoom)
        .padding(.horizontal, ToolbarMenuMetrics.cardHorizontalPadding * zoom)
    }

    private var moreRow: some View {
        ToolbarMenuRow(
            icon: .sfSymbol("line.3.horizontal"),
            title: "More actions",
            showsChevron: true,
            forceHighlighted: viewModel.isMenuSubmenuOpen,
            zoom: zoom,
            onHoverEnter: { viewModel.onMenuSubmenuHover?(moreRowFrame) },
            // Clicking opens the submenu too (same as hovering).
            action: { viewModel.onMenuSubmenuHover?(moreRowFrame) }
        )
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { moreRowFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { moreRowFrame = $0 }
            }
        )
    }

    @ViewBuilder
    private var systemRows: some View {
        if viewModel.showsIgnoreSite {
            ToolbarMenuRow(
                icon: .sfSymbol("nosign"),
                title: "Ignore this site",
                zoom: zoom,
                onHoverEnter: closeSubmenu,
                action: onIgnoreSite
            )
        }
        if viewModel.showsIgnoreAppButton {
            ToolbarMenuRow(
                icon: .sfSymbol("eye.slash"),
                title: "Ignore this app",
                isDisabled: viewModel.sourceBundleID == nil,
                zoom: zoom,
                onHoverEnter: closeSubmenu,
                action: onIgnoreApp
            )
        }
        if viewModel.showsSettingsButton {
            ToolbarMenuRow(
                icon: .sfSymbol("gear"),
                title: "Settings",
                zoom: zoom,
                onHoverEnter: closeSubmenu,
                action: onOpenSettings
            )
        }
    }
}

// MARK: - ToolbarSubmenuList

/// The Menu style's More actions submenu: the overflow actions in their own
/// card (same chrome as the toolbar card), with the toolbar's outer transparent
/// padding so the shadow has room. Hosted in a child panel by the controller.
struct ToolbarSubmenuList: View {
    @ObservedObject var viewModel: ToolbarViewModel

    private var zoom: CGFloat { viewModel.toolbarZoom.scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Rows here never report hover: closing the submenu on entering it
            // would defeat it.
            ForEach(viewModel.overflowActions, id: \.self) { id in
                actionRow(for: id, viewModel: viewModel, zoom: zoom, onHoverEnter: nil)
            }
        }
        .padding(.vertical, submenuTopOffset * zoom)
        .padding(.horizontal, ToolbarMenuMetrics.cardHorizontalPadding * zoom)
        .modifier(ToolbarCardBackground(cornerRadius: ToolbarMetrics(zoom: zoom).cardRadius))
        .fixedSize()
        .padding(.top, ToolbarView.outerTopPadding * zoom)
        .padding(.horizontal, ToolbarView.outerHorizontalPadding * zoom)
        .padding(.bottom, ToolbarView.outerBottomPadding * zoom)
        .fixedSize()
    }
}
