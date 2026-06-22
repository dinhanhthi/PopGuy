// GestureAnchorTests.swift
// PopGuyTests
//
// Unit tests for the pure `gestureAnchor(...)` helper in SelectionEvent.swift.
// No AppKit/window/event-monitor code — pure value-type math only.
// These tests run headlessly without a running UI environment.

import Testing
import CoreGraphics
import Foundation
@testable import PopGuy

@Suite("gestureAnchor()")
struct GestureAnchorTests {

    // Shared constants matching SelectionPipeline's internal values.
    let recencyWindow: TimeInterval = 0.6
    let dragThreshold: CGFloat = 3

    // A "now" reference for convenience.
    let now = Date()

    // MARK: - Down-drag

    @Test("down-drag: grewDownward true, mouseReleasePoint equals upLocation, not a double-click")
    func downDrag() {
        // AppKit Y-up: downward on screen means upLocation.y <= downLocation.y.
        let down = CGPoint(x: 500, y: 400)  // press
        let up   = CGPoint(x: 510, y: 350)  // release below (lower y = lower on screen)
        let upTime = now.addingTimeInterval(-0.1) // recent

        let result = gestureAnchor(
            downLocation: down,
            upLocation: up,
            upTime: upTime,
            clickCount: 1,
            now: now,
            recencyWindow: recencyWindow,
            dragThreshold: dragThreshold
        )

        #expect(result.grewDownward == true)
        #expect(result.mouseReleasePoint == up)
        #expect(result.isDoubleClick == false)
    }

    // MARK: - Up-drag

    @Test("up-drag: grewDownward false, mouseReleasePoint equals upLocation")
    func upDrag() {
        // upLocation.y > downLocation.y means cursor moved upward on screen.
        let down = CGPoint(x: 500, y: 400)
        let up   = CGPoint(x: 510, y: 450)  // release above (higher y = higher on screen)
        let upTime = now.addingTimeInterval(-0.1) // recent

        let result = gestureAnchor(
            downLocation: down,
            upLocation: up,
            upTime: upTime,
            clickCount: 1,
            now: now,
            recencyWindow: recencyWindow,
            dragThreshold: dragThreshold
        )

        #expect(result.grewDownward == false)
        #expect(result.mouseReleasePoint == up)
        #expect(result.isDoubleClick == false)
    }

    // MARK: - Bare click (distance < threshold)

    @Test("bare click: mouseReleasePoint nil, grewDownward nil, not a double-click")
    func bareClick() {
        // Click with negligible travel — excluded by the drag threshold.
        // This is the keyboard-after-click exclusion: a click followed by
        // Shift+Arrow should not carry a release point.
        let down = CGPoint(x: 500, y: 400)
        let up   = CGPoint(x: 501, y: 400)  // sub-threshold travel
        let upTime = now.addingTimeInterval(-0.1) // recent, clickCount 1

        let result = gestureAnchor(
            downLocation: down,
            upLocation: up,
            upTime: upTime,
            clickCount: 1,
            now: now,
            recencyWindow: recencyWindow,
            dragThreshold: dragThreshold
        )

        #expect(result.mouseReleasePoint == nil)
        #expect(result.grewDownward == nil)
        #expect(result.isDoubleClick == false)
    }

    // MARK: - Double-click

    @Test("double-click: isDoubleClick true, mouseReleasePoint equals upLocation, grewDownward nil")
    func doubleClick() {
        // Double-click: clickCount == 2, negligible travel, recent.
        // grewDownward must be nil — no meaningful drag direction.
        let down = CGPoint(x: 500, y: 400)
        let up   = CGPoint(x: 501, y: 400)  // essentially no travel
        let upTime = now.addingTimeInterval(-0.05) // very recent

        let result = gestureAnchor(
            downLocation: down,
            upLocation: up,
            upTime: upTime,
            clickCount: 2,
            now: now,
            recencyWindow: recencyWindow,
            dragThreshold: dragThreshold
        )

        #expect(result.isDoubleClick == true)
        #expect(result.mouseReleasePoint == up)
        #expect(result.grewDownward == nil)
    }

    // MARK: - Stale mouse-up

    @Test("stale mouse-up: all nil/false when upTime is outside recency window")
    func staleMouseUp() {
        // Mouse-up happened too long ago — not mouse-driven.
        let down = CGPoint(x: 500, y: 400)
        let up   = CGPoint(x: 510, y: 350)  // would be a drag if recent
        let upTime = now.addingTimeInterval(-(recencyWindow + 0.1))  // older than window

        let result = gestureAnchor(
            downLocation: down,
            upLocation: up,
            upTime: upTime,
            clickCount: 2,  // would be double-click if recent
            now: now,
            recencyWindow: recencyWindow,
            dragThreshold: dragThreshold
        )

        #expect(result.mouseReleasePoint == nil)
        #expect(result.grewDownward == nil)
        #expect(result.isDoubleClick == false)
    }
}
