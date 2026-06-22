// CustomActionTypeTests.swift
// PopGuyTests
//
// Regression tests for Phase 2 "Custom Action Types" security/correctness invariants.
//
// Covers:
//   1. SpeakSettings.resolvingCloudGate — cloud engine is forced to .system when
//      cloudAllowed is false (security gate).
//   2. Translation type-branching — triggerCustomAction on a .translation action
//      passes the action's targetLanguage, tone, and systemPrompt to handler.custom
//      unchanged; a .ai action passes its systemPrompt as-is.
//   3. Guard-before-cancel — .speech actions routed by triggerCustomAction do NOT
//      reach handler.custom, so they never cancel an in-flight AI/translation stream.
//   4. Dictionary type-branching — triggerCustomAction on a .dictionary action
//      routes through the dictionary handler with the action's own DictionaryConfig.
//
// Not covered (no injectable seam without production changes):
//   - ActionEngineHandler.custom() empty-systemPrompt→nil mapping for .translation
//     (private engine + no test-only init). Documented as a gap.
//   - In-flight stream state after a .speech guard (generation/streamTask are
//     private; observing "didn't cancel" needs the handler's internals). Documented
//     as a gap for item 3.
//
// Test framework: Swift Testing (@Test / #expect).
// Isolation: @MainActor — ToolbarViewModel is @MainActor.

import ApplicationServices
import Foundation
import Testing
@testable import PopGuy

// MARK: - SpyHandler

/// Lightweight spy conforming to ToolbarActionHandling.
/// Records every call so tests can assert which methods were invoked.
@MainActor
private final class SpyHandler: ToolbarActionHandling {

    // Capture bags
    private(set) var customCalls: [(action: CustomAction, text: String)] = []
    private(set) var dictionaryConfigCalls: [(text: String, config: DictionaryConfig, actionName: String)] = []
    private(set) var recordSpeakCalls: [(text: String, engineLabel: String, accent: String)] = []
    private(set) var improveCalled = false
    private(set) var shortenCalled = false
    private(set) var proofreadCalled = false
    private(set) var translateCalled = false
    private(set) var promptCalled = false
    private(set) var dictionaryCalled = false
    private(set) var cancelCalled = false

    func improve(text: String, viewModel: ToolbarViewModel) { improveCalled = true }
    func shorten(text: String, viewModel: ToolbarViewModel) { shortenCalled = true }
    func proofread(text: String, viewModel: ToolbarViewModel) { proofreadCalled = true }
    func translate(text: String, targetLanguage: TargetLanguage, viewModel: ToolbarViewModel) { translateCalled = true }

    func custom(action: CustomAction, text: String, viewModel: ToolbarViewModel) {
        customCalls.append((action: action, text: text))
    }

    func recordSpeak(text: String, engineLabel: String, accent: String, sourceBundleID: String?) {
        recordSpeakCalls.append((text: text, engineLabel: engineLabel, accent: accent))
    }

    func recordScriptAction(actionName: String, typeLabel: String, input: String, output: String, success: Bool, errorMessage: String?, startedAt: Date, sourceBundleID: String?) {}

    func prompt(promptText: String, text: String, viewModel: ToolbarViewModel) { promptCalled = true }
    func dictionary(text: String, targetLanguage: TargetLanguage, viewModel: ToolbarViewModel) {
        dictionaryCalled = true
    }
    func dictionary(text: String, config: DictionaryConfig, actionName: String, viewModel: ToolbarViewModel) {
        dictionaryCalled = true
        dictionaryConfigCalls.append((text: text, config: config, actionName: actionName))
    }
    func cancel() { cancelCalled = true }
}

// MARK: - 1. Cloud-gate tests

@Suite("SpeakSettings.resolvingCloudGate")
struct SpeakSettingsCloudGateTests {

    @Test("cloud engine + cloudAllowed:false → selectedEngine becomes .system")
    func cloudEngineBlockedWhenNotAllowed() {
        var settings = SpeakSettings.default
        settings.selectedEngine = .cloud(.openAITTS)
        let result = settings.resolvingCloudGate(cloudAllowed: false)
        #expect(result.selectedEngine == .system)
    }

    @Test("cloud engine + cloudAllowed:true → selectedEngine unchanged")
    func cloudEnginePassedThroughWhenAllowed() {
        var settings = SpeakSettings.default
        settings.selectedEngine = .cloud(.openAITTS)
        let result = settings.resolvingCloudGate(cloudAllowed: true)
        #expect(result.selectedEngine == .cloud(.openAITTS))
    }

    @Test("system engine + cloudAllowed:false → selectedEngine stays .system")
    func systemEngineUnchangedWhenNotAllowed() {
        var settings = SpeakSettings.default
        settings.selectedEngine = .system
        let result = settings.resolvingCloudGate(cloudAllowed: false)
        #expect(result.selectedEngine == .system)
    }

    @Test("system engine + cloudAllowed:true → selectedEngine stays .system")
    func systemEngineUnchangedWhenAllowed() {
        var settings = SpeakSettings.default
        settings.selectedEngine = .system
        let result = settings.resolvingCloudGate(cloudAllowed: true)
        #expect(result.selectedEngine == .system)
    }

    @Test("resolvingCloudGate preserves all other fields when blocking cloud")
    func cloudGatePreservesOtherFields() {
        var settings = SpeakSettings.default
        settings.selectedEngine = .cloud(.googleCloudTTS)
        settings.rate = 0.7
        settings.pitch = 1.5
        settings.dictionaryAudioEnabled = false
        settings.defaultAccent = .french
        let result = settings.resolvingCloudGate(cloudAllowed: false)
        // Only selectedEngine changes; other fields are identical.
        #expect(result.rate == 0.7)
        #expect(result.pitch == 1.5)
        #expect(result.dictionaryAudioEnabled == false)
        #expect(result.defaultAccent == .french)
    }
}

// MARK: - 2 & 3. ToolbarViewModel routing via SpyHandler

@Suite("triggerCustomAction routing")
@MainActor
struct TriggerCustomActionRoutingTests {

    // MARK: - Helpers

    private func makeVM(handler: SpyHandler) -> ToolbarViewModel {
        let vm = ToolbarViewModel()
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "some selected text", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        vm.actionHandler = handler
        return vm
    }

    private func makeAIAction(systemPrompt: String = "Summarize this.") -> CustomAction {
        CustomAction(
            title: "Summarize",
            icon: .sfSymbol("sparkles"),
            type: .ai,
            systemPrompt: systemPrompt,
            providerKind: .anthropic,
            model: "claude-sonnet-4-6",
            isEnabled: true
        )
    }

    private func makeTranslationAction(
        targetLanguage: String = "fr",
        tone: TranslateTone = .formal,
        systemPrompt: String = "Use formal vocabulary"
    ) -> CustomAction {
        CustomAction(
            title: "Translate to French",
            icon: .sfSymbol("globe"),
            type: .translation,
            systemPrompt: systemPrompt,
            providerKind: .deepL,
            model: "default",
            isEnabled: true,
            targetLanguage: targetLanguage,
            tone: tone
        )
    }

    private func makeSpeechAction() -> CustomAction {
        CustomAction(
            title: "Read Aloud",
            icon: .sfSymbol("speaker.wave.2"),
            type: .speech,
            systemPrompt: "",
            providerKind: .anthropic,
            model: "",
            isEnabled: true,
            speakSettings: .default,
            ttsConfig: .default
        )
    }

    private func makeDictionaryAction(config: DictionaryConfig) -> CustomAction {
        CustomAction(
            title: "Vietnamese Dictionary",
            icon: .sfSymbol("character.book.closed"),
            type: .dictionary,
            systemPrompt: "",
            providerKind: .anthropic,
            model: "",
            isEnabled: true,
            dictionaryConfig: config
        )
    }

    // MARK: - Translation type-branching

    @Test(".translation action forwards action with targetLanguage and tone to handler.custom")
    func translationActionForwardsToHandlerCustom() {
        let spy = SpyHandler()
        let vm = makeVM(handler: spy)

        let action = makeTranslationAction(targetLanguage: "fr", tone: .formal, systemPrompt: "Use formal vocabulary")
        vm.triggerCustomAction(action)

        // handler.custom must have been called once with the exact action.
        #expect(spy.customCalls.count == 1)
        let captured = spy.customCalls[0].action
        #expect(captured.type == .translation)
        #expect(captured.targetLanguage == "fr")
        #expect(captured.tone == .formal)
        #expect(captured.systemPrompt == "Use formal vocabulary")
    }

    @Test(".translation action with empty systemPrompt still forwards action to handler.custom")
    func translationActionEmptyPromptForwards() {
        let spy = SpyHandler()
        let vm = makeVM(handler: spy)

        // Empty systemPrompt should still reach handler.custom — the nil mapping
        // happens inside ActionEngineHandler.custom(), not in ToolbarViewModel.
        let action = makeTranslationAction(systemPrompt: "")
        vm.triggerCustomAction(action)

        #expect(spy.customCalls.count == 1)
        let captured = spy.customCalls[0].action
        #expect(captured.systemPrompt == "")
    }

    @Test(".ai action forwards action with systemPrompt to handler.custom")
    func aiActionForwardsToHandlerCustom() {
        let spy = SpyHandler()
        let vm = makeVM(handler: spy)

        let action = makeAIAction(systemPrompt: "Summarize in one sentence.")
        vm.triggerCustomAction(action)

        #expect(spy.customCalls.count == 1)
        let captured = spy.customCalls[0].action
        #expect(captured.type == .ai)
        #expect(captured.systemPrompt == "Summarize in one sentence.")
    }

    // MARK: - Guard-before-cancel (speech does NOT reach handler.custom)

    @Test(".speech action does NOT call handler.custom")
    func speechActionDoesNotCallHandlerCustom() {
        let spy = SpyHandler()
        let vm = makeVM(handler: spy)
        // speakPhase defaults to .idle, so the toggle-to-stop branch is skipped.

        let action = makeSpeechAction()
        vm.triggerCustomAction(action)

        // handler.custom must never be called for speech — speech routes through
        // SpeakCoordinator (nil here, so speak is a no-op) not ActionEngine.
        #expect(spy.customCalls.isEmpty)
    }

    @Test(".speech action calls recordSpeak instead of handler.custom")
    func speechActionCallsRecordSpeak() {
        let spy = SpyHandler()
        let vm = makeVM(handler: spy)

        let action = makeSpeechAction()
        vm.triggerCustomAction(action)

        // recordSpeak is the logging path, not the AI dispatch path.
        #expect(spy.recordSpeakCalls.count == 1)
        #expect(spy.customCalls.isEmpty)
    }

    @Test(".translation action does NOT call recordSpeak")
    func translationActionDoesNotCallRecordSpeak() {
        let spy = SpyHandler()
        let vm = makeVM(handler: spy)

        vm.triggerCustomAction(makeTranslationAction())

        #expect(spy.recordSpeakCalls.isEmpty)
        #expect(spy.customCalls.count == 1)
    }

    // MARK: - Dictionary type-branching

    @Test(".dictionary action routes to handler.dictionary with action config")
    func dictionaryActionForwardsConfigToHandlerDictionary() {
        var speech = SpeakSettings.default
        speech.defaultAccent = .french
        speech.dictionaryAudioEnabled = false
        let config = DictionaryConfig(
            provider: .minhqnd,
            definitionLanguage: "vi",
            isEnabled: true,
            speakSettings: speech,
            accent: .french
        )
        let action = makeDictionaryAction(config: config)
        let spy = SpyHandler()
        let vm = makeVM(handler: spy)

        vm.triggerCustomAction(action)

        #expect(spy.customCalls.isEmpty)
        #expect(spy.recordSpeakCalls.isEmpty)
        #expect(spy.dictionaryConfigCalls.count == 1)
        #expect(spy.dictionaryConfigCalls[0].text == "some selected text")
        #expect(spy.dictionaryConfigCalls[0].config == config)
        #expect(spy.dictionaryConfigCalls[0].actionName == "Vietnamese Dictionary")
        #expect(vm.isDictionaryAction == true)
        #expect(vm.activeCustomActionID == action.id)
        #expect(vm.dictionarySpeakSettings == config.speakSettings)
        #expect(vm.dictionaryAccent == config.accent)
    }
}
