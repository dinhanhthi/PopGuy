// ProEntitlements.swift
// PopGuy — Licensing
//
// Describes what the current tier allows.
//
// Isolation: nonisolated — this is model-layer data with no UI dependency.
// Marking nonisolated opts out of SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// so ProEntitlements can be used from any context without an actor hop.
// Mirrors the pattern used by ResultFontSize and KeychainManager.

import Foundation

// MARK: - ProEntitlements

/// A Sendable value type describing what the current license tier allows.
///
/// Use the `free` or `pro` preset. `LicenseGate` is the single source of
/// truth for which preset is active at runtime.
nonisolated struct ProEntitlements: Sendable, Equatable {

    // MARK: - Fields

    /// True when a valid Pro license is active.
    let isPro: Bool

    /// Maximum number of custom actions the user may create.
    let maxCustomActions: Int

    /// Maximum number of history entries retained (oldest are dropped past this).
    let maxHistoryRetained: Int

    /// Maximum number of apps the user may add to the ignored-apps list.
    let maxIgnoredApps: Int

    /// Maximum number of domains the user may add to the ignored-domains list.
    let maxIgnoredDomains: Int

    /// Maximum number of actions (built-in + custom) shown active in the toolbar.
    let maxActiveActions: Int

    /// Whether premium cloud TTS voices are accessible.
    let cloudTTSPremiumAllowed: Bool

    /// Whether importing and exporting action sets is allowed.
    let importExportAllowed: Bool

    /// Whether importing plugins/extensions (native JSON + PopClip) is allowed.
    let pluginImportAllowed: Bool

    /// Whether full-text history search is allowed.
    let historySearchAllowed: Bool

    /// Whether assigning a default action to the double-click trigger is allowed.
    let doubleClickActionAllowed: Bool

    /// Whether the OCR Screen Text Capture feature is allowed.
    let ocrAllowed: Bool

    // MARK: - Presets

    /// Free-tier entitlements. No Pro license required; applied at launch by default.
    /// All values come from `ProConfig` (the single source of truth — edit there).
    static let free = ProEntitlements(
        isPro: false,
        maxCustomActions: ProConfig.freeMaxCustomActions,
        maxHistoryRetained: ProConfig.freeMaxHistoryRetained,
        maxIgnoredApps: ProConfig.freeMaxIgnoredApps,
        maxIgnoredDomains: ProConfig.freeMaxIgnoredDomains,
        maxActiveActions: ProConfig.freeMaxActiveActions,
        cloudTTSPremiumAllowed: ProConfig.freeCloudTTSPremiumAllowed,
        importExportAllowed: ProConfig.freeImportExportAllowed,
        pluginImportAllowed: ProConfig.freePluginImportAllowed,
        historySearchAllowed: ProConfig.freeHistorySearchAllowed,
        doubleClickActionAllowed: ProConfig.freeDoubleClickActionAllowed,
        ocrAllowed: ProConfig.freeOCRAllowed
    )

    /// Pro-tier entitlements. Applied by `LicenseGate` on successful activation.
    ///
    /// `maxHistoryRetained` is set to `HistoryStore.maxEntries` (500).
    /// Both presets are uniformly `nonisolated` and readable from any context.
    static let pro = ProEntitlements(
        isPro: true,
        maxCustomActions: Int.max,
        maxHistoryRetained: HistoryStore.maxEntries,
        maxIgnoredApps: Int.max,
        maxIgnoredDomains: Int.max,
        maxActiveActions: Int.max,
        cloudTTSPremiumAllowed: true,
        importExportAllowed: true,
        pluginImportAllowed: true,
        historySearchAllowed: true,
        doubleClickActionAllowed: true,
        ocrAllowed: true
    )
}
