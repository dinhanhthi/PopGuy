// PanelPositioning.swift
// PopGuy
//
// Pure, nonisolated helper for computing the floating panel's on-screen origin.
//
// The pure math function `panelOrigin(panelSize:near:within:cursor:)` operates
// only over CGRect/CGSize/CGPoint — no AppKit types — so it is nonisolated and
// can be called from unit tests without an @MainActor context. The logo-only mode
// helpers `collapsedPanelOrigin` and `logoExpandsLeading`, and the Menu style
// helpers `menuCardOrigin` and `submenuCardOrigin`, are pure math too.
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

/// How far above/below the selection rect the mouse may sit and still count as
/// "on the selection" (points, about one text line). Some apps' AX rects sit a
/// few points off the line the pointer is on.
let mouseOnSelectionTolerance: CGFloat = 16

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
///     end), flipping above when there is no room below. AX rect used here,
///     except that a `mouse` inside the rect gives the horizontal centre: some
///     apps (Cursor) report a rect spanning the whole editor width.
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
///   - mouse:         Current mouse location in AppKit screen coordinates, or nil.
///                    Used only when `cursor` is nil, and only when it lies
///                    inside `selectionRect` (within `mouseOnSelectionTolerance`
///                    vertically).
/// - Returns: The clamped bottom-left origin for the panel.
///
/// Nonisolated: all inputs/outputs are value types from CoreGraphics.
func panelOrigin(
    panelSize: CGSize,
    near selectionRect: CGRect,
    within screenFrame: CGRect,
    cursor: CGPoint? = nil,
    grewDownward: Bool? = nil,
    mouse: CGPoint? = nil
) -> CGPoint {
    // Horizontal anchor: cursor X when available (keeps the panel near where the
    // user released on wide selections), else the mouse X when it sits on the
    // selection (an over-wide AX rect would push the midpoint far away), else
    // the selection midpoint.
    let mouseZone = selectionRect.insetBy(dx: 0, dy: -mouseOnSelectionTolerance)
    let mouseOnSelection = mouse.flatMap { mouseZone.contains($0) ? $0.x : nil }
    let anchorX = cursor?.x ?? mouseOnSelection ?? selectionRect.midX
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

// MARK: - Logo-only mode

/// Computes the bottom-left origin for the collapsed (logo-only) panel, so the
/// visible logo card lands right next to the mouse pointer.
///
/// Coordinate system: AppKit screen coordinates (Y up, origin bottom-left).
///
/// The panel carries transparent padding around the card: `cardTopInset` above,
/// `cardBottomInset` below, and symmetric horizontal padding (so the card is
/// horizontally centred in the panel). The card is centred on `mouse.x` with its
/// top `pointerVerticalGap` below the pointer; for an up-drag
/// (`grewDownward == false`) or when the card would not fit below, its bottom
/// sits `pointerVerticalGap` above the pointer instead. The whole panel is then
/// clamped inside `screenFrame` (minus `panelEdgeInset`), preferring the top/left
/// edge when the panel is larger than the screen.
///
/// Pure: CoreGraphics value types only; main-actor isolated (target default).
func collapsedPanelOrigin(
    panelSize: CGSize,
    cardTopInset: CGFloat,
    cardBottomInset: CGFloat,
    mouse: CGPoint,
    grewDownward: Bool?,
    within screenFrame: CGRect
) -> CGPoint {
    let cardHeight = panelSize.height - cardTopInset - cardBottomInset
    let cardBottomBelow = mouse.y - pointerVerticalGap - cardHeight
    let placeAbove = grewDownward == false || cardBottomBelow < screenFrame.minY + panelEdgeInset
    let cardBottom = placeAbove ? mouse.y + pointerVerticalGap : cardBottomBelow

    let minX = screenFrame.minX + panelEdgeInset
    let maxX = screenFrame.maxX - panelSize.width - panelEdgeInset
    let minY = screenFrame.minY + panelEdgeInset
    let maxY = screenFrame.maxY - panelSize.height - panelEdgeInset
    let x = mouse.x - panelSize.width / 2
    let y = cardBottom - cardBottomInset
    return CGPoint(
        x: maxX >= minX ? min(max(x, minX), maxX) : minX,
        y: maxY >= minY ? min(max(y, minY), maxY) : maxY
    )
}

/// Decides which way the full toolbar expands out of the logo card.
///
/// Returns false (expand rightward, the logo's left edge stays fixed) when the
/// expanded card fits to the right; else true (expand leftward, the logo's right
/// edge stays fixed) when it fits to the left. When it fits neither side, returns
/// true only when there is more room left of the logo than right of it; the
/// panel clamp handles the overflow.
///
/// Pure: CoreGraphics value types only; main-actor isolated (target default).
func logoExpandsLeading(
    logoCardFrame: CGRect,
    expandedCardWidth: CGFloat,
    within screenFrame: CGRect
) -> Bool {
    if logoCardFrame.minX + expandedCardWidth <= screenFrame.maxX - panelEdgeInset {
        return false
    }
    if logoCardFrame.maxX - expandedCardWidth >= screenFrame.minX + panelEdgeInset {
        return true
    }
    return logoCardFrame.maxX - screenFrame.minX > screenFrame.maxX - logoCardFrame.minX
}

// MARK: - Menu style

/// How far the submenu card overlaps the main menu card horizontally (points),
/// so the pointer crosses no gap moving from the More actions row into it.
let submenuHorizontalOverlap: CGFloat = 2

/// How far the submenu card's top sits above the More actions row's top
/// (points). Matches the menu card's inner vertical padding, so the submenu's
/// first row lines up with the More actions row.
let submenuTopOffset: CGFloat = 5

/// Computes the bottom-left origin for the Menu style's main menu card.
///
/// Coordinate system: AppKit screen coordinates (Y up, origin bottom-left). All
/// frames are visible card frames; the caller converts to the panel origin.
///
/// `anchor` is the rect the menu attaches to. Vertically the card sits outside
/// it: dropping down puts the card's top at `anchor.minY`, dropping up puts its
/// bottom at `anchor.maxY`. With `coversAnchor` the card aligns inside it
/// instead: top at `anchor.maxY` down, bottom at `anchor.minY` up. Horizontally
/// the card always aligns inside it: going right puts its left at `anchor.minX`,
/// going left puts its right at `anchor.maxX`.
///
/// Intended anchors:
///   • pointer release point `p`: `p` padded vertically by `pointerVerticalGap`
///     (zero width), so the menu opens beside the pointer.
///   • keyboard selection: the selection rect padded vertically by
///     `panelVerticalGap`, with the bar's anchor x (zero width).
///   • logo card: the logo card frame with `coversAnchor`, so the menu replaces
///     the logo in place (top-left on the logo's top-left; right- or
///     bottom-aligned with the logo when flipped).
///
/// Prefers down (up when `preferUp`); flips when the preferred side lacks room
/// and the other side has it, else takes the side with more room. Prefers
/// right; flips left when there is no room on the right. Finally clamps into
/// `visibleFrame` minus `panelEdgeInset`, preferring the top/left edge when the
/// card is larger than the screen.
///
/// Pure: CoreGraphics value types only; main-actor isolated (target default).
func menuCardOrigin(
    cardSize: CGSize,
    anchor: CGRect,
    preferUp: Bool,
    within visibleFrame: CGRect,
    coversAnchor: Bool = false
) -> CGPoint {
    let minX = visibleFrame.minX + panelEdgeInset
    let maxX = visibleFrame.maxX - cardSize.width - panelEdgeInset
    let minY = visibleFrame.minY + panelEdgeInset
    let maxY = visibleFrame.maxY - cardSize.height - panelEdgeInset

    let downTop = coversAnchor ? anchor.maxY : anchor.minY
    let upBottom = coversAnchor ? anchor.minY : anchor.maxY
    let roomBelow = downTop - minY
    let roomAbove = visibleFrame.maxY - panelEdgeInset - upBottom
    let goUp: Bool
    if preferUp {
        goUp = roomAbove >= cardSize.height || (roomBelow < cardSize.height && roomAbove >= roomBelow)
    } else {
        goUp = roomBelow < cardSize.height && (roomAbove >= cardSize.height || roomAbove > roomBelow)
    }
    let y = goUp ? upBottom : downTop - cardSize.height

    let x = anchor.minX <= maxX ? anchor.minX : anchor.maxX - cardSize.width

    return CGPoint(
        x: maxX >= minX ? min(max(x, minX), maxX) : minX,
        y: maxY >= minY ? min(max(y, minY), maxY) : maxY
    )
}

/// Computes the bottom-left origin for the Menu style's More actions submenu
/// card, shown beside the main menu card.
///
/// Coordinate system: AppKit screen coordinates (Y up, origin bottom-left);
/// `rowFrame` (the More actions row) and `menuCardFrame` are visible frames.
///
/// The card opens right of the menu card, overlapping it by
/// `submenuHorizontalOverlap`, with its top `topOffset` (default
/// `submenuTopOffset`; pass it scaled by the toolbar zoom) above the row's top.
/// When it does not fit on the right it opens left of the menu card
/// instead (same overlap). It then shifts vertically to stay inside
/// `visibleFrame` minus `panelEdgeInset`: up near the bottom edge, down near the
/// top edge.
///
/// Pure: CoreGraphics value types only; main-actor isolated (target default).
func submenuCardOrigin(
    cardSize: CGSize,
    rowFrame: CGRect,
    menuCardFrame: CGRect,
    within visibleFrame: CGRect,
    topOffset: CGFloat = submenuTopOffset
) -> CGPoint {
    let rightX = menuCardFrame.maxX - submenuHorizontalOverlap
    let fitsRight = rightX + cardSize.width <= visibleFrame.maxX - panelEdgeInset
    let x = fitsRight ? rightX : menuCardFrame.minX + submenuHorizontalOverlap - cardSize.width

    let minY = visibleFrame.minY + panelEdgeInset
    let maxY = visibleFrame.maxY - cardSize.height - panelEdgeInset
    let y = rowFrame.maxY + topOffset - cardSize.height
    return CGPoint(x: x, y: maxY >= minY ? min(max(y, minY), maxY) : maxY)
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
