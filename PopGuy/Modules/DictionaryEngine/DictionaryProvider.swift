// DictionaryProvider.swift
// PopGuy — DictionaryEngine
//
// Core protocol for dictionary lookup adapters. Separate from the LLM Provider
// abstraction — dictionaries return typed DictionaryEntry values, not streamed
// tokens.
//
// Constraint: Swift 6 strict concurrency — protocol and all conformers must be Sendable.

import Foundation

// MARK: - DictionaryProvider

/// A pluggable dictionary lookup source.
///
/// Each conformer encapsulates source-specific knowledge (local Dictionary
/// Services, REST API shape, response mapping). Callers (DictionaryEngine) only
/// see this protocol.
nonisolated protocol DictionaryProvider: Sendable {
    func lookup(
        term: String,
        sourceLanguage: String?,
        definitionLanguage: String?
    ) async throws -> DictionaryEntry
}

// MARK: - DictionaryProviderKind

/// Identifies a v1 dictionary source.
nonisolated enum DictionaryProviderKind: String, Sendable, Codable, CaseIterable, Hashable {
    case macOSBuiltin
    case minhqnd
    case freeDictionaryAPI
    case babylonBGL
}

extension DictionaryProviderKind {
    nonisolated var displayName: String {
        switch self {
        case .macOSBuiltin:      return "macOS Dictionary"
        case .minhqnd:           return "minhqnd"
        case .freeDictionaryAPI: return "Free Dictionary API"
        case .babylonBGL:        return "Babylon (BGL)"
        }
    }

    nonisolated var shortName: String {
        switch self {
        case .macOSBuiltin:      return "macOS"
        case .minhqnd:           return "minhqnd"
        case .freeDictionaryAPI: return "Free API"
        case .babylonBGL:        return "Babylon"
        }
    }

    nonisolated var iconSystemName: String {
        switch self {
        case .macOSBuiltin:      return "book.closed"
        case .minhqnd:           return "globe"
        case .freeDictionaryAPI: return "character.book.closed"
        case .babylonBGL:        return "book.closed"
        }
    }

    nonisolated var requiresNetwork: Bool {
        switch self {
        case .macOSBuiltin, .babylonBGL: return false
        case .minhqnd, .freeDictionaryAPI: return true
        }
    }

    nonisolated var languageHint: String {
        switch self {
        case .macOSBuiltin:      return "Installed macOS dictionaries, untargeted"
        case .minhqnd:           return "VI / EN / ZH"
        case .freeDictionaryAPI: return "EN / FR / ES via Wiktionary"
        case .babylonBGL:        return "User-loaded .bgl files"
        }
    }

    /// Whether this provider should appear in the multi-provider result set.
    /// macOS Dictionary Services returns the system's best local definition,
    /// so PopGuy only shows it for English or untargeted lookups.
    nonisolated func canParticipateInLookupAll(definitionLanguage: String?) -> Bool {
        guard let definitionLanguage = definitionLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !definitionLanguage.isEmpty
        else {
            return true
        }

        switch self {
        case .macOSBuiltin:
            return definitionLanguage == "en"
        case .minhqnd, .freeDictionaryAPI, .babylonBGL:
            return true
        }
    }
}

// MARK: - DictionaryLookupError

/// Errors surfaced by dictionary providers and DictionaryEngine.
nonisolated enum DictionaryLookupError: Error, Sendable, Equatable {
    case notFound
    case network(underlying: String)
    case rateLimited
    case decoding(String)
}
