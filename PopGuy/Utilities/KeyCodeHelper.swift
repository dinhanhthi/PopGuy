// KeyCodeHelper.swift
// PopGuy
//
// Keyboard-layout-aware virtual keycode lookup using Carbon UCKeyTranslate.
//
// Shared by ClipboardFallback (Cmd+C) and OutputHandler (Cmd+V) so the
// 40-line UCKeyTranslate scan is not duplicated.
//
// This is a free function (no type wrapper needed for a single utility).
// It is nonisolated because TIS/UCKey APIs are documented main-thread-safe
// and are called exclusively from @MainActor contexts in this project.

import Carbon
import CoreGraphics

/// Returns the virtual keycode that produces the given Unicode character
/// under the CURRENT keyboard layout, using Carbon UCKeyTranslate.
///
/// Scans keycodes 0–127 under no-modifier state. Falls back to `fallbackKeyCode`
/// when the layout data is unavailable or the character is not found.
///
/// TIS/UCKey APIs are main-thread-safe; callers are @MainActor.
func virtualKeyCode(for character: Unicode.Scalar, fallback fallbackKeyCode: CGKeyCode) -> CGKeyCode {
    guard
        let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
        let layoutDataPtr = TISGetInputSourceProperty(
            inputSource,
            kTISPropertyUnicodeKeyLayoutData
        )
    else { return fallbackKeyCode }

    let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue()
    let keyLayoutPtr = CFDataGetBytePtr(layoutData)
    let keyboardLayout = unsafeBitCast(keyLayoutPtr, to: UnsafePointer<UCKeyboardLayout>.self)

    var deadKeyState: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var charCount: Int = 0
    let target = UniChar(character.value)

    for keyCodeInt in 0 ..< 128 {
        let keyCode = CGKeyCode(keyCodeInt)
        deadKeyState = 0
        charCount = 0
        let status = UCKeyTranslate(
            keyboardLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDown),
            0, // no modifier
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &charCount,
            &chars
        )
        if status == noErr, charCount == 1, chars[0] == target {
            return keyCode
        }
    }

    return fallbackKeyCode
}
