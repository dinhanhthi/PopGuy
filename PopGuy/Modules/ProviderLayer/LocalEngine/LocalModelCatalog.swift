// LocalModelCatalog.swift
// PopGuy — ProviderLayer/LocalEngine
//
// Static curated catalog of on-device MLX models available in PopGuy.
// This catalog is the authoritative source for model metadata: family,
// approximate size, and RAM requirements.
//
// Free-tier eligibility is NOT stored here — it is determined by ProConfig.isLocalModelFree(_:),
// the single source of truth for all Pro/Free decisions (see CLAUDE.md).
//
// All types and members are nonisolated to remain accessible from nonisolated
// contexts (ProviderKind.curatedModels, MLXLocalProvider.stream, tests) under
// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import Foundation

// MARK: - ModelFamily

/// Identifies the model family for input-policy decisions.
///
/// Qwen models require `enable_thinking: false` injected via the chat-template
/// additional context. Gemma models have no such requirement. `other` is a
/// catch-all for any catalog entry that doesn't fit either family.
// nonisolated: enum values are accessible from any concurrency context.
public nonisolated enum ModelFamily: String, Sendable, CaseIterable {
    case gemma
    case qwen
    case other
}

// MARK: - LocalModel

/// Metadata for a single curated on-device model.
// nonisolated: prevents SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor from isolating
// stored properties; all fields must be readable from nonisolated code.
public struct LocalModel: Sendable {

    /// Short stable identifier used in ActionConfig (e.g. "gemma-4-e2b").
    public nonisolated let id: String

    /// HuggingFace repository id (e.g. "mlx-community/gemma-4-e2b-it-4bit").
    public nonisolated let repoID: String

    /// Human-readable label shown in the Settings model picker.
    public nonisolated let displayName: String

    /// Model family — governs chat-template options sent to the helper.
    public nonisolated let family: ModelFamily

    /// Approximate on-disk size in bytes after download.
    public nonisolated let approxSizeBytes: Int64

    /// Minimum recommended RAM in bytes to run this model.
    public nonisolated let minRAMBytes: Int64

    /// Whether this model is available on the Free plan.
    /// Delegates to `ProConfig.isLocalModelFree(_:)` — the single source of truth.
    public nonisolated var isFreeTier: Bool { ProConfig.isLocalModelFree(id) }
}

// MARK: - LocalModelCatalog

/// Static curated catalog of PopGuy's bundled on-device models.
///
/// `all` is the single source of truth for the Settings model picker,
/// installed-model detection, and factory default wiring.
// nonisolated: all members accessible from any concurrency context.
public nonisolated enum LocalModelCatalog {

    // MARK: - Catalog

    /// All curated on-device models, in display order.
    public nonisolated static let all: [LocalModel] = [
        LocalModel(
            id: "gemma-4-e2b",
            repoID: "mlx-community/gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 2B (4-bit)",
            family: .gemma,
            approxSizeBytes: 1_000_000_000,
            minRAMBytes: 4_294_967_296
        ),
        LocalModel(
            id: "gemma-4-e4b",
            repoID: "mlx-community/gemma-4-e4b-it-4bit",
            displayName: "Gemma 4 4B (4-bit)",
            family: .gemma,
            approxSizeBytes: 2_200_000_000,
            minRAMBytes: 6_442_450_944
        ),
        LocalModel(
            id: "gemma-4-12b",
            repoID: "mlx-community/gemma-4-12B-it-4bit",
            displayName: "Gemma 4 12B (4-bit)",
            family: .gemma,
            approxSizeBytes: 7_000_000_000,
            minRAMBytes: 12_884_901_888
        ),
        LocalModel(
            id: "qwen3-1.7b",
            repoID: "mlx-community/Qwen3-1.7B-4bit-DWQ",
            displayName: "Qwen3 1.7B (4-bit)",
            family: .qwen,
            approxSizeBytes: 1_200_000_000,
            minRAMBytes: 4_294_967_296
        ),
        LocalModel(
            id: "qwen3.5-4b",
            repoID: "mlx-community/Qwen3.5-4B-MLX-4bit",
            displayName: "Qwen3.5 4B (4-bit)",
            family: .qwen,
            approxSizeBytes: 2_400_000_000,
            minRAMBytes: 6_442_450_944
        ),
    ]

    // MARK: - Lookup

    /// Returns the catalog entry for the given model id, or `nil` when not found.
    public nonisolated static func model(for id: String) -> LocalModel? {
        all.first { $0.id == id }
    }
}
