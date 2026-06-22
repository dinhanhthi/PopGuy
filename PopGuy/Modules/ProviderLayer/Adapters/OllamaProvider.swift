// OllamaProvider.swift
// PopGuy — ProviderLayer/Adapters
//
// Provider adapter for Ollama and LM Studio (OpenAI-compatible API).
//
// Ollama and LM Studio expose an OpenAI-compatible Chat Completions endpoint
// at a user-configurable base URL (default: http://localhost:11434/v1).
// No API key is required for local deployments.
//
// This adapter shares the same SSE/JSON parsing as OpenAIProvider (same
// choices[0].delta.content shape) but is an independent file with its own
// implementation — no import or reference to OpenAIProvider.swift — so both
// adapters can evolve independently.
//
// Configuring the base URL:
//   Pass a `baseURL` in `ProviderOptions` (from SettingsStore at runtime).
//   For Ollama: http://localhost:11434/v1
//   For LM Studio: http://localhost:1234/v1 (typical default)

import Foundation

// MARK: - OllamaProvider

/// Streams tokens from an Ollama or LM Studio local inference server.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct OllamaProvider: Provider {

    private let httpClient: HTTPClient

    // Default Ollama base URL — overridable per-call via ProviderOptions.
    static let defaultBaseURL = URL(string: "http://localhost:11434/v1")!

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.httpClient = HTTPClient(session: session)
    }

    // MARK: - Provider

    func stream(
        systemPrompt: String?,
        input: String,
        model: String,
        options: ProviderOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        let baseURL = options.baseURL ?? OllamaProvider.defaultBaseURL
        let request = try OllamaProvider.makeRequest(
            baseURL: baseURL,
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
        baseURL: URL?,
        model: String,
        systemPrompt: String?,
        input: String,
        options: ProviderOptions
    ) throws -> URLRequest {
        // Normalize: trim all trailing slashes so "…/v1/" + "/chat/completions"
        // does not produce the double-slash "…/v1//chat/completions".
        var base = (baseURL ?? defaultBaseURL).absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw ProviderError.transport("Invalid Ollama base URL: \(base)")
        }

        var messages: [[String: String]] = []
        if let sys = systemPrompt {
            messages.append(["role": "system", "content": sys])
        }
        messages.append(["role": "user", "content": input])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            // Disable "thinking" on thinking-capable local models (e.g. qwen3, deepseek-r1).
            // On the OpenAI-compatible endpoint the native `think` flag is ignored; the
            // documented control is reasoning_effort, where "none" disables reasoning.
            "reasoning_effort": "none"
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No Authorization header — local servers don't require API keys.
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Delta parser (OpenAI-compatible)

    /// Parse choices[0].delta.content from each SSE payload.
    /// Identical shape to OpenAI — Ollama uses the same SSE format.
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
