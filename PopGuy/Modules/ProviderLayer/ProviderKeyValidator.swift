// ProviderKeyValidator.swift
// PopGuy — ProviderLayer
//
// Verifies an API key against its provider before it is saved to the Keychain.
// Each provider exposes a lightweight `makeValidationRequest` that hits an
// auth-only endpoint (model list / usage / language list) — no generation or
// translation tokens are consumed.
//
// Outcome contract:
//   • returns normally  → the key authenticates (HTTP 2xx)
//   • throws ProviderError.httpError(401/403) → the key is invalid
//   • throws ProviderError.httpError(other)   → reachable but not verifiable
//   • throws ProviderError.transport          → network failure (not "invalid")
// Callers distinguish these to show the right message (invalid vs. offline).

import Foundation

/// Stateless validator that checks an API key authenticates with its provider.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target)
// so the network round-trip runs off the main thread. All parameters are Sendable.
nonisolated enum ProviderKeyValidator {

    /// Verify that `apiKey` authenticates with `kind`'s API.
    ///
    /// - Parameters:
    ///   - kind: The provider to validate against.
    ///   - apiKey: The API key to test.
    ///   - baseURL: An optional endpoint override. Used for `.custom` (which has no
    ///     fixed host) so validation can target the user-configured endpoint.
    ///     Ignored for `.gemini` (which always uses its native REST API regardless).
    ///     For `.glm`/`.openRouter` the provider's `defaultBaseURL` takes precedence
    ///     unless overridden by a non-nil value here.
    /// - Throws: `ProviderError` on any non-2xx response or transport failure.
    ///           Ollama needs no key and validates trivially.
    static func validate(
        kind: ProviderKind,
        apiKey: String,
        baseURL: URL? = nil,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async throws {
        let request: URLRequest
        switch kind {
        case .openAI:
            request = try OpenAIProvider.makeValidationRequest(apiKey: apiKey)
        case .anthropic:
            request = try AnthropicProvider.makeValidationRequest(apiKey: apiKey)
        case .deepL:
            request = try DeepLProvider.makeValidationRequest(apiKey: apiKey)
        case .googleTranslate:
            request = try GoogleTranslateProvider.makeValidationRequest(apiKey: apiKey)
        case .ollama, .mlxLocal:
            // Keyless local providers — nothing to validate.
            return
        case .claudeCLI, .codexCLI, .geminiCLI:
            // CLI providers authenticate via subscription/OAuth (macOS Keychain or
            // dotfile credentials). No API key to validate.
            return
        case .custom:
            // Custom endpoints have no fixed URL; can only validate when the caller
            // supplies the user-configured endpoint. The wire format is OpenAI-compatible
            // (GET /models + Authorization: Bearer).
            guard let endpoint = baseURL else { return }
            request = try OpenAIProvider.makeValidationRequest(apiKey: apiKey, baseURL: endpoint)
        case .gemini:
            // Gemini uses x-goog-api-key, not Bearer, and its own native base URL.
            // Delegate to GeminiProvider which knows the correct endpoint and auth.
            // A caller-supplied baseURL is intentionally ignored here.
            request = try GeminiProvider.makeValidationRequest(apiKey: apiKey)
        case .glm, .openRouter:
            // OpenAI-wire-compatible providers: validate by hitting GET /models with
            // Bearer auth. Prefer an explicit caller-supplied baseURL; fall back to
            // the provider's known fixed endpoint.
            guard let endpoint = baseURL ?? kind.defaultBaseURL else { return }
            request = try OpenAIProvider.makeValidationRequest(apiKey: apiKey, baseURL: endpoint)
        }

        let client = HTTPClient(session: session)
        // rawData throws ProviderError.httpError on non-2xx and .transport on
        // a non-HTTP response; a 2xx return value means the key authenticated.
        _ = try await client.rawData(for: request)
    }
}
