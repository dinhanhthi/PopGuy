// PanelPositioningTests.swift
// PopGuyTests
//
// Unit tests for the pure `panelOrigin(panelSize:near:within:cursor:grewDownward:)` helper.
// No AppKit/window/event-monitor code — pure CGRect math only.
// These tests run headlessly without a running UI environment.

import Testing
import CoreGraphics
@testable import PopGuy

@Suite("PanelPositioning — panelOrigin()")
@MainActor
struct PanelPositioningTests {

    // Shared screen and panel sizes used across tests.
    let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let panelSize   = CGSize(width: 280, height: 50)

    // MARK: - Cursor-anchored: side follows the DRAG DIRECTION (not midY)

    @Test("down-drag places panel below the pointer")
    func downDragPanelBelowPointer() {
        // Cursor at the bottom extreme of a selection (drag went downward on screen).
        let selection = CGRect(x: 600, y: 400, width: 200, height: 120)
        let cursor = CGPoint(x: 650, y: selection.minY + 4) // near the visual-bottom extreme
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame,
                                 cursor: cursor, grewDownward: true)

        // Panel sits fully below the pointer.
        #expect(origin.y + panelSize.height <= cursor.y)
        // X centred on the cursor, not the selection midpoint.
        #expect(origin.x == cursor.x - panelSize.width / 2)
    }

    @Test("up-drag places panel above the pointer")
    func upDragPanelAbovePointer() {
        // Cursor at the top extreme of a selection (drag went upward on screen).
        let selection = CGRect(x: 600, y: 400, width: 200, height: 120)
        let cursor = CGPoint(x: 650, y: selection.maxY - 4) // near the visual-top extreme
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame,
                                 cursor: cursor, grewDownward: false)

        // Panel sits fully above the pointer.
        #expect(origin.y >= cursor.y)
        // X centred on the cursor.
        #expect(origin.x == cursor.x - panelSize.width / 2)
    }

    // MARK: - Regression: partial caret-line AX rect must not trap the panel

    @Test("up-drag with a partial caret-line AX rect never covers the full selection")
    func upDragPartialRectNeverCoversFullSelection() {
        // Forward invariant: panelOrigin must honour a caller-supplied grewDownward=false
        // (up-drag) even when the passed AX rect is partial (reports only the caret line).
        //
        // The regression guard that ensures grewDownward itself is correct for this
        // scenario lives in GestureAnchorTests — specifically the "up-drag" test which
        // verifies the helper derives grewDownward=false from pointer coordinates only,
        // ignoring the AX rect. This test owns the panelOrigin side: given the correct
        // direction signal, the panel must be placed above the cursor and must not
        // cover the full multi-line selection.
        let fullSelection = CGRect(x: 600, y: 300, width: 200, height: 200) // full multi-line selection
        let partialRect   = CGRect(x: 600, y: 480, width: 200, height: 20)  // top caret line only (AX partial)
        // Cursor near partialRect.midY — the old tie-break trap.
        let cursor = CGPoint(x: 650, y: partialRect.midY)  // y = 490

        let origin = panelOrigin(panelSize: panelSize, near: partialRect, within: screenFrame,
                                 cursor: cursor, grewDownward: false)

        let panelFrame = CGRect(origin: origin, size: panelSize)

        // Panel is ABOVE the cursor (up-drag logic applied, AX rect ignored).
        #expect(origin.y >= cursor.y, "panel should be above the cursor for an up-drag")

        // Panel must not intersect the FULL selection (the real text the user highlighted).
        #expect(!panelFrame.intersects(fullSelection),
                "panel \(panelFrame) must not intersect full selection \(fullSelection)")
    }

    // MARK: - Cursor-anchored: flips when there is no room

    @Test("down-drag flips above when there is no room below the cursor")
    func downDragFlipsAboveWhenNoRoomBelow() {
        // Cursor near the very bottom of the screen — no room for the panel below.
        // Selection fits comfortably above (20pt tall), so the flip should clear it.
        let selection = CGRect(x: 600, y: 2, width: 200, height: 20)
        let cursor = CGPoint(x: 650, y: 4)
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame,
                                 cursor: cursor, grewDownward: true)

        // Placed above the cursor (flipped), and stays on-screen.
        #expect(origin.y >= cursor.y)
        #expect(origin.y + panelSize.height <= screenFrame.maxY)

        // The flip clears the selection's top edge — non-cover assertion.
        let panelFrame = CGRect(origin: origin, size: panelSize)
        #expect(!panelFrame.intersects(selection),
                "flipped panel \(panelFrame) must not intersect selection \(selection)")
    }

    @Test("down-drag flip degenerate: selection taller than available space above — panel clamped on-screen")
    func downDragFlipDegenerateTallSelection() {
        // Near-full-screen-tall selection: no room to clear it on the flip side.
        // Assert only on-screen containment — overlap is unavoidable and documented.
        let selection = CGRect(x: 600, y: screenFrame.minY + 4, width: 200, height: screenFrame.height - 8)
        let cursor = CGPoint(x: 650, y: screenFrame.minY + 8)  // near bottom, forces flip above
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame,
                                 cursor: cursor, grewDownward: true)
        let panelFrame = CGRect(origin: origin, size: panelSize)

        #expect(panelFrame.minY >= screenFrame.minY - 1)
        #expect(panelFrame.maxY <= screenFrame.maxY + 1)
        #expect(panelFrame.minX >= screenFrame.minX - 1)
        #expect(panelFrame.maxX <= screenFrame.maxX + 1)
    }

    @Test("up-drag flips below when there is no room above the cursor")
    func upDragFlipsBelowWhenNoRoomAbove() {
        // Cursor near the very top of the screen — no room above.
        // Selection fits comfortably below (20pt tall), so the flip should clear it.
        let selection = CGRect(x: 600, y: screenFrame.maxY - 22, width: 200, height: 20)
        let cursor = CGPoint(x: 650, y: screenFrame.maxY - 4)
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame,
                                 cursor: cursor, grewDownward: false)

        // Placed below the cursor (flipped), and stays on-screen.
        #expect(origin.y + panelSize.height <= cursor.y)
        #expect(origin.y >= screenFrame.minY)

        // The flip clears the selection's bottom edge — non-cover assertion.
        let panelFrame = CGRect(origin: origin, size: panelSize)
        #expect(!panelFrame.intersects(selection),
                "flipped panel \(panelFrame) must not intersect selection \(selection)")
    }

    @Test("up-drag flip degenerate: selection taller than available space below — panel clamped on-screen")
    func upDragFlipDegenerateTallSelection() {
        // Near-full-screen-tall selection near the top: no room to clear it on the flip side.
        // Assert only on-screen containment — overlap is unavoidable and documented.
        let selection = CGRect(x: 600, y: screenFrame.minY + 4, width: 200, height: screenFrame.height - 8)
        let cursor = CGPoint(x: 650, y: screenFrame.maxY - 8)  // near top, forces flip below
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame,
                                 cursor: cursor, grewDownward: false)
        let panelFrame = CGRect(origin: origin, size: panelSize)

        #expect(panelFrame.minY >= screenFrame.minY - 1)
        #expect(panelFrame.maxY <= screenFrame.maxY + 1)
        #expect(panelFrame.minX >= screenFrame.minX - 1)
        #expect(panelFrame.maxX <= screenFrame.maxX + 1)
    }

    // MARK: - Cursor-anchored: horizontal clamping

    @Test("clamps cursor-anchored panel to the right edge")
    func cursorRightEdgeClamp() {
        let selection = CGRect(x: screenFrame.maxX - 10, y: 400, width: 8, height: 20)
        let cursor = CGPoint(x: screenFrame.maxX - 6, y: 402)
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame,
                                 cursor: cursor, grewDownward: true)

        let maxAllowedX = screenFrame.maxX - panelSize.width - panelEdgeInset
        #expect(origin.x <= maxAllowedX)
    }

    @Test("clamps cursor-anchored panel to the left edge")
    func cursorLeftEdgeClamp() {
        let selection = CGRect(x: 2, y: 400, width: 8, height: 20)
        let cursor = CGPoint(x: 4, y: 402)
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame,
                                 cursor: cursor, grewDownward: true)

        #expect(origin.x >= screenFrame.minX + panelEdgeInset)
    }

    // MARK: - Keyboard selection fallback (cursor == nil): below-centred

    @Test("nil cursor positions panel below and centred on the selection")
    func nilCursorBelowAndCentred() {
        let selection = CGRect(x: 600, y: 400, width: 200, height: 20)
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame, cursor: nil)

        // Centred on selection midX.
        #expect(origin.x == selection.midX - panelSize.width / 2)
        // Fully below the selection's bottom edge (AppKit Y-up: minY is the visual bottom).
        #expect(origin.y + panelSize.height <= selection.minY)
        #expect(origin.y == selection.minY - panelVerticalGap - panelSize.height)
    }

    @Test("nil cursor centres on the mouse when it sits inside an over-wide AX rect")
    func nilCursorCentresOnMouseInsideOverWideRect() {
        // Cursor (Monaco) reports a one-line rect spanning the whole editor width,
        // past the screen edge; ⌘C+C carries no release point (measured values).
        let screen = CGRect(x: 0, y: 58, width: 1800, height: 1072)
        let size = CGSize(width: 369, height: 66)
        let selection = CGRect(x: 471, y: 743, width: 1474, height: 19)
        let mouse = CGPoint(x: 549, y: 747)
        let origin = panelOrigin(panelSize: size, near: selection, within: screen,
                                 cursor: nil, mouse: mouse)

        #expect(origin.x == mouse.x - size.width / 2)
        // Vertical placement is unchanged: just below the AX rect.
        #expect(origin.y == selection.minY - panelVerticalGap - size.height)
    }

    @Test("nil cursor centres on a mouse a few points above an over-wide AX rect")
    func nilCursorCentresOnMouseJustAboveOverWideRect() {
        // Measured in Cursor: the AX rect sits a few points below the pointer's line.
        let screen = CGRect(x: 0, y: 58, width: 1800, height: 1072)
        let size = CGSize(width: 369, height: 66)
        let selection = CGRect(x: 471, y: 311, width: 2620, height: 43)
        let mouse = CGPoint(x: 670.6, y: 360.1)
        let origin = panelOrigin(panelSize: size, near: selection, within: screen,
                                 cursor: nil, mouse: mouse)

        #expect(origin.x == mouse.x - size.width / 2)
    }

    @Test("nil cursor ignores a mouse parked outside the selection")
    func nilCursorIgnoresMouseOutsideSelection() {
        let selection = CGRect(x: 600, y: 400, width: 200, height: 20)
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame,
                                 cursor: nil, mouse: CGPoint(x: 100, y: 800))

        #expect(origin.x == selection.midX - panelSize.width / 2)
    }

    @Test("nil cursor flips above the selection when there is no room below")
    func nilCursorFlipsAboveWhenNoRoomBelow() {
        // Selection whose bottom edge sits near the screen bottom — no room below.
        let selection = CGRect(x: 600, y: screenFrame.minY + 2, width: 200, height: 20)
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame, cursor: nil)

        // Panel flips above: its bottom edge is at or above the selection's top edge.
        #expect(origin.y >= selection.maxY)
    }

    // MARK: - Never-cover invariant matrix

    @Test("panel never covers the selection across representative cases")
    func neverCoversSelectionMatrix() {
        struct Case {
            let label: String
            let selection: CGRect
            let cursor: CGPoint?
            let grewDownward: Bool?
        }

        let cases: [Case] = [
            // Down-drag: cursor near the BOTTOM extreme of selection → panel below.
            Case(label: "down-drag, single-line",
                 selection: CGRect(x: 500, y: 400, width: 200, height: 20),
                 cursor: CGPoint(x: 550, y: 402),      // near minY (visual bottom)
                 grewDownward: true),

            // Up-drag: cursor near the TOP extreme of selection → panel above.
            Case(label: "up-drag, single-line",
                 selection: CGRect(x: 500, y: 400, width: 200, height: 20),
                 cursor: CGPoint(x: 550, y: 418),      // near maxY (visual top)
                 grewDownward: false),

            // Down-drag, multi-line, cursor left.
            Case(label: "down-drag, multi-line, cursor left",
                 selection: CGRect(x: 400, y: 300, width: 300, height: 120),
                 cursor: CGPoint(x: 410, y: 305),      // near minY
                 grewDownward: true),

            // Up-drag, multi-line, cursor right.
            Case(label: "up-drag, multi-line, cursor right",
                 selection: CGRect(x: 400, y: 300, width: 300, height: 120),
                 cursor: CGPoint(x: 690, y: 416),      // near maxY (420)
                 grewDownward: false),

            // Near top screen edge: down-drag so panel goes below cursor (no flip).
            Case(label: "selection near top screen edge, down-drag",
                 selection: CGRect(x: 500, y: screenFrame.maxY - 30, width: 200, height: 20),
                 cursor: CGPoint(x: 550, y: screenFrame.maxY - 28),  // near minY (visual bottom)
                 grewDownward: true),

            // Near bottom screen edge: up-drag so panel goes above cursor (no flip).
            Case(label: "selection near bottom screen edge, up-drag",
                 selection: CGRect(x: 500, y: screenFrame.minY + 5, width: 200, height: 20),
                 cursor: CGPoint(x: 550, y: screenFrame.minY + 23),  // near maxY (visual top)
                 grewDownward: false),

            // Near left screen edge, down-drag.
            Case(label: "selection near left edge, down-drag",
                 selection: CGRect(x: screenFrame.minX + 2, y: 400, width: 200, height: 20),
                 cursor: CGPoint(x: screenFrame.minX + 5, y: 402),   // near minY
                 grewDownward: true),

            // Near right screen edge, up-drag.
            Case(label: "selection near right edge, up-drag",
                 selection: CGRect(x: screenFrame.maxX - 202, y: 400, width: 200, height: 20),
                 cursor: CGPoint(x: screenFrame.maxX - 5, y: 418),   // near maxY
                 grewDownward: false),

            // cursor == nil: no release point (keyboard / chord path).
            Case(label: "nil cursor, mid-screen",
                 selection: CGRect(x: 500, y: 400, width: 200, height: 20),
                 cursor: nil,
                 grewDownward: nil),

            // cursor == nil: selection near bottom (flips above).
            Case(label: "nil cursor, selection near bottom",
                 selection: CGRect(x: 500, y: screenFrame.minY + 2, width: 200, height: 20),
                 cursor: nil,
                 grewDownward: nil),
        ]

        // Non-cover: panel is fully below (panelFrame.maxY <= selection.minY) or
        // fully above (panelFrame.minY >= selection.maxY) the selection.
        // Horizontal overlap is permitted and expected.
        for c in cases {
            let origin = panelOrigin(panelSize: panelSize, near: c.selection, within: screenFrame,
                                     cursor: c.cursor, grewDownward: c.grewDownward)
            let panelFrame = CGRect(origin: origin, size: panelSize)
            #expect(!panelFrame.intersects(c.selection), "\(c.label): panel \(panelFrame) covers selection \(c.selection)")
            let fullyBelow = panelFrame.maxY <= c.selection.minY
            let fullyAbove = panelFrame.minY >= c.selection.maxY
            #expect(fullyBelow || fullyAbove, "\(c.label): panel \(panelFrame) is not vertically separated from selection \(c.selection)")
        }
    }

    // MARK: - Degenerate: very tall selection (panel stays on-screen, no non-cover guarantee)

    @Test("tall selection: panel is clamped within screen even when it cannot avoid the selection")
    func tallSelectionClampsOnScreen() {
        // A near-full-screen-tall selection leaves no vertical space to avoid it.
        // We only assert the panel stays within the screen frame.
        let selection = CGRect(x: 400, y: screenFrame.minY + 4, width: 300, height: screenFrame.height - 8)
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame, cursor: nil)
        let panelFrame = CGRect(origin: origin, size: panelSize)

        #expect(panelFrame.minY >= screenFrame.minY - 1)
        #expect(panelFrame.maxY <= screenFrame.maxY + 1)
        #expect(panelFrame.minX >= screenFrame.minX - 1)
        #expect(panelFrame.maxX <= screenFrame.maxX + 1)
    }

    @Test("tall selection with cursor: panel is clamped within screen even when it cannot avoid the selection")
    func tallSelectionWithCursorClampsOnScreen() {
        // Same degenerate tall selection, but with a non-nil cursor — exercises the
        // flip-clamp branch in the cursor != nil path. On-screen containment only
        // (not non-intersection). grewDownward omitted → defaults to nil → treated as true.
        let selection = CGRect(x: 400, y: screenFrame.minY + 4, width: 300, height: screenFrame.height - 8)
        let cursor = CGPoint(x: 550, y: screenFrame.midY)
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame, cursor: cursor)
        let panelFrame = CGRect(origin: origin, size: panelSize)

        #expect(panelFrame.minY >= screenFrame.minY - 1)
        #expect(panelFrame.maxY <= screenFrame.maxY + 1)
        #expect(panelFrame.minX >= screenFrame.minX - 1)
        #expect(panelFrame.maxX <= screenFrame.maxX + 1)
    }

    // MARK: - Panel stays fully within screen frame

    @Test("panel stays fully within the screen frame for a typical selection")
    func panelWithinScreenFrame() {
        let selection = CGRect(x: 500, y: 300, width: 200, height: 20)
        let cursor = CGPoint(x: 600, y: 302) // near minY → down-drag
        let origin = panelOrigin(panelSize: panelSize, near: selection, within: screenFrame,
                                 cursor: cursor, grewDownward: true)

        let panelFrame = CGRect(origin: origin, size: panelSize)
        #expect(panelFrame.minX >= screenFrame.minX - 1) // allow floating-point slack
        #expect(panelFrame.maxX <= screenFrame.maxX + 1)
        #expect(panelFrame.minY >= screenFrame.minY - 1)
        #expect(panelFrame.maxY <= screenFrame.maxY + 1)
    }
}

@Suite("PanelPositioning — logo-only collapsed card")
@MainActor
struct CollapsedPanelPositioningTests {

    let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    // Panel = 40×40 logo card + transparent padding (12 each side, 8 top, 24 bottom).
    let panelSize = CGSize(width: 64, height: 72)
    let cardTopInset: CGFloat = 8
    let cardBottomInset: CGFloat = 24

    @Test("collapsed card sits centred just below the pointer")
    func collapsedBelowPointerCentred() {
        let mouse = CGPoint(x: 700, y: 500)
        let origin = collapsedPanelOrigin(panelSize: panelSize, cardTopInset: cardTopInset,
                                          cardBottomInset: cardBottomInset, mouse: mouse,
                                          grewDownward: true, within: screenFrame)

        #expect(origin.x == mouse.x - panelSize.width / 2)
        // Card top (panel top minus the top inset) is pointerVerticalGap below the pointer.
        let cardTop = origin.y + panelSize.height - cardTopInset
        #expect(cardTop == mouse.y - pointerVerticalGap)
    }

    @Test("collapsed card flips above the pointer for an up-drag")
    func collapsedFlipsAboveForUpDrag() {
        let mouse = CGPoint(x: 700, y: 500)
        let origin = collapsedPanelOrigin(panelSize: panelSize, cardTopInset: cardTopInset,
                                          cardBottomInset: cardBottomInset, mouse: mouse,
                                          grewDownward: false, within: screenFrame)

        let cardBottom = origin.y + cardBottomInset
        #expect(cardBottom == mouse.y + pointerVerticalGap)
    }

    @Test("collapsed panel is clamped inside the screen at the left edge")
    func collapsedClampsAtLeftEdge() {
        let mouse = CGPoint(x: 2, y: 500)
        let origin = collapsedPanelOrigin(panelSize: panelSize, cardTopInset: cardTopInset,
                                          cardBottomInset: cardBottomInset, mouse: mouse,
                                          grewDownward: true, within: screenFrame)

        #expect(origin.x == screenFrame.minX + panelEdgeInset)
    }

    @Test("logo expands rightward when the bar fits to its right")
    func logoExpandsTrailingWhenItFits() {
        let logo = CGRect(x: 600, y: 400, width: 40, height: 40)
        #expect(logoExpandsLeading(logoCardFrame: logo, expandedCardWidth: 320,
                                   within: screenFrame) == false)
    }

    @Test("logo expands leftward when it sits near the right screen edge")
    func logoExpandsLeadingNearRightEdge() {
        let logo = CGRect(x: screenFrame.maxX - 60, y: 400, width: 40, height: 40)
        #expect(logoExpandsLeading(logoCardFrame: logo, expandedCardWidth: 320,
                                   within: screenFrame) == true)
    }
}

@Suite("PanelPositioning — menu style")
@MainActor
struct MenuPanelPositioningTests {

    let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let menuSize = CGSize(width: 220, height: 300)
    let submenuSize = CGSize(width: 200, height: 160)

    /// The pointer anchor the controller builds: the release point padded
    /// vertically by `pointerVerticalGap`.
    func pointerAnchor(_ p: CGPoint) -> CGRect {
        CGRect(x: p.x, y: p.y - pointerVerticalGap, width: 0, height: 2 * pointerVerticalGap)
    }

    @Test("menu opens down-right of the pointer")
    func menuOpensDownRight() {
        let p = CGPoint(x: 600, y: 600)
        let origin = menuCardOrigin(cardSize: menuSize, anchor: pointerAnchor(p),
                                    preferUp: false, within: screenFrame)

        #expect(origin.x == p.x)
        #expect(origin.y + menuSize.height == p.y - pointerVerticalGap)
    }

    @Test("menu opens above the pointer for an up-drag or when there is no room below")
    func menuOpensAbove() {
        let p = CGPoint(x: 600, y: 400)
        let up = menuCardOrigin(cardSize: menuSize, anchor: pointerAnchor(p),
                                preferUp: true, within: screenFrame)
        #expect(up.y == p.y + pointerVerticalGap)

        let low = CGPoint(x: 600, y: 120)
        let flipped = menuCardOrigin(cardSize: menuSize, anchor: pointerAnchor(low),
                                     preferUp: false, within: screenFrame)
        #expect(flipped.y == low.y + pointerVerticalGap)
    }

    @Test("menu opens leftward near the right screen edge")
    func menuOpensLeftNearRightEdge() {
        let p = CGPoint(x: screenFrame.maxX - 50, y: 600)
        let origin = menuCardOrigin(cardSize: menuSize, anchor: pointerAnchor(p),
                                    preferUp: false, within: screenFrame)

        #expect(origin.x + menuSize.width == p.x)
    }

    @Test("submenu opens right of the menu, aligned to the row")
    func submenuOpensRightAlignedToRow() {
        let menu = CGRect(x: 600, y: 300, width: 220, height: 300)
        let row = CGRect(x: 606, y: 420, width: 208, height: 24)
        let origin = submenuCardOrigin(cardSize: submenuSize, rowFrame: row,
                                       menuCardFrame: menu, within: screenFrame)

        #expect(origin.x == menu.maxX - submenuHorizontalOverlap)
        #expect(origin.y + submenuSize.height == row.maxY + submenuTopOffset)
    }

    @Test("submenu flips to the left of the menu near the right screen edge")
    func submenuFlipsLeftNearRightEdge() {
        let menu = CGRect(x: screenFrame.maxX - 300, y: 300, width: 220, height: 300)
        let row = CGRect(x: menu.minX + 6, y: 420, width: 208, height: 24)
        let origin = submenuCardOrigin(cardSize: submenuSize, rowFrame: row,
                                       menuCardFrame: menu, within: screenFrame)

        #expect(origin.x + submenuSize.width == menu.minX + submenuHorizontalOverlap)
    }

    @Test("submenu shifts up to stay on screen near the bottom edge")
    func submenuShiftsUpNearBottom() {
        let menu = CGRect(x: 600, y: 10, width: 220, height: 300)
        let row = CGRect(x: 606, y: 40, width: 208, height: 24)
        let origin = submenuCardOrigin(cardSize: submenuSize, rowFrame: row,
                                       menuCardFrame: menu, within: screenFrame)

        #expect(origin.y == screenFrame.minY + panelEdgeInset)
    }
}
