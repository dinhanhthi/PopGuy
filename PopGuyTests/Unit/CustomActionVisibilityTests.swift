// CustomActionVisibilityTests.swift
// PopGuyTests
//
// Unit tests for CustomAction.isVisible(forSelection:) and CustomAction.isScriptable.
//
// Test framework: Swift Testing (@Test / #expect).

import Foundation
import Testing
@testable import PopGuy

// MARK: - Helpers

private func makeAction(
    type: CustomActionType,
    appliesWhenRegex: String = ""
) -> CustomAction {
    CustomAction(
        title: "Test",
        type: type,
        systemPrompt: type == .ai ? "Do something" : "",
        scriptSource: type.isScriptableType ? "echo hi" : "",
        appliesWhenRegex: appliesWhenRegex
    )
}

// Convenience for test helpers only — not on the type itself.
private extension CustomActionType {
    var isScriptableType: Bool {
        self == .openURL || self == .runShortcut || self == .appleScript || self == .shellScript
    }
}

// MARK: - isScriptable

@Suite("CustomAction.isScriptable")
struct CustomActionIsScriptableTests {

    @Test(".openURL is scriptable")
    func openURLIsScriptable() {
        #expect(makeAction(type: .openURL).isScriptable)
    }

    @Test(".runShortcut is scriptable")
    func runShortcutIsScriptable() {
        #expect(makeAction(type: .runShortcut).isScriptable)
    }

    @Test(".appleScript is scriptable")
    func appleScriptIsScriptable() {
        #expect(makeAction(type: .appleScript).isScriptable)
    }

    @Test(".shellScript is scriptable")
    func shellScriptIsScriptable() {
        #expect(makeAction(type: .shellScript).isScriptable)
    }

    @Test(".ai is not scriptable")
    func aiNotScriptable() {
        #expect(!makeAction(type: .ai).isScriptable)
    }

    @Test(".translation is not scriptable")
    func translationNotScriptable() {
        #expect(!makeAction(type: .translation).isScriptable)
    }

    @Test(".speech is not scriptable")
    func speechNotScriptable() {
        #expect(!makeAction(type: .speech).isScriptable)
    }

    @Test(".dictionary is not scriptable")
    func dictionaryNotScriptable() {
        #expect(!makeAction(type: .dictionary).isScriptable)
    }
}

// MARK: - isVisible(forSelection:)

@Suite("CustomAction.isVisible(forSelection:)")
struct CustomActionIsVisibleTests {

    // MARK: Empty regex — always visible

    @Test("empty regex + scriptable type → always visible")
    func emptyRegexScriptable() {
        let action = makeAction(type: .shellScript, appliesWhenRegex: "")
        #expect(action.isVisible(forSelection: "/Users/thi/file.txt"))
        #expect(action.isVisible(forSelection: "hello world"))
        #expect(action.isVisible(forSelection: ""))
    }

    @Test("empty regex + non-scriptable type → always visible")
    func emptyRegexNonScriptable() {
        let action = makeAction(type: .ai, appliesWhenRegex: "")
        #expect(action.isVisible(forSelection: "anything"))
        #expect(action.isVisible(forSelection: ""))
    }

    // MARK: Input length cap (ReDoS bound)

    @Test("match beyond maxRegexInputLength is not found (input is truncated)")
    func inputLengthCapTruncatesBeforeMatch() {
        // The only "MATCH" lies past the 4096-char cap, so the truncated input does
        // not contain it → not visible. If the cap were removed, this would match.
        // This pins the maxRegexInputLength truncation (the ReDoS bound).
        let selection = String(repeating: "a", count: CustomAction.maxRegexInputLength + 500) + "MATCH"
        let action = makeAction(type: .shellScript, appliesWhenRegex: "MATCH")
        #expect(!action.isVisible(forSelection: selection))

        // Sanity: the same pattern matches when "MATCH" is within the cap.
        let shortSelection = "head MATCH tail"
        #expect(makeAction(type: .shellScript, appliesWhenRegex: "MATCH").isVisible(forSelection: shortSelection))
    }

    // MARK: Non-scriptable types — regex is ignored (always visible)

    @Test("non-scriptable .ai with non-empty regex → always visible (regex ignored)")
    func aiWithRegexAlwaysVisible() {
        // Even with a regex that would not match, non-scriptable types are unaffected.
        let action = makeAction(type: .ai, appliesWhenRegex: "^(/|~|file:).+")
        #expect(action.isVisible(forSelection: "hello"))
        #expect(action.isVisible(forSelection: ""))
    }

    @Test("non-scriptable .translation with regex → always visible")
    func translationWithRegexAlwaysVisible() {
        let action = makeAction(type: .translation, appliesWhenRegex: "^https?://")
        #expect(action.isVisible(forSelection: "not a url"))
    }

    @Test("non-scriptable .speech with regex → always visible")
    func speechWithRegexAlwaysVisible() {
        let action = makeAction(type: .speech, appliesWhenRegex: "\\d+")
        #expect(action.isVisible(forSelection: "no digits here"))
    }

    @Test("non-scriptable .dictionary with regex → always visible")
    func dictionaryWithRegexAlwaysVisible() {
        let action = makeAction(type: .dictionary, appliesWhenRegex: "^https?://")
        #expect(action.isVisible(forSelection: "just text"))
    }

    // MARK: Matching regex — visible

    @Test("scriptable with matching regex → visible (file path pattern)")
    func matchingFilePathRegex() {
        let action = makeAction(type: .shellScript, appliesWhenRegex: "^(/|~|file:).+")
        #expect(action.isVisible(forSelection: "/Users/thi/file.txt"))
        #expect(action.isVisible(forSelection: "~/Documents/report.pdf"))
        #expect(action.isVisible(forSelection: "file:///tmp/x"))
    }

    @Test("scriptable with matching regex → visible (URL pattern)")
    func matchingURLRegex() {
        let action = makeAction(type: .openURL, appliesWhenRegex: "^https?://")
        #expect(action.isVisible(forSelection: "https://example.com"))
        #expect(action.isVisible(forSelection: "http://localhost:3000"))
    }

    @Test("scriptable with partial match → visible (regex finds match anywhere in string)")
    func partialMatch() {
        // The regex "\\d+" matches a substring — firstMatch returns non-nil.
        let action = makeAction(type: .appleScript, appliesWhenRegex: "\\d+")
        #expect(action.isVisible(forSelection: "page 42 of 100"))
    }

    // MARK: Non-matching regex — hidden

    @Test("scriptable with non-matching regex → hidden")
    func nonMatchingRegex() {
        let action = makeAction(type: .shellScript, appliesWhenRegex: "^(/|~|file:).+")
        #expect(!action.isVisible(forSelection: "hello world"))
        #expect(!action.isVisible(forSelection: "not a path"))
        #expect(!action.isVisible(forSelection: ""))
    }

    @Test("scriptable with URL regex on non-URL → hidden")
    func nonMatchingURLRegex() {
        let action = makeAction(type: .openURL, appliesWhenRegex: "^https?://")
        #expect(!action.isVisible(forSelection: "just some selected text"))
        #expect(!action.isVisible(forSelection: "ftp://not-http.com"))
    }

    // MARK: Malformed regex — fail open (always visible)

    @Test("malformed regex (unclosed group) → fail open, always visible")
    func malformedRegexUnclosedGroup() {
        let action = makeAction(type: .shellScript, appliesWhenRegex: "(")
        // Bad regex must NOT crash and must return true (fail open).
        #expect(action.isVisible(forSelection: "/Users/thi/file.txt"))
        #expect(action.isVisible(forSelection: "hello"))
        #expect(action.isVisible(forSelection: ""))
    }

    @Test("malformed regex (invalid escape) → fail open, always visible")
    func malformedRegexInvalidEscape() {
        let action = makeAction(type: .appleScript, appliesWhenRegex: "[invalid")
        #expect(action.isVisible(forSelection: "any text"))
    }

    // MARK: Edge cases

    @Test("empty selection text with non-empty regex → hidden (no match)")
    func emptySelectionNonEmptyRegex() {
        let action = makeAction(type: .shellScript, appliesWhenRegex: ".+")
        // ".+" requires at least one character, so empty string doesn't match.
        #expect(!action.isVisible(forSelection: ""))
    }

    @Test("case-sensitive by default — uppercase pattern doesn't match lowercase")
    func caseSensitiveDefault() {
        let action = makeAction(type: .shellScript, appliesWhenRegex: "^PATH")
        #expect(!action.isVisible(forSelection: "path/to/file"))
        #expect(action.isVisible(forSelection: "PATH=/usr/bin"))
    }

    // MARK: Multiline edge cases

    @Test("multiline — path regex doesn't match non-leading /path in multiline text")
    func multilinePathDoesNotMatchNonLeadingSlash() {
        // NSRegularExpression default has no anchorsMatchLines option:
        // ^ anchors to the very start of the string, not each line.
        // So "^(/|~|file:).+" must NOT match "hello\n/path".
        let action = makeAction(type: .shellScript, appliesWhenRegex: "^(/|~|file:).+")
        #expect(!action.isVisible(forSelection: "hello\n/path/to/file"))
    }

    // MARK: Unicode / emoji — UTF-16 NSRange bridging

    @Test("Unicode/emoji selection doesn't crash and is matched correctly")
    func unicodeEmojiNSRangeBridging() {
        // Uses multi-byte Unicode (emoji + accented chars) to exercise the
        // UTF-16 NSRange bridging in isVisible(forSelection:).
        let action = makeAction(type: .shellScript, appliesWhenRegex: "\\d+")
        // Emoji + digits — should match the digits.
        #expect(action.isVisible(forSelection: "👋 page 42"))
        // Emoji + accented chars, no digits — should not match.
        #expect(!action.isVisible(forSelection: "Héllo 🌍 wörld"))
    }
}

// MARK: - Round-trip consistency (visible helper)

@Suite("CustomAction.visible(_:forSelection:)")
struct CustomActionVisibleHelperTests {

    // MARK: Helpers

    private func makeScriptableAction(regex: String) -> CustomAction {
        CustomAction(
            title: "Test Script",
            type: .shellScript,
            systemPrompt: "",
            scriptSource: "echo hi",
            appliesWhenRegex: regex
        )
    }

    private func makeNonScriptableAction(regex: String) -> CustomAction {
        CustomAction(
            title: "Test AI",
            type: .ai,
            systemPrompt: "Do something",
            appliesWhenRegex: regex
        )
    }

    // MARK: Matching regex — present in both sets

    @Test("scriptable action whose regex matches is present in visible set")
    func matchingRegexPresent() {
        let action = makeScriptableAction(regex: "^(/|~|file:).+")
        let result = CustomAction.visible([action], forSelection: "/Users/thi/file.txt")
        #expect(result.map(\.id) == [action.id])
    }

    // MARK: Non-matching regex — absent from both sets

    @Test("scriptable action whose regex doesn't match is absent from visible set")
    func nonMatchingRegexAbsent() {
        let action = makeScriptableAction(regex: "^(/|~|file:).+")
        let result = CustomAction.visible([action], forSelection: "plain prose text")
        #expect(result.isEmpty)
    }

    // MARK: Non-scriptable types — always present regardless of regex

    @Test("non-scriptable action with non-matching regex is always present")
    func nonScriptableAlwaysPresent() {
        let action = makeNonScriptableAction(regex: "^(/|~|file:).+")
        let result = CustomAction.visible([action], forSelection: "plain prose text")
        #expect(result.map(\.id) == [action.id])
    }

    // MARK: Mixed list — scriptable hidden, non-scriptable present

    @Test("mixed list: only the matching and non-scriptable actions survive the filter")
    func mixedListFilter() {
        let hiddenScript  = makeScriptableAction(regex: "^(/|~|file:).+")
        let visibleScript = makeScriptableAction(regex: "\\d+")
        let nonScript     = makeNonScriptableAction(regex: "^(/|~|file:).+")
        let selection     = "page 42"  // matches \d+ but not ^(/|~|file:).+
        let result = CustomAction.visible([hiddenScript, visibleScript, nonScript], forSelection: selection)
        let resultIDs = result.map(\.id)
        // hiddenScript must be absent, visibleScript and nonScript must be present.
        #expect(!resultIDs.contains(hiddenScript.id))
        #expect(resultIDs.contains(visibleScript.id))
        #expect(resultIDs.contains(nonScript.id))
    }

    // MARK: Empty regex — always present

    @Test("scriptable with empty regex is always present in visible set")
    func emptyRegexAlwaysPresent() {
        let action = makeScriptableAction(regex: "")
        let result = CustomAction.visible([action], forSelection: "anything")
        #expect(result.map(\.id) == [action.id])
    }
}
