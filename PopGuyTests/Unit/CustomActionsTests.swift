// CustomActionsTests.swift
// PopGuyTests
//
// TDD: CustomAction CRUD / reorder round-trips + Codable fidelity.
// All tests run against an injected UserDefaults(suiteName:) so they never
// touch real app preferences.
//
// Also covers ActionIdentifier Codable round-trips (both .builtin and .custom).
//
// Test framework: Swift Testing (import Testing, @Test).

import Foundation
import Testing
@testable import PopGuy

// MARK: - CustomActionsTests

@Suite("CustomActions")
@MainActor
struct CustomActionsTests {

    // MARK: - Helpers

    private func makeSuite() -> (UserDefaults, String) {
        let name = "com.popguy.test.customactions.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func removeSuite(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    private func makeAction(title: String = "Test") -> CustomAction {
        CustomAction(
            title: title,
            icon: .sfSymbol("sparkles"),
            systemPrompt: "Do \(title)",
            providerKind: .anthropic,
            model: "claude-sonnet-4-6",
            isEnabled: true
        )
    }

    // MARK: - Default state

    @Test("custom actions default to empty list")
    func defaultCustomActionsEmpty() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        #expect(store.customActions.isEmpty)
    }

    // MARK: - Add

    @Test("addCustomAction appends to the list")
    func addCustomAction() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        let action = makeAction(title: "Summarise")
        store.addCustomAction(action)
        #expect(store.customActions.count == 1)
        #expect(store.customActions[0].title == "Summarise")
    }

    @Test("addCustomAction persists across store reloads")
    func addCustomActionPersists() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let action = makeAction(title: "Summarise")
        let store1 = SettingsStore(defaults: suite)
        store1.addCustomAction(action)

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.customActions.count == 1)
        #expect(store2.customActions[0].id == action.id)
        #expect(store2.customActions[0].title == "Summarise")
    }

    @Test("adding two actions preserves insertion order")
    func addTwoActionsOrder() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        let a = makeAction(title: "A")
        let b = makeAction(title: "B")
        store.addCustomAction(a)
        store.addCustomAction(b)
        #expect(store.customActions[0].title == "A")
        #expect(store.customActions[1].title == "B")
    }

    // MARK: - Update

    @Test("updateCustomAction replaces the matching entry by id")
    func updateCustomAction() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        var action = makeAction(title: "Original")
        store.addCustomAction(action)

        action.title = "Updated"
        store.updateCustomAction(action)

        #expect(store.customActions.count == 1)
        #expect(store.customActions[0].title == "Updated")
    }

    @Test("updateCustomAction is a no-op for unknown id")
    func updateCustomActionUnknown() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        let action = makeAction(title: "Real")
        store.addCustomAction(action)

        let ghost = makeAction(title: "Ghost") // different UUID
        store.updateCustomAction(ghost)

        #expect(store.customActions.count == 1)
        #expect(store.customActions[0].title == "Real")
    }

    @Test("updated action persists across store reloads")
    func updateCustomActionPersists() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        var action = makeAction(title: "Before")
        let store1 = SettingsStore(defaults: suite)
        store1.addCustomAction(action)

        action.title = "After"
        store1.updateCustomAction(action)

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.customActions[0].title == "After")
    }

    // MARK: - Delete

    @Test("deleteCustomAction removes the entry by id")
    func deleteCustomAction() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        let a = makeAction(title: "A")
        let b = makeAction(title: "B")
        store.addCustomAction(a)
        store.addCustomAction(b)
        store.deleteCustomAction(id: a.id)
        #expect(store.customActions.count == 1)
        #expect(store.customActions[0].title == "B")
    }

    @Test("deleteCustomAction is a no-op for unknown id")
    func deleteCustomActionUnknown() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        let a = makeAction(title: "A")
        store.addCustomAction(a)
        store.deleteCustomAction(id: UUID())
        #expect(store.customActions.count == 1)
    }

    @Test("deleteCustomAction also removes associated shortcut binding")
    func deleteCustomActionRemovesShortcut() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        store.shortcutBindings = [] // start from a clean slate (ignore seeded built-in defaults)
        let action = makeAction(title: "A")
        store.addCustomAction(action)
        let shortcut = KeyboardShortcut(keyCode: 0, modifierFlags: 1 << 20) // ⌘A
        store.setShortcut(shortcut, for: .custom(action.id))
        #expect(store.shortcutBindings.count == 1)

        store.deleteCustomAction(id: action.id)
        #expect(store.customActions.isEmpty)
        #expect(store.shortcutBindings.isEmpty)
    }

    @Test("delete persists across store reloads")
    func deleteCustomActionPersists() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let a = makeAction(title: "A")
        let b = makeAction(title: "B")
        let store1 = SettingsStore(defaults: suite)
        store1.addCustomAction(a)
        store1.addCustomAction(b)
        store1.deleteCustomAction(id: a.id)

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.customActions.count == 1)
        #expect(store2.customActions[0].id == b.id)
    }

    // MARK: - Reorder

    @Test("moveCustomActions reorders in-memory list")
    func moveCustomActions() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        let a = makeAction(title: "A")
        let b = makeAction(title: "B")
        let c = makeAction(title: "C")
        store.addCustomAction(a)
        store.addCustomAction(b)
        store.addCustomAction(c)

        // Move A (index 0) to after C → result: B, C, A
        store.moveCustomActions(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.customActions.map(\.title) == ["B", "C", "A"])
    }

    @Test("reorder persists across store reloads")
    func moveCustomActionsPersists() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let a = makeAction(title: "A")
        let b = makeAction(title: "B")
        let store1 = SettingsStore(defaults: suite)
        store1.addCustomAction(a)
        store1.addCustomAction(b)
        store1.moveCustomActions(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.customActions.map(\.title) == ["B", "A"])
    }

    // MARK: - CRUD sequence

    @Test("add 2, reorder, delete 1 — correct final order")
    func crudSequence() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let a = makeAction(title: "A")
        let b = makeAction(title: "B")
        let store1 = SettingsStore(defaults: suite)
        store1.addCustomAction(a)
        store1.addCustomAction(b)
        store1.moveCustomActions(fromOffsets: IndexSet(integer: 0), toOffset: 2) // B, A
        store1.deleteCustomAction(id: b.id)                                       // A

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.customActions.count == 1)
        #expect(store2.customActions[0].id == a.id)
    }

    // MARK: - Codable round-trip

    @Test("CustomAction Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = CustomAction(
            id: UUID(),
            title: "Round-trip test",
            icon: .sfSymbol("checkmark"),
            systemPrompt: "My custom prompt",
            providerKind: .openAI,
            model: "gpt-4o",
            isEnabled: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CustomAction.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - CustomActionType + migration

    @Test("legacy AI blob (no type key) decodes as .ai with fields intact")
    func legacyAIBlobDecodesAsAI() throws {
        let original = CustomAction(
            id: UUID(),
            title: "Legacy",
            icon: .sfSymbol("wand.and.stars"),
            systemPrompt: "Improve this text",
            providerKind: .openAI,
            model: "gpt-4o",
            isEnabled: true
        )
        // Encode then strip the `type`, `targetLanguage`, `tone`, `speakSettings`,
        // `ttsConfig` keys — simulating a blob written by an older build.
        var dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)
        ) as! [String: Any]
        dict.removeValue(forKey: "type")
        dict.removeValue(forKey: "targetLanguage")
        dict.removeValue(forKey: "tone")
        dict.removeValue(forKey: "speakSettings")
        dict.removeValue(forKey: "ttsConfig")
        let legacyData = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(CustomAction.self, from: legacyData)
        #expect(decoded.type == .ai)
        #expect(decoded.id == original.id)
        #expect(decoded.title == "Legacy")
        #expect(decoded.systemPrompt == "Improve this text")
        #expect(decoded.providerKind == .openAI)
        #expect(decoded.model == "gpt-4o")
        // Migration defaults must materialise for absent keys.
        #expect(decoded.targetLanguage == "en")
        #expect(decoded.tone == .neutral)
        #expect(decoded.speakSettings == .default)
        #expect(decoded.ttsConfig == .default)
        #expect(decoded.dictionaryConfig == .default)
    }

    @Test("translation action round-trip preserves targetLanguage and tone")
    func translationActionRoundTrip() throws {
        let original = CustomAction(
            id: UUID(),
            title: "Translate to French",
            icon: .sfSymbol("globe"),
            type: .translation,
            systemPrompt: "Use formal vocabulary",
            providerKind: .deepL,
            model: "default",
            isEnabled: true,
            targetLanguage: "fr",
            tone: .formal
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CustomAction.self, from: data)
        #expect(decoded.type == .translation)
        #expect(decoded.targetLanguage == "fr")
        #expect(decoded.tone == .formal)
        #expect(decoded.systemPrompt == "Use formal vocabulary")
        #expect(decoded == original)
    }

    @Test("speech action round-trip preserves speakSettings and ttsConfig")
    func speechActionRoundTrip() throws {
        let customConfig = TTSProviderConfig(
            voiceOverrides: ["en-US": "nova"],
            defaultVoice: "alloy",
            model: "tts-1-hd"
        )
        let original = CustomAction(
            id: UUID(),
            title: "Read Aloud",
            icon: .sfSymbol("speaker.wave.2"),
            type: .speech,
            systemPrompt: "",
            providerKind: .anthropic,   // ignored at dispatch for .speech
            model: "",
            isEnabled: true,
            speakSettings: .default,
            ttsConfig: customConfig
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CustomAction.self, from: data)
        #expect(decoded.type == .speech)
        #expect(decoded.speakSettings == .default)
        #expect(decoded.ttsConfig == customConfig)
        #expect(decoded.ttsConfig.defaultVoice == "alloy")
        #expect(decoded.ttsConfig.model == "tts-1-hd")
        #expect(decoded == original)
    }

    @Test("dictionary action round-trip preserves dictionaryConfig")
    func dictionaryActionRoundTrip() throws {
        var speech = SpeakSettings.default
        speech.defaultAccent = .french
        speech.dictionaryAudioEnabled = false

        let dictionary = DictionaryConfig(
            provider: .minhqnd,
            definitionLanguage: "vi",
            isEnabled: true,
            speakSettings: speech,
            accent: .french
        )
        let original = CustomAction(
            id: UUID(),
            title: "Vietnamese Dictionary",
            icon: .sfSymbol("character.book.closed"),
            type: .dictionary,
            systemPrompt: "",
            providerKind: .anthropic,
            model: "",
            isEnabled: true,
            dictionaryConfig: dictionary
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CustomAction.self, from: data)
        #expect(decoded.type == .dictionary)
        #expect(decoded.dictionaryConfig == dictionary)
        #expect(decoded == original)
    }

    // MARK: - allowedProviders

    @Test("allowedProviders(.ai) matches ActionKind.improve.allowedProviders")
    func allowedProvidersAIDelegates() {
        #expect(CustomAction.allowedProviders(for: .ai) == ActionKind.improve.allowedProviders)
    }

    @Test("allowedProviders(.translation) matches ActionKind.translate.allowedProviders")
    func allowedProvidersTranslationDelegates() {
        #expect(CustomAction.allowedProviders(for: .translation) == ActionKind.translate.allowedProviders)
    }

    @Test("allowedProviders(.speech) is empty")
    func allowedProvidersSpeechEmpty() {
        #expect(CustomAction.allowedProviders(for: .speech).isEmpty)
    }

    @Test("allowedProviders(.dictionary) is empty")
    func allowedProvidersDictionaryEmpty() {
        #expect(CustomAction.allowedProviders(for: .dictionary).isEmpty)
    }

    // MARK: - ActionIdentifier Codable

    @Test("ActionIdentifier.builtin Codable round-trip")
    func actionIdentifierBuiltinRoundTrip() throws {
        let id = ActionIdentifier.builtin(.improve)
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ActionIdentifier.self, from: data)
        #expect(decoded == id)
    }

    @Test("ActionIdentifier.custom Codable round-trip")
    func actionIdentifierCustomRoundTrip() throws {
        let uuid = UUID()
        let id = ActionIdentifier.custom(uuid)
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ActionIdentifier.self, from: data)
        #expect(decoded == id)
    }

    @Test("ActionIdentifier.speak Codable round-trip")
    func actionIdentifierSpeakRoundTrip() throws {
        let id = ActionIdentifier.speak
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ActionIdentifier.self, from: data)
        #expect(decoded == id)
    }

    @Test("ActionIdentifier array Codable round-trip")
    func actionIdentifierArrayRoundTrip() throws {
        let ids: [ActionIdentifier] = [
            .builtin(.improve),
            .builtin(.translate),
            .custom(UUID()),
            .speak,
        ]
        let data = try JSONEncoder().encode(ids)
        let decoded = try JSONDecoder().decode([ActionIdentifier].self, from: data)
        #expect(decoded == ids)
    }

    // MARK: - addCustomAction toolbar-clamp return value

    @Test("addCustomAction returns false when under the toolbar-active cap")
    func addCustomActionUnderCapReturnsFalse() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        // Fresh store: improve+shorten+proofread+translate+speak = 5 enabled (prompt+dictionary off by default).
        // Adding an enabled action (count goes 5→6, cap is 7) must return false.
        let action = makeAction(title: "Cap Test")
        let clamped = store.addCustomAction(action)
        #expect(!clamped)
        #expect(store.customActions.count == 1)
    }

    @Test("addCustomAction returns true (clamp) when adding past the toolbar-active cap")
    func addCustomActionAtCapReturnsTrue() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        // Fill to exactly maxToolbarActions by adding enabled actions.
        // Default count is 5 (improve+shorten+proofread+translate+speak), cap is 7.
        // Add enabled actions until we are one below the cap, then verify the
        // action that would exceed it gets clamped.
        while store.enabledToolbarActionCount < SettingsStore.maxToolbarActions {
            let filler = makeAction(title: "Filler \(store.enabledToolbarActionCount)")
            _ = store.addCustomAction(filler)
        }
        // Now at cap — adding another enabled action must be clamped.
        let overflow = makeAction(title: "Overflow")
        let clamped = store.addCustomAction(overflow)
        #expect(clamped)
        // The action is still appended, but with isEnabled = false.
        #expect(store.customActions.last?.title == "Overflow")
        #expect(store.customActions.last?.isEnabled == false)
    }

    // MARK: - isSaveable

    @Test("isSaveable: AI with empty title → false")
    func isSaveableAIEmptyTitle() {
        let action = CustomAction(title: "", type: .ai, systemPrompt: "Do something")
        #expect(!action.isSaveable)
    }

    @Test("isSaveable: AI with title but empty systemPrompt → false")
    func isSaveableAIEmptySystemPrompt() {
        let action = CustomAction(title: "Summarise", type: .ai, systemPrompt: "")
        #expect(!action.isSaveable)
    }

    @Test("isSaveable: AI with title and systemPrompt → true")
    func isSaveableAIBothFilled() {
        let action = CustomAction(title: "Summarise", type: .ai, systemPrompt: "Do something")
        #expect(action.isSaveable)
    }

    @Test("isSaveable: AI with whitespace-only title → false")
    func isSaveableAIWhitespaceTitle() {
        let action = CustomAction(title: "   ", type: .ai, systemPrompt: "Do something")
        #expect(!action.isSaveable)
    }

    @Test("isSaveable: AI with whitespace-only systemPrompt → false")
    func isSaveableAIWhitespaceSystemPrompt() {
        let action = CustomAction(title: "Summarise", type: .ai, systemPrompt: "  \t  ")
        #expect(!action.isSaveable)
    }

    @Test("isSaveable: Translation with empty title → false")
    func isSaveableTranslationEmptyTitle() {
        let action = CustomAction(title: "", type: .translation, systemPrompt: "")
        #expect(!action.isSaveable)
    }

    @Test("isSaveable: Translation with title and empty systemPrompt → true")
    func isSaveableTranslationTitleOnly() {
        let action = CustomAction(title: "Translate", type: .translation, systemPrompt: "")
        #expect(action.isSaveable)
    }

    @Test("isSaveable: Speech with empty title → false")
    func isSaveableSpeechEmptyTitle() {
        let action = CustomAction(title: "", type: .speech, systemPrompt: "")
        #expect(!action.isSaveable)
    }

    @Test("isSaveable: Speech with title and empty systemPrompt → true")
    func isSaveableSpeechTitleOnly() {
        let action = CustomAction(title: "Read Aloud", type: .speech, systemPrompt: "")
        #expect(action.isSaveable)
    }

    @Test("isSaveable: Dictionary with empty title → false")
    func isSaveableDictionaryEmptyTitle() {
        let action = CustomAction(title: "", type: .dictionary, systemPrompt: "")
        #expect(!action.isSaveable)
    }

    @Test("isSaveable: Dictionary with title and empty systemPrompt → true")
    func isSaveableDictionaryTitleOnly() {
        let action = CustomAction(title: "Check Vietnamese", type: .dictionary, systemPrompt: "")
        #expect(action.isSaveable)
    }
}

// MARK: - sanitizeImported tests

@Suite("CustomAction.sanitizeImported")
struct SanitizeImportedTests {

    // MARK: - Helpers

    private func makeAI(provider: ProviderKind = .anthropic) -> CustomAction {
        CustomAction(
            title: "AI Action",
            type: .ai,
            systemPrompt: "Do something",
            providerKind: provider,
            model: "claude-sonnet-4-6"
        )
    }

    private func makeTranslation(provider: ProviderKind = .deepL) -> CustomAction {
        CustomAction(
            title: "Translate",
            type: .translation,
            systemPrompt: "",
            providerKind: provider,
            model: "default",
            targetLanguage: "fr",
            tone: .formal
        )
    }

    private func makeSpeech(engine: SpeakEngineSelection = .system) -> CustomAction {
        var settings = SpeakSettings.default
        settings.selectedEngine = engine
        return CustomAction(
            title: "Read Aloud",
            type: .speech,
            systemPrompt: "",
            providerKind: .anthropic,
            model: "",
            speakSettings: settings
        )
    }

    private func makeDictionary(engine: SpeakEngineSelection = .system) -> CustomAction {
        var settings = SpeakSettings.default
        settings.selectedEngine = engine
        return CustomAction(
            title: "Look up",
            type: .dictionary,
            systemPrompt: "",
            providerKind: .anthropic,
            model: "",
            dictionaryConfig: DictionaryConfig(
                provider: .minhqnd,
                definitionLanguage: "vi",
                isEnabled: true,
                speakSettings: settings,
                accent: .french
            )
        )
    }

    // MARK: - Provider validation — type-aware

    @Test("AI action with allowed provider is accepted")
    func aiAllowedProviderAccepted() {
        let action = makeAI(provider: .anthropic)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result != nil)
        #expect(result?.type == .ai)
    }

    @Test("AI action with disallowed provider (deepL) is rejected")
    func aiDisallowedProviderRejected() {
        // deepL is allowed for translation but NOT for AI.
        let action = makeAI(provider: .deepL)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result == nil)
    }

    @Test("AI action with disallowed provider (googleTranslate) is rejected")
    func aiGoogleTranslateRejected() {
        let action = makeAI(provider: .googleTranslate)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result == nil)
    }

    @Test("translation action with allowed provider (deepL) is accepted")
    func translationDeepLAccepted() {
        let action = makeTranslation(provider: .deepL)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result != nil)
        #expect(result?.type == .translation)
    }

    @Test("translation action with AI provider (anthropic) is accepted when translate allows it")
    func translationAnthropicAcceptedWhenAllowed() {
        // Anthropic is in translate.allowedProviders — verify acceptance.
        let isAllowed = ActionKind.translate.allowedProviders.contains(.anthropic)
        let action = makeTranslation(provider: .anthropic)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        if isAllowed {
            #expect(result != nil)
        } else {
            #expect(result == nil)
        }
    }

    @Test("speech action is never rejected on provider (provider is irrelevant)")
    func speechAcceptedRegardlessOfProvider() {
        // Even with an arbitrary provider, speech must not be rejected.
        let action = makeSpeech(engine: .system)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result != nil)
        #expect(result?.type == .speech)
    }

    @Test("dictionary action is never rejected on provider (provider is irrelevant)")
    func dictionaryAcceptedRegardlessOfProvider() {
        let action = makeDictionary(engine: .system)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result != nil)
        #expect(result?.type == .dictionary)
    }

    // MARK: - Fresh UUID

    @Test("sanitizeImported generates a fresh UUID")
    func freshUUIDGenerated() {
        let action = makeAI()
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result != nil)
        #expect(result?.id != action.id)
    }

    // MARK: - Cloud-gate clamp

    @Test("speech with cloud engine + cloudAllowed:false → engine becomes .system")
    func speechCloudEngineClampedWhenNotPro() {
        let action = makeSpeech(engine: .cloud(.openAITTS))
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result != nil)
        #expect(result?.speakSettings.selectedEngine == .system)
    }

    @Test("speech with cloud engine + cloudAllowed:true → engine preserved")
    func speechCloudEnginePreservedWhenPro() {
        let action = makeSpeech(engine: .cloud(.openAITTS))
        let result = CustomAction.sanitizeImported(action, cloudAllowed: true)
        #expect(result != nil)
        #expect(result?.speakSettings.selectedEngine == .cloud(.openAITTS))
    }

    @Test("speech with system engine + cloudAllowed:false → engine stays .system")
    func speechSystemEngineUnchangedWhenNotPro() {
        let action = makeSpeech(engine: .system)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result != nil)
        #expect(result?.speakSettings.selectedEngine == .system)
    }

    @Test("dictionary with cloud speech engine + cloudAllowed:false → engine becomes .system")
    func dictionaryCloudEngineClampedWhenNotPro() {
        let action = makeDictionary(engine: .cloud(.openAITTS))
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result != nil)
        #expect(result?.dictionaryConfig.speakSettings.selectedEngine == .system)
    }

    // MARK: - Field bounding

    @Test("title longer than 100 chars is capped")
    func titleCapped() {
        var action = makeAI()
        action.title = String(repeating: "A", count: 200)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.title.count == 100)
    }

    @Test("systemPrompt longer than 10000 chars is capped")
    func systemPromptCapped() {
        var action = makeAI()
        action.systemPrompt = String(repeating: "X", count: 20000)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.systemPrompt.count == 10000)
    }

    @Test("targetLanguage longer than 20 chars is capped")
    func targetLanguageCapped() {
        var action = makeTranslation()
        action.targetLanguage = String(repeating: "z", count: 50)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.targetLanguage.count == 20)
    }

    @Test("dictionary definitionLanguage longer than 20 chars is capped")
    func dictionaryDefinitionLanguageCapped() {
        var action = makeDictionary()
        action.dictionaryConfig.definitionLanguage = String(repeating: "z", count: 50)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.dictionaryConfig.definitionLanguage.count == 20)
    }

    @Test("speakSettings.defaultVoiceID longer than 100 chars is capped")
    func speakSettingsDefaultVoiceIDCapped() {
        var action = makeAI()
        var settings = SpeakSettings.default
        settings.defaultVoiceID = String(repeating: "x", count: 200)
        action.speakSettings = settings
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.speakSettings.defaultVoiceID?.count == 100)
    }

    @Test("ttsConfig.model longer than 200 chars is capped")
    func ttsConfigModelCapped() {
        var action = makeAI()
        var config = TTSProviderConfig.default
        config.model = String(repeating: "m", count: 400)
        action.ttsConfig = config
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.ttsConfig.model?.count == 200)
    }

    @Test("ttsConfig.defaultVoice longer than 100 chars is capped")
    func ttsConfigDefaultVoiceCapped() {
        var action = makeAI()
        var config = TTSProviderConfig.default
        config.defaultVoice = String(repeating: "v", count: 200)
        action.ttsConfig = config
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.ttsConfig.defaultVoice?.count == 100)
    }

    @Test("ttsConfig.voiceOverrides with more than 20 entries is capped to 20")
    func ttsConfigVoiceOverridesCapped() {
        var action = makeAI()
        var config = TTSProviderConfig.default
        var overrides: [String: String] = [:]
        for i in 0..<50 {
            overrides["lang-\(i)"] = "voice-\(i)"
        }
        config.voiceOverrides = overrides
        action.ttsConfig = config
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.ttsConfig.voiceOverrides.count ?? 0 <= 20)
    }

    @Test("ttsConfig.voiceOverride keys longer than 20 chars are capped")
    func ttsConfigVoiceOverrideKeyCapped() {
        var action = makeAI()
        var config = TTSProviderConfig.default
        config.voiceOverrides = [String(repeating: "k", count: 50): "voice"]
        action.ttsConfig = config
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        let overrides = result?.ttsConfig.voiceOverrides ?? [:]
        for key in overrides.keys {
            #expect(key.count <= 20)
        }
    }

    @Test("ttsConfig.voiceOverride values longer than 100 chars are capped")
    func ttsConfigVoiceOverrideValueCapped() {
        var action = makeAI()
        var config = TTSProviderConfig.default
        config.voiceOverrides = ["en-US": String(repeating: "v", count: 200)]
        action.ttsConfig = config
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        let overrides = result?.ttsConfig.voiceOverrides ?? [:]
        for value in overrides.values {
            #expect(value.count <= 100)
        }
    }

    // MARK: - Translation fields carried through

    @Test("translation action preserves targetLanguage and tone")
    func translationFieldsPreserved() {
        let action = makeTranslation(provider: .deepL)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.targetLanguage == "fr")
        #expect(result?.tone == .formal)
    }

    // MARK: - AI+deepL is rejected; translation+deepL is accepted (type-awareness discriminator)

    @Test("type-aware: deepL rejected for AI but accepted for Translation")
    func typeAwarenessDiscriminator() {
        let aiAction = makeAI(provider: .deepL)
        let translationAction = makeTranslation(provider: .deepL)
        #expect(CustomAction.sanitizeImported(aiAction, cloudAllowed: false) == nil)
        #expect(CustomAction.sanitizeImported(translationAction, cloudAllowed: false) != nil)
    }

    // MARK: - Additional field bounding (security bounds coverage)

    @Test("actionDescription longer than 500 chars is capped")
    func actionDescriptionCapped() {
        var action = makeAI()
        action.actionDescription = String(repeating: "D", count: 1000)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.actionDescription.count == 500)
    }

    @Test("actionDescription under cap is passed through unchanged")
    func actionDescriptionUnderCapPassthrough() {
        var action = makeAI()
        action.actionDescription = "short"
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.actionDescription == "short")
    }

    @Test("icon .sfSymbol name longer than 100 chars is capped")
    func iconSFSymbolNameCapped() {
        var action = makeAI()
        action.icon = .sfSymbol(String(repeating: "s", count: 200))
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        if case .sfSymbol(let name) = result?.icon {
            #expect(name.count == 100)
        } else {
            Issue.record("Expected .sfSymbol icon")
        }
    }

    @Test("icon .emoji longer than 8 grapheme clusters is capped to 8 characters")
    func iconEmojiCapped() {
        // Each 👨‍👩‍👧‍👦 is 1 grapheme cluster but many unicode scalars.
        // Using 12 copies: 12 chars, 84 scalars. After cap: 8 chars.
        var action = makeAI()
        action.icon = .emoji(String(repeating: "👨‍👩‍👧‍👦", count: 12))
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        if case .emoji(let char) = result?.icon {
            #expect(char.count == 8)
        } else {
            Issue.record("Expected .emoji icon")
        }
    }

    @Test("ttsConfig.region longer than 50 chars is capped")
    func ttsConfigRegionCapped() {
        var action = makeAI()
        var config = TTSProviderConfig.default
        config.region = String(repeating: "r", count: 100)
        action.ttsConfig = config
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.ttsConfig.region?.count == 50)
    }

    @Test("CustomAction.model longer than 200 chars is capped")
    func customActionModelCapped() {
        var action = makeAI()
        action.model = String(repeating: "m", count: 400)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.model.count == 200)
    }

    @Test("speakSettings.quickSwitchAccents with more than 20 entries is capped to 20")
    func quickSwitchAccentsCapped() {
        var action = makeAI()
        var settings = SpeakSettings.default
        // SpeakAccent has only 5 cases; duplicates are allowed (per source comment).
        settings.quickSwitchAccents = Array(repeating: .usEnglish, count: 25)
        action.speakSettings = settings
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.speakSettings.quickSwitchAccents.count == 20)
    }

    // MARK: - Scriptable field bounds

    @Test("scriptSource longer than 20000 chars is clamped to 20000")
    func scriptSourceClamped() {
        var action = makeAI()
        action.scriptSource = String(repeating: "x", count: 25000)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.scriptSource.count == 20000)
    }

    @Test("appliesWhenRegex longer than 500 chars is clamped to 500")
    func appliesWhenRegexClamped() {
        var action = makeAI()
        action.appliesWhenRegex = String(repeating: ".", count: 1000)
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.appliesWhenRegex.count == 500)
    }

    @Test("scriptSource under cap passes through unchanged")
    func scriptSourceUnderCapPassthrough() {
        var action = makeAI()
        action.scriptSource = "echo hello"
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.scriptSource == "echo hello")
    }

    @Test("appliesWhenRegex under cap passes through unchanged")
    func appliesWhenRegexUnderCapPassthrough() {
        var action = makeAI()
        action.appliesWhenRegex = "^https?://"
        let result = CustomAction.sanitizeImported(action, cloudAllowed: false)
        #expect(result?.appliesWhenRegex == "^https?://")
    }
}

// MARK: - Backward-compat decode for new scriptable fields

@Suite("CustomAction backward-compat decode (scriptable fields)")
struct CustomActionBackwardCompatTests {

    /// Build a JSON blob that represents a CustomAction saved by an older build —
    /// i.e., a blob that has NO `scriptSource`, `afterRun`, or `appliesWhenRegex` keys.
    private func legacyBlob(type: String = "ai") throws -> Data {
        let dict: [String: Any] = [
            "id": UUID().uuidString,
            "title": "Legacy",
            "actionDescription": "",
            // ActionIcon Codable layout: {"type": "sfSymbol", "value": "<name>"}
            "icon": ["type": "sfSymbol", "value": "sparkles"],
            "type": type,
            "systemPrompt": "Do something",
            "providerKind": "anthropic",
            "model": "claude-sonnet-4-6",
            "isEnabled": true,
            "targetLanguage": "en",
            "tone": "neutral"
            // Deliberately omitting: scriptSource, afterRun, appliesWhenRegex
        ]
        return try JSONSerialization.data(withJSONObject: dict)
    }

    @Test("blob without scriptSource decodes to empty string")
    func noScriptSourceDecodesEmpty() throws {
        let data = try legacyBlob()
        let decoded = try JSONDecoder().decode(CustomAction.self, from: data)
        #expect(decoded.scriptSource == "")
    }

    @Test("blob without afterRun decodes to .none")
    func noAfterRunDecodesToNone() throws {
        let data = try legacyBlob()
        let decoded = try JSONDecoder().decode(CustomAction.self, from: data)
        #expect(decoded.afterRun == .none)
    }

    @Test("blob without appliesWhenRegex decodes to empty string")
    func noAppliesWhenRegexDecodesEmpty() throws {
        let data = try legacyBlob()
        let decoded = try JSONDecoder().decode(CustomAction.self, from: data)
        #expect(decoded.appliesWhenRegex == "")
    }

    @Test("all three scriptable field defaults coexist correctly")
    func allThreeDefaultsTogether() throws {
        let data = try legacyBlob()
        let decoded = try JSONDecoder().decode(CustomAction.self, from: data)
        #expect(decoded.scriptSource == "")
        #expect(decoded.afterRun == .none)
        #expect(decoded.appliesWhenRegex == "")
    }
}

// MARK: - New CustomActionType cases

@Suite("CustomActionType — new scriptable cases")
struct CustomActionTypeScriptableTests {

    // MARK: - Codable round-trips

    @Test("CustomActionType.openURL Codable round-trip")
    func openURLRoundTrip() throws {
        let action = CustomAction(
            title: "Open in Browser",
            type: .openURL,
            systemPrompt: "",
            scriptSource: "https://example.com/?q=\(PlaceholderExpander.textToken)"
        )
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(CustomAction.self, from: data)
        #expect(decoded.type == .openURL)
        #expect(decoded.scriptSource == action.scriptSource)
        #expect(decoded == action)
    }

    @Test("CustomActionType.runShortcut Codable round-trip")
    func runShortcutRoundTrip() throws {
        let action = CustomAction(
            title: "Run My Shortcut",
            type: .runShortcut,
            systemPrompt: "",
            scriptSource: "My Shortcut Name"
        )
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(CustomAction.self, from: data)
        #expect(decoded.type == .runShortcut)
        #expect(decoded.scriptSource == "My Shortcut Name")
        #expect(decoded == action)
    }

    @Test("CustomActionType.appleScript Codable round-trip")
    func appleScriptRoundTrip() throws {
        let action = CustomAction(
            title: "Say It",
            type: .appleScript,
            systemPrompt: "",
            scriptSource: "say \(PlaceholderExpander.textToken)",
            afterRun: .showResult
        )
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(CustomAction.self, from: data)
        #expect(decoded.type == .appleScript)
        #expect(decoded.afterRun == .showResult)
        #expect(decoded == action)
    }

    @Test("CustomActionType.shellScript Codable round-trip")
    func shellScriptRoundTrip() throws {
        let action = CustomAction(
            title: "Count Words",
            type: .shellScript,
            systemPrompt: "",
            scriptSource: "echo $POPGUY_TEXT | wc -w",
            afterRun: .copyResult
        )
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(CustomAction.self, from: data)
        #expect(decoded.type == .shellScript)
        #expect(decoded.afterRun == .copyResult)
        #expect(decoded == action)
    }

    // MARK: - isSaveable

    @Test("isSaveable: openURL with empty scriptSource → false")
    func openURLEmptyScriptSourceNotSaveable() {
        let action = CustomAction(title: "Open", type: .openURL, systemPrompt: "", scriptSource: "")
        #expect(!action.isSaveable)
    }

    @Test("isSaveable: openURL with title and scriptSource → true")
    func openURLWithSourceIsSaveable() {
        let action = CustomAction(title: "Open", type: .openURL, systemPrompt: "", scriptSource: "https://example.com")
        #expect(action.isSaveable)
    }

    @Test("isSaveable: runShortcut with empty scriptSource → false")
    func runShortcutEmptySourceNotSaveable() {
        let action = CustomAction(title: "Run", type: .runShortcut, systemPrompt: "", scriptSource: "")
        #expect(!action.isSaveable)
    }

    @Test("isSaveable: runShortcut with title and scriptSource → true")
    func runShortcutWithSourceIsSaveable() {
        let action = CustomAction(title: "Run", type: .runShortcut, systemPrompt: "", scriptSource: "My Shortcut")
        #expect(action.isSaveable)
    }

    @Test("isSaveable: appleScript with empty scriptSource → false")
    func appleScriptEmptySourceNotSaveable() {
        let action = CustomAction(title: "Script", type: .appleScript, systemPrompt: "", scriptSource: "")
        #expect(!action.isSaveable)
    }

    @Test("isSaveable: appleScript with title and scriptSource → true")
    func appleScriptWithSourceIsSaveable() {
        let action = CustomAction(title: "Script", type: .appleScript, systemPrompt: "", scriptSource: "say \"hello\"")
        #expect(action.isSaveable)
    }

    @Test("isSaveable: shellScript with empty scriptSource → false")
    func shellScriptEmptySourceNotSaveable() {
        let action = CustomAction(title: "Shell", type: .shellScript, systemPrompt: "", scriptSource: "")
        #expect(!action.isSaveable)
    }

    @Test("isSaveable: shellScript with title and scriptSource → true")
    func shellScriptWithSourceIsSaveable() {
        let action = CustomAction(title: "Shell", type: .shellScript, systemPrompt: "", scriptSource: "echo hi")
        #expect(action.isSaveable)
    }

    @Test("isSaveable: whitespace-only scriptSource is not saveable")
    func scriptSourceWhitespaceNotSaveable() {
        let action = CustomAction(title: "Script", type: .appleScript, systemPrompt: "", scriptSource: "   ")
        #expect(!action.isSaveable)
    }

    // MARK: - allowedProviders

    @Test("allowedProviders returns [] for .openURL")
    func openURLAllowedProvidersEmpty() {
        #expect(CustomAction.allowedProviders(for: .openURL).isEmpty)
    }

    @Test("allowedProviders returns [] for .runShortcut")
    func runShortcutAllowedProvidersEmpty() {
        #expect(CustomAction.allowedProviders(for: .runShortcut).isEmpty)
    }

    @Test("allowedProviders returns [] for .appleScript")
    func appleScriptAllowedProvidersEmpty() {
        #expect(CustomAction.allowedProviders(for: .appleScript).isEmpty)
    }

    @Test("allowedProviders returns [] for .shellScript")
    func shellScriptAllowedProvidersEmpty() {
        #expect(CustomAction.allowedProviders(for: .shellScript).isEmpty)
    }
}
