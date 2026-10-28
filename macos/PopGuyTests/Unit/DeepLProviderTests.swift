// DeepLProviderTests.swift
// PopGuyTests
//
// Tests request shape and response mapping for DeepLProvider (non-streaming).
// DeepL returns a single JSON response; the adapter wraps it as a
// single-element AsyncThrowingStream.

import Foundation
import Testing
@testable import PopGuy

// .serialized: all response-parsing tests in this suite share the mock host
// "api-free.deepl.com" — serialising prevents intra-suite concurrent access
// to the same registry slot.
@Suite("DeepLProvider", .serialized)
struct DeepLProviderTests {

    // Host key for this suite's mock handler (free-tier key used in all mock tests).
    private static let mockHost = "api-free.deepl.com"

    // MARK: - Helpers

    private func makeMockSession(body: Data, statusCode: Int = 200) -> URLSession {
        MockURLProtocol.register(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: statusCode,
                              headers: ["Content-Type": "application/json"]),
             body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private let cannedResponse = Data("""
    {
        "translations": [
            {
                "text": "Bonjour le monde",
                "detected_source_language": "EN"
            }
        ]
    }
    """.utf8)

    // MARK: - Request shape

    @Test("free-tier request targets api-free.deepl.com/v2/translate")
    func requestURLFree() throws {
        let req = try DeepLProvider.makeRequest(
            apiKey: "test-key:fx",
            isPro: false,
            input: "Hello",
            targetLanguage: "FR",
            sourceLanguage: nil
        )
        #expect(req.url?.host == "api-free.deepl.com")
        #expect(req.url?.path == "/v2/translate")
    }

    @Test("pro request targets api.deepl.com/v2/translate")
    func requestURLPro() throws {
        let req = try DeepLProvider.makeRequest(
            apiKey: "prokey",
            isPro: true,
            input: "Hello",
            targetLanguage: "FR",
            sourceLanguage: nil
        )
        #expect(req.url?.host == "api.deepl.com")
        #expect(req.url?.path == "/v2/translate")
    }

    @Test("request has DeepL-Auth-Key authorization header")
    func requestAuthHeader() throws {
        let req = try DeepLProvider.makeRequest(
            apiKey: "mydeeplkey",
            isPro: false,
            input: "hello",
            targetLanguage: "EN",
            sourceLanguage: nil
        )
        #expect(req.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key mydeeplkey")
    }

    @Test("request body contains text array and UPPERCASE target_lang")
    func requestBodyShape() throws {
        let req = try DeepLProvider.makeRequest(
            apiKey: "key",
            isPro: false,
            input: "Hello world",
            targetLanguage: "FR",
            sourceLanguage: nil
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let texts = body["text"] as? [String]
        #expect(texts == ["Hello world"])
        #expect(body["target_lang"] as? String == "FR")
    }

    @Test("lowercase target language is uppercased in request")
    func targetLanguageUppercased() throws {
        let req = try DeepLProvider.makeRequest(
            apiKey: "key",
            isPro: false,
            input: "hello",
            targetLanguage: "vi",
            sourceLanguage: nil
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["target_lang"] as? String == "VI")
    }

    @Test("source_lang included when sourceLanguage provided")
    func sourceLangIncluded() throws {
        let req = try DeepLProvider.makeRequest(
            apiKey: "key",
            isPro: false,
            input: "hello",
            targetLanguage: "FR",
            sourceLanguage: "EN"
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["source_lang"] as? String == "EN")
    }

    @Test("source_lang omitted when sourceLanguage is nil")
    func sourceLangOmitted() throws {
        let req = try DeepLProvider.makeRequest(
            apiKey: "key",
            isPro: false,
            input: "hello",
            targetLanguage: "FR",
            sourceLanguage: nil
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["source_lang"] == nil)
    }

    @Test("formality included in body when provided")
    func formalityIncluded() throws {
        let req = try DeepLProvider.makeRequest(
            apiKey: "key",
            isPro: false,
            input: "hello",
            targetLanguage: "FR",
            sourceLanguage: nil,
            formality: "prefer_less"
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["formality"] as? String == "prefer_less")
    }

    @Test("formality omitted when nil")
    func formalityOmitted() throws {
        let req = try DeepLProvider.makeRequest(
            apiKey: "key",
            isPro: false,
            input: "hello",
            targetLanguage: "FR",
            sourceLanguage: nil,
            formality: nil
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["formality"] == nil)
    }

    // MARK: - Response parsing

    @Test("maps translations[0].text to single stream element")
    func mapsTranslationResult() async throws {
        let session = makeMockSession(body: cannedResponse)
        let provider = DeepLProvider(apiKey: "key:fx", session: session)

        var tokens: [String] = []
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "Hello world",
            model: "",
            options: ProviderOptions(targetLanguage: "FR")
        )
        for try await token in stream { tokens.append(token) }

        #expect(tokens == ["Bonjour le monde"])
    }

    @Test("throws missingOption when targetLanguage is nil")
    func throwsWhenNoTargetLanguage() async throws {
        let session = makeMockSession(body: cannedResponse)
        let provider = DeepLProvider(apiKey: "key:fx", session: session)

        var threw = false
        do {
            _ = try await provider.stream(
                systemPrompt: nil,
                input: "hello",
                model: "",
                options: ProviderOptions()  // no targetLanguage
            )
        } catch let err as ProviderError {
            if case .missingOption = err { threw = true }
        }
        #expect(threw)
    }
}
