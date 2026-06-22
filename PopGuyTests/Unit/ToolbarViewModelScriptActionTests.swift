// ToolbarViewModelScriptActionTests.swift
// PopGuyTests
//
// Tests for ToolbarViewModel scriptable-action routing.
//
// Coverage:
//   - .showResult with text → actionState becomes .result, editedResult set
//   - .none → actionState becomes .idle, activeCustomActionID nil
//   - .copyResult with nil result text → .idle and no crash
//   - .pasteResult with nil result text → .idle and no crash
//   - error thrown → failWith path → actionState .error
//   - reset() cancels in-flight task
//   - update() cancels in-flight task
//
// Side-effect assertion scope:
//   Copy/paste side effects (NSPasteboard, OutputHandler) are NOT tested here —
//   OutputHandler is an AppKit object with real pasteboard dependencies. Only
//   actionState/activeCustomActionID transitions are asserted.
//
// Technique for awaiting the detached Task:
//   scriptActionTask is internal (not private) so tests can capture the task
//   reference immediately after trigger and await its completion before asserting
//   state. The task self-nils (at the end of its body) so the capture must
//   happen before `await`.

import ApplicationServices
import Foundation
import Testing
@testable import PopGuy

// MARK: - FakeScriptActionRunner

/// Returns a canned ScriptActionResult or throws, without executing any real script.
@MainActor
final class FakeScriptActionRunner: ScriptActionRunning {
    enum Behavior {
        case returnResult(ScriptActionResult)
        case throwError(Error)
    }

    var behavior: Behavior
    private(set) var runCallCount = 0

    init(result: ScriptActionResult) {
        self.behavior = .returnResult(result)
    }

    init(throwing error: Error) {
        self.behavior = .throwError(error)
    }

    func run(
        _ action: CustomAction,
        text: String,
        fullText: String
    ) async throws -> ScriptActionResult {
        runCallCount += 1
        // Yield once so the Task body runs asynchronously relative to the
        // triggerCustomAction call — ensures the task is schedulable before
        // we check actionState in tests.
        await Task.yield()
        switch behavior {
        case .returnResult(let result): return result
        case .throwError(let error): throw error
        }
    }
}

// MARK: - FakeToolbarActionHandler

/// No-op action handler that records cancel() calls.
/// Injected as vm.actionHandler so triggerImprove() (and other built-in
/// triggers) can actually reach the `actionState = .running` branch.
@MainActor
final class FakeToolbarActionHandler: ToolbarActionHandling {
    private(set) var cancelCallCount = 0

    func improve(text: String, viewModel: ToolbarViewModel) {}
    func shorten(text: String, viewModel: ToolbarViewModel) {}
    func proofread(text: String, viewModel: ToolbarViewModel) {}
    func translate(text: String, targetLanguage: TargetLanguage, viewModel: ToolbarViewModel) {}
    func custom(action: CustomAction, text: String, viewModel: ToolbarViewModel) {}
    func dictionary(text: String, targetLanguage: TargetLanguage, viewModel: ToolbarViewModel) {}
    func dictionary(text: String, config: DictionaryConfig, actionName: String, viewModel: ToolbarViewModel) {}
    func recordSpeak(text: String, engineLabel: String, accent: String, sourceBundleID: String?) {}
    func recordScriptAction(actionName: String, typeLabel: String, input: String, output: String, success: Bool, errorMessage: String?, startedAt: Date, sourceBundleID: String?) {}
    func prompt(promptText: String, text: String, viewModel: ToolbarViewModel) {}
    func cancel() { cancelCallCount += 1 }
}

// MARK: - Helpers

/// Reference-type counter so closures can record calls without local-var capture.
@MainActor
final class CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

@MainActor
private func scriptableAction(
    type: CustomActionType,
    afterRun: AfterRunBehavior
) -> CustomAction {
    CustomAction(
        title: "Test \(type.displayName)",
        type: type,
        systemPrompt: "",
        scriptSource: "echo hello",
        afterRun: afterRun
    )
}

@MainActor
private func vmWithFakeEngine(returning result: ScriptActionResult) -> (ToolbarViewModel, FakeScriptActionRunner) {
    let runner = FakeScriptActionRunner(result: result)
    let vm = ToolbarViewModel()
    vm.scriptActionEngine = runner
    // Inject a non-empty selection so the guard passes.
    let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
    vm.update(text: "hello world", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
    return (vm, runner)
}

@MainActor
private func vmWithFakeEngine(throwing error: Error) -> (ToolbarViewModel, FakeScriptActionRunner) {
    let runner = FakeScriptActionRunner(throwing: error)
    let vm = ToolbarViewModel()
    vm.scriptActionEngine = runner
    let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
    vm.update(text: "hello world", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
    return (vm, runner)
}

// MARK: - afterRun == .showResult

@Suite("ToolbarViewModel scriptable routing — showResult")
@MainActor
struct ToolbarViewModelScriptShowResultTests {

    @Test(".showResult with text → actionState .result, editedResult set")
    func showResultWithText() async throws {
        let (vm, runner) = vmWithFakeEngine(returning: ScriptActionResult(text: "output"))
        let counter = CallCounter()
        vm.onRequestDismiss = { counter.bump() }
        let action = scriptableAction(type: .shellScript, afterRun: .showResult)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        let task = vm.scriptActionTask
        await task?.value

        #expect(runner.runCallCount == 1)
        guard case .result(let text) = vm.actionState else {
            Issue.record("expected .result, got \(vm.actionState)")
            return
        }
        #expect(text == "output")
        #expect(vm.editedResult == "output")
        // A shown result keeps the toolbar open — no dismissal.
        #expect(counter.count == 0)
    }

    @Test(".showResult with empty text → actionState .idle")
    func showResultWithEmptyText() async throws {
        let (vm, runner) = vmWithFakeEngine(returning: ScriptActionResult(text: ""))
        let action = scriptableAction(type: .shellScript, afterRun: .showResult)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        let task = vm.scriptActionTask
        await task?.value

        #expect(runner.runCallCount == 1)
        #expect(vm.actionState == .idle)
        #expect(vm.activeCustomActionID == nil)
    }

    @Test(".showResult with nil text → actionState .idle")
    func showResultWithNilText() async throws {
        let (vm, runner) = vmWithFakeEngine(returning: ScriptActionResult(text: nil))
        let action = scriptableAction(type: .appleScript, afterRun: .showResult)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        let task = vm.scriptActionTask
        await task?.value

        #expect(runner.runCallCount == 1)
        #expect(vm.actionState == .idle)
        #expect(vm.activeCustomActionID == nil)
    }
}

// MARK: - afterRun == .none

@Suite("ToolbarViewModel scriptable routing — none")
@MainActor
struct ToolbarViewModelScriptNoneTests {

    @Test(".none → actionState .idle, activeCustomActionID nil")
    func noneGoesIdle() async throws {
        let (vm, runner) = vmWithFakeEngine(returning: ScriptActionResult(text: "ignored"))
        let action = scriptableAction(type: .openURL, afterRun: .none)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        let task = vm.scriptActionTask
        await task?.value

        #expect(runner.runCallCount == 1)
        #expect(vm.actionState == .idle)
        #expect(vm.activeCustomActionID == nil)
    }

    @Test(".none keeps the toolbar open (no dismissal)")
    func noneKeepsToolbarOpen() async throws {
        let (vm, runner) = vmWithFakeEngine(returning: ScriptActionResult(text: nil))
        let counter = CallCounter()
        vm.onRequestDismiss = { counter.bump() }
        let action = scriptableAction(type: .shellScript, afterRun: .none)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        await vm.scriptActionTask?.value

        #expect(runner.runCallCount == 1)
        #expect(vm.actionState == .idle)
        #expect(counter.count == 0)
    }
}

// MARK: - afterRun == .closeToolbar

@Suite("ToolbarViewModel scriptable routing — closeToolbar")
@MainActor
struct ToolbarViewModelScriptCloseToolbarTests {

    @Test(".closeToolbar requests toolbar dismissal (e.g. Reveal in Finder)")
    func closeToolbarRequestsDismiss() async throws {
        let (vm, runner) = vmWithFakeEngine(returning: ScriptActionResult(text: nil))
        let counter = CallCounter()
        vm.onRequestDismiss = { counter.bump() }
        let action = scriptableAction(type: .shellScript, afterRun: .closeToolbar)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        await vm.scriptActionTask?.value

        #expect(runner.runCallCount == 1)
        #expect(vm.actionState == .idle)
        #expect(vm.activeCustomActionID == nil)
        #expect(counter.count == 1)
    }
}

// MARK: - afterRun == .copyResult

@Suite("ToolbarViewModel scriptable routing — copyResult")
@MainActor
struct ToolbarViewModelScriptCopyResultTests {

    @Test(".copyResult with nil result text → .idle, no crash")
    func copyResultWithNilText() async throws {
        let (vm, runner) = vmWithFakeEngine(returning: ScriptActionResult(text: nil))
        let action = scriptableAction(type: .shellScript, afterRun: .copyResult)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        let task = vm.scriptActionTask
        await task?.value

        #expect(runner.runCallCount == 1)
        #expect(vm.actionState == .idle)
        #expect(vm.activeCustomActionID == nil)
    }

    @Test(".copyResult with empty result text → .idle, no crash")
    func copyResultWithEmptyText() async throws {
        // ScriptActionEngine already returns nil for empty output, but guard the
        // VM-level path too: if text is "" the guard should not write to pasteboard.
        let (vm, runner) = vmWithFakeEngine(returning: ScriptActionResult(text: ""))
        let action = scriptableAction(type: .shellScript, afterRun: .copyResult)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        let task = vm.scriptActionTask
        await task?.value

        #expect(runner.runCallCount == 1)
        #expect(vm.actionState == .idle)
        #expect(vm.activeCustomActionID == nil)
    }

    @Test(".copyResult with non-empty result text → .idle")
    func copyResultWithText() async throws {
        // OutputHandler.copy side effect is NOT asserted here (real NSPasteboard).
        // Only the state transition is verified.
        let (vm, runner) = vmWithFakeEngine(returning: ScriptActionResult(text: "copied text"))
        let action = scriptableAction(type: .shellScript, afterRun: .copyResult)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        let task = vm.scriptActionTask
        await task?.value

        #expect(runner.runCallCount == 1)
        #expect(vm.actionState == .idle)
        #expect(vm.activeCustomActionID == nil)
    }
}

// MARK: - afterRun == .pasteResult

@Suite("ToolbarViewModel scriptable routing — pasteResult")
@MainActor
struct ToolbarViewModelScriptPasteResultTests {

    @Test(".pasteResult with nil result text → .idle, no crash")
    func pasteResultWithNilText() async throws {
        let (vm, runner) = vmWithFakeEngine(returning: ScriptActionResult(text: nil))
        let action = scriptableAction(type: .shellScript, afterRun: .pasteResult)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        let task = vm.scriptActionTask
        await task?.value

        #expect(runner.runCallCount == 1)
        #expect(vm.actionState == .idle)
        #expect(vm.activeCustomActionID == nil)
    }
}

// MARK: - Error path

@Suite("ToolbarViewModel scriptable routing — error")
@MainActor
struct ToolbarViewModelScriptErrorTests {

    @Test("error thrown → failWith path → actionState .error")
    func errorThrown() async throws {
        struct FakeError: Error, LocalizedError {
            var errorDescription: String? { "script failed" }
        }
        let (vm, runner) = vmWithFakeEngine(throwing: FakeError())
        let action = scriptableAction(type: .shellScript, afterRun: .showResult)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        let task = vm.scriptActionTask
        await task?.value

        #expect(runner.runCallCount == 1)
        guard case .error(let msg) = vm.actionState else {
            Issue.record("expected .error, got \(vm.actionState)")
            return
        }
        #expect(msg.contains("script failed"))
    }
}

// MARK: - Cancellation via reset() and update()

@Suite("ToolbarViewModel scriptable routing — task cancellation")
@MainActor
struct ToolbarViewModelScriptCancellationTests {

    @Test("reset() cancels in-flight script task → state stays .idle")
    func resetCancelsTask() async throws {
        // Use a fake that suspends briefly via Task.sleep so reset() fires mid-flight.
        final class SlowRunner: ScriptActionRunning {
            func run(_ action: CustomAction, text: String, fullText: String) async throws -> ScriptActionResult {
                try await Task.sleep(nanoseconds: 60_000_000_000) // 60 s — always cancelled
                return ScriptActionResult(text: "should not arrive")
            }
        }
        let runner = SlowRunner()
        let vm = ToolbarViewModel()
        vm.scriptActionEngine = runner
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)

        let action = scriptableAction(type: .shellScript, afterRun: .showResult)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        let task = vm.scriptActionTask
        #expect(task != nil)

        // reset() cancels the task.
        vm.reset()
        await task?.value

        // After cancellation state is idle (reset() set it) and task handle is gone.
        #expect(vm.actionState == .idle)
        #expect(vm.scriptActionTask == nil)
    }

    @Test("update() cancels in-flight script task and clears state")
    func updateCancelsTask() async throws {
        final class SlowRunner: ScriptActionRunning {
            func run(_ action: CustomAction, text: String, fullText: String) async throws -> ScriptActionResult {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return ScriptActionResult(text: "should not arrive")
            }
        }
        let runner = SlowRunner()
        let vm = ToolbarViewModel()
        vm.scriptActionEngine = runner
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)

        let action = scriptableAction(type: .shellScript, afterRun: .showResult)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        let task = vm.scriptActionTask
        // Pre-cancellation: confirm a task was actually launched.
        #expect(task != nil)
        #expect(vm.actionState == .running(progress: ""))

        // update() with new text cancels the script task and resets state.
        vm.update(text: "new text", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        await task?.value

        #expect(vm.actionState == .idle)
        #expect(vm.capturedText == "new text")
    }
}

// MARK: - suppressRunningPanel
//
// These tests drive state through triggerCustomAction with a SlowRunner that
// never completes (cancelled at test end), so we can observe the .running state.

/// A fake runner that suspends indefinitely until cancelled.
@MainActor
private final class SlowScriptRunner: ScriptActionRunning {
    func run(_ action: CustomAction, text: String, fullText: String) async throws -> ScriptActionResult {
        try await Task.sleep(nanoseconds: 60_000_000_000) // effectively infinite
        return ScriptActionResult(text: nil)
    }
}

@Suite("ToolbarViewModel suppressRunningPanel")
@MainActor
struct ToolbarViewModelSuppressRunningPanelTests {

    @Test("returns true for scriptable action with afterRun .none while running")
    func suppressesDuringNoneAfterRun() {
        let runner = SlowScriptRunner()
        let vm = ToolbarViewModel()
        vm.scriptActionEngine = runner
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        let action = scriptableAction(type: .shellScript, afterRun: .none)
        vm.customActions = [action]

        vm.triggerCustomAction(action)

        // State is .running right after trigger (before task completes).
        #expect(vm.suppressRunningPanel == true)
        vm.reset() // cancel the slow task
    }

    @Test("returns true for scriptable action with afterRun .copyResult while running")
    func suppressesDuringCopyResultAfterRun() {
        let runner = SlowScriptRunner()
        let vm = ToolbarViewModel()
        vm.scriptActionEngine = runner
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        let action = scriptableAction(type: .shellScript, afterRun: .copyResult)
        vm.customActions = [action]

        vm.triggerCustomAction(action)

        #expect(vm.suppressRunningPanel == true)
        vm.reset()
    }

    @Test("returns false for .showResult scriptable action while running")
    func doesNotSuppressShowResult() {
        let runner = SlowScriptRunner()
        let vm = ToolbarViewModel()
        vm.scriptActionEngine = runner
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        let action = scriptableAction(type: .shellScript, afterRun: .showResult)
        vm.customActions = [action]

        vm.triggerCustomAction(action)

        #expect(vm.suppressRunningPanel == false)
        vm.reset()
    }

    @Test("returns false when actionState is .error (never suppress error panel)")
    func doesNotSuppressErrorState() async throws {
        struct FakeError: Error, LocalizedError {
            var errorDescription: String? { "oops" }
        }
        let (vm, runner) = vmWithFakeEngine(throwing: FakeError())
        let action = scriptableAction(type: .shellScript, afterRun: .none)
        vm.customActions = [action]

        vm.triggerCustomAction(action)
        let task = vm.scriptActionTask
        await task?.value

        #expect(runner.runCallCount == 1)
        // After error, actionState is .error — must not suppress.
        if case .error = vm.actionState {
            #expect(vm.suppressRunningPanel == false)
        } else {
            Issue.record("expected .error state, got \(vm.actionState)")
        }
    }

    @Test("returns false when no custom action is running (built-in .running)")
    func doesNotSuppressBuiltInRunning() {
        let handler = FakeToolbarActionHandler()
        let vm = ToolbarViewModel()
        vm.actionHandler = handler
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)

        // Drive the VM into .running via a built-in action (actionHandler is non-nil,
        // so triggerImprove() sets actionState = .running and activeCustomActionID = nil).
        vm.triggerImprove()

        // Preconditions: verify the first guard in suppressRunningPanel is passed
        // (so we're actually exercising the built-in-vs-scriptable branch).
        #expect(vm.actionState == .running(progress: ""))
        #expect(vm.activeCustomActionID == nil)
        // The built-in path has no activeCustomActionID → must NOT suppress.
        #expect(vm.suppressRunningPanel == false)
        // Keep handler alive through end of test (it's held by vm as a weak ref).
        _ = handler
    }
}

// MARK: - Mutual cross-engine cancellation

@Suite("ToolbarViewModel mutual cross-engine cancellation")
@MainActor
struct ToolbarViewModelCrossEngineCancellationTests {

    @Test("script→AI: triggering a scriptable action cancels the in-flight AI action")
    func scriptCancelsAI() async throws {
        // Set up: drive the VM into .running via a built-in action (AI side).
        let handler = FakeToolbarActionHandler()
        let vm = ToolbarViewModel()
        vm.actionHandler = handler
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        vm.triggerImprove()

        // Confirm AI is now in flight.
        #expect(vm.actionState == .running(progress: ""))
        #expect(vm.activeCustomActionID == nil)
        #expect(handler.cancelCallCount == 0)

        // Now trigger a scriptable action — the scriptable branch calls cancelAIAction()
        // which calls actionHandler.cancel() before setting its own .running state.
        let runner = SlowScriptRunner()
        vm.scriptActionEngine = runner
        let scriptAction = scriptableAction(type: .shellScript, afterRun: .none)
        vm.customActions = [scriptAction]
        vm.triggerCustomAction(scriptAction)

        // The AI handler must have received exactly one cancel() call.
        #expect(handler.cancelCallCount == 1)
        // The scriptable action now owns the running state.
        #expect(vm.actionState == .running(progress: ""))
        #expect(vm.activeCustomActionID == scriptAction.id)

        // Keep references alive; cancel the slow task.
        _ = handler
        vm.reset()
    }

    @Test("AI→script: triggering a built-in action cancels the in-flight script task")
    func aiCancelsScript() async throws {
        // Set up: drive the VM into .running via a scriptable action.
        let runner = SlowScriptRunner()
        let vm = ToolbarViewModel()
        vm.scriptActionEngine = runner
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "hello", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        let scriptAction = scriptableAction(type: .shellScript, afterRun: .none)
        vm.customActions = [scriptAction]
        vm.triggerCustomAction(scriptAction)

        // Confirm script task is in flight.
        let scriptTask = vm.scriptActionTask
        #expect(scriptTask != nil)
        #expect(vm.actionState == .running(progress: ""))
        #expect(vm.activeCustomActionID == scriptAction.id)

        // Now trigger a built-in action — triggerImprove() calls cancelScriptAction()
        // which cancels and nils the script task, then sets its own .running state.
        let handler = FakeToolbarActionHandler()
        vm.actionHandler = handler
        vm.triggerImprove()

        // The previously captured script task must be cancelled.
        #expect(scriptTask?.isCancelled == true)

        // Drain the cancelled task: the slow runner throws CancellationError → the
        // task body returns without mutating any state.
        await scriptTask?.value

        // State belongs to the built-in action; the cancelled script did not clobber it.
        #expect(vm.actionState == .running(progress: ""))
        #expect(vm.activeCustomActionID == nil)

        // Keep handler alive.
        _ = handler
    }
}
