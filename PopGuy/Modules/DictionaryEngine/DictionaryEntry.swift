// DictionaryEntry.swift
// PopGuy — DictionaryEngine
//
// Typed dictionary lookup result shared by all DictionaryProvider adapters.
// Supports structured entries (API sources) and a plain-text degraded variant
// (macOS built-in Dictionary Services).
//
// Isolation: nonisolated / Sendable value types — cross actor boundaries without
// issue under Swift 6 strict concurrency.

import Foundation

// MARK: - DictionaryEntry

/// A dictionary lookup result with optional structured lexical data.
nonisolated struct DictionaryEntry: Sendable, Equatable {
    let headword: String
    let lexicalEntries: [LexicalEntry]
    let sourceName: String
    /// Set when the source only provides unstructured plain text (e.g. macOS built-in).
    let rawText: String?

    /// The first native pronunciation audio URL across all lexical entries.
    var primaryAudioURL: String? {
        lexicalEntries.compactMap(\.audioURL).first
    }

    /// True when the entry has no structured lexical data and only `rawText`.
    var isPlainTextOnly: Bool {
        lexicalEntries.isEmpty && rawText != nil
    }

    /// Plain-text degraded entry for sources that return unstructured definitions.
    static func plainText(headword: String, text: String, sourceName: String) -> DictionaryEntry {
        DictionaryEntry(
            headword: headword,
            lexicalEntries: [],
            sourceName: sourceName,
            rawText: text
        )
    }
}

// MARK: - DictionaryProviderResult

/// A successful definition from one dictionary provider.
nonisolated struct DictionaryProviderResult: Sendable, Equatable, Identifiable {
    let providerKind: DictionaryProviderKind
    let entry: DictionaryEntry

    var id: DictionaryProviderKind { providerKind }
}

// MARK: - LexicalEntry

/// One lexical grouping (language / part-of-speech) within a dictionary entry.
nonisolated struct LexicalEntry: Sendable, Equatable {
    let language: String?
    let partOfSpeech: String?
    let pronunciations: [Pronunciation]
    let senses: [Sense]
    /// Native pronunciation audio URL from the source (https only at playback time).
    let audioURL: String?
}

// MARK: - Pronunciation

/// A single phonetic representation with optional region/type tags.
nonisolated struct Pronunciation: Sendable, Equatable {
    let ipa: String
    let tags: [String]
}

// MARK: - Sense

/// One definition sense with optional examples and synonyms.
nonisolated struct Sense: Sendable, Equatable {
    let definition: String
    let examples: [String]
    let synonyms: [String]
}
