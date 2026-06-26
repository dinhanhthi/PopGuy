// ActionConfig.swift
// PopGuy — SettingsStore
//
// Codable model for a single action's provider+model mapping.
//
// Isolation: nonisolated / Sendable value type — these are pure data objects
// that SettingsStore encodes/decodes and ActionEngine reads via a Sendable
// snapshot. They never hold mutable state so they cross actor boundaries
// without issue.
//
// NOTE: API keys are NOT stored here. They go through KeychainManager.

import Foundation

// MARK: - ActionKind

/// Identifies a built-in action type.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
nonisolated enum ActionKind: String, Sendable, CaseIterable, Codable {
    /// Improve / rewrite the selected text.
    case improve  = "improve"
    /// Shorten / condense the selected text without losing the main ideas.
    case shorten = "shorten"
    /// Proofread the selected text: fix spelling/grammar without rephrasing.
    case proofread = "proofread"
    /// Translate the selected text to the configured target language.
    case translate = "translate"
    /// Run a user-typed one-off prompt against the selected text.
    case prompt = "prompt"
}

// MARK: - Allowed providers per action kind

extension ActionKind {
    /// Provider kinds that may be selected for this action.
    ///
    /// Improve, Shorten, and Proofread require an AI/rewriting provider
    /// (no target language needed).
    /// Translate supports all providers including dedicated translation services.
    nonisolated var allowedProviders: [ProviderKind] {
        switch self {
        case .improve, .shorten, .proofread, .prompt:
            return [.openAI, .anthropic, .ollama, .gemini, .glm, .openRouter, .custom,
                    .claudeCLI, .codexCLI, .geminiCLI, .mlxLocal]
        case .translate:
            return ProviderKind.allCases
        }
    }
}

// MARK: - TranslateTone

/// Optional register applied to an action's output.
///
/// Used by the Improve, Shorten, and Translate actions. `neutral` is the default
/// (no tone steering). The other cases append a short instruction fragment to the
/// action's prompt (and, for Translate via DeepL, map to a `formality` parameter).
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
nonisolated enum TranslateTone: String, Sendable, CaseIterable, Codable, Identifiable {
    case neutral
    case formal
    case casual
    case professional
    case friendly

    nonisolated var id: String { rawValue }

    /// User-visible label for the tone picker.
    nonisolated var displayName: String {
        switch self {
        case .neutral:      return "Neutral"
        case .formal:       return "Formal"
        case .casual:       return "Casual"
        case .professional: return "Professional"
        case .friendly:     return "Friendly"
        }
    }

    /// Instruction fragment appended to the action prompt, or `nil` for
    /// `neutral` (no tone steering — the default behavior).
    ///
    /// - Parameter targetLanguage: BCP-47 target language for the Translate
    ///   action (e.g. "fr"), or `nil` for Improve/Shorten (text stays in its
    ///   original language). When the target language is French and the tone is
    ///   `friendly`, an explicit instruction to use informal "tu"/"toi" rather
    ///   than "vous" is appended — French does not default to the informal
    ///   register, so it must be requested.
    nonisolated func promptFragment(targetLanguage: String?) -> String? {
        switch self {
        case .neutral:      return nil
        case .formal:       return "Use a formal tone."
        case .casual:       return "Use a casual, conversational tone."
        case .professional: return "Use a professional tone."
        case .friendly:
            var fragment = "Use a friendly, warm, conversational tone."
            if let lang = targetLanguage?.lowercased(), lang == "fr" || lang.hasPrefix("fr-") {
                fragment += " When writing in French, address the reader informally using \"tu\"/\"toi\" rather than \"vous\"."
            }
            return fragment
        }
    }

    /// DeepL `formality` parameter for this tone, or `nil` for no preference.
    ///
    /// DeepL has no free-form prompt; the only register control is `formality`.
    /// The `prefer_*` values are used (not the strict `more`/`less`) so DeepL
    /// silently ignores them for target languages without formality support
    /// instead of returning an error. For French, `prefer_less` yields "tu".
    nonisolated var deepLFormality: String? {
        switch self {
        case .neutral:                 return nil
        case .formal, .professional:   return "prefer_more"
        case .casual, .friendly:       return "prefer_less"
        }
    }
}

// MARK: - ActionConfig

/// Configuration for one action: which provider + model to use.
///
/// Immutable value type. One config exists per `ActionKind` in SettingsStore.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
nonisolated struct ActionConfig: Sendable, Codable, Equatable {

    /// The action this config applies to.
    let id: ActionKind

    /// The provider that executes this action.
    let providerKind: ProviderKind

    /// The model identifier string for the provider (e.g. "gpt-4o", "claude-sonnet-4-6").
    let model: String

    /// User-defined custom prompt.
    /// - Improve: overrides the predefined prompt. `nil` means use the predefined one.
    /// - Translate: additive — extra instructions layered on top of the built-in
    ///   (invisible) translate prompt. `nil` means no extra instructions.
    var customPrompt: String?

    /// Output tone for the Improve, Shorten, and Translate actions.
    /// Ignored by Proofread (which preserves the author's tone). `nil` is
    /// treated as `.neutral`.
    var tone: TranslateTone?

    init(
        id: ActionKind,
        providerKind: ProviderKind,
        model: String,
        customPrompt: String? = nil,
        tone: TranslateTone? = nil
    ) {
        self.id = id
        self.providerKind = providerKind
        self.model = model
        self.customPrompt = customPrompt
        self.tone = tone
    }
}

// MARK: - Defaults

extension ActionConfig {
    /// The provider every predefined action defaults to.
    static let defaultProviderKind: ProviderKind = .openAI

    /// The model every predefined action defaults to: the first entry of the
    /// default provider's curated model list. Derived (not hard-coded) so editing
    /// `ProviderKind.curatedModels` updates every default at once. The `??`
    /// fallback only fires if the curated list is ever emptied.
    static let defaultModel: String = defaultProviderKind.curatedModels.first ?? "gpt-5.5"

    /// Default configuration for Improve: OpenAI / first curated model.
    static let defaultImprove = ActionConfig(
        id: .improve,
        providerKind: defaultProviderKind,
        model: defaultModel
    )

    /// Default configuration for Shorten: OpenAI / first curated model.
    static let defaultShorten = ActionConfig(
        id: .shorten,
        providerKind: defaultProviderKind,
        model: defaultModel
    )

    /// Default configuration for Proofread: OpenAI / first curated model.
    static let defaultProofread = ActionConfig(
        id: .proofread,
        providerKind: defaultProviderKind,
        model: defaultModel
    )

    /// Default configuration for Translate: OpenAI / first curated model.
    static let defaultTranslate = ActionConfig(
        id: .translate,
        providerKind: defaultProviderKind,
        model: defaultModel
    )

    /// Default configuration for Prompt: OpenAI / first curated model.
    static let defaultPrompt = ActionConfig(
        id: .prompt,
        providerKind: defaultProviderKind,
        model: defaultModel
    )
}
