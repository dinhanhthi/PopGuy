// LocalModelCatalogTests.swift
// PopGuyTests
//
// Tests for LocalModelCatalog — the static curated on-device model catalog.

import CryptoKit
import Foundation
import Testing
@testable import PopGuy

@Suite("LocalModelCatalog")
struct LocalModelCatalogTests {

    // MARK: - Unique ids

    @Test("all model ids are unique")
    func uniqueModelIDs() {
        let ids = LocalModelCatalog.all.map(\.id)
        let unique = Set(ids)
        #expect(ids.count == unique.count)
    }

    // MARK: - Lookup

    @Test("every catalog entry is resolvable via model(for:)")
    func everyEntryResolvable() {
        for model in LocalModelCatalog.all {
            let found = LocalModelCatalog.model(for: model.id)
            #expect(found != nil, "Expected to find model with id '\(model.id)'")
            #expect(found?.id == model.id)
        }
    }

    @Test("model(for:) returns nil for unknown id")
    func lookupUnknownIDReturnsNil() {
        let result = LocalModelCatalog.model(for: "nonexistent-model")
        #expect(result == nil)
    }

    // MARK: - Catalog size

    @Test("catalog contains the expected 9 models")
    func catalogSize() {
        #expect(LocalModelCatalog.all.count == 9)
    }

    @Test("humanizer is appended last; onboarding default stays first")
    func humanizerLastDefaultFirst() {
        #expect(LocalModelCatalog.all.last?.id == "humanizer-12b")
        #expect(LocalModelCatalog.all.first?.id == "gemma-4-e2b")
    }

    // MARK: - Family assignments

    @Test("gemma models have .gemma family")
    func gemmaModelsHaveGemmaFamily() {
        let gemmaModels = LocalModelCatalog.all.filter { $0.id.hasPrefix("gemma") }
        #expect(!gemmaModels.isEmpty)
        for model in gemmaModels {
            #expect(model.family == .gemma, "Expected .gemma family for '\(model.id)'")
        }
    }

    @Test("qwen models have .qwen family")
    func qwenModelsHaveQwenFamily() {
        let qwenModels = LocalModelCatalog.all.filter { $0.id.hasPrefix("qwen") }
        #expect(!qwenModels.isEmpty)
        for model in qwenModels {
            #expect(model.family == .qwen, "Expected .qwen family for '\(model.id)'")
        }
    }

    @Test("non-Gemma, non-Qwen models have .other family")
    func otherModelsHaveOtherFamily() {
        #expect(LocalModelCatalog.model(for: "llama-3.2-3b")?.family == .other)
    }

    // MARK: - Size fields

    @Test("all models have positive approxSizeBytes and minRAMBytes")
    func positiveSizeFields() {
        for model in LocalModelCatalog.all {
            #expect(model.approxSizeBytes > 0, "Expected positive approxSizeBytes for '\(model.id)'")
            #expect(model.minRAMBytes > 0,     "Expected positive minRAMBytes for '\(model.id)'")
        }
    }

    // MARK: - CompletionPrompt

    @Test("humanizer prompt matches the model authors' reference fingerprint")
    func humanizerPromptFingerprint() {
        let prompt = CompletionPrompt.humanizer.build(draft: "X")
        let hex = SHA256.hash(data: Data(prompt.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(hex.prefix(16) == "cc51d66b4c593fbe")
    }

    @Test("build trims surrounding whitespace and newlines from the draft")
    func buildTrimsDraft() {
        let prompt = CompletionPrompt.humanizer
        #expect(prompt.build(draft: "  \n X \n\t") == prompt.build(draft: "X"))
    }

    @Test("maxNewTokens leaves room for a rewrite of the longest allowed draft")
    func maxNewTokensBounds() {
        let prompt = CompletionPrompt.humanizer
        let longDraft = String(repeating: "a", count: prompt.maxInputCharacters)
        #expect(prompt.maxNewTokens(forDraft: longDraft) >= 2048)
        let short = prompt.maxNewTokens(forDraft: "X")
        #expect(short <= 8192)
        #expect(short >= 256)
    }

    // MARK: - selectableModels

    @Test("dedicated model is hidden unless the matching preset asks for it")
    func selectableModelsDedicatedFilter() {
        let installed: Set<String> = ["gemma-4-e2b", "humanizer-12b"]
        let forNil = LocalModelCatalog.selectableModels(installed: installed, presetID: nil).map(\.id)
        let forOther = LocalModelCatalog.selectableModels(installed: installed, presetID: "other").map(\.id)
        let forHumanize = LocalModelCatalog.selectableModels(installed: installed, presetID: "ai.humanize").map(\.id)
        #expect(forNil == ["gemma-4-e2b"])
        #expect(forOther == ["gemma-4-e2b"])
        #expect(forHumanize == ["gemma-4-e2b", "humanizer-12b"])
    }

    @Test("non-installed models are never selectable")
    func selectableModelsOnlyInstalled() {
        #expect(LocalModelCatalog.selectableModels(installed: [], presetID: "ai.humanize").isEmpty)
        let ids = LocalModelCatalog.selectableModels(installed: ["qwen3.5-4b"], presetID: nil).map(\.id)
        #expect(ids == ["qwen3.5-4b"])
    }

    @Test("curatedModels lists every general-purpose model but never a dedicated one")
    func curatedModelsExcludeDedicated() {
        let curated = ProviderKind.mlxLocal.curatedModels
        #expect(!curated.contains("humanizer-12b"))
        #expect(curated == LocalModelCatalog.all.filter { $0.dedicatedPresetID == nil }.map(\.id))
        #expect(curated.first == "gemma-4-e2b")
    }
}
