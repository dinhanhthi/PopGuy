// OpenAIProvider.swift
// PopGuy — ProviderLayer/Adapters
//
// Provider adapter for OpenAI Chat Completions API (streaming).
//
// Verified API contract:
//   POST https://api.openai.com/v1/chat/completions
//   Headers: Authorization: Bearer <key>, Content-Type: application/json
//   Body: { "model": <model>, "messages": [...], "stream": true }
//   SSE: data: {"choices":[{"delta":{"content":"<token>"}}]}
//        terminated by data: [DONE]
//
// The base URL is configurable so OllamaProvider can also use the
// OpenAI-compatible shape through its own independent adapter file.

import Foundation

// MARK: - OpenAIProvider

/// Streams tokens from the OpenAI Chat Completions endpoint.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct OpenAIProvider: Provider {

    private let apiKey: String
    private let httpClient: HTTPClient

    /// Which provider this adapter is serving (OpenAI, GLM, OpenRouter, Custom).
    /// Drives provider-specific "disable thinking" request fields; nil = plain OpenAI.
    private let providerKind: ProviderKind?

    /// Default base URL (overridable for tests; Ollama uses its own adapter).
    private static let defaultBase = "https://api.openai.com/v1"

    init(
        apiKey: String,
        providerKind: ProviderKind? = nil,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.apiKey = apiKey
        self.providerKind = providerKind
        self.httpClient = HTTPClient(session: session)
    }

    // MARK: - Provider

    func stream(
        systemPrompt: String?,
        input: String,
        model: String,
        options: ProviderOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        let request = try OpenAIProvider.makeRequest(
            apiKey: apiKey,
            baseURL: options.baseURL,
            model: model,
            systemPrompt: systemPrompt,
            input: input,
            options: options,
            providerKind: providerKind
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
        options: ProviderOptions,
        providerKind: ProviderKind? = nil
    ) throws -> URLRequest {
        // Normalize: trim all trailing slashes so "…/v1/" + "/chat/completions"
        // does not produce the double-slash "…/v1//chat/completions".
        var base = baseURL?.absoluteString ?? defaultBase
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw ProviderError.transport("Invalid base URL: \(base)")
        }

        var messages: [[String: String]] = []
        if let sys = systemPrompt {
            messages.append(["role": "system", "content": sys])
        }
        messages.append(["role": "user", "content": input])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true
        ]

        // Disable provider-side "thinking"/reasoning where the provider defaults it ON
        // and exposes a documented off switch. The field differs per provider, so it is
        // gated on providerKind. Plain OpenAI (providerKind nil/.openAI) is intentionally
        // excluded: its non-reasoning models (gpt-4o) reject reasoning params with a 400,
        // and its reasoning models (o-series) cannot fully disable thinking.
        switch providerKind {
        case .glm:
            // z.ai GLM hybrid models default thinking ON; {type:"disabled"} turns it off.
            body["thinking"] = ["type": "disabled"]
        case .openRouter:
            // OpenRouter unified reasoning control; {enabled:false} disables reasoning and
            // is normalized/ignored for models that don't support it.
            body["reasoning"] = ["enabled": false]
        default:
            break
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Key validation request

    /// Build a lightweight authenticated request used to verify an API key
    /// before saving it. Hits `GET /v1/models`, which only checks that the key
    /// authenticates (no tokens consumed). A 401 indicates an invalid key.
    static func makeValidationRequest(apiKey: String, baseURL: URL? = nil) throws -> URLRequest {
        var base = baseURL?.absoluteString ?? defaultBase
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/models") else {
            throw ProviderError.transport("Invalid base URL: \(base)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: - Delta parser

    /// Map raw SSE data-line payloads → content delta strings.
    /// Skips chunks where `choices[0].delta.content` is absent or empty.
    private func parseDeltas(from raw: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await payload in raw {
                        if Task.isCancelled { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String,
                              !content.isEmpty
                        else { continue }
                        continuation.yield(content)
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
