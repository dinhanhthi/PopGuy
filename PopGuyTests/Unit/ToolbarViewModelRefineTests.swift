// ToolbarViewModelRefineTests.swift
// PopGuyTests
//
// Tests for the Regenerate / Refine state and actions on ToolbarViewModel:
// which results can be regenerated or refined, what regenerate() re-dispatches,
// what runRefine() hands to the action handler, and that update()/reset()
// clear the refine state.

import ApplicationServices
import Foundation
import Testing
@testable import PopGuy

// MARK: - Recording spy

@MainActor
private final class RecordingActionHandler: ToolbarActionHandling {
    @MainActor enum Call: Equatable {
        case improve(String)
        case shorten(String)
        case proofread(String)
        case translate(String, TargetLanguage)
        case custom(UUID, String)
        case prompt(String, String)
        case refine(RefineTarget, text: String, previous: String, instruction: String)
    }

    private(set) var calls: [Call] = []

    func improve(text: String, viewModel: ToolbarViewModel) { calls.append(.improve(text)) }
    func shorten(text: String, viewModel: ToolbarViewModel) { calls.append(.shorten(text)) }
    func proofread(text: String, viewModel: ToolbarViewModel) { calls.append(.proofread(text)) }
    func translate(text: String, targetLanguage: TargetLanguage, viewModel: ToolbarViewModel) {
        calls.append(.translate(text, targetLanguage))
    }
    func custom(action: CustomAction, text: String, viewModel: ToolbarViewModel) {
        calls.append(.custom(action.id, text))
    }
    func dictionary(text: String, targetLanguage: TargetLanguage, viewModel: ToolbarViewModel) {}
    func dictionary(text: String, config: DictionaryConfig, actionName: String, viewModel: ToolbarViewModel) {}
    func recordSpeak(text: String, engineLabel: String, accent: String, sourceBundleID: String?) {}
    func recordScriptAction(actionName: String, typeLabel: String, input: String, output: String, success: Bool, errorMessage: String?, startedAt: Date, sourceBundleID: String?) {}
    func prompt(promptText: String, text: String, viewModel: ToolbarViewModel) {
        calls.append(.prompt(promptText, text))
    }
    func refine(target: RefineTarget, text: String, previousResult: String, instruction: String, viewModel: ToolbarViewModel) {
        calls.append(.refine(target, text: text, previous: previousResult, instruction: instruction))
    }
    func cancel() {}
}

@MainActor
private final class StubScriptRunner: ScriptActionRunning {
    func run(_ action: CustomAction, text: String, fullText: String) async throws -> ScriptActionResult {
        ScriptActionResult(text: "script output")
    }
}

// MARK: - Helpers

@MainActor
private func makeVM(text: String = "a b c d") -> (ToolbarViewModel, RecordingActionHandler) {
    let vm = ToolbarViewModel()
    let handler = RecordingActionHandler()
    vm.actionHandler = handler
    let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
    vm.update(text: text, sourceElement: ref, screenRect: nil, sourceBundleID: nil)
    return (vm, handler)
}

// MARK: - Regenerate

@Suite("ToolbarViewModel regenerate")
@MainActor
struct ToolbarViewModelRegenerateTests {

    @Test("regenerate after Improve calls improve again with the original text")
    func regenerateImprove() {
        let (vm, handler) = makeVM()
        vm.triggerImprove()
        vm.finishWith(result: "a B c D")
        #expect(vm.canRegenerate)

        vm.regenerate()

        #expect(handler.calls == [.improve("a b c d"), .improve("a b c d")])
        #expect(vm.actionState == .running(progress: ""))
    }

    @Test("regenerate after Prompt reuses the last prompt text")
    func regeneratePrompt() {
        let (vm, handler) = makeVM()
        vm.promptDraft = "  make it rhyme  "
        vm.runPrompt()
        #expect(vm.lastPromptText == "make it rhyme")
        #expect(vm.promptDraft.isEmpty)
        vm.finishWith(result: "rhymed")
        #expect(vm.canRegenerate)

        vm.regenerate()

        #expect(handler.calls == [
            .prompt("make it rhyme", "a b c d"),
            .prompt("make it rhyme", "a b c d"),
        ])
    }

    @Test("regenerate after Translate keeps the current target language")
    func regenerateTranslate() {
        let (vm, handler) = makeVM()
        vm.targetLanguage = .french
        vm.triggerTranslate()
        vm.finishWith(result: "un deux")

        vm.regenerate()

        #expect(handler.calls.last == .translate("a b c d", .french))
    }

    @Test("regenerate after a custom AI action finds the action by id")
    func regenerateCustomAI() {
        let (vm, handler) = makeVM()
        let action = CustomAction(title: "Pirate", type: .ai, systemPrompt: "Talk like a pirate")
        vm.customActions = [action]
        vm.triggerCustomAction(action)
        vm.finishWith(result: "arr")
        #expect(vm.canRegenerate)

        vm.regenerate()

        #expect(handler.calls == [.custom(action.id, "a b c d"), .custom(action.id, "a b c d")])
    }

    @Test("scriptable showResult results cannot be regenerated")
    func scriptableCannotRegenerate() async {
        let (vm, handler) = makeVM()
        defer { withExtendedLifetime(handler) {} }
        let runner = StubScriptRunner()
        vm.scriptActionEngine = runner
        let action = CustomAction(
            title: "Echo", type: .shellScript, systemPrompt: "",
            scriptSource: "echo hi", afterRun: .showResult
        )
        vm.customActions = [action]
        vm.triggerCustomAction(action)
        await vm.scriptActionTask?.value

        #expect(vm.actionState == .result("script output"))
        #expect(!vm.canRegenerate)
        #expect(!vm.canRefine)
    }

    @Test("dictionary results cannot be regenerated")
    func dictionaryCannotRegenerate() {
        let (vm, handler) = makeVM(text: "word")
        defer { withExtendedLifetime(handler) {} }
        vm.triggerDictionary()
        vm.finishWithDictionaryNotFound()

        #expect(!vm.canRegenerate)
        #expect(!vm.canRefine)
    }

    @Test("no result means nothing to regenerate")
    func runningCannotRegenerate() {
        let (vm, handler) = makeVM()
        defer { withExtendedLifetime(handler) {} }
        vm.triggerImprove()
        #expect(!vm.canRegenerate)
    }
}

// MARK: - canRefine

@Suite("ToolbarViewModel canRefine")
@MainActor
struct ToolbarViewModelCanRefineTests {

    @Test("built-in Translate on a non-model provider can regenerate but not refine")
    func translateWithoutModel() {
        let (vm, handler) = makeVM()
        defer { withExtendedLifetime(handler) {} }
        vm.translateUsesModel = false
        vm.triggerTranslate()
        vm.finishWith(result: "un deux")

        #expect(vm.canRegenerate)
        #expect(!vm.canRefine)
        vm.openRefineInput()
        #expect(!vm.isRefineInputActive)
    }

    @Test("custom translation action on Google Translate can regenerate but not refine")
    func customGoogleTranslate() {
        let (vm, handler) = makeVM()
        defer { withExtendedLifetime(handler) {} }
        let action = CustomAction(
            title: "To German", type: .translation, systemPrompt: "",
            providerKind: .googleTranslate, model: "", targetLanguage: "de"
        )
        vm.customActions = [action]
        vm.triggerCustomAction(action)
        vm.finishWith(result: "eins")

        #expect(vm.canRegenerate)
        #expect(!vm.canRefine)
    }

    @Test("Improve result can be refined")
    func improveCanRefine() {
        let (vm, handler) = makeVM()
        defer { withExtendedLifetime(handler) {} }
        vm.triggerImprove()
        vm.finishWith(result: "a B c D")
        #expect(vm.canRefine)
        vm.openRefineInput()
        #expect(vm.isRefineInputActive)
    }
}

// MARK: - runRefine

@Suite("ToolbarViewModel runRefine")
@MainActor
struct ToolbarViewModelRunRefineTests {

    @Test("refining Shorten passes the edited buffer and trimmed instruction, then clears the field")
    func refineShorten() {
        let (vm, handler) = makeVM()
        vm.triggerShorten()
        vm.finishWith(result: "a b")
        vm.editedResult = "a b (edited)"
        vm.openRefineInput()
        vm.refineDraft = "  more formal \n"

        vm.runRefine()

        #expect(handler.calls.last == .refine(.shorten, text: "a b c d", previous: "a b (edited)", instruction: "more formal"))
        #expect(vm.actionState == .running(progress: ""))
        #expect(vm.activeActionKind == .shorten)
        #expect(vm.refineDraft.isEmpty)
        #expect(!vm.isRefineInputActive)
    }

    @Test("refining Improve passes the merged text after rejecting a hunk")
    func refineImproveMerged() {
        let (vm, handler) = makeVM()
        vm.triggerImprove()
        vm.finishWith(result: "a B c D")
        vm.toggleHunk(0)
        vm.refineDraft = "shorter"

        vm.runRefine()

        #expect(handler.calls.last == .refine(.improve, text: "a b c d", previous: "a b c D", instruction: "shorter"))
    }

    @Test("refining Translate and Prompt carry the language and prompt text")
    func refineTranslateAndPrompt() {
        let (vm, handler) = makeVM()
        vm.targetLanguage = .german
        vm.triggerTranslate()
        vm.finishWith(result: "eins")
        vm.refineDraft = "casual"
        vm.runRefine()
        #expect(handler.calls.last == .refine(.translate(.german), text: "a b c d", previous: "eins", instruction: "casual"))

        vm.promptDraft = "summarize"
        vm.runPrompt()
        vm.finishWith(result: "sum")
        vm.refineDraft = "one line"
        vm.runRefine()
        #expect(handler.calls.last == .refine(.prompt("summarize"), text: "a b c d", previous: "sum", instruction: "one line"))
    }

    @Test("refining a custom AI action carries the action and keeps its id active")
    func refineCustom() {
        let (vm, handler) = makeVM()
        let action = CustomAction(title: "Pirate", type: .ai, systemPrompt: "Talk like a pirate")
        vm.customActions = [action]
        vm.triggerCustomAction(action)
        vm.finishWith(result: "arr")
        vm.refineDraft = "louder"

        vm.runRefine()

        #expect(handler.calls.last == .refine(.custom(action), text: "a b c d", previous: "arr", instruction: "louder"))
        #expect(vm.activeCustomActionID == action.id)
    }

    @Test("chained refine keeps the original text and the next result diffs against it")
    func chainedRefine() {
        let (vm, handler) = makeVM()
        vm.triggerImprove()
        vm.finishWith(result: "a B c D")
        vm.toggleHunk(0)
        vm.refineDraft = "first"
        vm.runRefine()
        vm.finishWith(result: "a b C D")

        #expect(vm.capturedText == "a b c d")
        #expect(vm.rejectedHunks.isEmpty)
        #expect(vm.diffSegments == DiffAlgorithm.diff(original: "a b c d", improved: "a b C D"))

        vm.refineDraft = "second"
        vm.runRefine()
        #expect(handler.calls.last == .refine(.improve, text: "a b c d", previous: "a b C D", instruction: "second"))
    }

    @Test("empty or whitespace draft is a no-op")
    func emptyDraftNoOp() {
        let (vm, handler) = makeVM()
        vm.triggerImprove()
        vm.finishWith(result: "a B c D")
        vm.openRefineInput()
        vm.refineDraft = "   \n"

        vm.runRefine()

        #expect(handler.calls == [.improve("a b c d")])
        #expect(vm.actionState == .result("a B c D"))
        #expect(vm.isRefineInputActive)
    }

    @Test("cancelRefineInput closes the field and clears the draft")
    func cancelRefine() {
        let (vm, handler) = makeVM()
        defer { withExtendedLifetime(handler) {} }
        vm.triggerImprove()
        vm.finishWith(result: "a B c D")
        vm.openRefineInput()
        vm.refineDraft = "x"

        vm.cancelRefineInput()

        #expect(!vm.isRefineInputActive)
        #expect(vm.refineDraft.isEmpty)
    }
}

// MARK: - Clearing

@Suite("ToolbarViewModel refine state clearing")
@MainActor
struct ToolbarViewModelRefineClearingTests {

    private func vmWithRefineState() -> (ToolbarViewModel, RecordingActionHandler) {
        let (vm, handler) = makeVM()
        vm.promptDraft = "summarize"
        vm.runPrompt()
        vm.finishWith(result: "sum")
        vm.openRefineInput()
        vm.refineDraft = "shorter"
        return (vm, handler)
    }

    @Test("update clears refine state and the last prompt")
    func updateClears() {
        let (vm, handler) = vmWithRefineState()
        defer { withExtendedLifetime(handler) {} }
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "new", sourceElement: ref, screenRect: nil, sourceBundleID: nil)

        #expect(!vm.isRefineInputActive)
        #expect(vm.refineDraft.isEmpty)
        #expect(vm.lastPromptText == nil)
    }

    @Test("reset clears refine state and the last prompt")
    func resetClears() {
        let (vm, handler) = vmWithRefineState()
        defer { withExtendedLifetime(handler) {} }
        vm.reset()

        #expect(!vm.isRefineInputActive)
        #expect(vm.refineDraft.isEmpty)
        #expect(vm.lastPromptText == nil)
    }
}
