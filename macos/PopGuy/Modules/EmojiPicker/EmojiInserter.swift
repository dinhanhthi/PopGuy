// EmojiInserter.swift
// PopGuy — EmojiPicker
//
// Puts a picked emoji into the frontmost app with one synthetic Unicode key event
// (Core Graphics events), or copies it to the clipboard when typing is not possible.
//
// Isolation: MainActor — called by the picker controller after the panel hides.

import AppKit
import CoreGraphics

@MainActor
enum EmojiInserter {
    /// "PGEM", stored in the event's source user data. Reserved so a future PopGuy event tap
    /// can skip the events PopGuy posted itself; nothing reads it today.
    static let tag: Int64 = 0x5047454D

    /// A key event carries at most about 20 UTF-16 units of text; the rest is dropped.
    static let maxUnicodeLength = 20

    /// Types `text` as one tagged keyDown/keyUp pair posted to the HID event tap.
    /// Text longer than `maxUnicodeLength` UTF-16 units is copied instead.
    static func type(_ text: String) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return }
        guard utf16.count <= maxUnicodeLength else {
            copy(text)
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
            else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            utf16.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    /// Writes `text` to the general pasteboard as plain text.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
