// MacOSBuiltinDictionaryProvider.swift
// PopGuy — DictionaryEngine
//
// Offline dictionary lookup via macOS Dictionary Services (CoreServices).
// Returns plain-text definitions only — no structured IPA/senses.

import CoreServices
import Foundation

// MARK: - MacOSBuiltinDictionaryProvider

nonisolated struct MacOSBuiltinDictionaryProvider: DictionaryProvider {
    func lookup(
        term: String,
        sourceLanguage: String?,
        definitionLanguage: String?
    ) async throws -> DictionaryEntry {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictionaryLookupError.notFound }

        let cfTerm = trimmed as CFString
        let range = DCSGetTermRangeInString(nil, cfTerm, 0)
        guard range.location != kCFNotFound, range.length > 0 else {
            throw DictionaryLookupError.notFound
        }

        guard let definition = DCSCopyTextDefinition(nil, cfTerm, range)?.takeRetainedValue() as String?,
              !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DictionaryLookupError.notFound
        }

        return .plainText(
            headword: trimmed,
            text: definition,
            sourceName: "macOS Dictionary"
        )
    }
}