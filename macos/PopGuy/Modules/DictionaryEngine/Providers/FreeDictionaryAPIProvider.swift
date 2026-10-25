// FreeDictionaryAPIProvider.swift
// PopGuy — DictionaryEngine
//
// EN/FR/ES dictionary lookup via freedictionaryapi.com (Wiktionary-backed).

import Foundation

// MARK: - FreeDictionaryAPIProvider

nonisolated struct FreeDictionaryAPIProvider: DictionaryProvider {
    private static let baseURL = "https://freedictionaryapi.com/api/v1/entries"

    /// Ephemeral session with a short timeout — the toolbar is staring at the user
    /// while a lookup is in flight, so the shared session's 60s default is far too
    /// long. Mirrors `DictionaryAudioEngine`'s ephemeral + 4s request timeout.
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    private let session: URLSession

    /// Production initializer — uses the shared ephemeral session.
    init() {
        self.session = Self.defaultSession
    }

    /// Test-only initializer — injects a session configured with a custom
    /// `URLProtocol` to stub responses without hitting the network.
    init(session: URLSession) {
        self.session = session
    }

    func lookup(
        term: String,
        sourceLanguage: String?,
        definitionLanguage: String?
    ) async throws -> DictionaryEntry {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictionaryLookupError.notFound }

        let sourceLang = sourceLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defLang = definitionLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let language: String
        if let sourceLang, !sourceLang.isEmpty {
            language = sourceLang
        } else if let defLang, !defLang.isEmpty {
            language = defLang
        } else {
            language = "en"
        }

        guard
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "\(Self.baseURL)/\(language)/\(encoded)")
        else {
            throw DictionaryLookupError.network(underlying: "Invalid lookup URL")
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw DictionaryLookupError.network(underlying: "Non-HTTP response")
        }
        if http.statusCode == 429 {
            throw DictionaryLookupError.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 {
                throw DictionaryLookupError.notFound
            }
            throw DictionaryLookupError.network(underlying: "HTTP \(http.statusCode)")
        }

        let payload: FreeDictResponse
        do {
            payload = try JSONDecoder().decode(FreeDictResponse.self, from: data)
        } catch {
            throw DictionaryLookupError.decoding(error.localizedDescription)
        }

        let entries = payload.entries ?? []
        guard !entries.isEmpty else { throw DictionaryLookupError.notFound }

        let headword = payload.word ?? trimmed
        let lexicalEntries = entries.map(mapEntry)

        return DictionaryEntry(
            headword: headword,
            lexicalEntries: lexicalEntries,
            sourceName: "Free Dictionary API",
            rawText: nil
        )
    }

    // MARK: - Mapping

    private func mapEntry(_ entry: FreeDictEntry) -> LexicalEntry {
        let pronunciations = (entry.pronunciations ?? []).compactMap { p -> Pronunciation? in
            guard let ipa = p.text, !ipa.isEmpty else { return nil }
            return Pronunciation(ipa: ipa, tags: p.tags ?? [])
        }

        let entrySynonyms = entry.synonyms ?? []
        let senses = (entry.senses ?? []).compactMap { sense -> Sense? in
            guard let definition = sense.definition, !definition.isEmpty else { return nil }
            let examples = (sense.examples ?? []).filter { !$0.isEmpty }
            let synonyms = (sense.synonyms ?? []) + entrySynonyms
            return Sense(definition: definition, examples: examples, synonyms: synonyms)
        }

        return LexicalEntry(
            language: entry.language?.name ?? entry.language?.code,
            partOfSpeech: entry.partOfSpeech,
            pronunciations: pronunciations,
            senses: senses,
            audioURL: nil
        )
    }
}

// MARK: - JSON models

private nonisolated struct FreeDictResponse: Decodable {
    let word: String?
    let entries: [FreeDictEntry]?
}

private nonisolated struct FreeDictEntry: Decodable {
    let language: FreeDictLanguage?
    let partOfSpeech: String?
    let pronunciations: [FreeDictPronunciation]?
    let senses: [FreeDictSense]?
    let synonyms: [String]?
}

private nonisolated struct FreeDictLanguage: Decodable {
    let code: String?
    let name: String?
}

private nonisolated struct FreeDictPronunciation: Decodable {
    let text: String?
    let tags: [String]?
}

private nonisolated struct FreeDictSense: Decodable {
    let definition: String?
    let examples: [String]?
    let synonyms: [String]?
}