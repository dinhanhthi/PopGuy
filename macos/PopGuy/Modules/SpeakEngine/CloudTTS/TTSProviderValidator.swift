// TTSProviderValidator.swift
// PopGuy — SpeakEngine/CloudTTS
//
// Verifies a TTS API key against its provider before it is saved to the Keychain.
// Each provider exposes a lightweight `makeValidationRequest` that hits an
// auth-only endpoint — no audio is synthesised.
//
// Outcome contract:
//   • returns normally  → the key authenticates (HTTP 2xx)
//   • throws ProviderError.httpError(401/403) → the key is invalid
//   • throws ProviderError.httpError(other)   → reachable but not verifiable
//   • throws ProviderError.transport          → network failure (not "invalid")
// Callers distinguish these to show the right message (invalid vs. offline).

import Foundation

/// Stateless validator that checks a TTS API key authenticates with its provider.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target)
// so the network round-trip runs off the main thread. All parameters are Sendable.
nonisolated enum TTSProviderValidator {

    /// Verify that `apiKey` authenticates with `kind`'s TTS API.
    ///
    /// - Parameters:
    ///   - kind: The TTS provider to validate against.
    ///   - apiKey: The API key to test. Leading/trailing whitespace is trimmed
    ///     before the check; a blank key throws `TTSProviderError.missingAPIKey`
    ///     without making any network call.
    ///   - config: Per-provider configuration (region, model, etc.).
    ///   - session: A `URLSession` to use for the request. Defaults to an
    ///     ephemeral session (no disk caching, no credential storage).
    /// - Throws: `TTSProviderError.missingAPIKey` when the trimmed key is empty.
    ///           `TTSProviderError.missingRegion` when the provider requires a region but none is configured.
    ///           `ProviderError` on any non-2xx response or transport failure.
    static func validate(
        kind: TTSProviderKind,
        apiKey: String,
        config: TTSProviderConfig = .default,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw TTSProviderError.missingAPIKey }

        let request: URLRequest
        switch kind {
        case .openAITTS:
            request = try OpenAITTSProvider.makeValidationRequest(apiKey: trimmed, config: config)
        case .googleCloudTTS:
            request = try GoogleCloudTTSProvider.makeValidationRequest(apiKey: trimmed, config: config)
        case .azureTTS:
            request = try AzureTTSProvider.makeValidationRequest(apiKey: trimmed, config: config)
        }

        let client = HTTPClient(session: session)
        // rawData throws ProviderError.httpError on non-2xx and .transport on
        // a non-HTTP response; a 2xx return value means the key authenticated.
        _ = try await client.rawData(for: request)
    }
}
