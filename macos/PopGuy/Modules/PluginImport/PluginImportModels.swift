// PluginImportModels.swift
// PopGuy — PluginImport
//
// Shared result model produced by every import path (native JSON importer,
// PopClip adapter) and consumed by the consent sheet (Phase 3).
//
// Isolation: nonisolated / Sendable value types — pure data, no logic, no IO.

import Foundation

// MARK: - SkippedItem

/// An item that could not be imported, with a human-readable reason.
///
/// Produced by any import path when an action is intentionally skipped rather
/// than silently dropped — e.g. a JavaScript action with no PopGuy equivalent.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct SkippedItem: Sendable, Identifiable, Equatable {

    /// Stable identifier for this skip record (not persisted; scoped to the import session).
    let id: UUID

    /// Short description of what was skipped (e.g. an action title or `"JavaScript action"`).
    let label: String

    /// Human-readable reason the item was skipped (e.g. `"JavaScript actions are not supported"`).
    let reason: String

    nonisolated init(
        id: UUID = UUID(),
        label: String,
        reason: String
    ) {
        self.id = id
        self.label = label
        self.reason = reason
    }
}

// MARK: - PluginImportResult

/// The output of a completed import pass — ready for the consent sheet to present.
///
/// `sourceName` identifies the plugin/extension being imported (shown in the
/// consent sheet header). `imported` holds actions the user can review and accept;
/// `skipped` records items that were intentionally omitted, with reasons.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct PluginImportResult: Sendable, Identifiable {

    /// Stable identity so the result can drive a SwiftUI `.sheet(item:)` (scoped to the import session).
    let id: UUID

    /// Display name of the plugin or extension (e.g. `"My PopClip Extension"`).
    let sourceName: String

    /// Actions that passed validation and are ready to be added after user consent.
    let imported: [CustomAction]

    /// Items that could not be imported, with reasons surfaced to the user.
    let skipped: [SkippedItem]

    nonisolated init(
        id: UUID = UUID(),
        sourceName: String,
        imported: [CustomAction] = [],
        skipped: [SkippedItem] = []
    ) {
        self.id = id
        self.sourceName = sourceName
        self.imported = imported
        self.skipped = skipped
    }
}
