// DoubleTapDetectorTests.swift
// PopGuyTests
//
// TDD: pure DoubleTapDetector state machine.
//
// Tests feed (timestamp, isCmdC) pairs directly into the detector and assert
// whether a chord fires. No CGEventTap, no AppKit — deterministic and fast.
//
// Policy: triple rapid Cmd+C fires once (for the first pair) and rearms so
// the third tap becomes the first of a potential next pair.

import Foundation
import Testing
@testable import PopGuy

// MARK: - DoubleTapDetectorTests

@Suite("DoubleTapDetector")
struct DoubleTapDetectorTests {

    /// Default chord window used in tests — matches DoubleTapDetector default.
    private let window: TimeInterval = 0.3

    // MARK: - Two Cmd+C within window → fires

    @Test("two Cmd+C within window fires chord")
    func twoCmdCWithinWindowFires() {
        var detector = DoubleTapDetector()
        let t0 = 0.0
        let t1 = t0 + 0.1 // well within 300ms

        let first  = detector.handle(timestamp: t0, isCmdC: true)
        let second = detector.handle(timestamp: t1, isCmdC: true)

        #expect(first  == false, "first tap alone should not fire")
        #expect(second == true,  "second tap within window should fire")
    }

    @Test("fires at exactly the edge of the window (< window, not <=)")
    func twoCmdCAtEdgeFires() {
        var detector = DoubleTapDetector()
        let t0 = 0.0
        let t1 = t0 + window - 0.001 // just inside

        let first  = detector.handle(timestamp: t0, isCmdC: true)
        let second = detector.handle(timestamp: t1, isCmdC: true)

        #expect(first  == false)
        #expect(second == true)
    }

    // MARK: - Two Cmd+C outside window → no fire

    @Test("two Cmd+C outside window does not fire")
    func twoCmdCOutsideWindowNoFire() {
        var detector = DoubleTapDetector()
        let t0 = 0.0
        let t1 = t0 + window + 0.001 // just outside

        let first  = detector.handle(timestamp: t0, isCmdC: true)
        let second = detector.handle(timestamp: t1, isCmdC: true)

        #expect(first  == false)
        // The second tap came too late — it now becomes the new "first tap".
        // No chord should fire.
        #expect(second == false)
    }

    @Test("large gap between two Cmd+C does not fire")
    func twoCmdCLargeGap() {
        var detector = DoubleTapDetector()

        let first  = detector.handle(timestamp: 0.0, isCmdC: true)
        let second = detector.handle(timestamp: 2.0, isCmdC: true)

        #expect(first  == false)
        #expect(second == false)
    }

    // MARK: - Single Cmd+C → no fire

    @Test("single Cmd+C does not fire")
    func singleCmdCNoFire() {
        var detector = DoubleTapDetector()
        let result = detector.handle(timestamp: 0.0, isCmdC: true)
        #expect(result == false)
    }

    // MARK: - Cmd+C then different key → no fire

    @Test("Cmd+C then non-Cmd+C key does not fire")
    func cmdCThenOtherKeyNoFire() {
        var detector = DoubleTapDetector()
        let first  = detector.handle(timestamp: 0.0, isCmdC: true)
        let other  = detector.handle(timestamp: 0.1, isCmdC: false)
        // After a non-Cmd+C event, the detector should reset.
        let third  = detector.handle(timestamp: 0.2, isCmdC: true)

        #expect(first == false)
        #expect(other == false)
        // third is now a lone Cmd+C (state was reset by the non-Cmd+C key)
        #expect(third == false)
    }

    // MARK: - Triple rapid Cmd+C

    @Test("triple rapid Cmd+C fires once for the first pair, third rearms")
    func tripleCmdCFiresOnce() {
        var detector = DoubleTapDetector()
        let t0 = 0.0
        let t1 = t0 + 0.1
        let t2 = t1 + 0.1

        let r0 = detector.handle(timestamp: t0, isCmdC: true)
        let r1 = detector.handle(timestamp: t1, isCmdC: true) // fires
        let r2 = detector.handle(timestamp: t2, isCmdC: true) // third: rearms, does not fire

        #expect(r0 == false)
        #expect(r1 == true,  "second tap fires the chord")
        #expect(r2 == false, "third tap rearms (becomes new first tap)")
    }

    @Test("after triple, a fourth rapid Cmd+C fires again")
    func quadrupleCmdCFiresTwice() {
        var detector = DoubleTapDetector()
        let base = 0.0
        var results: [Bool] = []
        for i in 0..<4 {
            results.append(detector.handle(timestamp: base + Double(i) * 0.1, isCmdC: true))
        }
        // pair 1 fires at index 1, pair 2 fires at index 3
        #expect(results[0] == false)
        #expect(results[1] == true)
        #expect(results[2] == false)
        #expect(results[3] == true)
    }

    // MARK: - Non-Cmd+C events are ignored / reset state

    @Test("non-Cmd+C event before any tap: no fire")
    func nonCmdCBeforeAnyTap() {
        var detector = DoubleTapDetector()
        let r1 = detector.handle(timestamp: 0.0, isCmdC: false)
        let r2 = detector.handle(timestamp: 0.1, isCmdC: true)  // first real Cmd+C
        let r3 = detector.handle(timestamp: 0.2, isCmdC: false) // interleaved non-Cmd+C
        let r4 = detector.handle(timestamp: 0.3, isCmdC: true)  // this should NOT fire

        #expect(r1 == false)
        #expect(r2 == false)
        #expect(r3 == false)
        // r3 reset the detector, so r4 is a lone first tap — no fire.
        #expect(r4 == false)
    }
}
