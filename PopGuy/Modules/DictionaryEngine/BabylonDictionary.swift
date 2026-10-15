// BabylonDictionary.swift
// PopGuy — DictionaryEngine
//
// Persisted metadata and searchable index types for user-loaded Babylon .bgl files.

import Foundation

// MARK: - BabylonDictionary

/// User-loaded Babylon dictionary metadata.
///
/// The file itself stays on disk; PopGuy persists the path plus user-declared
/// language mapping and builds a searchable index when needed.
nonisolated struct BabylonDictionary: Sendable, Codable, Equatable, Identifiable {
    var id: UUID
    var displayName: String
    var filePath: String
    var isEnabled: Bool
    var entryCount: Int
    /// User-declared source (headword) language code, e.g. "en". Empty when unset.
    var sourceLanguage: String
    /// User-declared definition (target) language code, e.g. "vi". Empty when unset.
    var targetLanguage: String

    init(
        id: UUID = UUID(),
        displayName: String,
        filePath: String,
        isEnabled: Bool = true,
        entryCount: Int = 0,
        sourceLanguage: String = "",
        targetLanguage: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.filePath = filePath
        self.isEnabled = isEnabled
        self.entryCount = entryCount
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }

    /// Backward-compatible decoding: blobs persisted before the language fields
    /// existed (SettingsStore) lack these keys, so they
    /// default to empty instead of failing to decode.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        filePath = try c.decode(String.self, forKey: .filePath)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        entryCount = try c.decode(Int.self, forKey: .entryCount)
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? ""
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? ""
    }

    nonisolated var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let fileName = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        return fileName.isEmpty ? "Babylon Dictionary" : fileName
    }
}

// MARK: - BabylonBGLEntry

/// A single indexed BGL entry. Definitions are kept as source-derived text with
/// common HTML layout markers normalized to line breaks.
nonisolated struct BabylonBGLEntry: Sendable, Codable, Equatable {
    let headword: String
    let definition: String
    let alternates: [String]
}

// MARK: - BabylonBGLIndex

/// Case-insensitive lookup index for one loaded BGL dictionary.
nonisolated struct BabylonBGLIndex: Sendable, Equatable {
    let dictionary: BabylonDictionary
    let entries: [BabylonBGLEntry]
    let termIndex: [String: [Int]]

    init(dictionary: BabylonDictionary, entries: [BabylonBGLEntry]) {
        self.dictionary = dictionary
        self.entries = entries
        self.termIndex = Self.makeTermIndex(entries: entries)
    }

    nonisolated var entryCount: Int { entries.count }

    nonisolated func lookup(term: String) -> [BabylonBGLEntry] {
        (termIndex[Self.normalizedTerm(term)] ?? []).compactMap { index in
            guard entries.indices.contains(index) else { return nil }
            return entries[index]
        }
    }

    private static func makeTermIndex(entries: [BabylonBGLEntry]) -> [String: [Int]] {
        var mapped: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            for term in lookupTerms(for: entry) {
                mapped[term, default: []].append(index)
            }
        }
        return mapped
    }

    /// Normalized headword + alternates for one entry: empty terms skipped,
    /// duplicates removed, first-occurrence order kept.
    nonisolated static func lookupTerms(for entry: BabylonBGLEntry) -> [String] {
        var seen: Set<String> = []
        var terms: [String] = []
        for term in [entry.headword] + entry.alternates {
            let normalized = normalizedTerm(term)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            terms.append(normalized)
        }
        return terms
    }

    /// The folding locale is pinned (not the user's current locale) because
    /// normalized terms are persisted on disk and must stay stable across locales.
    nonisolated static func normalizedTerm(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }
}
