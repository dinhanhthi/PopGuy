// SettingsPageLayout.swift
// PopGuy — UI/SettingsWindow/Components
//
// The layout of a Settings page: a header row in the window's titlebar band
// (page tabs at the leading edge, search/buttons at the trailing edge) and the
// page content below it. There are no page titles.
//
// The detail column reaches the window's top edge (the Settings layout ignores
// the top safe area), so the header row sits in the band the empty unified
// toolbar gives the titlebar, next to the traffic lights over the sidebar.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - SettingsPageLayout

/// A Settings page: a `SettingsMetrics.headerRowHeight` header row (`leading`
/// views lined up with the content, `trailing` views at the trailing edge) over
/// the page content.
///
/// A band of window glass covers the top `SettingsMetrics.bodyTopInset`, so
/// content scrolled under the titlebar never shows through or takes clicks.
/// The band sits under the header row: the row's controls get their clicks,
/// and a drag on its empty space lands on the band, which moves the window.
struct SettingsPageLayout<Leading: View, Trailing: View, Content: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    init(
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.leading = leading
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .top) {
            content()
                // No background of the page's own: grouped Forms and lists show
                // the window glass between their sections.
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Pages put `pagePadding` (a grouped Form ~20 pt) above their first
                // section or card, so it lands at `bodyTopInset`.
                .padding(.top, SettingsMetrics.bodyTopInset - SettingsMetrics.pagePadding)

            // The titlebar band, over the content: the same glass as the window,
            // so content scrolled under the header disappears at `bodyTopInset`
            // and the band and the body read as one surface. It catches clicks
            // (a control scrolled under it can't be clicked) and drags the window.
            WindowGlass(draggable: true)
                .frame(height: SettingsMetrics.bodyTopInset)

            // Controls centered on the traffic lights (y = 26).
            HStack(spacing: 8) {
                leading()
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.leading, SettingsMetrics.pagePadding)
            .padding(.trailing, 12)
            .frame(height: SettingsMetrics.headerRowHeight)
        }
        // 12 pt from the sidebar card to the content (and the header controls);
        // nothing opaque is drawn in the pulled-in strip.
        .padding(.leading, -SettingsMetrics.pageContentPullLeading)
    }
}

// MARK: - Convenience inits

extension SettingsPageLayout where Leading == EmptyView, Trailing == EmptyView {
    /// A page with no header-row controls.
    init(@ViewBuilder content: @escaping () -> Content) {
        self.init(leading: { EmptyView() }, trailing: { EmptyView() }, content: content)
    }
}

extension SettingsPageLayout where Trailing == EmptyView {
    /// A page with leading header-row controls only (e.g. page tabs).
    init(
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(leading: leading, trailing: { EmptyView() }, content: content)
    }
}

extension SettingsPageLayout where Leading == EmptyView {
    /// A page with trailing header-row controls only (e.g. search, buttons).
    init(
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(leading: { EmptyView() }, trailing: trailing, content: content)
    }
}
