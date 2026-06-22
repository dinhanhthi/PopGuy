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
