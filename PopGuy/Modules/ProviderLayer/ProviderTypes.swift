// ProviderTypes.swift
// PopGuy — ProviderLayer
//
// Shared request/response types, enum of provider kinds, and error type
// used across the ProviderLayer. All types are Sendable.

import Foundation

// MARK: - ProviderKind

/// Identifies which concrete provider implementation handles an action.
/// Stored in SettingsStore per-action config; used to instantiate the correct adapter.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
public nonisolated enum ProviderKind: String, Sendable, CaseIterable, Codable {
    case openAI          = "openai"
    case anthropic       = "anthropic"
    case ollama          = "ollama"
    case deepL           = "deepl"
    case googleTranslate = "google_translate"
    case gemini          = "gemini"
    case glm             = "glm"
    case openRouter      = "openrouter"
    case custom          = "custom"
    case claudeCLI       = "claude_cli"
    case codexCLI        = "codex_cli"
    case geminiCLI       = "gemini_cli"
    case mlxLocal        = "mlx_local"
}

// MARK: - ProviderKind display name

extension ProviderKind {
    /// Human-readable label for use in Settings pickers.
    public nonisolated var displayName: String {
        switch self {
        case .openAI:          return "OpenAI"
        case .anthropic:       return "Anthropic (Claude)"
        case .ollama:          return "Ollama / LM Studio"
        case .deepL:           return "DeepL"
        case .googleTranslate: return "Google Translate"
        case .gemini:          return "Google Gemini"
        case .glm:             return "GLM / z.ai"
        case .openRouter:      return "OpenRouter"
        case .custom:          return "Custom (OpenAI-compatible)"
        case .claudeCLI:       return "Claude CLI (subscription)"
        case .codexCLI:        return "Codex CLI (subscription)"
        case .geminiCLI:       return "Gemini CLI (subscription)"
        case .mlxLocal:        return "Local (MLX)"
        }
    }

    /// Asset-catalog name for the provider's real brand logo, shown before the
    /// provider name in Settings. Drop the official logo art into an image set
    /// of this name (e.g. "ProviderLogo-openai") to display the real logo;
    /// when the asset is absent, the UI falls back to `iconSystemName`.
    public nonisolated var logoImageName: String {
        "ProviderLogo-\(rawValue)"
    }

    /// SF Symbol fallback used when the brand logo asset (`logoImageName`) is not
    /// bundled. Generic glyphs: AI text providers vs. local runtime vs. translation.
    public nonisolated var iconSystemName: String {
        switch self {
        case .openAI:          return "brain"
        case .anthropic:       return "sparkles"
        case .ollama:          return "desktopcomputer"
        case .deepL:           return "character.bubble"
        case .googleTranslate: return "globe"
        case .gemini:          return "star"
        case .glm:             return "cpu"
        case .openRouter:      return "arrow.triangle.branch"
        case .custom:          return "server.rack"
        case .claudeCLI:       return "sparkles"
        case .codexCLI:        return "chevron.left.forwardslash.chevron.right"
        case .geminiCLI:       return "star"
        case .mlxLocal:        return "memorychip"
        }
    }

    /// Official web page where the user can sign in and obtain an API key for
    /// this provider. Shown as an external-link button beside the provider name
    /// in Settings. Returns `nil` for providers that need no key from a hosted
    /// console — Ollama / LM Studio (local) and Custom (user-supplied endpoint).
    ///
    /// For GLM the link points at the z.ai international console to match the
    /// configured `defaultBaseURL` (api.z.ai).
    public nonisolated var apiKeyURL: URL? {
        switch self {
        case .openAI:          return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic:       return URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini:          return URL(string: "https://aistudio.google.com/app/apikey")
        case .glm:             return URL(string: "https://z.ai/manage-apikey/apikey-list")
        case .openRouter:      return URL(string: "https://openrouter.ai/keys")
        case .deepL:           return URL(string: "https://www.deepl.com/your-account/keys")
        case .googleTranslate: return URL(string: "https://console.cloud.google.com/apis/credentials")
        case .ollama, .custom: return nil
        case .claudeCLI, .codexCLI, .geminiCLI: return nil
        case .mlxLocal: return nil
        }
    }

    /// Whether this provider takes a model identifier. Translation-native
    /// providers (DeepL, Google) translate automatically and have no model, so
    /// the Settings UI hides the Model field for them.
    public nonisolated var usesModel: Bool {
        switch self {
        case .openAI, .anthropic, .ollama,
             .gemini, .glm, .openRouter, .custom,
             .claudeCLI, .codexCLI, .geminiCLI,
             .mlxLocal:                           return true
        case .deepL, .googleTranslate:            return false
        }
    }

    /// Guidance shown in the Model field's (i) tooltip, telling the user which
    /// model identifier this provider expects and where to find valid values.
    public nonisolated var modelHint: String {
        switch self {
        case .openAI:
            return "Enter an OpenAI model id, e.g. \"gpt-5.5\" or \"gpt-5.4-mini\". Find available models in your OpenAI account."
        case .anthropic:
            return "Enter an Anthropic model id, e.g. \"claude-sonnet-4-6\" or \"claude-opus-4-8\". See Anthropic's model list for valid identifiers."
        case .ollama:
            return "Enter the name of a model installed in Ollama / LM Studio, e.g. \"llama3.1\" or \"qwen2.5\". Run `ollama list` to see installed models."
        case .deepL:
            return "DeepL handles translation automatically and does not use a model identifier — this field can be left empty."
        case .googleTranslate:
            return "Google Translate handles translation automatically and does not use a model identifier — this field can be left empty."
        case .gemini:
            return "Enter a Gemini model id, e.g. \"gemini-3.1-pro\" or \"gemini-3.5-flash\". See Google AI for Developers for the current model list."
        case .glm:
            return "Enter a GLM model id, e.g. \"glm-4.7\" or \"glm-4.7-flash\". See the z.ai / BigModel documentation for available models."
        case .openRouter:
            return "Enter an OpenRouter model id in provider/model format, e.g. \"openai/gpt-5.5\" or \"google/gemini-3.1-pro\". Browse models at openrouter.ai."
        case .custom:
            return "Enter the model identifier expected by your custom OpenAI-compatible endpoint (e.g. the model name your local server advertises)."
        case .claudeCLI:
            return "Optional. A model alias (opus/sonnet/haiku) or full id; empty uses the CLI default."
        case .codexCLI:
            return "Optional. A model id (e.g. gpt-5.5); empty uses the CLI default."
        case .geminiCLI:
            return "Optional. A model id (e.g. gemini-3-pro); empty uses the CLI default."
        case .mlxLocal:
            return "Select an on-device model. Download models in Settings → Local (MLX)."
        }
    }
}

// MARK: - ProviderKind default base URL

extension ProviderKind {
    /// Fixed base URL for OpenAI-wire-compatible providers that have a known, non-OpenAI endpoint.
    /// Used by ProviderKeyValidator for GLM and OpenRouter key validation (GET /models + Bearer).
    ///
    /// Returns `nil` for providers that either have a hard-coded URL inside their own adapter
    /// (OpenAI, Anthropic, Gemini) or require the user to supply a URL at runtime (Ollama, Custom).
    /// Translation providers also return `nil` — they do not use an OpenAI-compatible API.
    ///
    /// NOTE — `.gemini` returns `nil` here: GeminiProvider targets the native Gemini REST API at
    /// generativelanguage.googleapis.com/v1beta directly and must never be redirected through the
    /// OpenAI-compatibility shim. Both ProviderKeyValidator and ProviderModelValidator route Gemini
    /// to GeminiProvider.makeValidationRequest, so this field is never consulted for Gemini.
    public nonisolated var defaultBaseURL: URL? {
        switch self {
        case .glm:
            // z.ai international API base (OpenAI-wire compatible: POST /chat/completions,
            // GET /models, Authorization: Bearer). Matches the z.ai API-key console
            // linked from Settings. See https://docs.z.ai/api-reference/introduction
            return URL(string: "https://api.z.ai/api/paas/v4/")
        case .openRouter:
            return URL(string: "https://openrouter.ai/api/v1")
        case .openAI, .anthropic, .gemini, .ollama, .custom,
             .deepL, .googleTranslate,
             .claudeCLI, .codexCLI, .geminiCLI,
             .mlxLocal:
            return nil
        }
    }
}

// MARK: - ProviderKind curated models

extension ProviderKind {
    /// A small, curated list of well-known model identifiers shown in the Settings
    /// model-picker dropdown.  Users may still type any valid id into the field;
    /// this list is a convenience starting point, not an exhaustive catalogue.
    /// Returns an empty array for providers where no curated list is applicable
    /// (local/custom runtimes and translation-only providers).
    public nonisolated var curatedModels: [String] {
        switch self {
        case .openAI:
            return ["gpt-5.5", "gpt-5.4-mini", "gpt-5.4-nano"]
        case .anthropic:
            return ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]
        case .gemini:
            return ["gemini-3.1-pro", "gemini-3.5-flash", "gemini-3-flash", "gemini-3.1-flash-lite"]
        case .glm:
            return ["glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7", "glm-4.7-flash", "glm-4.5-air"]
        case .openRouter:
            return ["openai/gpt-5.5", "anthropic/claude-opus-4-8", "google/gemini-3.1-pro", "z-ai/glm-5.1"]
        case .ollama, .custom,
             .deepL, .googleTranslate:
            return []
        case .mlxLocal:
            return LocalModelCatalog.all.map(\.id)
        case .claudeCLI:
            return ["opus", "sonnet", "haiku"]
        case .codexCLI:
            return ["gpt-5.5"]
        case .geminiCLI:
            return ["gemini-3-pro", "gemini-3-flash"]
        }
    }
}

// MARK: - ProviderKind CLI helpers

extension ProviderKind {
    /// Whether this provider runs a local CLI binary using the user's subscription
    /// or OAuth login rather than an API key. Used by the UI to show latency warnings
    /// and by validators / handlers to branch on authentication strategy.
    ///
    /// Exhaustive switch (no `default`) so a future ProviderKind case fails to compile
    /// rather than silently returning false.
    public nonisolated var usesLocalCLI: Bool {
        switch self {
        case .claudeCLI, .codexCLI, .geminiCLI:
            return true
        case .openAI, .anthropic, .ollama, .deepL, .googleTranslate,
             .gemini, .glm, .openRouter, .custom, .mlxLocal:
            return false
        }
    }

    /// A short warning shown in the UI when the provider runs via a local CLI
    /// subprocess (typically 2–15 s per call). `nil` for API-backed providers.
    public nonisolated var latencyWarning: String? {
        guard usesLocalCLI else { return nil }
        return "This provider runs a local CLI using your subscription — slower than the API providers (a few seconds, up to ~15s)."
    }
}

// MARK: - ProviderOptions

/// Per-call options forwarded from ActionEngine to a Provider adapter.
/// Adapters read only the fields relevant to their API.
///
/// Immutable value type — all fields are set at construction time and
/// read by adapters without mutation.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
public nonisolated struct ProviderOptions: Sendable {

    /// Target language for translation providers (e.g. "EN", "VI", "es").
    /// DeepL expects uppercase codes; Google Translate accepts lowercase BCP-47.
    public let targetLanguage: String?

    /// Source language hint for translation (optional; providers auto-detect if nil).
    public let sourceLanguage: String?

    /// Base URL override consumed by adapters that support a configurable endpoint.
    /// Currently honoured by:
    ///   - OllamaProvider — local/LM Studio deployments
    ///   - OpenAIProvider when used for OpenAI-wire-compatible providers (GLM, OpenRouter, Custom)
    ///   - GeminiProvider — falls back to its native base when nil
    /// All other adapters (Anthropic, DeepL, Google Translate) ignore this field.
    /// Default: nil — each adapter uses its own hard-coded base URL.
    public let baseURL: URL?

    /// Maximum tokens for completion (used by AnthropicProvider, which requires
    /// `max_tokens` in the request body). Other adapters may ignore this.
    public let maxTokens: Int

    /// Absolute path to a local CLI binary, consumed by CLI-based providers
    /// (Claude/Codex/Gemini CLI). Ignored by HTTP providers.
    public let executablePath: String?

    /// DeepL `formality` register hint ("prefer_more" / "prefer_less"), derived
    /// from the action's tone. Honoured only by DeepLProvider; all other adapters
    /// ignore it. Default: nil — no formality preference.
    public let formality: String?

    public nonisolated init(
        targetLanguage: String? = nil,
        sourceLanguage: String? = nil,
        baseURL: URL? = nil,
        maxTokens: Int = 4096,
        executablePath: String? = nil,
        formality: String? = nil
    ) {
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
        self.baseURL = baseURL
        self.maxTokens = maxTokens
        self.executablePath = executablePath
        self.formality = formality
    }
}

// MARK: - ProviderError

/// Errors thrown by Provider adapters.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
public nonisolated enum ProviderError: Error, Sendable, LocalizedError {

    /// A network/transport failure (e.g. unreachable host, timeout).
    case transport(String)

    /// The provider returned a non-2xx HTTP status code with an optional body.
    case httpError(statusCode: Int, body: String?)

    /// JSON decoding of the provider response failed.
    case decodingFailed(String)

    /// A required option was missing (e.g. no targetLanguage for a translation call).
    case missingOption(String)

    /// The provider returned an empty or unexpected response.
    case unexpectedResponse(String)

    /// The provider emitted an in-stream error event (e.g. Anthropic `event: error`
    /// after a 200 response). First string is the error type/kind; second is the
    /// human-readable message from the API.
    case apiError(String, String)

    public var errorDescription: String? {
        switch self {
        case .transport(let msg):
            return "Transport error: \(msg)"
        case .httpError(let code, let body):
            let snippet = body.map { String($0.prefix(200)) } ?? "(no body)"
            return "HTTP \(code): \(snippet)"
        case .decodingFailed(let msg):
            return "Decoding failed: \(msg)"
        case .missingOption(let msg):
            return "Missing option: \(msg)"
        case .unexpectedResponse(let msg):
            return "Unexpected response: \(msg)"
        case .apiError(let kind, let msg):
            return "API error (\(kind)): \(msg)"
        }
    }
}
