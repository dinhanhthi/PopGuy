// DictionaryConfig.swift
// PopGuy — SettingsStore
//
// Codable configuration for the Look up action.
//
// Isolation: nonisolated / Sendable value type — persisted by SettingsStore and
// read by DictionaryEngine via a Sendable snapshot.
//
// NOTE: API keys are NOT stored here. v1 dictionary providers are key-less.

import Foundation

// MARK: - DictionaryConfig

/// Per-action configuration for the Look up toolbar action.
nonisolated struct DictionaryConfig: Sendable, Codable, Equatable {
    /// Target provider. The built-in Look up ignores this and queries every provider
    /// concurrently; a custom Dictionary action looks up in this single provider.
    var provider: DictionaryProviderKind
    var definitionLanguage: String
    /// Dark-launch default: disabled until explicitly enabled in Settings.
    var isEnabled: Bool
    /// Dedicated speech settings for dictionary listening (independent of Speak action).
    var speakSettings: SpeakSettings
    /// Drives Free Dictionary API audio variant and TTS voice for the Listen button.
    var accent: SpeakAccent

    init(
        provider: DictionaryProviderKind = .macOSBuiltin,
        definitionLanguage: String = "en",
        isEnabled: Bool = false,
        speakSettings: SpeakSettings = .default,
        accent: SpeakAccent = .usEnglish
    ) {
        self.provider = provider
        self.definitionLanguage = definitionLanguage
        self.isEnabled = isEnabled
        self.speakSettings = speakSettings
        self.accent = accent
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider           = try c.decodeIfPresent(DictionaryProviderKind.self, forKey: .provider)           ?? .macOSBuiltin
        definitionLanguage = try c.decodeIfPresent(String.self,                  forKey: .definitionLanguage) ?? "en"
        isEnabled          = try c.decodeIfPresent(Bool.self,                      forKey: .isEnabled)          ?? false
        speakSettings      = try c.decodeIfPresent(SpeakSettings.self,             forKey: .speakSettings)      ?? .default
        accent             = try c.decodeIfPresent(SpeakAccent.self,               forKey: .accent)             ?? .usEnglish
    }

    static let `default` = DictionaryConfig()
}
