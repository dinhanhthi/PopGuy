// ToolbarViewModelTests.swift
// PopGuyTests
//
// Unit tests for ToolbarViewModel.compactActions threshold logic.
// Verifies that the flag is false below 4 inline controls (principal actions
// plus the burger button when present) and true at 4+.
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

    // MARK: - compactActions threshold

    @Test("compactActions is false with no principal or overflow actions")
    func zeroActions() {
        let vm = ToolbarViewModel()
        vm.orderedActions = []
        vm.overflowActions = []
        #expect(vm.compactActions == false)
    }

    @Test("compactActions is false with 1 principal action")
    func oneAction() {
        let vm = ToolbarViewModel()
        vm.orderedActions = [.builtin(.improve)]
        #expect(vm.compactActions == false)
    }

    @Test("compactActions is false with 2 principal actions")
    func twoActions() {
        let vm = ToolbarViewModel()
        vm.orderedActions = [.builtin(.improve), .builtin(.shorten)]
        #expect(vm.compactActions == false)
    }

    @Test("compactActions is false with exactly 3 principal actions")
    func threePrincipal() {
        let vm = ToolbarViewModel()
        vm.orderedActions = [.builtin(.improve), .builtin(.shorten), .builtin(.proofread)]
        #expect(vm.compactActions == false)
    }

    @Test("compactActions is true with 4 principal actions")
    func fourPrincipal() {
        let vm = ToolbarViewModel()
        vm.orderedActions = [
            .builtin(.improve), .builtin(.shorten), .builtin(.proofread), .builtin(.translate),
        ]
        #expect(vm.compactActions == true)
    }

    @Test("compactActions is true with 3 principal actions and a burger menu")
    func threePrincipalPlusBurger() {
        let vm = ToolbarViewModel()
        vm.orderedActions = [.builtin(.improve), .builtin(.shorten), .builtin(.proofread)]
        vm.overflowActions = [.builtin(.translate)]
        #expect(vm.compactActions == true)
    }

    @Test("compactActions is false with 2 principal actions and a burger menu (3 inline)")
    func twoPrincipalPlusBurger() {
        let vm = ToolbarViewModel()
        vm.orderedActions = [.builtin(.improve), .builtin(.shorten)]
        vm.overflowActions = [.builtin(.proofread), .builtin(.translate)]
        #expect(vm.compactActions == false)
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
}
