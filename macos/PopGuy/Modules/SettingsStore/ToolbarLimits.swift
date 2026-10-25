// ToolbarLimits.swift
// PopGuy — SettingsStore
//
// Compile-time toolbar constants: the double-click assignment feature flag and
// the soft toolbar-width warning threshold. There are no action-count caps;
// users decide how many actions sit on the toolbar or in More actions.
//
// Isolation: nonisolated — pure constants, usable from any context.

import Foundation

// MARK: - ToolbarLimits

nonisolated enum ToolbarLimits {

    /// Master switch for assigning a default action to the double-click trigger.
    /// When false, the assignment UI is hidden and a double-click always shows
    /// the toolbar, regardless of any stored assignment.
    static let doubleClickActionFeatureEnabled = true

    /// Toolbar card width (points) above which Settings → Actions shows a soft,
    /// non-blocking warning under the preview that the toolbar is getting wide.
    /// Not a cap: nothing is rejected or trimmed.
    static let toolbarWidthWarningThreshold: CGFloat = 480
}
