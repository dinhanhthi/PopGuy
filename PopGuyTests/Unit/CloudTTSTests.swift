// CloudTTSTests.swift
// PopGuyTests
//
// Unit tests for T1.1: TTSProviderKind, TTSProviderConfig, and
// the generic KeychainManager account-string API.
//
// Keychain resilience and collision-safety strategy mirrors
// KeychainManagerTests.swift exactly (UUID-ephemeral service name,
// keychainIsAvailable probe, no real keychain slots touched).

import Foundation
import Security
import Testing
@testable import PopGuy

// MARK: - CloudTTSTests

@Suite("CloudTTS T1.1")
struct CloudTTSTests {

    // MARK: - Keychain helpers (mirrors KeychainManagerTests pattern)

    private func makeManager() -> (KeychainManager, String) {
        let service = "dinh.thi.PopGuy.tests.\(UUID().uuidString)"
        return (KeychainManager(serviceName: service), service)
    }

    private func keychainIsAvailable(service: String) -> Bool {
        let probeAccount = "probe-availability"
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword as String,
            kSecAttrService as String: service,
            kSecAttrAccount as String: probeAccount,
            kSecValueData as String:   Data("probe".utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            let del: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword as String,
                kSecAttrService as String: service,
                kSecAttrAccount as String: probeAccount
            ]
            SecItemDelete(del as CFDictionary)
            return true
        }
        return false
    }

    // MARK: - KeychainManager generic account API

    @Test("setKey/key/deleteKey(account:) round-trips correctly")
    func accountRoundTrip() {
        let (km, service) = makeManager()
        guard keychainIsAvailable(service: service) else { return }

        let account = TTSProviderKind.openAITTS.keychainAccount  // "openai_tts"
        defer { km.deleteKey(account: account) }

        let stored = km.setKey("tts-test-key", account: account)
        #expect(stored == true)

        let retrieved = km.key(account: account)
        #expect(retrieved == "tts-test-key")

        km.deleteKey(account: account)
        #expect(km.key(account: account) == nil)
    }

    @Test("deleteKey(account:) on non-existent item returns true")
    func deleteAccountNonExistentIsIdempotent() {
        let (km, service) = makeManager()
        guard keychainIsAvailable(service: service) else { return }

        let result = km.deleteKey(account: "nonexistent-account")
        #expect(result == true)
    }

    @Test("key(account:) returns nil when nothing is stored")
    func keyAccountReturnsNilWhenEmpty() {
        let (km, service) = makeManager()
        guard keychainIsAvailable(service: service) else { return }

        #expect(km.key(account: "google_cloud_tts") == nil)
    }

    @Test("setKey(account:) overwrites an existing value")
    func overwriteExistingAccountKey() {
        let (km, service) = makeManager()
        guard keychainIsAvailable(service: service) else { return }

        let account = TTSProviderKind.azureTTS.keychainAccount  // "azure_tts"
        defer { km.deleteKey(account: account) }

        km.setKey("azure-first", account: account)
        km.setKey("azure-second", account: account)
        #expect(km.key(account: account) == "azure-second")
    }

    @Test("TTS account slots are distinct from AI provider slots")
    func ttsAndAIAccountsDoNotCollide() {
        let (km, service) = makeManager()
        guard keychainIsAvailable(service: service) else { return }

        defer {
            km.deleteKey(account: TTSProviderKind.openAITTS.keychainAccount)
            km.deleteKey(for: .openAI)
        }

        km.setKey("tts-key", account: TTSProviderKind.openAITTS.keychainAccount)
        km.setKey("ai-key", for: .openAI)

        // "openai_tts" != "openai" — separate slots.
        #expect(km.key(account: TTSProviderKind.openAITTS.keychainAccount) == "tts-key")
        #expect(km.key(for: .openAI) == "ai-key")
    }

    // MARK: - TTSProviderKind metadata

    @Test("TTSProviderKind.id equals rawValue")
    func providerKindIDEqualsRawValue() {
        for kind in TTSProviderKind.allCases {
            #expect(kind.id == kind.rawValue)
        }
    }

    @Test("TTSProviderKind.keychainAccount equals rawValue")
    func keychainAccountEqualsRawValue() {
        for kind in TTSProviderKind.allCases {
            #expect(kind.keychainAccount == kind.rawValue)
        }
    }

    @Test("implemented list contains openAITTS, googleCloudTTS, and azureTTS")
    func implementedContainsAllThreeProviders() {
        #expect(TTSProviderKind.implemented == [.openAITTS, .googleCloudTTS, .azureTTS])
    }

    @Test("usesModel is true only for openAITTS")
    func usesModelOnlyForOpenAI() {
        #expect(TTSProviderKind.openAITTS.usesModel == true)
        #expect(TTSProviderKind.googleCloudTTS.usesModel == false)
        #expect(TTSProviderKind.azureTTS.usesModel == false)
    }

    @Test("openAITTS has a non-nil defaultModel")
    func openAIHasDefaultModel() {
        #expect(TTSProviderKind.openAITTS.defaultModel != nil)
    }

    @Test("azureTTS usesRegion is true; others are false")
    func usesRegionOnlyForAzure() {
        #expect(TTSProviderKind.azureTTS.usesRegion == true)
        #expect(TTSProviderKind.openAITTS.usesRegion == false)
        #expect(TTSProviderKind.googleCloudTTS.usesRegion == false)
    }

    @Test("all implemented providers support speed")
    func allProvidersSupportSpeed() {
        for kind in TTSProviderKind.implemented {
            #expect(kind.supportsSpeed == true, "\(kind.rawValue) should support speed")
        }
    }

    @Test("only google and azure support pitch; openAI does not")
    func pitchSupportMatrix() {
        #expect(TTSProviderKind.openAITTS.supportsPitch == false)
        #expect(TTSProviderKind.googleCloudTTS.supportsPitch == true)
        #expect(TTSProviderKind.azureTTS.supportsPitch == true)
    }

    @Test("SpeakEngineSelection.supportsSpeed/supportsPitch reflect the provider")
    func engineSelectionCapabilityRouting() {
        #expect(SpeakEngineSelection.system.supportsSpeed == true)
        #expect(SpeakEngineSelection.system.supportsPitch == true)
        #expect(SpeakEngineSelection.cloud(.openAITTS).supportsSpeed == true)
        #expect(SpeakEngineSelection.cloud(.openAITTS).supportsPitch == false)
        #expect(SpeakEngineSelection.cloud(.googleCloudTTS).supportsPitch == true)
        #expect(SpeakEngineSelection.cloud(.azureTTS).supportsPitch == true)
    }

    @Test("all providers have non-nil apiKeyURL")
    func allProvidersHaveAPIKeyURL() {
        for kind in TTSProviderKind.allCases {
            #expect(kind.apiKeyURL != nil)
        }
    }

    // MARK: - TTSProviderConfig

    @Test("TTSProviderConfig.default has empty voiceOverrides, nil model and region")
    func configDefaultValues() {
        let config = TTSProviderConfig.default
        #expect(config.voiceOverrides.isEmpty)
        #expect(config.model == nil)
        #expect(config.region == nil)
    }

    @Test("TTSProviderConfig memberwise init sets all fields")
    func configMemberwiseInit() {
        let config = TTSProviderConfig(
            voiceOverrides: ["en-US": "alloy"],
            model: "gpt-4o-mini-tts",
            region: "eastus"
        )
        #expect(config.voiceOverrides == ["en-US": "alloy"])
        #expect(config.model == "gpt-4o-mini-tts")
        #expect(config.region == "eastus")
    }

    @Test("TTSProviderConfig Codable round-trips correctly")
    func configCodableRoundTrip() throws {
        let original = TTSProviderConfig(
            voiceOverrides: ["fr-FR": "echo"],
            model: "gpt-4o-mini-tts",
            region: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TTSProviderConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("TTSProviderConfig decodes from empty JSON blob to defaults")
    func configResilientDecodeFromEmptyObject() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(TTSProviderConfig.self, from: data)
        #expect(decoded == TTSProviderConfig.default)
    }
}

// MARK: - CuratedVoicesTests

@Suite("CloudTTS curatedVoices")
struct CuratedVoicesTests {

    @Test("gpt-4o-mini-tts has 13 curated voices")
    func gptMiniTTSHas13Voices() {
        let voices = TTSProviderKind.openAITTS.curatedVoices(forModel: "gpt-4o-mini-tts")
        #expect(voices.count == 13)
    }

    @Test("gpt-4o-mini-tts voices contain marin and cedar")
    func gptMiniTTSContainsMarinAndCedar() {
        let voices = TTSProviderKind.openAITTS.curatedVoices(forModel: "gpt-4o-mini-tts")
        #expect(voices.contains("marin"))
        #expect(voices.contains("cedar"))
    }

    @Test("tts-1 has 9 curated voices")
    func tts1Has9Voices() {
        let voices = TTSProviderKind.openAITTS.curatedVoices(forModel: "tts-1")
        #expect(voices.count == 9)
    }

    @Test("tts-1 does not contain marin or cedar")
    func tts1DoesNotContainExclusiveVoices() {
        let voices = TTSProviderKind.openAITTS.curatedVoices(forModel: "tts-1")
        #expect(!voices.contains("marin"))
        #expect(!voices.contains("cedar"))
    }

    @Test("tts-1-hd has 9 curated voices (classic set)")
    func tts1HDHas9Voices() {
        let voices = TTSProviderKind.openAITTS.curatedVoices(forModel: "tts-1-hd")
        #expect(voices.count == 9)
    }

    @Test("googleCloudTTS curatedVoices returns empty list")
    func googleCloudTTSHasNoVoices() {
        let voices = TTSProviderKind.googleCloudTTS.curatedVoices(forModel: "any-model")
        #expect(voices.isEmpty)
    }

    @Test("azureTTS curatedVoices returns empty list")
    func azureTTSHasNoVoices() {
        let voices = TTSProviderKind.azureTTS.curatedVoices(forModel: "any-model")
        #expect(voices.isEmpty)
    }
}

// MARK: - ResolveTTSVoiceTests

@Suite("CloudTTS resolveTTSVoice precedence")
struct ResolveTTSVoiceTests {

    @Test("voiceOverrides[languageCode] wins over defaultVoice and adapter default")
    func perLanguageOverrideWins() {
        let config = TTSProviderConfig(
            voiceOverrides: ["en-US": "nova"],
            defaultVoice: "echo"
        )
        let result = resolveTTSVoice(
            languageCode: "en-US",
            config: config,
            provider: OpenAITTSProvider.self
        )
        #expect(result == "nova")
    }

    @Test("defaultVoice wins over adapter default when no per-language override")
    func defaultVoiceWinsOverAdapterDefault() {
        let config = TTSProviderConfig(
            voiceOverrides: [:],
            defaultVoice: "shimmer"
        )
        let result = resolveTTSVoice(
            languageCode: "en-US",
            config: config,
            provider: OpenAITTSProvider.self
        )
        #expect(result == "shimmer")
    }

    @Test("adapter default is used when voiceOverrides and defaultVoice are both nil/empty")
    func adapterDefaultFallthrough() {
        let config = TTSProviderConfig(
            voiceOverrides: [:],
            defaultVoice: nil
        )
        let result = resolveTTSVoice(
            languageCode: "en-US",
            config: config,
            provider: OpenAITTSProvider.self
        )
        // OpenAITTSProvider.defaultVoice(forLanguage:) returns "alloy"
        #expect(result == "alloy")
    }

    @Test("per-language override takes priority over defaultVoice when both present")
    func perLanguageOverrideTakesPriorityOverDefaultVoice() {
        let config = TTSProviderConfig(
            voiceOverrides: ["fr-FR": "onyx"],
            defaultVoice: "nova"
        )
        // fr-FR override exists → should win
        let frResult = resolveTTSVoice(
            languageCode: "fr-FR",
            config: config,
            provider: OpenAITTSProvider.self
        )
        #expect(frResult == "onyx")

        // ja-JP has no override → defaultVoice wins
        let jaResult = resolveTTSVoice(
            languageCode: "ja-JP",
            config: config,
            provider: OpenAITTSProvider.self
        )
        #expect(jaResult == "nova")
    }
}

// MARK: - TTSProviderConfigDefaultVoiceTests

@Suite("CloudTTS TTSProviderConfig defaultVoice field")
struct TTSProviderConfigDefaultVoiceTests {

    @Test("TTSProviderConfig.default has nil defaultVoice")
    func defaultConfigHasNilDefaultVoice() {
        #expect(TTSProviderConfig.default.defaultVoice == nil)
    }

    @Test("defaultVoice set in memberwise init round-trips via Codable")
    func defaultVoiceCodableRoundTrip() throws {
        let original = TTSProviderConfig(defaultVoice: "marin")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TTSProviderConfig.self, from: data)
        #expect(decoded.defaultVoice == "marin")
    }

    @Test("old blob without defaultVoice decodes to nil")
    func oldBlobDecodesToNilDefaultVoice() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(TTSProviderConfig.self, from: data)
        #expect(decoded.defaultVoice == nil)
    }
}

// MARK: - OpenAITTSProviderTests

@Suite("CloudTTS T1.3 OpenAITTSProvider")
struct OpenAITTSProviderTests {

    // MARK: defaultVoice

    @Test("defaultVoice(forLanguage:) returns a non-empty string for en-US")
    func defaultVoiceIsNonEmpty() {
        let voice = OpenAITTSProvider.defaultVoice(forLanguage: "en-US")
        #expect(!voice.isEmpty)
    }

    @Test("defaultVoice returns the same voice regardless of language")
    func defaultVoiceIsLanguageIndependent() {
        let en = OpenAITTSProvider.defaultVoice(forLanguage: "en-US")
        let fr = OpenAITTSProvider.defaultVoice(forLanguage: "fr-FR")
        let ja = OpenAITTSProvider.defaultVoice(forLanguage: "ja-JP")
        #expect(en == fr)
        #expect(en == ja)
    }

    // MARK: makeSynthesisRequest — header / method / URL

    @Test("makeSynthesisRequest returns POST to /v1/audio/speech")
    func synthesisRequestURLAndMethod() throws {
        let req = try OpenAITTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "alloy",
            languageCode: "en-US",
            config: .default,
            apiKey: "sk-test"
        )
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(req.httpMethod == "POST")
    }

    @Test("makeSynthesisRequest sets Authorization: Bearer header")
    func synthesisRequestBearerHeader() throws {
        let req = try OpenAITTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "alloy",
            languageCode: "en-US",
            config: .default,
            apiKey: "sk-test-key"
        )
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key")
    }

    @Test("makeSynthesisRequest sets Content-Type: application/json")
    func synthesisRequestContentTypeHeader() throws {
        let req = try OpenAITTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "alloy",
            languageCode: "en-US",
            config: .default,
            apiKey: "sk-test"
        )
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    // MARK: makeSynthesisRequest — JSON body

    @Test("makeSynthesisRequest body has correct keys and values")
    func synthesisRequestBodyFields() throws {
        let inputText = "The quick brown fox"
        let req = try OpenAITTSProvider.makeSynthesisRequest(
            text: inputText,
            voice: "nova",
            languageCode: "en-US",
            config: .default,
            apiKey: "sk-test"
        )
        let bodyData = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        let body = try #require(json)
        #expect(body["input"] == inputText)
        #expect(body["voice"] == "nova")
        #expect(body["response_format"] == "mp3")
        #expect(body["model"] != nil)
    }

    @Test("makeSynthesisRequest uses config model override when set")
    func synthesisRequestUsesConfigModel() throws {
        let config = TTSProviderConfig(model: "tts-1-hd")
        let req = try OpenAITTSProvider.makeSynthesisRequest(
            text: "Hi",
            voice: "alloy",
            languageCode: "en-US",
            config: config,
            apiKey: "sk-test"
        )
        let bodyData = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        let body = try #require(json)
        #expect(body["model"] == "tts-1-hd")
    }

    @Test("makeSynthesisRequest includes speed when provided, encoded as a short decimal")
    func synthesisRequestIncludesSpeed() throws {
        let req = try OpenAITTSProvider.makeSynthesisRequest(
            text: "Hi",
            voice: "alloy",
            languageCode: "en-US",
            speed: 1.75,
            pitch: nil,
            config: .default,
            apiKey: "sk-test"
        )
        let bodyData = try #require(req.httpBody)
        // Verify the raw JSON body contains a short decimal literal (no
        // full-precision Double expansion like 1.7500000000000002 that would
        // exceed OpenAI's 16-decimal-place validation limit on gpt-4o-mini-tts).
        let rawBody = try #require(String(data: bodyData, encoding: .utf8))
        #expect(rawBody.contains("\"speed\":1.75"))
        // Also verify it round-trips to 1.75 via JSONSerialization.
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let body = try #require(json)
        let speedValue = (body["speed"] as? NSNumber)?.doubleValue
        #expect(speedValue == 1.75)
    }

    @Test("makeSynthesisRequest encodes a 3-decimal speed without full-precision expansion")
    func synthesisRequestSpeedIsShortDecimal() throws {
        // 0.572 as a Double expands to 0.57199999999999995 under full-precision
        // JSONSerialization; the provider must emit "0.572" instead.
        let req = try OpenAITTSProvider.makeSynthesisRequest(
            text: "Hi",
            voice: "alloy",
            languageCode: "en-US",
            speed: 0.572,
            pitch: nil,
            config: .default,
            apiKey: "sk-test"
        )
        let bodyData = try #require(req.httpBody)
        let rawBody = try #require(String(data: bodyData, encoding: .utf8))
        #expect(rawBody.contains("\"speed\":0.572"))
        #expect(!rawBody.contains("0.5719999999999999"))
    }

    @Test("makeSynthesisRequest omits speed when nil so the provider default applies")
    func synthesisRequestOmitsSpeedWhenNil() throws {
        let req = try OpenAITTSProvider.makeSynthesisRequest(
            text: "Hi",
            voice: "alloy",
            languageCode: "en-US",
            speed: nil,
            pitch: nil,
            config: .default,
            apiKey: "sk-test"
        )
        let bodyData = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let body = try #require(json)
        #expect(body["speed"] == nil)
    }

    @Test("makeSynthesisRequest falls back to TTSProviderKind.openAITTS.defaultModel when config.model is nil")
    func synthesisRequestFallsBackToDefaultModel() throws {
        let req = try OpenAITTSProvider.makeSynthesisRequest(
            text: "Hi",
            voice: "alloy",
            languageCode: "en-US",
            config: .default,
            apiKey: "sk-test"
        )
        let bodyData = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        let body = try #require(json)
        #expect(body["model"] == TTSProviderKind.openAITTS.defaultModel)
    }

    // MARK: makeSynthesisRequest — empty apiKey

    @Test("makeSynthesisRequest throws missingAPIKey for empty key")
    func synthesisRequestEmptyKeyThrows() {
        #expect(throws: TTSProviderError.missingAPIKey) {
            try OpenAITTSProvider.makeSynthesisRequest(
                text: "Hi",
                voice: "alloy",
                languageCode: "en-US",
                config: .default,
                apiKey: ""
            )
        }
    }

    // MARK: decodeAudio

    @Test("decodeAudio returns input bytes unchanged")
    func decodeAudioIdentity() throws {
        let bytes = Data([0xFF, 0xFB, 0x90, 0x00, 0x01])
        let result = try OpenAITTSProvider.decodeAudio(from: bytes)
        #expect(result == bytes)
    }

    @Test("decodeAudio throws decode error for empty data")
    func decodeAudioEmptyThrows() {
        #expect(throws: TTSProviderError.decode("empty audio")) {
            try OpenAITTSProvider.decodeAudio(from: Data())
        }
    }

    // MARK: makeValidationRequest

    @Test("makeValidationRequest returns GET to /v1/models with Bearer header")
    func validationRequestShape() throws {
        let req = try OpenAITTSProvider.makeValidationRequest(
            apiKey: "sk-val-key",
            config: .default
        )
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(req.httpMethod == "GET")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-val-key")
    }

    @Test("makeValidationRequest throws missingAPIKey for empty key")
    func validationRequestEmptyKeyThrows() {
        #expect(throws: TTSProviderError.missingAPIKey) {
            try OpenAITTSProvider.makeValidationRequest(apiKey: "", config: .default)
        }
    }

    // MARK: kind

    @Test("OpenAITTSProvider.kind is .openAITTS")
    func providerKind() {
        #expect(OpenAITTSProvider.kind == .openAITTS)
    }
}

// MARK: - ClearingInvalidDefaultVoiceTests

@Suite("CloudTTS TTSProviderConfig.clearingInvalidDefaultVoice")
struct ClearingInvalidDefaultVoiceTests {

    @Test("clears defaultVoice when it is absent from validVoices")
    func clearsWhenVoiceAbsent() {
        let config = TTSProviderConfig(defaultVoice: "shimmer")
        let result = config.clearingInvalidDefaultVoice(forModel: "tts-1", validVoices: ["alloy", "echo"])
        #expect(result.defaultVoice == nil)
    }

    @Test("keeps defaultVoice when it is present in validVoices")
    func keepsWhenVoicePresent() {
        let config = TTSProviderConfig(defaultVoice: "alloy")
        let result = config.clearingInvalidDefaultVoice(forModel: "tts-1", validVoices: ["alloy", "echo"])
        #expect(result.defaultVoice == "alloy")
    }

    @Test("is a no-op when defaultVoice is nil")
    func noOpWhenDefaultVoiceNil() {
        let config = TTSProviderConfig(defaultVoice: nil)
        let result = config.clearingInvalidDefaultVoice(forModel: "tts-1", validVoices: ["alloy", "echo"])
        #expect(result.defaultVoice == nil)
        // Other fields must be unchanged.
        #expect(result == config)
    }

    @Test("does not modify other fields when clearing")
    func otherFieldsUnchangedWhenClearing() {
        let config = TTSProviderConfig(
            voiceOverrides: ["en-US": "nova"],
            defaultVoice: "shimmer",
            model: "tts-1-hd",
            region: "eastus"
        )
        let result = config.clearingInvalidDefaultVoice(forModel: "tts-1-hd", validVoices: ["alloy"])
        #expect(result.defaultVoice == nil)
        #expect(result.voiceOverrides == ["en-US": "nova"])
        #expect(result.model == "tts-1-hd")
        #expect(result.region == "eastus")
    }
}

// MARK: - TTSProviderValidatorTests

@Suite("CloudTTS T1.4 TTSProviderValidator")
struct TTSProviderValidatorTests {

    @Test("validate(.openAITTS, apiKey: \"\") throws missingAPIKey without a network call")
    func emptyKeyThrowsMissingAPIKey() async {
        await #expect(throws: TTSProviderError.missingAPIKey) {
            try await TTSProviderValidator.validate(kind: .openAITTS, apiKey: "")
        }
    }

    @Test("validate(.openAITTS, apiKey: whitespace-only) throws missingAPIKey without a network call")
    func whitespaceKeyThrowsMissingAPIKey() async {
        await #expect(throws: TTSProviderError.missingAPIKey) {
            try await TTSProviderValidator.validate(kind: .openAITTS, apiKey: "   ")
        }
    }

    @Test("validate(.googleCloudTTS, apiKey: \"\") throws missingAPIKey without a network call")
    func googleCloudTTSEmptyKeyThrowsMissingAPIKey() async {
        await #expect(throws: TTSProviderError.missingAPIKey) {
            try await TTSProviderValidator.validate(kind: .googleCloudTTS, apiKey: "")
        }
    }

    @Test("validate(.googleCloudTTS, apiKey: whitespace-only) throws missingAPIKey without a network call")
    func googleCloudTTSWhitespaceKeyThrowsMissingAPIKey() async {
        await #expect(throws: TTSProviderError.missingAPIKey) {
            try await TTSProviderValidator.validate(kind: .googleCloudTTS, apiKey: "   ")
        }
    }

    @Test("validate(.azureTTS, apiKey: \"\") throws missingAPIKey without a network call")
    func azureTTSEmptyKeyThrowsMissingAPIKey() async {
        await #expect(throws: TTSProviderError.missingAPIKey) {
            try await TTSProviderValidator.validate(kind: .azureTTS, apiKey: "")
        }
    }

    @Test("validate(.azureTTS) with non-empty key but no region throws missingRegion without a network call")
    func azureTTSNoRegionThrowsMissingRegion() async {
        // The throw happens in AzureTTSProvider.makeValidationRequest, before any
        // network call — no URLSession mock needed.
        await #expect(throws: TTSProviderError.missingRegion) {
            try await TTSProviderValidator.validate(
                kind: .azureTTS,
                apiKey: "some-key",
                config: TTSProviderConfig(region: nil)
            )
        }
    }
}

// MARK: - SpeakCoordinatorProviderTypeTests

@Suite("SpeakCoordinator providerType T5.3")
struct SpeakCoordinatorProviderTypeTests {

    @Test("providerType(for: .openAITTS) returns non-nil")
    func openAITTSProviderTypeIsNonNil() {
        #expect(SpeakCoordinator.providerType(for: .openAITTS) != nil)
    }

    @Test("providerType(for: .googleCloudTTS) returns non-nil")
    func googleCloudTTSProviderTypeIsNonNil() {
        #expect(SpeakCoordinator.providerType(for: .googleCloudTTS) != nil)
    }

    @Test("providerType(for: .azureTTS) returns non-nil")
    func azureTTSProviderTypeIsNonNil() {
        #expect(SpeakCoordinator.providerType(for: .azureTTS) != nil)
    }
}

// MARK: - GoogleCloudTTSProviderTests

@Suite("CloudTTS T5.1 GoogleCloudTTSProvider")
struct GoogleCloudTTSProviderTests {

    // MARK: defaultVoice

    @Test("defaultVoice(forLanguage: en-US) returns non-empty string containing en-US")
    func defaultVoiceEnUS() {
        let voice = GoogleCloudTTSProvider.defaultVoice(forLanguage: "en-US")
        #expect(!voice.isEmpty)
        #expect(voice.contains("en-US"))
    }

    @Test("defaultVoice(forLanguage: fr-FR) returns non-empty string containing fr-FR")
    func defaultVoiceFrFR() {
        let voice = GoogleCloudTTSProvider.defaultVoice(forLanguage: "fr-FR")
        #expect(!voice.isEmpty)
        #expect(voice.contains("fr-FR"))
    }

    @Test("defaultVoice(forLanguage: en-GB) returns non-empty string containing en-GB")
    func defaultVoiceEnGB() {
        let voice = GoogleCloudTTSProvider.defaultVoice(forLanguage: "en-GB")
        #expect(!voice.isEmpty)
        #expect(voice.contains("en-GB"))
    }

    @Test("defaultVoice(forLanguage: es-ES) returns non-empty string containing es-ES")
    func defaultVoiceEsES() {
        let voice = GoogleCloudTTSProvider.defaultVoice(forLanguage: "es-ES")
        #expect(!voice.isEmpty)
        #expect(voice.contains("es-ES"))
    }

    @Test("defaultVoice(forLanguage: de-DE) returns non-empty string containing de-DE")
    func defaultVoiceDeDe() {
        let voice = GoogleCloudTTSProvider.defaultVoice(forLanguage: "de-DE")
        #expect(!voice.isEmpty)
        #expect(voice.contains("de-DE"))
    }

    @Test("defaultVoice falls back to an en-US voice for unknown language")
    func defaultVoiceUnknownLanguageFallback() {
        let voice = GoogleCloudTTSProvider.defaultVoice(forLanguage: "ja-JP")
        #expect(!voice.isEmpty)
        #expect(voice.contains("en-US"))
    }

    // MARK: makeSynthesisRequest — host / path / method

    @Test("makeSynthesisRequest returns POST to texttospeech.googleapis.com/v1/text:synthesize")
    func synthesisRequestURLAndMethod() throws {
        let req = try GoogleCloudTTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "en-US-Neural2-C",
            languageCode: "en-US",
            config: .default,
            apiKey: "test-key"
        )
        #expect(req.url?.host == "texttospeech.googleapis.com")
        #expect(req.url?.path == "/v1/text:synthesize")
        #expect(req.httpMethod == "POST")
    }

    @Test("makeSynthesisRequest URL contains key= query parameter")
    func synthesisRequestContainsKeyQueryParam() throws {
        let req = try GoogleCloudTTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "en-US-Neural2-C",
            languageCode: "en-US",
            config: .default,
            apiKey: "my-api-key"
        )
        let query = req.url?.query ?? ""
        #expect(query.contains("key="))
    }

    @Test("makeSynthesisRequest sets Content-Type: application/json")
    func synthesisRequestContentTypeHeader() throws {
        let req = try GoogleCloudTTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "en-US-Neural2-C",
            languageCode: "en-US",
            config: .default,
            apiKey: "test-key"
        )
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    // MARK: makeSynthesisRequest — JSON body structure

    @Test("makeSynthesisRequest body has input.text, voice.languageCode, voice.name, audioConfig.audioEncoding")
    func synthesisRequestBodyFields() throws {
        let inputText = "The quick brown fox"
        let voiceName = "en-US-Neural2-C"
        let langCode  = "en-US"

        let req = try GoogleCloudTTSProvider.makeSynthesisRequest(
            text: inputText,
            voice: voiceName,
            languageCode: langCode,
            config: .default,
            apiKey: "test-key"
        )

        let bodyData = try #require(req.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )

        // input.text
        let input = try #require(json["input"] as? [String: Any])
        #expect(input["text"] as? String == inputText)

        // voice.languageCode and voice.name
        let voice = try #require(json["voice"] as? [String: Any])
        #expect(voice["languageCode"] as? String == langCode)
        #expect(voice["name"] as? String == voiceName)

        // audioConfig.audioEncoding
        let audioConfig = try #require(json["audioConfig"] as? [String: Any])
        #expect(audioConfig["audioEncoding"] as? String == "MP3")
    }

    @Test("makeSynthesisRequest includes speakingRate and pitch in audioConfig when provided")
    func synthesisRequestIncludesSpeedAndPitch() throws {
        let req = try GoogleCloudTTSProvider.makeSynthesisRequest(
            text: "Hi",
            voice: "en-US-Neural2-C",
            languageCode: "en-US",
            speed: 1.5,
            pitch: 2.0,
            config: .default,
            apiKey: "test-key"
        )
        let bodyData = try #require(req.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        let audioConfig = try #require(json["audioConfig"] as? [String: Any])
        #expect(audioConfig["speakingRate"] as? Double == 1.5)
        // pitch multiplier 2.0 → +12.0 semitones (one octave up).
        #expect(audioConfig["pitch"] as? Double == 12.0)
    }

    @Test("makeSynthesisRequest omits pitch but keeps speakingRate for Chirp3-HD voices")
    func synthesisRequestOmitsPitchForChirpVoices() throws {
        let req = try GoogleCloudTTSProvider.makeSynthesisRequest(
            text: "Hi",
            voice: "en-US-Chirp3-HD-Aoede",
            languageCode: "en-US",
            speed: 1.5,
            pitch: 2.0,
            config: .default,
            apiKey: "test-key"
        )
        let bodyData = try #require(req.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        let audioConfig = try #require(json["audioConfig"] as? [String: Any])
        // Chirp3-HD supports speakingRate but rejects pitch (HTTP 400).
        #expect(audioConfig["speakingRate"] as? Double == 1.5)
        #expect(audioConfig["pitch"] == nil)
    }

    @Test("makeSynthesisRequest omits speakingRate and pitch when nil")
    func synthesisRequestOmitsSpeedAndPitchWhenNil() throws {
        let req = try GoogleCloudTTSProvider.makeSynthesisRequest(
            text: "Hi",
            voice: "en-US-Neural2-C",
            languageCode: "en-US",
            speed: nil,
            pitch: nil,
            config: .default,
            apiKey: "test-key"
        )
        let bodyData = try #require(req.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        let audioConfig = try #require(json["audioConfig"] as? [String: Any])
        #expect(audioConfig["speakingRate"] == nil)
        #expect(audioConfig["pitch"] == nil)
    }

    @Test("semitones(forPitchMultiplier:) maps 1.0 to 0.0 and clamps to [-20, 20]")
    func semitoneMapping() {
        #expect(GoogleCloudTTSProvider.semitones(forPitchMultiplier: 1.0) == 0.0)
        #expect(GoogleCloudTTSProvider.semitones(forPitchMultiplier: 2.0) == 12.0)
        #expect(GoogleCloudTTSProvider.semitones(forPitchMultiplier: 0.5) == -12.0)
        #expect(GoogleCloudTTSProvider.semitones(forPitchMultiplier: 4.0) == 20.0)
        #expect(GoogleCloudTTSProvider.semitones(forPitchMultiplier: 0.25) == -20.0)
    }

    @Test("makeSynthesisRequest voice.languageCode matches the passed languageCode")
    func synthesisRequestVoiceLanguageCodeMatchesParam() throws {
        for langCode in ["en-US", "fr-FR", "de-DE", "es-ES"] {
            let req = try GoogleCloudTTSProvider.makeSynthesisRequest(
                text: "test",
                voice: GoogleCloudTTSProvider.defaultVoice(forLanguage: langCode),
                languageCode: langCode,
                config: .default,
                apiKey: "k"
            )
            let bodyData = try #require(req.httpBody)
            let json = try #require(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            let voiceObj = try #require(json["voice"] as? [String: Any])
            #expect(voiceObj["languageCode"] as? String == langCode)
        }
    }

    // MARK: makeSynthesisRequest — empty apiKey

    @Test("makeSynthesisRequest throws missingAPIKey for empty key")
    func synthesisRequestEmptyKeyThrows() {
        #expect(throws: TTSProviderError.missingAPIKey) {
            try GoogleCloudTTSProvider.makeSynthesisRequest(
                text: "Hi",
                voice: "en-US-Neural2-C",
                languageCode: "en-US",
                config: .default,
                apiKey: ""
            )
        }
    }

    // MARK: decodeAudio

    @Test("decodeAudio base64-decodes audioContent to original bytes")
    func decodeAudioRoundTrip() throws {
        let originalBytes = Data([0xFF, 0xFB, 0x90, 0x04, 0x00, 0x01, 0x02])
        let base64String  = originalBytes.base64EncodedString()
        let json          = "{\"audioContent\":\"\(base64String)\"}"
        let jsonData      = Data(json.utf8)

        let result = try GoogleCloudTTSProvider.decodeAudio(from: jsonData)
        #expect(result == originalBytes)
    }

    @Test("decodeAudio throws decode error when audioContent field is missing")
    func decodeAudioMissingFieldThrows() {
        let json = Data("{\"other\":\"value\"}".utf8)
        #expect(throws: TTSProviderError.decode("missing audioContent")) {
            try GoogleCloudTTSProvider.decodeAudio(from: json)
        }
    }

    @Test("decodeAudio throws decode error when audioContent is empty string")
    func decodeAudioEmptyStringThrows() {
        let json = Data("{\"audioContent\":\"\"}".utf8)
        #expect(throws: TTSProviderError.decode("missing audioContent")) {
            try GoogleCloudTTSProvider.decodeAudio(from: json)
        }
    }

    @Test("decodeAudio throws decode error when audioContent is invalid base64")
    func decodeAudioInvalidBase64Throws() {
        let json = Data("{\"audioContent\":\"!!!not-valid-base64!!!\"}".utf8)
        #expect(throws: TTSProviderError.decode("invalid base64")) {
            try GoogleCloudTTSProvider.decodeAudio(from: json)
        }
    }

    @Test("decodeAudio throws decode error for non-JSON input")
    func decodeAudioNonJSONThrows() {
        let notJSON = Data("not json at all".utf8)
        #expect(throws: TTSProviderError.decode("missing audioContent")) {
            try GoogleCloudTTSProvider.decodeAudio(from: notJSON)
        }
    }

    // MARK: makeValidationRequest

    @Test("makeValidationRequest returns GET to texttospeech.googleapis.com/v1/voices with key= param")
    func validationRequestShape() throws {
        let req = try GoogleCloudTTSProvider.makeValidationRequest(
            apiKey: "val-key",
            config: .default
        )
        #expect(req.url?.host == "texttospeech.googleapis.com")
        #expect(req.url?.path == "/v1/voices")
        #expect(req.httpMethod == "GET")
        let query = req.url?.query ?? ""
        #expect(query.contains("key="))
    }

    @Test("makeValidationRequest throws missingAPIKey for empty key")
    func validationRequestEmptyKeyThrows() {
        #expect(throws: TTSProviderError.missingAPIKey) {
            try GoogleCloudTTSProvider.makeValidationRequest(apiKey: "", config: .default)
        }
    }

    // MARK: kind

    @Test("GoogleCloudTTSProvider.kind is .googleCloudTTS")
    func providerKind() {
        #expect(GoogleCloudTTSProvider.kind == .googleCloudTTS)
    }
}

// MARK: - AzureTTSProviderTests

@Suite("CloudTTS T5.2 AzureTTSProvider")
struct AzureTTSProviderTests {

    // MARK: - defaultVoice

    @Test("defaultVoice(forLanguage: en-US) returns non-empty string containing en-US")
    func defaultVoiceEnUS() {
        let voice = AzureTTSProvider.defaultVoice(forLanguage: "en-US")
        #expect(!voice.isEmpty)
        #expect(voice.contains("en-US"))
    }

    @Test("defaultVoice(forLanguage: en-GB) returns non-empty string containing en-GB")
    func defaultVoiceEnGB() {
        let voice = AzureTTSProvider.defaultVoice(forLanguage: "en-GB")
        #expect(!voice.isEmpty)
        #expect(voice.contains("en-GB"))
    }

    @Test("defaultVoice(forLanguage: fr-FR) returns non-empty string containing fr-FR")
    func defaultVoiceFrFR() {
        let voice = AzureTTSProvider.defaultVoice(forLanguage: "fr-FR")
        #expect(!voice.isEmpty)
        #expect(voice.contains("fr-FR"))
    }

    @Test("defaultVoice(forLanguage: es-ES) returns non-empty string containing es-ES")
    func defaultVoiceEsES() {
        let voice = AzureTTSProvider.defaultVoice(forLanguage: "es-ES")
        #expect(!voice.isEmpty)
        #expect(voice.contains("es-ES"))
    }

    @Test("defaultVoice(forLanguage: de-DE) returns non-empty string containing de-DE")
    func defaultVoiceDeDe() {
        let voice = AzureTTSProvider.defaultVoice(forLanguage: "de-DE")
        #expect(!voice.isEmpty)
        #expect(voice.contains("de-DE"))
    }

    @Test("defaultVoice falls back to an en-US voice for unknown language")
    func defaultVoiceUnknownLanguageFallback() {
        let voice = AzureTTSProvider.defaultVoice(forLanguage: "ja-JP")
        #expect(!voice.isEmpty)
        #expect(voice.contains("en-US"))
    }

    // MARK: - makeSynthesisRequest — host / path / method

    @Test("makeSynthesisRequest returns POST to region-templated host and cognitiveservices/v1 path")
    func synthesisRequestURLAndMethod() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "test-key"
        )
        #expect(req.url?.host == "eastus.tts.speech.microsoft.com")
        #expect(req.url?.path == "/cognitiveservices/v1")
        #expect(req.httpMethod == "POST")
    }

    @Test("makeSynthesisRequest uses region from config in the URL host")
    func synthesisRequestRegionTemplatedHost() throws {
        for region in ["westeurope", "australiaeast", "japaneast"] {
            let config = TTSProviderConfig(region: region)
            let req = try AzureTTSProvider.makeSynthesisRequest(
                text: "test",
                voice: "en-US-JennyNeural",
                languageCode: "en-US",
                config: config,
                apiKey: "k"
            )
            #expect(req.url?.host == "\(region).tts.speech.microsoft.com")
        }
    }

    // MARK: - makeSynthesisRequest — required headers

    @Test("makeSynthesisRequest sets Ocp-Apim-Subscription-Key header")
    func synthesisRequestSubscriptionKeyHeader() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "my-azure-key"
        )
        #expect(req.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "my-azure-key")
    }

    @Test("makeSynthesisRequest sets Content-Type: application/ssml+xml")
    func synthesisRequestContentTypeHeader() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "k"
        )
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/ssml+xml")
    }

    @Test("makeSynthesisRequest sets X-Microsoft-OutputFormat to audio-24khz-48kbitrate-mono-mp3")
    func synthesisRequestOutputFormatHeader() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "k"
        )
        #expect(req.value(forHTTPHeaderField: "X-Microsoft-OutputFormat") == "audio-24khz-48kbitrate-mono-mp3")
    }

    @Test("makeSynthesisRequest sets a non-empty User-Agent header")
    func synthesisRequestUserAgentHeader() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "k"
        )
        let ua = req.value(forHTTPHeaderField: "User-Agent") ?? ""
        #expect(!ua.isEmpty)
    }

    // MARK: - makeSynthesisRequest — SSML body

    @Test("makeSynthesisRequest SSML body contains the voice name and xml:lang attribute")
    func synthesisRequestSSMLBodyContainsVoiceAndLang() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "Bonjour",
            voice: "fr-FR-DeniseNeural",
            languageCode: "fr-FR",
            config: config,
            apiKey: "k"
        )
        let bodyData = try #require(req.httpBody)
        let body = try #require(String(data: bodyData, encoding: .utf8))

        #expect(body.contains("fr-FR-DeniseNeural"))
        #expect(body.contains("fr-FR"))
    }

    @Test("makeSynthesisRequest wraps text in prosody with rate and pitch when provided")
    func synthesisRequestSSMLIncludesProsodyRateAndPitch() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            speed: 1.5,
            pitch: 2.0,
            config: config,
            apiKey: "k"
        )
        let bodyData = try #require(req.httpBody)
        let body = try #require(String(data: bodyData, encoding: .utf8))
        // Speed 1.5 → +50% rate; pitch 2.0 → +12.0st.
        #expect(body.contains("<prosody"))
        #expect(body.contains("rate='+50%'"))
        #expect(body.contains("pitch='+12.0st'"))
        #expect(body.contains("Hello</prosody>"))
    }

    @Test("makeSynthesisRequest omits prosody when speed and pitch are nil")
    func synthesisRequestSSMLOmitsProsodyWhenNil() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "Hello",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            speed: nil,
            pitch: nil,
            config: config,
            apiKey: "k"
        )
        let bodyData = try #require(req.httpBody)
        let body = try #require(String(data: bodyData, encoding: .utf8))
        #expect(!body.contains("<prosody"))
    }

    @Test("semitoneString(forPitchMultiplier:) maps 1.0 to +0st and clamps to a 2-octave range")
    func semitoneStringMapping() {
        #expect(AzureTTSProvider.semitoneString(forPitchMultiplier: 1.0) == "+0.0st")
        #expect(AzureTTSProvider.semitoneString(forPitchMultiplier: 2.0) == "+12.0st")
        #expect(AzureTTSProvider.semitoneString(forPitchMultiplier: 0.5) == "-12.0st")
    }

    @Test("makeSynthesisRequest SSML body contains plain text when no special characters")
    func synthesisRequestSSMLBodyContainsText() throws {
        let config = TTSProviderConfig(region: "eastus")
        let inputText = "Hello world"
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: inputText,
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "k"
        )
        let bodyData = try #require(req.httpBody)
        let body = try #require(String(data: bodyData, encoding: .utf8))
        #expect(body.contains("Hello world"))
    }

    // MARK: - XML escaping

    @Test("makeSynthesisRequest XML-escapes < in user text")
    func xmlEscapeLessThan() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "5 < 3",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "k"
        )
        let rawBody = try #require(req.httpBody)
        let body = try #require(String(data: rawBody, encoding: .utf8))
        // The escaped entity must appear in the user-text region.
        #expect(body.contains("5 &lt; 3"))
        // The raw substring "5 < 3" must not appear (contiguous raw form).
        #expect(!body.contains("5 < 3"))
    }

    @Test("makeSynthesisRequest XML-escapes & in user text")
    func xmlEscapeAmpersand() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "bread & butter",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "k"
        )
        let rawBody = try #require(req.httpBody)
        let body = try #require(String(data: rawBody, encoding: .utf8))
        #expect(body.contains("bread &amp; butter"))
        #expect(!body.contains("bread & butter"))
    }

    @Test("makeSynthesisRequest XML-escapes \" in user text")
    func xmlEscapeQuote() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "say \"hi\"",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "k"
        )
        let rawBody = try #require(req.httpBody)
        let body = try #require(String(data: rawBody, encoding: .utf8))
        #expect(body.contains("say &quot;hi&quot;"))
        #expect(!body.contains("say \"hi\""))
    }

    @Test("makeSynthesisRequest XML-escapes combined special characters without double-escaping")
    func xmlEscapeCombined() throws {
        let config = TTSProviderConfig(region: "eastus")
        // Text contains all three characters that must be escaped.
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "a < b & c \"d\"",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "k"
        )
        let rawBody = try #require(req.httpBody)
        let body = try #require(String(data: rawBody, encoding: .utf8))
        #expect(body.contains("&lt;"))
        #expect(body.contains("&amp;"))
        #expect(body.contains("&quot;"))
        // Raw unescaped forms must not appear contiguously in the body.
        #expect(!body.contains("a < b"))
        #expect(!body.contains("b & c"))
    }

    @Test("makeSynthesisRequest XML-escapes & before < proving no double-escaping")
    func xmlEscapeOrderGuarantee() throws {
        // Input "a < b & c": & must become &amp; and < must become &lt;.
        // If < were escaped first and then & were escaped, &lt; would become
        // &amp;lt; (double-escape). The correct output is "a &lt; b &amp; c".
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "a < b & c",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "k"
        )
        let rawBody = try #require(req.httpBody)
        let body = try #require(String(data: rawBody, encoding: .utf8))
        // Exact escaped sequence — proves & → &amp; happened before < → &lt;
        // (no double-escaping: &amp;lt; must NOT appear).
        #expect(body.contains("a &lt; b &amp; c"))
        #expect(!body.contains("&amp;lt;"))
        #expect(!body.contains("&amp;amp;"))
    }

    @Test("makeSynthesisRequest XML-escapes > in user text")
    func xmlEscapeGreaterThan() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "3 > 1",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "k"
        )
        let rawBody = try #require(req.httpBody)
        let body = try #require(String(data: rawBody, encoding: .utf8))
        #expect(body.contains("3 &gt; 1"))
        #expect(!body.contains("3 > 1"))
    }

    @Test("makeSynthesisRequest XML-escapes single quote in user text")
    func xmlEscapeSingleQuote() throws {
        let config = TTSProviderConfig(region: "eastus")
        let req = try AzureTTSProvider.makeSynthesisRequest(
            text: "it's",
            voice: "en-US-JennyNeural",
            languageCode: "en-US",
            config: config,
            apiKey: "k"
        )
        let rawBody = try #require(req.httpBody)
        let body = try #require(String(data: rawBody, encoding: .utf8))
        // AzureTTSProvider.xmlEscape replaces ' with &apos;
        #expect(body.contains("it&apos;s"))
        #expect(!body.contains("it's"))
    }

    // MARK: - makeSynthesisRequest — error cases

    @Test("makeSynthesisRequest throws missingAPIKey for empty key")
    func synthesisRequestEmptyKeyThrows() {
        let config = TTSProviderConfig(region: "eastus")
        #expect(throws: TTSProviderError.missingAPIKey) {
            try AzureTTSProvider.makeSynthesisRequest(
                text: "Hi",
                voice: "en-US-JennyNeural",
                languageCode: "en-US",
                config: config,
                apiKey: ""
            )
        }
    }

    @Test("makeSynthesisRequest throws missingRegion when config.region is nil")
    func synthesisRequestNilRegionThrows() {
        let config = TTSProviderConfig(region: nil)
        #expect(throws: TTSProviderError.missingRegion) {
            try AzureTTSProvider.makeSynthesisRequest(
                text: "Hi",
                voice: "en-US-JennyNeural",
                languageCode: "en-US",
                config: config,
                apiKey: "some-key"
            )
        }
    }

    @Test("makeSynthesisRequest throws missingRegion when config.region is empty string")
    func synthesisRequestEmptyRegionThrows() {
        let config = TTSProviderConfig(region: "")
        #expect(throws: TTSProviderError.missingRegion) {
            try AzureTTSProvider.makeSynthesisRequest(
                text: "Hi",
                voice: "en-US-JennyNeural",
                languageCode: "en-US",
                config: config,
                apiKey: "some-key"
            )
        }
    }

    // MARK: - decodeAudio

    @Test("decodeAudio returns input bytes unchanged")
    func decodeAudioIdentity() throws {
        let bytes = Data([0xFF, 0xFB, 0x90, 0x00, 0x01, 0x02])
        let result = try AzureTTSProvider.decodeAudio(from: bytes)
        #expect(result == bytes)
    }

    @Test("decodeAudio throws decode error for empty data")
    func decodeAudioEmptyThrows() {
        #expect(throws: TTSProviderError.decode("empty audio")) {
            try AzureTTSProvider.decodeAudio(from: Data())
        }
    }

    // MARK: - makeValidationRequest

    @Test("makeValidationRequest returns GET to region voices/list endpoint with subscription key")
    func validationRequestShape() throws {
        let config = TTSProviderConfig(region: "westus2")
        let req = try AzureTTSProvider.makeValidationRequest(apiKey: "val-key", config: config)
        #expect(req.url?.host == "westus2.tts.speech.microsoft.com")
        #expect(req.url?.path == "/cognitiveservices/voices/list")
        #expect(req.httpMethod == "GET")
        #expect(req.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "val-key")
    }

    @Test("makeValidationRequest throws missingAPIKey for empty key")
    func validationRequestEmptyKeyThrows() {
        let config = TTSProviderConfig(region: "eastus")
        #expect(throws: TTSProviderError.missingAPIKey) {
            try AzureTTSProvider.makeValidationRequest(apiKey: "", config: config)
        }
    }

    @Test("makeValidationRequest throws missingRegion when config.region is nil")
    func validationRequestNilRegionThrows() {
        let config = TTSProviderConfig(region: nil)
        #expect(throws: TTSProviderError.missingRegion) {
            try AzureTTSProvider.makeValidationRequest(apiKey: "k", config: config)
        }
    }

    @Test("makeValidationRequest throws missingRegion when config.region is empty string")
    func validationRequestEmptyRegionThrows() {
        let config = TTSProviderConfig(region: "")
        #expect(throws: TTSProviderError.missingRegion) {
            try AzureTTSProvider.makeValidationRequest(apiKey: "k", config: config)
        }
    }

    // MARK: - kind

    @Test("AzureTTSProvider.kind is .azureTTS")
    func providerKind() {
        #expect(AzureTTSProvider.kind == .azureTTS)
    }
}

// MARK: - GoogleCloudTTSCuratedLanguageVoicesTests

@Suite("CloudTTS GoogleCloudTTS curatedVoices(forLanguage:)")
struct GoogleCloudTTSCuratedLanguageVoicesTests {

    @Test("en-US returns non-empty list with locale prefix")
    func enUSNonEmpty() {
        let voices = GoogleCloudTTSProvider.curatedVoices(forLanguage: "en-US")
        #expect(!voices.isEmpty)
        #expect(voices.allSatisfy { $0.hasPrefix("en-US-") })
    }

    @Test("en-GB returns non-empty list with locale prefix")
    func enGBNonEmpty() {
        let voices = GoogleCloudTTSProvider.curatedVoices(forLanguage: "en-GB")
        #expect(!voices.isEmpty)
        #expect(voices.allSatisfy { $0.hasPrefix("en-GB-") })
    }

    @Test("fr-FR returns non-empty list with locale prefix")
    func frFRNonEmpty() {
        let voices = GoogleCloudTTSProvider.curatedVoices(forLanguage: "fr-FR")
        #expect(!voices.isEmpty)
        #expect(voices.allSatisfy { $0.hasPrefix("fr-FR-") })
    }

    @Test("es-ES returns non-empty list with locale prefix")
    func esESNonEmpty() {
        let voices = GoogleCloudTTSProvider.curatedVoices(forLanguage: "es-ES")
        #expect(!voices.isEmpty)
        #expect(voices.allSatisfy { $0.hasPrefix("es-ES-") })
    }

    @Test("de-DE returns non-empty list with locale prefix")
    func deDENonEmpty() {
        let voices = GoogleCloudTTSProvider.curatedVoices(forLanguage: "de-DE")
        #expect(!voices.isEmpty)
        #expect(voices.allSatisfy { $0.hasPrefix("de-DE-") })
    }

    @Test("unknown locale returns empty list")
    func unknownLocaleEmpty() {
        let voices = GoogleCloudTTSProvider.curatedVoices(forLanguage: "ja-JP")
        #expect(voices.isEmpty)
    }

    @Test("all five locales have Chirp3-HD voices leading the list")
    func chirp3HDVoicesLeadList() {
        let locales = ["en-US", "en-GB", "fr-FR", "es-ES", "de-DE"]
        for locale in locales {
            let voices = GoogleCloudTTSProvider.curatedVoices(forLanguage: locale)
            #expect(!voices.isEmpty, "Expected voices for \(locale)")
            #expect(voices.first?.contains("Chirp3-HD") == true,
                    "Expected first voice for \(locale) to be Chirp3-HD")
        }
    }

    @Test("TTSProviderKind.googleCloudTTS delegates to GoogleCloudTTSProvider")
    func kindDelegates() {
        let direct = GoogleCloudTTSProvider.curatedVoices(forLanguage: "en-US")
        let viaKind = TTSProviderKind.googleCloudTTS.curatedVoices(forLanguage: "en-US")
        #expect(direct == viaKind)
    }

    @Test("TTSProviderKind.openAITTS returns empty for any language")
    func openAITTSReturnsEmpty() {
        #expect(TTSProviderKind.openAITTS.curatedVoices(forLanguage: "en-US").isEmpty)
    }
}

// MARK: - AzureTTSCuratedLanguageVoicesTests

@Suite("CloudTTS AzureTTS curatedVoices(forLanguage:)")
struct AzureTTSCuratedLanguageVoicesTests {

    @Test("en-US returns non-empty list with locale prefix")
    func enUSNonEmpty() {
        let voices = AzureTTSProvider.curatedVoices(forLanguage: "en-US")
        #expect(!voices.isEmpty)
        #expect(voices.allSatisfy { $0.hasPrefix("en-US-") })
    }

    @Test("en-GB returns non-empty list with locale prefix")
    func enGBNonEmpty() {
        let voices = AzureTTSProvider.curatedVoices(forLanguage: "en-GB")
        #expect(!voices.isEmpty)
        #expect(voices.allSatisfy { $0.hasPrefix("en-GB-") })
    }

    @Test("fr-FR returns non-empty list with locale prefix")
    func frFRNonEmpty() {
        let voices = AzureTTSProvider.curatedVoices(forLanguage: "fr-FR")
        #expect(!voices.isEmpty)
        #expect(voices.allSatisfy { $0.hasPrefix("fr-FR-") })
    }

    @Test("es-ES returns non-empty list with locale prefix")
    func esESNonEmpty() {
        let voices = AzureTTSProvider.curatedVoices(forLanguage: "es-ES")
        #expect(!voices.isEmpty)
        #expect(voices.allSatisfy { $0.hasPrefix("es-ES-") })
    }

    @Test("de-DE returns non-empty list with locale prefix")
    func deDENonEmpty() {
        let voices = AzureTTSProvider.curatedVoices(forLanguage: "de-DE")
        #expect(!voices.isEmpty)
        #expect(voices.allSatisfy { $0.hasPrefix("de-DE-") })
    }

    @Test("unknown locale returns empty list")
    func unknownLocaleEmpty() {
        let voices = AzureTTSProvider.curatedVoices(forLanguage: "ja-JP")
        #expect(voices.isEmpty)
    }

    @Test("all five locales have DragonHD voices leading the list")
    func dragonHDVoicesLeadList() {
        let locales = ["en-US", "en-GB", "fr-FR", "es-ES", "de-DE"]
        for locale in locales {
            let voices = AzureTTSProvider.curatedVoices(forLanguage: locale)
            #expect(!voices.isEmpty, "Expected voices for \(locale)")
            #expect(voices.first?.contains("DragonHD") == true,
                    "Expected first voice for \(locale) to be DragonHD")
        }
    }

    @Test("TTSProviderKind.azureTTS delegates to AzureTTSProvider")
    func kindDelegates() {
        let direct = AzureTTSProvider.curatedVoices(forLanguage: "en-US")
        let viaKind = TTSProviderKind.azureTTS.curatedVoices(forLanguage: "en-US")
        #expect(direct == viaKind)
    }
}

// MARK: - VoiceOverridesRoundTripTests

@Suite("CloudTTS voiceOverrides round-trip")
@MainActor
struct VoiceOverridesRoundTripTests {

    private func makeSuite() -> (UserDefaults, String) {
        let name = "com.popguy.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func removeSuite(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    @Test("setting voiceOverrides[bcp47] round-trips through SettingsStore")
    func voiceOverrideRoundTrips() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        var config = store.ttsConfig(for: .googleCloudTTS)
        config.voiceOverrides["en-US"] = "en-US-Chirp3-HD-Aoede"
        store.setTTSConfig(config, for: .googleCloudTTS)

        let loaded = store.ttsConfig(for: .googleCloudTTS)
        #expect(loaded.voiceOverrides["en-US"] == "en-US-Chirp3-HD-Aoede")
    }

    @Test("removing voiceOverrides[bcp47] round-trips through SettingsStore")
    func voiceOverrideRemovalRoundTrips() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        var config = store.ttsConfig(for: .azureTTS)
        config.voiceOverrides["fr-FR"] = "fr-FR-DeniseNeural"
        store.setTTSConfig(config, for: .azureTTS)

        var updated = store.ttsConfig(for: .azureTTS)
        updated.voiceOverrides.removeValue(forKey: "fr-FR")
        store.setTTSConfig(updated, for: .azureTTS)

        let loaded = store.ttsConfig(for: .azureTTS)
        #expect(loaded.voiceOverrides["fr-FR"] == nil)
    }

    @Test("multiple bcp47 overrides co-exist independently")
    func multipleOverridesCoexist() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        var config = store.ttsConfig(for: .googleCloudTTS)
        config.voiceOverrides["en-US"] = "en-US-Neural2-C"
        config.voiceOverrides["fr-FR"] = "fr-FR-Chirp3-HD-Aoede"
        config.voiceOverrides["de-DE"] = "de-DE-Neural2-G"
        store.setTTSConfig(config, for: .googleCloudTTS)

        let loaded = store.ttsConfig(for: .googleCloudTTS)
        #expect(loaded.voiceOverrides["en-US"] == "en-US-Neural2-C")
        #expect(loaded.voiceOverrides["fr-FR"] == "fr-FR-Chirp3-HD-Aoede")
        #expect(loaded.voiceOverrides["de-DE"] == "de-DE-Neural2-G")
        #expect(loaded.voiceOverrides["es-ES"] == nil)
    }
}
