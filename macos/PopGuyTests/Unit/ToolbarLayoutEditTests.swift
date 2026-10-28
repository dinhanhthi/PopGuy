// ToolbarLayoutEditTests.swift
// PopGuyTests
//
// TDD: atomic zone move + reorder via SettingsStore.moveAction(_:toZone:atIndex:).

import CoreGraphics
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

    @Test("moving between zones keeps the Show label flag")
    func moveKeepsLabel() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let moving = store.principalOrderedIdentifiers[0]
        store.setLabeled(moving, true)

        store.moveAction(moving, toZone: false, atIndex: 0)
        #expect(store.isLabeled(moving))
        store.moveAction(moving, toZone: true, atIndex: 0)
        #expect(store.isLabeled(moving))
        #expect(store.labeledActionIDs == [moving])
    }
}

// MARK: - Drag math

/// Pure insertion-index / preview-order math behind the Settings → Actions
/// drag-and-drop editor (neighbour-swap with hysteresis).
@Suite("Toolbar layout editor drag math")
struct ToolbarLayoutEditMathTests {

    private let a = ActionIdentifier.builtin(.improve)
    private let b = ActionIdentifier.builtin(.shorten)
    private let c = ActionIdentifier.builtin(.translate)
    private let d = ActionIdentifier.speak

    /// Lays `ids` out left to right with the given widths (no spacing).
    private func frames(_ ids: [ActionIdentifier], widths: [CGFloat]) -> [ActionIdentifier: CGRect] {
        var x: CGFloat = 0
        var result: [ActionIdentifier: CGRect] = [:]
        for (id, w) in zip(ids, widths) {
            result[id] = CGRect(x: x, y: 0, width: w, height: 26)
            x += w
        }
        return result
    }

    @Test("moving right past the next neighbour's midX steps +1; short of it stays")
    func stepsRight() {
        // Layout a | d(dragged) | b | c, each 20pt wide: b spans 40-60 (midX 50).
        let order = [a, d, b, c]
        let f = frames(order, widths: [20, 20, 20, 20])
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 51, current: 1, orderedIDs: order, frames: f, dragging: d) == 2)
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 49, current: 1, orderedIDs: order, frames: f, dragging: d) == 1)
    }

    @Test("moving left past the previous neighbour's midX steps -1; short of it stays")
    func stepsLeft() {
        // Layout a | b | d(dragged) | c: b spans 20-40 (midX 30).
        let order = [a, b, d, c]
        let f = frames(order, widths: [20, 20, 20, 20])
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 29, current: 2, orderedIDs: order, frames: f, dragging: d) == 1)
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 31, current: 2, orderedIDs: order, frames: f, dragging: d) == 2)
    }

    @Test("a fast drag across several neighbours steps all the way")
    func multiStep() {
        let order = [d, a, b, c]
        let f = frames(order, widths: [20, 20, 20, 20])
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 75, current: 0, orderedIDs: order, frames: f, dragging: d) == 3)
    }

    @Test("uneven widths: after a swap the pointer does not bounce back")
    func unevenWidthsHysteresis() {
        // Narrow dragged icon (10pt) next to a wide labeled neighbour (100pt).
        let before = [d, b]
        let f1 = frames(before, widths: [10, 100]) // b midX 60
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 59, current: 0, orderedIDs: before, frames: f1, dragging: d) == 0)
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 61, current: 0, orderedIDs: before, frames: f1, dragging: d) == 1)

        // After the swap b sits at 0-100 (midX 50); pointer at 61 must stay at 1.
        let after = [b, d]
        let f2 = frames(after, widths: [100, 10])
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 61, current: 1, orderedIDs: after, frames: f2, dragging: d) == 1)
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 49, current: 1, orderedIDs: after, frames: f2, dragging: d) == 0)
    }

    @Test("entering a row (current 0, dragged not in the row) lands before the first midX right of the pointer")
    func entersRow() {
        let order = [a, b, c]
        let f = frames(order, widths: [20, 20, 20]) // midX 10, 30, 50
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 35, current: 0, orderedIDs: order, frames: f, dragging: d) == 2)
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 5, current: 0, orderedIDs: order, frames: f, dragging: d) == 0)
    }

    @Test("empty row yields 0; index clamps at both ends")
    func emptyAndClamp() {
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 100, current: 3, orderedIDs: [], frames: [:], dragging: d) == 0)
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 100, current: 0, orderedIDs: [d], frames: [:], dragging: d) == 0)

        let order = [a, b, d]
        let f = frames(order, widths: [20, 20, 20])
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 1_000, current: 2, orderedIDs: order, frames: f, dragging: d) == 2)
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: 1_000, current: 9, orderedIDs: order, frames: f, dragging: d) == 2)
        #expect(ToolbarLayoutEditMath.insertionIndex(pointerX: -1_000, current: -4, orderedIDs: order, frames: f, dragging: d) == 0)
    }

    @Test("previewOrder moves the dragged item to the clamped index")
    func previewOrder() {
        #expect(ToolbarLayoutEditMath.previewOrder([a, b, c], dragging: a, at: 2) == [b, c, a])
        #expect(ToolbarLayoutEditMath.previewOrder([a, b], dragging: d, at: 1) == [a, d, b])
        #expect(ToolbarLayoutEditMath.previewOrder([a, b], dragging: d, at: 99) == [a, b, d])
        #expect(ToolbarLayoutEditMath.previewOrder([], dragging: d, at: -1) == [d])
    }
}
