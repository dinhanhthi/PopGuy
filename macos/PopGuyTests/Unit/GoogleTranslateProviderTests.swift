// GoogleTranslateProviderTests.swift
// PopGuyTests
//
// Tests request shape and response mapping for GoogleTranslateProvider.
//
// Cloud Translation v2 (Basic) — authenticates with an API key in the
// `key` query parameter (NOT OAuth/service-account).
// Non-streaming: result wrapped as a single-element AsyncThrowingStream.

import Foundation
import Testing
@testable import PopGuy

// .serialized: all response-parsing tests in this suite share the mock host
// "translation.googleapis.com" — serialising prevents intra-suite concurrent
// access to the same registry slot.
@Suite("GoogleTranslateProvider", .serialized)
struct GoogleTranslateProviderTests {

    // Host key for this suite's mock handler.
    private static let mockHost = "translation.googleapis.com"

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
        "data": {
            "translations": [
                {
                    "translatedText": "Bonjour le monde",
                    "detectedSourceLanguage": "en"
                }
            ]
        }
    }
    """.utf8)

    // MARK: - Request shape

    @Test("request targets translation.googleapis.com/language/translate/v2")
    func requestURL() throws {
        let req = try GoogleTranslateProvider.makeRequest(
            apiKey: "gcp-key",
            input: "Hello",
            targetLanguage: "fr",
            sourceLanguage: nil
        )
        #expect(req.url?.host == "translation.googleapis.com")
        #expect(req.url?.path == "/language/translate/v2")
    }

    @Test("API key is passed as 'key' query parameter")
    func apiKeyQueryParam() throws {
        let req = try GoogleTranslateProvider.makeRequest(
            apiKey: "my-api-key",
            input: "hello",
            targetLanguage: "es",
            sourceLanguage: nil
        )
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
        let keyParam = components?.queryItems?.first(where: { $0.name == "key" })?.value
        #expect(keyParam == "my-api-key")
    }

    @Test("request body contains q, target, and format:text")
    func requestBodyShape() throws {
        let req = try GoogleTranslateProvider.makeRequest(
            apiKey: "key",
            input: "Hello world",
            targetLanguage: "vi",
            sourceLanguage: nil
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["q"] as? String == "Hello world")
        #expect(body["target"] as? String == "vi")
        #expect(body["format"] as? String == "text")
    }

    @Test("source language included when provided")
    func sourceLangIncluded() throws {
        let req = try GoogleTranslateProvider.makeRequest(
            apiKey: "key",
            input: "hello",
            targetLanguage: "fr",
            sourceLanguage: "en"
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["source"] as? String == "en")
    }

    @Test("source language omitted when nil")
    func sourceLangOmitted() throws {
        let req = try GoogleTranslateProvider.makeRequest(
            apiKey: "key",
            input: "hello",
            targetLanguage: "fr",
            sourceLanguage: nil
        )
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["source"] == nil)
    }

    @Test("request has no Authorization header (key is in query param)")
    func noAuthHeader() throws {
        let req = try GoogleTranslateProvider.makeRequest(
            apiKey: "key",
            input: "hello",
            targetLanguage: "fr",
            sourceLanguage: nil
        )
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Response parsing

    @Test("maps data.translations[0].translatedText to single stream element")
    func mapsTranslationResult() async throws {
        let session = makeMockSession(body: cannedResponse)
        let provider = GoogleTranslateProvider(apiKey: "key", session: session)

        var tokens: [String] = []
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "Hello world",
            model: "",
            options: ProviderOptions(targetLanguage: "fr")
        )
        for try await token in stream { tokens.append(token) }

        #expect(tokens == ["Bonjour le monde"])
    }

    @Test("throws missingOption when targetLanguage is nil")
    func throwsWhenNoTargetLanguage() async throws {
        let session = makeMockSession(body: cannedResponse)
        let provider = GoogleTranslateProvider(apiKey: "key", session: session)

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

    // MARK: - HTML entity decoding

    @Test("apostrophe entity &#39; is decoded")
    func apostropheEntityDecoded() {
        let decoded = GoogleTranslateProvider.decodeHTMLEntities("It&#39;s fine")
        #expect(decoded == "It's fine")
    }

    @Test("ampersand entity &amp; is decoded")
    func ampersandEntityDecoded() {
        let decoded = GoogleTranslateProvider.decodeHTMLEntities("a &amp; b")
        #expect(decoded == "a & b")
    }

    @Test("angle bracket entities are decoded")
    func angleBracketsDecoded() {
        let decoded = GoogleTranslateProvider.decodeHTMLEntities("&lt;tag&gt;")
        #expect(decoded == "<tag>")
    }

    @Test("quote entity &quot; is decoded")
    func quoteEntityDecoded() {
        let decoded = GoogleTranslateProvider.decodeHTMLEntities("say &quot;hello&quot;")
        #expect(decoded == "say \"hello\"")
    }

    @Test("hex numeric character reference is decoded")
    func hexNumericRefDecoded() {
        // &#x27; = apostrophe U+0027
        let decoded = GoogleTranslateProvider.decodeHTMLEntities("it&#x27;s")
        #expect(decoded == "it's")
    }

    @Test("decimal numeric character reference is decoded")
    func decimalNumericRefDecoded() {
        // &#233; = é U+00E9
        let decoded = GoogleTranslateProvider.decodeHTMLEntities("caf&#233;")
        #expect(decoded == "café")
    }

    @Test("string without entities is returned unchanged")
    func plainStringUnchanged() {
        let decoded = GoogleTranslateProvider.decodeHTMLEntities("Hello world")
        #expect(decoded == "Hello world")
    }

    @Test("HTML-escaped translatedText is decoded in full stream pipeline")
    func escapedTextDecodedInStream() async throws {
        // Simulate a Google Translate response returning HTML-escaped text.
        let escapedResponse = Data("""
        {
            "data": {
                "translations": [
                    { "translatedText": "C&#39;est la vie &amp; tout va bien" }
                ]
            }
        }
        """.utf8)
        let session = makeMockSession(body: escapedResponse)
        let provider = GoogleTranslateProvider(apiKey: "key", session: session)

        var tokens: [String] = []
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "That's life and all is well",
            model: "",
            options: ProviderOptions(targetLanguage: "fr")
        )
        for try await token in stream { tokens.append(token) }

        #expect(tokens == ["C'est la vie & tout va bien"])
    }

    // FIX 4: &amp;lt; → &lt; (single decode, not double-decode to <)
    @Test("cascade entity &amp;lt; decodes to &lt; not <")
    func cascadeAmpLtDecodesToLiteral() {
        let decoded = GoogleTranslateProvider.decodeHTMLEntities("&amp;lt;")
        #expect(decoded == "&lt;")
    }

    // FIX 4: &amp;#39; → &#39; (single decode, not double-decode to ')
    @Test("cascade entity &amp;#39; decodes to &#39; not apostrophe")
    func cascadeAmpNumericDecodesToLiteral() {
        let decoded = GoogleTranslateProvider.decodeHTMLEntities("&amp;#39;")
        #expect(decoded == "&#39;")
    }
}
