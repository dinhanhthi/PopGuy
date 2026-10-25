// OllamaProviderTests.swift
// PopGuyTests
//
// Tests OllamaProvider — an OpenAI-compatible adapter with a configurable
// base URL and no API key requirement.

import Foundation
import Testing
@testable import PopGuy

// .serialized: all response-parsing tests in this suite share mock host keys
// ("localhost" and "custom-ollama") — serialising prevents intra-suite
// concurrent access to the same registry slots.
@Suite("OllamaProvider", .serialized)
struct OllamaProviderTests {

    // Host keys used by this suite.
    private static let defaultMockHost = "localhost"
    private static let customMockHost  = "custom-ollama"

    // MARK: - Helpers

    private func makeMockSession(body: Data) -> URLSession {
        MockURLProtocol.register(host: Self.defaultMockHost) { _ in
            (MockHTTPResponse(statusCode: 200,
                              headers: ["Content-Type": "text/event-stream"]),
             body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // Canned OpenAI-compatible SSE (same format as OpenAI, just different host).
    private let cannedSSE = Data("""
    data: {"choices":[{"delta":{"content":"Bonjour"}}]}

    data: {"choices":[{"delta":{"content":"!"}}]}

    data: [DONE]

    """.utf8)

    // MARK: - Request shape

    @Test("default base URL is localhost:11434/v1")
    func defaultBaseURL() throws {
        let req = try OllamaProvider.makeRequest(
            baseURL: nil,
            model: "llama3",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        #expect(req.url?.host == "localhost")
        #expect(req.url?.port == 11434)
        #expect(req.url?.path == "/v1/chat/completions")
    }

    @Test("custom base URL overrides default")
    func customBaseURL() throws {
        let custom = URL(string: "http://192.168.1.100:8080/v1")!
        let req = try OllamaProvider.makeRequest(
            baseURL: custom,
            model: "llama3",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions(baseURL: custom)
        )
        #expect(req.url?.host == "192.168.1.100")
        #expect(req.url?.port == 8080)
    }

    @Test("request has no Authorization header (no API key)")
    func requestNoAuthHeader() throws {
        let req = try OllamaProvider.makeRequest(
            baseURL: nil,
            model: "llama3",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("request body contains model, messages, stream:true")
    func requestBodyShape() throws {
        let req = try OllamaProvider.makeRequest(
            baseURL: nil,
            model: "mistral",
            systemPrompt: "sys",
            input: "user",
            options: ProviderOptions()
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "mistral")
        #expect(body["stream"] as? Bool == true)
        let messages = body["messages"] as? [[String: String]]
        #expect(messages?.count == 2)
        #expect(messages?[0]["role"] == "system")
        #expect(messages?[1]["role"] == "user")
    }

    @Test("request body sends reasoning_effort:none to disable thinking")
    func requestBodyDisablesThinking() throws {
        let req = try OllamaProvider.makeRequest(
            baseURL: nil,
            model: "qwen3",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["reasoning_effort"] as? String == "none")
    }

    // FIX 3: trailing-slash base URL must not produce a double slash.
    @Test("trailing-slash base URL does not produce double slash in path")
    func trailingSlashBaseURL() throws {
        let trailingSlash = URL(string: "http://localhost:11434/v1/")!
        let req = try OllamaProvider.makeRequest(
            baseURL: trailingSlash,
            model: "llama3",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions(baseURL: trailingSlash)
        )
        #expect(req.url?.path == "/v1/chat/completions")
        #expect(req.url?.absoluteString.contains("//chat") == false)
    }

    // MARK: - Response parsing

    @Test("streams content delta tokens from canned Ollama SSE")
    func streamDeltas() async throws {
        let customBase = URL(string: "http://localhost:11434/v1")!
        let session = makeMockSession(body: cannedSSE)
        let provider = OllamaProvider(session: session)

        var tokens: [String] = []
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "Say bonjour",
            model: "llama3",
            options: ProviderOptions(baseURL: customBase)
        )
        for try await token in stream { tokens.append(token) }

        #expect(tokens == ["Bonjour", "!"])
    }

    @Test("base URL from options.baseURL is used when streaming")
    func baseURLFromOptions() async throws {
        // Register a handler under the custom host. The stream completing without
        // throwing proves the request was routed to the correct host.
        let customBase = URL(string: "http://custom-ollama:9000/v1")!
        MockURLProtocol.register(host: Self.customMockHost) { _ in
            (MockHTTPResponse(statusCode: 200), Data("data: [DONE]\n\n".utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let provider = OllamaProvider(session: session)

        // If the request doesn't go to custom-ollama, MockURLProtocol finds no
        // handler and the stream throws — so completing without error proves routing.
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "test",
            model: "llama3",
            options: ProviderOptions(baseURL: customBase)
        )
        for try await _ in stream {}
        // Stream completed without throwing → request reached custom-ollama:9000.
    }
}
