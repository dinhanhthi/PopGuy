// Provider.swift
// PopGuy — ProviderLayer
//
// Core protocol for all AI/translation provider adapters.
// Conformers are responsible for building requests to their respective APIs
// and streaming token deltas back to callers.
//
// Constraint: Swift 6 strict concurrency — protocol and all conformers must be Sendable.

import Foundation

/// A pluggable AI/translation provider.
///
/// Each conformer encapsulates all API-specific knowledge (request shape,
/// authentication, response parsing). Callers (ActionEngine) only see this
/// protocol — they never know which provider is in use.
// nonisolated: prevents SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target) from
// pinning all Provider conformers and their async methods to the main thread.
// Provider streaming must execute on an arbitrary executor context.
public nonisolated protocol Provider: Sendable {

    /// Stream token deltas from this provider.
    ///
    /// - Parameters:
    ///   - systemPrompt: Optional system/instruction prompt (ignored by translation providers).
    ///   - input:        The user text to process (improve, translate, etc.).
    ///   - model:        Model identifier string as configured per-action in SettingsStore.
    ///   - options:      Per-call options (target language, base URL override, etc.).
    /// - Returns:        An `AsyncThrowingStream` emitting raw token delta strings.
    ///                   Non-streaming providers wrap their single result in a one-element stream.
    /// - Throws:         `ProviderError` on transport, decode, or API-level failures.
    func stream(
        systemPrompt: String?,
        input: String,
        model: String,
        options: ProviderOptions
    ) async throws -> AsyncThrowingStream<String, Error>
}
