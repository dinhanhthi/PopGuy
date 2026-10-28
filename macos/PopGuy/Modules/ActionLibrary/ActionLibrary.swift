// ActionLibrary.swift
// PopGuy — ActionLibrary
//
// Core model for the Action Library preset catalog.
// Defines categories, preset wrappers, and the aggregator enum.
// Per-category preset factories live in separate files (ActionLibraryWeb.swift, etc.)
// and are wired into `presets(in:)`.
//
// Isolation: nonisolated / Sendable value-type namespace — pure factory, no state.

import Foundation

// MARK: - LibraryCategory

// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum LibraryCategory: String, CaseIterable, Sendable, Identifiable {
    case aiWriting
    case search
    case web
    case maps
    case aiLaunchers
    case translateLaunchers
    case textTransform
    case devTools
    case apps

    nonisolated var id: String { rawValue }

    /// Human-readable label shown in the category picker.
    nonisolated var displayName: String {
        switch self {
        case .aiWriting:         return "AI Writing"
        case .search:            return "Search Engines"
        case .web:               return "Websites"
        case .maps:              return "Maps"
        case .aiLaunchers:       return "AI Launchers"
        case .translateLaunchers: return "Translate"
        case .textTransform:     return "Text Transform"
        case .devTools:          return "Developer Tools"
        case .apps:              return "Apps"
        }
    }

    /// SF Symbol name representing the category.
    nonisolated var iconName: String {
        switch self {
        case .aiWriting:         return "wand.and.stars"
        case .search:            return "magnifyingglass"
        case .web:               return "globe"
        case .maps:              return "map"
        case .aiLaunchers:       return "sparkles"
        case .translateLaunchers: return "character.bubble"
        case .textTransform:     return "textformat"
        case .devTools:          return "hammer"
        case .apps:              return "square.grid.2x2"
        }
    }
}

// MARK: - LibraryPreset

/// A single entry in the Action Library catalog.
///
/// `id` is a stable string key (e.g. "search.google") used for installed-state
/// matching and SwiftUI identity — NOT a UUID.
///
/// `make` is a `@Sendable` factory closure that returns a fresh `CustomAction`
/// (new UUID each call) so adding the same preset twice never collides with an
/// existing action.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct LibraryPreset: Sendable, Identifiable {

    /// Stable catalog key (e.g. "search.google"). Used for installed-state checks
    /// and SwiftUI identity. Never a UUID — must be constant across builds.
    let id: String

    /// The category this preset belongs to.
    let category: LibraryCategory

    /// Factory that returns a fresh `CustomAction` with a new UUID on each call.
    let make: @Sendable () -> CustomAction

    nonisolated init(
        id: String,
        category: LibraryCategory,
        make: @Sendable @escaping () -> CustomAction
    ) {
        self.id = id
        self.category = category
        self.make = make
    }
}

// MARK: - ActionLibrary

/// Aggregator for the full Action Library preset catalog.
///
/// Per-category presets live in separate files (ActionLibraryAI/Web/Text/Dev/Apps.swift)
/// and are wired into `presets(in:)`.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum ActionLibrary: Sendable {

    /// Returns all presets for the given category.
    nonisolated static func presets(in category: LibraryCategory) -> [LibraryPreset] {
        switch category {
        case .aiWriting:
            return ActionLibraryAI.all()
        case .search, .web, .maps, .aiLaunchers, .translateLaunchers:
            return ActionLibraryWeb.all().filter { $0.category == category }
        case .textTransform:
            return ActionLibraryText.all()
        case .devTools:
            return ActionLibraryDev.all()
        case .apps:
            return ActionLibraryApps.all()
        }
    }

    /// Returns all presets across all categories, in `LibraryCategory.allCases` order.
    nonisolated static func allPresets() -> [LibraryPreset] {
        LibraryCategory.allCases.flatMap { presets(in: $0) }
    }

    /// All categories in declaration order.
    nonisolated static var categories: [LibraryCategory] { LibraryCategory.allCases }

    /// Returns `true` when `actions` already contains an action installed from this
    /// preset (`libraryPresetID`), or one matching the preset's `type` + `scriptSource`.
    ///
    /// The `!isEmpty` guard prevents a false positive when two non-scriptable
    /// presets share an empty `scriptSource`: an empty `scriptSource` means
    /// "no script body", so it is never a meaningful identity key. Those
    /// presets report installed only through `libraryPresetID`.
    nonisolated static func isInstalled(_ preset: LibraryPreset, in actions: [CustomAction]) -> Bool {
        if actions.contains(where: { $0.libraryPresetID == preset.id }) { return true }
        let a = preset.make()
        guard !a.scriptSource.isEmpty else { return false }
        return actions.contains { $0.type == a.type && $0.scriptSource == a.scriptSource }
    }

    /// Builds the action the Library installs for `preset`: sanitized like an import,
    /// tagged with the preset identity, and — for `.ai` presets — running on the
    /// Improve action's provider and model. Returns `nil` when sanitizing rejects it.
    ///
    /// No re-sanitize after the provider copy: `.ai` actions allow exactly
    /// `ActionKind.improve.allowedProviders`, so Improve's provider is always valid.
    nonisolated static func installableAction(
        for preset: LibraryPreset,
        improveConfig: ActionConfig
    ) -> CustomAction? {
        guard var action = CustomAction.sanitizeImported(preset.make(), cloudAllowed: true) else {
            return nil
        }
        action.libraryPresetID = preset.id
        if action.type == .ai {
            action.providerKind = improveConfig.providerKind
            action.model = improveConfig.model
        }
        return action
    }
}
