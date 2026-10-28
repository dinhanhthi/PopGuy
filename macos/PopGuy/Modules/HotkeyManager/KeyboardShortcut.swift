// KeyboardShortcut.swift
// PopGuy — HotkeyManager
//
// Codable value type for a global keyboard shortcut binding.
//
// Three representation layers:
//   1. Stored (this file): UInt32 keyCode + NSEventModifierFlags.RawValue (UInt)
//      — canonical Codable form persisted to UserDefaults.
//   2. Carbon / RegisterEventHotKey: UInt32 keyCode + UInt32 Carbon modifier mask
//      — different bit positions than NSEvent flags.
//   3. NSEvent (recorder): CGKeyCode + NSEvent.ModifierFlags
//      — used when reading key-down events in the recorder.
//
// The pure converters (nsModifiers ↔ carbonModifiers) are unit-tested in
// ShortcutBindingTests to guard against accidental mapping drift.
//
// Isolation: nonisolated / Sendable — pure value type; no actor context needed.

import Carbon
import CoreGraphics
import Foundation

// MARK: - KeyboardShortcut

// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct KeyboardShortcut: Codable, Sendable, Equatable, Hashable {

    /// Virtual key code (hardware-layout independent — the same as CGKeyCode /
    /// Carbon's keyCode parameter to RegisterEventHotKey).
    let keyCode: UInt32

    /// Modifier flags stored as NSEvent.ModifierFlags.rawValue (UInt).
    /// Only the device-independent bits are stored (.command, .option, .control, .shift).
    let modifierFlags: UInt

    nonisolated init(keyCode: UInt32, modifierFlags: UInt) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }
}

// MARK: - Carbon modifier conversion

extension KeyboardShortcut {

    /// Convert NSEvent.ModifierFlags (device-independent bits) to the Carbon
    /// UInt32 modifier mask expected by RegisterEventHotKey.
    ///
    /// Carbon uses different bit positions from NSEvent:
    ///   NSEvent .command = 1<<20; Carbon cmdKey    = 1<<8  (256)
    ///   NSEvent .option  = 1<<19; Carbon optionKey = 1<<11 (2048)
    ///   NSEvent .control = 1<<18; Carbon controlKey= 1<<12 (4096)
    ///   NSEvent .shift   = 1<<17; Carbon shiftKey  = 1<<9  (512)
    nonisolated var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        let ns = modifierFlags
        if ns & (1 << 20) != 0 { carbon |= UInt32(cmdKey) }       // .command
        if ns & (1 << 19) != 0 { carbon |= UInt32(optionKey) }    // .option
        if ns & (1 << 18) != 0 { carbon |= UInt32(controlKey) }   // .control
        if ns & (1 << 17) != 0 { carbon |= UInt32(shiftKey) }     // .shift
        return carbon
    }

    /// Convert a Carbon modifier UInt32 to the NSEvent modifier flag bits (UInt).
    nonisolated static func modifiersFromCarbon(_ carbon: UInt32) -> UInt {
        var ns: UInt = 0
        if carbon & UInt32(cmdKey)     != 0 { ns |= (1 << 20) }   // .command
        if carbon & UInt32(optionKey)  != 0 { ns |= (1 << 19) }   // .option
        if carbon & UInt32(controlKey) != 0 { ns |= (1 << 18) }   // .control
        if carbon & UInt32(shiftKey)   != 0 { ns |= (1 << 17) }   // .shift
        return ns
    }
}

// MARK: - Human-readable description

extension KeyboardShortcut {

    /// Short display string for use in the Shortcuts settings UI (e.g. "⌘⇧K").
    nonisolated var displayString: String {
        var parts: [String] = []
        let ns = modifierFlags
        if ns & (1 << 18) != 0 { parts.append("⌃") }   // control
        if ns & (1 << 19) != 0 { parts.append("⌥") }   // option
        if ns & (1 << 17) != 0 { parts.append("⇧") }   // shift
        if ns & (1 << 20) != 0 { parts.append("⌘") }   // command
        // Translate virtual key code to a character via lookup table.
        parts.append(Self.keyCodeToGlyph(keyCode))
        return parts.joined()
    }

    /// Best-effort glyph for a virtual key code.
    ///
    /// Covers the most common shortcut keys. For uncovered codes, falls back
    /// to a decimal string so the UI always shows something.
    private nonisolated static func keyCodeToGlyph(_ keyCode: UInt32) -> String {
        switch keyCode {
        case 0:  return "A"
        case 1:  return "S"
        case 2:  return "D"
        case 3:  return "F"
        case 4:  return "H"
        case 5:  return "G"
        case 6:  return "Z"
        case 7:  return "X"
        case 8:  return "C"
        case 9:  return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 36: return "↩"   // Return
        case 48: return "⇥"   // Tab
        case 49: return "Space"
        case 51: return "⌫"   // Delete
        case 53: return "⎋"   // Escape
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return "#\(keyCode)"
        }
    }
}

// MARK: - ShortcutBinding

/// Associates an action identifier with its global keyboard shortcut.
///
/// Stored as an array of bindings (not a dictionary) because Swift Codable does
/// not round-trip custom enum keys in `[Key: Value]` dictionaries reliably.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct ShortcutBinding: Codable, Sendable, Equatable {
    let actionID: ActionIdentifier
    let shortcut: KeyboardShortcut

    nonisolated init(actionID: ActionIdentifier, shortcut: KeyboardShortcut) {
        self.actionID = actionID
        self.shortcut = shortcut
    }
}

// MARK: - Default built-in shortcuts

extension ShortcutBinding {

    /// Default global shortcuts for the five built-in actions: ⌃⌥⌘ + mnemonic
    /// (I/S/P/T/K). Applied on first launch only — when no bindings have been
    /// persisted yet. ⌃⌥⌘ is an uncommon modifier combo, so these rarely
    /// collide with other apps; the user can still rebind or clear any of them.
    ///
    /// Each mnemonic letter is resolved to the key code that PRODUCES it under
    /// the current keyboard layout (via `virtualKeyCode`), so the shortcut still
    /// matches the action's initial on non-QWERTY layouts (Dvorak/AZERTY). The
    /// fallbacks are the US-QWERTY virtual key codes (I=34, S=1, P=35, T=17, K=40).
    ///
    /// @MainActor: resolves key codes via `virtualKeyCode` (TIS/UCKey, main-thread
    /// only). Both call sites — `SettingsStore.init` and the tests — are @MainActor.
    @MainActor static var defaultBuiltins: [ShortcutBinding] {
        // NSEvent device-independent bits: control 1<<18, option 1<<19, command 1<<20.
        // Shift (1<<17) is intentionally omitted — the combo is ⌃⌥⌘, no shift.
        let mods: UInt = (1 << 18) | (1 << 19) | (1 << 20)
        func make(_ kind: ActionKind, _ mnemonic: Unicode.Scalar, fallback: CGKeyCode) -> ShortcutBinding {
            let keyCode = virtualKeyCode(for: mnemonic, fallback: fallback)
            return ShortcutBinding(
                actionID: .builtin(kind),
                shortcut: KeyboardShortcut(keyCode: UInt32(keyCode), modifierFlags: mods)
            )
        }
        let speakKeyCode = virtualKeyCode(for: "k", fallback: 40)
        let speakBinding = ShortcutBinding(
            actionID: .speak,
            shortcut: KeyboardShortcut(keyCode: UInt32(speakKeyCode), modifierFlags: mods)
        )
        return [
            make(.improve,   "i", fallback: 34),
            make(.shorten,   "s", fallback: 1),
            make(.proofread, "p", fallback: 35),
            make(.translate, "t", fallback: 17),
            speakBinding,
        ]
    }
}
