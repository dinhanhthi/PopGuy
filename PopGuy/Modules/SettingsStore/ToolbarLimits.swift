// ToolbarLimits.swift
// PopGuy — SettingsStore
//
// Compile-time toolbar layout caps and the double-click assignment feature flag.
//
// Isolation: nonisolated — pure constants, usable from any context.

import Foundation

// MARK: - ToolbarLimits

nonisolated enum ToolbarLimits {

    /// Max actions shown inline on the floating toolbar (outside the burger menu).
    static let maxPrincipalActions = 6

    /// Max actions inside the burger overflow menu.
    static let maxBurgerActions = 5

    /// Master switch for assigning a default action to the double-click trigger.
    /// When false, the assignment UI is hidden and a double-click always shows
    /// the toolbar, regardless of any stored assignment.
    static let doubleClickActionFeatureEnabled = true
}
