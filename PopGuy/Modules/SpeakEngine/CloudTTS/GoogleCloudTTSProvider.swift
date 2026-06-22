// GoogleCloudTTSProvider.swift
// PopGuy — SpeakEngine/CloudTTS
//
// Cloud TTS adapter for the Google Cloud Text-to-Speech REST API.
// Stateless namespace of static functions — conforms to TTSProvider.
//
// Isolation: nonisolated — opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
// so the adapter can be called from any executor context without a hop.
//
// API shape (confirmed from Google Cloud TTS discovery document and REST reference,
// fetched 2026-06-12 via WebFetch):
//   POST https://texttospeech.googleapis.com/v1/text:synthesize?key=<API_KEY>
//   Content-Type: application/json
//   Body: {
//     "input":       { "text": <text> },
//     "voice":       { "languageCode": <bcp47>, "name": <voiceName> },
//     "audioConfig": { "audioEncoding": "MP3" }
//   }
//   Response: { "audioContent": "<base64-encoded mp3 bytes>" }
//
// Authentication: API key passed as a `key` query parameter
// (confirmed from the TTS API discovery document: key is "location": "query").
//
// NOTE: The API key appears in the request URL — NEVER log the request URL or
// the URLRequest object. All logging must be scoped to response status/body only.

import Foundation

// MARK: - GoogleCloudTTSProvider

/// Cloud TTS adapter for the Google Cloud Text-to-Speech REST API.
///
/// Google Cloud TTS voices are locale-bound — each voice only works with its
/// matching `languageCode`. `defaultVoice(forLanguage:)` returns the correct
/// Neural2 (or Standard where Neural2 is unavailable) voice for each supported
/// locale. Unsupported locales fall back to `en-US-Neural2-C`.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum GoogleCloudTTSProvider: TTSProvider {

    // MARK: - TTSProvider conformance

    static var kind: TTSProviderKind { .googleCloudTTS }

    /// Returns a locale-correct default voice for the given BCP-47 language code.
    ///
    /// Voice names are confirmed from the Google Cloud TTS voices documentation
    /// (fetched 2026-06-12). Neural2 voices are used where available.
    ///
    /// IMPORTANT: Each voice is locale-bound — the returned name must be used
    /// with a matching `languageCode` in every synthesis request. A voice from
    /// `en-US` cannot be used with `languageCode: "fr-FR"`.
    ///
    /// Supported locales and chosen defaults:
    /// - `en-US` → `en-US-Neural2-C` (Female, Neural2)
    /// - `en-GB` → `en-GB-Neural2-A` (Female, Neural2)
    /// - `fr-FR` → `fr-FR-Neural2-F` (Female, Neural2)
    /// - `es-ES` → `es-ES-Neural2-A` (Female, Neural2)
    /// - `de-DE` → `de-DE-Neural2-G` (Female, Neural2)
    /// - Any other → falls back to `en-US-Neural2-C`
    static func defaultVoice(forLanguage languageCode: String) -> String {
        switch languageCode {
        case "en-US": return "en-US-Neural2-C"
        case "en-GB": return "en-GB-Neural2-A"
        case "fr-FR": return "fr-FR-Neural2-F"
        case "es-ES": return "es-ES-Neural2-A"
        case "de-DE": return "de-DE-Neural2-G"
        default:      return "en-US-Neural2-C"
        }
    }

    /// Returns a curated list of voice identifiers for the given BCP-47 language code.
    ///
    /// Voices are ordered highest-to-lowest quality: Chirp3-HD first (newest, highest
    /// quality), then Neural2 (standard high quality), then WaveNet/Standard fallback.
    /// Voice names are verified from the Google Cloud TTS voice list documentation
    /// (fetched 2026-06-12 from docs.cloud.google.com/text-to-speech/docs/voices).
    ///
    /// All voices are locale-bound — every name in the returned array contains the
    /// locale prefix (e.g. "en-US-") as a hard invariant.
    ///
    /// - Parameter languageCode: A BCP-47 locale string (e.g. "en-US", "fr-FR").
    /// - Returns: An ordered array of voice identifier strings, or `[]` for unknown locales.
    static func curatedVoices(forLanguage languageCode: String) -> [String] {
        switch languageCode {
        case "en-US":
            return [
                "en-US-Chirp3-HD-Aoede",
                "en-US-Chirp3-HD-Charon",
                "en-US-Chirp3-HD-Kore",
                "en-US-Chirp3-HD-Puck",
                "en-US-Neural2-C",
                "en-US-Neural2-A",
                "en-US-Neural2-J",
            ]
        case "en-GB":
            return [
                "en-GB-Chirp3-HD-Aoede",
                "en-GB-Chirp3-HD-Charon",
                "en-GB-Chirp3-HD-Kore",
                "en-GB-Chirp3-HD-Puck",
                "en-GB-Neural2-A",
                "en-GB-Neural2-B",
                "en-GB-Neural2-F",
            ]
        case "fr-FR":
            return [
                "fr-FR-Chirp3-HD-Aoede",
                "fr-FR-Chirp3-HD-Charon",
                "fr-FR-Chirp3-HD-Kore",
                "fr-FR-Chirp3-HD-Puck",
                "fr-FR-Neural2-F",
                "fr-FR-Neural2-G",
            ]
        case "es-ES":
            return [
                "es-ES-Chirp3-HD-Aoede",
                "es-ES-Chirp3-HD-Charon",
                "es-ES-Chirp3-HD-Kore",
                "es-ES-Chirp3-HD-Puck",
                "es-ES-Neural2-A",
                "es-ES-Neural2-B",
                "es-ES-Neural2-C",
            ]
        case "de-DE":
            return [
                "de-DE-Chirp3-HD-Aoede",
                "de-DE-Chirp3-HD-Charon",
                "de-DE-Chirp3-HD-Kore",
                "de-DE-Chirp3-HD-Puck",
                "de-DE-Neural2-G",
                "de-DE-Neural2-H",
            ]
        default:
            return []
        }
    }

    /// Builds a POST request to synthesise `text` using the Google Cloud TTS API.
    ///
    /// The API key is passed as a percent-encoded URL query parameter named `key`.
    /// **Never log the returned `URLRequest` or its URL** — the API key is embedded
    /// in the URL query string.
    ///
    /// - Throws: `TTSProviderError.missingAPIKey` when `apiKey` is empty.
    /// - Throws: `TTSProviderError.encoding` when the JSON body cannot be serialised.
    static func makeSynthesisRequest(
        text: String,
        voice: String,
        languageCode: String,
        config: TTSProviderConfig,
        apiKey: String
    ) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw TTSProviderError.missingAPIKey }

        let url = try buildURL(
            path: "https://texttospeech.googleapis.com/v1/text:synthesize",
            apiKey: apiKey
        )

        let bodyObject: [String: Any] = [
            "input":       ["text": text],
            "voice":       ["languageCode": languageCode, "name": voice],
            "audioConfig": ["audioEncoding": "MP3"]
        ]

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: bodyObject)
        } catch {
            throw TTSProviderError.encoding
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        return request
    }

    /// Decodes the Google Cloud TTS JSON response into MP3 bytes.
    ///
    /// Google Cloud TTS wraps the audio in a JSON envelope:
    /// `{ "audioContent": "<base64-encoded mp3>" }`.
    /// This method parses the envelope and base64-decodes the audio bytes.
    ///
    /// - Throws: `TTSProviderError.decode("missing audioContent")` when the field
    ///   is absent or not a non-empty string.
    /// - Throws: `TTSProviderError.decode("invalid base64")` when base64 decoding fails.
    static func decodeAudio(from data: Data) throws -> Data {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let base64String = json["audioContent"] as? String,
            !base64String.isEmpty
        else {
            throw TTSProviderError.decode("missing audioContent")
        }

        guard let audioData = Data(base64Encoded: base64String) else {
            throw TTSProviderError.decode("invalid base64")
        }

        return audioData
    }

    /// Builds a cheap `GET /v1/voices` request to verify that `apiKey` is valid.
    ///
    /// The voices list endpoint returns 2xx for a valid API key and is the
    /// least expensive call available that exercises authentication without
    /// producing audio.
    ///
    /// **Never log the returned `URLRequest` or its URL** — the API key is embedded
    /// in the URL query string.
    ///
    /// - Throws: `TTSProviderError.missingAPIKey` when `apiKey` is empty.
    static func makeValidationRequest(
        apiKey: String,
        config: TTSProviderConfig
    ) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw TTSProviderError.missingAPIKey }

        let url = try buildURL(
            path: "https://texttospeech.googleapis.com/v1/voices",
            apiKey: apiKey
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return request
    }

    // MARK: - Private helpers

    /// Builds a URL by appending `?key=<percent-encoded apiKey>` to `path`.
    ///
    /// Uses `URLComponents` for safe percent-encoding of the key value,
    /// preventing injection of extra query components.
    private static func buildURL(path: String, apiKey: String) throws -> URL {
        guard var components = URLComponents(string: path) else {
            throw TTSProviderError.encoding
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw TTSProviderError.encoding
        }
        return url
    }
}
