// MinhqndDictionaryProvider.swift
// PopGuy — DictionaryEngine
//
// VI-focused dictionary lookup via dict.minhqnd.com JSON API.

import Foundation

// MARK: - MinhqndDictionaryProvider

nonisolated struct MinhqndDictionaryProvider: DictionaryProvider {
    private static let baseURL = "https://dict.minhqnd.com"

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

        guard var components = URLComponents(string: "\(Self.baseURL)/api/v1/lookup") else {
            throw DictionaryLookupError.network(underlying: "Invalid lookup URL")
        }
        var query: [URLQueryItem] = [
            URLQueryItem(name: "word", value: trimmed)
        ]
        if let sourceLanguage, !sourceLanguage.isEmpty {
            query.append(URLQueryItem(name: "lang", value: sourceLanguage))
        }
        if let definitionLanguage, !definitionLanguage.isEmpty {
            query.append(URLQueryItem(name: "def_lang", value: definitionLanguage))
        }
        components.queryItems = query

        guard let url = components.url else {
            throw DictionaryLookupError.network(underlying: "Invalid lookup URL")
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw DictionaryLookupError.network(underlying: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 {
                throw DictionaryLookupError.notFound
            }
            throw DictionaryLookupError.network(underlying: "HTTP \(http.statusCode)")
        }

        let payload: MinhqndResponse
        do {
            payload = try JSONDecoder().decode(MinhqndResponse.self, from: data)
        } catch {
            throw DictionaryLookupError.decoding(error.localizedDescription)
        }

        let resultItems = payload.results ?? []
        guard payload.exists == true, !resultItems.isEmpty else {
            throw DictionaryLookupError.notFound
        }

        let headword = payload.word ?? trimmed
        let lexicalEntries = resultItems.map { result in
            mapResult(result, headword: headword)
        }

        return DictionaryEntry(
            headword: headword,
            lexicalEntries: lexicalEntries,
            sourceName: "minhqnd",
            rawText: nil
        )
    }

    // MARK: - Mapping

    private func mapResult(_ result: MinhqndResult, headword: String) -> LexicalEntry {
        let synonyms = result.relations?
            .filter { Self.isSynonymRelation($0.relation_type) }
            .compactMap(\.related_word) ?? []

        let senses = (result.meanings ?? []).map { meaning in
            Sense(
                definition: meaning.definition ?? "",
                examples: [meaning.example].compactMap { $0 }.filter { !$0.isEmpty },
                synonyms: synonyms + (meaning.links ?? [])
            )
        }.filter { !$0.definition.isEmpty }

        let pronunciations = (result.pronunciations ?? []).compactMap { p -> Pronunciation? in
            guard let ipa = p.ipa, !ipa.isEmpty else { return nil }
            let tags = [p.region].compactMap { $0 }.filter { !$0.isEmpty }
            return Pronunciation(ipa: ipa, tags: tags)
        }

        let partOfSpeech = result.meanings?.compactMap(\.pos).first { !$0.isEmpty }

        return LexicalEntry(
            language: result.lang_name ?? result.lang_code,
            partOfSpeech: partOfSpeech,
            pronunciations: pronunciations,
            senses: senses,
            audioURL: Self.resolveAudioURL(audio: result.audio, langCode: result.lang_code, headword: headword)
        )
    }

    /// Resolve the source-native pronunciation URL for a result, enforcing https.
    ///
    /// Exposed as a static for unit testing without going through the network path.
    /// `audio` is untrusted external data — non-https schemes (http, data, file,
    /// javascript, …) are refused here (defense-in-depth alongside
    /// `DictionaryAudioEngine.play(urlString:)`'s scheme check).
    nonisolated static func resolveAudioURL(audio: String?, langCode: String?, headword: String) -> String? {
        if let audio = audio?.trimmingCharacters(in: .whitespacesAndNewlines),
           !audio.isEmpty {
            // Reject any explicit scheme other than https. Covers `http://`,
            // `data:`, `javascript:`, `file://`, etc. — anything where the URL
            // parses to a scheme that isn't https. The check runs on the raw
            // input first (so `data:…` / `javascript:…` never get prefixed),
            // then again on the candidate after prefixing relative paths.
            if Self.urlScheme(audio) != nil && !audio.hasPrefix("https://") {
                return nil
            }
            let candidate: String
            if audio.hasPrefix("https://") {
                candidate = audio
            } else if audio.hasPrefix("/") {
                candidate = baseURL + audio
            } else {
                candidate = "\(baseURL)/\(audio)"
            }
            guard let url = URL(string: candidate), url.scheme == "https" else { return nil }
            return candidate
        }
        guard let lang = langCode, !lang.isEmpty else { return nil }
        // Build with URLComponents so query delimiters in untrusted values (a
        // lang_code or headword containing "&"/"=") are escaped. Manual interpolation
        // with .urlQueryAllowed leaves those separators intact, which would let a
        // crafted response inject extra query parameters.
        guard var components = URLComponents(string: "\(baseURL)/api/v1/tts") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "word", value: headword),
            URLQueryItem(name: "lang", value: lang)
        ]
        guard let url = components.url, url.scheme == "https" else { return nil }
        return url.absoluteString
    }

    /// Returns the URL scheme of `string` if it parses as a URL with one.
    /// Used to detect explicit non-https schemes embedded in the audio string.
    nonisolated static func urlScheme(_ string: String) -> String? {
        URL(string: string)?.scheme
    }

    /// Static helper for unit testing without going through the network path.
    nonisolated static func isSynonymRelation(_ type: String?) -> Bool {
        guard let type = type?.lowercased() else { return false }
        return type == "synonym" || type.contains("đồng nghĩa")
    }
}

// MARK: - JSON models

private nonisolated struct MinhqndResponse: Decodable {
    let exists: Bool?
    let word: String?
    let results: [MinhqndResult]?
}

private nonisolated struct MinhqndResult: Decodable {
    let lang_code: String?
    let lang_name: String?
    let audio: String?
    let meanings: [MinhqndMeaning]?
    let pronunciations: [MinhqndPronunciation]?
    let relations: [MinhqndRelation]?
}

private nonisolated struct MinhqndMeaning: Decodable {
    let definition: String?
    let example: String?
    let pos: String?
    let links: [String]?
}

private nonisolated struct MinhqndPronunciation: Decodable {
    let ipa: String?
    let region: String?
}

private nonisolated struct MinhqndRelation: Decodable {
    let related_word: String?
    let relation_type: String?
}