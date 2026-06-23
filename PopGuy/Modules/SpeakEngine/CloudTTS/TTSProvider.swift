// TTSProvider.swift
// PopGuy — SpeakEngine/CloudTTS
//
// Core protocol for all cloud TTS provider adapters, plus the shared error type.
// Adapters are stateless namespaces of static functions — they hold no instance
// state. Callers interact with a metatype (`any TTSProvider.Type`) so they can
// switch adapters at runtime without boxing a concrete instance.
//
// Isolation: nonisolated — opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
// so adapters and helpers can be called from any executor context.

import Foundation

// MARK: - TTSProviderError

/// Errors thrown by TTSProvider adapters and helpers.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum TTSProviderError: Error, Equatable {

    /// No API key is stored in the Keychain for this provider.
    case missingAPIKey

    /// A region identifier is required but was not supplied in `TTSProviderConfig`.
    /// (Applies to Azure Speech, which routes requests by region.)
    case missingRegion

    /// Text or JSON encoding of the request body failed.
    case encoding

    /// The provider returned a non-2xx HTTP status code.
    /// `body` contains the raw response body for diagnostics (may be nil if unreadable).
    case http(status: Int, body: String?)

    /// Decoding the provider's response into audio data failed.
    /// The associated value is a human-readable reason string.
    case decode(String)

    /// The requested provider has no adapter implementation yet.
    /// The associated value names the provider for diagnostic messages.
    case notImplemented(String)
}

// MARK: - TTSProvider

/// A stateless cloud TTS adapter.
///
/// Conformers expose only static requirements — they are pure namespaces with
/// no stored state. Callers hold a metatype (`any TTSProvider.Type`) to choose
/// the active adapter at runtime.
///
/// All methods that touch the network are split into two stages:
///   1. `makeSynthesisRequest` / `makeValidationRequest` — pure, testable,
///      never performs I/O.
///   2. The actual URL session call — performed by the engine layer, not here.
///
/// To add a new provider: create a new `nonisolated enum MyProvider: TTSProvider`
/// that implements all static requirements. No changes to the engine are needed.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated protocol TTSProvider: Sendable {

    /// The canonical kind tag for this provider.
    static var kind: TTSProviderKind { get }

    /// Whether the language/accent selection meaningfully affects this provider's
    /// output. Locale-bound providers (Google, Azure) and the system voice need a
    /// language to pick a voice, so this is `true`. Multilingual providers that
    /// auto-detect the language from the input text (OpenAI) ignore the language
    /// entirely and override this to `false`, which lets the UI hide the accent
    /// picker. Defaults to `true` via the protocol extension below.
    static var usesLanguageSelection: Bool { get }

    /// Returns a sensible default voice identifier for the given BCP-47 language code.
    ///
    /// Multilingual providers (e.g. OpenAI) may return a single good voice regardless
    /// of `languageCode`. Locale-bound providers (Google, Azure) should return the
    /// most natural voice for that locale.
    ///
    /// - Parameter languageCode: A BCP-47 code such as `"en-US"` or `"fr-FR"`.
    /// - Returns: A provider-specific voice identifier string.
    static func defaultVoice(forLanguage languageCode: String) -> String

    /// Builds the POST request to synthesise `text` as spoken audio.
    ///
    /// This method is purely constructive — it performs no I/O and is safe to
    /// call on any actor. The resulting `URLRequest` is ready to be handed to
    /// a `URLSession`.
    ///
    /// - Parameters:
    ///   - text: The input text to synthesise.
    ///   - voice: The voice identifier to use (already resolved by `resolveTTSVoice`).
    ///   - languageCode: BCP-47 language tag forwarded to providers that need it in
    ///     the request body (Google, Azure).
    ///   - speed: Optional speech-speed override on the provider's native scale
    ///     (nil → provider default). Conformers should clamp to their supported
    ///     range; OpenAI uses 0.25–4.0 (1.0 = default).
    ///   - pitch: Optional pitch override as an AVFoundation-style multiplier
    ///     (0.5–2.0, 1.0 = default). Providers that don't support pitch (e.g.
    ///     OpenAI) accept and ignore the parameter; locale-bound providers
    ///     (Google, Azure) map it onto their native pitch representation.
    ///   - config: Per-provider configuration (model override, region, etc.).
    ///   - apiKey: The API key retrieved from the Keychain.
    /// - Returns: A fully-formed `URLRequest`.
    /// - Throws: `TTSProviderError.missingAPIKey` when `apiKey` is empty;
    ///   `TTSProviderError.missingRegion` when a region is required but absent;
    ///   `TTSProviderError.encoding` when the JSON body cannot be serialised.
    static func makeSynthesisRequest(
        text: String,
        voice: String,
        languageCode: String,
        speed: Double?,
        pitch: Double?,
        config: TTSProviderConfig,
        apiKey: String
    ) throws -> URLRequest

    /// Converts the raw HTTP response body into playable MP3 bytes.
    ///
    /// - Providers that return raw binary (OpenAI, Azure): return `data` unchanged.
    /// - Providers that wrap audio in JSON (Google Cloud TTS): base64-decode the
    ///   `audioContent` field and return the decoded bytes.
    ///
    /// - Parameter data: The raw response body from `URLSession`.
    /// - Returns: MP3-encoded audio bytes ready for `AVAudioPlayer` / `AVPlayer`.
    /// - Throws: `TTSProviderError.decode(_:)` when the body cannot be interpreted
    ///   as the expected format.
    static func decodeAudio(from data: Data) throws -> Data

    /// Builds a cheap request to verify that `apiKey` is valid for this provider.
    ///
    /// The request should be the least expensive call the provider API supports
    /// that still exercises authentication — for example, a models-list endpoint
    /// or a minimal synthesis payload. It must not produce audible output.
    ///
    /// - Parameters:
    ///   - apiKey: The API key to validate.
    ///   - config: Per-provider configuration (region, etc.).
    /// - Returns: A fully-formed `URLRequest`.
    /// - Throws: `TTSProviderError.missingAPIKey` when `apiKey` is empty;
    ///   `TTSProviderError.missingRegion` when a region is required but absent.
    static func makeValidationRequest(
        apiKey: String,
        config: TTSProviderConfig
    ) throws -> URLRequest
}

// MARK: - TTSProvider defaults

nonisolated extension TTSProvider {
    /// Default: language selection is meaningful. Multilingual providers override.
    static var usesLanguageSelection: Bool { true }

    /// Backward-compatible convenience for call sites/tests that do not need a
    /// provider-specific speech speed override.
    static func makeSynthesisRequest(
        text: String,
        voice: String,
        languageCode: String,
        config: TTSProviderConfig,
        apiKey: String
    ) throws -> URLRequest {
        try makeSynthesisRequest(
            text: text,
            voice: voice,
            languageCode: languageCode,
            speed: nil,
            pitch: nil,
            config: config,
            apiKey: apiKey
        )
    }
}

// MARK: - resolveTTSVoice

/// Resolves the voice identifier to use for a synthesis call.
///
/// The resolution order is:
///   1. A per-language override stored in `config.voiceOverrides` (user preference,
///      highest priority — locale-bound providers use this for per-language routing).
///   2. The provider-wide default voice in `config.defaultVoice` (applies to
///      multilingual providers like OpenAI where one voice serves all languages).
///   3. The adapter's built-in default voice for the given language tag.
///
/// - Parameters:
///   - languageCode: A BCP-47 language code (e.g. `"en-US"`, `"ja-JP"`).
///   - config: The provider's persisted configuration (may contain voice overrides).
///   - provider: The metatype of the concrete `TTSProvider` adapter.
/// - Returns: The resolved voice identifier string.
nonisolated func resolveTTSVoice(
    languageCode: String,
    config: TTSProviderConfig,
    provider: any TTSProvider.Type
) -> String {
    config.voiceOverrides[languageCode] ?? config.defaultVoice ?? provider.defaultVoice(forLanguage: languageCode)
}
