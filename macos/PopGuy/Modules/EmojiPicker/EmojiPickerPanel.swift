// EmojiPickerPanel.swift
// PopGuy — EmojiPicker
//
// Borderless floating panel of the emoji picker (ported from FastMoji's hotkey picker).
// Non-activating: the source app stays frontmost while the panel is key, so the search
// field takes the keys and the inserted emoji goes back to the source app.
//
// Isolation: MainActor (AppKit windows).

import AppKit
import SwiftUI

final class EmojiPickerPanel: NSPanel {
    /// Header (44) + divider (1) + grid (288).
    static let contentSize = NSSize(width: 360, height: 333)

    private static let caretGap: CGFloat = 4
    private static let cornerRadius: CGFloat = 12

    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false

        contentView = Self.makeBackground(hosting: EmojiPickerHostingView(rootView: content))
        setContentSize(Self.contentSize)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Every hide path (Esc, resign key, click outside) also drops a hover tooltip attached
    /// as a child window: ordering the panel front again would re-show it otherwise.
    override func orderOut(_ sender: Any?) {
        if childWindows?.isEmpty == false {
            HoverTooltipPanelPresenter.shared.hide(anchor: nil)
        }
        super.orderOut(sender)
    }

    /// Vibrant background that stays active: a SwiftUI material renders flat in a window of
    /// an app that is never active.
    private static func makeBackground(hosting: NSView) -> NSVisualEffectView {
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = cornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        return background
    }

    /// Panel frame below the caret (above it when there is no room), inside the caret's screen.
    /// `caret` is in AppKit screen coordinates (bottom-left origin).
    static func frame(caret: NSRect) -> NSRect {
        let size = contentSize
        let screen = NSScreen.screens.first { NSMouseInRect(caret.origin, $0.frame, false) }
            ?? NSScreen.main
        var origin = NSPoint(x: caret.minX, y: caret.minY - caretGap - size.height)
        guard let visible = screen?.visibleFrame else { return NSRect(origin: origin, size: size) }

        if origin.y < visible.minY {
            origin.y = caret.maxY + caretGap
        }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        return NSRect(origin: origin, size: size)
    }
}

/// Takes the first click, so a click on a cell or the gear acts at once.
private final class EmojiPickerHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
