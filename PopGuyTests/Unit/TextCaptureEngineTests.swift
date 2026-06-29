// TextCaptureEngineTests.swift
// PopGuyTests
//
// Unit tests for the testable (pure-logic) surface of the text-capture path:
// the Electron/Chromium enhanced-capture allowlist matcher, the cheap-probe
// helpers, and a guard that pins the clipboard-fallback poll timeout.
// The AX reads themselves require a live accessibility tree and are covered
// by the manual QA checklist.

import CoreFoundation
import CoreGraphics
import Testing
@testable import PopGuy

@Suite("TextCaptureEngine enhanced-capture allowlist")
@MainActor
struct TextCaptureEngineTests {

    // MARK: - usesEnhancedCapture matcher

    @Test("Listed Electron/Chromium bundle IDs use the enhanced path", arguments: [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.hnc.DiscordCanary",
        "com.hnc.DiscordPTB",
        "md.obsidian",
        "notion.id",
        "com.figma.Desktop",
    ])
    func listedAppsUseEnhanced(bundleID: String) {
        #expect(TextCaptureEngine.usesEnhancedCapture(bundleID: bundleID) == true)
    }

    @Test("Native / unknown bundle IDs do not use the enhanced path", arguments: [
        "com.apple.TextEdit",
        "com.apple.Notes",
        "com.apple.Safari",
        "com.googlecode.iterm2",
        "",
        "com.microsoft.vscode",   // case-sensitive: lowercase must not match
    ])
    func nativeAppsSkipEnhanced(bundleID: String) {
        #expect(TextCaptureEngine.usesEnhancedCapture(bundleID: bundleID) == false)
    }

    /// Guards against additive drift: a new bundle ID added to the source set
    /// without a matching test entry fails this assertion.
    @Test("Allowlist set exactly matches the tested IDs")
    func allowlistMatchesTestedIDs() {
        let tested: Set<String> = [
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.visualstudio.code.oss",
            "com.todesktop.230313mzl4w4u92",
            "com.google.Chrome",
            "com.google.Chrome.beta",
            "com.google.Chrome.dev",
            "com.google.Chrome.canary",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "company.thebrowser.Browser",
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord",
            "com.hnc.DiscordCanary",
            "com.hnc.DiscordPTB",
            "md.obsidian",
            "notion.id",
            "com.figma.Desktop",
        ]
        #expect(TextCaptureEngine.enhancedCaptureBundleIDs == tested)
    }

    // MARK: - usesClipboardFallback matcher (narrow Monaco-only allowlist)

    /// Regression guard for the "Chrome tab-bar drag beeps" bug: browsers and
    /// other marker-readable enhanced apps must NOT trigger the synthetic ⌘C
    /// fallback, or a non-text drag (e.g. moving a window by its tab bar) makes
    /// the host beep with nothing to copy.
    @Test("Only Monaco editors use the ⌘C clipboard fallback", arguments: [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92",
    ])
    func monacoEditorsUseClipboardFallback(bundleID: String) {
        #expect(TextCaptureEngine.usesClipboardFallback(bundleID: bundleID) == true)
    }

    @Test("Browsers / other enhanced apps do NOT use the ⌘C clipboard fallback", arguments: [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.hnc.DiscordCanary",
        "com.hnc.DiscordPTB",
        "md.obsidian",
        "notion.id",
        "com.figma.Desktop",
        "com.apple.Safari",
        "",
    ])
    func nonMonacoAppsSkipClipboardFallback(bundleID: String) {
        #expect(TextCaptureEngine.usesClipboardFallback(bundleID: bundleID) == false)
    }

    /// Exact-match drift guard (mirrors `allowlistMatchesTestedIDs`): a new ID
    /// added to `clipboardFallbackBundleIDs` without a matching entry here fails
    /// this assertion. The subset test below cannot catch an addition of an ID
    /// that is ALSO already in `enhancedCaptureBundleIDs` — this one can, so a new
    /// ⌘C-eligible app can never slip in untested and re-open the beep regression.
    @Test("clipboardFallbackBundleIDs exactly matches the tested IDs")
    func clipboardFallbackMatchesTestedIDs() {
        let tested: Set<String> = [
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.visualstudio.code.oss",
            "com.todesktop.230313mzl4w4u92",
        ]
        #expect(TextCaptureEngine.clipboardFallbackBundleIDs == tested)
    }

    /// The clipboard-fallback set must stay a strict subset of the enhanced set:
    /// every app that gets a ⌘C also needs the woken-AX/marker path, never the
    /// reverse.
    @Test("clipboardFallbackBundleIDs ⊂ enhancedCaptureBundleIDs")
    func clipboardFallbackIsSubsetOfEnhanced() {
        #expect(
            TextCaptureEngine.clipboardFallbackBundleIDs
                .isSubset(of: TextCaptureEngine.enhancedCaptureBundleIDs)
        )
        #expect(
            TextCaptureEngine.clipboardFallbackBundleIDs != TextCaptureEngine.enhancedCaptureBundleIDs
        )
    }
}

// MARK: - assembleSelectedText (descending capture join)

/// Unit tests for the pure helper that joins per-element selected-text fragments
/// collected when descending the AX tree (e.g. Apple Books exposes the selection
/// on multiple AXStaticText leaves rather than one container). Trims each piece,
/// drops empties, joins the rest with a single space.
@Suite("TextCaptureEngine.assembleSelectedText")
struct AssembleSelectedTextTests {

    @Test("joins multiple fragments with a single space")
    func joinsFragments() {
        #expect(TextCaptureEngine.assembleSelectedText(["hello", "world"]) == "hello world")
    }

    @Test("trims each fragment and drops empties / whitespace-only")
    func trimsAndDropsEmpties() {
        #expect(TextCaptureEngine.assembleSelectedText(["  a  ", "", "  b "]) == "a b")
        #expect(TextCaptureEngine.assembleSelectedText(["   ", "\n", ""]) == "")
    }

    @Test("empty input → empty string")
    func emptyInput() {
        #expect(TextCaptureEngine.assembleSelectedText([]) == "")
    }

    @Test("single fragment is returned trimmed")
    func singleFragment() {
        #expect(TextCaptureEngine.assembleSelectedText(["  only piece  "]) == "only piece")
    }
}

// MARK: - Probe helpers

/// Unit tests for the two pure static helpers that implement the O(1) presence
/// decision in `probeSelection`. These exercise only the decision logic — no
/// AXUIElement, no live accessibility tree required.
@Suite("TextCaptureEngine probe helpers")
struct ProbeHelperTests {

    // MARK: - isNonEmptyRange

    @Test("length > 0 → non-empty", arguments: [1, 10, 100, Int.max])
    func nonEmptyRange(length: Int) {
        let range = CFRange(location: 0, length: length)
        #expect(TextCaptureEngine.isNonEmptyRange(range) == true)
    }

    @Test("length == 0 → empty")
    func emptyRange() {
        let range = CFRange(location: 5, length: 0)
        #expect(TextCaptureEngine.isNonEmptyRange(range) == false)
    }

    // MARK: - isNonEmptyRect

    @Test("positive width → non-empty", arguments: [1.0, 10.5, 1000.0] as [CGFloat])
    func nonEmptyRect(width: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: width, height: 20)
        #expect(TextCaptureEngine.isNonEmptyRect(rect) == true)
    }

    @Test("zero width → empty")
    func emptyRect() {
        let rect = CGRect(x: 10, y: 20, width: 0, height: 20)
        #expect(TextCaptureEngine.isNonEmptyRect(rect) == false)
    }

    @Test("zero height but positive width → non-empty (width is the proxy)")
    func positiveWidthZeroHeight() {
        // Presence is determined by width only — a zero-height rect with a
        // positive width is still a detected selection.
        let rect = CGRect(x: 0, y: 0, width: 50, height: 0)
        #expect(TextCaptureEngine.isNonEmptyRect(rect) == true)
    }
}

// MARK: - Finding 1: anchor merge

/// Unit tests for the `mergeGestureAnchor` pure helper that preserves a
/// double-click tag (and release point) when the AX notification for a
/// double-click reschedules within the 80ms debounce window, causing
/// `scheduleCapture` to recompute the anchor from already-zeroed state.
@Suite("mergeGestureAnchor() — Finding 1 double-click race fix")
struct MergeGestureAnchorTests {

    let somePoint = CGPoint(x: 200, y: 300)

    // --- isDoubleClick merge ---

    @Test("pending double-click survives a fresh non-double-click recompute")
    func pendingDoubleClickSurvives() {
        // Simulates: mouse-up scheduled with isDoubleClick=true (pendingIsDoubleClick=true),
        // then the AX notification reschedules within 80ms — fresh recomputes to false.
        let fresh = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.none, isDoubleClick: false)
        let pending = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.none, isDoubleClick: true)
        let result = mergeGestureAnchor(fresh: fresh, pending: pending)
        #expect(result.isDoubleClick == true)
    }

    @Test("fresh double-click is not lost even when pending is non-double-click")
    func freshDoubleClickKept() {
        let fresh = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.none, isDoubleClick: true)
        let pending = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.none, isDoubleClick: false)
        let result = mergeGestureAnchor(fresh: fresh, pending: pending)
        #expect(result.isDoubleClick == true)
    }

    @Test("both false → merged false (post-emit unrelated gesture)")
    func bothFalseRemainsClean() {
        let fresh = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.none, isDoubleClick: false)
        let pending = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.none, isDoubleClick: false)
        let result = mergeGestureAnchor(fresh: fresh, pending: pending)
        #expect(result.isDoubleClick == false)
    }

    // --- mouseReleasePoint merge ---

    @Test("pending release point survives zeroed fresh recompute")
    func pendingReleasePointSurvives() {
        let fresh = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.none, isDoubleClick: false)
        let pending = (mouseReleasePoint: CGPoint?.some(somePoint), grewDownward: Bool?.none, isDoubleClick: false)
        let result = mergeGestureAnchor(fresh: fresh, pending: pending)
        #expect(result.mouseReleasePoint == somePoint)
    }

    @Test("fresh release point wins when pending is nil")
    func freshReleasePointWins() {
        let fresh = (mouseReleasePoint: CGPoint?.some(somePoint), grewDownward: Bool?.none, isDoubleClick: false)
        let pending = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.none, isDoubleClick: false)
        let result = mergeGestureAnchor(fresh: fresh, pending: pending)
        #expect(result.mouseReleasePoint == somePoint)
    }

    // --- grewDownward merge ---

    @Test("pending grewDownward=true survives zeroed fresh recompute")
    func pendingGrewDownwardSurvives() {
        let fresh = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.none, isDoubleClick: false)
        let pending = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.some(true), isDoubleClick: false)
        let result = mergeGestureAnchor(fresh: fresh, pending: pending)
        #expect(result.grewDownward == true)
    }

    @Test("pending grewDownward=false survives zeroed fresh recompute")
    func pendingGrewDownwardFalseSurvives() {
        let fresh = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.none, isDoubleClick: false)
        let pending = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.some(false), isDoubleClick: false)
        let result = mergeGestureAnchor(fresh: fresh, pending: pending)
        #expect(result.grewDownward == false)
    }

    @Test("both nil grewDownward → nil")
    func bothNilGrewDownward() {
        let fresh = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.none, isDoubleClick: false)
        let pending = (mouseReleasePoint: CGPoint?.none, grewDownward: Bool?.none, isDoubleClick: false)
        let result = mergeGestureAnchor(fresh: fresh, pending: pending)
        #expect(result.grewDownward == nil)
    }
}

// MARK: - Finding 2: inconclusive-skip guard

/// Unit tests for `shouldSkipInconclusiveFallback` — the pure guard that
/// prevents the expensive `touchDescendants` path from running on every bare
/// click in Electron apps when `probeSelection` returns `.inconclusive`.
@Suite("shouldSkipInconclusiveFallback() — Finding 2 Electron bare-click guard")
struct SkipInconclusiveFallbackTests {

    let somePoint = CGPoint(x: 100, y: 200)

    // --- Cases that SHOULD skip (bare click on mouse-up path) ---

    @Test("fromMouseUp + no release point + not double-click → skip")
    func bareClickMouseUpSkips() {
        #expect(shouldSkipInconclusiveFallback(
            fromMouseUp: true, mouseReleasePoint: nil, isDoubleClick: false
        ) == true)
    }

    // --- Cases that must NOT skip ---

    @Test("fromMouseUp + drag release point → do NOT skip (drag needs capture)")
    func dragMouseUpDoesNotSkip() {
        #expect(shouldSkipInconclusiveFallback(
            fromMouseUp: true, mouseReleasePoint: somePoint, isDoubleClick: false
        ) == false)
    }

    @Test("fromMouseUp + double-click → do NOT skip (word selection)")
    func doubleClickMouseUpDoesNotSkip() {
        #expect(shouldSkipInconclusiveFallback(
            fromMouseUp: true, mouseReleasePoint: nil, isDoubleClick: true
        ) == false)
    }

    @Test("fromMouseUp + drag + double-click → do NOT skip")
    func dragDoubleClickMouseUpDoesNotSkip() {
        #expect(shouldSkipInconclusiveFallback(
            fromMouseUp: true, mouseReleasePoint: somePoint, isDoubleClick: true
        ) == false)
    }

    @Test("passive AX notification path (fromMouseUp=false, no release point) → do NOT skip")
    func passiveAXNotificationDoesNotSkip() {
        #expect(shouldSkipInconclusiveFallback(
            fromMouseUp: false, mouseReleasePoint: nil, isDoubleClick: false
        ) == false)
    }

    @Test("passive AX notification + double-click → do NOT skip")
    func passiveAXDoubleClickDoesNotSkip() {
        #expect(shouldSkipInconclusiveFallback(
            fromMouseUp: false, mouseReleasePoint: nil, isDoubleClick: true
        ) == false)
    }
}

// MARK: - Finding 1: sequence test (state assertion)

/// Exercises the exact sequence described in Finding 1: double-click mouse-up
/// followed by the AX notification arriving within the 80ms window.
/// Asserts that `pendingIsDoubleClick` is still `true` after the notification
/// reschedules — i.e. the merge preserved it through the cancel+reschedule.
///
/// Note: `SelectionPipeline` is constructed but NOT started (no `start()`),
/// so no global event monitors are registered. `handleMouseUp` and
/// `handleSignal` are called directly. Each call schedules a debounce task
/// that would run `captureAndEmit` against the pid after ~80 ms. The test
/// cancels that task via `pipeline.stop()` (deferred immediately after
/// construction) so AX capture never runs and there is no inter-test
/// interference.
@Suite("SelectionPipeline — Finding 1 double-click sequence")
@MainActor
struct SelectionPipelineDoubleClickSequenceTests {

    @Test("pendingIsDoubleClick survives AX notification arriving after double-click mouse-up")
    func doubleClickTagSurvivesTrailingNotification() {
        let pipeline = SelectionPipeline()
        defer { pipeline.stop() }

        // Step 1: double-click mouse-up fires. `handleMouseUp` sets
        // lastMouseUpClickCount=2 and schedules debounce task #1 with
        // pendingIsDoubleClick=true (the anchor merge picks it up).
        pipeline.handleMouseUp(clickCount: 2, location: CGPoint(x: 200, y: 300))

        // Verify the pending state was set by the mouse-up schedule.
        #expect(pipeline.pendingIsDoubleClick == true)

        // Step 2: the word-selection AX notification arrives within the 80ms
        // window (simulated synchronously here). handleSignal calls scheduleCapture
        // again — this cancels task #1 and schedules task #2, recomputing from
        // zeroed state (clickCount=0). The merge must preserve pendingIsDoubleClick=true.
        //
        // NSEvent.pressedMouseButtons is 0 in the test host (no button held),
        // so handleSignal takes the "mouse is up" branch → scheduleCapture.
        // Task #2 is the surviving task; pipeline.stop() (deferred above) cancels it.
        pipeline.handleSignal(SelectionChangedSignal(pid: 1))

        // After the notification reschedules, the pending anchor must still
        // carry isDoubleClick=true. The surviving task #2 would emit with it
        // if not cancelled by stop().
        #expect(pipeline.pendingIsDoubleClick == true,
                "isDoubleClick must survive the trailing AX notification's reschedule")
    }

    @Test("triple-click after double-click clears the pending double-click tag")
    func tripleClickClearsPendingDoubleClickTag() {
        let pipeline = SelectionPipeline()
        defer { pipeline.stop() }

        // Step 1: double-click mouse-up fires. scheduleCapture sets
        // pendingIsDoubleClick=true (clickCount=2, recency guard passes).
        // Schedules debounce task #1.
        pipeline.handleMouseUp(clickCount: 2, location: CGPoint(x: 200, y: 300))

        // Verify the pending tag is set after the double-click.
        #expect(pipeline.pendingIsDoubleClick == true)

        // Step 2: triple-click mouse-up fires within the 80ms window. The fix:
        // handleMouseUp clears pendingIsDoubleClick before recomputing the anchor.
        // clickCount=3 → gestureAnchor returns isDoubleClick=false →
        // merge(false, false)=false. The pending tag must now be false.
        // Cancels task #1 and schedules task #2 (cancelled by stop() on defer).
        pipeline.handleMouseUp(clickCount: 3, location: CGPoint(x: 200, y: 300))

        // A line selection (triple-click) must NOT carry isDoubleClick=true.
        #expect(pipeline.pendingIsDoubleClick == false,
                "triple-click must not inherit the stale double-click tag")
    }

    @Test("pendingIsDoubleClick is false for a bare click followed by a notification")
    func bareClickTagIsNotUpgraded() {
        let pipeline = SelectionPipeline()
        defer { pipeline.stop() }

        // A bare single click (clickCount=1, sub-threshold travel — default
        // lastMouseDownLocation is .zero, upLocation is also near zero).
        // Schedules debounce task #1.
        pipeline.handleMouseUp(clickCount: 1, location: CGPoint(x: 1, y: 0))

        // The AX notification arrives (e.g. caret move from click). Cancels
        // task #1 and schedules task #2 (cancelled by stop() on defer).
        pipeline.handleSignal(SelectionChangedSignal(pid: 1))

        // pendingIsDoubleClick must remain false — we must not upgrade a bare click.
        #expect(pipeline.pendingIsDoubleClick == false)
    }
}

@Suite("ClipboardFallback timing")
@MainActor
struct ClipboardFallbackTimingTests {

    /// Pins the bumped poll ceiling. Large selections in Electron apps can take
    /// longer than the old 250 ms to land; an accidental revert would silently
    /// re-break them.
    @Test("Poll ceiling is 600 ms with an integral step count")
    func pollCeiling() {
        #expect(ClipboardFallback.maxPollDuration == 600_000_000)
        // Ceiling must be an exact multiple of the interval so the step count
        // does not truncate.
        #expect(ClipboardFallback.maxPollDuration % ClipboardFallback.pollInterval == 0)
        #expect(ClipboardFallback.maxPollDuration / ClipboardFallback.pollInterval == 30)
    }
}
