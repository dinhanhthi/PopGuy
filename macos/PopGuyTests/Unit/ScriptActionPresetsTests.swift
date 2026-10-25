// ScriptActionPresetsTests.swift
// PopGuyTests
//
// Unit tests for ScriptActionPresets.
//
// Test framework: Swift Testing (@Test / #expect).

import Foundation
import Testing
@testable import PopGuy

@Suite("ScriptActionPresets")
struct ScriptActionPresetsTests {

    // MARK: - all() factory

    @Test("all() returns three presets")
    func allReturnsThreePresets() {
        #expect(ScriptActionPresets.all().count == 3)
    }

    @Test("two calls to all() produce different ids")
    func allProducesDifferentIDsEachCall() {
        let first = ScriptActionPresets.all()
        let second = ScriptActionPresets.all()
        let firstIDs = Set(first.map(\.id))
        let secondIDs = Set(second.map(\.id))
        #expect(firstIDs.isDisjoint(with: secondIDs))
    }

    @Test("revealInFinder() and searchGoogle() produce different ids on separate calls")
    func factoryFunctionsDifferentIDs() {
        let a = ScriptActionPresets.revealInFinder()
        let b = ScriptActionPresets.revealInFinder()
        #expect(a.id != b.id)
    }

    // MARK: - All presets: isScriptable + isSaveable

    @Test("all presets are scriptable")
    func allPresetsAreScriptable() {
        for preset in ScriptActionPresets.all() {
            #expect(preset.isScriptable, "preset '\(preset.title)' should be scriptable")
        }
    }

    @Test("all presets are saveable")
    func allPresetsAreSaveable() {
        for preset in ScriptActionPresets.all() {
            #expect(preset.isSaveable, "preset '\(preset.title)' should be saveable")
        }
    }

    // MARK: - Reveal in Finder

    @Test("Reveal in Finder has shellScript type")
    func revealInFinderIsShellScript() {
        #expect(ScriptActionPresets.revealInFinder().type == .shellScript)
    }

    @Test("Reveal in Finder afterRun is .closeToolbar")
    func revealInFinderAfterRunIsCloseToolbar() {
        #expect(ScriptActionPresets.revealInFinder().afterRun == .closeToolbar)
    }

    @Test("Reveal in Finder has path regex")
    func revealInFinderHasPathRegex() {
        let preset = ScriptActionPresets.revealInFinder()
        #expect(!preset.appliesWhenRegex.isEmpty)
        // Regex should match typical file paths
        #expect(preset.isVisible(forSelection: "/Users/thi/file.txt"))
        #expect(preset.isVisible(forSelection: "~/Documents/report.pdf"))
        // Regex should not match plain text
        #expect(!preset.isVisible(forSelection: "hello world"))
    }

    @Test("Reveal in Finder scriptSource references POPGUY_TEXT")
    func revealInFinderScriptSourceValid() {
        let source = ScriptActionPresets.revealInFinder().scriptSource
        #expect(source.contains("POPGUY_TEXT"))
        #expect(source.contains("open"))
    }

    // MARK: - Search Google

    @Test("Search Google has openURL type")
    func searchGoogleIsOpenURL() {
        #expect(ScriptActionPresets.searchGoogle().type == .openURL)
    }

    @Test("Search Google afterRun is .closeToolbar")
    func searchGoogleAfterRunIsCloseToolbar() {
        #expect(ScriptActionPresets.searchGoogle().afterRun == .closeToolbar)
    }

    @Test("Search Google scriptSource contains google.com and text token")
    func searchGoogleScriptSourceValid() {
        let source = ScriptActionPresets.searchGoogle().scriptSource
        #expect(source.contains("google.com"))
        #expect(source.contains(PlaceholderExpander.textToken))
    }

    @Test("Search Google has empty appliesWhenRegex (always visible)")
    func searchGoogleAlwaysVisible() {
        let preset = ScriptActionPresets.searchGoogle()
        #expect(preset.appliesWhenRegex.isEmpty)
        #expect(preset.isVisible(forSelection: "anything"))
        #expect(preset.isVisible(forSelection: ""))
    }

    // MARK: - New TextEdit Document

    @Test("New TextEdit Document has appleScript type")
    func newTextEditDocumentIsAppleScript() {
        #expect(ScriptActionPresets.newTextEditDocument().type == .appleScript)
    }

    @Test("New TextEdit Document afterRun is .closeToolbar")
    func newTextEditDocumentAfterRunIsCloseToolbar() {
        #expect(ScriptActionPresets.newTextEditDocument().afterRun == .closeToolbar)
    }

    @Test("New TextEdit Document scriptSource targets TextEdit and uses text token")
    func newTextEditDocumentScriptSourceValid() {
        let source = ScriptActionPresets.newTextEditDocument().scriptSource
        #expect(source.contains("TextEdit"))
        #expect(source.contains(PlaceholderExpander.textToken))
    }

    @Test("New TextEdit Document text token expands to a quoted, escaped literal")
    func newTextEditDocumentExpandsSafely() {
        let source = ScriptActionPresets.newTextEditDocument().scriptSource
        let expanded = PlaceholderExpander.expandAppleScript(source: source, text: #"a "b" c"#)
        // The token is replaced by a self-contained, escaped string literal.
        #expect(!expanded.contains(PlaceholderExpander.textToken))
        #expect(expanded.contains(#"{text:"a \"b\" c"}"#))
    }
}
