// ToolbarViewModelTests.swift
// PopGuyTests
//
// Unit tests for ToolbarViewModel.compactActions threshold logic.
// Verifies that the flag is false below 4 enabled action buttons and
// true at 4+, and that utility buttons (Ignore / Settings) never count.
//
// Also covers edit-buffer invariants introduced in the editable-toolbar-result phase:
// finishWith seeds editedResult, reset/update clear it, beginEditing/endEditing toggle isEditing.

import ApplicationServices
import Testing
@testable import PopGuy

@Suite("ToolbarViewModel")
@MainActor
struct ToolbarViewModelTests {

    // MARK: - compactActions threshold

    @Test("compactActions is false with 0 enabled actions")
    func zeroActions() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = false
        vm.shortenEnabled = false
        vm.proofreadEnabled = false
        vm.translateEnabled = false
        vm.speakEnabled = false
        #expect(vm.compactActions == false)
    }

    @Test("compactActions is false with 1 enabled action")
    func oneAction() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = true
        vm.shortenEnabled = false
        vm.proofreadEnabled = false
        vm.translateEnabled = false
        vm.speakEnabled = false
        #expect(vm.compactActions == false)
    }

    @Test("compactActions is false with 2 enabled actions")
    func twoActions() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = true
        vm.shortenEnabled = true
        vm.proofreadEnabled = false
        vm.translateEnabled = false
        vm.speakEnabled = false
        #expect(vm.compactActions == false)
    }

    @Test("compactActions is false with exactly 3 enabled built-in actions")
    func threeBuiltIns() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = true
        vm.shortenEnabled = true
        vm.proofreadEnabled = true
        vm.translateEnabled = false
        vm.speakEnabled = false
        #expect(vm.compactActions == false)
    }

    @Test("compactActions is true with all 4 built-in actions enabled")
    func allFourBuiltIns() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = true
        vm.shortenEnabled = true
        vm.proofreadEnabled = true
        vm.translateEnabled = true
        vm.speakEnabled = false
        #expect(vm.compactActions == true)
    }

    @Test("compactActions is false when 2 built-ins + 1 custom action (total 3)")
    func twoBuiltInsPlusOneCustom() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = true
        vm.shortenEnabled = true
        vm.proofreadEnabled = false
        vm.translateEnabled = false
        vm.speakEnabled = false
        let custom = CustomAction(
            title: "Summarize",
            icon: .sfSymbol("sparkles"),
            systemPrompt: "Summarize this.",
            providerKind: .anthropic,
            model: "claude-sonnet-4-6",
            isEnabled: true
        )
        vm.customActions = [custom]
        #expect(vm.compactActions == false)
    }

    @Test("compactActions is true when 2 built-ins + 2 custom actions (total 4)")
    func twoBuiltInsPlusTwoCustom() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = true
        vm.shortenEnabled = true
        vm.proofreadEnabled = false
        vm.translateEnabled = false
        vm.speakEnabled = false
        vm.customActions = (1...2).map { i in
            CustomAction(
                title: "Custom \(i)",
                icon: .sfSymbol("sparkles"),
                systemPrompt: "Do \(i).",
                providerKind: .anthropic,
                model: "claude-sonnet-4-6",
                isEnabled: true
            )
        }
        #expect(vm.compactActions == true)
    }

    @Test("compactActions is false when 0 built-ins + 3 custom actions")
    func threeCustomOnly() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = false
        vm.shortenEnabled = false
        vm.proofreadEnabled = false
        vm.translateEnabled = false
        vm.speakEnabled = false
        vm.customActions = (1...3).map { i in
            CustomAction(
                title: "Custom \(i)",
                icon: .sfSymbol("sparkles"),
                systemPrompt: "Do \(i).",
                providerKind: .anthropic,
                model: "claude-sonnet-4-6",
                isEnabled: true
            )
        }
        #expect(vm.compactActions == false)
    }

    @Test("compactActions is true when 0 built-ins + 4 custom actions")
    func fourCustomOnly() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = false
        vm.shortenEnabled = false
        vm.proofreadEnabled = false
        vm.translateEnabled = false
        vm.speakEnabled = false
        vm.customActions = (1...4).map { i in
            CustomAction(
                title: "Custom \(i)",
                icon: .sfSymbol("sparkles"),
                systemPrompt: "Do \(i).",
                providerKind: .anthropic,
                model: "claude-sonnet-4-6",
                isEnabled: true
            )
        }
        #expect(vm.compactActions == true)
    }

    @Test("compactActions is false when 1 built-in + 1 custom action (total 2)")
    func oneBuiltInPlusOneCustom() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = true
        vm.shortenEnabled = false
        vm.proofreadEnabled = false
        vm.translateEnabled = false
        vm.speakEnabled = false
        let custom = CustomAction(
            title: "Summarize",
            icon: .sfSymbol("sparkles"),
            systemPrompt: "Summarize this.",
            providerKind: .anthropic,
            model: "claude-sonnet-4-6",
            isEnabled: true
        )
        vm.customActions = [custom]
        #expect(vm.compactActions == false)
    }

    @Test("compactActions is false when 0 built-ins + 2 custom actions (boundary symmetry)")
    func zeroBuiltInsTwoCustom() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = false
        vm.shortenEnabled = false
        vm.proofreadEnabled = false
        vm.translateEnabled = false
        vm.speakEnabled = false
        vm.customActions = (1...2).map { i in
            CustomAction(
                title: "Custom \(i)",
                icon: .sfSymbol("sparkles"),
                systemPrompt: "Do \(i).",
                providerKind: .anthropic,
                model: "claude-sonnet-4-6",
                isEnabled: true
            )
        }
        #expect(vm.compactActions == false)
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
