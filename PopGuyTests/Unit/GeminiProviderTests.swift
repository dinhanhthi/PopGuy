// GeminiProviderTests.swift
// PopGuyTests
//
// Tests for GeminiProvider: request shape, delta parsing, URL safety.
//
// Covers:
//   - makeRequest: URL shape, auth header, body fields
//   - parseDeltas: multi-part concatenation, no-candidate skip, error surfacing
//   - Host-routing regression: GLM/OpenRouter resolve their own defaultBaseURL,
//     Gemini produces no override (native), GLM/Custom with empty endpoint throws.

import Foundation
import Testing
@testable import PopGuy

// MARK: - GeminiProviderTests

@Suite("GeminiProvider", .serialized)
struct GeminiProviderTests {

    private static let mockHost = "generativelanguage.googleapis.com"

    private func makeMockSession(body: Data, statusCode: Int = 200) -> URLSession {
        MockURLProtocol.register(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: statusCode,
                              headers: ["Content-Type": "text/event-stream"]),
             body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - makeRequest: URL shape

    @Test("request URL targets native base /models/<model>:streamGenerateContent")
    func requestURLShape() throws {
        let req = try GeminiProvider.makeRequest(
            apiKey: "gapi-key",
            baseURL: nil,
            model: "gemini-2.5-flash",
            systemPrompt: nil,
            input: "hello",
            options: ProviderOptions()
        )
        #expect(req.url?.host == "generativelanguage.googleapis.com")
        #expect(req.url?.path == "/v1beta/models/gemini-2.5-flash:streamGenerateContent")
    }

    @Test("request URL has alt=sse query item")
    func requestURLHasAltSSE() throws {
        let req = try GeminiProvider.makeRequest(
            apiKey: "key",
            baseURL: nil,
            model: "gemini-2.5-pro",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
        let altItem = components?.queryItems?.first(where: { $0.name == "alt" })
        #expect(altItem?.value == "sse")
    }

    @Test("request method is POST")
    func requestMethod() throws {
        let req = try GeminiProvider.makeRequest(
            apiKey: "key",
            baseURL: nil,
            model: "gemini-2.5-flash",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        #expect(req.httpMethod == "POST")
    }

    // MARK: - makeRequest: auth header

    @Test("request uses x-goog-api-key header, NOT Authorization Bearer")
    func requestApiKeyHeader() throws {
        let req = try GeminiProvider.makeRequest(
            apiKey: "my-gapi-key",
            baseURL: nil,
            model: "gemini-2.5-flash",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "my-gapi-key")
        // API key must NOT appear in the URL (query params or path).
        #expect(req.url?.absoluteString.contains("my-gapi-key") == false)
        // Bearer header must be absent.
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - makeRequest: body fields

    @Test("systemInstruction is included when systemPrompt is non-nil")
    func requestBodySystemInstruction() throws {
        let req = try GeminiProvider.makeRequest(
            apiKey: "key",
            baseURL: nil,
            model: "gemini-2.5-flash",
            systemPrompt: "Be helpful.",
            input: "hi",
            options: ProviderOptions()
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let si = body["systemInstruction"] as? [String: Any]
        let parts = si?["parts"] as? [[String: Any]]
        #expect(parts?.first?["text"] as? String == "Be helpful.")
    }

    @Test("systemInstruction is omitted when systemPrompt is nil")
    func requestBodyNoSystemInstruction() throws {
        let req = try GeminiProvider.makeRequest(
            apiKey: "key",
            baseURL: nil,
            model: "gemini-2.5-flash",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["systemInstruction"] == nil)
    }

    @Test("generationConfig.maxOutputTokens is present in body")
    func requestBodyMaxOutputTokens() throws {
        let req = try GeminiProvider.makeRequest(
            apiKey: "key",
            baseURL: nil,
            model: "gemini-2.5-flash",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions(maxTokens: 2048)
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let genConfig = body["generationConfig"] as? [String: Any]
        #expect(genConfig?["maxOutputTokens"] as? Int == 2048)
    }

    // MARK: - makeRequest: thinking disabled (Flash family only)

    @Test("Flash model sends thinkingConfig.thinkingBudget: 0 to disable thinking")
    func requestBodyDisablesThinkingForFlash() throws {
        for model in ["gemini-2.5-flash", "gemini-2.5-flash-lite"] {
            let req = try GeminiProvider.makeRequest(
                apiKey: "key",
                baseURL: nil,
                model: model,
                systemPrompt: nil,
                input: "hi",
                options: ProviderOptions()
            )
            let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let genConfig = body["generationConfig"] as? [String: Any]
            let thinkingConfig = genConfig?["thinkingConfig"] as? [String: Any]
            #expect(thinkingConfig?["thinkingBudget"] as? Int == 0, "expected budget 0 for \(model)")
        }
    }

    @Test("Pro model omits thinkingConfig — Pro cannot disable thinking (budget 0 → 400)")
    func requestBodyOmitsThinkingForPro() throws {
        let req = try GeminiProvider.makeRequest(
            apiKey: "key",
            baseURL: nil,
            model: "gemini-2.5-pro",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let genConfig = body["generationConfig"] as? [String: Any]
        #expect(genConfig?["thinkingConfig"] == nil)
    }

    @Test("Non-Flash model (Gemma) omits thinkingConfig — rejects the field (→ 400)")
    func requestBodyOmitsThinkingForGemma() throws {
        let req = try GeminiProvider.makeRequest(
            apiKey: "key",
            baseURL: nil,
            model: "gemma-3-27b-it",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let genConfig = body["generationConfig"] as? [String: Any]
        #expect(genConfig?["thinkingConfig"] == nil)
    }

    // MARK: - makeRequest: URL path safety (model encoding)

    @Test("model containing '?' does not pollute the URL query string")
    func modelWithQueryCharEncoded() throws {
        let req = try GeminiProvider.makeRequest(
            apiKey: "key",
            baseURL: nil,
            model: "gemini?evil=true",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        // The query string should only contain alt=sse, not evil=true.
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
        let queryNames = components?.queryItems?.map { $0.name } ?? []
        #expect(!queryNames.contains("evil"))
        #expect(queryNames.contains("alt"))
    }

    @Test("model containing '#' does not truncate the URL path")
    func modelWithFragmentCharEncoded() throws {
        // A '#' in the model id would normally truncate the URL at the fragment.
        // After encoding it must appear as %23 in the absoluteString.
        let req = try GeminiProvider.makeRequest(
            apiKey: "key",
            baseURL: nil,
            model: "gemini#fragment",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        // URL fragment must be nil (# was encoded into the path, not as a fragment).
        #expect(req.url?.fragment == nil)
        // The percent-encoded form must appear in the raw URL string (not decoded path).
        // URL.path returns the decoded form; absoluteString preserves percent-encoding.
        #expect(req.url?.absoluteString.contains("%23") == true)
    }

    @Test("model containing '/' is percent-encoded so it cannot rewrite the URL path")
    func modelWithSlashEncoded() throws {
        // A '/' in the model id (e.g. "gemini/evil") would otherwise split the URL
        // path, pushing ':streamGenerateContent' to a different segment.
        // After encoding it must appear as %2F and the ':streamGenerateContent' suffix
        // and 'alt=sse' query must remain structurally intact.
        let req = try GeminiProvider.makeRequest(
            apiKey: "key",
            baseURL: nil,
            model: "gemini/evil",
            systemPrompt: nil,
            input: "hi",
            options: ProviderOptions()
        )
        // The percent-encoded form must appear in the raw URL string.
        #expect(req.url?.absoluteString.contains("%2F") == true)
        // The ':streamGenerateContent' action suffix must still be present.
        #expect(req.url?.absoluteString.contains(":streamGenerateContent") == true)
        // The 'alt=sse' query parameter must still be present.
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
        let altItem = components?.queryItems?.first(where: { $0.name == "alt" })
        #expect(altItem?.value == "sse")
    }

    // MARK: - parseDeltas: multi-part chunks

    @Test("parseDeltas concatenates text from multiple parts in one chunk")
    func parseDeltasMultiPart() async throws {
        // Gemini may return multiple parts in a single candidate.
        let multiPartSSE = Data("""
        data: {"candidates":[{"content":{"parts":[{"text":"Hello"},{"text":" world"}]}}]}

        data: {"candidates":[{"content":{"parts":[{"text":"!"}]}}]}

        """.utf8)

        let session = makeMockSession(body: multiPartSSE)
        let provider = GeminiProvider(apiKey: "key", session: session)

        var tokens: [String] = []
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "hi",
            model: "gemini-2.5-flash",
            options: ProviderOptions()
        )
        for try await token in stream { tokens.append(token) }

        #expect(tokens == ["Hello world", "!"])
    }

    @Test("parseDeltas skips chunks with no candidates")
    func parseDeltasSkipsNoCandidates() async throws {
        // The final usageMetadata-only chunk has no candidates array.
        let mixedSSE = Data("""
        data: {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}

        data: {"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":1}}

        """.utf8)

        let session = makeMockSession(body: mixedSSE)
        let provider = GeminiProvider(apiKey: "key", session: session)

        var tokens: [String] = []
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "hi",
            model: "gemini-2.5-flash",
            options: ProviderOptions()
        )
        for try await token in stream { tokens.append(token) }

        #expect(tokens == ["Hello"])
    }

    @Test("parseDeltas surfaces in-stream error object as ProviderError.apiError")
    func parseDeltasInStreamError() async throws {
        let errorSSE = Data("""
        data: {"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}

        """.utf8)

        let session = makeMockSession(body: errorSSE)
        let provider = GeminiProvider(apiKey: "key", session: session)

        var threwApiError = false
        do {
            let stream = try await provider.stream(
                systemPrompt: nil,
                input: "hi",
                model: "gemini-2.5-flash",
                options: ProviderOptions()
            )
            for try await _ in stream {}
        } catch let err as ProviderError {
            if case .apiError(let status, _) = err, status == "RESOURCE_EXHAUSTED" {
                threwApiError = true
            }
        }
        #expect(threwApiError)
    }

    @Test("parseDeltas streams text from a single-part chunk")
    func parseDeltasSinglePart() async throws {
        let singleSSE = Data("""
        data: {"candidates":[{"content":{"parts":[{"text":"Hi there"}]}}]}

        """.utf8)

        let session = makeMockSession(body: singleSSE)
        let provider = GeminiProvider(apiKey: "key", session: session)

        var tokens: [String] = []
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "hi",
            model: "gemini-2.5-flash",
            options: ProviderOptions()
        )
        for try await token in stream { tokens.append(token) }

        #expect(tokens == ["Hi there"])
    }
}

// MARK: - HostRoutingTests

/// Regression tests: verifies that each ProviderKind resolves to the expected
/// base URL — never accidentally routing GLM/OpenRouter/Custom keys to api.openai.com.
@Suite("HostRouting")
struct HostRoutingTests {

    // Helper: resolve base URL via ActionEngine's full dispatch path using a mock
    // provider that records options. Uses the same factory as production.
    // We test the ActionEngine dispatch guard directly by calling dispatch() with
    // appropriate configs and observing either the captured URL or a thrown error.

    private func makeEngine(mock: MockProvider) -> ActionEngine {
        ActionEngine { _, _ in mock }
    }

    // MARK: - GLM resolves to api.z.ai

    @Test("GLM dispatch resolves to z.ai base URL, not api.openai.com")
    func glmResolvesToZAI() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .improve, providerKind: .glm, model: "glm-4.7")
        let glmBase = ProviderKind.glm.defaultBaseURL!.absoluteString

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input: "test",
            config: config,
            apiKey: "glm-key",
            baseURLOverride: glmBase
        )
        let host = mock.capturedOptions.baseURL?.host
        #expect(host == "api.z.ai")
        #expect(host != "api.openai.com")
    }

    // MARK: - OpenRouter resolves to openrouter.ai

    @Test("OpenRouter dispatch resolves to openrouter.ai base URL, not api.openai.com")
    func openRouterResolvesToOpenRouter() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .improve, providerKind: .openRouter, model: "openai/gpt-4o")
        let orBase = ProviderKind.openRouter.defaultBaseURL!.absoluteString

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input: "test",
            config: config,
            apiKey: "or-key",
            baseURLOverride: orBase
        )
        let host = mock.capturedOptions.baseURL?.host
        #expect(host == "openrouter.ai")
        #expect(host != "api.openai.com")
    }

    // MARK: - Gemini produces no baseURL override (uses native base)

    @Test("Gemini dispatch passes no baseURL override — GeminiProvider uses native base")
    func geminiProducesNoOverride() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .improve, providerKind: .gemini, model: "gemini-2.5-flash")

        // No baseURLOverride means GeminiProvider falls back to its own nativeBase.
        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input: "test",
            config: config,
            apiKey: "gapi-key",
            baseURLOverride: nil
        )
        // The mock provider receives nil baseURL — GeminiProvider's native base is
        // resolved internally, not via ProviderOptions.
        #expect(mock.capturedOptions.baseURL == nil)
    }

    // MARK: - GLM with empty endpoint throws before hitting api.openai.com

    @Test("GLM with empty baseURLOverride throws ProviderError.transport, never hits api.openai.com")
    func glmEmptyEndpointThrows() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .improve, providerKind: .glm, model: "glm-4.7")

        var threwTransport = false
        do {
            _ = try await engine.dispatch(
                action: .improve(customPrompt: nil, tone: .neutral),
                input: "test",
                config: config,
                apiKey: "glm-key",
                baseURLOverride: nil         // nil = no endpoint configured
            )
        } catch let err as ProviderError {
            if case .transport(let msg) = err, msg.contains("No endpoint") {
                threwTransport = true
            }
        }
        #expect(threwTransport, "Expected ProviderError.transport when GLM has no endpoint")
        // The mock should never have been called (factory never executed dispatch).
        #expect(mock.capturedInput.isEmpty, "Provider must not be called when endpoint is missing")
    }

    @Test("Custom with empty baseURLOverride throws ProviderError.transport")
    func customEmptyEndpointThrows() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .improve, providerKind: .custom, model: "my-model")

        var threwTransport = false
        do {
            _ = try await engine.dispatch(
                action: .improve(customPrompt: nil, tone: .neutral),
                input: "test",
                config: config,
                apiKey: "custom-key",
                baseURLOverride: ""          // empty string = no endpoint configured
            )
        } catch let err as ProviderError {
            if case .transport(let msg) = err, msg.contains("No endpoint") {
                threwTransport = true
            }
        }
        #expect(threwTransport, "Expected ProviderError.transport when Custom has no endpoint")
    }

    @Test("OpenRouter with empty baseURLOverride throws ProviderError.transport")
    func openRouterEmptyEndpointThrows() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .improve, providerKind: .openRouter, model: "openai/gpt-4o")

        var threwTransport = false
        do {
            _ = try await engine.dispatch(
                action: .improve(customPrompt: nil, tone: .neutral),
                input: "test",
                config: config,
                apiKey: "or-key",
                baseURLOverride: "   "       // whitespace only = treated as empty
            )
        } catch let err as ProviderError {
            if case .transport(let msg) = err, msg.contains("No endpoint") {
                threwTransport = true
            }
        }
        #expect(threwTransport, "Expected ProviderError.transport when OpenRouter override is blank")
    }

    // MARK: - Malformed endpoint throws before reaching api.openai.com

    @Test("GLM with malformed base URL (contains space) throws ProviderError.transport, never hits api.openai.com")
    func glmMalformedEndpointThrows() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .improve, providerKind: .glm, model: "glm-4.7")

        var threwTransport = false
        do {
            _ = try await engine.dispatch(
                action: .improve(customPrompt: nil, tone: .neutral),
                input: "test",
                config: config,
                apiKey: "glm-key",
                baseURLOverride: "http://my host/v1"  // space in host — invalid URL
            )
        } catch let err as ProviderError {
            if case .transport = err {
                threwTransport = true
            }
        }
        #expect(threwTransport, "Expected ProviderError.transport when GLM base URL is malformed")
        #expect(mock.capturedInput.isEmpty, "Provider must not be called when endpoint is malformed")
    }

    @Test("OpenRouter with malformed base URL throws ProviderError.transport, never hits api.openai.com")
    func openRouterMalformedEndpointThrows() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .improve, providerKind: .openRouter, model: "openai/gpt-4o")

        var threwTransport = false
        do {
            _ = try await engine.dispatch(
                action: .improve(customPrompt: nil, tone: .neutral),
                input: "test",
                config: config,
                apiKey: "or-key",
                baseURLOverride: "http://bad url/v1"  // space in host — invalid URL
            )
        } catch let err as ProviderError {
            if case .transport = err {
                threwTransport = true
            }
        }
        #expect(threwTransport, "Expected ProviderError.transport when OpenRouter base URL is malformed")
        #expect(mock.capturedInput.isEmpty, "Provider must not be called when endpoint is malformed")
    }
}
