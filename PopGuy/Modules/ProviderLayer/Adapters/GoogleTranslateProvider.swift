// GoogleTranslateProvider.swift
// PopGuy — ProviderLayer/Adapters
//
// Provider adapter for Google Cloud Translation v2 (Basic).
//
// Verified API contract:
//   POST https://translation.googleapis.com/language/translate/v2?key=<API_KEY>
//   Headers: Content-Type: application/json (NO Authorization header)
//   Body: { "q": <text>, "target": "<lang e.g. es, vi, fr>",
//           "source": <optional>, "format": "text" }
//   Response: { "data": { "translations": [{ "translatedText": "<result>" }] } }
//
// Authentication: API key in the `key` query parameter.
// This is Cloud Translation v2 (Basic). Do NOT use v3 Advanced — it requires
// OAuth/service-account, which is incompatible with the Keychain API-key model.
//
// Non-streaming: result wrapped as a single-element AsyncThrowingStream.
//
// JSON parsing uses JSONSerialization (not Codable) — cleaner for dynamic
// API responses with optional fields; no additional types needed.

import Foundation

// MARK: - GoogleTranslateProvider

/// Translates text via Google Cloud Translation v2 (Basic) API.
/// Non-streaming — result is a single-element AsyncThrowingStream.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct GoogleTranslateProvider: Provider {

    private let apiKey: String
    private let httpClient: HTTPClient

    private static let baseURL = "https://translation.googleapis.com/language/translate/v2"

    init(apiKey: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.apiKey = apiKey
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
            throw ProviderError.missingOption("targetLanguage is required for Google Translate")
        }

        let request = try GoogleTranslateProvider.makeRequest(
            apiKey: apiKey,
            input: input,
            targetLanguage: targetLang,
            sourceLanguage: options.sourceLanguage
        )

        let data = try await httpClient.rawData(for: request)
        let text = try GoogleTranslateProvider.parseTranslation(from: data)

        // Wrap the single result as a one-element stream.
        return AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }

    // MARK: - Request builder (internal; also used by tests)

    static func makeRequest(
        apiKey: String,
        input: String,
        targetLanguage: String,
        sourceLanguage: String?
    ) throws -> URLRequest {
        // Embed the API key as a query parameter (v2 Basic authentication).
        guard var components = URLComponents(string: baseURL) else {
            throw ProviderError.transport("Invalid Google Translate base URL")
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw ProviderError.transport("Could not construct Google Translate URL with key param")
        }
        // SECURITY: Never log `url` — it contains the API key in the query string.
        // Ensure any ProviderError messages thrown below do NOT interpolate `url`.

        var body: [String: Any] = [
            "q": input,
            "target": targetLanguage,
            "format": "text"
        ]
        if let src = sourceLanguage {
            body["source"] = src
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No Authorization header — authentication is via the `key` query param.
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Key validation request

    /// Build a lightweight request used to verify an API key before saving it.
    /// Hits `GET /language/translate/v2/languages?key=…`, which only checks the
    /// key and returns the supported-language list — no translation performed.
    /// A 400/403 indicates an invalid key.
    static func makeValidationRequest(apiKey: String) throws -> URLRequest {
        guard var components = URLComponents(
            string: "https://translation.googleapis.com/language/translate/v2/languages"
        ) else {
            throw ProviderError.transport("Invalid Google Translate languages URL")
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw ProviderError.transport("Could not construct Google Translate validation URL")
        }
        // SECURITY: Never log `url` — it contains the API key in the query string.
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return req
    }

    // MARK: - Response parser

    /// Parse `data.translations[0].translatedText` from the raw response body.
    /// Google Cloud Translation v2 HTML-escapes translatedText even for `format:text`
    /// requests; decode named and numeric character references before returning.
    static func parseTranslation(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let translations = dataObj["translations"] as? [[String: Any]],
              let first = translations.first,
              let text = first["translatedText"] as? String
        else {
            throw ProviderError.decodingFailed(
                "Could not parse data.translations[0].translatedText from Google Translate response"
            )
        }
        return decodeHTMLEntities(text)
    }

    // MARK: - HTML entity decoder

    /// Decode HTML character references in a plain-text string.
    ///
    /// Handles the common named entities and decimal / hex numeric references:
    ///   `&amp;` `&lt;` `&gt;` `&quot;` `&#39;` `&apos;` `&#NN;` `&#xNN;`
    ///
    /// This is a lightweight pure-Swift implementation — no NSAttributedString,
    /// no @MainActor dependency — suitable for use from nonisolated contexts.
    static func decodeHTMLEntities(_ string: String) -> String {
        // Fast path: if there's no '&' at all, nothing to decode.
        guard string.contains("&") else { return string }

        var result = string

        // Named entities — decode all EXCEPT &amp; first, then numeric refs,
        // then &amp; last. This prevents cascade double-decode: e.g. "&amp;lt;"
        // must decode once to "&lt;" not twice to "<". Processing &amp; last
        // ensures it only matches a literal "&amp;" that survived all prior passes.
        let namedEntitiesFirst: [(String, String)] = [
            ("&lt;",   "<"),
            ("&gt;",   ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;",  "'"),   // numeric form of apostrophe — also common
        ]
        for (entity, char) in namedEntitiesFirst {
            result = result.replacingOccurrences(of: entity, with: char)
        }

        // Numeric character references: decimal &#NN; and hex &#xNN;
        // Use a simple scan rather than a regex to avoid Foundation regex API
        // availability differences across macOS versions.
        result = decodeNumericCharacterReferences(result)

        // &amp; is decoded LAST so that "&amp;lt;" → "&lt;" (not "<").
        result = result.replacingOccurrences(of: "&amp;", with: "&")

        return result
    }

    /// Replace `&#NN;` (decimal) and `&#xNN;` / `&#XNN;` (hex) references.
    private static func decodeNumericCharacterReferences(_ string: String) -> String {
        guard string.contains("&#") else { return string }
        var output = ""
        var idx = string.startIndex
        while idx < string.endIndex {
            // Look for "&#"
            guard string[idx] == "&",
                  string.index(after: idx) < string.endIndex,
                  string[string.index(after: idx)] == "#"
            else {
                output.append(string[idx])
                idx = string.index(after: idx)
                continue
            }
            // We're at '&', next is '#'. Scan to find the closing ';'.
            let hashIdx = string.index(after: idx) // points at '#'
            var scanIdx = string.index(after: hashIdx) // first char after '#'
            while scanIdx < string.endIndex && string[scanIdx] != ";" {
                scanIdx = string.index(after: scanIdx)
            }
            guard scanIdx < string.endIndex else {
                // No closing ';' — emit literally and move on.
                output.append(string[idx])
                idx = string.index(after: idx)
                continue
            }
            // digits are string[scanIdx's start .. scanIdx)
            let digitsStart = string.index(after: hashIdx)
            let digitsRange = digitsStart ..< scanIdx
            let digits = String(string[digitsRange])
            var codePoint: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                codePoint = UInt32(digits.dropFirst(), radix: 16)
            } else {
                codePoint = UInt32(digits)
            }
            if let cp = codePoint, let scalar = Unicode.Scalar(cp) {
                output.append(Character(scalar))
            } else {
                // Unrecognised — emit the original sequence.
                output += String(string[idx ... scanIdx])
            }
            idx = string.index(after: scanIdx) // past the ';'
        }
        return output
    }
}
