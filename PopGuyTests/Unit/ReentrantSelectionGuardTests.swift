// ReentrantSelectionGuardTests.swift
// PopGuyTests
//
// Unit tests for `shouldIgnoreReentrantSelection` — the pure guard that stops a
// re-entrant selection event (same text, while the toolbar is showing and an
// action has already been dispatched) from resetting the view model and
// repositioning the panel. A genuinely different selection still re-shows.

import Testing
@testable import PopGuy

@Suite("shouldIgnoreReentrantSelection")
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

// MARK: - effectiveIgnoredApps tests

@Suite("effectiveIgnoredApps")
struct EffectiveIgnoredAppsTests {

    private let apps = ["com.a", "com.b", "com.c", "com.d", "com.e"]

    @Test("Pro returns the full list regardless of maxAllowed")
    func proReturnsAll() {
        let result = effectiveIgnoredApps(apps, maxAllowed: 2, isPro: true)
        #expect(result == apps)
    }

    @Test("non-Pro caps to the first maxAllowed by insertion order")
    func nonProCapsToPrefix() {
        let result = effectiveIgnoredApps(apps, maxAllowed: 3, isPro: false)
        #expect(result == ["com.a", "com.b", "com.c"])
    }

    @Test("non-Pro with count below cap returns all")
    func nonProBelowCapReturnsAll() {
        let short = ["com.x", "com.y"]
        let result = effectiveIgnoredApps(short, maxAllowed: 8, isPro: false)
        #expect(result == short)
    }

    @Test("empty list is safe for both Pro and non-Pro")
    func emptyListIsSafe() {
        #expect(effectiveIgnoredApps([], maxAllowed: 5, isPro: true) == [])
        #expect(effectiveIgnoredApps([], maxAllowed: 5, isPro: false) == [])
    }

    @Test("non-Pro maxAllowed=0 returns empty")
    func zeroCap() {
        let result = effectiveIgnoredApps(apps, maxAllowed: 0, isPro: false)
        #expect(result.isEmpty)
    }
}
