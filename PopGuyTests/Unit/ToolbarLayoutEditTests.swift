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
        let name = UserDefaults.testSuiteDirectory + "/com.popguy.test.\(UUID().uuidString)"
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
        store.moveAction(moving, toZone: true, atIndex: 0)
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
        store.moveAction(principalID, toZone: false, atIndex: overflowBefore.count)
        #expect(!store.isPrincipal(principalID))
        #expect(store.overflowOrderedIdentifiers.last == principalID)
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
        store.moveAction(moving, toZone: true, atIndex: 1)
        #expect(store.principalOrderedIdentifiers[1] == moving)
    }

    /// Fills More actions with three custom actions and returns them in order.
    private func storeWithThreeInMore(_ suite: UserDefaults) -> (SettingsStore, [ActionIdentifier]) {
        let store = SettingsStore(defaults: suite)
        for i in 0..<3 {
            let action = CustomAction(title: "More \(i)", systemPrompt: "p", isEnabled: true)
            store.addCustomAction(action)
            store.setPrincipal(.custom(action.id), false)
        }
        return (store, store.overflowOrderedIdentifiers)
    }

    @Test("toolbar to More at index 0 lands first")
    func toolbarToMoreAtStart() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let (store, more) = storeWithThreeInMore(suite)
        #expect(more.count == 3)
        let moving = store.principalOrderedIdentifiers[0]

        store.moveAction(moving, toZone: false, atIndex: 0)
        #expect(store.overflowOrderedIdentifiers == [moving] + more)
    }

    @Test("toolbar to More at a middle index lands at that index")
    func toolbarToMoreAtMiddle() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let (store, more) = storeWithThreeInMore(suite)
        #expect(more.count == 3)
        let moving = store.principalOrderedIdentifiers[0]

        store.moveAction(moving, toZone: false, atIndex: 2)
        #expect(store.overflowOrderedIdentifiers == [more[0], more[1], moving, more[2]])
    }

    @Test("reorder within More moves the action to the target index")
    func reorderWithinMore() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let (store, more) = storeWithThreeInMore(suite)
        #expect(more.count == 3)

        store.moveAction(more[2], toZone: false, atIndex: 0)
        #expect(store.overflowOrderedIdentifiers == [more[2], more[0], more[1]])
    }

    @Test("More to toolbar at index i lands at i")
    func moreToToolbarAtIndex() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let (store, more) = storeWithThreeInMore(suite)
        #expect(more.count == 3)
        let principalBefore = store.principalOrderedIdentifiers

        store.moveAction(more[1], toZone: true, atIndex: 2)
        #expect(store.isPrincipal(more[1]))
        #expect(store.principalOrderedIdentifiers.count == principalBefore.count + 1)
        #expect(store.principalOrderedIdentifiers[2] == more[1])
        #expect(store.overflowOrderedIdentifiers == [more[0], more[2]])
    }
}
