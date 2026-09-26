// ReentrantSelectionGuardTests.swift
// PopGuyTests
//
// Unit tests for `shouldIgnoreReentrantSelection` — the pure guard that stops a
// re-entrant selection event (same text, while the toolbar is showing and an
// action has already been dispatched) from resetting the view model and
// repositioning the panel. A genuinely different selection still re-shows.

import Foundation
import Testing
@testable import PopGuy

@Suite("shouldIgnoreReentrantSelection")
@MainActor
struct ReentrantSelectionGuardTests {

    @Test("showing + action in progress + same text → ignore")
    func ignoresSameTextDuringAction() {
        #expect(shouldIgnoreReentrantSelection(
            isShowing: true, actionInProgress: true,
            newText: "hello world", currentText: "hello world"
        ) == true)
    }

    @Test("showing + action in progress + DIFFERENT text → do NOT ignore (re-show)")
    func allowsDifferentText() {
        #expect(shouldIgnoreReentrantSelection(
            isShowing: true, actionInProgress: true,
            newText: "new selection", currentText: "hello world"
        ) == false)
    }

    @Test("showing + idle (no action yet) + same text → do NOT ignore (reposition allowed)")
    func allowsRepositionWhenIdle() {
        #expect(shouldIgnoreReentrantSelection(
            isShowing: true, actionInProgress: false,
            newText: "hello world", currentText: "hello world"
        ) == false)
    }

    @Test("not showing → never ignore")
    func neverIgnoresWhenHidden() {
        #expect(shouldIgnoreReentrantSelection(
            isShowing: false, actionInProgress: true,
            newText: "hello world", currentText: "hello world"
        ) == false)
    }
}

// MARK: - ignored apps — full list (no prefix cap)

@Suite("ignored apps — full list")
@MainActor
struct IgnoredAppsIdentityTests {

    private func makeSuite() -> (UserDefaults, String) {
        let name = UserDefaults.testSuiteDirectory + "/com.popguy.test.ignoredapps.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func removeSuite(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    @Test("isIgnored matches every stored bundle id — no prefix cap")
    func fullListUsed() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let apps = ["com.a", "com.b", "com.c", "com.d", "com.e"]
        for id in apps { store.addIgnoredApp(bundleID: id) }

        #expect(store.ignoredAppBundleIDs == apps)
        for id in apps {
            #expect(store.isIgnored(bundleID: id))
        }
    }

    @Test("empty list ignores no bundle")
    func emptyListIsSafe() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.ignoredAppBundleIDs.isEmpty)
        #expect(store.isIgnored(bundleID: "com.a") == false)
    }

    @Test("list identity is preserved after add and remove")
    func addRemoveIdentity() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        store.addIgnoredApp(bundleID: "com.a")
        store.addIgnoredApp(bundleID: "com.b")
        store.addIgnoredApp(bundleID: "com.c")
        store.removeIgnoredApp(bundleID: "com.b")

        #expect(store.ignoredAppBundleIDs == ["com.a", "com.c"])
        #expect(store.isIgnored(bundleID: "com.a"))
        #expect(store.isIgnored(bundleID: "com.b") == false)
        #expect(store.isIgnored(bundleID: "com.c"))
    }
}
