// AnthropicProvider.swift
// PopGuy — ProviderLayer/Adapters
//
// Provider adapter for the Anthropic Messages API (streaming).
//
// Verified API contract (from official Anthropic API docs):
//   POST https://api.anthropic.com/v1/messages
//   Headers:
//     x-api-key: <key>
//     anthropic-version: 2023-06-01
//     Content-Type: application/json
//   Body:
//     { "model": <model>, "max_tokens": <n>,
//       "system": <system prompt — OMIT if nil>,
//       "messages": [{"role":"user","content":<input>}],
//       "stream": true }
//   IMPORTANT: Do NOT send temperature/top_p/top_k — removed on Opus 4.8/4.7;
//              sending them causes a 400 Bad Request.
//
//   SSE event types (event-typed, NOT OpenAI's choice/delta format):
//     content_block_delta → data.delta.text (extract this)
//     message_stop        → stream is done (not "[DONE]")
//
//   Current recommended defaults (per-action config, not hardcoded):
//     claude-opus-4-8, claude-sonnet-4-6, claude-haiku-4-5

import Foundation

// MARK: - AnthropicProvider

/// Streams tokens from the Anthropic Messages API.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct AnthropicProvider: Provider {

    private let apiKey: String
    private let httpClient: HTTPClient

    private static let baseURL = "https://api.anthropic.com/v1/messages"
    private static let apiVersion = "2023-06-01"

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
        let request = try AnthropicProvider.makeRequest(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            input: input,
            options: options
        )
        let rawStream = try await httpClient.sseStream(for: request)
        return parseDeltas(from: rawStream)
    }

    // MARK: - Request builder (internal; also used by tests)

    static func makeRequest(
        apiKey: String,
        model: String,
        systemPrompt: String?,
        input: String,
        options: ProviderOptions
    ) throws -> URLRequest {
        guard let url = URL(string: baseURL) else {
            throw ProviderError.transport("Invalid Anthropic base URL")
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": options.maxTokens,
            "messages": [["role": "user", "content": input]],
            "stream": true
        ]
        // System prompt is optional — omit the key entirely when nil to stay
        // compatible with all Anthropic models (including those that reject the key).
        if let sys = systemPrompt {
            body["system"] = sys
        }
        // DO NOT add temperature, top_p, or top_k — these cause 400 on Opus 4.8/4.7.

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Key validation request

    /// Build a lightweight authenticated request used to verify an API key
    /// before saving it. Hits `GET /v1/models` (sibling of the messages
    /// endpoint), which only checks that the key authenticates — no tokens
    /// consumed. A 401 indicates an invalid key.
    static func makeValidationRequest(apiKey: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else {
            throw ProviderError.transport("Invalid Anthropic models URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        return req
    }

    // MARK: - Delta parser

    /// Map raw SSE data-line payloads → text delta strings.
    ///
    /// Anthropic SSE is event-typed. Only `content_block_delta` events with
    /// `delta.type == "text_delta"` carry text tokens. Benign event types
    /// (message_start, content_block_start/stop, message_delta, message_stop, ping)
    /// are skipped. `error` events (which Anthropic can emit after a 200 response,
    /// e.g. overloaded_error) are surfaced as thrown ProviderErrors so callers
    /// see failures rather than silent partial/empty responses.
    private func parseDeltas(from raw: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await payload in raw {
                        if Task.isCancelled { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        let eventType = json["type"] as? String

                        // Surface mid-stream API errors (e.g. overloaded_error)
                        // instead of silently skipping them.
                        if eventType == "error" {
                            let errorObj = json["error"] as? [String: Any]
                            let kind    = errorObj?["type"] as? String ?? "unknown_error"
                            let message = errorObj?["message"] as? String ?? "Anthropic error event received"
                            continuation.finish(throwing: ProviderError.apiError(kind, message))
                            return
                        }

                        guard eventType == "content_block_delta",
                              let delta = json["delta"] as? [String: Any],
                              delta["type"] as? String == "text_delta",
                              let text = delta["text"] as? String,
                              !text.isEmpty
                        else { continue }

                        continuation.yield(text)
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
