// RegionSelectionOverlay.swift
// PopGuy
//
// Full-screen crosshair drag-to-select overlay used to pick a screen region
// for OCR capture.

import AppKit

/// Result of a completed region selection.
///
/// `rect` and `mouseUpPoint` are in GLOBAL QUARTZ coordinates (origin
/// top-left, y increasing downward) — the same space `ScreenshotCapturer`
/// expects, so the result can be passed straight through.
struct RegionSelectionResult {
    /// The selected rectangle, ready for `ScreenshotCapturer.captureImage(of:on:)`.
    let rect: CGRect
    /// The point where the user released the mouse. Used as the toolbar anchor.
    let mouseUpPoint: CGPoint
    /// The screen the selection ended on (contains `mouseUpPoint`).
    let screen: NSScreen
}

/// Presents a single transparent, borderless, non-activating window spanning
/// the union of all `NSScreen.screens` frames, so the crosshair cursor and
/// rubber-band selection can cross monitor boundaries. Drag to select a
/// region; `Esc` or a zero-area click cancels.
///
/// ## Coordinate conversion
/// AppKit local/window coordinates have origin bottom-left, y increasing
/// upward; `ScreenshotCapturer`/`OCRCaptureController` need GLOBAL QUARTZ
/// coordinates: origin top-left of the *primary* screen, y increasing
/// downward. The overlay window's frame is set to the union of all screen
/// frames (in AppKit global space), so converting a point/rect drawn inside
/// the overlay happens in two steps:
///   1. window-local -> AppKit global: add the window's frame origin.
///   2. AppKit global -> Quartz global: `quartzY = primaryScreenHeight - appKitY`
///      for a point, or `quartzY = primaryScreenHeight - appKitY - height` for
///      a rect (whose AppKit origin is its bottom-left corner, so the rect's
///      top edge sits `height` above `origin.y`). `x` is unchanged — both
///      spaces share the same horizontal axis and origin.
/// This mirrors `ToolbarController.flipToAppKit`'s inverse.
///
/// Isolation: @MainActor — hosts an NSWindow/NSView, main-thread-only.
@MainActor
final class RegionSelectionOverlay {

    private var window: OverlayWindow?
    private var completion: (@MainActor (RegionSelectionResult?) -> Void)?

    /// Present the overlay and drag-select a region. Calls `completion`
    /// exactly once (on MainActor) with the result, or `nil` on cancel, then
    /// tears down all overlay state.
    func present(completion: @escaping @MainActor (RegionSelectionResult?) -> Void) {
        self.completion = completion

        let screens = NSScreen.screens
        // Union of all screen frames, in AppKit global coordinates (origin
        // bottom-left of the primary screen, y increasing upward).
        let unionFrame = screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !unionFrame.isEmpty else {
            self.completion = nil
            completion(nil)
            return
        }

        let overlayView = OverlaySelectionView(frame: NSRect(origin: .zero, size: unionFrame.size))
        overlayView.onFinish = { [weak self] localRect, localMouseUpPoint in
            self?.finish(localRect: localRect, localMouseUpPoint: localMouseUpPoint, screens: screens)
        }

        let window = OverlayWindow(contentRect: unionFrame)
        window.contentView = overlayView
        self.window = window

        NSCursor.crosshair.push()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlayView)
    }

    /// `localRect`/`localMouseUpPoint` are in the overlay window's own local
    /// coordinate space (origin bottom-left of the window, matching AppKit
    /// points) or `nil` on cancel/zero-area click. `screens` is the snapshot
    /// taken when the overlay was presented.
    private func finish(localRect: NSRect?, localMouseUpPoint: NSPoint?, screens: [NSScreen]) {
        let windowOrigin = window?.frame.origin ?? .zero

        NSCursor.pop()
        window?.orderOut(nil)
        window = nil

        let completion = self.completion
        self.completion = nil

        guard let localRect, let localMouseUpPoint else {
            completion?(nil)
            return
        }

        // Step 1: window-local -> AppKit global.
        let appKitRect = localRect.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y)
        let appKitMouseUpPoint = CGPoint(
            x: localMouseUpPoint.x + windowOrigin.x,
            y: localMouseUpPoint.y + windowOrigin.y
        )

        // The screen the drag ended on, resolved in AppKit space (NSScreen.frame
        // is AppKit global) before converting to Quartz.
        let resolvedScreen = screens.first { $0.frame.contains(appKitMouseUpPoint) }
            ?? screens.first { $0.frame.contains(CGPoint(x: appKitRect.midX, y: appKitRect.midY)) }
            ?? NSScreen.main
            ?? screens.first

        guard let resolvedScreen else {
            completion?(nil)
            return
        }

        // Step 2: AppKit global -> Quartz global. Primary screen is
        // `NSScreen.screens.first` by AppKit convention (matches
        // `ToolbarController.flipToAppKit`'s use of the same anchor).
        let primaryScreenHeight = screens.first?.frame.height ?? 0
        let quartzRect = CGRect(
            x: appKitRect.origin.x,
            y: primaryScreenHeight - appKitRect.origin.y - appKitRect.height,
            width: appKitRect.width,
            height: appKitRect.height
        )
        let quartzMouseUpPoint = CGPoint(
            x: appKitMouseUpPoint.x,
            y: primaryScreenHeight - appKitMouseUpPoint.y
        )

        completion?(RegionSelectionResult(rect: quartzRect, mouseUpPoint: quartzMouseUpPoint, screen: resolvedScreen))
    }
}

// MARK: - Overlay window

/// Borderless, transparent, non-activating window that hosts the selection
/// view. Modeled after `FloatingToolbar/FloatingPanel.swift`'s idioms
/// (`.nonactivatingPanel`, transparent background, no window shadow), but at
/// `.screenSaver` level so it sits above everything, including the floating
/// toolbar, while a capture is in progress.
@MainActor
private final class OverlayWindow: NSPanel {

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
        isReleasedWhenClosed = false
    }

    /// Necessary to receive `keyDown` for `Esc` cancellation. Because the
    /// window is `.nonactivatingPanel`, becoming key does not activate PopGuy
    /// or steal focus from the app the user was in.
    override var canBecomeKey: Bool { true }
}

// MARK: - Selection view

/// Draws the dimmed backdrop with the active selection rectangle punched
/// clear, and handles the mouse-drag / Esc interaction.
@MainActor
private final class OverlaySelectionView: NSView {

    /// `(rect, mouseUpPoint)` in this view's local coordinate space on a
    /// committed drag, or `(nil, nil)` on cancel / zero-area click.
    var onFinish: ((NSRect?, NSPoint?) -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var isFinished = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard startPoint != nil else { return }
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint else { return }
        let end = convert(event.locationInWindow, from: nil)
        let rect = NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        startPoint = nil
        currentPoint = nil

        guard rect.width > 0, rect.height > 0 else {
            finish(rect: nil, mouseUpPoint: nil)
            return
        }
        finish(rect: rect, mouseUpPoint: end)
    }

    override func keyDown(with event: NSEvent) {
        // kVK_Escape == 53.
        if event.keyCode == 53 {
            cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        startPoint = nil
        currentPoint = nil
        finish(rect: nil, mouseUpPoint: nil)
    }

    private func finish(rect: NSRect?, mouseUpPoint: NSPoint?) {
        guard !isFinished else { return }
        isFinished = true
        needsDisplay = true
        onFinish?(rect, mouseUpPoint)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        guard let start = startPoint, let current = currentPoint else { return }
        let selectionRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )

        // Punch the selection rect fully clear (removes the dim overlay
        // there) using .clear compositing, which requires the view's backing
        // store to be non-opaque (the window is `isOpaque = false`).
        if let context = NSGraphicsContext.current {
            context.saveGraphicsState()
            context.compositingOperation = .clear
            NSColor.clear.setFill()
            selectionRect.fill()
            context.restoreGraphicsState()
        }

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}
