// TTSProviderKind.swift
// PopGuy — SpeakEngine/CloudTTS
//
// Identifies which cloud TTS provider handles a speech request.
// Mirrors the ProviderKind conventions in ProviderTypes.swift.
//
// Isolation: nonisolated — pure value type, opts out of
// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor so it can be used from
// nonisolated contexts (SpeakCoordinator, settings persistence).

import Foundation

// MARK: - TTSProviderKind

/// Identifies which cloud TTS provider handles a speech request.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
nonisolated enum TTSProviderKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case openAITTS      = "openai_tts"
    case googleCloudTTS = "google_cloud_tts"
    case azureTTS       = "azure_tts"

    nonisolated var id: String { rawValue }
}

// MARK: - TTSProviderKind display metadata

extension TTSProviderKind {
    /// Human-readable label for use in Settings pickers.
    nonisolated var displayName: String {
        switch self {
        case .openAITTS:      return "OpenAI"
        case .googleCloudTTS: return "Google Cloud TTS"
        case .azureTTS:       return "Azure Speech"
        }
    }

    /// Official web page where the user can obtain an API key for this provider.
    /// `nil` is not possible for any current case but the return type matches
    /// the ProviderKind convention so the Settings UI can use a uniform code path.
    nonisolated var apiKeyURL: URL? {
        switch self {
        case .openAITTS:
            return URL(string: "https://platform.openai.com/api-keys")
        case .googleCloudTTS:
            return URL(string: "https://console.cloud.google.com/apis/credentials")
        case .azureTTS:
            return URL(string: "https://portal.azure.com/")
        }
    }

    /// Whether this provider requires a region identifier in addition to an API key.
    /// Only Azure Speech requires a region (e.g. "eastus").
    nonisolated var usesRegion: Bool {
        switch self {
        case .openAITTS, .googleCloudTTS: return false
        case .azureTTS:                   return true
        }
    }

    /// A sensible default model id for this provider, or `nil` when the provider
    /// has no meaningful model concept (Google Cloud TTS selects voice, not model).
    nonisolated var defaultModel: String? {
        switch self {
        case .openAITTS:      return "gpt-4o-mini-tts"
        case .googleCloudTTS: return nil
        case .azureTTS:       return nil
        }
    }

    /// Curated model identifiers shown in the Settings model picker.
    /// An empty array means the picker falls back to a plain TextField.
    nonisolated var curatedModels: [String] {
        switch self {
        case .openAITTS:      return ["gpt-4o-mini-tts", "tts-1-hd", "tts-1"]
        case .googleCloudTTS: return []
        case .azureTTS:       return []
        }
    }

    /// The Keychain account string for this provider's API key slot.
    /// Uses `rawValue` so TTS keys are in a distinct namespace from AI provider keys.
    nonisolated var keychainAccount: String { rawValue }

    /// Curated voice identifiers for the given language code, shown in the per-language
    /// voice pickers for locale-bound providers (Google Cloud TTS, Azure Speech).
    ///
    /// Returns the ordered voice list for the specified BCP-47 locale:
    /// - `.googleCloudTTS`: delegates to `GoogleCloudTTSProvider.curatedVoices(forLanguage:)`.
    ///   Chirp3-HD voices first, then Neural2.
    /// - `.azureTTS`: delegates to `AzureTTSProvider.curatedVoices(forLanguage:)`.
    ///   DragonHD voices first, then standard Neural.
    /// - `.openAITTS`: always `[]` — OpenAI uses a single model-wide voice, not per-language.
    ///
    /// - Parameter languageCode: A BCP-47 locale string (e.g. "en-US", "fr-FR").
    /// - Returns: An ordered array of voice identifier strings, or `[]` when the provider
    ///   is not locale-bound or the locale is not in the curated list.
    nonisolated func curatedVoices(forLanguage languageCode: String) -> [String] {
        switch self {
        case .openAITTS:      return []
        case .googleCloudTTS: return GoogleCloudTTSProvider.curatedVoices(forLanguage: languageCode)
        case .azureTTS:       return AzureTTSProvider.curatedVoices(forLanguage: languageCode)
        }
    }

    /// Curated voice identifiers for the given model, shown in the Settings voice picker.
    ///
    /// Returns the voices that are available for the specified model string.
    /// - `openAITTS` with `gpt-4o-mini-tts`: all 13 voices (the gpt-4o-mini-tts exclusive
    ///   voices `ballad`, `verse`, `marin`, and `cedar` are included). `marin` and `cedar`
    ///   are recommended for best quality by OpenAI.
    /// - `openAITTS` with `tts-1` or `tts-1-hd`: the classic 9-voice set.
    /// - Other providers: `[]` (no curated list; voice is handled by language routing).
    ///
    /// - Parameter model: The model identifier string (e.g. `"gpt-4o-mini-tts"`, `"tts-1"`).
    /// - Returns: An ordered array of voice identifier strings for that model.
    nonisolated func curatedVoices(forModel model: String) -> [String] {
        switch self {
        case .openAITTS:
            if model.hasPrefix("gpt-4o-mini-tts") {
                return ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova",
                        "onyx", "sage", "shimmer", "verse", "marin", "cedar"]
            } else {
                return ["alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]
            }
        case .googleCloudTTS, .azureTTS:
            return []
        }
    }
}

// MARK: - TTSProviderKind implemented subset

extension TTSProviderKind {
    /// The subset of providers that have a complete adapter implementation.
    /// The engine picker iterates this list; unimplemented providers are hidden
    /// from the UI until their Phase 5 adapters land.
    nonisolated static var implemented: [TTSProviderKind] { [.openAITTS, .googleCloudTTS, .azureTTS] }

    /// Whether this provider exposes a user-facing model selector in Settings.
    ///
    /// `true` only for OpenAI, where the model (e.g. `gpt-4o-mini-tts`, `tts-1-hd`)
    /// meaningfully changes the voice set and quality. Google Cloud TTS and Azure
    /// Speech select audio quality through the locale-bound voice name, so there is
    /// no user-facing "model" concept — the Settings model row is hidden for them.
    nonisolated var usesModel: Bool {
        switch self {
        case .openAITTS:      return true
        case .googleCloudTTS: return false
        case .azureTTS:       return false
        }
    }
}
