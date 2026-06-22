// GeminiProvider.swift
// PopGuy — ProviderLayer/Adapters
//
// Provider adapter for the Google Gemini generateContent API (native SSE streaming).
//
// Verified API contract (from https://ai.google.dev/gemini-api/docs/api-overview):
//   POST https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?alt=sse
//   Headers:
//     x-goog-api-key: <key>
//     Content-Type: application/json
//   Body:
//     {
//       "contents": [{"role": "user", "parts": [{"text": <input>}]}],
//       "systemInstruction": {"parts": [{"text": <system prompt>}]},  // OMIT if nil
//       "generationConfig": { "maxOutputTokens": <n> }                // optional
//     }
//   SSE chunks (data: lines):
//     { "candidates": [{ "content": { "parts": [{ "text": "<token>" }] } }] }
//   In-stream error:
//     { "error": { "code": <int>, "message": "<msg>", "status": "<status>" } }
//   Stream terminates when the HTTP body ends (no "[DONE]" sentinel like OpenAI).
//
//   Authentication: x-goog-api-key header (preferred over ?key= query param).
//   Base URL: configurable via ProviderOptions.baseURL; falls back to the canonical
//   v1beta base. ProviderKind.gemini.defaultBaseURL is the OpenAI-compatible endpoint
//   and is intentionally NOT used here — this adapter targets the native Gemini REST API.

import Foundation

// MARK: - GeminiProvider

/// Streams tokens from the Google Gemini generateContent API using native SSE.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct GeminiProvider: Provider {

    private let apiKey: String
    private let httpClient: HTTPClient

    /// Canonical v1beta base URL for the native Gemini REST API.
    /// Note: this is NOT the OpenAI-compatible endpoint stored in ProviderKind.gemini.defaultBaseURL.
    private static let nativeBase = "https://generativelanguage.googleapis.com/v1beta"

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
        let request = try GeminiProvider.makeRequest(
            apiKey: apiKey,
            baseURL: options.baseURL,
            model: model,
            systemPrompt: systemPrompt,
            input: input,
            options: options
        )
        let rawStream = try await httpClient.sseStream(for: request)
        return parseDeltas(from: rawStream)
    }

    // MARK: - Request builder (internal; also used by tests to assert shape)

    static func makeRequest(
        apiKey: String,
        baseURL: URL?,
        model: String,
        systemPrompt: String?,
        input: String,
        options: ProviderOptions
    ) throws -> URLRequest {
        // Build the endpoint: <base>/models/<model>:streamGenerateContent?alt=sse
        // Normalize: trim trailing slashes to avoid double-slash in URL.
        var base = baseURL?.absoluteString ?? nativeBase
        while base.hasSuffix("/") { base.removeLast() }

        // Percent-encode the model path segment so characters like `?`, `#`, `/`,
        // or `%` in a user-supplied model id cannot rewrite the URL structure.
        // allowedCharacters excludes those URL-structural characters from the segment.
        guard let encodedModel = model.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(.init(charactersIn: "/?#"))
        ) else {
            throw ProviderError.transport("Invalid characters in Gemini model identifier: \(model)")
        }
        let endpointString = "\(base)/models/\(encodedModel):streamGenerateContent"

        guard var components = URLComponents(string: endpointString) else {
            throw ProviderError.transport("Invalid Gemini endpoint URL: \(endpointString)")
        }
        // alt=sse instructs the server to respond with Server-Sent Events.
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        guard let url = components.url else {
            throw ProviderError.transport("Could not construct Gemini SSE URL for model: \(model)")
        }

        // Build the request body.
        // contents: user turn carrying the input text.
        let userContent: [String: Any] = [
            "role": "user",
            "parts": [["text": input]]
        ]

        var body: [String: Any] = [
            "contents": [userContent]
        ]

        // systemInstruction: omit the key entirely when nil.
        if let sys = systemPrompt, !sys.isEmpty {
            body["systemInstruction"] = ["parts": [["text": sys]]]
        }

        // generationConfig: send maxOutputTokens when non-default (> 0).
        // ProviderOptions.maxTokens defaults to 4096; always forward it to
        // stay consistent with other adapters (AnthropicProvider always sends it).
        var generationConfig: [String: Any] = ["maxOutputTokens": options.maxTokens]
        // Disable "thinking" only on the Gemini 2.5 Flash family (flash, flash-lite),
        // which accepts thinkingBudget: 0. This is a positive allowlist, NOT a
        // "not pro" exclusion: Gemini 2.5 Pro requires a budget >= 128 (0 → 400),
        // and other non-Flash models reachable via the Gemini API (e.g. Gemma) reject
        // thinkingConfig entirely (→ 400). Gating on "flash" covers exactly the models
        // that support turning thinking off and leaves every other model untouched.
        if model.lowercased().contains("flash") {
            generationConfig["thinkingConfig"] = ["thinkingBudget": 0]
        }
        body["generationConfig"] = generationConfig

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Authenticate via header — preferred over the ?key= query param to avoid
        // the API key appearing in server logs or URLSession debug output.
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Key validation request

    /// Build a lightweight authenticated request used to verify an API key
    /// before saving it. Hits GET /v1beta/models (list models), which only checks
    /// that the key authenticates — no generation tokens consumed.
    /// A 400/403 indicates an invalid key; 200 means the key is valid.
    static func makeValidationRequest(apiKey: String) throws -> URLRequest {
        guard let url = URL(string: "\(nativeBase)/models") else {
            throw ProviderError.transport("Invalid Gemini models URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return req
    }

    // MARK: - Delta parser

    /// Map raw SSE data-line payloads → text delta strings.
    ///
    /// Each Gemini SSE chunk is a complete `GenerateContentResponse` JSON object:
    ///   candidates[0].content.parts[0].text  — the text delta (may be absent in
    ///   some chunks, e.g. the final usageMetadata-only chunk).
    ///
    /// In-stream error payloads ({"error": {...}}) are surfaced as thrown
    /// ProviderErrors rather than silently dropped — same behaviour as AnthropicProvider.
    private func parseDeltas(from raw: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await payload in raw {
                        if Task.isCancelled { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        // Surface in-stream error objects (e.g. quota exceeded, blocked prompt).
                        if let errorObj = json["error"] as? [String: Any] {
                            let status  = errorObj["status"]  as? String ?? "UNKNOWN"
                            let message = errorObj["message"] as? String ?? "Gemini error event received"
                            continuation.finish(throwing: ProviderError.apiError(status, message))
                            return
                        }

                        // Extract candidates[0].content.parts[*].text
                        // Some chunks (e.g. the final usageMetadata chunk) carry no candidates —
                        // silently skip them via the guard chain.
                        // Gemini may return multiple parts per chunk; concatenate all text parts
                        // so no content is dropped.
                        guard let candidates = json["candidates"] as? [[String: Any]],
                              let first      = candidates.first,
                              let content    = first["content"] as? [String: Any],
                              let parts      = content["parts"] as? [[String: Any]]
                        else { continue }

                        let combined = parts.compactMap { $0["text"] as? String }.joined()
                        guard !combined.isEmpty else { continue }

                        continuation.yield(combined)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
