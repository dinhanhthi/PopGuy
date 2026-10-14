// ModelDeprecations.swift
// PopGuy — ProviderLayer
//
// Per-provider maps of deprecated, retired, or never-valid model ids to their
// recommended replacement, plus a helper that migrates a saved model id.
// Used to rewrite saved action configs that point at a model the provider no
// longer serves.
//
// Sources (checked 2026-10-14):
// - Anthropic: "Model deprecations" page (platform.claude.com docs).
// - OpenAI: "Deprecations" page (developers.openai.com) and the Codex
//   "Models" page (ChatGPT sign-in retirements).
// - Google: Gemini API "Deprecations" page (ai.google.dev) and the Gemini CLI
//   model registry (geminicli.com configuration reference).
// - OpenRouter: live models API catalog.
//
// Rules:
// - Only ids the docs mark deprecated / retired / shut down, plus ids PopGuy
//   once shipped that were never valid. Legacy-but-active ids are not touched.
// - A replacement is always a terminal, active id: it is never itself a key in
//   the same map (no chains).
// - Matching is exact after trimming whitespace; no fuzzy matching.
//
// Isolation: nonisolated — pure value lookups, opts out of
// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor so they can run from SettingsStore.init
// and nonisolated contexts.

import Foundation

// MARK: - ProviderKind deprecated models

extension ProviderKind {
    /// Deprecated model id → recommended replacement for this provider.
    /// Keyed per provider because the same id can be live on one provider and
    /// retired on another (e.g. `gpt-5.5` on the OpenAI API vs. Codex sign-in).
    ///
    /// Exhaustive switch (no `default`) so a future ProviderKind case fails to
    /// compile rather than silently getting no map.
    public nonisolated var deprecatedModelReplacements: [String: String] {
        switch self {
        case .openAI:
            return Self.openAIReplacements
        case .codexCLI:
            // Codex overrides win over the inherited OpenAI entries.
            return Self.openAIReplacements.merging(Self.codexOverrides) { _, override in override }
        case .anthropic, .claudeCLI:
            return Self.anthropicReplacements
        case .gemini:
            return Self.geminiReplacements
        case .geminiCLI:
            return Self.geminiCLIReplacements
        case .openRouter:
            return Self.openRouterReplacements
        case .glm, .ollama, .custom, .deepL, .googleTranslate, .mlxLocal:
            // No documented deprecations, or the model list is user-defined.
            return [:]
        }
    }

    /// Returns the replacement for `model` when it is a deprecated id for this
    /// provider (matched after trimming whitespace and newlines); otherwise
    /// returns `model` unchanged. An empty string stays empty.
    public nonisolated func migratedModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return deprecatedModelReplacements[trimmed] ?? model
    }
}

// MARK: - Maps

private extension ProviderKind {
    /// OpenAI "Deprecations" page.
    nonisolated static let openAIReplacements: [String: String] = [
        "gpt-5.4-nano": "gpt-6-luna",

        "gpt-5.1": "gpt-6-sol",
        "gpt-5.3-codex": "gpt-6-sol",

        "gpt-5": "gpt-5.6-sol",
        "gpt-5-2025-08-07": "gpt-5.6-sol",
        "o3": "gpt-5.6-sol",
        "o3-2025-04-16": "gpt-5.6-sol",

        "gpt-5-mini": "gpt-5.6-terra",
        "gpt-5-mini-2025-08-07": "gpt-5.6-terra",

        "gpt-5-nano": "gpt-5.6-luna",
        "gpt-5-nano-2025-08-07": "gpt-5.6-luna",

        "gpt-5.2-chat-latest": "gpt-5.6-sol",
        "gpt-5.3-chat-latest": "gpt-5.6-sol",

        "gpt-4o": "gpt-6-luna",
        "gpt-4o-2024-08-06": "gpt-6-luna",
        "gpt-4o-2024-11-20": "gpt-6-luna",
        "gpt-4o-mini": "gpt-6-luna",
        "gpt-4o-mini-2024-07-18": "gpt-6-luna",
        "gpt-4.1": "gpt-6-luna",
        "gpt-4.1-2025-04-14": "gpt-6-luna",
        "gpt-4.1-mini": "gpt-6-luna",
        "gpt-4.1-mini-2025-04-14": "gpt-6-luna",

        "gpt-4.1-nano": "gpt-5.6-luna",
        "gpt-4.1-nano-2025-04-14": "gpt-5.6-luna",

        "o4-mini": "gpt-5.6-terra",
        "o4-mini-2025-04-16": "gpt-5.6-terra",
        "gpt-3.5-turbo": "gpt-5.6-terra",
        "gpt-3.5-turbo-0125": "gpt-5.6-terra",

        "gpt-4": "gpt-5.6-sol",
        "gpt-4-0613": "gpt-5.6-sol",
        "gpt-4-turbo": "gpt-5.6-sol",
        "gpt-4-turbo-2024-04-09": "gpt-5.6-sol",
        "gpt-4-turbo-preview": "gpt-5.6-sol",
        "gpt-4-1106-preview": "gpt-5.6-sol",
        "gpt-4o-2024-05-13": "gpt-5.6-sol",
        "o1": "gpt-5.6-sol",
        "o1-2024-12-17": "gpt-5.6-sol",
        "o3-mini": "gpt-5.6-sol",
        "o3-mini-2025-01-31": "gpt-5.6-sol",
    ]

    /// Codex "Models" page: ids retired for ChatGPT sign-in. Applied on top of
    /// the OpenAI map.
    nonisolated static let codexOverrides: [String: String] = [
        "gpt-5.5": "gpt-6.1-sol",
        "gpt-5.2": "gpt-6.1-sol",
        "gpt-5.3-codex": "gpt-6.1-sol",
        "gpt-5.3-codex-spark": "gpt-6.1-sol",
        "gpt-5.4": "gpt-6-sol",
        "gpt-5.4-mini": "gpt-6-luna",
    ]

    /// Anthropic "Model deprecations" page (alias and dated forms). Shared by
    /// the Anthropic API and the Claude CLI.
    nonisolated static let anthropicReplacements: [String: String] = [
        "claude-sonnet-4-5": "claude-sonnet-5-5",
        "claude-sonnet-4-5-20250929": "claude-sonnet-5-5",

        "claude-sonnet-4-0": "claude-sonnet-5-5",
        "claude-sonnet-4-20250514": "claude-sonnet-5-5",
        "claude-3-7-sonnet-latest": "claude-sonnet-5-5",
        "claude-3-7-sonnet-20250219": "claude-sonnet-5-5",
        "claude-3-5-sonnet-latest": "claude-sonnet-5-5",
        "claude-3-5-sonnet-20240620": "claude-sonnet-5-5",
        "claude-3-5-sonnet-20241022": "claude-sonnet-5-5",
        "claude-3-sonnet-20240229": "claude-sonnet-5-5",

        "claude-opus-4-1": "claude-opus-4-8",
        "claude-opus-4-1-20250805": "claude-opus-4-8",
        "claude-opus-4-0": "claude-opus-4-8",
        "claude-opus-4-20250514": "claude-opus-4-8",
        "claude-3-opus-latest": "claude-opus-4-8",
        "claude-3-opus-20240229": "claude-opus-4-8",

        "claude-3-5-haiku-latest": "claude-haiku-4-5-20251001",
        "claude-3-5-haiku-20241022": "claude-haiku-4-5-20251001",
        "claude-3-haiku-20240307": "claude-haiku-4-5-20251001",
    ]

    /// Gemini API "Deprecations" page. Pro-class ids map to the stable flagship
    /// rather than a preview, because preview ids churn and get shut down.
    nonisolated static let geminiReplacements: [String: String] = [
        "gemini-3.1-pro": "gemini-4-argon",          // never valid
        "gemini-3-pro": "gemini-4-argon",            // never valid
        "gemini-3-pro-preview": "gemini-4-argon",
        "gemini-2.5-pro-preview-03-25": "gemini-4-argon",
        "gemini-2.5-pro-preview-05-06": "gemini-4-argon",
        "gemini-2.5-pro-preview-06-05": "gemini-4-argon",

        "gemini-3-flash": "gemini-3.6-flash",        // never valid
        "gemini-3-flash-preview": "gemini-3.6-flash",
        "gemini-3.5-flash": "gemini-3.6-flash",
        "gemini-2.0-flash": "gemini-3.6-flash",
        "gemini-2.0-flash-001": "gemini-3.6-flash",
        "gemini-2.5-flash-preview-05-20": "gemini-3.6-flash",
        "gemini-2.5-flash-preview-09-2025": "gemini-3.6-flash",

        "gemini-3.7-flash": "gemini-3.8-flash",

        "gemini-3.1-flash-lite": "gemini-3.5-flash-lite",
        "gemini-3.1-flash-lite-preview": "gemini-3.5-flash-lite",
        "gemini-2.0-flash-lite": "gemini-3.5-flash-lite",
        "gemini-2.0-flash-lite-001": "gemini-3.5-flash-lite",
        "gemini-2.5-flash-lite-preview-09-2025": "gemini-3.5-flash-lite",
    ]

    /// Gemini CLI model registry ids.
    nonisolated static let geminiCLIReplacements: [String: String] = [
        "gemini-3-pro": "gemini-3.1-pro-preview",    // never valid
        "gemini-3-pro-preview": "gemini-3.1-pro-preview",

        "gemini-3-flash": "gemini-3.8-flash",        // never valid
        "gemini-3-flash-preview": "gemini-3.8-flash",
        "gemini-3.5-flash": "gemini-3.8-flash",

        "gemini-3.1-flash-lite": "gemini-3.5-flash-lite",
    ]

    /// OpenRouter live models catalog.
    nonisolated static let openRouterReplacements: [String: String] = [
        "anthropic/claude-opus-4-8": "anthropic/claude-opus-5.5", // never valid (OpenRouter uses dots)
        "google/gemini-3.1-pro": "google/gemini-4-argon",         // never valid
    ]
}
