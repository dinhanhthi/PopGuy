// MLXLocalProvider.swift
// PopGuy — ProviderLayer/Adapters
//
// Provider adapter for the on-device MLX engine (PopGuyMLXHelper subprocess).
//
// No API key, no base URL. All inference is local via MLXHelperManager.
// Temperature defaults to 0.7 (sanitized); maxTokens comes from ProviderOptions.
//
// Family is intentionally not looked up here: HelperRequest.generate must stay
// byte-identical with the helper-side copy of LocalHelperProtocol.swift (no family
// field on the wire), so there is no way to forward a resolved family. The helper
// resolves family itself via its own isQwenFamily() heuristic. Catalog-family
// consolidation is deferred to a future phase.

import Foundation

// MARK: - MLXLocalProvider

/// Streams tokens from the on-device MLX helper subprocess.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct MLXLocalProvider: Provider {

    // MARK: - Provider

    func stream(
        systemPrompt: String?,
        input: String,
        model: String,
        options: ProviderOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        // Inline the clamping/sanitizing rather than calling the MainActor-isolated
        // global helpers from ModelFamilyDetection.swift (inferred MainActor due to
        // SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor on the app target).
        let maxTokens = max(1, min(options.maxTokens, 16384))
        let temperature = 0.7  // ProviderOptions has no temperature field; use safe default.

        // The action stores the catalog id (e.g. "gemma-4-e2b"); the helper needs the
        // HuggingFace repo id (e.g. "mlx-community/gemma-4-e2b-it-4bit") to load the model.
        // Map id -> repoID via the catalog, matching the download path. Fall back to the
        // raw value so a directly-entered repo id still works.
        let repoID = LocalModelCatalog.model(for: model)?.repoID ?? model

        do {
            return try await MLXHelperManager.shared.generate(
                modelID: repoID,
                systemPrompt: systemPrompt,
                input: input,
                maxTokens: maxTokens,
                temperature: temperature
            )
        } catch let helperError as MLXHelperError {
            throw ProviderError.transport(helperError.localizedDescription)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }
}
