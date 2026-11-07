// ListContinuationTests.swift
// PopGuyTests
//
// Tests for the Terminal Composer's Markdown list editing (pure text → edit).
// Covers:
//   - Return continues "-", "*" and numbered items (indentation kept, number + 1)
//   - Return on an empty item clears it; Return before the marker or off a list is plain
//   - Backspace right after a marker deletes the marker, elsewhere it is plain
//   - The composer's text view applies them on Return/Backspace

import AppKit
import Testing
@testable import PopGuy

@Suite("Terminal Composer list continuation")
struct ListContinuationTests {

    private func applying(_ edit: ListContinuation.Edit?, to text: String) -> String? {
        guard let edit else { return nil }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    private func afterReturn(_ text: String, caret: Int? = nil) -> String? {
        applying(ListContinuation.returnEdit(in: text, caret: caret ?? (text as NSString).length), to: text)
    }

    private func afterBackspace(_ text: String, caret: Int? = nil) -> String? {
        applying(ListContinuation.backspaceEdit(in: text, caret: caret ?? (text as NSString).length), to: text)
    }

    @Test("Return continues bullets and numbers with the same indentation")
    func returnContinues() {
        #expect(afterReturn("- one") == "- one\n- ")
        #expect(afterReturn("intro\n* one") == "intro\n* one\n* ")
        #expect(afterReturn("1. one") == "1. one\n2. ")
        #expect(afterReturn("9. nine") == "9. nine\n10. ")
        #expect(afterReturn("  - nested 😀") == "  - nested 😀\n  - ")
        // The caret mid-item splits it, the rest moving to the new item.
        #expect(afterReturn("- onetwo\nnext", caret: 5) == "- one\n- two\nnext")
    }

    @Test("Return on an empty item clears it; off a list it is plain")
    func returnEndsOrIgnores() {
        #expect(afterReturn("- one\n- ") == "- one\n")
        #expect(afterReturn("- one\n  2.  ") == "- one\n")
        #expect(afterReturn("plain") == nil)
        #expect(afterReturn("-not a marker") == nil)
        #expect(afterReturn("- one\n") == nil)
        #expect(afterReturn("1.5 kg") == nil)
        // The caret before the marker's end: a plain newline.
        #expect(afterReturn("- one", caret: 1) == nil)
    }

    @Test("Backspace right after a marker deletes the marker")
    func backspaceDeletesMarker() {
        #expect(afterBackspace("- one\n- ") == "- one\n")
        #expect(afterBackspace("  12. ") == "  ")
        #expect(afterBackspace("* item", caret: 2) == "item")
        #expect(afterBackspace("- item") == nil)
        #expect(afterBackspace("- ", caret: 1) == nil)
        #expect(afterBackspace("plain ") == nil)
    }

    @Test("the composer text view applies list edits on Return and Backspace")
    @MainActor
    func textViewAppliesEdits() {
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.string = "1. one"
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string == "1. one\n2. ")
        textView.deleteBackward(nil)
        #expect(textView.string == "1. one\n")
        textView.insertText("- a", replacementRange: textView.selectedRange())
        textView.insertNewline(nil)
        textView.insertNewline(nil)
        #expect(textView.string == "1. one\n- a\n")
    }
}
