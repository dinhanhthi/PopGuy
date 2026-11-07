// ComposerWindow.swift
// PopGuy
//
// The Terminal Composer window: an activating, titled NSPanel hosting SwiftUI content.
//
// Design:
//   - Activating (no .nonactivatingPanel): PopGuy becomes the active app while the
//     composer is open, so it gets the keyboard and the selection pipeline sees it.
//     PopGuy stays an accessory app; the activation policy is never changed.
//   - Level one step below the toolbar's FloatingPanel (.floating), so the selection
//     toolbar renders above the composer.
//   - Opens centered on the screen with the mouse pointer; the size is remembered
//     with an AppKit frame autosave name.
//   - Closing returns focus to the app that was frontmost when the composer opened.

import AppKit
import SwiftUI

/// Floating composer window. Call `show()` to open it; `close()` (or the close
/// button) hides it and returns focus to the previously frontmost app.
@MainActor
final class ComposerWindow: NSPanel {

    private static let defaultContentSize = NSSize(width: 640, height: 420)
    private static let minimumContentSize = NSSize(width: 360, height: 220)
    private static let frameAutosaveName = "PopGuyComposerWindow"

    /// App that was frontmost (other than PopGuy) when the composer was shown.
    private var previousApp: NSRunningApplication?

    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "PopGuy Composer"
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Open on the current Space, also over a fullscreen terminal.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: rootView)
        // No SwiftUI-driven size constraints: contentMinSize and the saved frame rule.
        hostingView.sizingOptions = []
        contentView = hostingView

        contentMinSize = Self.minimumContentSize
        setContentSize(Self.defaultContentSize)
        // Restores the saved frame (if any) and saves later size changes.
        setFrameAutosaveName(Self.frameAutosaveName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: - Show / close

    /// Activates PopGuy and brings the composer to the front with key focus.
    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        if !isVisible {
            centerOnMouseScreen()
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        super.close()
        let app = previousApp
        previousApp = nil
        guard let app, !app.isTerminated else { return }
        if #available(macOS 14, *) {
            NSApp.yieldActivation(to: app)
        }
        app.activate(options: [])
    }

    // MARK: - Placement

    private func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        setFrame(
            NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height),
            display: false
        )
    }
}
