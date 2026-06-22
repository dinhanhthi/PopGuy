// OpenAITTSProvider.swift
// PopGuy — SpeakEngine/CloudTTS
//
// Cloud TTS adapter for the OpenAI Audio/Speech API.
// Stateless namespace of static functions — conforms to TTSProvider.
//
// Isolation: nonisolated — opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
// so the adapter can be called from any executor context without a hop.
//
// API shape (confirmed from OpenAI API Reference via context7, 2026-06-12):
//   POST https://api.openai.com/v1/audio/speech
//   Authorization: Bearer <key>
//   Content-Type: application/json
//   Body: { "model": <id>, "input": <text>, "voice": <id>, "response_format": "mp3" }
//   Response: raw MP3 bytes

import Foundation

// MARK: - OpenAITTSProvider

/// Cloud TTS adapter for the OpenAI Audio/Speech endpoint.
///
/// OpenAI voices are multilingual — no per-language routing is needed.
/// `languageCode` is accepted but unused in `makeSynthesisRequest`.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum OpenAITTSProvider: TTSProvider {

    // MARK: - TTSProvider conformance

    static var kind: TTSProviderKind { .openAITTS }

    /// OpenAI voices auto-detect the language from the input text, so the accent
    /// selection has no effect — the UI hides the accent picker for this provider.
    static var usesLanguageSelection: Bool { false }

    /// Returns a neutral default voice for any language.
    ///
    /// OpenAI voices are multilingual so a single voice works for all
    /// `languageCode` values. `"alloy"` is a neutral, gender-neutral voice
    /// documented in the OpenAI Audio API.
    static func defaultVoice(forLanguage languageCode: String) -> String {
        "alloy"
    }

    /// Builds a POST request to synthesise `text` using the OpenAI Audio/Speech API.
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

        let model = config.model ?? TTSProviderKind.openAITTS.defaultModel ?? "gpt-4o-mini-tts"

        let bodyObject: [String: String] = [
            "model":           model,
            "input":           text,
            "voice":           voice,
            "response_format": "mp3"
        ]

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: bodyObject)
        } catch {
            throw TTSProviderError.encoding
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        return request
    }

    /// Returns the raw response bytes as-is.
    ///
    /// OpenAI returns raw MP3 bytes directly — no JSON unwrapping needed.
    ///
    /// - Throws: `TTSProviderError.decode("empty audio")` when `data` is empty.
    static func decodeAudio(from data: Data) throws -> Data {
        guard !data.isEmpty else { throw TTSProviderError.decode("empty audio") }
        return data
    }

    /// Builds a cheap `GET /v1/models` request to verify that `apiKey` is valid.
    ///
    /// This endpoint returns 2xx for a valid Bearer key and costs nothing.
    ///
    /// - Throws: `TTSProviderError.missingAPIKey` when `apiKey` is empty.
    static func makeValidationRequest(
        apiKey: String,
        config: TTSProviderConfig
    ) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw TTSProviderError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }
}
