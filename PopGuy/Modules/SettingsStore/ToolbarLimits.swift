// ToolbarLimits.swift
// PopGuy — SettingsStore
//
// Compile-time toolbar constants: the double-click assignment feature flag.
// There are no action-count caps; users decide how many actions sit on the
// toolbar or in More actions.
//
// Isolation: nonisolated — pure constants, usable from any context.

import Foundation

// MARK: - ToolbarLimits

nonisolated enum ToolbarLimits {

    /// Master switch for assigning a default action to the double-click trigger.
    /// When false, the assignment UI is hidden and a double-click always shows
    /// the toolbar, regardless of any stored assignment.
    static let doubleClickActionFeatureEnabled = true
}
