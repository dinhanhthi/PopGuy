// ActionEngine.swift
// PopGuy — ActionEngine
//
// Resolves which provider+model handles an action, fetches the API key from
// Keychain, builds the prompt, and returns the streamed result.
//
// ISOLATION CHOICE: ActionEngine is nonisolated (a plain struct).
// Rationale: the streaming work is provider-driven and must not hold the main
// thread. The configuration snapshot (@MainActor SettingsStore values) is
// captured BEFORE calling dispatch() — callers on the main actor extract the
// ActionConfig snapshot and key themselves and pass them in. This avoids any
// attempt to synchronously read @MainActor state from a nonisolated context.
//
// Provider injection: a `ProviderFactory` closure maps ProviderKind + API key
// to any Provider, making the engine fully testable without real adapters.
//
// Prompt strategy:
//   - Improve: AI system prompt; all providers receive the same prompt string.
//   - Shorten / Proofread: same pattern as Improve, each with its own
//     predefined prompt and optional user override.
//   - Translate: AI providers receive a translate system prompt WITH the target
//     language. Translation-native providers (DeepL, Google) read targetLanguage
//     from ProviderOptions and ignore the prompt. ActionEngine sets BOTH
//     unconditionally — no switch on ProviderKind needed here.
//   - Custom: the custom prompt is used as the system prompt.
//
// UNTRUSTED DATA: input text and streamed provider output are treated as plain
// text. ActionEngine does not interpret or execute them.

import Foundation

// MARK: - ProviderFactory

/// A closure that produces a Provider given a kind and an API key.
/// The key may be empty (e.g. for Ollama which doesn't require one).
typealias ProviderFactory = @Sendable (ProviderKind, String) -> any Provider

// MARK: - ActionEngine

/// Resolves and dispatches a text action to the configured provider.
///
/// nonisolated: streams execute on the provider's own async context, not the
/// main thread. Callers extract any @MainActor state (ActionConfig, key) and
/// pass it as Sendable values before calling dispatch().
nonisolated struct ActionEngine: Sendable {

    // MARK: - Dependencies

    private let providerFactory: ProviderFactory

    // MARK: - System prompts

    private static let improveSystemPrompt = """
        Revise the provided content to improve its overall writing quality.

        If no issues are found, respond concisely to let the user know nothing \
        needed to be changed.

        Additional guidelines:

        - Do NOT add new information or alter the meaning of the original \
        content.
        - Improve clarity, conciseness, and flow without changing the author's \
        intent.
        - Reorder or split sentences when it improves readability.
        - Reduce repetition and remove filler or redundant phrases.
        - Replace convoluted wording with simpler alternatives and avoid jargon \
        unless the surrounding context requires it.
        - Correct spelling, grammar, and punctuation.
        - Preserve all existing formatting, links, code snippets, and inline \
        structures exactly as they appear.

        Return only the corrected text — no commentary, no preamble.
        """

    private static let shortenSystemPrompt = """
        You are a writing assistant. Shorten the following text: make it more \
        concise and simpler without losing any of the main ideas, and preserve \
        the original meaning. Return only the shortened text — no commentary, \
        no preamble.
        """

    private static let proofreadSystemPrompt = """
        Make any necessary edits to fix spelling, grammar, punctuation, and \
        formatting mistakes ONLY to what the user has selected.

        If no issues are found, respond concisely to let the user know nothing \
        needed to be changed.

        Guidelines:

        - Correct typos, grammatical errors, and punctuation issues.
        - Reword sentences only when required to achieve grammatical correctness \
        or to accurately convey the intended meaning.
        - Maintain the author's tone and level of formality.
        - Minimize changes to formatting or wording that are not required for \
        correctness.
        - Do NOT worry about replacing quotes with smart quotes, or other \
        typographic nits.

        Return only the corrected text — no commentary, no preamble
        """

    /// Appended to the system prompt (or input) when the user enables
    /// "Preserve & render formatting" — asks the model to keep the input's
    /// Markdown formatting in its output.
    private static let preserveFormattingInstruction = "Preserve the Markdown formatting of the input in your output (keep bold, italic, strikethrough, inline code, and lists)."

    // MARK: - Init

    /// Create an ActionEngine with the given provider factory.
    ///
    /// - Parameter providerFactory: A closure that instantiates a Provider
    ///   given a `ProviderKind` and API key string. Inject a mock in tests.
    init(providerFactory: @escaping ProviderFactory) {
        self.providerFactory = providerFactory
    }

    // MARK: - Dispatch

    /// Execute an action and return the streamed result.
    ///
    /// - Parameters:
    ///   - action:  The action to execute.
    ///   - input:   The selected text (treated as untrusted plain text).
    ///   - config:  The provider+model configuration from SettingsStore.
    ///   - apiKey:  The API key from KeychainManager (empty string for keyless providers).
    ///   - baseURLOverride: Opaque base URL override forwarded into ProviderOptions.
    ///                      The caller resolves which URL to pass (Ollama endpoint,
    ///                      a fixed provider URL, or a user-supplied custom URL).
    ///                      ActionEngine does not interpret this value.
    ///   - executablePathOverride: Absolute path to a CLI binary forwarded into
    ///                      ProviderOptions. Resolved by the caller (ActionEngineHandler)
    ///                      per provider kind; nil for HTTP providers.
    ///   - preserveFormatting: When true, appends a Markdown-preservation directive
    ///                      to the system prompt (or to the user input when a custom
    ///                      prompt consumed the system role via `{{text}}`).
    /// - Returns: An `AsyncThrowingStream<String, Error>` of token deltas.
    func dispatch(
        action: Action,
        input: String,
        config: ActionConfig,
        apiKey: String,
        baseURLOverride: String? = nil,
        executablePathOverride: String? = nil,
        preserveFormatting: Bool = false
    ) async throws -> AsyncThrowingStream<String, Error> {

        // Guard: OpenAI-wire providers that require an explicit endpoint must have
        // one configured. If baseURLOverride is nil or blank for these kinds, the
        // OpenAIProvider would silently fall through to api.openai.com — leaking
        // the user's key to the wrong service. Throw before constructing the provider.
        switch config.providerKind {
        case .glm, .openRouter, .custom:
            let trimmed = baseURLOverride?.trimmingCharacters(in: .whitespaces) ?? ""
            if trimmed.isEmpty {
                throw ProviderError.transport("No endpoint configured for \(config.providerKind.displayName). Set the base URL in Settings.")
            }
            if URL(string: trimmed) == nil {
                throw ProviderError.transport("Invalid endpoint URL for \(config.providerKind.displayName): \"\(trimmed)\". Check the base URL in Settings.")
            }
        default:
            break
        }

        let provider = providerFactory(config.providerKind, apiKey)

        let (rawSystemPrompt, options) = Self.buildPromptAndOptions(
            action: action,
            baseURLOverride: baseURLOverride,
            executablePath: executablePathOverride
        )

        // Apply {{text}} placeholder substitution. When the prompt contains the
        // token, the substituted string becomes the user message (input) and
        // systemPrompt is set to nil — the custom prompt is a complete user request.
        // When the token is absent this is a no-op (identity transform).
        let (systemPrompt, effectiveInput) = Self.applyTextPlaceholder(
            prompt: rawSystemPrompt,
            input: input
        )

        // When preserveFormatting is enabled, append a Markdown-preservation
        // directive. If a system prompt exists it goes there; otherwise the custom
        // prompt consumed the system role via {{text}} substitution, so the
        // directive is appended to the user input instead.
        var finalSystemPrompt = systemPrompt
        var finalInput = effectiveInput
        if preserveFormatting {
            if let systemPrompt = finalSystemPrompt {
                finalSystemPrompt = systemPrompt + "\n\n" + Self.preserveFormattingInstruction
            } else {
                finalInput = finalInput + "\n\n" + Self.preserveFormattingInstruction
            }
        }

        return try await provider.stream(
            systemPrompt: finalSystemPrompt,
            input: finalInput,
            model: config.model,
            options: options
        )
    }

    // MARK: - Prompt + options builder

    /// Build the system prompt and ProviderOptions for a given Action.
    ///
    /// AI providers read the systemPrompt to know what to do.
    /// Translation-native providers (DeepL, Google) read options.targetLanguage
    /// and ignore the system prompt. Both are set unconditionally — no branching
    /// on ProviderKind here (ActionEngine must not know provider specifics).
    private static func buildPromptAndOptions(
        action: Action,
        baseURLOverride: String?,
        executablePath: String? = nil
    ) -> (systemPrompt: String?, options: ProviderOptions) {
        // Resolve the base URL string to a URL. nil/empty legitimately means "no override".
        // A non-nil/non-empty string that fails URL parsing is a misconfiguration — log it
        // so it is not silently swallowed, but do not crash: the adapter will fall back to
        // its default endpoint (which is the lesser evil vs. a crash).
        let resolvedBaseURL: URL?
        if let override = baseURLOverride, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            if let url = URL(string: override) {
                resolvedBaseURL = url
            } else {
                // Non-empty override that is not a valid URL — log and proceed without override.
                // In practice this should not be reached because the dispatch guard above rejects
                // empty/missing endpoints for requires-URL kinds before we get here.
                #if DEBUG
                print("[ActionEngine] Warning: baseURLOverride \"\(override)\" is not a valid URL — ignoring override")
                #endif
                resolvedBaseURL = nil
            }
        } else {
            resolvedBaseURL = nil
        }
        switch action {
        case .improve(let customPrompt, let tone):
            // Use the custom prompt when non-nil and non-empty; otherwise fall back
            // to the predefined writing-assistant prompt. The tone fragment (if any)
            // is appended to whichever prompt is used; `.neutral` is a no-op.
            let trimmed = customPrompt?.trimmingCharacters(in: .whitespaces) ?? ""
            let basePrompt = trimmed.isEmpty ? improveSystemPrompt : trimmed
            let prompt = Self.appendingTone(tone, to: basePrompt)
            return (
                systemPrompt: prompt,
                options: ProviderOptions(baseURL: resolvedBaseURL, executablePath: executablePath)
            )

        case .shorten(let customPrompt, let tone):
            // Same custom-prompt fallback and tone semantics as Improve.
            let trimmed = customPrompt?.trimmingCharacters(in: .whitespaces) ?? ""
            let basePrompt = trimmed.isEmpty ? shortenSystemPrompt : trimmed
            let prompt = Self.appendingTone(tone, to: basePrompt)
            return (
                systemPrompt: prompt,
                options: ProviderOptions(baseURL: resolvedBaseURL, executablePath: executablePath)
            )

        case .proofread(let customPrompt):
            // Same custom-prompt fallback semantics as Improve.
            let trimmed = customPrompt?.trimmingCharacters(in: .whitespaces) ?? ""
            let prompt = trimmed.isEmpty ? proofreadSystemPrompt : trimmed
            return (
                systemPrompt: prompt,
                options: ProviderOptions(baseURL: resolvedBaseURL, executablePath: executablePath)
            )

        case .translate(let targetLanguage, let customPrompt, let tone):
            // AI providers: system prompt tells them what language to translate to.
            // Translation-native providers (DeepL, Google) ignore this prompt and
            // read options.targetLanguage, so their language is hard-enforced.
            //
            // Prompt ordering is deliberate. The optional custom prompt is framed
            // as SUBORDINATE guidance and placed FIRST; the authoritative target
            // language and tone instructions follow it so they carry more weight.
            // This reduces (but cannot fully guarantee against) the custom prompt
            // overriding the configured language/tone for AI providers.
            let custom = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var parts: [String] = []
            if !custom.isEmpty {
                parts.append("Apply these additional instructions where they do not conflict with the translation task: \(custom)")
            }
            parts.append("Translate the following text to \(targetLanguage).")
            if let fragment = tone.promptFragment(targetLanguage: targetLanguage) { parts.append(fragment) }
            parts.append("Return only the translated text — no commentary, no preamble.")
            let translatePrompt = parts.joined(separator: " ")
            return (
                systemPrompt: translatePrompt,
                options: ProviderOptions(
                    targetLanguage: targetLanguage,
                    baseURL: resolvedBaseURL,
                    executablePath: executablePath,
                    // DeepL/Google read this; AI providers ignore it (they get the
                    // tone via the prompt fragment above).
                    formality: tone.deepLFormality
                )
            )

        case .custom(let prompt):
            // Custom prompt as system prompt; executablePath forwarded for CLI providers.
            return (
                systemPrompt: prompt,
                options: ProviderOptions(baseURL: resolvedBaseURL, executablePath: executablePath)
            )
        }
    }

    // MARK: - Tone fragment

    /// Append the tone's instruction fragment to a prompt, separated by a blank
    /// line. Returns the prompt unchanged for `.neutral` (no fragment). Used by
    /// Improve and Shorten, which have no target language, so the French-specific
    /// branch never fires here.
    private static func appendingTone(_ tone: TranslateTone, to prompt: String) -> String {
        guard let fragment = tone.promptFragment(targetLanguage: nil) else { return prompt }
        return prompt + "\n\n" + fragment
    }

    // MARK: - {{text}} placeholder substitution

    /// Substitute `{{text}}` in a prompt with the selected input text.
    ///
    /// When `prompt` contains the `{{text}}` token, the token is replaced with
    /// `input` and the result becomes the USER message (input); systemPrompt is
    /// returned as nil. Rationale: a prompt containing `{{text}}` is a complete
    /// user-authored request ("Summarize: {{text}}"), so the substituted string
    /// belongs in the user turn — not the system role. This avoids sending an
    /// empty user message (which Anthropic rejects with HTTP 400) and deliberately
    /// places untrusted selection text in the lower-authority user role.
    ///
    /// When the token is absent this is an identity transform: prompt and input
    /// are returned unchanged.
    ///
    /// UNTRUSTED DATA: `input` is plain text from the user's selection. It is
    /// only substituted as literal text — never interpreted or executed.
    private static func applyTextPlaceholder(
        prompt: String?,
        input: String
    ) -> (systemPrompt: String?, input: String) {
        guard let prompt, prompt.contains("{{text}}") else {
            return (prompt, input)
        }
        let substituted = prompt.replacingOccurrences(of: "{{text}}", with: input)
        return (nil, substituted)
    }
}

// MARK: - Default factory

extension ActionEngine {
    /// A provider factory that instantiates real adapters for use in production.
    /// Ollama requires a baseURL from SettingsStore passed via ProviderOptions,
    /// not from this factory — the factory only creates the adapter instance.
    static func makeDefaultFactory() -> ProviderFactory {
        return { kind, apiKey in
            switch kind {
            case .openAI:
                return OpenAIProvider(apiKey: apiKey)
            case .anthropic:
                return AnthropicProvider(apiKey: apiKey)
            case .ollama:
                // Ollama doesn't use an API key; base URL comes from ProviderOptions.
                // The apiKey parameter is ignored for local Ollama deployments.
                return OllamaProvider()
            case .deepL:
                return DeepLProvider(apiKey: apiKey)
            case .googleTranslate:
                return GoogleTranslateProvider(apiKey: apiKey)
            case .gemini:
                return GeminiProvider(apiKey: apiKey)
            case .glm, .openRouter, .custom:
                // These providers speak the OpenAI wire protocol (chat/completions SSE).
                // OpenAIProvider is reused intentionally; the correct base URL is
                // resolved by ActionEngineHandler.resolveBaseURL(_:) and passed via
                // ProviderOptions.baseURL — it is never api.openai.com for these kinds.
                // Pass the kind so the adapter can emit the provider-specific
                // "disable thinking" field (GLM, OpenRouter).
                return OpenAIProvider(apiKey: apiKey, providerKind: kind)
            case .claudeCLI:
                // Keyless — uses macOS Keychain OAuth token managed by the claude CLI.
                return ClaudeCLIProvider()
            case .codexCLI:
                // Keyless — uses ~/.codex/auth.json managed by the codex CLI.
                return CodexCLIProvider()
            case .geminiCLI:
                // Keyless — uses ~/.gemini/oauth_creds.json managed by the gemini CLI.
                return GeminiCLIProvider()
            }
        }
    }
}
