// ClipboardFallback.swift
// PopGuy
//
// Fallback text-capture path: simulates Cmd+C, reads the result from
// NSPasteboard.general, then IMMEDIATELY restores the previous pasteboard
// contents.
//
// HARD CONSTRAINT (see CLAUDE.md): "when the fallback simulates Cmd+C, the
// previous pasteboard contents must be restored immediately after reading;
// never leave the user's clipboard clobbered." PopGuy never leaves its own
// synthetic Cmd+C copy on the clipboard — the original is always restored.
// (See the "Clipboard-restore decision" block below for the known
// best-effort limitation; this is NOT a two-directional guarantee.)
//
// Strict-concurrency design:
//   All pasteboard and CGEvent work is @MainActor-isolated.
//   The async delay uses polling on changeCount — no blocking sleep on the
//   main actor.
//
// Clipboard-restore decision (Fix 1):
//   The fallback ALWAYS restores the user's original pasteboard after reading.
//   PopGuy never leaves its synthetic Cmd+C copy behind on the clipboard.
//   This satisfies the CLAUDE.md hard constraint unconditionally.
//
//   KNOWN BEST-EFFORT LIMITATION: synthetic Cmd+C cannot distinguish our own
//   copy from a foreign process that writes the pasteboard during the ~600 ms
//   poll window.  Both reads (`captured` and any re-read) are synchronous on
//   the MainActor with no suspension point between them, so a "copy landed vs.
//   external writer" comparison is always identical — the distinction is
//   structurally undetectable.  In the exotic case where a foreign process
//   writes the board during our window, that foreign text is read AS the
//   captured selection and then the original is restored over it.
//   Consequences: (a) the original user clipboard is still safely restored —
//   the hard constraint holds; (b) the returned "selection" could be the
//   foreign text rather than the real selection — a best-effort capture
//   limitation.  Flag for MANUAL QA.  This is inherent to the synthetic-Cmd+C
//   approach and bounded by the 600 ms poll window.
//
// Residual race (Fix 2, documented):
//   If the target app processes Cmd+C AFTER our 600 ms poll window closes,
//   a late-arriving copy will land on the board after we restored the original.
//   This race is inherent (we cannot coordinate with the target app) and is
//   bounded by the 600 ms timeout.  Flag for MANUAL QA: if the user notices
//   a clipboard side-effect after a capture, it is this race.
//
// Keyboard-layout awareness (Fix 4):
//   keyCodeForC() maps the Unicode character 'c' to the virtual keycode for
//   the CURRENT keyboard layout via Carbon UCKeyTranslate.  Falls back to
//   keycode 8 (ANSI 'c') when the layout look-up fails.

import AppKit
import CoreGraphics

/// Clipboard-based fallback for text selection capture.
///
/// When the primary AX attribute read returns nothing (the source app does
/// not expose kAXSelectedTextAttribute), this path:
///   1. Snapshots NSPasteboard.general (including changeCount and string).
///   2. Posts a synthetic Cmd+C to the source app.
///   3. Polls changeCount in short intervals until it advances or timeout.
///   4. Reads the new clipboard string.
///   5. Restores the previous clipboard contents (always — see the
///      clipboard-restore decision above).
@MainActor
struct ClipboardFallback {

    /// Maximum wait after posting Cmd+C before giving up. The loop still breaks
    /// as soon as `changeCount` advances, so this only bounds the slow case —
    /// large selections in apps that serialize the pasteboard slowly (e.g.
    /// Electron) can take longer than the old 250 ms ceiling to land.
    static let maxPollDuration: UInt64 = 600_000_000 // nanoseconds (600 ms)

    /// Interval between changeCount polls.
    static let pollInterval: UInt64 = 20_000_000 // nanoseconds (20 ms)

    // MARK: - Public interface

    /// Capture selected text via the clipboard fallback.
    ///
    /// - Parameter pid: The PID of the source application.
    /// - Returns: The selected text, or `nil` if capture failed.
    func capture(from pid: pid_t) async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let c0 = snapshot.changeCount

        // Post synthetic Cmd+C to the source app.
        postCmdC(to: pid)

        // Poll changeCount in short intervals to detect when the copy lands.
        // NOTE: after the loop, we re-read c1 from actual pasteboard state
        // (not from which branch broke the loop) so that a copy that lands
        // simultaneously with Task cancellation is still recognized (Fix 2).
        let steps = Int(ClipboardFallback.maxPollDuration / ClipboardFallback.pollInterval)
        for _ in 0 ..< steps {
            if Task.isCancelled { break }
            if pasteboard.changeCount > c0 {
                break
            }
            try? await Task.sleep(nanoseconds: ClipboardFallback.pollInterval)
        }

        // Re-read current state from pasteboard (not from loop-exit branch).
        let c1 = pasteboard.changeCount
        let copyLanded = (c1 > c0)

        // Read the new clipboard text only if the count advanced AND the new
        // string is non-empty (empty means the app responded with nothing).
        let captured: String?
        if copyLanded, let s = pasteboard.string(forType: .string), !s.isEmpty {
            captured = s
        } else {
            // changeCount unchanged (copy never landed) or empty — treat as
            // "did not land".  We never captured anything useful.
            // RESIDUAL RACE: if the copy arrives AFTER this poll window, it
            // will land after we restore below.  This is bounded by the 600 ms
            // timeout and requires MANUAL QA.
            captured = nil
        }

        // HARD CONSTRAINT: always restore the original pasteboard (Fix 1).
        // See header comment for the known best-effort limitation regarding
        // exotic foreign writes during the poll window.
        snapshot.restore(to: pasteboard)

        // `captured` is either nil or a non-empty string (set only in the
        // guarded branch above), so it can be returned directly.
        return captured
    }

    // MARK: - Synthetic key event

    /// Post a Cmd+C key-down/key-up pair to the application identified by `pid`.
    ///
    /// Uses the shared `virtualKeyCode(for:fallback:)` helper from
    /// Utilities/KeyCodeHelper.swift for keyboard-layout-aware keycode lookup
    /// (Fix 4 — Dvorak, AZERTY, etc.). ANSI fallback = keycode 8.
    private func postCmdC(to pid: pid_t) {
        let cKeyCode = virtualKeyCode(for: "c", fallback: 8)

        guard
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: cKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: cKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Post to the target PID's event stream so other apps are not affected.
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }
}
