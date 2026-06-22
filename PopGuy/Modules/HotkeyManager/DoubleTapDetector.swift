// DoubleTapDetector.swift
// PopGuy — HotkeyManager
//
// Pure state machine that detects a Cmd+C double-tap chord.
//
// Design: DoubleTapDetector is completely isolated from CGEventTap and AppKit.
// It receives (timestamp, isCmdC) events and returns a Bool (chord fired).
// The CGEventTap in DoubleTapChord.swift feeds raw events into this detector.
//
// Policy for triple (and more) rapid Cmd+C:
//   - Tap 1: arms (no fire)
//   - Tap 2: fires chord, then RESETS (tap 2 does NOT rearm)
//     → the third tap becomes a new "tap 1"
// This gives clean pair semantics: [1,2], [3,4], … each fires once.
//
// Non-Cmd+C events reset the pending state so sequences like
// Cmd+C → other key → Cmd+C never trigger a chord.
//
// Isolation: nonisolated / Sendable struct. All state is value-type.
// The CGEventTap callback (a C function in DoubleTapChord.swift) mutates a
// copy of this detector — thread-safety is the caller's responsibility.
// DoubleTapChord runs on the main run loop so there is no concurrent mutation.

import Foundation

// MARK: - DoubleTapDetector

/// Pure state machine for Cmd+C double-tap chord detection.
///
/// Usage:
/// ```swift
/// var detector = DoubleTapDetector()
/// let fired = detector.handle(timestamp: CACurrentMediaTime(), isCmdC: true)
/// if fired { /* chord! */ }
/// ```
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct DoubleTapDetector: Sendable {

    // MARK: - Configuration

    /// Maximum interval (seconds) between two Cmd+C presses to count as a chord.
    let chordWindow: TimeInterval

    // MARK: - State

    /// Timestamp of the most recent Cmd+C tap, or nil if no pending tap.
    private var lastCmdCTimestamp: TimeInterval?

    // MARK: - Init

    nonisolated init(chordWindow: TimeInterval = 0.3) {
        self.chordWindow = chordWindow
    }

    // MARK: - Handle event

    /// Feed a keyboard event into the detector.
    ///
    /// - Parameters:
    ///   - timestamp: Monotonic timestamp in seconds (use CACurrentMediaTime() at
    ///     the call site — not CGEvent.timestamp which is mach_absolute_time ticks).
    ///   - isCmdC:   True if this event is a Cmd+C key-down; false for all other keys.
    /// - Returns: `true` if this event completed a double-tap chord; `false` otherwise.
    ///
    /// A non-Cmd+C event resets pending state so interleaved keypresses do not
    /// accidentally contribute to a chord.
    nonisolated mutating func handle(timestamp: TimeInterval, isCmdC: Bool) -> Bool {
        guard isCmdC else {
            // Any non-Cmd+C resets the pending first-tap.
            lastCmdCTimestamp = nil
            return false
        }

        if let last = lastCmdCTimestamp, (timestamp - last) < chordWindow {
            // Within window: chord fires. Reset state (so a third tap rearms).
            lastCmdCTimestamp = nil
            return true
        } else {
            // Either no pending tap, or the gap was too large.
            // Record this tap as the new "first tap" candidate.
            lastCmdCTimestamp = timestamp
            return false
        }
    }

    // MARK: - Reset

    /// Discard any pending first-tap state.
    nonisolated mutating func reset() {
        lastCmdCTimestamp = nil
    }
}
