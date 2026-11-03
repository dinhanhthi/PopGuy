// KeyboardSelectionKeyTests.swift
// PopGuyTests
//
// Unit tests for the pure keyboard-gesture helpers: `isKeyboardSelectionKey`
// (SelectionEvent.swift), which makes a keyboard selection show the toolbar, and
// `shouldCheckSelectionClearedOnKey` (ToolbarController.swift), which decides
// whether a key press re-checks the selection to close the toolbar.

import Testing
import AppKit
@testable import PopGuy

@Suite("Keyboard selection keys")
struct KeyboardSelectionKeyTests {

    // Key codes.
    let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, home: UInt16 = 115, pageDown: UInt16 = 121
    let a: UInt16 = 0, c: UInt16 = 8

    @Test("Shift with a navigation key selects, with Option or Command optional")
    func shiftNavigationSelects() {
        #expect(isKeyboardSelectionKey(keyCode: right, characters: nil, flags: [.shift]))
        #expect(isKeyboardSelectionKey(keyCode: left, characters: nil, flags: [.shift, .option]))
        #expect(isKeyboardSelectionKey(keyCode: down, characters: nil, flags: [.shift, .command]))
        #expect(isKeyboardSelectionKey(keyCode: home, characters: nil, flags: [.shift]))
        // Arrow events carry the function and numeric-pad flags too.
        #expect(isKeyboardSelectionKey(keyCode: pageDown, characters: nil, flags: [.shift, .function, .numericPad]))
    }

    @Test("Command+A selects on any layout, by its character")
    func commandASelects() {
        #expect(isKeyboardSelectionKey(keyCode: a, characters: "a", flags: [.command]))
        // AZERTY: the A key has another key code.
        #expect(isKeyboardSelectionKey(keyCode: 12, characters: "a", flags: [.command]))
    }

    @Test("caret moves, typing, other shortcuts and Control combos do not select")
    func nonSelectionKeys() {
        #expect(!isKeyboardSelectionKey(keyCode: right, characters: nil, flags: []))
        #expect(!isKeyboardSelectionKey(keyCode: right, characters: nil, flags: [.command]))
        #expect(!isKeyboardSelectionKey(keyCode: right, characters: nil, flags: [.shift, .control]))
        #expect(!isKeyboardSelectionKey(keyCode: a, characters: "a", flags: []))
        #expect(!isKeyboardSelectionKey(keyCode: a, characters: "a", flags: [.command, .shift]))
        #expect(!isKeyboardSelectionKey(keyCode: c, characters: "c", flags: [.command]))
    }

    @Test("when the probe sees the selection every key re-checks it")
    func everyKeyChecksWhenProbeSeesSelection() {
        #expect(shouldCheckSelectionClearedOnKey(keyCode: c, characters: "c", flags: [.command], selectionHiddenFromProbe: false))
        #expect(shouldCheckSelectionClearedOnKey(keyCode: right, characters: nil, flags: [], selectionHiddenFromProbe: false))
        #expect(shouldCheckSelectionClearedOnKey(keyCode: left, characters: nil, flags: [.shift], selectionHiddenFromProbe: false))
    }

    @Test("when the probe may miss the selection (Monaco, Books) shortcuts and Shift selection keys never close the toolbar")
    func hiddenSelectionSkipsShortcutsAndSelectionKeys() {
        #expect(!shouldCheckSelectionClearedOnKey(keyCode: c, characters: "c", flags: [.command], selectionHiddenFromProbe: true))
        #expect(!shouldCheckSelectionClearedOnKey(keyCode: right, characters: nil, flags: [.shift], selectionHiddenFromProbe: true))
        #expect(shouldCheckSelectionClearedOnKey(keyCode: right, characters: nil, flags: [], selectionHiddenFromProbe: true))
        #expect(shouldCheckSelectionClearedOnKey(keyCode: 0, characters: "x", flags: [], selectionHiddenFromProbe: true))
    }
}
