// OpenAIProviderTests.swift
// PopGuyTests
//
// Tests request shape and streamed-delta parsing for OpenAIProvider.
//
// Request shape is tested by inspecting the URLRequest built by
// OpenAIProvider.makeRequest(...) directly — this avoids the
// URLSession/httpBody-nil trap (URLSession moves httpBody to httpBodyStream
// before the URLProtocol handler sees it, so we never read httpBody in the mock).
//
// Response parsing is tested by feeding canned OpenAI SSE bytes through
// MockURLProtocol and asserting collected token deltas.

import Foundation
import Testing
@testable import PopGuy

// .serialized: all response-parsing tests in this suite share the mock host
// "api.openai.com" — serialising prevents intra-suite concurrent access to
// the same registry slot.
@Suite("OpenAIProvider", .serialized)
struct OpenAIProviderTests {

    // Host key for this suite's mock handler.
    private static let mockHost = "api.openai.com"

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

    // Canned OpenAI SSE: two content deltas then [DONE].
    private let cannedSSE = Data("""
    data: {"choices":[{"delta":{"content":"Hello"}}]}

    data: {"choices":[{"delta":{"content":" world"}}]}

    data: [DONE]

    """.utf8)

    // MARK: - Request shape

    @Test("request targets api.openai.com/v1/chat/completions")
    func requestURL() throws {
        let req = try OpenAIProvider.makeRequest(
            apiKey: "sk-test",
            baseURL: nil,
            model: "gpt-4o",
            systemPrompt: "Be helpful.",
            input: "Say hello",
            options: ProviderOptions()
        )
        #expect(req.url?.host == "api.openai.com")
        #expect(req.url?.path == "/v1/chat/completions")
    }

    @Test("request has Bearer authorization header")
    func requestAuthHeader() throws {
        let req = try OpenAIProvider.makeRequest(
            apiKey: "sk-mykey",
            baseURL: nil,
            model: "gpt-4o",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-mykey")
    }

    @Test("request body contains model, messages array, and stream:true")
    func requestBodyShape() throws {
        let req = try OpenAIProvider.makeRequest(
            apiKey: "sk-test",
            baseURL: nil,
            model: "gpt-4o-mini",
            systemPrompt: "sys",
            input: "user input",
            options: ProviderOptions()
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "gpt-4o-mini")
        #expect(body["stream"] as? Bool == true)
        let messages = body["messages"] as? [[String: String]]
        #expect(messages?.count == 2)
        #expect(messages?[0]["role"] == "system")
        #expect(messages?[0]["content"] == "sys")
        #expect(messages?[1]["role"] == "user")
        #expect(messages?[1]["content"] == "user input")
    }

    @Test("request body omits system message when systemPrompt is nil")
    func requestBodyNoSystem() throws {
        let req = try OpenAIProvider.makeRequest(
            apiKey: "sk-test",
            baseURL: nil,
            model: "gpt-4o",
            systemPrompt: nil,
            input: "hello",
            options: ProviderOptions()
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let messages = body["messages"] as? [[String: String]]
        #expect(messages?.count == 1)
        #expect(messages?[0]["role"] == "user")
    }

    // MARK: - Provider-specific "disable thinking" fields

    @Test("GLM kind adds thinking:{type:disabled} to disable reasoning")
    func glmDisablesThinking() throws {
        let req = try OpenAIProvider.makeRequest(
            apiKey: "k",
            baseURL: URL(string: "https://api.z.ai/api/paas/v4"),
            model: "glm-4.7",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions(),
            providerKind: .glm
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let thinking = body["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "disabled")
        #expect(body["reasoning"] == nil)
    }

    @Test("OpenRouter kind adds reasoning:{enabled:false} to disable reasoning")
    func openRouterDisablesReasoning() throws {
        let req = try OpenAIProvider.makeRequest(
            apiKey: "k",
            baseURL: URL(string: "https://openrouter.ai/api/v1"),
            model: "openai/gpt-4o",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions(),
            providerKind: .openRouter
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let reasoning = body["reasoning"] as? [String: Any]
        #expect(reasoning?["enabled"] as? Bool == false)
        #expect(body["thinking"] == nil)
    }

    @Test("plain OpenAI / nil / custom kinds omit thinking and reasoning fields")
    func openAIAndCustomOmitDisableFields() throws {
        // Plain OpenAI rejects reasoning params on non-reasoning models (gpt-4o → 400),
        // and Custom endpoints are unknown — both must send neither field.
        let kinds: [ProviderKind?] = [nil, .openAI, .custom]
        for kind in kinds {
            let req = try OpenAIProvider.makeRequest(
                apiKey: "k",
                baseURL: nil,
                model: "gpt-4o",
                systemPrompt: nil,
                input: "hi",
                options: ProviderOptions(),
                providerKind: kind
            )
            let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            #expect(body["thinking"] == nil, "thinking must be absent for \(String(describing: kind))")
            #expect(body["reasoning"] == nil, "reasoning must be absent for \(String(describing: kind))")
        }
    }

    @Test("baseURL override replaces default host")
    func baseURLOverride() throws {
        let customBase = URL(string: "http://localhost:11434/v1")!
        let req = try OpenAIProvider.makeRequest(
            apiKey: "",
            baseURL: customBase,
            model: "llama3",
            systemPrompt: nil,
            input: "test",
            options: ProviderOptions(baseURL: customBase)
        )
        #expect(req.url?.host == "localhost")
        #expect(req.url?.port == 11434)
    }

    // FIX 3: trailing-slash base URL must not produce a double slash.
    @Test("trailing-slash base URL does not produce double slash in path")
    func trailingSlashBaseURL() throws {
        let trailingSlash = URL(string: "http://localhost:11434/v1/")!
        let req = try OpenAIProvider.makeRequest(
            apiKey: "",
            baseURL: trailingSlash,
            model: "llama3",
            systemPrompt: nil,
            input: "test",
            options: ProviderOptions(baseURL: trailingSlash)
        )
        #expect(req.url?.path == "/v1/chat/completions")
        // Must NOT contain double slash
        #expect(req.url?.absoluteString.contains("//chat") == false)
    }

    // MARK: - Response parsing

    @Test("streams content delta tokens from canned OpenAI SSE")
    func streamDeltas() async throws {
        let session = makeMockSession(body: cannedSSE)
        let provider = OpenAIProvider(apiKey: "sk-test", session: session)

        var tokens: [String] = []
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "Say hello",
            model: "gpt-4o",
            options: ProviderOptions()
        )
        for try await token in stream { tokens.append(token) }

        #expect(tokens == ["Hello", " world"])
    }

    @Test("empty delta content is skipped")
    func emptyDeltaSkipped() async throws {
        // Some OpenAI responses send an empty delta for the first chunk.
        let sseWithEmpty = Data("""
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"Hi"}}]}

        data: [DONE]

        """.utf8)
        let session = makeMockSession(body: sseWithEmpty)
        let provider = OpenAIProvider(apiKey: "sk-test", session: session)

        var tokens: [String] = []
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "hi",
            model: "gpt-4o",
            options: ProviderOptions()
        )
        for try await token in stream { tokens.append(token) }

        #expect(tokens == ["Hi"])
    }
}
