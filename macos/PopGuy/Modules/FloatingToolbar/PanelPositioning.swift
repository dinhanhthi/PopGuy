// PanelPositioning.swift
// PopGuy
//
// Pure, nonisolated helper for computing the floating panel's on-screen origin.
//
// The pure math function `panelOrigin(panelSize:near:within:cursor:)` operates
// only over CGRect/CGSize/CGPoint — no AppKit types — so it is nonisolated and
// can be called from unit tests without an @MainActor context.
//
// The @MainActor helper `visibleFrameForSelection(_:)` wraps NSScreen (AppKit)
// and must be called from the main actor.
//
// Unit test: PopGuyTests/Unit/PanelPositioningTests.swift

import AppKit
import CoreGraphics

// MARK: - Constants

/// Vertical gap between the selection edge and the panel (points).
/// Used by the cursor == nil (keyboard) branch.
let panelVerticalGap: CGFloat = 8

/// Gap between the mouse pointer and the panel when anchoring to the release
/// point (points). Larger than panelVerticalGap because the pointer sits
/// mid-line, so the panel must clear the text line above/below the cursor.
let pointerVerticalGap: CGFloat = 16

/// Minimum inset from any screen edge before the panel is clamped (points).
let panelEdgeInset: CGFloat = 4

// MARK: - Pure positioning function

/// Computes the bottom-left origin for the floating panel, kept just outside the
/// selection and clamped to remain fully within `screenFrame`.
///
/// Coordinate system: AppKit screen coordinates (Y=0 at bottom of main screen,
/// Y increases upward). The caller is responsible for converting from
/// Quartz/AX flipped coordinates if necessary.
///
/// Two anchoring modes:
///   • `cursor != nil` — the pointer is at the mouse-release point (a drag-select
///     or double-click). The panel is centred on the cursor X and placed on the
///     far side of the pointer in the drag direction (`grewDownward`): below the
///     pointer when dragging down, above when dragging up. The AX selection rect
///     is IGNORED in this branch — it may be partial for multi-line selections,
///     and the pointer is always at one extreme of the selection, so anchoring
///     purely to the pointer never covers the selected text.
///   • `cursor == nil` — keyboard selection or chord (mouse parked elsewhere).
///     The panel is centred on the selection and placed just below it (near the
///     end), flipping above when there is no room below. AX rect used here.
///
/// - Parameters:
///   - panelSize:     Desired panel size.
///   - selectionRect: Selection bounding rect in AppKit screen coordinates.
///   - screenFrame:   Visible frame of the display (NSScreen.visibleFrame).
///   - cursor:        Mouse-release point in AppKit screen coordinates, or nil.
///   - grewDownward:  True when the mouse was dragged downward on screen (Y
///                    release <= Y press in AppKit Y-up coords); false for an
///                    upward drag; nil when direction is unknown (e.g. double-
///                    click with no movement, or keyboard selection). Ignored
///                    when `cursor` is nil.
/// - Returns: The clamped bottom-left origin for the panel.
///
/// Nonisolated: all inputs/outputs are value types from CoreGraphics.
func panelOrigin(
    panelSize: CGSize,
    near selectionRect: CGRect,
    within screenFrame: CGRect,
    cursor: CGPoint? = nil,
    grewDownward: Bool? = nil
) -> CGPoint {
    // Horizontal anchor: cursor X when available (keeps the panel near where the
    // user released on wide selections), else the selection midpoint.
    let anchorX = cursor?.x ?? selectionRect.midX
    let minX = screenFrame.minX + panelEdgeInset
    let maxX = screenFrame.maxX - panelSize.width - panelEdgeInset
    let clampedX = min(max(anchorX - panelSize.width / 2, minX), maxX)

    let floorY = screenFrame.minY + panelEdgeInset
    let ceilY  = screenFrame.maxY - panelSize.height - panelEdgeInset

    let clampedY: CGFloat
    if let cursor {
        // Mouse-driven: anchor to the release pointer; side from the drag direction.
        // The happy path (enough room) places the panel on the FAR SIDE of the pointer
        // in the drag direction — because the pointer is always at one extreme of the
        // selection, this never covers the selected text by construction, regardless of
        // the AX rect (which may be partial for multi-line selections).
        //
        // The rare edge-of-screen flip uses the selection rect edge (best-effort: AX
        // rects may be partial) to reduce overlap. When the selection is taller than
        // the available space on the flipped side the panel is clamped to the screen
        // edge and may still overlap — this is a documented degenerate case.
        let down = grewDownward ?? true   // default below when direction unknown (e.g. double-click)
        if down {
            let belowY = cursor.y - pointerVerticalGap - panelSize.height
            if belowY >= floorY {
                clampedY = belowY                                   // happy path: below the pointer, never covers
            } else {
                // No room below — flip above, clearing the selection's TOP edge (best-effort: AX rect may be partial).
                clampedY = min(max(cursor.y, selectionRect.maxY) + pointerVerticalGap, ceilY)
            }
        } else {
            let aboveY = cursor.y + pointerVerticalGap
            if aboveY <= ceilY {
                clampedY = aboveY                                   // happy path: above the pointer
            } else {
                // No room above — flip below, clearing the selection's BOTTOM edge.
                clampedY = max(min(cursor.y, selectionRect.minY) - pointerVerticalGap - panelSize.height, floorY)
            }
        }
    } else {
        // cursor == nil: keyboard selection or chord (mouse parked / no release point).
        // Place the panel just BELOW the selection — "near the end" of the text in
        // reading order — never covering it. Flip above only when there is no room below.
        let belowY = selectionRect.minY - panelVerticalGap - panelSize.height
        let aboveY = selectionRect.maxY + panelVerticalGap
        if belowY >= floorY {
            clampedY = belowY
        } else {
            // No room below — flip above, clamped to the top edge.
            clampedY = min(aboveY, ceilY)
        }
    }

    return CGPoint(x: clampedX, y: clampedY)
}

// MARK: - Screen lookup

/// Returns the `visibleFrame` of the display that best contains the selection.
///
/// Priority:
///   1. Screen whose visibleFrame contains the selection midpoint.
///   2. Screen nearest to the selection midpoint (by centre-to-centre distance).
///   3. Main screen.
///   4. Hardcoded fallback (should never reach this in practice).
///
/// Must be called from the main actor (NSScreen is main-thread-only).
@MainActor
func visibleFrameForSelection(_ selectionRect: CGRect) -> CGRect {
    let screens = NSScreen.screens
    let mid = CGPoint(x: selectionRect.midX, y: selectionRect.midY)

    if let containing = screens.first(where: { $0.visibleFrame.contains(mid) }) {
        return containing.visibleFrame
    }
    if let nearest = screens.min(by: { a, b in
        let da = hypot(a.frame.midX - mid.x, a.frame.midY - mid.y)
        let db = hypot(b.frame.midX - mid.x, b.frame.midY - mid.y)
        return da < db
    }) {
        return nearest.visibleFrame
    }
    return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
}
