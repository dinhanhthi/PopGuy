// ModelDeprecationsTests.swift
// PopGuyTests
//
// Unit tests for the per-provider deprecated-model replacement maps and the
// migratedModel helpers on ProviderKind and TTSProviderKind.

import Foundation
import Testing
@testable import PopGuy

// MARK: - ModelDeprecationsTests

@Suite("ModelDeprecations")
struct ModelDeprecationsTests {

    // MARK: - ProviderKind spot checks

    @Test("OpenAI: gpt-5.4-nano migrates to gpt-6-luna")
    func openAINanoMigrates() {
        #expect(ProviderKind.openAI.migratedModel("gpt-5.4-nano") == "gpt-6-luna")
    }

    @Test("OpenAI: legacy-but-active gpt-5.5 is unchanged")
    func openAIGpt55Unchanged() {
        #expect(ProviderKind.openAI.migratedModel("gpt-5.5") == "gpt-5.5")
    }

    @Test("Codex CLI: gpt-5.5 migrates to gpt-6.1-sol")
    func codexGpt55Migrates() {
        #expect(ProviderKind.codexCLI.migratedModel("gpt-5.5") == "gpt-6.1-sol")
    }

    @Test("Codex CLI inherits the OpenAI map")
    func codexInheritsOpenAIMap() {
        #expect(ProviderKind.codexCLI.migratedModel("gpt-5.4-nano") == "gpt-6-luna")
    }

    @Test("Codex CLI overrides win over the inherited OpenAI entry")
    func codexOverrideWins() {
        #expect(ProviderKind.codexCLI.migratedModel("gpt-5.3-codex") == "gpt-6.1-sol")
    }

    @Test("Anthropic and Claude CLI: dated Sonnet 4.5 migrates to claude-sonnet-5-5")
    func anthropicSonnet45Migrates() {
        #expect(ProviderKind.anthropic.migratedModel("claude-sonnet-4-5-20250929") == "claude-sonnet-5-5")
        #expect(ProviderKind.claudeCLI.migratedModel("claude-sonnet-4-5-20250929") == "claude-sonnet-5-5")
    }

    @Test("Anthropic: legacy-but-active claude-opus-4-8 is unchanged")
    func anthropicOpus48Unchanged() {
        #expect(ProviderKind.anthropic.migratedModel("claude-opus-4-8") == "claude-opus-4-8")
    }

    @Test("Gemini: never-valid gemini-3.1-pro migrates to gemini-4-argon")
    func geminiProMigrates() {
        #expect(ProviderKind.gemini.migratedModel("gemini-3.1-pro") == "gemini-4-argon")
    }

    @Test("Gemini CLI: never-valid gemini-3-pro migrates to gemini-3.1-pro-preview")
    func geminiCLIProMigrates() {
        #expect(ProviderKind.geminiCLI.migratedModel("gemini-3-pro") == "gemini-3.1-pro-preview")
    }

    @Test("OpenRouter: never-valid anthropic/claude-opus-4-8 migrates to anthropic/claude-opus-5.5")
    func openRouterOpusMigrates() {
        #expect(ProviderKind.openRouter.migratedModel("anthropic/claude-opus-4-8") == "anthropic/claude-opus-5.5")
    }

    @Test("Whitespace-padded deprecated id migrates")
    func paddedIdMigrates() {
        #expect(ProviderKind.openAI.migratedModel("  gpt-5.4-nano\n") == "gpt-6-luna")
    }

    @Test("Unknown id is returned unchanged")
    func unknownIdUnchanged() {
        #expect(ProviderKind.openAI.migratedModel("my-fine-tune") == "my-fine-tune")
        #expect(ProviderKind.openAI.migratedModel("") == "")
    }

    @Test("GLM: glm-4.7 is unchanged")
    func glmUnchanged() {
        #expect(ProviderKind.glm.migratedModel("glm-4.7") == "glm-4.7")
    }

    // MARK: - TTSProviderKind spot checks

    @Test("OpenAI TTS: tts-1-hd migrates to gpt-4o-mini-tts")
    func ttsHDMigrates() {
        #expect(TTSProviderKind.openAITTS.migratedModel("tts-1-hd") == "gpt-4o-mini-tts")
    }

    @Test("OpenAI TTS: nil model stays nil")
    func ttsNilStaysNil() {
        #expect(TTSProviderKind.openAITTS.migratedModel(nil) == nil)
    }

    // MARK: - Invariants

    @Test("No replacement is itself a deprecated key (no chains)", arguments: ProviderKind.allCases)
    func noChains(kind: ProviderKind) {
        let map = kind.deprecatedModelReplacements
        for (key, value) in map {
            #expect(map[value] == nil, "\(kind): \(key) -> \(value) is itself a key")
        }
    }

    @Test("No deprecated key is offered in curatedModels", arguments: ProviderKind.allCases)
    func noKeyInCuratedModels(kind: ProviderKind) {
        let map = kind.deprecatedModelReplacements
        for model in kind.curatedModels {
            #expect(map[model] == nil, "\(kind): curated \(model) is deprecated")
        }
    }

    @Test("TTS: no replacement is itself a deprecated key (no chains)", arguments: TTSProviderKind.allCases)
    func ttsNoChains(kind: TTSProviderKind) {
        let map = kind.deprecatedModelReplacements
        for (key, value) in map {
            #expect(map[value] == nil, "\(kind): \(key) -> \(value) is itself a key")
        }
    }

    @Test("TTS: no deprecated key is offered in curatedModels", arguments: TTSProviderKind.allCases)
    func ttsNoKeyInCuratedModels(kind: TTSProviderKind) {
        let map = kind.deprecatedModelReplacements
        for model in kind.curatedModels {
            #expect(map[model] == nil, "\(kind): curated \(model) is deprecated")
        }
    }

    @Test("TTS: defaultModel is not a deprecated key", arguments: TTSProviderKind.allCases)
    func ttsDefaultModelNotDeprecated(kind: TTSProviderKind) {
        guard let model = kind.defaultModel else { return }
        #expect(kind.deprecatedModelReplacements[model] == nil)
    }
}
