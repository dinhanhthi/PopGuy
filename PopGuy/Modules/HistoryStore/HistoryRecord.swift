// HistoryRecord.swift
// PopGuy — HistoryStore
//
// Codable record for a single completed action run shown in the History tab.
//
// Isolation: nonisolated / Sendable value type — pure data that HistoryStore
// encodes/decodes and the UI renders. It holds no mutable state, so it crosses
// actor boundaries without issue (mirrors the ActionConfig convention).
//
// NOTE: input/output may be stored as a truncated preview when the
// `historyStoreFullText` setting is off; `truncated` records which.

import Foundation

// MARK: - HistoryRecord

/// One logged action execution: what ran, where, how long it took, and whether
/// it succeeded — plus the input and (on success) output text.
nonisolated struct HistoryRecord: Identifiable, Codable, Sendable, Equatable {
    /// Stable identity for SwiftUI lists and per-row delete.
    let id: UUID
    /// When the run finished (record-time).
    let timestamp: Date
    /// "Improve"/"Shorten"/"Proofread"/"Translate"/"Speak" or a custom action title.
    let actionName: String
    /// Provider that handled the run. Nil for runs not backed by a `ProviderKind`
    /// (e.g. Speak, which uses a TTS engine) — those carry `providerLabel` instead.
    let providerKind: ProviderKind?
    /// Human-readable provider label for runs without a `ProviderKind` (Speak's
    /// TTS engine). Nil when `providerKind` is set.
    let providerLabel: String?
    /// Raw model id; the UI decides whether to show it (see `ProviderKind.usesModel`).
    let model: String
    /// Bundle ID of the source app the text came from, if known.
    let sourceBundleID: String?
    /// Resolved app name at record-time; falls back to the bundle ID when the app already quit.
    let sourceAppName: String?
    /// Wall-clock duration of the run in milliseconds.
    let durationMs: Int
    /// Whether the run completed successfully.
    let success: Bool
    /// Error message on failure; nil on success.
    let errorMessage: String?
    /// Input text, or a truncated preview when `truncated` is true.
    let input: String
    /// Output text, or a truncated preview; on failure may be "".
    let output: String
    /// True when input/output were stored as previews rather than full text.
    let truncated: Bool

    init(
        id: UUID,
        timestamp: Date,
        actionName: String,
        providerKind: ProviderKind?,
        providerLabel: String? = nil,
        model: String,
        sourceBundleID: String?,
        sourceAppName: String?,
        durationMs: Int,
        success: Bool,
        errorMessage: String?,
        input: String,
        output: String,
        truncated: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.actionName = actionName
        self.providerKind = providerKind
        self.providerLabel = providerLabel
        self.model = model
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.durationMs = durationMs
        self.success = success
        self.errorMessage = errorMessage
        self.input = input
        self.output = output
        self.truncated = truncated
    }
}
