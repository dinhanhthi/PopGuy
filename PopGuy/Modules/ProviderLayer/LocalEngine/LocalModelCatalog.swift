// LocalModelCatalog.swift
// PopGuy — ProviderLayer/LocalEngine
//
// Static curated catalog of on-device MLX models available in PopGuy.
// This catalog is the authoritative source for model metadata: family,
// approximate size, and RAM requirements.
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
/// Completion-only entries (see `CompletionPrompt`) skip the chat template entirely.
// nonisolated: enum values are accessible from any concurrency context.
public nonisolated enum ModelFamily: String, Sendable, CaseIterable {
    case gemma
    case qwen
    case other
}

// MARK: - CompletionPrompt

/// Fixed prompt format for a completion-only model (no chat template).
///
/// The model was trained on one exact layout: instruction, blank line, draft,
/// separator; it then continues with the rewrite. Changing any byte of the
/// layout degrades output, so the instruction is stored verbatim.
// nonisolated: read from nonisolated provider code and tests.
public nonisolated struct CompletionPrompt: Sendable {

    /// Fixed instruction placed before the draft.
    public let instruction: String

    /// Marker after the draft; the model generates the rewrite from here.
    public let separator: String

    /// Sampling temperature the model was tuned for.
    public let temperature: Double

    /// Nucleus sampling cutoff the model was tuned for.
    public let topP: Double

    /// Context window shared by the prompt and the generated rewrite.
    public let contextTokens: Int

    /// Longest draft (in characters) accepted before the context runs out.
    public let maxInputCharacters: Int

    /// The exact text sent to the model for `draft`.
    public func build(draft: String) -> String {
        instruction + "\n\n" + draft.trimmingCharacters(in: .whitespacesAndNewlines) + separator
    }

    /// Output-token budget for `draft`.
    ///
    /// Draft and rewrite share the same context window, so the output gets
    /// whatever the prompt leaves (minus a small safety margin). The prompt size
    /// is estimated cautiously at 3 characters per token; the floor keeps short
    /// drafts from getting an unusably small budget.
    public func maxNewTokens(forDraft draft: String) -> Int {
        let estimatedPromptTokens = (build(draft: draft).count + 2) / 3
        return max(256, contextTokens - estimatedPromptTokens - 64)
    }

    /// Prompt format of the humanizer model (its published fixed instruction).
    public static let humanizer = CompletionPrompt(
        instruction: "Rewrite the text below so it reads like a person wrote it, not a language model.\n\n"
            + "Reorganize it as you see fit. Vary sentence length on purpose. Cut hedging,\n"
            + "throat-clearing, and any sentence that only announces what comes next.\n"
            + "Prefer the concrete word over the abstract one. It is fine to sound uneven.\n\n"
            + "Every fact, number, unit, date, name and quotation must survive unchanged.",
        separator: "\n\n### Rewritten:\n\n",
        temperature: 1.0,
        topP: 0.95,
        contextTokens: 8192,
        maxInputCharacters: 10_000
    )
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

    /// Model family — governs chat-template options sent to the helper
    /// (unused for completion-only models).
    public nonisolated let family: ModelFamily

    /// Approximate on-disk size in bytes after download.
    public nonisolated let approxSizeBytes: Int64

    /// Minimum recommended RAM in bytes to run this model.
    public nonisolated let minRAMBytes: Int64

    /// Non-nil for a completion-only model: it has no chat template, so the
    /// provider sends exactly this prompt and ignores the action's system prompt.
    public nonisolated let completionPrompt: CompletionPrompt?

    /// Non-nil when the model may only be picked by the action installed from
    /// this Action Library preset id.
    public nonisolated let dedicatedPresetID: String?

    public nonisolated init(
        id: String,
        repoID: String,
        displayName: String,
        family: ModelFamily,
        approxSizeBytes: Int64,
        minRAMBytes: Int64,
        completionPrompt: CompletionPrompt? = nil,
        dedicatedPresetID: String? = nil
    ) {
        self.id = id
        self.repoID = repoID
        self.displayName = displayName
        self.family = family
        self.approxSizeBytes = approxSizeBytes
        self.minRAMBytes = minRAMBytes
        self.completionPrompt = completionPrompt
        self.dedicatedPresetID = dedicatedPresetID
    }
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
            approxSizeBytes: 3_600_000_000,
            minRAMBytes: 4_294_967_296
        ),
        LocalModel(
            id: "gemma-4-e4b",
            repoID: "mlx-community/gemma-4-e4b-it-4bit",
            displayName: "Gemma 4 4B (4-bit)",
            family: .gemma,
            approxSizeBytes: 5_200_000_000,
            minRAMBytes: 6_442_450_944
        ),
        LocalModel(
            id: "gemma-4-12b",
            repoID: "mlx-community/gemma-4-12B-it-4bit",
            displayName: "Gemma 4 12B (4-bit)",
            family: .gemma,
            approxSizeBytes: 6_800_000_000,
            minRAMBytes: 12_884_901_888
        ),
        LocalModel(
            id: "qwen3-1.7b",
            repoID: "mlx-community/Qwen3-1.7B-4bit-DWQ",
            displayName: "Qwen3 1.7B (4-bit)",
            family: .qwen,
            approxSizeBytes: 1_000_000_000,
            minRAMBytes: 4_294_967_296
        ),
        LocalModel(
            id: "qwen3.5-2b",
            repoID: "mlx-community/Qwen3.5-2B-MLX-4bit",
            displayName: "Qwen3.5 2B (4-bit)",
            family: .qwen,
            approxSizeBytes: 1_750_000_000,
            minRAMBytes: 4_294_967_296
        ),
        LocalModel(
            id: "qwen3.5-4b",
            repoID: "mlx-community/Qwen3.5-4B-MLX-4bit",
            displayName: "Qwen3.5 4B (4-bit)",
            family: .qwen,
            approxSizeBytes: 3_100_000_000,
            minRAMBytes: 6_442_450_944
        ),
        LocalModel(
            id: "qwen3.5-9b",
            repoID: "mlx-community/Qwen3.5-9B-MLX-4bit",
            displayName: "Qwen3.5 9B (4-bit)",
            family: .qwen,
            approxSizeBytes: 6_000_000_000,
            minRAMBytes: 12_884_901_888
        ),
        LocalModel(
            id: "llama-3.2-3b",
            repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B (4-bit)",
            family: .other,
            approxSizeBytes: 1_820_000_000,
            minRAMBytes: 4_294_967_296
        ),
        // Keep last: `all.first` is the onboarding default.
        LocalModel(
            id: "humanizer-12b",
            repoID: "mlx-community/humanizer-12b-OptiQ-4bit",
            displayName: "Humanizer 12B (4-bit)",
            family: .gemma,
            approxSizeBytes: 9_000_000_000,
            minRAMBytes: 17_179_869_184,
            completionPrompt: .humanizer,
            dedicatedPresetID: "ai.humanize"
        ),
    ]

    // MARK: - Lookup

    /// Returns the catalog entry for the given model id, or `nil` when not found.
    public nonisolated static func model(for id: String) -> LocalModel? {
        all.first { $0.id == id }
    }

    /// Models an action may pick, in catalog order.
    ///
    /// `installed` holds catalog ids (not repo ids), as in the store's installed set.
    /// Models dedicated to a Library preset are hidden unless `presetID` matches it.
    public nonisolated static func selectableModels(installed: Set<String>, presetID: String?) -> [LocalModel] {
        all.filter { model in
            installed.contains(model.id)
                && (model.dedicatedPresetID == nil || model.dedicatedPresetID == presetID)
        }
    }
}
