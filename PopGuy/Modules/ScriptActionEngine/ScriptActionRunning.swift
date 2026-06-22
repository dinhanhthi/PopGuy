// ScriptActionRunning.swift
// PopGuy — ScriptActionEngine
//
// Protocol seam for the scriptable-action executor.
//
// Lives in its own file (not inside ScriptActionEngine or ToolbarViewModel) because
// it is the abstraction SHARED between the FloatingToolbar module (which holds it)
// and the ScriptActionEngine module (which implements it). A standalone declaration
// gives both a stable anchor and avoids either concrete type appearing to "own" it.

import Foundation

/// Protocol seam that lets `ToolbarViewModel` hold the executor behind an
/// abstraction (and lets tests inject a fake `ScriptActionRunning`).
///
/// Class-bound (`AnyObject`) so the view model can hold a weak reference, matching
/// the existing pattern for `ToolbarActionHandling` and `SpeakCoordinator`.
@MainActor
protocol ScriptActionRunning: AnyObject {
    /// Execute the given scriptable action and return its result.
    func run(_ action: CustomAction, text: String, fullText: String) async throws -> ScriptActionResult
}
