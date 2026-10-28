// PasteboardSnapshotTests.swift
// PopGuyTests
//
// Unit tests for PasteboardSnapshot against a named (non-general) pasteboard.
// Using a named board ensures these tests NEVER touch NSPasteboard.general
// and cannot clobber the real user clipboard during a test run.

import AppKit
import Testing
@testable import PopGuy

@Suite("PasteboardSnapshot")
@MainActor
struct PasteboardSnapshotTests {

    // Named board used exclusively in these tests.
    let board = NSPasteboard(name: NSPasteboard.Name("PopGuyTests.PasteboardSnapshot"))

    @Test("capture records changeCount and string item")
    func captureRecordsChangeCountAndStringItem() {
        board.clearContents()
        board.setString("hello snapshot", forType: .string)

        let snapshot = PasteboardSnapshot.capture(from: board)

        #expect(snapshot.changeCount == board.changeCount)
        #expect(snapshot.items.count == 1)
        let typeKey = NSPasteboard.PasteboardType.string.rawValue
        #expect(snapshot.items.first?.dataByType[typeKey] != nil)
    }

    @Test("restore writes snapshot data back and replaces current contents")
    func restoreWritesSnapshotBack() {
        board.clearContents()
        board.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot.capture(from: board)

        // Replace with something else.
        board.clearContents()
        board.setString("overwritten", forType: .string)
        #expect(board.string(forType: .string) == "overwritten")

        // Restore.
        snapshot.restore(to: board)
        #expect(board.string(forType: .string) == "original")
    }

    @Test("capture of empty board produces empty items array")
    func captureEmptyBoard() {
        board.clearContents()

        let snapshot = PasteboardSnapshot.capture(from: board)

        #expect(snapshot.items.isEmpty)
    }
}
