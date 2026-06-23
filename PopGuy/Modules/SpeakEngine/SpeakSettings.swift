// SpeakSettings.swift
// PopGuy — SpeakEngine
//
// Data model for the Speak toolbar action: accent selection, voice override,
// playback rate/pitch, and dictionary-audio preference.
//
// Isolation: nonisolated / Sendable value types — pure data that SettingsStore
// persists and SpeakCoordinator reads across actor boundaries. Mirrors the
// nonisolated enum / nonisolated struct pattern in ActionConfig.swift.
//
// Codable resilience: SpeakSettings.init(from:) uses decodeIfPresent(_:_:) for
// every field so that older persisted blobs (or an empty {}) decode cleanly to
// .default instead of throwing.

import AVFoundation
import Foundation

// MARK: - SpeakEngineSelection

/// Selects whether TTS uses the local system voice or a cloud provider.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
nonisolated enum SpeakEngineSelection: Sendable, Codable, Equatable, Hashable, Identifiable {
    case system
    case cloud(TTSProviderKind)

    // MARK: Stable string representation (used for Codable + id)

    /// Encodes the selection as a single string:
    /// `.system` → "system", `.cloud(k)` → "cloud:" + k.rawValue.
    private nonisolated var encoded: String {
        switch self {
        case .system:       return "system"
        case .cloud(let k): return "cloud:\(k.rawValue)"
        }
    }

    // MARK: Identifiable

    nonisolated var id: String { encoded }

    // MARK: Display

    /// Human-readable label for Settings pickers.
    nonisolated var displayName: String {
        switch self {
        case .system:       return "System voice"
        case .cloud(let k): return k.displayName
        }
    }

    // MARK: Language relevance

    /// Whether the accent/language selection affects this engine's output.
    /// The system voice is always locale-bound. For cloud engines, defers to the
    /// provider adapter's `usesLanguageSelection` (false for multilingual
    /// auto-detecting providers like OpenAI). The UI hides the accent picker when
    /// this is false.
    nonisolated var usesLanguageSelection: Bool {
        switch self {
        case .system:
            return true
        case .cloud(let kind):
            return SpeakCoordinator.providerType(for: kind)?.usesLanguageSelection ?? true
        }
    }

    /// Whether the selected engine accepts a speech-speed override. The system
    /// voice always supports it; cloud engines defer to the provider's capability.
    nonisolated var supportsSpeed: Bool {
        switch self {
        case .system:       return true
        case .cloud(let k): return k.supportsSpeed
        }
    }

    /// Whether the selected engine accepts a pitch override. The system voice
    /// always supports it; cloud engines defer to the provider's capability.
    nonisolated var supportsPitch: Bool {
        switch self {
        case .system:       return true
        case .cloud(let k): return k.supportsPitch
        }
    }

    // MARK: Available selections

    /// All selections the engine picker should show: system first, then every
    /// implemented cloud provider.
    static func available() -> [SpeakEngineSelection] {
        [.system] + TTSProviderKind.implemented.map { .cloud($0) }
    }

    // MARK: Codable

    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(encoded)
    }

    nonisolated init(from decoder: any Decoder) throws {
        // Decode a single string; on any failure (wrong type, missing value,
        // unknown value) fall back to .system — never throw.
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "system"
        if raw == "system" {
            self = .system
        } else if raw.hasPrefix("cloud:") {
            let kindRaw = String(raw.dropFirst("cloud:".count))
            if let kind = TTSProviderKind(rawValue: kindRaw) {
                self = .cloud(kind)
            } else {
                self = .system
            }
        } else {
            self = .system
        }
    }
}

// MARK: - SpeakAccent

/// The language/region accent used for both voice selection and dictionary lookup.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
nonisolated enum SpeakAccent: String, Sendable, Codable, CaseIterable, Identifiable {
    case usEnglish = "usEnglish"
    case ukEnglish = "ukEnglish"
    case french    = "french"
    case spanish   = "spanish"
    case german    = "german"

    nonisolated var id: String { rawValue }

    /// BCP-47 language tag used for exact voice-language matching and TTS locale.
    nonisolated var bcp47: String {
        switch self {
        case .usEnglish: return "en-US"
        case .ukEnglish: return "en-GB"
        case .french:    return "fr-FR"
        case .spanish:   return "es-ES"
        case .german:    return "de-DE"
        }
    }

    /// ISO 639-1 language prefix (used for coarse language detection — note that
    /// voice matching MUST use `bcp47` for exact region disambiguation, since
    /// both en-US and en-GB share the "en" prefix).
    nonisolated var languagePrefix: String {
        switch self {
        case .usEnglish: return "en"
        case .ukEnglish: return "en"
        case .french:    return "fr"
        case .spanish:   return "es"
        case .german:    return "de"
        }
    }

    /// Short label used in the toolbar accent-picker menu.
    nonisolated var shortTag: String {
        switch self {
        case .usEnglish: return "US"
        case .ukEnglish: return "UK"
        case .french:    return "FR"
        case .spanish:   return "ES"
        case .german:    return "DE"
        }
    }

    /// Full human-readable name for the Settings UI.
    nonisolated var displayName: String {
        switch self {
        case .usEnglish: return "US English"
        case .ukEnglish: return "UK English"
        case .french:    return "French"
        case .spanish:   return "Spanish"
        case .german:    return "German"
        }
    }

    /// Free Dictionary API audio variant identifier, or `nil` when the accent
    /// has no corresponding variant. Only US/UK English use real dictionary
    /// recordings; French, Spanish, and German are synthesized via TTS.
    nonisolated var dictionaryVariant: String? {
        switch self {
        case .usEnglish: return "us"
        case .ukEnglish: return "uk"
        case .french:    return nil
        case .spanish:   return nil
        case .german:    return nil
        }
    }

    /// Whether the Free Dictionary API can be used as a pronunciation source
    /// for this accent. False when `dictionaryVariant` is nil.
    nonisolated var usesDictionary: Bool {
        dictionaryVariant != nil
    }

    /// A short natural-language sentence used as the voice preview sample for this accent.
    nonisolated var previewSample: String {
        switch self {
        case .usEnglish, .ukEnglish:
            return "Hello, this is a preview of the selected voice."
        case .french:
            return "Bonjour, ceci est un aperçu de la voix sélectionnée."
        case .spanish:
            return "Hola, esta es una vista previa de la voz seleccionada."
        case .german:
            return "Hallo, dies ist eine Vorschau der ausgewählten Stimme."
        }
    }
}

// MARK: - SpeakSettings

/// Persistent configuration for the Speak toolbar action.
///
/// Stored as JSON in UserDefaults via SettingsStore. All fields default
/// gracefully when absent from an older persisted blob (see `init(from:)`).
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
nonisolated struct SpeakSettings: Sendable, Codable, Equatable {

    /// Accent used when no quick-switch selection is active.
    var defaultAccent: SpeakAccent

    /// `AVSpeechSynthesisVoice` identifier override for the default accent.
    /// `nil` means VoiceCatalog.bestVoice(for: defaultAccent) is used.
    var defaultVoiceID: String?

    /// Ordered list of accents shown in the toolbar's accent quick-switch menu.
    var quickSwitchAccents: [SpeakAccent]

    /// Speech rate passed to AVSpeechUtterance. Clamped by AVFoundation to
    /// AVSpeechUtteranceMinimumSpeechRate … AVSpeechUtteranceMaximumSpeechRate.
    var rate: Float

    /// Baseline pitch multiplier (1.0 = default). AVFoundation range: 0.5–2.0.
    var pitch: Float

    /// When true and the accent supports it, single-word lookups are attempted
    /// via the Free Dictionary API before falling back to AVSpeechSynthesizer.
    var dictionaryAudioEnabled: Bool

    /// Which TTS engine to use: local system voice or a cloud provider.
    var selectedEngine: SpeakEngineSelection

    /// Maximum number of characters forwarded to a cloud TTS provider.
    /// Text longer than this limit is rejected before the network call.
    var cloudCharLimit: Int

    // MARK: Memberwise init with defaults

    init(
        defaultAccent: SpeakAccent = .usEnglish,
        defaultVoiceID: String? = nil,
        quickSwitchAccents: [SpeakAccent] = [.usEnglish, .ukEnglish, .french, .spanish, .german],
        rate: Float = AVSpeechUtteranceDefaultSpeechRate,
        pitch: Float = 1.0,
        dictionaryAudioEnabled: Bool = true,
        selectedEngine: SpeakEngineSelection = .system,
        cloudCharLimit: Int = 600
    ) {
        self.defaultAccent         = defaultAccent
        self.defaultVoiceID        = defaultVoiceID
        self.quickSwitchAccents    = quickSwitchAccents
        self.rate                  = rate
        self.pitch                 = pitch
        self.dictionaryAudioEnabled = dictionaryAudioEnabled
        self.selectedEngine        = selectedEngine
        self.cloudCharLimit        = cloudCharLimit
    }

    // MARK: Codable — resilient decoding

    /// Tolerates absent keys: any field missing from a stored blob decodes to
    /// the same value as `SpeakSettings.default`, preventing decode errors
    /// when old blobs are loaded after a schema evolution.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultAccent         = try c.decodeIfPresent(SpeakAccent.self,          forKey: .defaultAccent)         ?? .usEnglish
        defaultVoiceID        = try c.decodeIfPresent(String.self,                forKey: .defaultVoiceID)
        // Resilient decode: read as [String] and map to known cases, dropping any
        // unknown rawValue so a future accent added in a newer build doesn't crash
        // settings load on an older binary. Only fall back to the default list when
        // the key is ABSENT or the wrong type — a present-but-empty list (the user
        // unchecked every accent) is preserved, not silently replaced.
        let rawAccents = (try? c.decodeIfPresent([String].self, forKey: .quickSwitchAccents)) ?? nil
        if let rawAccents {
            quickSwitchAccents = rawAccents.compactMap { SpeakAccent(rawValue: $0) }
        } else {
            quickSwitchAccents = [.usEnglish, .ukEnglish, .french, .spanish, .german]
        }
        rate                  = try c.decodeIfPresent(Float.self,                 forKey: .rate)                  ?? AVSpeechUtteranceDefaultSpeechRate
        pitch                 = try c.decodeIfPresent(Float.self,                 forKey: .pitch)                 ?? 1.0
        dictionaryAudioEnabled = try c.decodeIfPresent(Bool.self,                 forKey: .dictionaryAudioEnabled) ?? true
        selectedEngine        = try c.decodeIfPresent(SpeakEngineSelection.self,  forKey: .selectedEngine)        ?? .system
        cloudCharLimit        = try c.decodeIfPresent(Int.self,                   forKey: .cloudCharLimit)        ?? 600
    }

    // MARK: Default instance

    /// Factory default: US English, system-best voice, all three accents in the
    /// quick-switch menu, system default rate/pitch, dictionary audio on.
    static let `default` = SpeakSettings()

    // MARK: Cloud gate

    /// Returns a copy of the receiver with the cloud TTS engine forced to
    /// `.system` when `cloudAllowed` is `false`. When `cloudAllowed` is `true`,
    /// returns `self` unchanged.
    ///
    /// This is the single authoritative gate consumed by every speak entry point
    /// so that a user who downgrades (or the public build with a planted engine
    /// value) never silently routes audio to a locked cloud provider.
    nonisolated func resolvingCloudGate(cloudAllowed: Bool) -> SpeakSettings {
        guard !cloudAllowed else { return self }
        if case .cloud = selectedEngine {
            var copy = self
            copy.selectedEngine = .system
            return copy
        }
        return self
    }
}

// MARK: - VoiceCatalog

/// Namespace for all `AVSpeechSynthesisVoice` queries.
///
/// All AVFoundation voice reads are centralised here. No other type in
/// SpeakEngine should call `AVSpeechSynthesisVoice.speechVoices()` directly.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
nonisolated enum VoiceCatalog {

    // MARK: VoiceInfo

    /// Lightweight, Sendable snapshot of one installed AVSpeechSynthesisVoice.
    // nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor so
    // VoiceInfo values can be created and compared on any actor.
    nonisolated struct VoiceInfo: Sendable, Identifiable, Equatable {
        /// `AVSpeechSynthesisVoice.identifier` — stable across reboots.
        let id: String
        /// `AVSpeechSynthesisVoice.name` — display name shown in the UI.
        let displayName: String
        /// BCP-47 language tag (`AVSpeechSynthesisVoice.language`).
        let bcp47: String
        /// Human-readable quality tier: "Default", "Enhanced", or "Premium".
        let qualityLabel: String
    }

    // MARK: Quality helpers

    /// Converts `AVSpeechSynthesisVoiceQuality` to a display label.
    private static func qualityLabel(for quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default:   return "Default"
        case .enhanced:  return "Enhanced"
        case .premium:   return "Premium"
        @unknown default: return "Default"
        }
    }

    /// Numeric rank used for sorting: higher = better quality.
    private static func qualityRank(for quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .default:    return 0
        case .enhanced:   return 1
        case .premium:    return 2
        @unknown default: return 0
        }
    }

    // MARK: Public API

    /// All installed voices whose `language` exactly matches `accent.bcp47`.
    ///
    /// Exact region matching (e.g. `"en-US"` vs `"en-GB"`) means US and UK
    /// voices are kept distinct. Sorted best quality first.
    static func voices(for accent: SpeakAccent) -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == accent.bcp47 }
            .sorted { qualityRank(for: $0.quality) > qualityRank(for: $1.quality) }
            .map { voice in
                VoiceInfo(
                    id: voice.identifier,
                    displayName: voice.name,
                    bcp47: voice.language,
                    qualityLabel: qualityLabel(for: voice.quality)
                )
            }
    }

    /// The highest-quality installed voice whose `language` exactly matches
    /// `accent.bcp47`, or `nil` if no matching voice is installed.
    static func bestVoice(for accent: SpeakAccent) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == accent.bcp47 }
            .max { qualityRank(for: $0.quality) < qualityRank(for: $1.quality) }
    }

    /// Returns the `AVSpeechSynthesisVoice` for a known identifier, or `nil`
    /// if the voice is not installed on this machine.
    static func voice(forIdentifier id: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(identifier: id)
    }
}
