// DoubleTapChord.swift
// PopGuy — HotkeyManager
//
// Installs a low-level CGEventTap to observe keyDown events and detect a
// Cmd+C double-tap chord (two Cmd+C presses within a tuned time window).
//
// Design principles:
//   1. OBSERVATIONAL — the tap passes every event through unmodified. It
//      never swallows the first Cmd+C; ordinary copies are unaffected.
//   2. PURE STATE MACHINE — all chord logic is in DoubleTapDetector (a plain
//      struct). This class only bridges C callbacks → DoubleTapDetector →
//      @MainActor chord action.
//   3. AUTO-RE-ENABLE — the tap re-enables itself if the system disables it
//      (kCGEventTapDisabledByTimeout / kCGEventTapDisabledByUserInput).
//
// C callback bridging (strict concurrency):
//   The CGEventTap callback is a @convention(c) function — it cannot be
//   actor-isolated and cannot capture Swift context. The DoubleTapChord
//   instance is recovered from the `userInfo` refcon via Unmanaged.
//   The tap source is added to the main run loop so callbacks fire on the
//   main thread; `MainActor.assumeIsolated` is safe for the small state
//   mutations that follow.
//
// nonisolated(unsafe) rationale:
//   `detector`, `runLoopSource`, and `tapPort` are declared nonisolated(unsafe)
//   so that the nonisolated deinit and the @convention(c) callback can read
//   them without an actor hop. Safety: all writes happen on the MainActor
//   (start() / stop() / callback are all main-thread). deinit runs after the
//   last retain is released, at which point no concurrent MainActor mutation
//   can be in flight.

import AppKit
import CoreGraphics
import Foundation
import QuartzCore

// MARK: - Chord action type

/// Called on the main actor when a Cmd+C double-tap chord is detected.
typealias ChordAction = @MainActor (PasteboardSnapshot?) -> Void

// MARK: - DoubleTapChord

/// Installs a CGEventTap to detect the Cmd+C double-tap chord.
///
/// Isolation: @MainActor — start/stop and the chord callback run on the main
/// actor. The @convention(c) tap callback fires on the main run loop and uses
/// MainActor.assumeIsolated to access state safely.
@MainActor
final class DoubleTapChord {

    // MARK: - Configuration

    /// The virtual keycode for 'C' on ANSI/US layouts. Hardcoded as the
    /// default; KeyCodeHelper.virtualKeyCode(for:fallback:) is main-actor-safe
    /// and is used at start() time to handle non-US layouts.
    private static let fallbackCKeyCode: CGKeyCode = 8

    // MARK: - State

    // nonisolated(unsafe): written only on MainActor; read from @convention(c)
    // callback (main run loop) via MainActor.assumeIsolated — safe, same thread.
    nonisolated(unsafe) private var detector = DoubleTapDetector()
    nonisolated(unsafe) private var tapPort: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?

    /// The virtual keycode for 'C' in the current keyboard layout.
    /// Resolved at start() time.
    private var cKeyCode: CGKeyCode = DoubleTapChord.fallbackCKeyCode

    /// Called on the main actor when a chord fires, with the clipboard snapshot
    /// taken on the arming tap (or nil when none was captured).
    private let onChord: ChordAction

    /// Optional clipboard snapshot taken on the arming (first) Cmd+C, before the
    /// app processes that copy. Lets the chord handler restore the user's
    /// pre-chord clipboard afterward (the user's own ⌘C clobbers it otherwise).
    private let captureArmSnapshot: (@MainActor () -> PasteboardSnapshot?)?

    /// Stash for the most recent arm snapshot, consumed when the chord fires.
    // nonisolated(unsafe): same MainActor-confined-via-assumeIsolated pattern as `detector`.
    nonisolated(unsafe) private var pendingArmSnapshot: PasteboardSnapshot?

    // MARK: - Init

    /// - Parameters:
    ///   - captureArmSnapshot: Optional block run on the arming Cmd+C to snapshot
    ///     the clipboard before the app overwrites it. Return nil to skip.
    ///   - onChord: Block called on the main actor when the chord fires.
    init(captureArmSnapshot: (@MainActor () -> PasteboardSnapshot?)? = nil,
         onChord: @escaping ChordAction) {
        self.captureArmSnapshot = captureArmSnapshot
        self.onChord = onChord
    }

    deinit {
        // deinit is nonisolated — only safe to call C APIs here.
        // tapPort / runLoopSource are nonisolated(unsafe) for exactly this reason.
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
    }

    // MARK: - Lifecycle

    /// Install the CGEventTap and start observing.
    ///
    /// Requires trusted-accessibility status (AXIsProcessTrusted() == true).
    /// If the process is not trusted the tap will not be installed — the caller
    /// should gate this on the result of AccessibilityPermission.isTrusted.
    func start() {
        guard tapPort == nil else { return } // Already running.

        // Resolve layout-aware keycode for 'C' (main-actor-safe Carbon API).
        // Unicode.Scalar(value:) returns an optional when value is out of range,
        // but 99 (ASCII 'c') is always valid — the fallback is unreachable.
        let cScalar = Unicode.Scalar(99) ?? Unicode.Scalar("c")
        cKeyCode = virtualKeyCode(for: cScalar, fallback: DoubleTapChord.fallbackCKeyCode)

        // `refcon` carries `self` as an unretained opaque pointer.
        // The literal callback below is @convention(c)-compatible and captures
        // nothing — context is recovered from refcon on each invocation.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Install as a passive (listen-only) tap: CGEventTapCreate with
        // kCGHeadInsertEventTap and kCGEventTapOptionListenOnly. Listen-only
        // means we can never accidentally swallow events even if the callback
        // mistakenly returns nil — the system ignores the return value.
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let chord = Unmanaged<DoubleTapChord>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // The system disabled the tap — re-enable it.
                    // MainActor.assumeIsolated is safe: the tap source runs on
                    // the main run loop, so callbacks fire on the main thread.
                    MainActor.assumeIsolated {
                        if let port = chord.tapPort {
                            CGEvent.tapEnable(tap: port, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                // Determine whether this is Cmd+C (exclusive: command only — no shift,
                // option, or control). CapsLock (.maskAlphaShift), numeric pad
                // (.maskNumericPad), and help (.maskHelp) are intentionally ignored so
                // they do not block the chord when active.
                let flags = event.flags
                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                let isCmdOnly = flags.contains(.maskCommand)
                    && !flags.contains(.maskShift)
                    && !flags.contains(.maskAlternate)
                    && !flags.contains(.maskControl)
                let isCmdC = isCmdOnly && (keyCode == chord.cKeyCode)

                // Feed into the pure state machine.
                // CGEvent.timestamp is mach_absolute_time (ticks at ~24 MHz on arm64,
                // NOT nanoseconds) — do not divide by 1e9. Instead, use
                // CACurrentMediaTime() which returns seconds on the same monotonic
                // clock and is safe to call from any thread.
                let timestamp = CACurrentMediaTime()

                MainActor.assumeIsolated {
                    let fired = chord.detector.handle(timestamp: timestamp, isCmdC: isCmdC)
                    if fired {
                        chord.onChord(chord.pendingArmSnapshot)
                        chord.pendingArmSnapshot = nil
                    } else if isCmdC {
                        // Arming (first) Cmd+C: snapshot the clipboard now, before
                        // the app processes this copy. The listen-only head-insert
                        // tap fires before the event reaches the app, so the board
                        // still holds the user's pre-chord content.
                        chord.pendingArmSnapshot = chord.captureArmSnapshot?()
                    } else {
                        // Non-Cmd+C key resets the chord — drop any stashed
                        // snapshot so a possibly-large copy isn't pinned in memory.
                        chord.pendingArmSnapshot = nil
                    }
                }

                // Observational — always pass the event through unmodified.
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        )

        guard let tap else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)

        tapPort = tap
        runLoopSource = source
    }

    /// Remove the CGEventTap and stop observing.
    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            runLoopSource = nil
        }
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
            tapPort = nil
        }
        detector.reset()
    }
}
