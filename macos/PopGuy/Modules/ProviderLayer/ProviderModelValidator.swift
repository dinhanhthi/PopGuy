// ProviderModelValidator.swift
// PopGuy — ProviderLayer
//
// Verifies that a model identifier is valid for a provider+key pair by performing
// a minimal 1-token streaming call and consuming the first yielded token (or a
// clean completion with zero tokens). Any thrown ProviderError propagates to the
// caller so it can render the model id as invalid.
//
// Outcome contract:
//   • returns normally              → model id is accepted by the provider
//   • throws ProviderError.httpError(404/400) → model not found / bad request
//   • throws ProviderError.httpError(401/403) → key authentication failure
//   • throws ProviderError.transport          → network failure (inconclusive)
//
// Scope: only providers where usesModel == true are relevant. For translation
// providers (DeepL, Google Translate) this returns early without any network call.
//
// Provider factory injection: an optional providerFactory parameter lets tests
// inject a stub provider without real network calls — mirroring how ActionEngine
// accepts an injected factory. The default is ActionEngine.makeDefaultFactory(),
// reusing the same production mapping. Note: makeDefaultFactory() does not
// thread a URLSession through — the session parameter is only used for Gemini
// (which accepts a session directly) and the OpenAI-wire adapters used for
// GLM/OpenRouter/Custom, which must be constructed separately here. For all
// other paths the factory is used as-is.

import Foundation

/// Stateless validator that checks a model id is accepted by a provider.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target)
// so the streaming round-trip runs off the main thread. All parameters are Sendable.
nonisolated enum ProviderModelValidator {

    /// Verify that `model` is accepted by the given `kind`/`apiKey` pair.
    ///
    /// Performs a minimal 1-token streaming call and reads at most one token.
    /// The stream is discarded (cancelled) after the first token or a clean finish.
    ///
    /// - Parameters:
    ///   - kind:            The provider to validate against.
    ///   - apiKey:          The API key (empty string for Ollama).
    ///   - baseURL:         Endpoint override. Required for `.custom`; used for
    ///                      `.glm`/`.openRouter` (fallback to provider's default).
    ///                      Ignored for `.gemini` — GeminiProvider always uses its
    ///                      native base URL regardless of this value.
    ///   - model:           The model identifier string to test.
    ///   - providerFactory: Optional factory override for testing. Defaults to the
    ///                      same production mapping as ActionEngine.makeDefaultFactory().
    ///   - session:         URLSession used when constructing adapters that accept one
    ///                      (Gemini, OpenAI-wire adapters for GLM/OpenRouter/Custom).
    ///                      The default factory does not thread session through for
    ///                      OpenAI/Anthropic/Ollama, so those use their own ephemeral
    ///                      sessions unless an injected factory is provided.
    /// - Throws: `ProviderError` on any API-level or transport failure.
    static func validate(
        kind: ProviderKind,
        apiKey: String,
        baseURL: URL? = nil,
        model: String,
        providerFactory: ProviderFactory? = nil,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async throws {
        // Translation-native providers have no model to validate.
        guard kind.usesModel else { return }

        // Resolve the base URL BEFORE constructing the provider so that early-return
        // conditions (custom with no endpoint) fire before the factory is ever called.
        //
        // - Gemini: always nil — GeminiProvider resolves its own native base URL
        //   internally; a caller-supplied baseURL is intentionally ignored.
        // - GLM / OpenRouter: use caller-supplied URL or the provider's known default.
        // - Custom: use caller-supplied URL; if absent, no endpoint is known — return
        //   early (cannot validate without an endpoint, same logic as ProviderKeyValidator).
        // - All others: nil (adapter uses its own hard-coded base URL).
        let resolvedBaseURL: URL?
        switch kind {
        case .gemini:
            resolvedBaseURL = nil
        case .glm, .openRouter:
            resolvedBaseURL = baseURL ?? kind.defaultBaseURL
        case .custom:
            guard let endpoint = baseURL else { return }
            resolvedBaseURL = endpoint
        case .claudeCLI, .codexCLI, .geminiCLI:
            // CLI providers authenticate via subscription; spawning a 10-30s process
            // to validate a freeform model name is not acceptable. Skip validation.
            return
        case .mlxLocal:
            // On-device models are validated by checking the local cache, not by
            // sending a live request. Skip network validation.
            return
        case .openAI, .anthropic, .ollama,
             .deepL, .googleTranslate:
            resolvedBaseURL = nil
        }

        // Construct the provider after all early-return guards have passed.
        // When an injected factory is provided (tests), use it directly.
        // Otherwise build the production adapter, threading the session through where
        // the adapter's initializer accepts one.
        let provider: any Provider
        if let factory = providerFactory {
            provider = factory(kind, apiKey)
        } else {
            provider = Self.makeAdapter(kind: kind, apiKey: apiKey, session: session)
        }

        let options = ProviderOptions(baseURL: resolvedBaseURL, maxTokens: 1)
        let stream = try await provider.stream(
            systemPrompt: nil,
            input: "Hi",
            model: model,
            options: options
        )

        // Consume the first token and stop — the stream may yield zero tokens
        // (e.g. a model that returns an empty completion) which is still a success.
        for try await _ in stream {
            break
        }
    }

    // MARK: - Adapter factory (production path, no injected factory)

    /// Build the production adapter for `kind`, threading `session` through where
    /// the adapter accepts one. For Gemini and OpenAI-wire adapters (which power
    /// GLM/OpenRouter/Custom) the session is injected so tests can stub network.
    ///
    /// NOTE: This mapping must stay in sync with ActionEngine.makeDefaultFactory().
    /// If a new ProviderKind is added, update both switch statements.
    private static func makeAdapter(
        kind: ProviderKind,
        apiKey: String,
        session: URLSession
    ) -> any Provider {
        switch kind {
        case .openAI:
            return OpenAIProvider(apiKey: apiKey)
        case .anthropic:
            return AnthropicProvider(apiKey: apiKey)
        case .ollama:
            return OllamaProvider()
        case .deepL:
            return DeepLProvider(apiKey: apiKey)
        case .googleTranslate:
            return GoogleTranslateProvider(apiKey: apiKey)
        case .gemini:
            // Inject session so callers can stub network in tests.
            return GeminiProvider(apiKey: apiKey, session: session)
        case .glm, .openRouter, .custom:
            // OpenAI-wire-compatible; inject session for test stubbing.
            return OpenAIProvider(apiKey: apiKey, session: session)
        case .claudeCLI:
            // Unreachable: CLI kinds (.claudeCLI, .codexCLI, .geminiCLI) early-return
            // in validate() before makeAdapter is ever called.
            return ClaudeCLIProvider()
        case .codexCLI:
            // Unreachable: see .claudeCLI comment above.
            return CodexCLIProvider()
        case .geminiCLI:
            // Unreachable: see .claudeCLI comment above.
            return GeminiCLIProvider()
        case .mlxLocal:
            // Unreachable: .mlxLocal early-returns in validate() above.
            return MLXLocalProvider()
        }
    }
}
