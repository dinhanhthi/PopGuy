// AzureTTSProvider.swift
// PopGuy — SpeakEngine/CloudTTS
//
// Cloud TTS adapter for the Azure Speech Service REST API.
// Stateless namespace of static functions — conforms to TTSProvider.
//
// Isolation: nonisolated — opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
// so the adapter can be called from any executor context without a hop.
//
// API shape (confirmed from Azure Speech REST TTS reference,
// fetched 2026-06-12 via WebFetch from learn.microsoft.com):
//   POST https://<region>.tts.speech.microsoft.com/cognitiveservices/v1
//   Ocp-Apim-Subscription-Key: <key>
//   Content-Type: application/ssml+xml
//   X-Microsoft-OutputFormat: audio-24khz-48kbitrate-mono-mp3
//   User-Agent: <application name> (required, < 255 chars)
//   Body: SSML (UTF-8)
//   Response: raw MP3 bytes
//
// Voice-list endpoint (docs-matched; regional path inferred from resource-name
// form https://<resource>.cognitiveservices.azure.com/tts/cognitiveservices/voices/list):
//   GET https://<region>.tts.speech.microsoft.com/cognitiveservices/voices/list
//   Ocp-Apim-Subscription-Key: <key>
//
// NOTE: The API key is passed in the Ocp-Apim-Subscription-Key header —
// NEVER log the request headers or this header's value.

import Foundation

// MARK: - AzureTTSProvider

/// Cloud TTS adapter for the Azure Speech Service REST API.
///
/// Azure voices are locale-bound — each voice only works with its matching
/// locale. `defaultVoice(forLanguage:)` returns the correct Neural voice for
/// each supported locale. Unsupported locales fall back to `en-US-JennyNeural`.
///
/// A non-nil, non-empty `config.region` is required — the synthesis endpoint
/// URL host is region-specific. If missing, `makeSynthesisRequest` and
/// `makeValidationRequest` throw `TTSProviderError.missingRegion`.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum AzureTTSProvider: TTSProvider {

    // MARK: - TTSProvider conformance

    static var kind: TTSProviderKind { .azureTTS }

    /// Returns a locale-correct default Neural voice for the given BCP-47 language code.
    ///
    /// Voice names are confirmed from the Azure Speech language-support documentation
    /// (fetched 2026-06-12). All returned voices are Neural and are available as GA.
    ///
    /// IMPORTANT: Each voice is locale-bound — the returned name must be used with a
    /// matching `xml:lang` in every SSML synthesis request.
    ///
    /// Supported locales and chosen defaults:
    /// - `en-US` → `en-US-JennyNeural` (Female, GA)
    /// - `en-GB` → `en-GB-SoniaNeural` (Female, GA)
    /// - `fr-FR` → `fr-FR-DeniseNeural` (Female, GA)
    /// - `es-ES` → `es-ES-ElviraNeural` (Female, GA)
    /// - `de-DE` → `de-DE-KatjaNeural` (Female, GA)
    /// - Any other → falls back to `en-US-JennyNeural`
    static func defaultVoice(forLanguage languageCode: String) -> String {
        switch languageCode {
        case "en-US": return "en-US-JennyNeural"
        case "en-GB": return "en-GB-SoniaNeural"
        case "fr-FR": return "fr-FR-DeniseNeural"
        case "es-ES": return "es-ES-ElviraNeural"
        case "de-DE": return "de-DE-KatjaNeural"
        default:      return "en-US-JennyNeural"
        }
    }

    /// Returns a curated list of voice identifiers for the given BCP-47 language code.
    ///
    /// Voices are ordered highest-to-lowest quality: Neural HD (DragonHDLatestNeural) first
    /// (newest, expressive), then standard Neural voices.
    /// Voice names are verified from the Azure Speech language-support documentation
    /// (fetched 2026-06-12 from learn.microsoft.com/en-us/azure/ai-services/speech-service/language-support).
    ///
    /// All voices are locale-bound — every name in the returned array contains the
    /// locale prefix (e.g. "en-US-") as a hard invariant.
    ///
    /// - Parameter languageCode: A BCP-47 locale string (e.g. "en-US", "fr-FR").
    /// - Returns: An ordered array of voice identifier strings, or `[]` for unknown locales.
    static func curatedVoices(forLanguage languageCode: String) -> [String] {
        switch languageCode {
        case "en-US":
            return [
                "en-US-Aria:DragonHDLatestNeural",
                "en-US-Jenny:DragonHDLatestNeural",
                "en-US-Andrew:DragonHDLatestNeural",
                "en-US-Brian:DragonHDLatestNeural",
                "en-US-AriaNeural",
                "en-US-JennyNeural",
                "en-US-GuyNeural",
            ]
        case "en-GB":
            return [
                "en-GB-Ada:DragonHDLatestNeural",
                "en-GB-Ollie:DragonHDLatestNeural",
                "en-GB-SoniaNeural",
                "en-GB-RyanNeural",
                "en-GB-LibbyNeural",
            ]
        case "fr-FR":
            return [
                "fr-FR-Vivienne:DragonHDLatestNeural",
                "fr-FR-Remy:DragonHDLatestNeural",
                "fr-FR-DeniseNeural",
                "fr-FR-HenriNeural",
            ]
        case "es-ES":
            return [
                "es-ES-Ximena:DragonHDLatestNeural",
                "es-ES-Tristan:DragonHDLatestNeural",
                "es-ES-ElviraNeural",
                "es-ES-AlvaroNeural",
            ]
        case "de-DE":
            return [
                "de-DE-Seraphina:DragonHDLatestNeural",
                "de-DE-Florian:DragonHDLatestNeural",
                "de-DE-KatjaNeural",
                "de-DE-ConradNeural",
            ]
        default:
            return []
        }
    }

    /// Builds a POST request to synthesise `text` using the Azure Speech REST API.
    ///
    /// The request body is an SSML document. The user text is XML-escaped before
    /// insertion — `&`, `<`, `>`, `"`, and `'` are replaced with their XML entities
    /// (in that order, with `&` replaced first to avoid double-escaping).
    ///
    /// **Never log the returned `URLRequest` or its headers** — the API key is
    /// present in the `Ocp-Apim-Subscription-Key` header.
    ///
    /// - Throws: `TTSProviderError.missingAPIKey` when `apiKey` is empty.
    /// - Throws: `TTSProviderError.missingRegion` when `config.region` is nil or empty.
    /// - Throws: `TTSProviderError.encoding` when the URL cannot be constructed or the
    ///   SSML body cannot be UTF-8 encoded.
    static func makeSynthesisRequest(
        text: String,
        voice: String,
        languageCode: String,
        speed: Double?,
        pitch: Double?,
        config: TTSProviderConfig,
        apiKey: String
    ) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw TTSProviderError.missingAPIKey }
        guard let region = config.region, !region.isEmpty else { throw TTSProviderError.missingRegion }

        let url = try buildSynthesisURL(region: region)

        let ssml = buildSSML(
            text: text,
            voice: voice,
            languageCode: languageCode,
            speed: speed,
            pitch: pitch
        )

        guard let bodyData = ssml.data(using: .utf8) else {
            throw TTSProviderError.encoding
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey,                           forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml",           forHTTPHeaderField: "Content-Type")
        request.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("PopGuy",                         forHTTPHeaderField: "User-Agent")
        request.httpBody = bodyData
        return request
    }

    /// Returns the raw response bytes as-is.
    ///
    /// Azure Speech returns raw MP3 bytes directly — no JSON unwrapping needed.
    ///
    /// - Throws: `TTSProviderError.decode("empty audio")` when `data` is empty.
    static func decodeAudio(from data: Data) throws -> Data {
        guard !data.isEmpty else { throw TTSProviderError.decode("empty audio") }
        return data
    }

    /// Builds a cheap GET request to the voices list endpoint to verify `apiKey`.
    ///
    /// This endpoint returns 2xx for a valid subscription key and is the least
    /// expensive call that exercises authentication without producing audio.
    ///
    /// **Never log the returned `URLRequest` or its headers** — the API key is
    /// present in the `Ocp-Apim-Subscription-Key` header.
    ///
    /// - Throws: `TTSProviderError.missingAPIKey` when `apiKey` is empty.
    /// - Throws: `TTSProviderError.missingRegion` when `config.region` is nil or empty.
    /// - Throws: `TTSProviderError.encoding` when the URL cannot be constructed.
    static func makeValidationRequest(
        apiKey: String,
        config: TTSProviderConfig
    ) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw TTSProviderError.missingAPIKey }
        guard let region = config.region, !region.isEmpty else { throw TTSProviderError.missingRegion }

        let url = try buildVoicesListURL(region: region)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        return request
    }

    // MARK: - Private helpers

    /// Constructs the synthesis endpoint URL for the given region.
    private static func buildSynthesisURL(region: String) throws -> URL {
        guard let url = URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1") else {
            throw TTSProviderError.encoding
        }
        return url
    }

    /// Constructs the voices-list endpoint URL for the given region.
    private static func buildVoicesListURL(region: String) throws -> URL {
        guard let url = URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/voices/list") else {
            throw TTSProviderError.encoding
        }
        return url
    }

    /// Returns a minimal SSML document for the given text, voice, and language code.
    ///
    /// When `speed` and/or `pitch` are non-nil, the text is wrapped in a
    /// `<prosody>` element. Azure SSML `rate` accepts a multiplier (e.g.
    /// "1.5") or percentage; we use the numeric form matching the cloud speed
    /// scale (0.25–4.0, 1.0 = default). `pitch` accepts relative semitones
    /// (e.g. "+2st") or absolute Hz; we use the relative semitone form derived
    /// from PopGuy's pitch multiplier (1.0 = +0st).
    /// The user text is XML-escaped before insertion. Escaping order: `&` first (to
    /// avoid double-escaping), then `<`, `>`, `"`, `'`.
    private static func buildSSML(
        text: String,
        voice: String,
        languageCode: String,
        speed: Double?,
        pitch: Double?
    ) -> String {
        let escaped = xmlEscape(text)
        let inner: String
        if speed == nil && pitch == nil {
            inner = escaped
        } else {
            var attrs = ""
            if let speed {
                attrs += " rate='\(formatRate(speed))'"
            }
            if let pitch {
                attrs += " pitch='\(AzureTTSProvider.semitoneString(forPitchMultiplier: pitch))'"
            }
            inner = "<prosody\(attrs)>\(escaped)</prosody>"
        }
        return "<speak version='1.0' xml:lang='\(languageCode)'><voice name='\(voice)'>\(inner)</voice></speak>"
    }

    /// Formats the cloud speed value for Azure SSML `rate`. 1.0 is emitted as
    /// "+0%" so Azure treats it as default; otherwise a relative percentage is
    /// derived from the multiplier (e.g. 1.5 → "+50%", 0.5 → "-50%").
    private static func formatRate(_ speed: Double) -> String {
        let clamped = min(max(speed, 0.25), 4.0)
        let percent = (clamped - 1.0) * 100
        let rounded = (percent * 10).rounded() / 10
        let sign = rounded >= 0 ? "+" : ""
        return "\(sign)\(rounded)%"
    }

    /// Maps PopGuy's AVFoundation-style pitch multiplier (0.5–2.0, 1.0 = default)
    /// onto Azure SSML's relative semitone notation (e.g. "+2st", "-3st").
    /// Uses a log2 mapping so each octave doubles the multiplier, matching how
    /// perceived pitch maps to frequency ratios. 1.0 → "+0st".
    nonisolated static func semitoneString(forPitchMultiplier multiplier: Double) -> String {
        let clamped = min(max(multiplier, 0.5), 2.0)
        let semitones = 12.0 * log2(clamped)
        let rounded = (semitones * 10).rounded() / 10
        let sign = rounded >= 0 ? "+" : ""
        return "\(sign)\(rounded)st"
    }

    /// XML-escapes untrusted user text for safe insertion into an SSML document.
    ///
    /// Replaces the five XML special characters with their named entities.
    /// `&` is replaced first to prevent double-escaping of entities already in the string.
    private static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'",  with: "&apos;")
    }
}
