// DictionaryEngine.swift
// PopGuy — DictionaryEngine
//
// Performs typed dictionary lookups through one provider or all providers.
//
// ISOLATION CHOICE: DictionaryEngine is nonisolated (a plain struct).
// Configuration is captured as Sendable values before calling lookup().

import Foundation

// MARK: - DictionaryEngine

/// Resolves and dispatches dictionary lookups.
nonisolated struct DictionaryEngine: Sendable {
    private let providerFactory: @Sendable (DictionaryProviderKind) -> any DictionaryProvider

    init(
        providerFactory: @escaping @Sendable (DictionaryProviderKind) -> any DictionaryProvider = {
            DictionaryProviderFactory.make($0)
        }
    ) {
        self.providerFactory = providerFactory
    }

    func lookup(
        term: String,
        config: DictionaryConfig,
        babylonDictionaries: [BabylonDictionary] = []
    ) async throws -> DictionaryEntry {
        let provider = makeProvider(for: config.provider, babylonDictionaries: babylonDictionaries)
        return try await provider.lookup(
            term: term,
            sourceLanguage: nil,
            definitionLanguage: config.definitionLanguage
        )
    }

    /// Looks up a term across every dictionary provider concurrently.
    ///
    /// Providers that return `.notFound` are omitted. If any provider succeeds,
    /// provider errors are suppressed so useful definitions can still be shown.
    /// If no provider succeeds, a real provider error wins over the aggregate
    /// not-found state.
    func lookupAll(
        term: String,
        config: DictionaryConfig,
        babylonDictionaries: [BabylonDictionary] = []
    ) async throws -> [DictionaryProviderResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictionaryLookupError.notFound }

        let hasEnabledBabylonDictionary = babylonDictionaries.contains { $0.isEnabled }
        let kinds = DictionaryProviderKind.allCases.filter {
            if $0 == .babylonBGL {
                return hasEnabledBabylonDictionary
                    && $0.canParticipateInLookupAll(definitionLanguage: config.definitionLanguage)
            }
            return $0.canParticipateInLookupAll(definitionLanguage: config.definitionLanguage)
        }
        let outcomes = await withTaskGroup(
            of: DictionaryProviderLookupOutcome.self,
            returning: [DictionaryProviderLookupOutcome].self
        ) { group in
            for kind in kinds {
                let provider = makeProvider(for: kind, babylonDictionaries: babylonDictionaries)
                group.addTask {
                    do {
                        let entry = try await provider.lookup(
                            term: trimmed,
                            sourceLanguage: nil,
                            definitionLanguage: config.definitionLanguage
                        )
                        return .success(DictionaryProviderResult(providerKind: kind, entry: entry))
                    } catch DictionaryLookupError.notFound {
                        return .notFound(kind)
                    } catch let error as DictionaryLookupError {
                        return .failure(kind, error)
                    } catch {
                        return .failure(kind, .network(underlying: error.localizedDescription))
                    }
                }
            }

            var collected: [DictionaryProviderLookupOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        let successesByKind = Dictionary(
            uniqueKeysWithValues: outcomes.compactMap { outcome -> (DictionaryProviderKind, DictionaryProviderResult)? in
                guard case .success(let result) = outcome else { return nil }
                return (result.providerKind, result)
            }
        )
        let successes = kinds.compactMap { successesByKind[$0] }
        if !successes.isEmpty {
            return successes
        }

        if let firstFailure = outcomes.compactMap({ $0.failureError }).first {
            throw firstFailure
        }

        throw DictionaryLookupError.notFound
    }

    private func makeProvider(
        for kind: DictionaryProviderKind,
        babylonDictionaries: [BabylonDictionary]
    ) -> any DictionaryProvider {
        switch kind {
        case .babylonBGL:
            BabylonBGLDictionaryProvider(dictionaries: babylonDictionaries)
        case .macOSBuiltin, .minhqnd, .freeDictionaryAPI:
            providerFactory(kind)
        }
    }
}

private enum DictionaryProviderLookupOutcome: Sendable {
    case success(DictionaryProviderResult)
    case notFound(DictionaryProviderKind)
    case failure(DictionaryProviderKind, DictionaryLookupError)

    nonisolated var failureError: DictionaryLookupError? {
        guard case .failure(_, let error) = self else { return nil }
        return error
    }
}
