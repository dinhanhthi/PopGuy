// TextSelectEditableGateTests.swift
// PopGuyTests
//
// Unit tests for `shouldShowOnTextSelect` — the pure gate that, when the
// "only in editable text" option is on, keeps the text-select trigger from
// showing the toolbar for read-only selections (web page text, chat messages).

import Foundation
import Testing
@testable import PopGuy

@Suite("shouldShowOnTextSelect")
@MainActor
struct TextSelectEditableGateTests {

    @Test("editable-only ON + editable source → show")
    func showsForEditableWhenEditableOnly() {
        #expect(shouldShowOnTextSelect(isEditable: true, editableOnly: true) == true)
    }

    @Test("editable-only ON + read-only source → do NOT show")
    func hidesForReadOnlyWhenEditableOnly() {
        #expect(shouldShowOnTextSelect(isEditable: false, editableOnly: true) == false)
    }

    @Test("editable-only OFF + editable source → show")
    func showsForEditableWhenNotEditableOnly() {
        #expect(shouldShowOnTextSelect(isEditable: true, editableOnly: false) == true)
    }

    @Test("editable-only OFF + read-only source → show")
    func showsForReadOnlyWhenNotEditableOnly() {
        #expect(shouldShowOnTextSelect(isEditable: false, editableOnly: false) == true)
    }
}
