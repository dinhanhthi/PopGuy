// OutputHandler.swift
// PopGuy
//
// Delivers AI-action results back to the user via two paths:
//
//   1. copy(_ text:)      — writes to NSPasteboard.general (intentional,
//                           user-visible write — clipboard hygiene N/A here).
//   2. pasteBack(_:to:)   — snapshots the pasteboard, sets result text,
//                           posts synthetic Cmd+V to the source app's PID,
//                           waits a short delay, then restores the original
//                           pasteboard (clipboard hygiene).
//
// Clipboard-restore decision (paste-back path):
//   The delay before restore (~150 ms) is a best-effort window for the target
//   app to process the Cmd+V. A race exists: if the app processes the paste
//   after this window, it may read the restored (original) clipboard instead
//   of the result text.  This is an inherent limitation of the synthetic-paste
//   approach and matches the caveat documented in ClipboardFallback.swift.
//   MANUAL QA required.
//
// Strict concurrency:
//   All pasteboard and CGEvent work is @MainActor-isolated.
//   PasteboardSnapshot.capture/restore are also @MainActor (see Utilities/).

import AppKit
import ApplicationServices
import CoreGraphics
import Carbon

// MARK: - OutputHandler

/// Delivers AI results to the user via copy-to-clipboard or synthetic paste-back.
///
/// Isolation: @MainActor — NSPasteboard and CGEvent are main-thread-only.
@MainActor
final class OutputHandler {

    // MARK: - Reentrancy guard

    /// Prevents interleaved paste-back calls from clobbering the clipboard.
    /// Safe to use as a plain Bool because all access is @MainActor-isolated.
    private var isPasting = false

    // MARK: - Copy

    /// Write result text to NSPasteboard.general.
    ///
    /// This is an intentional, user-visible clipboard write (the user tapped
    /// "Copy"). Clipboard hygiene (restore) does NOT apply here.
    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Paste-back

    /// Write result text to the source application via synthetic Cmd+V.
    ///
    /// Steps:
    ///   1. Snapshot the current pasteboard.
    ///   2. Set result text on the pasteboard.
    ///   3. Derive the source app PID from `source.element`.
    ///   4. Post Cmd+V key-down + key-up to that PID.
    ///   5. Wait ~150 ms (best-effort window for the target app to process paste).
    ///   6. Restore the original pasteboard (clipboard hygiene).
    ///
    /// - Parameters:
    ///   - text:   The result text to paste.
    ///   - source: The AXUIElement reference pointing to the originating element.
    func pasteBack(_ text: String, to source: SourceElementRef) async {
        guard !isPasting else { return }
        isPasting = true
        defer { isPasting = false }

        let pasteboard = NSPasteboard.general

        // 1. Snapshot.
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        // 2. Set result text.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Derive PID.
        var pid: pid_t = 0
        AXUIElementGetPid(source.element, &pid)
        guard pid > 0 else {
            // Could not determine PID — restore and bail.
            snapshot.restore(to: pasteboard)
            return
        }

        // 4. Post Cmd+V.
        postCmdV(to: pid)

        // 5. Best-effort delay to let the target app process the paste
        //    before we restore the clipboard.
        //    Clipboard-restore race: if the app processes Cmd+V after this
        //    150 ms window, it reads the restored clipboard instead.
        //    This is an inherent limitation of synthetic paste (same caveat as
        //    ClipboardFallback). Flag for MANUAL QA.
        try? await Task.sleep(nanoseconds: 150_000_000) // 150 ms

        // 6. Restore original pasteboard (clipboard hygiene).
        snapshot.restore(to: pasteboard)
    }

    // MARK: - Synthetic Cmd+V

    private func postCmdV(to pid: pid_t) {
        // Keyboard-layout-aware: find the keycode that produces 'v' in the
        // current layout. ANSI fallback = keycode 9.
        let vKeyCode = virtualKeyCode(for: "v", fallback: 9)

        guard
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
            let keyUp   = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand

        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }
}
