// EmojiCaretLocatorTests.swift
// PopGuyTests
//
// Tests for the Emoji Picker caret locator's pure helpers (ported from FastMoji).

import CoreGraphics
import Testing
@testable import PopGuy

@Suite("EmojiCaretLocator")
struct EmojiCaretLocatorTests {

    @Test("Chromium-style bogus caret outside the focused field is rejected")
    func bogusCaretOutsideFieldIsRejected() {
        let element = CGRect(x: 500, y: 300, width: 400, height: 24)

        #expect(!EmojiCaretLocator.isPlausibleCaret(CGRect(x: 0, y: 0, width: 0, height: 16), in: element))
        #expect(EmojiCaretLocator.isPlausibleCaret(CGRect(x: 620, y: 304, width: 1, height: 16), in: element))
        // Maximised browser: the focused web area covers the screen, so containment alone passes.
        let webArea = CGRect(x: 0, y: 25, width: 1512, height: 957)
        #expect(!EmojiCaretLocator.isPlausibleCaret(CGRect(x: 0, y: 0, width: 0, height: 16), in: webArea))
        // Native apps: an empty caret at position 0 often reports zero height; it must stay usable.
        #expect(EmojiCaretLocator.isPlausibleCaret(CGRect(x: 510, y: 304, width: 0, height: 0), in: element))
    }

    @Test("caret in a small field anchors to the whole field, so the panel never covers it")
    func caretInSmallFieldAnchorsToField() {
        // Safari's address bar: a 16 pt caret inside a 36 pt field.
        let field = CGRect(x: 300, y: 60, width: 600, height: 36)
        let caret = CGRect(x: 420, y: 70, width: 1, height: 16)
        #expect(EmojiCaretLocator.anchor(caret, in: field) == CGRect(x: 420, y: 60, width: 1, height: 36))
        // Large text view (TextEdit): keep the caret line.
        let textView = CGRect(x: 0, y: 60, width: 800, height: 600)
        #expect(EmojiCaretLocator.anchor(caret, in: textView) == caret)
    }

    @Test("a secure text field is detected by its role or its subrole")
    func secureTextFieldIsDetected() {
        #expect(EmojiCaretLocator.isSecureTextInput(role: "AXSecureTextField", subrole: nil))
        #expect(EmojiCaretLocator.isSecureTextInput(role: "AXTextField", subrole: "AXSecureTextField"))
        #expect(!EmojiCaretLocator.isSecureTextInput(role: "AXTextField", subrole: nil))
        #expect(!EmojiCaretLocator.isSecureTextInput(role: nil, subrole: nil))
    }
}
