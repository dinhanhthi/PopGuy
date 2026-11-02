// ToolbarSubmenuPresenter.swift
// PopGuy
//
// Shows the Menu toolbar style's "More actions" submenu (ToolbarSubmenuList) in
// its own borderless child panel beside the main menu card.
//
// Design:
//   - One lazily created FloatingPanel + NSHostingView, reused across shows; it
//     observes the toolbar's view model, so rows pick through the same path.
//   - Attached as a child window of the toolbar panel, so it moves and orders
//     with it and never takes the foreground from the source app.
//   - The More row reports hover-enter only, so the presenter tracks the pointer
//     itself while open (a short repeating timer on the main run loop): leaving
//     both the More row and the submenu card for a short grace period closes it.

import AppKit
import SwiftUI

/// Presents the Menu style's More actions submenu in a child panel.
///
/// Isolation: @MainActor — AppKit windows and the view model are main-thread-only.
@MainActor
final class ToolbarSubmenuPresenter {

    /// How often the pointer is checked while the submenu is open (seconds).
    private static let pointerCheckInterval: TimeInterval = 0.05
    /// How long the pointer may stay outside the More row and the submenu card
    /// before the submenu closes (seconds).
    private static let closeGrace: TimeInterval = 0.2

    private let viewModel: ToolbarViewModel
    private var panel: FloatingPanel?
    private var hostingView: NSHostingView<ToolbarSubmenuList>?

    /// The More actions row in screen coordinates, for the hover check.
    private var rowScreenFrame: NSRect = .zero
    /// Toolbar zoom at the last show, for the card's outer padding.
    private var zoom: CGFloat = 1
    private var pointerTimer: Timer?
    /// When the pointer left both the row and the card; nil while inside.
    private var pointerOutsideSince: TimeInterval?

    init(viewModel: ToolbarViewModel) {
        self.viewModel = viewModel
    }

    /// The submenu panel's frame while it is visible, else nil.
    var visibleFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    /// Shows the submenu beside the main menu card, or re-places it when open.
    ///
    /// - Parameters:
    ///   - moreRowFrameInHost: The More actions row's frame in SwiftUI's global
    ///     space of `hostView` (top-left origin).
    ///   - hostView: The toolbar panel's hosting view.
    ///   - menuCardFrameOnScreen: The main menu's visible card frame in screen
    ///     coordinates.
    ///   - zoom: The toolbar zoom scale.
    func show(moreRowFrameInHost: CGRect, hostView: NSView, menuCardFrameOnScreen: NSRect, zoom: CGFloat) {
        guard let parent = hostView.window else { return }

        let rowOnScreen = screenFrame(of: moreRowFrameInHost, in: hostView, window: parent)
        rowScreenFrame = rowOnScreen
        self.zoom = zoom

        let (panel, hostingView) = panelAndHostingView()
        let panelSize = hostingView.fittingSize
        let cardSize = CGSize(
            width: panelSize.width - 2 * ToolbarView.outerHorizontalPadding * zoom,
            height: panelSize.height - (ToolbarView.outerTopPadding + ToolbarView.outerBottomPadding) * zoom
        )
        let rowCenter = NSPoint(x: rowOnScreen.midX, y: rowOnScreen.midY)
        let screenFrame = NSScreen.screens.first { $0.frame.contains(rowCenter) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? parent.frame
        let cardOrigin = submenuCardOrigin(
            cardSize: cardSize,
            rowFrame: rowOnScreen,
            menuCardFrame: menuCardFrameOnScreen,
            within: screenFrame,
            topOffset: submenuTopOffset * zoom
        )
        let panelOrigin = NSPoint(
            x: cardOrigin.x - ToolbarView.outerHorizontalPadding * zoom,
            y: cardOrigin.y - ToolbarView.outerBottomPadding * zoom
        )
        // setFrame (not setFrameOrigin) so the move is not counted as a user drag.
        panel.setFrame(NSRect(origin: panelOrigin, size: panelSize), display: true)

        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible {
            panel.orderFront(nil)
        }
        if !viewModel.isMenuSubmenuOpen {
            viewModel.isMenuSubmenuOpen = true
        }
        pointerOutsideSince = nil
        startPointerTimer()
    }

    /// Closes the submenu immediately and detaches it from the toolbar panel.
    /// Safe to call when already hidden.
    func hide() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        pointerOutsideSince = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if viewModel.isMenuSubmenuOpen {
            viewModel.isMenuSubmenuOpen = false
        }
    }

    // MARK: - Panel

    private func panelAndHostingView() -> (FloatingPanel, NSHostingView<ToolbarSubmenuList>) {
        if let panel, let hostingView {
            return (panel, hostingView)
        }
        let panel = FloatingPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        // The submenu stays attached beside the menu; the SwiftUI card draws
        // its own shadow (FloatingPanel already disables the window shadow).
        panel.isMovableByWindowBackground = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        let hostingView = NSHostingView(rootView: ToolbarSubmenuList(viewModel: viewModel))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        // Like the toolbar's hosting view: no window min/max size from the
        // content, so a re-show with a different row count is sized by setFrame.
        hostingView.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hostingView
        self.panel = panel
        self.hostingView = hostingView
        return (panel, hostingView)
    }

    /// Converts a frame in SwiftUI's global space of `view` (top-left origin)
    /// to screen coordinates.
    private func screenFrame(of frame: CGRect, in view: NSView, window: NSWindow) -> NSRect {
        let local = view.isFlipped
            ? frame
            : NSRect(x: frame.minX, y: view.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        return window.convertToScreen(view.convert(local, to: nil))
    }

    // MARK: - Hover grace

    private func startPointerTimer() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pointerCheckInterval, repeats: true) { [weak self] timer in
            guard self != nil else {
                timer.invalidate()
                return
            }
            // Added to the main run loop below, so it always fires on the main thread.
            MainActor.assumeIsolated {
                self?.checkPointer()
            }
        }
        // Common modes: keep checking during event tracking (e.g. a drag).
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func checkPointer() {
        guard let panel, panel.isVisible else {
            hide()
            return
        }
        let pointer = NSEvent.mouseLocation
        let cardFrame = NSRect(
            x: panel.frame.minX + ToolbarView.outerHorizontalPadding * zoom,
            y: panel.frame.minY + ToolbarView.outerBottomPadding * zoom,
            width: panel.frame.width - 2 * ToolbarView.outerHorizontalPadding * zoom,
            height: panel.frame.height - (ToolbarView.outerTopPadding + ToolbarView.outerBottomPadding) * zoom
        )
        if cardFrame.contains(pointer) || rowScreenFrame.contains(pointer) {
            pointerOutsideSince = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let since = pointerOutsideSince {
            if now - since >= Self.closeGrace { hide() }
        } else {
            pointerOutsideSince = now
        }
    }
}
