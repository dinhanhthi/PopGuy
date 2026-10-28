// ProviderModelValidatorTests.swift
// PopGuyTests
//
// Unit tests for ProviderModelValidator.
//
// Strategy: all tests are fully offline. Three approaches are used depending
// on what is being tested:
//
//   (a) Injected MockProvider (via providerFactory parameter) — for testing
//       that a successful token → returns normally, and that a ProviderError
//       thrown by the adapter propagates out unchanged.
//
//   (b) Injected MockURLProtocol session (via session parameter) — for testing
//       the production-path adapter selection for Gemini/GLM/OpenRouter/Custom
//       which are session-injectable in makeAdapter().
//
//   (c) Direct return-early path — for kinds where usesModel == false, verify
//       no adapter is ever called (provider factory receives no call).
//
// No real network calls are made.

import Foundation
import Testing
@testable import PopGuy

// MARK: - CallTracker

/// Thread-safe boolean flag for tracking whether a closure was called.
/// @unchecked Sendable: only used in test code; mutation is sequential within
/// a single test (factory is called synchronously before or after validate).
final class CallTracker: @unchecked Sendable {
    private(set) var wasCalled = false
    func markCalled() { wasCalled = true }
}

// MARK: - ProviderModelValidatorTests

@Suite("ProviderModelValidator", .serialized)
struct ProviderModelValidatorTests {

    // MARK: - Helpers

    /// A MockProvider that succeeds (emits one token) by default.
    private func successProvider(tokens: [String] = ["Hi"]) -> MockProvider {
        let mock = MockProvider()
        mock.tokensToEmit = tokens
        return mock
    }

    /// A MockProvider factory that always returns the given provider.
    private func factory(for provider: any Provider) -> ProviderFactory {
        { _, _ in provider }
    }

    // MARK: - (a) Injected MockProvider: successful token → returns normally

    @Test("successful first token → validate returns without throwing")
    func successfulTokenReturnsNormally() async throws {
        let mock = successProvider()
        // Should complete without throwing.
        try await ProviderModelValidator.validate(
            kind: .openAI,
            apiKey: "sk-test",
            model: "gpt-4o",
            providerFactory: factory(for: mock)
        )
        // If we reach this line, validate returned normally — correct behavior.
        #expect(mock.capturedModel == "gpt-4o")
    }

    @Test("clean finish with zero tokens → validate returns without throwing")
    func cleanFinishNoTokensReturnsNormally() async throws {
        let mock = successProvider(tokens: [])
        // Zero-token clean completion is also a success (some providers may respond
        // with finish_reason=stop and no content for very short completions).
        try await ProviderModelValidator.validate(
            kind: .anthropic,
            apiKey: "sk-ant-test",
            model: "claude-sonnet-4-6",
            providerFactory: factory(for: mock)
        )
        #expect(mock.capturedModel == "claude-sonnet-4-6")
    }

    // MARK: - (a) Injected MockProvider: ProviderError propagation

    @Test("ProviderError.httpError(404) → rethrown from validate")
    func httpError404Propagates() async throws {
        final class ThrowingProvider: Provider, @unchecked Sendable {
            nonisolated func stream(
                systemPrompt: String?,
                input: String,
                model: String,
                options: ProviderOptions
            ) async throws -> AsyncThrowingStream<String, Error> {
                throw ProviderError.httpError(statusCode: 404, body: "model not found")
            }
        }

        var caughtError: Error?
        do {
            try await ProviderModelValidator.validate(
                kind: .openAI,
                apiKey: "sk-test",
                model: "gpt-nonexistent",
                providerFactory: { _, _ in ThrowingProvider() }
            )
        } catch {
            caughtError = error
        }

        let providerError = try #require(caughtError as? ProviderError)
        if case .httpError(let code, _) = providerError {
            #expect(code == 404)
        } else {
            Issue.record("Expected ProviderError.httpError(404), got \(providerError)")
        }
    }

    @Test("ProviderError.httpError(401) → rethrown from validate")
    func httpError401Propagates() async throws {
        final class UnauthorizedProvider: Provider, @unchecked Sendable {
            nonisolated func stream(
                systemPrompt: String?,
                input: String,
                model: String,
                options: ProviderOptions
            ) async throws -> AsyncThrowingStream<String, Error> {
                throw ProviderError.httpError(statusCode: 401, body: "Unauthorized")
            }
        }

        var caughtError: Error?
        do {
            try await ProviderModelValidator.validate(
                kind: .anthropic,
                apiKey: "bad-key",
                model: "claude-sonnet-4-6",
                providerFactory: { _, _ in UnauthorizedProvider() }
            )
        } catch {
            caughtError = error
        }

        let providerError = try #require(caughtError as? ProviderError)
        if case .httpError(let code, _) = providerError {
            #expect(code == 401)
        } else {
            Issue.record("Expected ProviderError.httpError(401), got \(providerError)")
        }
    }

    @Test("in-stream ProviderError.apiError → rethrown from validate")
    func inStreamApiErrorPropagates() async throws {
        // Simulates a provider that starts the stream then throws mid-stream
        // (e.g. Anthropic/Gemini in-stream error events).
        final class InStreamErrorProvider: Provider, @unchecked Sendable {
            nonisolated func stream(
                systemPrompt: String?,
                input: String,
                model: String,
                options: ProviderOptions
            ) async throws -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ProviderError.apiError("model_not_found", "The model does not exist"))
                }
            }
        }

        var caughtError: Error?
        do {
            try await ProviderModelValidator.validate(
                kind: .openAI,
                apiKey: "sk-test",
                model: "gpt-bad",
                providerFactory: { _, _ in InStreamErrorProvider() }
            )
        } catch {
            caughtError = error
        }

        let providerError = try #require(caughtError as? ProviderError)
        if case .apiError(let kind, _) = providerError {
            #expect(kind == "model_not_found")
        } else {
            Issue.record("Expected ProviderError.apiError, got \(providerError)")
        }
    }

    // MARK: - (c) !usesModel kinds → returns early, no adapter call

    @Test("deepL (usesModel=false) → returns early without calling the adapter")
    func deepLReturnsEarly() async throws {
        let tracker = CallTracker()
        let factory: ProviderFactory = { _, _ in
            tracker.markCalled()
            return MockProvider()
        }

        // DeepL.usesModel == false — should return without calling factory.
        try await ProviderModelValidator.validate(
            kind: .deepL,
            apiKey: "deepl-key",
            model: "default",
            providerFactory: factory
        )

        #expect(!tracker.wasCalled, "DeepL usesModel=false: factory must not be called")
    }

    @Test("googleTranslate (usesModel=false) → returns early without calling the adapter")
    func googleTranslateReturnsEarly() async throws {
        let tracker = CallTracker()
        let factory: ProviderFactory = { _, _ in
            tracker.markCalled()
            return MockProvider()
        }

        try await ProviderModelValidator.validate(
            kind: .googleTranslate,
            apiKey: "gct-key",
            model: "default",
            providerFactory: factory
        )

        #expect(!tracker.wasCalled, "GoogleTranslate usesModel=false: factory must not be called")
    }

    // MARK: - ProviderOptions contract

    @Test("validate passes maxTokens=1 to provider")
    func passesMaxTokens1() async throws {
        let mock = successProvider()
        try await ProviderModelValidator.validate(
            kind: .openAI,
            apiKey: "sk-test",
            model: "gpt-4o",
            providerFactory: factory(for: mock)
        )
        #expect(mock.capturedOptions.maxTokens == 1)
    }

    @Test("validate passes fixed input 'Hi' to provider")
    func passesFixedInputHi() async throws {
        let mock = successProvider()
        try await ProviderModelValidator.validate(
            kind: .openAI,
            apiKey: "sk-test",
            model: "gpt-4o",
            providerFactory: factory(for: mock)
        )
        #expect(mock.capturedInput == "Hi")
    }

    @Test("validate passes nil systemPrompt to provider")
    func passesNilSystemPrompt() async throws {
        let mock = successProvider()
        try await ProviderModelValidator.validate(
            kind: .anthropic,
            apiKey: "sk-ant",
            model: "claude-sonnet-4-6",
            providerFactory: factory(for: mock)
        )
        #expect(mock.capturedSystemPrompt == nil)
    }

    // MARK: - baseURL routing (injected factory)

    @Test("gemini kind passes nil baseURL to provider (ignores caller-supplied URL)")
    func geminiPassesNilBaseURL() async throws {
        let mock = successProvider()
        let callerURL = URL(string: "https://some.other.host/v1")!
        try await ProviderModelValidator.validate(
            kind: .gemini,
            apiKey: "gapi-key",
            baseURL: callerURL,
            model: "gemini-2.5-flash",
            providerFactory: factory(for: mock)
        )
        // Gemini must NEVER receive a caller-supplied baseURL — it uses native base.
        #expect(mock.capturedOptions.baseURL == nil)
    }

    @Test("openAI kind passes nil baseURL to provider")
    func openAIPassesNilBaseURL() async throws {
        let mock = successProvider()
        try await ProviderModelValidator.validate(
            kind: .openAI,
            apiKey: "sk-test",
            model: "gpt-4o",
            providerFactory: factory(for: mock)
        )
        #expect(mock.capturedOptions.baseURL == nil)
    }

    @Test("glm kind passes its defaultBaseURL when no caller baseURL supplied")
    func glmUsesDefaultBaseURL() async throws {
        let mock = successProvider()
        try await ProviderModelValidator.validate(
            kind: .glm,
            apiKey: "glm-key",
            baseURL: nil,
            model: "glm-4.7",
            providerFactory: factory(for: mock)
        )
        #expect(mock.capturedOptions.baseURL == ProviderKind.glm.defaultBaseURL)
    }

    @Test("glm kind passes caller-supplied baseURL when provided")
    func glmUsesCallerBaseURL() async throws {
        let mock = successProvider()
        let customURL = URL(string: "https://custom.glm.host/v4")!
        try await ProviderModelValidator.validate(
            kind: .glm,
            apiKey: "glm-key",
            baseURL: customURL,
            model: "glm-4.7",
            providerFactory: factory(for: mock)
        )
        #expect(mock.capturedOptions.baseURL == customURL)
    }

    @Test("openRouter kind passes its defaultBaseURL when no caller baseURL supplied")
    func openRouterUsesDefaultBaseURL() async throws {
        let mock = successProvider()
        try await ProviderModelValidator.validate(
            kind: .openRouter,
            apiKey: "or-key",
            baseURL: nil,
            model: "openai/gpt-4o",
            providerFactory: factory(for: mock)
        )
        #expect(mock.capturedOptions.baseURL == ProviderKind.openRouter.defaultBaseURL)
    }

    @Test("custom kind with no baseURL → returns early without calling the adapter")
    func customNoBaseURLReturnsEarly() async throws {
        let tracker = CallTracker()
        let factory: ProviderFactory = { _, _ in
            tracker.markCalled()
            return MockProvider()
        }

        // No baseURL for custom — cannot validate without an endpoint.
        try await ProviderModelValidator.validate(
            kind: .custom,
            apiKey: "custom-key",
            baseURL: nil,
            model: "my-model",
            providerFactory: factory
        )

        #expect(!tracker.wasCalled, "Custom with no baseURL: factory must not be called")
    }

    @Test("custom kind with baseURL → passes it through to provider")
    func customWithBaseURLPassesThrough() async throws {
        let mock = successProvider()
        let endpoint = URL(string: "https://my-llm.example.com/v1")!
        try await ProviderModelValidator.validate(
            kind: .custom,
            apiKey: "custom-key",
            baseURL: endpoint,
            model: "my-model",
            providerFactory: factory(for: mock)
        )
        #expect(mock.capturedOptions.baseURL == endpoint)
    }

    // MARK: - CLI kinds → return early, no factory call (no subprocess spawn)

    @Test("claudeCLI (CLI subscription kind) → returns early without calling the factory")
    func claudeCLIReturnsEarlyWithoutFactory() async throws {
        let tracker = CallTracker()
        let factory: ProviderFactory = { _, _ in
            tracker.markCalled()
            return MockProvider()
        }

        try await ProviderModelValidator.validate(
            kind: .claudeCLI,
            apiKey: "",
            model: "claude-sonnet-4-6",
            providerFactory: factory
        )

        #expect(!tracker.wasCalled, "claudeCLI: factory must not be called (no subprocess spawn)")
    }

    @Test("codexCLI (CLI subscription kind) → returns early without calling the factory")
    func codexCLIReturnsEarlyWithoutFactory() async throws {
        let tracker = CallTracker()
        let factory: ProviderFactory = { _, _ in
            tracker.markCalled()
            return MockProvider()
        }

        try await ProviderModelValidator.validate(
            kind: .codexCLI,
            apiKey: "",
            model: "codex-mini",
            providerFactory: factory
        )

        #expect(!tracker.wasCalled, "codexCLI: factory must not be called (no subprocess spawn)")
    }

    @Test("geminiCLI (CLI subscription kind) → returns early without calling the factory")
    func geminiCLIReturnsEarlyWithoutFactory() async throws {
        let tracker = CallTracker()
        let factory: ProviderFactory = { _, _ in
            tracker.markCalled()
            return MockProvider()
        }

        try await ProviderModelValidator.validate(
            kind: .geminiCLI,
            apiKey: "",
            model: "gemini-2.5-pro",
            providerFactory: factory
        )

        #expect(!tracker.wasCalled, "geminiCLI: factory must not be called (no subprocess spawn)")
    }

    // MARK: - (b) Session injection: Gemini production path via MockURLProtocol

    @Test("Gemini production adapter: successful SSE response → validate returns normally")
    func geminiProductionAdapterSuccess() async throws {
        let geminiHost = "generativelanguage.googleapis.com"
        let sseBody = Data("""
        data: {"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}

        """.utf8)

        MockURLProtocol.register(host: geminiHost) { _ in
            (MockHTTPResponse(statusCode: 200,
                              headers: ["Content-Type": "text/event-stream"]),
             sseBody)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        // Should complete without throwing — one token received.
        try await ProviderModelValidator.validate(
            kind: .gemini,
            apiKey: "gapi-key",
            model: "gemini-2.5-flash",
            session: session
        )
    }

    @Test("Gemini production adapter: 404 HTTP response → validate throws ProviderError.httpError")
    func geminiProductionAdapter404() async throws {
        let geminiHost = "generativelanguage.googleapis.com"

        MockURLProtocol.register(host: geminiHost) { _ in
            (MockHTTPResponse(statusCode: 404,
                              headers: ["Content-Type": "application/json"]),
             Data("{\"error\":{\"message\":\"model not found\"}}".utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        var threwHttpError = false
        do {
            try await ProviderModelValidator.validate(
                kind: .gemini,
                apiKey: "gapi-key",
                model: "gemini-nonexistent",
                session: session
            )
        } catch let err as ProviderError {
            if case .httpError(let code, _) = err, code == 404 {
                threwHttpError = true
            }
        }
        #expect(threwHttpError, "Expected ProviderError.httpError(404) for Gemini 404 response")
    }
}
