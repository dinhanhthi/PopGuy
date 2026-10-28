// DeepLProvider.swift
// PopGuy — ProviderLayer/Adapters
//
// Provider adapter for DeepL Translation API (non-streaming).
//
// Verified API contract:
//   Free tier: POST https://api-free.deepl.com/v2/translate
//   Pro tier:  POST https://api.deepl.com/v2/translate
//   Headers: Authorization: DeepL-Auth-Key <key>, Content-Type: application/json
//   Body: { "text": [<input>], "target_lang": "<UPPERCASE>", "source_lang": <optional> }
//   Response: { "translations": [{ "text": "<result>", "detected_source_language": "<lang>" }] }
//
// Non-streaming: the result is wrapped as a single-element AsyncThrowingStream.
//
// Tier detection: DeepL free-tier keys end with ":fx". The caller may also
// pass `isPro` explicitly; the default infers from the key suffix.
//
// JSON parsing uses JSONSerialization (not Codable) — cleaner for dynamic
// API responses with optional fields; no additional types needed.

import Foundation

// MARK: - DeepLProvider

/// Translates text via the DeepL API (non-streaming, single-element stream output).
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct DeepLProvider: Provider {

    private let apiKey: String
    private let isPro: Bool
    private let httpClient: HTTPClient

    private static let freeBaseURL = "https://api-free.deepl.com/v2/translate"
    private static let proBaseURL  = "https://api.deepl.com/v2/translate"

    /// Create a DeepL provider.
    /// - Parameters:
    ///   - apiKey: DeepL authentication key.
    ///   - isPro: If `nil` (default), infers pro/free from the key's `:fx` suffix.
    ///   - session: URLSession for injection in tests.
    init(apiKey: String, isPro: Bool? = nil, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.apiKey = apiKey
        // Free-tier keys end in ":fx"; everything else is assumed pro.
        self.isPro = isPro ?? !apiKey.hasSuffix(":fx")
        self.httpClient = HTTPClient(session: session)
    }

    // MARK: - Provider

    func stream(
        systemPrompt: String?,
        input: String,
        model: String,
        options: ProviderOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let targetLang = options.targetLanguage, !targetLang.isEmpty else {
            throw ProviderError.missingOption("targetLanguage is required for DeepL translation")
        }

        let request = try DeepLProvider.makeRequest(
            apiKey: apiKey,
            isPro: isPro,
            input: input,
            targetLanguage: targetLang,
            sourceLanguage: options.sourceLanguage,
            formality: options.formality
        )

        let data = try await httpClient.rawData(for: request)
        let text = try DeepLProvider.parseTranslation(from: data)

        // Wrap the single result as a one-element stream.
        return AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }

    // MARK: - Request builder (internal; also used by tests)

    static func makeRequest(
        apiKey: String,
        isPro: Bool,
        input: String,
        targetLanguage: String,
        sourceLanguage: String?,
        formality: String? = nil
    ) throws -> URLRequest {
        let urlString = isPro ? proBaseURL : freeBaseURL
        guard let url = URL(string: urlString) else {
            throw ProviderError.transport("Invalid DeepL URL")
        }

        var body: [String: Any] = [
            "text": [input],
            // DeepL requires uppercase language codes (e.g. "EN", "FR", "VI").
            "target_lang": targetLanguage.uppercased()
        ]
        if let src = sourceLanguage {
            body["source_lang"] = src.uppercased()
        }
        // formality steers the register (e.g. "tu" vs "vous" in French). The
        // "prefer_*" values are silently ignored by DeepL for target languages
        // without formality support, so no per-language gating is needed here.
        if let formality, !formality.isEmpty {
            body["formality"] = formality
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Key validation request

    /// Build a lightweight authenticated request used to verify an API key
    /// before saving it. Hits `GET /v2/usage`, which only checks that the key
    /// authenticates and returns the account's quota — no translation
    /// performed. A 403 indicates an invalid key. The free/pro endpoint is
    /// inferred from the `:fx` suffix, matching the translation path.
    static func makeValidationRequest(apiKey: String, isPro: Bool? = nil) throws -> URLRequest {
        let pro = isPro ?? !apiKey.hasSuffix(":fx")
        let urlString = pro
            ? "https://api.deepl.com/v2/usage"
            : "https://api-free.deepl.com/v2/usage"
        guard let url = URL(string: urlString) else {
            throw ProviderError.transport("Invalid DeepL usage URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: - Response parser

    /// Parse `translations[0].text` from the raw DeepL response body.
    static func parseTranslation(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = json["translations"] as? [[String: Any]],
              let first = translations.first,
              let text = first["text"] as? String
        else {
            throw ProviderError.decodingFailed("Could not parse translations[0].text from DeepL response")
        }
        return text
    }
}
