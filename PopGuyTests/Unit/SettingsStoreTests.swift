// SettingsStoreTests.swift
// PopGuyTests
//
// TDD: SettingsStore — encode/decode and mapping round-trips against an
// injected UserDefaults(suiteName:) so tests don't touch real app prefs.
// Each test generates a unique suite name and removes the suite after.

import Foundation
import Testing
@testable import PopGuy

// MARK: - SettingsStoreTests

@Suite("SettingsStore")
@MainActor
struct SettingsStoreTests {

    // MARK: - Helpers

    /// Create a fresh UserDefaults suite with a unique name for this test run.
    /// The caller is responsible for removing it (use `defer`).
    private func makeSuite() -> (UserDefaults, String) {
        let name = "com.popguy.test.\(UUID().uuidString)"
        // UserDefaults(suiteName:) returns non-nil for any non-empty name.
        return (UserDefaults(suiteName: name)!, name)
    }

    private func removeSuite(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    // MARK: - Default values

    @Test("default improveConfig is OpenAI / first curated model")
    func defaultImproveConfig() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.improveConfig == ActionConfig.defaultImprove)
        #expect(store.improveConfig.providerKind == .openAI)
        #expect(store.improveConfig.model == ActionConfig.defaultModel)
    }

    @Test("default translateConfig is OpenAI / first curated model")
    func defaultTranslateConfig() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.translateConfig == ActionConfig.defaultTranslate)
        #expect(store.translateConfig.providerKind == .openAI)
        #expect(store.translateConfig.model == ActionConfig.defaultModel)
    }

    @Test("default target language is 'en'")
    func defaultTargetLanguage() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.defaultTargetLanguage == "en")
    }

    @Test("default Ollama base URL is localhost:11434")
    func defaultOllamaBaseURL() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.ollamaBaseURL.contains("localhost"))
        #expect(store.ollamaBaseURL.contains("11434"))
    }

    @Test("default enabled flags are true")
    func defaultEnabledFlags() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.improveEnabled == true)
        #expect(store.translateEnabled == true)
    }

    // MARK: - Round-trips

    @Test("improveConfig round-trips through UserDefaults")
    func improveConfigRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let custom = ActionConfig(id: .improve, providerKind: .openAI, model: "gpt-4o")
        let store1 = SettingsStore(defaults: suite)
        store1.improveConfig = custom

        // Re-load from the same suite — simulates app restart.
        let store2 = SettingsStore(defaults: suite)
        #expect(store2.improveConfig == custom)
    }

    @Test("translateConfig round-trips through UserDefaults")
    func translateConfigRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let custom = ActionConfig(id: .translate, providerKind: .googleTranslate, model: "default")
        let store1 = SettingsStore(defaults: suite)
        store1.translateConfig = custom

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.translateConfig == custom)
    }

    @Test("defaultTargetLanguage round-trips through UserDefaults")
    func targetLanguageRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store1 = SettingsStore(defaults: suite)
        store1.defaultTargetLanguage = "vi"

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.defaultTargetLanguage == "vi")
    }

    @Test("ollamaBaseURL round-trips through UserDefaults")
    func ollamaBaseURLRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store1 = SettingsStore(defaults: suite)
        store1.ollamaBaseURL = "http://192.168.1.10:11434/v1"

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.ollamaBaseURL == "http://192.168.1.10:11434/v1")
    }

    @Test("Babylon BGL dictionaries round-trip through UserDefaults")
    func babylonDictionariesRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let dictionary = BabylonDictionary(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            displayName: "Vietnamese English",
            filePath: "/Users/example/Dictionaries/ve.bgl",
            isEnabled: true,
            entryCount: 42
        )
        let store1 = SettingsStore(defaults: suite)
        store1.babylonDictionaries = [dictionary]

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.babylonDictionaries == [dictionary])
    }

    @Test("enabled flags round-trip through UserDefaults")
    func enabledFlagsRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store1 = SettingsStore(defaults: suite)
        store1.improveEnabled   = false
        store1.translateEnabled = false

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.improveEnabled   == false)
        #expect(store2.translateEnabled == false)
    }

    // MARK: - History toggles

    @Test("history toggles default to true on a fresh suite")
    func historyTogglesDefaultTrue() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.historyEnabled == true)
        #expect(store.historyStoreFullText == true)
    }

    @Test("history toggles round-trip through UserDefaults")
    func historyTogglesRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store1 = SettingsStore(defaults: suite)
        store1.historyEnabled = false
        store1.historyStoreFullText = false

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.historyEnabled == false)
        #expect(store2.historyStoreFullText == false)
    }

    // MARK: - preserveFormatting

    @Test("preserveFormatting defaults to false on a fresh suite")
    func preserveFormattingDefaultsFalse() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.preserveFormatting == false)
    }

    @Test("preserveFormatting round-trips through UserDefaults")
    func preserveFormattingRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store1 = SettingsStore(defaults: suite)
        store1.preserveFormatting = true

        // Re-load from the same suite — simulates app restart.
        let store2 = SettingsStore(defaults: suite)
        #expect(store2.preserveFormatting == true)
    }

    // MARK: - globalPrompt

    @Test("globalPrompt defaults to empty on a fresh suite")
    func globalPromptDefaultsEmpty() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.globalPrompt == "")
    }

    @Test("globalPrompt round-trips through UserDefaults")
    func globalPromptRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store1 = SettingsStore(defaults: suite)
        store1.globalPrompt = "Always respond in a concise, professional tone."

        // Re-load from the same suite — simulates app restart.
        let store2 = SettingsStore(defaults: suite)
        #expect(store2.globalPrompt == "Always respond in a concise, professional tone.")
    }

    // MARK: - hasOnboarded

    @Test("hasOnboarded defaults to false on a fresh suite")
    func hasOnboardedDefaultsFalse() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.hasOnboarded == false)
    }

    @Test("hasOnboarded round-trips through UserDefaults")
    func hasOnboardedRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store1 = SettingsStore(defaults: suite)
        store1.hasOnboarded = true

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.hasOnboarded == true)
    }

    // MARK: - config(for:) / setConfig(_:for:) helpers

    @Test("config(for: .improve) returns improveConfig")
    func configForImprove() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.config(for: .improve) == store.improveConfig)
    }

    @Test("config(for: .translate) returns translateConfig")
    func configForTranslate() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.config(for: .translate) == store.translateConfig)
    }

    @Test("setConfig persists and can be re-read via config(for:)")
    func setConfigRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let custom = ActionConfig(id: .improve, providerKind: .ollama, model: "llama3")
        let store = SettingsStore(defaults: suite)
        store.setConfig(custom, for: .improve)
        #expect(store.config(for: .improve) == custom)
    }

    // MARK: - I-B: Allowed-provider lists

    @Test("improve.allowedProviders contains only AI providers")
    func improveAllowedProviders() {
        let allowed = ActionKind.improve.allowedProviders
        #expect(allowed.contains(.openAI))
        #expect(allowed.contains(.anthropic))
        #expect(allowed.contains(.ollama))
        // Translation-only providers must NOT appear
        #expect(!allowed.contains(.deepL))
        #expect(!allowed.contains(.googleTranslate))
    }

    @Test("translate.allowedProviders contains all providers")
    func translateAllowedProviders() {
        let allowed = ActionKind.translate.allowedProviders
        for kind in ProviderKind.allCases {
            #expect(allowed.contains(kind), "Expected \(kind) in translate.allowedProviders")
        }
    }

    // MARK: - I-B: Bad-state coercion on load

    @Test("improveConfig persisted with DeepL provider is coerced to AI default on load")
    func improveConfigCoercedFromDeepL() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Persist a bad config (DeepL for Improve).
        let bad = ActionConfig(id: .improve, providerKind: .deepL, model: "default")
        let store1 = SettingsStore(defaults: suite)
        // Bypass the coercion by directly encoding to defaults (simulates old data).
        if let data = try? JSONEncoder().encode(bad) {
            suite.set(data, forKey: "settings.improveConfig")
        }

        // Re-load — coercion should kick in.
        let store2 = SettingsStore(defaults: suite)
        #expect(ActionKind.improve.allowedProviders.contains(store2.improveConfig.providerKind),
                "Loaded improveConfig.providerKind should be AI-only after coercion")
        #expect(store2.improveConfig.providerKind != .deepL)
    }

    @Test("improveConfig persisted with Google Translate is coerced to AI default on load")
    func improveConfigCoercedFromGoogle() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let bad = ActionConfig(id: .improve, providerKind: .googleTranslate, model: "default")
        if let data = try? JSONEncoder().encode(bad) {
            suite.set(data, forKey: "settings.improveConfig")
        }

        let store = SettingsStore(defaults: suite)
        #expect(store.improveConfig.providerKind != .googleTranslate)
        #expect(ActionKind.improve.allowedProviders.contains(store.improveConfig.providerKind))
    }

    @Test("improveConfig with valid AI provider is not coerced")
    func improveConfigNotCoercedForOllama() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let valid = ActionConfig(id: .improve, providerKind: .ollama, model: "llama3")
        if let data = try? JSONEncoder().encode(valid) {
            suite.set(data, forKey: "settings.improveConfig")
        }

        let store = SettingsStore(defaults: suite)
        #expect(store.improveConfig.providerKind == .ollama)
    }

    @Test("promptConfig coerces a translation-only provider to the default AI provider")
    func promptConfigCoercedFromDeepL() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Persist a bad config (DeepL for Prompt — translation-only, not in prompt.allowedProviders).
        let bad = ActionConfig(id: .prompt, providerKind: .deepL, model: "default")
        if let data = try? JSONEncoder().encode(bad) {
            suite.set(data, forKey: "settings.promptConfig")
        }

        // Re-load — coercion should kick in.
        let store = SettingsStore(defaults: suite)
        #expect(store.promptConfig.providerKind != .deepL)
        #expect(ActionKind.prompt.allowedProviders.contains(store.promptConfig.providerKind),
                "Loaded promptConfig.providerKind should be AI-only after coercion")
    }

    // MARK: - Shorten / Proofread built-in actions

    @Test("default shortenConfig is OpenAI / first curated model")
    func defaultShortenConfig() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.shortenConfig == ActionConfig.defaultShorten)
        #expect(store.shortenConfig.providerKind == .openAI)
        #expect(store.shortenConfig.model == ActionConfig.defaultModel)
    }

    @Test("default proofreadConfig is OpenAI / first curated model")
    func defaultProofreadConfig() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.proofreadConfig == ActionConfig.defaultProofread)
        #expect(store.proofreadConfig.providerKind == .openAI)
        #expect(store.proofreadConfig.model == ActionConfig.defaultModel)
    }

    @Test("default shorten/proofread enabled flags are true")
    func defaultShortenProofreadEnabled() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.shortenEnabled == true)
        #expect(store.proofreadEnabled == true)
    }

    @Test("config(for: .shorten) and config(for: .proofread) return the matching configs")
    func configForShortenProofread() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.config(for: .shorten) == store.shortenConfig)
        #expect(store.config(for: .proofread) == store.proofreadConfig)
    }

    @Test("setConfig persists shorten and proofread configs")
    func setConfigShortenProofread() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let shorten   = ActionConfig(id: .shorten,   providerKind: .openAI, model: "gpt-4o")
        let proofread = ActionConfig(id: .proofread, providerKind: .ollama, model: "llama3")
        store.setConfig(shorten, for: .shorten)
        store.setConfig(proofread, for: .proofread)
        #expect(store.config(for: .shorten) == shorten)
        #expect(store.config(for: .proofread) == proofread)
    }

    @Test("shortenConfig round-trips through UserDefaults")
    func shortenConfigRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let custom = ActionConfig(id: .shorten, providerKind: .openAI, model: "gpt-4o")
        let store1 = SettingsStore(defaults: suite)
        store1.shortenConfig = custom

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.shortenConfig == custom)
    }

    @Test("shorten and proofread allowedProviders contain only AI providers")
    func shortenProofreadAllowedProviders() {
        for kind in [ActionKind.shorten, ActionKind.proofread] {
            let allowed = kind.allowedProviders
            #expect(allowed.contains(.openAI))
            #expect(allowed.contains(.anthropic))
            #expect(allowed.contains(.ollama))
            #expect(!allowed.contains(.deepL))
            #expect(!allowed.contains(.googleTranslate))
        }
    }

    // MARK: - Toolbar action cap

    @Test("maxToolbarActions is 11 (6 principal + 5 burger)")
    func maxToolbarActionsIs11() {
        #expect(SettingsStore.maxToolbarActions == 11)
        #expect(SettingsStore.maxToolbarActions == ProConfig.maxPrincipalActions + ProConfig.maxBurgerActions)
    }

    @Test("enabledToolbarActionCount counts enabled built-ins and custom actions")
    func enabledToolbarActionCount() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        // Default: all 5 built-ins on, no custom actions → count = 5.
        #expect(store.enabledToolbarActionCount == 5)

        // Disable one built-in → count = 4.
        store.improveEnabled = false
        #expect(store.enabledToolbarActionCount == 4)

        // Add one enabled custom action → count = 5.
        store.addCustomAction(CustomAction(
            title: "Test",
            systemPrompt: "Do something",
            isEnabled: true
        ))
        #expect(store.enabledToolbarActionCount == 5)

        // Add a disabled custom action → count unchanged.
        store.addCustomAction(CustomAction(
            title: "Disabled",
            systemPrompt: "Noop",
            isEnabled: false
        ))
        #expect(store.enabledToolbarActionCount == 5)

        // Re-enable the built-in — 5 built-ins + 1 enabled custom = 6 = cap (write-time enforcement via addCustomAction/updateCustomAction).
        store.improveEnabled = true
        #expect(store.enabledToolbarActionCount == 6)
    }

    @Test("enabledToolbarActionCount does not exceed maxToolbarActions when all built-ins are enabled")
    func enabledCountAtCap() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        // All 6 built-ins enabled (default 5 + enable Prompt) = count 6 (under cap=11).
        store.promptEnabled = true
        // Adding one enabled custom: count goes 6→7, still under cap.
        let firstResult = store.addCustomAction(CustomAction(
            title: "Custom1",
            systemPrompt: "Do something",
            isEnabled: true
        ))
        #expect(!firstResult)
        #expect(store.enabledToolbarActionCount == 7)

        // Fill remaining slots to cap=11.
        while store.enabledToolbarActionCount < SettingsStore.maxToolbarActions {
            let filler = CustomAction(
                title: "Filler \(store.enabledToolbarActionCount)",
                systemPrompt: "p",
                isEnabled: true
            )
            _ = store.addCustomAction(filler)
        }
        #expect(store.enabledToolbarActionCount == SettingsStore.maxToolbarActions)

        // Now at cap. Adding another enabled custom clamps it.
        let secondResult = store.addCustomAction(CustomAction(
            title: "CustomOverflow",
            systemPrompt: "Do something else",
            isEnabled: true
        ))
        #expect(secondResult)
        #expect(store.enabledToolbarActionCount == SettingsStore.maxToolbarActions)
    }

    // MARK: - Save-path cap enforcement

    @Test("addCustomAction clamps to disabled and returns true when at cap")
    func addCustomActionClampsAtCap() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // All 6 built-ins enabled (default 5 + Prompt) = count 6. Add enabled customs to reach cap=11.
        let store = SettingsStore(defaults: suite)
        store.promptEnabled = true
        #expect(store.enabledToolbarActionCount == 6)
        while store.enabledToolbarActionCount < SettingsStore.maxToolbarActions {
            let filler = CustomAction(title: "Filler \(store.enabledToolbarActionCount)", systemPrompt: "p", isEnabled: true)
            _ = store.addCustomAction(filler)
        }
        #expect(store.enabledToolbarActionCount == SettingsStore.maxToolbarActions)

        // Adding another enabled action at cap should clamp it to disabled.
        let countBeforeOverflow = store.customActions.count
        let clamped = store.addCustomAction(CustomAction(title: "B", systemPrompt: "p2", isEnabled: true))
        #expect(clamped)
        #expect(store.enabledToolbarActionCount == SettingsStore.maxToolbarActions)
        #expect(store.customActions.count == countBeforeOverflow + 1)
        #expect(store.customActions.last?.isEnabled == false)
    }

    @Test("addCustomAction under the cap stays enabled and returns false")
    func addCustomActionUnderCapStaysEnabled() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Disable one built-in so there is room: 4 built-ins enabled, add 1 custom → count goes 4→5, no clamp.
        let store = SettingsStore(defaults: suite)
        store.improveEnabled = false
        let clamped = store.addCustomAction(CustomAction(title: "A", systemPrompt: "p", isEnabled: true))
        #expect(!clamped)
        #expect(store.customActions.last?.isEnabled == true)
        #expect(store.enabledToolbarActionCount == 5)
    }

    @Test("addCustomAction disabled action is never clamped")
    func addCustomActionDisabledNeverClamped() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // All 5 built-ins enabled (default) = count 5 (under cap=6).
        let store = SettingsStore(defaults: suite)
        #expect(store.enabledToolbarActionCount == 5)

        // Adding a disabled action is never clamped regardless of current count.
        let clamped = store.addCustomAction(CustomAction(title: "B", systemPrompt: "p", isEnabled: false))
        #expect(!clamped)
        #expect(store.enabledToolbarActionCount == 5)
        #expect(store.customActions.last?.isEnabled == false)
    }

    @Test("updateCustomAction clamps flip-to-on at cap and returns true")
    func updateCustomActionClampsFlipOnAtCap() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Fill to cap=11: 6 built-ins (default 5 + Prompt) + enabled customs.
        let store = SettingsStore(defaults: suite)
        store.promptEnabled = true
        #expect(store.enabledToolbarActionCount == 6)
        while store.enabledToolbarActionCount < SettingsStore.maxToolbarActions {
            let filler = CustomAction(title: "Filler \(store.enabledToolbarActionCount)", systemPrompt: "p1", isEnabled: true)
            _ = store.addCustomAction(filler)
        }
        #expect(store.enabledToolbarActionCount == SettingsStore.maxToolbarActions)

        // Add a disabled custom action.
        var disabled = CustomAction(title: "B", systemPrompt: "p", isEnabled: false)
        let _ = store.addCustomAction(disabled)
        #expect(store.enabledToolbarActionCount == SettingsStore.maxToolbarActions)

        // Flip the disabled custom to enabled — at cap, should clamp.
        disabled.isEnabled = true
        let clamped = store.updateCustomAction(disabled)
        #expect(clamped)
        #expect(store.enabledToolbarActionCount == SettingsStore.maxToolbarActions)
        #expect(store.customActions.first(where: { $0.id == disabled.id })?.isEnabled == false)
    }

    @Test("updateCustomAction flip-to-on under cap stays enabled and returns false")
    func updateCustomActionFlipOnUnderCap() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Disable one built-in so there is room: 4 built-ins enabled, add a disabled custom → count = 4 (under cap).
        let store = SettingsStore(defaults: suite)
        store.improveEnabled = false
        let disabled = CustomAction(title: "A", systemPrompt: "p", isEnabled: false)
        let _ = store.addCustomAction(disabled)
        #expect(store.enabledToolbarActionCount == 4)

        // Flip to enabled — under cap, no clamp.
        var enabled = disabled
        enabled.isEnabled = true
        let clamped = store.updateCustomAction(enabled)
        #expect(!clamped)
        #expect(store.customActions.first(where: { $0.id == enabled.id })?.isEnabled == true)
        #expect(store.enabledToolbarActionCount == 5)
    }

    @Test("updateCustomAction already-enabled at cap keeps enabled — no false clamp")
    func updateCustomActionAlreadyEnabledAtCapNoFalseClamp() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Fill to cap=11: 6 built-ins (default 5 + Prompt) + enabled customs.
        let store = SettingsStore(defaults: suite)
        store.promptEnabled = true
        var action = CustomAction(title: "A", systemPrompt: "old", isEnabled: true)
        while store.enabledToolbarActionCount < SettingsStore.maxToolbarActions {
            if store.enabledToolbarActionCount == SettingsStore.maxToolbarActions - 1 {
                _ = store.addCustomAction(action)
            } else {
                let filler = CustomAction(title: "Filler \(store.enabledToolbarActionCount)", systemPrompt: "p", isEnabled: true)
                _ = store.addCustomAction(filler)
            }
        }
        #expect(store.enabledToolbarActionCount == SettingsStore.maxToolbarActions)

        // Edit a non-enable field (systemPrompt) — must not disable it.
        action.systemPrompt = "new"
        let clamped = store.updateCustomAction(action)
        #expect(!clamped)
        #expect(store.customActions.first(where: { $0.id == action.id })?.isEnabled == true)
        #expect(store.customActions.first(where: { $0.id == action.id })?.systemPrompt == "new")
        #expect(store.enabledToolbarActionCount == SettingsStore.maxToolbarActions)
    }

    @Test("updateCustomAction disabling is never blocked")
    func updateCustomActionDisableNeverBlocked() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // 4 built-ins + 1 enabled custom = 5 (under cap=6).
        let store = SettingsStore(defaults: suite)
        store.improveEnabled = false
        let action = CustomAction(title: "A", systemPrompt: "p", isEnabled: true)
        let _ = store.addCustomAction(action)
        #expect(store.enabledToolbarActionCount == 5)

        // Disable the custom — must always succeed with no clamp.
        var disabled = action
        disabled.isEnabled = false
        let clamped = store.updateCustomAction(disabled)
        #expect(!clamped)
        #expect(store.customActions.first(where: { $0.id == action.id })?.isEnabled == false)
        #expect(store.enabledToolbarActionCount == 4)
    }

    // MARK: - ttsConfig / setTTSConfig

    @Test("ttsConfig returns .default for an unset provider")
    func ttsConfigDefaultForUnset() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let config = store.ttsConfig(for: .googleCloudTTS)
        #expect(config == TTSProviderConfig.default)
    }

    @Test("setTTSConfig persists and ttsConfig reads back via same store")
    func setTTSConfigRoundTripSameStore() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let config = TTSProviderConfig(voiceOverrides: ["en-US": "alloy"], model: "tts-1")
        store.setTTSConfig(config, for: .openAITTS)
        #expect(store.ttsConfig(for: .openAITTS) == config)
    }

    @Test("ttsProviderConfigs round-trips through UserDefaults")
    func ttsProviderConfigsRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let config = TTSProviderConfig(voiceOverrides: ["en-US": "alloy"], model: "tts-1")
        let store1 = SettingsStore(defaults: suite)
        store1.setTTSConfig(config, for: .openAITTS)

        // Re-load from the same suite — simulates app restart.
        let store2 = SettingsStore(defaults: suite)
        #expect(store2.ttsConfig(for: .openAITTS) == config)
        // An unset provider still returns .default after reload.
        #expect(store2.ttsConfig(for: .azureTTS) == TTSProviderConfig.default)
    }

    // MARK: - detectCLIPath injection-seam tests

    @Test("detectCLIPath returns fixed path when ~/.local/bin hit")
    func detectCLIPathFixedLocalBin() {
        let home = "/fake/home"
        let name = "claude"
        let result = SettingsStore.detectCLIPath(
            name,
            home: home,
            fileExists: { path in path == "\(home)/.local/bin/\(name)" }
        )
        #expect(result == "\(home)/.local/bin/\(name)")
    }

    @Test("detectCLIPath returns not-found empty string when no candidate exists")
    func detectCLIPathNotFound() {
        let result = SettingsStore.detectCLIPath(
            "nonexistent-tool",
            home: "/fake/home",
            fileExists: { _ in false }
        )
        #expect(result == "")
    }

    @Test("detectCLIPath selects newest nvm version via localizedStandardCompare")
    func detectCLIPathNvmNewestVersion() throws {
        // Create a real temporary nvm-style directory tree so contentsOfDirectory
        // can enumerate the version directories.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("popguy-test-\(UUID().uuidString)")
        let nvmNodeDir = tmp.appendingPathComponent(".nvm/versions/node")
        // Create two version directories; v22 is newer than v9.
        let v9bin  = nvmNodeDir.appendingPathComponent("v9.11.2/bin")
        let v22bin = nvmNodeDir.appendingPathComponent("v22.21.1/bin")
        try FileManager.default.createDirectory(at: v9bin,  withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: v22bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let name = "codex"
        let home = tmp.path

        // fileExists returns true only for the v22 candidate, simulating the
        // binary being present only in the newest version's bin.
        let expectedPath = "\(home)/.nvm/versions/node/v22.21.1/bin/\(name)"
        let result = SettingsStore.detectCLIPath(
            name,
            home: home,
            fileExists: { path in path == expectedPath }
        )
        #expect(result == expectedPath)
    }

    // MARK: - actionOrder — first launch (no persisted order)

    @Test("actionOrder on first launch equals defaultBuiltinOrder plus seeded custom actions in array order")
    func actionOrderFirstLaunch() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Seed two custom actions directly into defaults so the store loads them at init
        // (mirrors how existing tests pre-seed customActions).
        let a = CustomAction(title: "A", systemPrompt: "pa", isEnabled: true)
        let b = CustomAction(title: "B", systemPrompt: "pb", isEnabled: true)
        if let data = try? JSONEncoder().encode([a, b]) {
            suite.set(data, forKey: "settings.customActions")
        }
        // Do NOT seed actionOrder — this simulates a first launch.

        let store = SettingsStore(defaults: suite)
        let expected = SettingsStore.defaultBuiltinOrder + [.custom(a.id), .custom(b.id)]
        #expect(store.actionOrder == expected)
    }

    // MARK: - actionOrder — reconcile behavior

    @Test("reconcileOrder drops duplicates and stale entries, appends missing canonical id")
    func actionOrderReconcile() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let a = CustomAction(title: "A", systemPrompt: "pa", isEnabled: true)
        // Seed customActions with only `a` (no `b` — so .custom(b.id) is stale).
        if let data = try? JSONEncoder().encode([a]) {
            suite.set(data, forKey: "settings.customActions")
        }

        let staleID = UUID()
        // Persisted order: [.custom(a), .speak, .speak (dup), .custom(staleID), .builtin(.improve) MISSING translate/shorten/etc]
        let persisted: [ActionIdentifier] = [
            .custom(a.id),
            .speak,
            .speak,                  // duplicate — should be dropped
            .custom(staleID),        // stale — not in canonical, should be dropped
            .builtin(.improve),
        ]
        if let data = try? JSONEncoder().encode(persisted) {
            suite.set(data, forKey: "settings.actionOrder")
        }

        let store = SettingsStore(defaults: suite)
        // Expected: valid persisted entries in their persisted order, then missing canonical entries appended.
        // Valid from persisted (first-occurrence): .custom(a), .speak, .builtin(.improve)
        // Missing canonical (in canonical order): .builtin(.shorten), .builtin(.proofread), .builtin(.prompt), .builtin(.translate), .dictionary
        let expected: [ActionIdentifier] = [
            .custom(a.id),
            .speak,
            .builtin(.improve),
            .builtin(.shorten),
            .builtin(.proofread),
            .builtin(.prompt),
            .builtin(.translate),
            .dictionary,
        ]
        #expect(store.actionOrder == expected)
    }

    // MARK: - actionOrder — CRUD sync and round-trip

    @Test("addCustomAction appends to actionOrder; deleteCustomAction removes it; round-trips across reload")
    func actionOrderCRUDRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store1 = SettingsStore(defaults: suite)
        let action = CustomAction(title: "Custom1", systemPrompt: "p1", isEnabled: true)
        store1.addCustomAction(action)

        // Exact equality: defaultBuiltinOrder + the added action.
        let expectedAfterAdd = SettingsStore.defaultBuiltinOrder + [ActionIdentifier.custom(action.id)]
        #expect(store1.actionOrder == expectedAfterAdd)

        store1.deleteCustomAction(id: action.id)
        #expect(store1.actionOrder == SettingsStore.defaultBuiltinOrder)

        // Re-add and reload to verify persistence.
        let action2 = CustomAction(title: "Custom2", systemPrompt: "p2", isEnabled: true)
        store1.addCustomAction(action2)

        let store2 = SettingsStore(defaults: suite)
        let expectedAfterReload = SettingsStore.defaultBuiltinOrder + [ActionIdentifier.custom(action2.id)]
        #expect(store2.actionOrder == expectedAfterReload)
    }

    // MARK: - actionOrder — moveAction

    @Test("moveAction reorders actionOrder")
    func moveActionReorders() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        // Fresh store: actionOrder = defaultBuiltinOrder (no customs).
        // Default: [.improve, .shorten, .proofread, .prompt, .translate, .dictionary, .speak]
        // Move .speak (index 6) to the front (toOffset: 0).
        store.moveAction(fromOffsets: IndexSet(integer: 6), toOffset: 0)

        let expected: [ActionIdentifier] = [
            .speak,
            .builtin(.improve),
            .builtin(.shorten),
            .builtin(.proofread),
            .builtin(.prompt),
            .builtin(.translate),
            .dictionary,
        ]
        #expect(store.actionOrder == expected)
    }

    // MARK: - actionOrder — clamp branch persists to actionOrder

    @Test("addCustomAction clamped branch still appends to actionOrder and persists across reload")
    func addCustomActionClampedAppendsToActionOrder() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Reach cap=11: all 6 built-ins enabled, plus enabled customs.
        let store1 = SettingsStore(defaults: suite)
        store1.promptEnabled = true
        while store1.enabledToolbarActionCount < SettingsStore.maxToolbarActions {
            let filler = CustomAction(title: "Filler \(store1.enabledToolbarActionCount)", systemPrompt: "p", isEnabled: true)
            _ = store1.addCustomAction(filler)
        }
        #expect(store1.enabledToolbarActionCount == SettingsStore.maxToolbarActions)

        // Add an enabled custom at cap — triggers the clamp branch.
        let extra = CustomAction(title: "Extra", systemPrompt: "p2", isEnabled: true)
        let clamped = store1.addCustomAction(extra)
        #expect(clamped)

        // The clamped action must appear in actionOrder even though isEnabled was flipped to false.
        let expectedOrder = SettingsStore.defaultBuiltinOrder + store1.customActions.map { .custom($0.id) }
        #expect(store1.actionOrder == expectedOrder)

        // Verify the order persists across a reload.
        let store2 = SettingsStore(defaults: suite)
        #expect(store2.actionOrder == expectedOrder)
    }

    // MARK: - actionOrder — user-reordered builtin order persists

    @Test("user-reordered builtin order is preserved across reload")
    func moveActionPersistedAcrossReload() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store1 = SettingsStore(defaults: suite)
        // Move .speak (index 6) to the front (toOffset: 0).
        store1.moveAction(fromOffsets: IndexSet(integer: 6), toOffset: 0)

        let expected: [ActionIdentifier] = [
            .speak,
            .builtin(.improve),
            .builtin(.shorten),
            .builtin(.proofread),
            .builtin(.prompt),
            .builtin(.translate),
            .dictionary,
        ]
        #expect(store1.actionOrder == expected)

        // Reload — reconcile must keep the user-reordered sequence intact.
        let store2 = SettingsStore(defaults: suite)
        #expect(store2.actionOrder == expected)
    }

    // MARK: - actionOrder — moveAction edge cases

    @Test("moveAction upward: move index 0 to toOffset 6 (end)")
    func moveActionUpward() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        // Default: [improve(0), shorten(1), proofread(2), prompt(3), translate(4), dictionary(5), speak(6)]
        // Move improve (index 0) to toOffset 7 (end) → [shorten, proofread, prompt, translate, dictionary, speak, improve]
        store.moveAction(fromOffsets: IndexSet(integer: 0), toOffset: 7)

        let expected: [ActionIdentifier] = [
            .builtin(.shorten),
            .builtin(.proofread),
            .builtin(.prompt),
            .builtin(.translate),
            .dictionary,
            .speak,
            .builtin(.improve),
        ]
        #expect(store.actionOrder == expected)
    }

    @Test("moveAction multi-index: move indices 0 and 1 to toOffset 4")
    func moveActionMultiIndex() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        // Default: [improve(0), shorten(1), proofread(2), prompt(3), translate(4), dictionary(5), speak(6)]
        // Move improve+shorten (indices 0,1) to toOffset 5.
        // adjustedDest = 5 - 2 = 3 (two source indices < 5).
        // After removal: [proofread, prompt, translate, dictionary, speak]
        // Insert at 3: [proofread, prompt, translate, improve, shorten, dictionary, speak]
        store.moveAction(fromOffsets: IndexSet([0, 1]), toOffset: 5)

        let expected: [ActionIdentifier] = [
            .builtin(.proofread),
            .builtin(.prompt),
            .builtin(.translate),
            .builtin(.improve),
            .builtin(.shorten),
            .dictionary,
            .speak,
        ]
        #expect(store.actionOrder == expected)
    }

    // MARK: - actionOrder — bounds guard

    @Test("moveAction out-of-bounds source is a no-op")
    func moveActionOutOfBoundsIsNoop() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let before = store.actionOrder
        // Source index 99 is out of bounds for a 6-element array.
        store.moveAction(fromOffsets: IndexSet(integer: 99), toOffset: 0)
        #expect(store.actionOrder == before)
    }

    @Test("moveAction out-of-bounds destination is a no-op")
    func moveActionOutOfBoundsDestinationIsNoop() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let before = store.actionOrder
        // toOffset: -1 is below the valid destination range.
        store.moveAction(fromOffsets: IndexSet(integer: 0), toOffset: -1)
        #expect(store.actionOrder == SettingsStore.defaultBuiltinOrder)
        #expect(store.actionOrder == before)
        // toOffset: count + 1 is above the valid destination range.
        store.moveAction(fromOffsets: IndexSet(integer: 0), toOffset: store.actionOrder.count + 1)
        #expect(store.actionOrder == SettingsStore.defaultBuiltinOrder)
        #expect(store.actionOrder == before)
    }

    // MARK: - isEnabled graceful degradation

    @Test("isEnabled returns false for a custom UUID not present in customActions")
    func isEnabledStaleCustomUUIDReturnsFalse() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let staleID = UUID()
        #expect(store.isEnabled(.custom(staleID)) == false)
    }

    // MARK: - enabledOrderedIdentifiers reflects reordered order

    @Test("enabledOrderedIdentifiers reflects reordered actionOrder after moveAction")
    func enabledOrderedIdentifiersReflectsReorder() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        // Disable prompt (default is already false) and shorten so the reorder effect is visible.
        store.promptEnabled = false
        store.shortenEnabled = false

        // Move .speak (index 6) to the front.
        store.moveAction(fromOffsets: IndexSet(integer: 6), toOffset: 0)
        // actionOrder is now: [speak, improve, shorten, proofread, prompt, translate, dictionary]

        // enabledOrderedIdentifiers should follow the reordered sequence, filtering disabled.
        // speak ✓, improve ✓, shorten ✗ (disabled), proofread ✓, prompt ✗ (disabled), translate ✓
        let expected: [ActionIdentifier] = [
            .speak,
            .builtin(.improve),
            .builtin(.proofread),
            .builtin(.translate),
        ]
        #expect(store.enabledOrderedIdentifiers == expected)
    }

    // MARK: - malformed JSON recovery

    @Test("malformed JSON in actionOrder key falls back to defaultBuiltinOrder on load")
    func malformedJSONActionOrderFallsBackToDefault() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Write raw invalid JSON to the actionOrder key.
        suite.set(Data("not json".utf8), forKey: "settings.actionOrder")

        let store = SettingsStore(defaults: suite)
        #expect(store.actionOrder == SettingsStore.defaultBuiltinOrder)
    }

    // MARK: - toolbarZoom / zoomIncludesFontSize

    @Test("toolbarZoom defaults to .x1 on a fresh suite")
    func toolbarZoomDefaultsToX1() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(store.toolbarZoom == .x1)
    }

    @Test("zoomIncludesFontSize defaults to true on a fresh suite where the key was never set")
    func zoomIncludesFontSizeDefaultsTrue() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Verify the key has never been set — plain defaults.bool(_:) would return
        // false for a missing key, which would be the wrong default.
        #expect(suite.object(forKey: "settings.zoomIncludesFontSize") == nil)

        let store = SettingsStore(defaults: suite)
        #expect(store.zoomIncludesFontSize == true)
    }

    @Test("zoomIncludesFontSize false round-trips through UserDefaults")
    func zoomIncludesFontSizeRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store1 = SettingsStore(defaults: suite)
        store1.zoomIncludesFontSize = false

        // Re-load — explicitly stored false must be distinguished from "unset → true".
        let store2 = SettingsStore(defaults: suite)
        #expect(store2.zoomIncludesFontSize == false)
    }

    @Test("toolbarZoom round-trips through UserDefaults")
    func toolbarZoomRoundTrip() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store1 = SettingsStore(defaults: suite)
        store1.toolbarZoom = .x1_3

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.toolbarZoom == .x1_3)
    }

    @Test("toolbarZoom falls back to .x1 for an unknown stored raw value (e.g. the removed x1_5)")
    func toolbarZoomUnknownRawFallsBackToX1() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Simulate a value persisted by an older build before 1.5x was renamed to
        // 1.3x. The unknown raw value must decode to .x1, never crash.
        suite.set("x1_5", forKey: "settings.toolbarZoom")

        let store = SettingsStore(defaults: suite)
        #expect(store.toolbarZoom == .x1)
    }

    @Test("toolbarZoom scale and displayName match the defined levels")
    func toolbarZoomScaleAndDisplayName() {
        #expect(ToolbarZoom.x1.scale == 1.0)
        #expect(ToolbarZoom.x1_2.scale == 1.2)
        #expect(ToolbarZoom.x1_3.scale == 1.3)
        #expect(ToolbarZoom.x1.displayName == "1×")
        #expect(ToolbarZoom.x1_2.displayName == "1.2×")
        #expect(ToolbarZoom.x1_3.displayName == "1.3×")
    }

    // MARK: - enabledOrderedIdentifiers

    @Test("enabledOrderedIdentifiers excludes disabled built-in and disabled custom, preserving order")
    func enabledOrderedIdentifiersFiltersDisabled() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        // Disable speakEnabled (default is true).
        store.speakEnabled = false

        // Add one enabled and one disabled custom action.
        let enabledCustom  = CustomAction(title: "E", systemPrompt: "pe", isEnabled: true)
        let disabledCustom = CustomAction(title: "D", systemPrompt: "pd", isEnabled: false)
        store.addCustomAction(enabledCustom)
        store.addCustomAction(disabledCustom)

        let result = store.enabledOrderedIdentifiers
        // promptEnabled defaults to false, speakEnabled is now false, disabledCustom is disabled.
        // Expected order (from actionOrder) filtering enabled:
        //   .builtin(.improve)    ✓ enabled
        //   .builtin(.shorten)    ✓ enabled
        //   .builtin(.proofread)  ✓ enabled
        //   .builtin(.prompt)     ✗ disabled (default false)
        //   .builtin(.translate)  ✓ enabled
        //   .speak                ✗ disabled
        //   .custom(enabledCustom.id)  ✓ enabled
        //   .custom(disabledCustom.id) ✗ disabled
        let expected: [ActionIdentifier] = [
            .builtin(.improve),
            .builtin(.shorten),
            .builtin(.proofread),
            .builtin(.translate),
            .custom(enabledCustom.id),
        ]
        #expect(result == expected)
    }
}
