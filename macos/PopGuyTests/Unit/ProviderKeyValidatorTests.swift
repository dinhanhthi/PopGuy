// ProviderKeyValidatorTests.swift
// PopGuyTests
//
// Unit tests for validator routing: asserts that each ProviderKind builds the
// correct validation request (auth header, host) WITHOUT making live network calls.
//
// Strategy: test the underlying static request builders directly
// (GeminiProvider.makeValidationRequest, OpenAIProvider.makeValidationRequest)
// to assert the correct host and auth header are used per provider kind.
// This avoids network dependency while fully covering the routing contract.

import Foundation
import Testing
@testable import PopGuy

// MARK: - ValidatorRequestBuilderTests

@Suite("ValidatorRequestBuilders")
struct ValidatorRequestBuilderTests {

    // MARK: - Gemini validation request

    @Test("Gemini validation request uses x-goog-api-key header, NOT Authorization Bearer")
    func geminiValidationRequestUsesGoogApiKey() throws {
        let req = try GeminiProvider.makeValidationRequest(apiKey: "gapi-key-123")
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "gapi-key-123")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Gemini validation request targets native Gemini host, NOT api.openai.com")
    func geminiValidationRequestTargetsNativeHost() throws {
        let req = try GeminiProvider.makeValidationRequest(apiKey: "gapi-key")
        #expect(req.url?.host == "generativelanguage.googleapis.com")
        #expect(req.url?.host != "api.openai.com")
    }

    @Test("Gemini validation request is GET /v1beta/models")
    func geminiValidationRequestIsGetModels() throws {
        let req = try GeminiProvider.makeValidationRequest(apiKey: "gapi-key")
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path == "/v1beta/models")
    }

    // MARK: - GLM validation request

    @Test("GLM validation request uses Authorization Bearer header")
    func glmValidationRequestUsesBearerAuth() throws {
        let glmBase = try #require(ProviderKind.glm.defaultBaseURL)
        let req = try OpenAIProvider.makeValidationRequest(apiKey: "glm-key-abc", baseURL: glmBase)
        let authHeader = try #require(req.value(forHTTPHeaderField: "Authorization"))
        #expect(authHeader.hasPrefix("Bearer "))
        #expect(authHeader.contains("glm-key-abc"))
    }

    @Test("GLM validation request targets api.z.ai, NOT api.openai.com")
    func glmValidationRequestTargetsZAI() throws {
        let glmBase = try #require(ProviderKind.glm.defaultBaseURL)
        let req = try OpenAIProvider.makeValidationRequest(apiKey: "glm-key", baseURL: glmBase)
        #expect(req.url?.host == "api.z.ai")
        #expect(req.url?.host != "api.openai.com")
    }

    @Test("GLM validation request is GET /models endpoint")
    func glmValidationRequestIsGetModels() throws {
        let glmBase = try #require(ProviderKind.glm.defaultBaseURL)
        let req = try OpenAIProvider.makeValidationRequest(apiKey: "glm-key", baseURL: glmBase)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path.hasSuffix("/models") == true)
    }

    // MARK: - OpenRouter validation request

    @Test("OpenRouter validation request uses Authorization Bearer header")
    func openRouterValidationRequestUsesBearerAuth() throws {
        let orBase = try #require(ProviderKind.openRouter.defaultBaseURL)
        let req = try OpenAIProvider.makeValidationRequest(apiKey: "or-key-xyz", baseURL: orBase)
        let authHeader = try #require(req.value(forHTTPHeaderField: "Authorization"))
        #expect(authHeader.hasPrefix("Bearer "))
        #expect(authHeader.contains("or-key-xyz"))
    }

    @Test("OpenRouter validation request targets openrouter.ai, NOT api.openai.com")
    func openRouterValidationRequestTargetsOpenRouter() throws {
        let orBase = try #require(ProviderKind.openRouter.defaultBaseURL)
        let req = try OpenAIProvider.makeValidationRequest(apiKey: "or-key", baseURL: orBase)
        #expect(req.url?.host == "openrouter.ai")
        #expect(req.url?.host != "api.openai.com")
    }

    @Test("OpenRouter validation request is GET /models endpoint")
    func openRouterValidationRequestIsGetModels() throws {
        let orBase = try #require(ProviderKind.openRouter.defaultBaseURL)
        let req = try OpenAIProvider.makeValidationRequest(apiKey: "or-key", baseURL: orBase)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path.hasSuffix("/models") == true)
    }

    // MARK: - Custom provider validation request

    @Test("Custom provider validation request uses Authorization Bearer header")
    func customValidationRequestUsesBearerAuth() throws {
        let customBase = try #require(URL(string: "https://my-llm.example.com/v1"))
        let req = try OpenAIProvider.makeValidationRequest(apiKey: "custom-key-abc", baseURL: customBase)
        let authHeader = try #require(req.value(forHTTPHeaderField: "Authorization"))
        #expect(authHeader.hasPrefix("Bearer "))
        #expect(authHeader.contains("custom-key-abc"))
    }

    @Test("Custom provider validation request targets the supplied custom host")
    func customValidationRequestTargetsCustomHost() throws {
        let customBase = try #require(URL(string: "https://my-llm.example.com/v1"))
        let req = try OpenAIProvider.makeValidationRequest(apiKey: "custom-key", baseURL: customBase)
        #expect(req.url?.host == "my-llm.example.com")
        #expect(req.url?.host != "api.openai.com")
    }

    @Test("Custom provider validation request is GET /models endpoint")
    func customValidationRequestIsGetModels() throws {
        let customBase = try #require(URL(string: "https://my-llm.example.com/v1"))
        let req = try OpenAIProvider.makeValidationRequest(apiKey: "custom-key", baseURL: customBase)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path.hasSuffix("/models") == true)
    }

    @Test("Custom provider with trailing slash in base URL still produces clean /models path")
    func customValidationRequestWithTrailingSlashBaseURL() throws {
        let customBase = try #require(URL(string: "https://my-llm.example.com/v1/"))
        let req = try OpenAIProvider.makeValidationRequest(apiKey: "custom-key", baseURL: customBase)
        #expect(req.url?.path == "/v1/models")
    }
}
