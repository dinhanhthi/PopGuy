// StatusMenuTriggerItemTests.swift
// PopGuyTests

import AppKit
import Testing
@testable import PopGuy

@MainActor
@Suite("Status menu trigger items")
struct StatusMenuTriggerItemTests {
    @Test("text selection trigger has an icon")
    func textSelectionTriggerHasIcon() {
        let item = makeStatusTriggerMenuItem(
            .textSelection,
            isOn: true,
            action: #selector(NSApplication.hide(_:))
        )

        #expect(item.title == "Show on Text Selection")
        #expect(item.state == .on)
        #expect(item.image != nil)
    }

    @Test("double-click trigger has an icon")
    func doubleClickTriggerHasIcon() {
        let item = makeStatusTriggerMenuItem(
            .doubleClick,
            isOn: false,
            action: #selector(NSApplication.hide(_:))
        )

        #expect(item.title == "Show on Double-Click")
        #expect(item.state == .off)
        #expect(item.image != nil)
    }
}
