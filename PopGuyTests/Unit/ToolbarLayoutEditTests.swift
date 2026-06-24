// ToolbarLayoutEditTests.swift
// PopGuyTests
//
// TDD: atomic zone move + reorder via SettingsStore.moveAction(_:toZone:atIndex:).

import Foundation
import Testing
@testable import PopGuy

@Suite("Toolbar layout editor mutations")
@MainActor
struct ToolbarLayoutEditTests {

    private func makeSuite() -> (UserDefaults, String) {
        let name = "com.popguy.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func removeSuite(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    @Test("reorder within principal preserves zone membership")
    func reorderWithinPrincipal() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let before = store.principalOrderedIdentifiers
        guard before.count >= 2 else {
            Issue.record("Need at least two principal actions")
            return
        }

        let moving = before[1]
        #expect(store.moveAction(moving, toZone: true, atIndex: 0))
        #expect(store.principalOrderedIdentifiers.first == moving)
        #expect(Set(store.principalOrderedIdentifiers) == Set(before))
    }

    @Test("drag principal to burger updates membership and order")
    func movePrincipalToBurger() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        guard let principalID = store.principalOrderedIdentifiers.last else {
            Issue.record("Expected a principal action")
            return
        }

        let overflowBefore = store.overflowOrderedIdentifiers
        #expect(store.moveAction(principalID, toZone: false, atIndex: overflowBefore.count))
        #expect(!store.isPrincipal(principalID))
        #expect(store.overflowOrderedIdentifiers.last == principalID)
    }

    @Test("cap-full target zone rejects move")
    func rejectsWhenZoneFull() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        store.promptEnabled = true
        _ = store.setPrincipal(.builtin(.prompt), true)
        store.dictionaryConfig.isEnabled = true
        #expect(store.principalActionCount == ProConfig.maxPrincipalActions)

        #expect(!store.moveAction(.dictionary, toZone: true, atIndex: 0))
        #expect(!store.isPrincipal(.dictionary))
    }

    @Test("index translation lands at expected position among zone members")
    func landsAtExpectedIndex() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let principal = store.principalOrderedIdentifiers
        guard principal.count >= 3 else {
            Issue.record("Need at least three principal actions")
            return
        }

        let moving = principal[2]
        #expect(store.moveAction(moving, toZone: true, atIndex: 1))
        #expect(store.principalOrderedIdentifiers[1] == moving)
    }
}
