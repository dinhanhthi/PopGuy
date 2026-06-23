// SpeakEngineTests.swift
// PopGuyTests
//
// Pure-data / pure-logic tests for the SpeakEngine module.
// No network, no AVFoundation playback, no URLSession injection.
//
// Covers:
//   - SpeakAccent: bcp47, shortTag, dictionaryVariant, usesDictionary
//   - SpeakSettings: .default field values, Codable resilience, round-trip
//   - SpeakCoordinator.isSingleWord: true/false cases
//   - DictionaryAudioEngine.pickAudioString: variant preference, fallback, nil

import AVFoundation
import Foundation
import Testing
@testable import PopGuy

// MARK: - SpyCloud

/// Minimal test double for `CloudSpeaking`.
/// `speakResult`: the value returned by `speak(...)` (default `false`).
/// When `speakResult == true` the spy also fires `isSpeaking = true` + callback
/// to drive `SpeakCoordinator.recomputePhase()` → `phase == .playing`.
@MainActor
final class SpyCloud: CloudSpeaking {
    private(set) var isSpeaking: Bool = false
    var onSpeakingChange: ((Bool) -> Void)?
    private(set) var lastSpokenText: String?
    var speakResult: Bool

    /// Number of times `speak(...)` (the network path) was invoked. Replay tests
    /// assert this does NOT increase when replaying cached audio.
    private(set) var speakCallCount = 0
    /// Last speed forwarded to the cloud provider.
    private(set) var lastSpeed: Double?
    /// Last pitch forwarded to the cloud provider.
    private(set) var lastPitch: Double?
    /// Number of times `replayCached()` was invoked.
    private(set) var replayCallCount = 0

    init(speakResult: Bool = false) {
        self.speakResult = speakResult
    }

    func speak(
        text: String,
        languageCode: String,
        provider: any TTSProvider.Type,
        config: TTSProviderConfig,
        speed: Double?,
        pitch: Double?,
        apiKey: String
    ) async -> Bool {
        speakCallCount += 1
        lastSpokenText = text
        lastSpeed = speed
        lastPitch = pitch
        if speakResult {
            isSpeaking = true
            onSpeakingChange?(true)
        }
        return speakResult
    }

    func stop() {
        isSpeaking = false
        onSpeakingChange?(false)
    }

    /// Mirrors `speak`'s playing behaviour without a network call. Returns the
    /// same `speakResult` so replay tests can drive `phase == .playing`.
    func replayCached() -> Bool {
        replayCallCount += 1
        if speakResult {
            isSpeaking = true
            onSpeakingChange?(true)
            return true
        }
        return false
    }

    func clearCache() {}
}

// MARK: - SpyTTS

/// Minimal test double for `LocalTTSSpeaking`.
/// Records the last text delivered so fallback tests can assert non-vacuously.
///
/// `autoStart`: when true (default), speak() immediately sets isSpeaking = true
/// and fires onSpeakingChange, mimicking a synchronous engine. When false, the
/// engine stays silent after speak() — useful for testing the `.loading` phase
/// before playback begins (the real AVSpeechSynthesizer fires its delegate async).
@MainActor
final class SpyTTS: LocalTTSSpeaking {
    private(set) var isSpeaking: Bool = false
    var onSpeakingChange: ((Bool) -> Void)?
    private(set) var lastSpokenText: String?
    private(set) var lastRate: Float?
    private(set) var lastPitch: Float?
    let autoStart: Bool

    init(autoStart: Bool = true) {
        self.autoStart = autoStart
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float, pitch: Float) {
        lastSpokenText = text
        lastRate = rate
        lastPitch = pitch
        if autoStart {
            isSpeaking = true
            onSpeakingChange?(true)
        }
    }

    func stop() {
        isSpeaking = false
        onSpeakingChange?(false)
    }
}

// MARK: - SpyDictionaryAudio

@MainActor
final class SpyDictionaryAudio: DictionaryAudioSpeaking {
    private(set) var isSpeaking: Bool = false
    var onSpeakingChange: ((Bool) -> Void)?
    private(set) var playedURLs: [String] = []
    private(set) var speakRequests: [(word: String, variant: String)] = []
    var playResult: Bool
    var speakResult: Bool
    let autoStart: Bool

    init(playResult: Bool = true, speakResult: Bool = false, autoStart: Bool = true) {
        self.playResult = playResult
        self.speakResult = speakResult
        self.autoStart = autoStart
    }

    func play(urlString: String) -> Bool {
        playedURLs.append(urlString)
        if playResult && autoStart {
            isSpeaking = true
            onSpeakingChange?(true)
        }
        return playResult
    }

    func speak(word: String, variant: String) async -> Bool {
        speakRequests.append((word: word, variant: variant))
        if speakResult && autoStart {
            isSpeaking = true
            onSpeakingChange?(true)
        }
        return speakResult
    }

    func stop() {
        isSpeaking = false
        onSpeakingChange?(false)
    }
}

// MARK: - SpeakEngineTests

@Suite("SpeakEngine")
struct SpeakEngineTests {

    // MARK: - SpeakAccent

    @Suite("SpeakAccent")
    struct AccentTests {

        @Test("usEnglish bcp47 is en-US")
        func usEnglishBCP47() {
            #expect(SpeakAccent.usEnglish.bcp47 == "en-US")
        }

        @Test("ukEnglish bcp47 is en-GB")
        func ukEnglishBCP47() {
            #expect(SpeakAccent.ukEnglish.bcp47 == "en-GB")
        }

        @Test("french bcp47 is fr-FR")
        func frenchBCP47() {
            #expect(SpeakAccent.french.bcp47 == "fr-FR")
        }

        @Test("usEnglish shortTag is US")
        func usEnglishShortTag() {
            #expect(SpeakAccent.usEnglish.shortTag == "US")
        }

        @Test("ukEnglish shortTag is UK")
        func ukEnglishShortTag() {
            #expect(SpeakAccent.ukEnglish.shortTag == "UK")
        }

        @Test("french shortTag is FR")
        func frenchShortTag() {
            #expect(SpeakAccent.french.shortTag == "FR")
        }

        @Test("usEnglish dictionaryVariant is us")
        func usEnglishDictionaryVariant() {
            #expect(SpeakAccent.usEnglish.dictionaryVariant == "us")
        }

        @Test("ukEnglish dictionaryVariant is uk")
        func ukEnglishDictionaryVariant() {
            #expect(SpeakAccent.ukEnglish.dictionaryVariant == "uk")
        }

        @Test("french dictionaryVariant is nil")
        func frenchDictionaryVariant() {
            #expect(SpeakAccent.french.dictionaryVariant == nil)
        }

        @Test("usEnglish usesDictionary is true")
        func usEnglishUsesDictionary() {
            #expect(SpeakAccent.usEnglish.usesDictionary == true)
        }

        @Test("ukEnglish usesDictionary is true")
        func ukEnglishUsesDictionary() {
            #expect(SpeakAccent.ukEnglish.usesDictionary == true)
        }

        @Test("french usesDictionary is false")
        func frenchUsesDictionary() {
            #expect(SpeakAccent.french.usesDictionary == false)
        }

        @Test("spanish maps to es-ES / ES and is TTS-only")
        func spanishAccent() {
            #expect(SpeakAccent.spanish.bcp47 == "es-ES")
            #expect(SpeakAccent.spanish.shortTag == "ES")
            #expect(SpeakAccent.spanish.displayName == "Spanish")
            #expect(SpeakAccent.spanish.dictionaryVariant == nil)
            #expect(SpeakAccent.spanish.usesDictionary == false)
        }

        @Test("german maps to de-DE / DE and is TTS-only")
        func germanAccent() {
            #expect(SpeakAccent.german.bcp47 == "de-DE")
            #expect(SpeakAccent.german.shortTag == "DE")
            #expect(SpeakAccent.german.displayName == "German")
            #expect(SpeakAccent.german.dictionaryVariant == nil)
            #expect(SpeakAccent.german.usesDictionary == false)
        }
    }

    // MARK: - SpeakEngineSelection

    @Suite("SpeakEngineSelection")
    struct EngineSelectionTests {

        private let encoder = JSONEncoder()
        private let decoder = JSONDecoder()

        // MARK: id

        @Test(".system id is 'system'")
        func systemID() {
            #expect(SpeakEngineSelection.system.id == "system")
        }

        @Test(".cloud(.openAITTS) id is 'cloud:openai_tts'")
        func cloudOpenAIID() {
            #expect(SpeakEngineSelection.cloud(.openAITTS).id == "cloud:openai_tts")
        }

        // MARK: displayName

        @Test(".system displayName is 'System voice'")
        func systemDisplayName() {
            #expect(SpeakEngineSelection.system.displayName == "System voice")
        }

        @Test(".cloud(.openAITTS) displayName is 'OpenAI'")
        func cloudOpenAIDisplayName() {
            #expect(SpeakEngineSelection.cloud(.openAITTS).displayName == "OpenAI")
        }

        // MARK: available()

        @Test("available() equals [.system, .cloud(.openAITTS), .cloud(.googleCloudTTS), .cloud(.azureTTS)]")
        func availableList() {
            #expect(SpeakEngineSelection.available() == [
                .system,
                .cloud(.openAITTS),
                .cloud(.googleCloudTTS),
                .cloud(.azureTTS)
            ])
        }

        // MARK: Codable round-trips

        @Test(".system round-trips through JSON")
        func systemRoundTrip() throws {
            let data = try encoder.encode(SpeakEngineSelection.system)
            let decoded = try decoder.decode(SpeakEngineSelection.self, from: data)
            #expect(decoded == .system)
        }

        @Test(".cloud(.openAITTS) round-trips through JSON")
        func cloudRoundTrip() throws {
            let data = try encoder.encode(SpeakEngineSelection.cloud(.openAITTS))
            let decoded = try decoder.decode(SpeakEngineSelection.self, from: data)
            #expect(decoded == .cloud(.openAITTS))
        }

        @Test(".system encodes to the string 'system'")
        func systemEncoding() throws {
            let data = try encoder.encode(SpeakEngineSelection.system)
            let raw = try decoder.decode(String.self, from: data)
            #expect(raw == "system")
        }

        @Test(".cloud(.openAITTS) encodes to the string 'cloud:openai_tts'")
        func cloudEncoding() throws {
            let data = try encoder.encode(SpeakEngineSelection.cloud(.openAITTS))
            let raw = try decoder.decode(String.self, from: data)
            #expect(raw == "cloud:openai_tts")
        }

        // MARK: Resilient decoding

        @Test("totally unknown string decodes to .system")
        func garbageDecodesToSystem() throws {
            let data = try encoder.encode("xyz")
            let decoded = try decoder.decode(SpeakEngineSelection.self, from: data)
            #expect(decoded == .system)
        }

        @Test("'cloud:bogus' (unknown provider) decodes to .system")
        func unknownProviderDecodesToSystem() throws {
            let data = try encoder.encode("cloud:bogus")
            let decoded = try decoder.decode(SpeakEngineSelection.self, from: data)
            #expect(decoded == .system)
        }
    }

    // MARK: - SpeakSettings

    @Suite("SpeakSettings")
    struct SettingsTests {

        @Test("default accent is usEnglish")
        func defaultAccent() {
            #expect(SpeakSettings.default.defaultAccent == .usEnglish)
        }

        @Test("default defaultVoiceID is nil")
        func defaultVoiceID() {
            #expect(SpeakSettings.default.defaultVoiceID == nil)
        }

        @Test("default quickSwitchAccents contains all five accents")
        func defaultQuickSwitchAccents() {
            let accents = SpeakSettings.default.quickSwitchAccents
            #expect(accents.contains(.usEnglish))
            #expect(accents.contains(.ukEnglish))
            #expect(accents.contains(.french))
            #expect(accents.contains(.spanish))
            #expect(accents.contains(.german))
        }

        @Test("default pitch is 1.0")
        func defaultPitch() {
            #expect(SpeakSettings.default.pitch == 1.0)
        }

        @Test("default dictionaryAudioEnabled is true")
        func defaultDictionaryAudioEnabled() {
            #expect(SpeakSettings.default.dictionaryAudioEnabled == true)
        }

        @Test("decoding empty JSON yields default-equivalent")
        func decodeEmptyJSON() throws {
            let data = "{}".data(using: .utf8)!
            let decoded = try JSONDecoder().decode(SpeakSettings.self, from: data)
            #expect(decoded.defaultAccent == SpeakSettings.default.defaultAccent)
            #expect(decoded.defaultVoiceID == SpeakSettings.default.defaultVoiceID)
            #expect(decoded.pitch == SpeakSettings.default.pitch)
            #expect(decoded.dictionaryAudioEnabled == SpeakSettings.default.dictionaryAudioEnabled)
        }

        @Test("decoding partial JSON fills missing fields with defaults")
        func decodePartialJSON() throws {
            // Only 'rate' is present; all other fields should fall back to defaults.
            let json = """
            {"rate": 0.4}
            """
            let data = json.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(SpeakSettings.self, from: data)
            #expect(decoded.rate == 0.4)
            #expect(decoded.defaultAccent == SpeakSettings.default.defaultAccent)
            #expect(decoded.pitch == SpeakSettings.default.pitch)
            #expect(decoded.dictionaryAudioEnabled == SpeakSettings.default.dictionaryAudioEnabled)
        }

        @Test("full encode-decode round-trip is equal")
        func roundTrip() throws {
            let original = SpeakSettings(
                defaultAccent: .ukEnglish,
                defaultVoiceID: "com.apple.voice.en-GB.example",
                quickSwitchAccents: [.ukEnglish, .usEnglish],
                rate: 0.5,
                pitch: 1.0,
                dictionaryAudioEnabled: false
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(SpeakSettings.self, from: data)
            #expect(decoded == original)
        }

        @Test("an intentionally-empty quickSwitchAccents is preserved, not reset to defaults")
        func emptyQuickSwitchPreserved() throws {
            let original = SpeakSettings(quickSwitchAccents: [])
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(SpeakSettings.self, from: data)
            #expect(decoded.quickSwitchAccents == [])
        }

        @Test("absent quickSwitchAccents key falls back to the default five")
        func absentQuickSwitchDefaults() throws {
            // A blob with no quickSwitchAccents key → default list.
            let json = Data(#"{"defaultAccent":"usEnglish"}"#.utf8)
            let decoded = try JSONDecoder().decode(SpeakSettings.self, from: json)
            #expect(decoded.quickSwitchAccents.count == 5)
        }

        // MARK: New fields: selectedEngine + cloudCharLimit

        @Test("default selectedEngine is .system")
        func defaultSelectedEngine() {
            #expect(SpeakSettings.default.selectedEngine == .system)
        }

        @Test("default cloudCharLimit is 600")
        func defaultCloudCharLimit() {
            #expect(SpeakSettings.default.cloudCharLimit == 600)
        }

        @Test("selectedEngine and cloudCharLimit round-trip with non-default values")
        func newFieldsRoundTrip() throws {
            let original = SpeakSettings(
                selectedEngine: .cloud(.openAITTS),
                cloudCharLimit: 900
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(SpeakSettings.self, from: data)
            #expect(decoded.selectedEngine == .cloud(.openAITTS))
            #expect(decoded.cloudCharLimit == 900)
            #expect(decoded == original)
        }

        @Test("decoding old blob without new fields yields .system / 600")
        func oldBlobResilienceForNewFields() throws {
            // Simulate a blob saved before selectedEngine/cloudCharLimit were added.
            let json = """
            {"defaultAccent": "usEnglish", "rate": 0.5, "pitch": 1.0,
             "dictionaryAudioEnabled": true}
            """
            let data = json.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(SpeakSettings.self, from: data)
            #expect(decoded.selectedEngine == .system)
            #expect(decoded.cloudCharLimit == 600)
        }
    }

    // MARK: - SpeakCoordinator.isSingleWord

    @Suite("SpeakCoordinator.isSingleWord")
    struct IsSingleWordTests {

        @Test("'hello' is a single word")
        func helloIsWord() {
            #expect(SpeakCoordinator.isSingleWord("hello") == true)
        }

        @Test("'well-being' is a single word (hyphen allowed)")
        func wellBeingIsWord() {
            #expect(SpeakCoordinator.isSingleWord("well-being") == true)
        }

        @Test("'don't' is a single word (apostrophe allowed)")
        func dontIsWord() {
            #expect(SpeakCoordinator.isSingleWord("don't") == true)
        }

        @Test("'hello world' is not a single word (space)")
        func helloWorldIsNotWord() {
            #expect(SpeakCoordinator.isSingleWord("hello world") == false)
        }

        @Test("string longer than 45 characters is not a single word")
        func tooLongIsNotWord() {
            let long = String(repeating: "a", count: 46)
            #expect(SpeakCoordinator.isSingleWord(long) == false)
        }

        @Test("empty string is not a single word")
        func emptyIsNotWord() {
            #expect(SpeakCoordinator.isSingleWord("") == false)
        }

        @Test("'abc123' is not a single word (digit)")
        func digitIsNotWord() {
            #expect(SpeakCoordinator.isSingleWord("abc123") == false)
        }

        @Test("'a b' is not a single word (space)")
        func aSpaceBIsNotWord() {
            #expect(SpeakCoordinator.isSingleWord("a b") == false)
        }
    }

    // MARK: - DictionaryAudioEngine.pickAudioString

    @Suite("DictionaryAudioEngine.pickAudioString")
    struct PickAudioStringTests {

        @Test("prefers -us.mp3 entry when variant is 'us'")
        func prefersUSVariant() {
            let entries = [
                DictEntry(phonetics: [
                    DictPhonetic(audio: "https://example.com/word-uk.mp3"),
                    DictPhonetic(audio: "https://example.com/word-us.mp3"),
                ])
            ]
            let result = DictionaryAudioEngine.pickAudioString(from: entries, variant: "us")
            #expect(result == "https://example.com/word-us.mp3")
        }

        @Test("falls back to first non-empty audio when no variant match")
        func fallbackToFirstNonEmpty() {
            let entries = [
                DictEntry(phonetics: [
                    DictPhonetic(audio: "https://example.com/word-au.mp3"),
                    DictPhonetic(audio: "https://example.com/word-uk.mp3"),
                ])
            ]
            let result = DictionaryAudioEngine.pickAudioString(from: entries, variant: "us")
            #expect(result == "https://example.com/word-au.mp3")
        }

        @Test("returns nil when all audio entries are empty or nil")
        func returnsNilWhenAllEmpty() {
            let entries = [
                DictEntry(phonetics: [
                    DictPhonetic(audio: nil),
                    DictPhonetic(audio: ""),
                ])
            ]
            let result = DictionaryAudioEngine.pickAudioString(from: entries, variant: "us")
            #expect(result == nil)
        }

        @Test("returns nil for empty entries list")
        func returnsNilForEmptyEntries() {
            let result = DictionaryAudioEngine.pickAudioString(from: [], variant: "us")
            #expect(result == nil)
        }

        @Test("handles audio spread across multiple entries")
        func audioAcrossMultipleEntries() {
            let entries = [
                DictEntry(phonetics: [
                    DictPhonetic(audio: nil),
                ]),
                DictEntry(phonetics: [
                    DictPhonetic(audio: "https://example.com/word-us.mp3"),
                ]),
            ]
            let result = DictionaryAudioEngine.pickAudioString(from: entries, variant: "us")
            #expect(result == "https://example.com/word-us.mp3")
        }

        @Test("prefers variant match over earlier non-matching non-empty audio")
        func preferVariantOverEarlierFallback() {
            let entries = [
                DictEntry(phonetics: [
                    DictPhonetic(audio: "https://example.com/word-uk.mp3"),
                ]),
                DictEntry(phonetics: [
                    DictPhonetic(audio: "https://example.com/word-us.mp3"),
                ]),
            ]
            let result = DictionaryAudioEngine.pickAudioString(from: entries, variant: "us")
            #expect(result == "https://example.com/word-us.mp3")
        }
    }

    // MARK: - SpeakCoordinator routing

    @Suite("SpeakCoordinator routing")
    struct RoutingTests {

        // MARK: providerType lookup

        @Test("providerType returns OpenAITTSProvider for .openAITTS")
        func providerTypeOpenAI() {
            let result = SpeakCoordinator.providerType(for: .openAITTS)
            #expect(result != nil)
            #expect(result?.kind == .openAITTS)
        }

        @Test("providerType returns GoogleCloudTTSProvider for .googleCloudTTS")
        func providerTypeGoogleCloud() {
            let result = SpeakCoordinator.providerType(for: .googleCloudTTS)
            #expect(result != nil)
            #expect(result?.kind == .googleCloudTTS)
        }

        @Test("providerType returns AzureTTSProvider for .azureTTS")
        func providerTypeAzure() {
            let result = SpeakCoordinator.providerType(for: .azureTTS)
            #expect(result != nil)
            #expect(result?.kind == .azureTTS)
        }

        // MARK: .system engine — local path only

        @Test(".system engine: text reaches local TTS engine")
        @MainActor
        func systemEngineReachesLocal() async {
            let spy = SpyTTS()
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let cloudEngine = CloudTTSEngine()
            let coordinator = SpeakCoordinator(tts: spy, cloud: cloudEngine, keychain: keychain)

            var settings = SpeakSettings.default
            settings.selectedEngine = .system
            settings.dictionaryAudioEnabled = false  // skip dictionary path

            coordinator.speak("hello", accent: .french, settings: settings)
            // Local engine must have received the text.
            #expect(spy.lastSpokenText == "hello")
            // Cloud engine must not have been engaged.
            #expect(cloudEngine.isSpeaking == false)
        }

        @Test(".system engine: English single word still reaches local TTS when dictionary audio is enabled")
        @MainActor
        func systemEnglishWordDoesNotUseDictionaryAudio() async {
            let spyTTS = SpyTTS()
            let spyDictionary = SpyDictionaryAudio(speakResult: true)
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let coordinator = SpeakCoordinator(tts: spyTTS, dictionary: spyDictionary, keychain: keychain)

            var settings = SpeakSettings.default
            settings.selectedEngine = .system
            settings.dictionaryAudioEnabled = true
            settings.rate = AVSpeechUtteranceMinimumSpeechRate

            coordinator.speak("hello", accent: .usEnglish, settings: settings)

            #expect(spyDictionary.speakRequests.isEmpty)
            #expect(spyTTS.lastSpokenText == "hello")
            #expect(spyTTS.lastRate == AVSpeechUtteranceMinimumSpeechRate)
        }

        // MARK: .cloud with no API key → local fallback

        @Test(".cloud(.openAITTS) with no key stored: text falls back to local TTS")
        @MainActor
        func cloudNoKeyFallsBackToLocal() async {
            let spy = SpyTTS()
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let cloudEngine = CloudTTSEngine()
            let coordinator = SpeakCoordinator(tts: spy, cloud: cloudEngine, keychain: keychain)

            var settings = SpeakSettings.default
            settings.selectedEngine = .cloud(.openAITTS)
            settings.dictionaryAudioEnabled = false  // skip dictionary path

            coordinator.speak("hello", accent: .french, settings: settings)
            // No key → guard fails before any Task is launched; local TTS must receive the text.
            #expect(spy.lastSpokenText == "hello")
            #expect(cloudEngine.isSpeaking == false)
        }

        // MARK: .cloud over character limit → local fallback

        @Test(".cloud(.openAITTS) text over cloudCharLimit: text falls back to local TTS")
        @MainActor
        func cloudOverCharLimitFallsBackToLocal() async {
            let spy = SpyTTS()
            let serviceName = "dinh.thi.PopGuy.Tests.\(UUID().uuidString)"
            let keychain = KeychainManager(serviceName: serviceName)
            // Store a fake key so only the char-limit guard triggers.
            keychain.setKey("fake-api-key", account: TTSProviderKind.openAITTS.keychainAccount)
            defer { keychain.deleteKey(account: TTSProviderKind.openAITTS.keychainAccount) }

            let cloudEngine = CloudTTSEngine()
            let coordinator = SpeakCoordinator(tts: spy, cloud: cloudEngine, keychain: keychain)

            var settings = SpeakSettings.default
            settings.selectedEngine = .cloud(.openAITTS)
            settings.cloudCharLimit = 5           // limit = 5 chars
            settings.dictionaryAudioEnabled = false

            coordinator.speak("this text is over the limit", accent: .french, settings: settings)
            // Text is 26 chars > 5 → guard fails; local TTS must receive the text.
            #expect(spy.lastSpokenText == "this text is over the limit")
            #expect(cloudEngine.isSpeaking == false)
        }

        // MARK: stop() is safe when nothing is playing

        @Test("stop() is safe when nothing is playing")
        @MainActor
        func stopSafeWhenIdle() async {
            let coordinator = SpeakCoordinator()
            // Should not crash.
            coordinator.stop()
            #expect(coordinator.isSpeaking == false)
        }

        // MARK: stop() clears isSpeaking

        @Test("stop() clears isSpeaking")
        @MainActor
        func stopClearsSpeaking() async {
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let coordinator = SpeakCoordinator(keychain: keychain)

            var settings = SpeakSettings.default
            settings.dictionaryAudioEnabled = false
            settings.selectedEngine = .system

            coordinator.speak("hello", accent: .french, settings: settings)
            coordinator.stop()
            #expect(coordinator.isSpeaking == false)
        }
    }

    // MARK: - SpeakPhase state machine

    @Suite("SpeakPhase state machine")
    struct PhaseTests {

        // MARK: .system engine → loading phase (no fallback)

        @Test(".system engine: phase is .loading after speak(), didFallBackToSystem is false")
        @MainActor
        func systemEnginePhaseIsLoadingNoBallback() {
            // autoStart: false — engine does not fire onSpeakingChange synchronously,
            // so the phase stays at .loading after the speak() call returns.
            let spy = SpyTTS(autoStart: false)
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let coordinator = SpeakCoordinator(tts: spy, keychain: keychain)

            var settings = SpeakSettings.default
            settings.selectedEngine = .system
            settings.dictionaryAudioEnabled = false

            coordinator.speak("hello there", accent: .usEnglish, settings: settings)

            // Phase must be .loading synchronously (instant UI feedback).
            #expect(coordinator.phase == .loading)
            // System path is not a fallback — flag must stay false.
            #expect(coordinator.didFallBackToSystem == false)
            // Spy must have received the text.
            #expect(spy.lastSpokenText == "hello there")
        }

        // MARK: .cloud with no key → loading then fallback

        @Test(".cloud(.openAITTS) no key: phase is .loading, didFallBackToSystem is true, spy got text")
        @MainActor
        func cloudNoKeyPhaseLoadingFallback() {
            let spy = SpyTTS(autoStart: false)
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let coordinator = SpeakCoordinator(tts: spy, keychain: keychain)

            var settings = SpeakSettings.default
            settings.selectedEngine = .cloud(.openAITTS)
            settings.dictionaryAudioEnabled = false

            coordinator.speak("hello", accent: .french, settings: settings)

            // Guard 3 (no key) fires synchronously → fallback flag must be true.
            #expect(coordinator.didFallBackToSystem == true)
            // Spy (autoStart: false) received text but didn't fire onSpeakingChange,
            // so phase stays at .loading.
            #expect(coordinator.phase == .loading)
            // Spy must have received the text from the fallback speakWithTTS call.
            #expect(spy.lastSpokenText == "hello")
        }

        // MARK: .cloud over char limit → fallback

        @Test(".cloud(.openAITTS) over cloudCharLimit: didFallBackToSystem is true, spy got text")
        @MainActor
        func cloudOverCharLimitFallback() {
            let spy = SpyTTS(autoStart: false)
            let serviceName = "dinh.thi.PopGuy.Tests.\(UUID().uuidString)"
            let keychain = KeychainManager(serviceName: serviceName)
            keychain.setKey("fake-api-key", account: TTSProviderKind.openAITTS.keychainAccount)
            defer { keychain.deleteKey(account: TTSProviderKind.openAITTS.keychainAccount) }

            let coordinator = SpeakCoordinator(tts: spy, keychain: keychain)

            var settings = SpeakSettings.default
            settings.selectedEngine = .cloud(.openAITTS)
            settings.cloudCharLimit = 5
            settings.dictionaryAudioEnabled = false

            let longText = "this text is over the limit"
            coordinator.speak(longText, accent: .french, settings: settings)

            // Guard 2 (char limit) fires synchronously → fallback flag must be true.
            #expect(coordinator.didFallBackToSystem == true)
            // Spy received the text.
            #expect(spy.lastSpokenText == longText)
        }

        // MARK: stop() sets phase to .idle

        @Test("stop() sets phase to .idle")
        @MainActor
        func stopSetsPhaseIdle() {
            let spy = SpyTTS(autoStart: false)
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let coordinator = SpeakCoordinator(tts: spy, keychain: keychain)

            var settings = SpeakSettings.default
            settings.selectedEngine = .system
            settings.dictionaryAudioEnabled = false

            coordinator.speak("hello", accent: .usEnglish, settings: settings)
            #expect(coordinator.phase == .loading)

            coordinator.stop()
            #expect(coordinator.phase == .idle)
        }

        // MARK: .system path does NOT set didFallBackToSystem

        @Test(".system path does not set didFallBackToSystem")
        @MainActor
        func systemPathNeverSetsDidFallBack() {
            let spy = SpyTTS(autoStart: false)
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let coordinator = SpeakCoordinator(tts: spy, keychain: keychain)

            var settings = SpeakSettings.default
            settings.selectedEngine = .system
            settings.dictionaryAudioEnabled = false

            coordinator.speak("hello", accent: .usEnglish, settings: settings)
            #expect(coordinator.didFallBackToSystem == false)
        }
    }

    // MARK: - Cloud speak() return-value fallback (FIX 2)

    @Suite("Cloud speak() return-value fallback")
    struct CloudSpeakFallbackTests {

        // MARK: SpyCloud returning false → didFallBackToSystem + SpyTTS got text

        @Test(".cloud speak() returns false: didFallBackToSystem is true, local TTS got text")
        @MainActor
        func cloudSpeakReturnsFalseTriggersLocalFallback() async {
            let spyTTS  = SpyTTS(autoStart: true)
            let spyCloud = SpyCloud(speakResult: false)
            let serviceName = "dinh.thi.PopGuy.Tests.\(UUID().uuidString)"
            let keychain = KeychainManager(serviceName: serviceName)
            keychain.setKey("fake-api-key", account: TTSProviderKind.openAITTS.keychainAccount)
            defer { keychain.deleteKey(account: TTSProviderKind.openAITTS.keychainAccount) }

            let coordinator = SpeakCoordinator(tts: spyTTS, cloud: spyCloud, keychain: keychain)

            var settings = SpeakSettings.default
            settings.selectedEngine = .cloud(.openAITTS)
            settings.dictionaryAudioEnabled = false

            coordinator.speak("hello cloud", accent: .french, settings: settings)

            // Wait (bounded) for the cloud Task to complete and the fallback to fire.
            var attempts = 0
            while !coordinator.didFallBackToSystem && attempts < 50 {
                await Task.yield()
                attempts += 1
            }

            #expect(coordinator.didFallBackToSystem == true)
            #expect(spyTTS.lastSpokenText == "hello cloud")
        }

        // MARK: SpyCloud returning true → no fallback, SpyTTS did NOT get text

        @Test(".cloud speak() returns true: didFallBackToSystem is false, local TTS did not get text")
        @MainActor
        func cloudSpeakReturnsTrueNoLocalFallback() async {
            let spyTTS  = SpyTTS(autoStart: true)
            let spyCloud = SpyCloud(speakResult: true)
            let serviceName = "dinh.thi.PopGuy.Tests.\(UUID().uuidString)"
            let keychain = KeychainManager(serviceName: serviceName)
            keychain.setKey("fake-api-key", account: TTSProviderKind.openAITTS.keychainAccount)
            defer { keychain.deleteKey(account: TTSProviderKind.openAITTS.keychainAccount) }

            let coordinator = SpeakCoordinator(tts: spyTTS, cloud: spyCloud, keychain: keychain)

            var settings = SpeakSettings.default
            settings.selectedEngine = .cloud(.openAITTS)
            settings.dictionaryAudioEnabled = false

            coordinator.speak("hello cloud", accent: .french, settings: settings)

            // Wait (bounded) for the cloud Task to complete → cloud engine fires
            // isSpeaking = true which drives phase to .playing.
            var attempts = 0
            while coordinator.phase != .playing && attempts < 50 {
                await Task.yield()
                attempts += 1
            }

            #expect(coordinator.didFallBackToSystem == false)
            #expect(spyTTS.lastSpokenText == nil)
        }

        @Test(".cloud engine: English single word skips dictionary audio and forwards speech speed and pitch")
        @MainActor
        func cloudEnglishWordSkipsDictionaryAndForwardsSpeed() async {
            let spyTTS = SpyTTS(autoStart: true)
            let spyCloud = SpyCloud(speakResult: true)
            let spyDictionary = SpyDictionaryAudio(speakResult: true)
            let serviceName = "dinh.thi.PopGuy.Tests.\(UUID().uuidString)"
            let keychain = KeychainManager(serviceName: serviceName)
            keychain.setKey("fake-api-key", account: TTSProviderKind.openAITTS.keychainAccount)
            defer { keychain.deleteKey(account: TTSProviderKind.openAITTS.keychainAccount) }

            let coordinator = SpeakCoordinator(
                tts: spyTTS,
                dictionary: spyDictionary,
                cloud: spyCloud,
                keychain: keychain
            )

            var settings = SpeakSettings.default
            settings.selectedEngine = .cloud(.openAITTS)
            settings.dictionaryAudioEnabled = true
            settings.rate = AVSpeechUtteranceMaximumSpeechRate
            settings.pitch = 1.5

            coordinator.speak("hello", accent: .usEnglish, settings: settings)

            var attempts = 0
            while spyCloud.speakCallCount == 0 && attempts < 50 {
                await Task.yield()
                attempts += 1
            }

            #expect(spyDictionary.speakRequests.isEmpty)
            #expect(spyCloud.lastSpokenText == "hello")
            // Max system rate (slider level 10) maps to cloud speed 1.5 via
            // the linear 0.6-1.5 mapping centred on the default rate.
            #expect(spyCloud.lastSpeed == 1.5)
            #expect(spyCloud.lastPitch == 1.5)
            #expect(spyTTS.lastSpokenText == nil)
        }
    }

    // MARK: - didFallBackToSystem persist/reset invariants (FIX 3)

    @Suite("didFallBackToSystem persist/reset invariants")
    struct FallbackFlagInvariantTests {

        // MARK: stop() does NOT reset didFallBackToSystem

        @Test("stop() does not reset didFallBackToSystem")
        @MainActor
        func stopDoesNotResetFallbackFlag() {
            let spy = SpyTTS(autoStart: false)
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let coordinator = SpeakCoordinator(tts: spy, keychain: keychain)

            // No API key stored → Guard 3 fires synchronously and sets the flag.
            var settings = SpeakSettings.default
            settings.selectedEngine = .cloud(.openAITTS)
            settings.dictionaryAudioEnabled = false

            coordinator.speak("test", accent: .french, settings: settings)
            #expect(coordinator.didFallBackToSystem == true)

            coordinator.stop()
            // stop() must NOT clear the flag.
            #expect(coordinator.didFallBackToSystem == true)
        }

        // MARK: speak() on .system resets didFallBackToSystem to false

        @Test("speak() on .system engine resets didFallBackToSystem to false")
        @MainActor
        func speakOnSystemEngineResetsFallbackFlag() {
            let spy = SpyTTS(autoStart: false)
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let coordinator = SpeakCoordinator(tts: spy, keychain: keychain)

            // First call: cloud with no key → flag set true.
            var cloudSettings = SpeakSettings.default
            cloudSettings.selectedEngine = .cloud(.openAITTS)
            cloudSettings.dictionaryAudioEnabled = false

            coordinator.speak("test", accent: .french, settings: cloudSettings)
            #expect(coordinator.didFallBackToSystem == true)

            // Second call: system engine → flag must be reset to false at speak() start.
            var systemSettings = SpeakSettings.default
            systemSettings.selectedEngine = .system
            systemSettings.dictionaryAudioEnabled = false

            coordinator.speak("test", accent: .french, settings: systemSettings)
            #expect(coordinator.didFallBackToSystem == false)
        }
    }

    // MARK: - Speak replay (cache-backed "Listen again")

    @Suite("Speak replay")
    struct ReplayTests {

        /// Drives a successful cloud speak to completion, then asserts replay()
        /// re-plays via the cached audio (replayCached) WITHOUT a new speak() call.
        @Test("cloud success: replay() re-plays cached audio, no new request")
        @MainActor
        func cloudReplayUsesCacheNoNewRequest() async {
            let spyTTS = SpyTTS(autoStart: true)
            let spyCloud = SpyCloud(speakResult: true)
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            keychain.setKey("fake-api-key", account: TTSProviderKind.openAITTS.keychainAccount)
            defer { keychain.deleteKey(account: TTSProviderKind.openAITTS.keychainAccount) }

            let coordinator = SpeakCoordinator(tts: spyTTS, cloud: spyCloud, keychain: keychain)
            var settings = SpeakSettings.default
            settings.selectedEngine = .cloud(.openAITTS)
            settings.dictionaryAudioEnabled = false

            coordinator.speak("cached phrase", accent: .french, settings: settings)
            var attempts = 0
            while !coordinator.canReplay && attempts < 50 {
                await Task.yield(); attempts += 1
            }
            #expect(coordinator.canReplay == true)
            #expect(coordinator.lastSpokenText == "cached phrase")
            #expect(spyCloud.speakCallCount == 1)

            coordinator.replay()
            // Cache-backed: replayCached fired, speak() (the network path) did not.
            #expect(spyCloud.replayCallCount == 1)
            #expect(spyCloud.speakCallCount == 1)
            #expect(coordinator.phase == .playing)
            // Local TTS must NOT have been engaged for a cloud-cache replay.
            #expect(spyTTS.lastSpokenText == nil)
        }

        /// A cloud fallback (cloud.speak == false → system voice) must replay via
        /// the system voice, never re-hitting (re-billing) the cloud provider.
        @Test("cloud fallback: replay() re-synthesises locally, no new cloud request")
        @MainActor
        func fallbackReplayDoesNotReHitCloud() async {
            let spyTTS = SpyTTS(autoStart: true)
            let spyCloud = SpyCloud(speakResult: false)
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            keychain.setKey("fake-api-key", account: TTSProviderKind.openAITTS.keychainAccount)
            defer { keychain.deleteKey(account: TTSProviderKind.openAITTS.keychainAccount) }

            let coordinator = SpeakCoordinator(tts: spyTTS, cloud: spyCloud, keychain: keychain)
            var settings = SpeakSettings.default
            settings.selectedEngine = .cloud(.openAITTS)
            settings.dictionaryAudioEnabled = false

            coordinator.speak("fell back", accent: .french, settings: settings)
            var attempts = 0
            while !coordinator.didFallBackToSystem && attempts < 50 {
                await Task.yield(); attempts += 1
            }
            #expect(coordinator.canReplay == true)
            #expect(spyCloud.speakCallCount == 1)

            coordinator.replay()
            // Replay went to the system voice; the cloud provider was not touched again.
            #expect(spyCloud.speakCallCount == 1)
            #expect(spyCloud.replayCallCount == 0)
            #expect(spyTTS.lastSpokenText == "fell back")
        }

        /// clearReplay() drops the cache and the toolbar body state.
        @Test("clearReplay() clears lastSpokenText and canReplay")
        @MainActor
        func clearReplayResetsState() async {
            let spyTTS = SpyTTS(autoStart: true)
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let coordinator = SpeakCoordinator(tts: spyTTS, keychain: keychain)
            var settings = SpeakSettings.default
            settings.selectedEngine = .system
            settings.dictionaryAudioEnabled = false

            coordinator.speak("hello", accent: .french, settings: settings)
            #expect(coordinator.canReplay == true)
            #expect(coordinator.lastSpokenText == "hello")

            coordinator.clearReplay()
            #expect(coordinator.canReplay == false)
            #expect(coordinator.lastSpokenText == nil)
        }

        @Test("dictionary native URL success: replay() replays the same URL")
        @MainActor
        func dictionaryNativeReplayUsesOriginalURL() async {
            let nativeURL = "https://dict.minhqnd.com/audio/xin-chao.mp3"
            let spyTTS = SpyTTS(autoStart: true)
            let spyDictionary = SpyDictionaryAudio(playResult: true, speakResult: false)
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let coordinator = SpeakCoordinator(
                tts: spyTTS,
                dictionary: spyDictionary,
                keychain: keychain
            )

            var settings = SpeakSettings.default
            settings.selectedEngine = .system
            settings.dictionaryAudioEnabled = true

            coordinator.speakDictionary(
                headword: "xin chao",
                nativeAudioURL: nativeURL,
                accent: .usEnglish,
                settings: settings
            )

            var attempts = 0
            while !coordinator.canReplay && attempts < 50 {
                await Task.yield(); attempts += 1
            }

            #expect(coordinator.canReplay == true)
            #expect(spyDictionary.playedURLs == [nativeURL])
            #expect(spyDictionary.speakRequests.isEmpty)

            coordinator.replay()
            attempts = 0
            while spyDictionary.playedURLs.count < 2 && spyDictionary.speakRequests.isEmpty && attempts < 50 {
                await Task.yield(); attempts += 1
            }

            #expect(spyDictionary.playedURLs == [nativeURL, nativeURL])
            #expect(spyDictionary.speakRequests.isEmpty)
            #expect(spyTTS.lastSpokenText == nil)
        }
    }

    // MARK: - Toolbar dictionary Listen toggle

    @Suite("Toolbar dictionary Listen toggle")
    struct ToolbarDictionaryListenTests {

        @Test("dictionary Listen stops loading speech instead of starting a new request")
        @MainActor
        func dictionaryListenStopsWhileLoading() async {
            let spyTTS = SpyTTS(autoStart: false)
            let spyDictionary = SpyDictionaryAudio(playResult: true)
            let keychain = KeychainManager(serviceName: "dinh.thi.PopGuy.Tests.\(UUID().uuidString)")
            let coordinator = SpeakCoordinator(
                tts: spyTTS,
                dictionary: spyDictionary,
                keychain: keychain
            )
            let viewModel = ToolbarViewModel()
            viewModel.bindSpeakCoordinator(coordinator)
            viewModel.finishWithDictionary(DictionaryEntry(
                headword: "hello",
                lexicalEntries: [
                    LexicalEntry(
                        language: "en",
                        partOfSpeech: "interjection",
                        pronunciations: [],
                        senses: [Sense(definition: "used as a greeting", examples: [], synonyms: [])],
                        audioURL: "https://example.com/hello.mp3"
                    )
                ],
                sourceName: "Test Dictionary",
                rawText: nil
            ))

            var settings = SpeakSettings.default
            settings.selectedEngine = .system
            settings.dictionaryAudioEnabled = false
            coordinator.speak("loading phrase", accent: .french, settings: settings)
            #expect(coordinator.phase == .loading)
            #expect(viewModel.speakPhase == .loading)

            viewModel.triggerDictionaryListen()
            await Task.yield()

            #expect(coordinator.phase == .idle)
            #expect(spyDictionary.playedURLs.isEmpty)
            #expect(spyDictionary.speakRequests.isEmpty)
            #expect(spyTTS.isSpeaking == false)
        }
    }

    // MARK: - cloudSpeechSpeed geometric mapping

    @Suite("cloudSpeechSpeed geometric mapping")
    struct CloudSpeechSpeedMappingTests {

        @Test("default system rate maps to cloud speed 1.0 (level 5 = normal)")
        func defaultRateMapsToCloudOne() {
            let speed = SpeakCoordinator.cloudSpeechSpeed(forSystemRate: AVSpeechUtteranceDefaultSpeechRate)
            #expect(speed == 1.0)
        }

        @Test("max system rate maps to 1.5 (level 10, fast end of the 0.6-1.5 range)")
        func maxRateMapsToCloudFastEnd() {
            let speed = SpeakCoordinator.cloudSpeechSpeed(forSystemRate: AVSpeechUtteranceMaximumSpeechRate)
            #expect(speed == 1.5)
        }

        @Test("min system rate maps to 0.6 (level 1, slow end of the 0.6-1.5 range)")
        func minRateMapsToCloudSlowEnd() {
            let speed = SpeakCoordinator.cloudSpeechSpeed(forSystemRate: AVSpeechUtteranceMinimumSpeechRate)
            #expect(speed == 0.6)
        }

        @Test("level 6 (slightly above default) maps to 1.1, a gentle step above 1.0")
        func levelSixMapsToGentleStep() {
            // Level 6 = speakSpeedDefault + 1/5 * (max - default) = 0.5 + 0.1 = 0.6
            let rate: Float = AVSpeechUtteranceDefaultSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceDefaultSpeechRate) / 5
            let speed = SpeakCoordinator.cloudSpeechSpeed(forSystemRate: rate)
            #expect(speed == 1.1)
        }

        @Test("mapping is monotonic non-decreasing across the full slider range")
        func mappingIsMonotonic() {
            var prev: Double = 0
            for level in 1...10 {
                let minR = AVSpeechUtteranceMinimumSpeechRate
                let defR = AVSpeechUtteranceDefaultSpeechRate
                let maxR = AVSpeechUtteranceMaximumSpeechRate
                let rate: Float
                if level <= 5 {
                    rate = minR + Float(level - 1) / 4 * (defR - minR)
                } else {
                    rate = defR + Float(level - 5) / 5 * (maxR - defR)
                }
                let speed = SpeakCoordinator.cloudSpeechSpeed(forSystemRate: rate)
                #expect(speed >= prev, "level \(level) speed \(speed) < prev \(prev)")
                prev = speed
            }
        }
    }
}
