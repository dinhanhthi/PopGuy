// ComposerTextViewTests.swift
// PopGuyTests
//
// Regression test for the Terminal Composer editor freezing after Select All and
// typing: replacing a long selection with one typed character must not raise
// inside the text storage's edit pass (that left the editor stuck mid-edit).

import AppKit
import SwiftUI
import Testing
@testable import PopGuy

@MainActor
@Suite("Terminal Composer text view")
struct ComposerTextViewTests {

    @Test("typing over a select-all replaces the text and keeps the editor editable")
    func typingOverSelectAll() throws {
        // Both delegates are unretained: keep the coordinator alive for the whole test.
        let coordinator = ComposerTextView.Coordinator(parent: ComposerTextView(text: .constant("")))
        let scrollView = ComposerTextView.makeScrollView(
            text: "# Title\nSome **bold** and `code` text\n```\nlet x = 1\n```\n- item",
            coordinator: coordinator)
        let textView = try #require(scrollView.documentView as? ComposerNSTextView)
        // The text view updates the font panel (where the crash was) only in the app's
        // key or main window: make a never-shown window main, so nothing appears on screen.
        let window = MainWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scrollView
        window.makeMain()
        window.makeFirstResponder(textView)
        let typing = NSRange(location: NSNotFound, length: 0)

        textView.selectAll(nil)
        textView.insertText("x", replacementRange: typing)
        #expect(textView.string == "x")

        textView.insertText("y", replacementRange: typing)
        #expect(textView.string == "xy")
    }
}

/// Can become the app's main window while hidden (borderless windows cannot by default).
private final class MainWindow: NSWindow {
    override var canBecomeMain: Bool { true }
}
