// TTSProviderConfig.swift
// PopGuy — SpeakEngine/CloudTTS
//
// Per-provider configuration stored in SettingsStore for cloud TTS.
//
// Isolation: nonisolated / Sendable value type — pure data that crosses
// actor boundaries without a MainActor hop. Mirrors the SpeakSettings
// resilient-Codable pattern: every field uses decodeIfPresent so old
// persisted blobs decode cleanly to `.default`.

import Foundation

// MARK: - TTSProviderConfig

/// Persistent per-provider configuration for a cloud TTS provider.
///
/// Keyed in SettingsStore by `TTSProviderKind`. Stored as JSON via
/// the standard UserDefaults/JSON-encoder pipeline used for all settings.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
nonisolated struct TTSProviderConfig: Sendable, Codable, Equatable {

    /// Per-language voice overrides.
    ///
    /// Key: BCP-47 language code (e.g. `"en-US"`, `"fr-FR"`).
    /// Value: provider-specific voice identifier.
    /// An empty dictionary means all languages use the provider's default voice.
    var voiceOverrides: [String: String]

    /// Provider-wide default voice override.
    ///
    /// Used by multilingual providers (e.g. OpenAI) where a single voice applies
    /// to every language. When set, this voice is used unless overridden by a
    /// per-language entry in `voiceOverrides`. When `nil`, the adapter's built-in
    /// default voice is used.
    var defaultVoice: String?

    /// Model identifier override. When `nil` the adapter falls back to
    /// `TTSProviderKind.defaultModel` (OpenAI) or the provider default.
    var model: String?

    /// Azure region identifier (e.g. `"eastus"`). Ignored by providers
    /// where `TTSProviderKind.usesRegion` is `false`.
    var region: String?

    // MARK: Memberwise init with defaults

    init(
        voiceOverrides: [String: String] = [:],
        defaultVoice: String? = nil,
        model: String? = nil,
        region: String? = nil
    ) {
        self.voiceOverrides = voiceOverrides
        self.defaultVoice   = defaultVoice
        self.model          = model
        self.region         = region
    }

    // MARK: Codable — resilient decoding

    /// Tolerates absent keys: any field missing from a stored blob decodes to
    /// the same value as `TTSProviderConfig.default`, preventing decode errors
    /// when old blobs are loaded after a schema evolution.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voiceOverrides = try c.decodeIfPresent([String: String].self, forKey: .voiceOverrides) ?? [:]
        defaultVoice   = try c.decodeIfPresent(String.self,           forKey: .defaultVoice)
        model          = try c.decodeIfPresent(String.self,           forKey: .model)
        region         = try c.decodeIfPresent(String.self,           forKey: .region)
    }

    // MARK: Voice-reset helper

    /// Returns a copy of this config with `defaultVoice` cleared when it is
    /// non-nil and no longer present in `validVoices` for the given model.
    /// Returns `self` unchanged when `defaultVoice` is nil or is still valid.
    func clearingInvalidDefaultVoice(forModel model: String, validVoices: [String]) -> TTSProviderConfig {
        guard let dv = defaultVoice, !validVoices.contains(dv) else { return self }
        var copy = self
        copy.defaultVoice = nil
        return copy
    }

    // MARK: Default instance

    /// Factory default: no voice overrides, no model override, no region.
    static let `default` = TTSProviderConfig()
}
