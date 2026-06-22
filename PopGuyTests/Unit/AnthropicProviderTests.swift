// AnthropicProviderTests.swift
// PopGuyTests
//
// Tests request shape and streamed-delta parsing for AnthropicProvider.
//
// Verified API contract:
//   POST https://api.anthropic.com/v1/messages
//   Headers: x-api-key, anthropic-version: 2023-06-01, Content-Type: application/json
//   Body: { "model", "max_tokens", "system", "messages":[{"role":"user","content":...}], "stream": true }
//   SSE events: content_block_delta → delta.text extracted; message_stop → terminates.
//   NO temperature/top_p/top_k (removed on Opus 4.8/4.7 → would cause 400).

import Foundation
import Testing
@testable import PopGuy

// .serialized: all response-parsing tests in this suite share the mock host
// "api.anthropic.com" — serialising prevents intra-suite concurrent access
// to the same registry slot.
@Suite("AnthropicProvider", .serialized)
struct AnthropicProviderTests {

    // Host key for this suite's mock handler.
    private static let mockHost = "api.anthropic.com"

    // MARK: - Helpers

    private func makeMockSession(body: Data) -> URLSession {
        MockURLProtocol.register(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: 200,
                              headers: ["Content-Type": "text/event-stream"]),
             body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // Canned Anthropic SSE with two content_block_delta events + message_stop.
    private let cannedSSE = Data("""
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_01","model":"claude-opus-4-8"}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

    event: message_stop
    data: {"type":"message_stop"}

    """.utf8)

    // MARK: - Request shape

    @Test("request targets api.anthropic.com/v1/messages")
    func requestURL() throws {
        let req = try AnthropicProvider.makeRequest(
            apiKey: "test-key",
            model: "claude-opus-4-8",
            systemPrompt: "Be helpful.",
            input: "Hi",
            options: ProviderOptions(maxTokens: 1024)
        )
        #expect(req.url?.host == "api.anthropic.com")
        #expect(req.url?.path == "/v1/messages")
    }

    @Test("request has x-api-key header")
    func requestApiKeyHeader() throws {
        let req = try AnthropicProvider.makeRequest(
            apiKey: "anthro-key",
            model: "claude-opus-4-8",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "anthro-key")
    }

    @Test("request has anthropic-version header")
    func requestVersionHeader() throws {
        let req = try AnthropicProvider.makeRequest(
            apiKey: "key",
            model: "claude-opus-4-8",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test("request body shape: model, max_tokens, system, messages, stream")
    func requestBodyShape() throws {
        let req = try AnthropicProvider.makeRequest(
            apiKey: "key",
            model: "claude-sonnet-4-6",
            systemPrompt: "system text",
            input: "user text",
            options: ProviderOptions(maxTokens: 2048)
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "claude-sonnet-4-6")
        #expect(body["max_tokens"] as? Int == 2048)
        #expect(body["system"] as? String == "system text")
        #expect(body["stream"] as? Bool == true)
        let messages = body["messages"] as? [[String: String]]
        #expect(messages?.count == 1)
        #expect(messages?[0]["role"] == "user")
        #expect(messages?[0]["content"] == "user text")
    }

    @Test("request body does NOT contain temperature, top_p, or top_k")
    func requestBodyNoTemperature() throws {
        let req = try AnthropicProvider.makeRequest(
            apiKey: "key",
            model: "claude-opus-4-8",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["temperature"] == nil)
        #expect(body["top_p"] == nil)
        #expect(body["top_k"] == nil)
    }

    @Test("system key is omitted when systemPrompt is nil")
    func requestBodyNoSystem() throws {
        let req = try AnthropicProvider.makeRequest(
            apiKey: "key",
            model: "claude-opus-4-8",
            systemPrompt: nil,
            input: "hello",
            options: ProviderOptions()
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["system"] == nil)
    }

    // MARK: - Response parsing

    @Test("streams text_delta tokens from canned Anthropic SSE")
    func streamDeltas() async throws {
        let session = makeMockSession(body: cannedSSE)
        let provider = AnthropicProvider(apiKey: "key", session: session)

        var tokens: [String] = []
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "Say hello",
            model: "claude-opus-4-8",
            options: ProviderOptions()
        )
        for try await token in stream { tokens.append(token) }

        #expect(tokens == ["Hello", " world"])
    }

    @Test("non content_block_delta events are skipped")
    func nonDeltaEventsSkipped() async throws {
        // Only content_block_delta events contribute tokens.
        // message_start, content_block_start/stop, message_delta are skipped.
        let session = makeMockSession(body: cannedSSE)
        let provider = AnthropicProvider(apiKey: "key", session: session)

        var count = 0
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "hi",
            model: "claude-opus-4-8",
            options: ProviderOptions()
        )
        for try await _ in stream { count += 1 }

        #expect(count == 2)
    }

    // MARK: - Mid-stream error event

    @Test("event:error after 200 throws ProviderError.apiError")
    func midStreamErrorEventThrows() async throws {
        // Anthropic can emit `event: error` after a 200 response (e.g. overloaded_error).
        // The parser must surface this as a thrown error rather than silently dropping it.
        let errorSSE = Data("""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_01","model":"claude-opus-4-8"}}

        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

        """.utf8)
        let session = makeMockSession(body: errorSSE)
        let provider = AnthropicProvider(apiKey: "key", session: session)

        var threwApiError = false
        do {
            let stream = try await provider.stream(
                systemPrompt: nil,
                input: "hi",
                model: "claude-opus-4-8",
                options: ProviderOptions()
            )
            for try await _ in stream {}
        } catch let err as ProviderError {
            if case .apiError(let kind, _) = err, kind == "overloaded_error" {
                threwApiError = true
            }
        }
        #expect(threwApiError)
    }

    @Test("event:error message is preserved in thrown error")
    func midStreamErrorMessagePreserved() async throws {
        let errorSSE = Data("""
        event: error
        data: {"type":"error","error":{"type":"rate_limit_error","message":"Too many requests"}}

        """.utf8)
        let session = makeMockSession(body: errorSSE)
        let provider = AnthropicProvider(apiKey: "key", session: session)

        var errorMessage: String?
        do {
            let stream = try await provider.stream(
                systemPrompt: nil,
                input: "hi",
                model: "claude-opus-4-8",
                options: ProviderOptions()
            )
            for try await _ in stream {}
        } catch let err as ProviderError {
            if case .apiError(_, let msg) = err {
                errorMessage = msg
            }
        }
        #expect(errorMessage == "Too many requests")
    }
}
