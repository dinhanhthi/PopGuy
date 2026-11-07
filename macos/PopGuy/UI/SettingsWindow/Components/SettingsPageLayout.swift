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
/// the page content, topped by the update banner when an update is available.
///
/// A band of window glass covers the top `SettingsMetrics.contentTopInset`, so
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
            VStack(spacing: 0) {
                UpdateBannerSlot()
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Pages put `pagePadding` above their first section or card, so
            // it lands at `contentTopInset`.
            .padding(.top, SettingsMetrics.contentTopInset - SettingsMetrics.pagePadding)

            // The titlebar band, over the content: the same glass as the window,
            // so content scrolled under the header disappears at `contentTopInset`
            // and the band and the body read as one surface. It catches clicks
            // (a control scrolled under it can't be clicked) and drags the window.
            WindowGlass(draggable: true)
                .frame(height: SettingsMetrics.contentTopInset)
                // From the content column's edge: below `bodyTopInset` the
                // pulled-in strip is the sidebar card's corner, not the band's.
                .padding(.leading, SettingsMetrics.pageContentPullLeading)

            // Controls centered on the traffic lights (y = 26).
            HStack(spacing: 8) {
                leading()
                Spacer(minLength: 0)
                // First claim on the free space, so a search field grows into it
                // instead of sharing it with the spacer.
                trailing()
                    .layoutPriority(1)
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

// MARK: - Update banner

/// The update banner at the top of every page's content (when an update is
/// available), from the `settingsUpdater` the Settings window puts in the
/// environment. Nothing without one (previews).
private struct UpdateBannerSlot: View {
    @Environment(\.settingsUpdater) private var updater

    var body: some View {
        if let updater {
            Banner(updater: updater)
        }
    }

    private struct Banner: View {
        @ObservedObject var updater: UpdaterController

        var body: some View {
            if updater.updateAvailable {
                UpdateBanner(version: updater.pendingVersion) {
                    updater.checkForUpdates()
                }
                // At `contentTopInset`, like the content (which starts
                // `pagePadding` above it), and at the content column's leading
                // edge, not pulled over the sidebar card.
                .padding(.top, SettingsMetrics.pagePadding)
                .padding(.leading, SettingsMetrics.pageContentPullLeading)
            }
        }
    }
}

private struct SettingsUpdaterKey: EnvironmentKey {
    static let defaultValue: UpdaterController? = nil
}

extension EnvironmentValues {
    /// The Settings window's updater, for the update banner of `SettingsPageLayout`.
    var settingsUpdater: UpdaterController? {
        get { self[SettingsUpdaterKey.self] }
        set { self[SettingsUpdaterKey.self] = newValue }
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
