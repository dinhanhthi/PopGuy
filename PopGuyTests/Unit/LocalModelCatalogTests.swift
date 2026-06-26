// LocalModelCatalogTests.swift
// PopGuyTests
//
// Tests for LocalModelCatalog — the static curated on-device model catalog.

import Foundation
import Testing
@testable import PopGuy

@Suite("LocalModelCatalog")
struct LocalModelCatalogTests {

    // MARK: - Free-tier (via ProConfig — single source of truth)

    @Test("exactly one model is free per ProConfig")
    func exactlyOneFreeTierModel() {
        let freeTier = LocalModelCatalog.all.filter { ProConfig.isLocalModelFree($0.id) }
        #expect(freeTier.count == 1)
        #expect(freeTier.first?.id == "gemma-4-e2b",
                "Expected gemma-4-e2b to be the free model; ProConfig.freeLocalModelIDs = \(ProConfig.freeLocalModelIDs)")
    }

    @Test("isFreeTier property delegates to ProConfig")
    func isFreeTierDelegatesToProConfig() {
        for model in LocalModelCatalog.all {
            #expect(model.isFreeTier == ProConfig.isLocalModelFree(model.id),
                    "isFreeTier mismatch for \(model.id)")
        }
    }

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

    @Test("catalog contains the expected 5 models")
    func catalogSize() {
        #expect(LocalModelCatalog.all.count == 5)
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

    // MARK: - Size fields

    @Test("all models have positive approxSizeBytes and minRAMBytes")
    func positiveSizeFields() {
        for model in LocalModelCatalog.all {
            #expect(model.approxSizeBytes > 0, "Expected positive approxSizeBytes for '\(model.id)'")
            #expect(model.minRAMBytes > 0,     "Expected positive minRAMBytes for '\(model.id)'")
        }
    }
}
