// ToolbarViewModelTests.swift
// PopGuyTests
//
// Unit tests for ToolbarViewModel per-action labels (labeledActions) and
// the hasOverflow burger flag, plus the system-button flags (hasSystemButtons).
//
// Also covers edit-buffer invariants introduced in the editable-toolbar-result phase:
// finishWith seeds editedResult, reset/update clear it, beginEditing/endEditing toggle isEditing.

import ApplicationServices
import AppKit
import Testing
@testable import PopGuy

@Suite("ToolbarViewModel")
@MainActor
struct ToolbarViewModelTests {

    // MARK: - labeledActions

    @Test("labeledActions defaults to empty (all actions icon-only)")
    func labeledActionsDefaultsEmpty() {
        let vm = ToolbarViewModel()
        #expect(vm.labeledActions.isEmpty)
    }

    @Test("hasOverflow is false when overflowActions is empty")
    func hasOverflowFalse() {
        let vm = ToolbarViewModel()
        vm.overflowActions = []
        #expect(vm.hasOverflow == false)
    }

    @Test("hasOverflow is true when overflowActions is non-empty")
    func hasOverflowTrue() {
        let vm = ToolbarViewModel()
        vm.overflowActions = [.builtin(.translate)]
        #expect(vm.hasOverflow == true)
    }

    // MARK: - System buttons (Ignore this site / app, Settings)

    @Test("system button flags default to true")
    func systemButtonFlagsDefaultTrue() {
        let vm = ToolbarViewModel()
        #expect(vm.showsIgnoreAppButton == true)
        #expect(vm.showsSettingsButton == true)
        #expect(vm.hasSystemButtons == true)
    }

    @Test("hasSystemButtons is false when no system button is visible")
    func hasSystemButtonsFalseWhenNoneVisible() {
        let vm = ToolbarViewModel()
        vm.showsIgnoreAppButton = false
        vm.showsSettingsButton = false
        #expect(vm.sourceDomain == nil)
        #expect(vm.hasSystemButtons == false)
    }

    @Test("hasSystemButtons is true when only the Ignore this app button is visible")
    func hasSystemButtonsTrueForIgnoreApp() {
        let vm = ToolbarViewModel()
        vm.showsIgnoreAppButton = true
        vm.showsSettingsButton = false
        #expect(vm.hasSystemButtons == true)
    }

    @Test("hasSystemButtons is true when only the Settings button is visible")
    func hasSystemButtonsTrueForSettings() {
        let vm = ToolbarViewModel()
        vm.showsIgnoreAppButton = false
        vm.showsSettingsButton = true
        #expect(vm.hasSystemButtons == true)
    }

    @Test("hasSystemButtons is true when only Ignore this site is visible (source domain set)")
    func hasSystemButtonsTrueForSourceDomain() {
        let vm = ToolbarViewModel()
        vm.showsIgnoreAppButton = false
        vm.showsSettingsButton = false
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "x", sourceElement: ref, screenRect: nil, sourceBundleID: nil, sourceDomain: "example.com")
        #expect(vm.hasSystemButtons == true)
    }
}

// MARK: - Edit buffer invariants

@Suite("ToolbarViewModel edit buffer")
@MainActor
struct ToolbarViewModelEditBufferTests {

    @Test("finishWith seeds editedResult and clears isEditing")
    func finishWithSeedsEditedResult() {
        let vm = ToolbarViewModel()
        vm.isEditing = true
        vm.finishWith(result: "hello world")
        #expect(vm.editedResult == "hello world")
        #expect(vm.isEditing == false)
    }

    @Test("reset clears editedResult and isEditing")
    func resetClearsEditBuffer() {
        let vm = ToolbarViewModel()
        vm.finishWith(result: "some result")
        vm.isEditing = true
        vm.reset()
        #expect(vm.editedResult == "")
        #expect(vm.isEditing == false)
    }

    @Test("beginEditing sets isEditing true")
    func beginEditingToggles() {
        let vm = ToolbarViewModel()
        #expect(vm.isEditing == false)
        vm.beginEditing()
        #expect(vm.isEditing == true)
    }

    @Test("endEditing sets isEditing false")
    func endEditingToggles() {
        let vm = ToolbarViewModel()
        vm.beginEditing()
        #expect(vm.isEditing == true)
        vm.endEditing()
        #expect(vm.isEditing == false)
    }

    @Test("update clears editedResult and isEditing")
    func updateClearsEditBuffer() {
        let vm = ToolbarViewModel()
        vm.finishWith(result: "old result")
        vm.isEditing = true
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "new text", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        #expect(vm.editedResult == "")
        #expect(vm.isEditing == false)
    }
}

// MARK: - Toolbar error message rendering

@Suite("Toolbar error message text")
@MainActor
struct ToolbarErrorMessageTextTests {

    @Test("error message label is selectable so users can copy it")
    func errorMessageLabelIsSelectable() {
        let label = SelectableToolbarErrorText.makeLabel(
            message: "Provider failed with HTTP 401",
            font: .systemFont(ofSize: 11),
            textColor: .systemRed
        )

        #expect(label.isSelectable == true)
        #expect(label.isEditable == false)
        #expect(label.stringValue == "Provider failed with HTTP 401")
    }
}

// MARK: - Placeholder seeding and computed property tests

@Suite("ToolbarViewModel placeholder seeding and computed properties")
@MainActor
struct ToolbarViewModelComputedTests {

    // MARK: - Placeholder seeding

    @Test("triggerTranslate placeholder seeds editedResult, clears isEditing")
    func triggerTranslatePlaceholderSeeds() {
        let vm = ToolbarViewModel()
        vm.isEditing = true
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        vm.triggerTranslate()
        let expected = "[Phase 3] Translate (\(vm.targetLanguage.rawValue)): hello"
        #expect(vm.editedResult == expected)
        #expect(vm.isEditing == false)
    }

    @Test("triggerImprove placeholder seeds editedResult, clears isEditing")
    func triggerImprovePlaceholderSeeds() {
        let vm = ToolbarViewModel()
        vm.isEditing = true
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        vm.triggerImprove()
        #expect(vm.editedResult.hasPrefix("[Phase 3] Improve:"))
        #expect(vm.editedResult.contains("hello"))
        #expect(vm.isEditing == false)
    }

    @Test("triggerShorten placeholder seeds editedResult, clears isEditing")
    func triggerShortenPlaceholderSeeds() {
        let vm = ToolbarViewModel()
        vm.isEditing = true
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        vm.triggerShorten()
        #expect(vm.editedResult.hasPrefix("[Phase 3] Shorten:"))
        #expect(vm.editedResult.contains("hello"))
        #expect(vm.isEditing == false)
    }

    @Test("triggerProofread placeholder seeds editedResult, clears isEditing")
    func triggerProofreadPlaceholderSeeds() {
        let vm = ToolbarViewModel()
        vm.isEditing = true
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        vm.triggerProofread()
        #expect(vm.editedResult.hasPrefix("[Phase 3] Proofread:"))
        #expect(vm.editedResult.contains("hello"))
        #expect(vm.isEditing == false)
    }

    @Test("triggerCustomAction placeholder seeds editedResult, clears isEditing")
    func triggerCustomActionPlaceholderSeeds() {
        let vm = ToolbarViewModel()
        vm.isEditing = true
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        let action = CustomAction(
            title: "Summarize",
            icon: .sfSymbol("sparkles"),
            systemPrompt: "Summarize this.",
            providerKind: .anthropic,
            model: "claude-sonnet-4-6",
            isEnabled: true
        )
        vm.triggerCustomAction(action)
        #expect(vm.editedResult.hasPrefix("[Phase 5] Summarize:"))
        #expect(vm.editedResult.contains("hello"))
        #expect(vm.isEditing == false)
    }

    // MARK: - displayedResult equivalence

    @Test("displayedResult returns editedResult for non-diff actions")
    func displayedResultForNonDiff() {
        let vm = ToolbarViewModel()
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        // triggerTranslate (no handler) sets activeActionKind = .translate and actionState = .result
        vm.triggerTranslate()
        vm.editedResult = "edited"
        vm.isEditing = false
        #expect(vm.isResultEditable == true)
        #expect(vm.displayedResult == "edited")
    }

    @Test("displayedResult returns finalized result for diff actions")
    func displayedResultForDiff() {
        let vm = ToolbarViewModel()
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        // triggerImprove (no handler) sets activeActionKind = .improve and actionState = .result(placeholder)
        vm.triggerImprove()
        let placeholder = vm.editedResult
        vm.editedResult = "edited"
        #expect(vm.isResultEditable == false)
        // displayedResult must return the finalized result stored in actionState, not editedResult
        #expect(vm.displayedResult == placeholder)
    }

    @Test("isResultEditable is false for improve and proofread, true otherwise")
    func isResultEditableKinds() {
        let vm = ToolbarViewModel()
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "x", sourceElement: ref, screenRect: nil, sourceBundleID: nil)

        vm.triggerImprove()
        #expect(vm.isResultEditable == false)

        vm.update(text: "x", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        vm.triggerProofread()
        #expect(vm.isResultEditable == false)

        vm.update(text: "x", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        vm.triggerTranslate()
        #expect(vm.isResultEditable == true)

        vm.update(text: "x", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        vm.triggerShorten()
        #expect(vm.isResultEditable == true)
    }

    // MARK: - endEditing retains buffer

    @Test("endEditing does not discard editedResult")
    func endEditingRetainsBuffer() {
        let vm = ToolbarViewModel()
        vm.editedResult = "my edits"
        vm.beginEditing()
        vm.endEditing()
        #expect(vm.editedResult == "my edits")
        #expect(vm.isEditing == false)
    }
    // MARK: - Rejected hunks (per-hunk diff accept)

    private func improvedVM(original: String = "a b c d", result: String = "a B c D") -> ToolbarViewModel {
        let vm = ToolbarViewModel()
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: original, sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        vm.triggerImprove()
        vm.finishWith(result: result)
        return vm
    }

    @Test("Improve result with no rejected hunks displays the full result")
    func rejectedHunksEmptyShowsResult() {
        let vm = improvedVM()
        #expect(vm.rejectedHunks.isEmpty)
        #expect(vm.displayedResult == "a B c D")
    }

    @Test("toggleHunk reverts one hunk in displayedResult")
    func toggleHunkRevertsOne() {
        let vm = improvedVM()
        vm.toggleHunk(0)
        #expect(vm.rejectedHunks == [0])
        #expect(vm.displayedResult == "a b c D")
    }

    @Test("toggling a hunk twice restores the full result")
    func toggleHunkTwiceRestores() {
        let vm = improvedVM()
        vm.toggleHunk(1)
        vm.toggleHunk(1)
        #expect(vm.rejectedHunks.isEmpty)
        #expect(vm.displayedResult == "a B c D")
    }

    @Test("toggleHunk ignores out-of-range indices")
    func toggleHunkOutOfRange() {
        let vm = improvedVM()
        vm.toggleHunk(2)
        vm.toggleHunk(-1)
        #expect(vm.rejectedHunks.isEmpty)
        #expect(vm.displayedResult == "a B c D")
    }

    @Test("reset clears rejectedHunks")
    func resetClearsRejectedHunks() {
        let vm = improvedVM()
        vm.toggleHunk(0)
        vm.reset()
        #expect(vm.rejectedHunks.isEmpty)
    }

    @Test("update clears rejectedHunks")
    func updateClearsRejectedHunks() {
        let vm = improvedVM()
        vm.toggleHunk(0)
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "new", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        #expect(vm.rejectedHunks.isEmpty)
    }

    @Test("a second finishWith clears rejectedHunks")
    func secondFinishClearsRejectedHunks() {
        let vm = improvedVM()
        vm.toggleHunk(0)
        vm.finishWith(result: "a B c D")
        #expect(vm.rejectedHunks.isEmpty)
        #expect(vm.displayedResult == "a B c D")
    }

    @Test("translate and shorten displayedResult are unaffected by hunk state")
    func nonDiffActionsUnaffected() {
        let vm = ToolbarViewModel()
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "a b c d", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        vm.triggerTranslate()
        vm.finishWith(result: "x y")
        vm.toggleHunk(0)
        #expect(vm.rejectedHunks.isEmpty)
        #expect(vm.displayedResult == "x y")

        vm.update(text: "a b c d", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        vm.triggerShorten()
        vm.finishWith(result: "a b")
        vm.toggleHunk(0)
        #expect(vm.displayedResult == "a b")
    }
}
