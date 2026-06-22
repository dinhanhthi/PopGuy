// ClipboardFallbackGateTests.swift
// PopGuyTests
//
// Unit tests for the pure `shouldAttemptClipboardFallback(...)` helper in
// SelectionEvent.swift. No AppKit, no AX, no pasteboard — pure value logic.
// These tests run headlessly without a running UI environment.

import Testing
import CoreGraphics
@testable import PopGuy

@Suite("shouldAttemptClipboardFallback()")
struct ClipboardFallbackGateTests {

    // Release point for a real drag — non-nil satisfies the drag check.
    let dragPoint = CGPoint(x: 400, y: 300)

    // MARK: - Gate passes (all three conditions met)

    @Test("real drag in allowlisted editor on mouse-up path: gate passes")
    func realDragInAllowlistedEditor() {
        #expect(shouldAttemptClipboardFallback(
            fromMouseUp: true,
            mouseReleasePoint: dragPoint,
            usesEnhancedCapture: true
        ) == true)
    }

    // MARK: - Gate fails when any single condition is missing

    @Test("not from mouse-up (keyboard/chord path): gate fails")
    func notFromMouseUp() {
        #expect(shouldAttemptClipboardFallback(
            fromMouseUp: false,
            mouseReleasePoint: dragPoint,
            usesEnhancedCapture: true
        ) == false)
    }

    @Test("bare click (mouseReleasePoint nil): gate fails")
    func bareClick() {
        #expect(shouldAttemptClipboardFallback(
            fromMouseUp: true,
            mouseReleasePoint: nil,
            usesEnhancedCapture: true
        ) == false)
    }

    @Test("non-allowlisted app: gate fails")
    func nonAllowlistedApp() {
        #expect(shouldAttemptClipboardFallback(
            fromMouseUp: true,
            mouseReleasePoint: dragPoint,
            usesEnhancedCapture: false
        ) == false)
    }

    // MARK: - All conditions false

    @Test("all conditions false: gate fails")
    func allFalse() {
        #expect(shouldAttemptClipboardFallback(
            fromMouseUp: false,
            mouseReleasePoint: nil,
            usesEnhancedCapture: false
        ) == false)
    }

    // MARK: - Interaction with keyboard-selection path

    @Test("keyboard selection (fromMouseUp=false, release point non-nil): gate fails — not a mouse-up path")
    func keyboardSelectionWithReleasePoint() {
        // Even if somehow a release point is present, the keyboard path must not fire.
        #expect(shouldAttemptClipboardFallback(
            fromMouseUp: false,
            mouseReleasePoint: dragPoint,
            usesEnhancedCapture: true
        ) == false)
    }
}
