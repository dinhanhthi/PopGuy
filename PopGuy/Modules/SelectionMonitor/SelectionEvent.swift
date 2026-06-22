// SelectionEvent.swift
// PopGuy
//
// Combines SelectionMonitor's signal + TextCaptureEngine into a single
// published stream of SelectionEvents.
//
// This is Phase 2's subscription point: FloatingToolbar subscribes to
// SelectionPipeline.events to know when and where to appear.
//
// Strict-concurrency design:
//   SelectionEvent is @MainActor-confined (not Sendable across actors).
//   Both the producer (SelectionPipeline) and the consumer (FloatingToolbar,
//   Phase 2) run on @MainActor, so cross-actor transfer is never needed.
//   The AsyncStream continuation is stored on @MainActor and called only
//   from @MainActor contexts — no data race.
//
// Buffer policy:
//   The stream uses .bufferingNewest(1): if the consumer is slow and a new
//   selection arrives, only the latest is kept. This is correct for the
//   "show toolbar at latest selection" semantics and prevents unbounded
//   retention of AX elements when no consumer is attached yet (Phase 1).

import AppKit
import ApplicationServices
import Combine

// MARK: - Gesture anchor helper

/// Derives the panel-anchoring inputs from the last mouse gesture. Pure/testable.
/// AppKit Y-up: dragging downward on screen means upLocation.y <= downLocation.y.
///
/// All derived values are computed from a snapshot taken at schedule time, not
/// after the debounce sleep, so new mouse events during the 80ms window cannot
/// corrupt the geometry (Problem B), and a cancelling reschedule recomputes from
/// already-consumed state so a keyboard selection after a double-click yields
/// mouseReleasePoint=nil, isDoubleClick=false (Problem A).
func gestureAnchor(
    downLocation: CGPoint,
    upLocation: CGPoint,
    upTime: Date,
    clickCount: Int,
    now: Date,
    recencyWindow: TimeInterval,
    dragThreshold: CGFloat
) -> (mouseReleasePoint: CGPoint?, grewDownward: Bool?, isDoubleClick: Bool) {
    let recentMouseUp = now.timeIntervalSince(upTime) < recencyWindow
    let isDoubleClick = clickCount == 2 && recentMouseUp
    let dragDistance = hypot(upLocation.x - downLocation.x, upLocation.y - downLocation.y)
    let isDrag = dragDistance >= dragThreshold
    let mouseDriven = recentMouseUp && (isDrag || isDoubleClick)
    let mouseReleasePoint: CGPoint? = mouseDriven ? upLocation : nil
    // Only a real drag has a meaningful direction; a double-click has none (nil → below default).
    let grewDownward: Bool? = (mouseDriven && isDrag) ? (upLocation.y <= downLocation.y) : nil
    return (mouseReleasePoint, grewDownward, isDoubleClick)
}

// MARK: - Finding 1: anchor merge

/// Merges a freshly computed gesture anchor (from zeroed state) with a
/// carry-forward pending anchor (from the same gesture's previous schedule).
/// The richer value wins for each field: a true/non-nil from either source
/// survives the merge. Pure/testable — called by `scheduleCapture`.
///
/// This preserves the double-click tag (and release point / drag direction)
/// when a double-click's own AX notification rescheduled within the 80ms
/// debounce window, causing `scheduleCapture` to recompute from zeroed state.
func mergeGestureAnchor(
    fresh: (mouseReleasePoint: CGPoint?, grewDownward: Bool?, isDoubleClick: Bool),
    pending: (mouseReleasePoint: CGPoint?, grewDownward: Bool?, isDoubleClick: Bool)
) -> (mouseReleasePoint: CGPoint?, grewDownward: Bool?, isDoubleClick: Bool) {
    (
        mouseReleasePoint: fresh.mouseReleasePoint ?? pending.mouseReleasePoint,
        grewDownward: fresh.grewDownward ?? pending.grewDownward,
        isDoubleClick: fresh.isDoubleClick || pending.isDoubleClick
    )
}

// MARK: - Finding 2: inconclusive-skip guard

/// Returns true when the expensive `captureSelection` fallback should be
/// SKIPPED for an `.inconclusive` probe result. Only skips on the mouse-up
/// path when no selection gesture is evident (no drag, no double-click).
/// Pure/testable — called by `captureAndEmit`.
///
/// - Parameters:
///   - fromMouseUp: whether this capture was triggered by a left mouse-up.
///   - mouseReleasePoint: non-nil when a drag of ≥ `dragThreshold` occurred.
///   - isDoubleClick: whether the triggering gesture was a double-click.
///
/// Returns `true` (skip) only when: fromMouseUp AND no release point AND not
/// a double-click — i.e. a bare click on the mouse-up path.
func shouldSkipInconclusiveFallback(
    fromMouseUp: Bool,
    mouseReleasePoint: CGPoint?,
    isDoubleClick: Bool
) -> Bool {
    fromMouseUp && mouseReleasePoint == nil && !isDoubleClick
}

// MARK: - Phase 3: ⌘C clipboard fallback gate

/// Returns true when the ⌘C clipboard fallback should be attempted for an
/// AX-absent result from an allowlisted editor. ALL three conditions must hold
/// to preserve the no-phantom-⌘C invariant on bare clicks, caret moves, and
/// keyboard selections.
///
/// - Parameters:
///   - fromMouseUp: whether this capture was triggered by a left mouse-up.
///   - mouseReleasePoint: non-nil when a real drag of ≥ dragThreshold occurred.
///   - usesEnhancedCapture: true when the source app is in the allowlisted set
///     of Electron/Chromium editors (VSCode, Cursor, etc.).
///
/// Returns `true` only when: mouse-up-driven AND a real drag (not a bare click)
/// AND the source app hides its large selections from AX.
/// Pure/testable — called by `captureAndEmit`.
func shouldAttemptClipboardFallback(
    fromMouseUp: Bool,
    mouseReleasePoint: CGPoint?,
    usesEnhancedCapture: Bool
) -> Bool {
    fromMouseUp && mouseReleasePoint != nil && usesEnhancedCapture
}

// MARK: - Event type

/// A fully-resolved selection event: text, source element, and screen position.
///
/// Isolation: @MainActor — AXUIElement (inside SourceElementRef) is not
/// Sendable, and both producer and consumer live on the main actor. Confining
/// this type to @MainActor is the correct choice; marking it @unchecked
/// Sendable would be unsound here.
@MainActor
struct SelectionEvent {
    /// The selected text. Non-empty.
    let text: String

    /// Reference to the AXUIElement for paste-back in Phase 2.
    let sourceElement: SourceElementRef

    /// Bounding rect of the selection in screen coordinates.
    /// Used by FloatingToolbar to position the panel near the selection.
    /// Nil when the Accessibility API cannot determine it.
    let screenRect: CGRect?

    /// True when this selection originated from a double-click (single word).
    /// Read by the double-click trigger gate in ToolbarController. Explicit
    /// triggers (chord, hotkey) leave this false — they bypass the trigger gate.
    let isDoubleClick: Bool

    /// AppKit screen coords of the mouse-release point when the selection ended
    /// with a left-mouse release; nil for keyboard/chord-invoked selections.
    let mouseReleasePoint: CGPoint?

    /// True when the selection was made by dragging the mouse downward on screen
    /// (panel goes below the pointer); false when dragged upward (panel goes
    /// above); nil for keyboard/chord selections, double-clicks (no drag direction),
    /// or any case where physical drag evidence is absent.
    ///
    /// AppKit is Y-up: "downward on screen" means the release Y is <= the press Y.
    let selectionGrewDownward: Bool?

    init(text: String, sourceElement: SourceElementRef, screenRect: CGRect?, isDoubleClick: Bool = false, mouseReleasePoint: CGPoint? = nil, selectionGrewDownward: Bool? = nil) {
        self.text = text
        self.sourceElement = sourceElement
        self.screenRect = screenRect
        self.isDoubleClick = isDoubleClick
        self.mouseReleasePoint = mouseReleasePoint
        self.selectionGrewDownward = selectionGrewDownward
    }
}

// MARK: - Pipeline

/// Wires together SelectionMonitor + TextCaptureEngine and vends a stream of
/// `SelectionEvent` values.
///
/// AppDelegate retains one instance and calls `start()` once AX is trusted.
@MainActor
final class SelectionPipeline {

    /// Async stream of selection events. Subscribers iterate with `for await`.
    let events: AsyncStream<SelectionEvent>

    // MARK: - Private

    private let continuation: AsyncStream<SelectionEvent>.Continuation
    private let monitor = SelectionMonitor()
    private let engine = TextCaptureEngine()

    /// Clipboard-based fallback capture for drag-selections that AX cannot read
    /// (e.g. large Monaco selections in Cursor/VSCode where probeSelection returns
    /// `.absent` with length=0). Reuses the same implementation that
    /// ToolbarController uses for its hotkey/chord path.
    private let fallback = ClipboardFallback()
    private var cancellables = Set<AnyCancellable>()

    // Debounce: coalesce rapid AX notifications (e.g. dragging to extend a
    // selection fires many events) into one read.
    private var debounceTask: Task<Void, Never>?
    private static let debounceDelay: UInt64 = 80_000_000 // 80 ms

    // Mouse-up deferral: while the user is dragging to select (left button held),
    // defer emission until the button is released so the toolbar appears only at
    // the end of the selection, not mid-drag. `pendingPid` holds the latest
    // signal's pid until mouse-up consumes it. Keyboard selections (Shift+Arrow,
    // Cmd+A) never set the button bit, so they skip this path and emit via the
    // normal debounce.
    private var pendingPid: pid_t?
    private var mouseUpMonitor: Any?

    // Double-click tagging: click count + timestamp of the most recent left
    // mouse-up. A double-click (clickCount == 2) selects a single word, firing
    // kAXSelectedTextChangedNotification just like a drag, so the deferral path
    // already captures it — we only need to know it was a double-click. We
    // correlate by recency rather than strict ordering because the AX
    // notification may arrive just after mouse-up (the deferral path misses it).
    private var lastMouseUpClickCount = 0
    private var lastMouseUpTime: Date = .distantPast
    private var lastMouseUpLocation: CGPoint = .zero
    private static let doubleClickWindow: TimeInterval = 0.6

    // Pending anchor carry-forward: when a double-click's AX notification fires
    // within the 80ms debounce window and reschedules, `scheduleCapture` recomputes
    // the anchor from already-zeroed state and would downgrade `isDoubleClick` to
    // false (Finding 1 race). These fields carry the pending-task's anchor so a
    // rescheduling within the same gesture inherits the correct values. They are
    // cleared when the debounce task completes normally (after the sleep), NOT when
    // cancelled — so a cancel+reschedule within the same gesture sees them.
    // They are also cleared at the TOP of handleMouseUp (every new mouse-up),
    // so a triple-click's third mouse-up resets the stale double-click tag before
    // recomputing. The double-click rescue path (handleSignal) does NOT clear them,
    // so the double-click sequence is unaffected.
    // A subsequent unrelated gesture (post-emit) recomputes from clean state
    // (lastMouseUpTime = .distantPast → recency guard fails → both false/nil).
    // Internal (not private) so the sequence test in PopGuyTests can assert state
    // after handleMouseUp → handleSignal without needing a fake engine.
    var pendingIsDoubleClick = false
    var pendingMouseReleasePoint: CGPoint? = nil
    var pendingGrewDownward: Bool? = nil

    // Mouse-down tracking: capture the press location so we can compute the
    // drag direction (down vs. up) when the mouse is released. Stored on the
    // main actor; both down and up monitors dispatch to @MainActor before writing.
    private var mouseDownMonitor: Any?
    private var lastMouseDownLocation: CGPoint = .zero

    // Minimum pointer travel (points) to count as a deliberate drag vs. a bare click.
    private static let dragThreshold: CGFloat = 3

    // MARK: - Lifecycle

    init() {
        var cont: AsyncStream<SelectionEvent>.Continuation!
        // .bufferingNewest(1): only the latest selection event is buffered.
        // Prevents unbounded AX element retention when no consumer is attached.
        events = AsyncStream(SelectionEvent.self, bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        continuation = cont
    }

    /// Start observing. Safe to call once; subsequent calls are no-ops.
    func start() {
        // Idempotency guard: a second start() would double-subscribe the sink
        // and overwrite monitor tokens, leaking the first global monitor tokens.
        // mouseDownMonitor and mouseUpMonitor are always added/removed in lock-step,
        // so guarding on mouseUpMonitor == nil is sufficient for both.
        guard mouseUpMonitor == nil else { return }

        monitor.selectionChanged
            .sink { [weak self] signal in
                Task { @MainActor [weak self] in
                    self?.handleSignal(signal)
                }
            }
            .store(in: &cancellables)

        // Observe global left mouse-down to record the press location. This is
        // used together with the mouse-up location to compute the drag direction
        // (selectionGrewDownward) for pointer-anchored panel positioning.
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            // Capture synchronously before the Task hop so the location reflects
            // the exact moment of press (same rationale as mouse-up).
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in self?.recordMouseDown(location: location) }
        }

        // Observe global left mouse-up to flush a selection deferred during a
        // drag and to record the release location / click count.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            // Capture both values synchronously, before the Task hop, so they
            // reflect the exact moment of release (not a drifted live read).
            let clickCount = event.clickCount
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleMouseUp(clickCount: clickCount, location: location)
            }
        }

        monitor.start()
    }

    /// Stop observing and finish the event stream.
    /// Terminal: the AsyncStream continuation is finished and this instance is not restartable.
    func stop() {
        monitor.stop()
        cancellables.removeAll()
        debounceTask?.cancel()
        if let token = mouseDownMonitor {
            NSEvent.removeMonitor(token)
            mouseDownMonitor = nil
        }
        if let token = mouseUpMonitor {
            NSEvent.removeMonitor(token)
            mouseUpMonitor = nil
        }
        pendingPid = nil
        pendingIsDoubleClick = false
        pendingMouseReleasePoint = nil
        pendingGrewDownward = nil
        continuation.finish()
    }

    // MARK: - Signal handling

    // Internal (not private) so the sequence test can call handleSignal/handleMouseUp
    // directly and assert `pendingIsDoubleClick` state without needing a fake engine.
    func handleSignal(_ signal: SelectionChangedSignal) {
        // While the left mouse button is held, the user is still dragging to
        // select. Defer the capture until release: stash the pid and let
        // handleMouseUp() flush it. Bit 0 of pressedMouseButtons is the left
        // button. This is read synchronously, so there is no race with a flag.
        if NSEvent.pressedMouseButtons & 0x1 != 0 {
            debounceTask?.cancel()
            pendingPid = signal.pid
            return
        }
        // Mouse is up: any deferred pid is stale (this is a fresh, finished
        // selection — keyboard or post-release). Clear it and capture now.
        pendingPid = nil
        scheduleCapture(pid: signal.pid)
    }

    /// Record the mouse-down location for drag-direction computation.
    private func recordMouseDown(location: CGPoint) {
        lastMouseDownLocation = location
    }

    /// Left mouse button released — attempt capture on every left mouse-up, not
    /// only when a notification already set `pendingPid`.
    ///
    /// The cheap `probeSelection` in `captureAndEmit` filters out bare clicks
    /// (no selection), so driving capture on every mouse-up is safe and is the
    /// fix for large Cursor/Monaco selections where
    /// `kAXSelectedTextChangedNotification` never fires.
    func handleMouseUp(clickCount: Int, location: CGPoint) {
        // A new mouse-up starts a new gesture. Clear the pending anchor so the
        // incoming click count (e.g. triple-click) does not inherit a stale
        // double-click tag left by the previous handleMouseUp. The double-click
        // rescue arrives via handleSignal, which does NOT clear pending — so the
        // double-click sequence (up2 → AX notification) is unaffected.
        pendingIsDoubleClick = false
        pendingMouseReleasePoint = nil
        pendingGrewDownward = nil

        // Record for double-click tagging and release-point anchoring (read by
        // captureAndEmit), regardless of whether a capture was deferred — a
        // double-click's AX notification may arrive just after this mouse-up.
        lastMouseUpClickCount = clickCount
        lastMouseUpTime = Date()
        lastMouseUpLocation = location

        // Use the notification-supplied pid when available (it may differ from
        // the frontmost app if the user fast-switched apps during a drag).
        // Fall back to the frontmost application so every mouse-up can trigger
        // capture even when the AX notification was never delivered (the core
        // fix for large Monaco selections).
        let pid = pendingPid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        pendingPid = nil

        guard let pid else { return }
        scheduleCapture(pid: pid, fromMouseUp: true)
    }

    /// Debounce rapid notifications, then capture and emit.
    ///
    /// Snapshot + consume: gesture state is read synchronously at schedule time
    /// (before the debounce sleep) and the mutable fields are immediately consumed
    /// (reset). This fixes two races:
    ///   • Problem A (original): a cancelling reschedule from a keyboard AX signal
    ///     arriving AFTER the debounce task already emitted recomputes from clean
    ///     state, so a keyboard capture after a double-click correctly yields
    ///     mouseReleasePoint=nil, isDoubleClick=false.
    ///   • Problem A2 (Finding 1): a cancelling reschedule from the double-click's
    ///     own AX notification (within the 80ms window) must NOT downgrade the
    ///     anchor. The pending anchor fields (`pendingIsDoubleClick`,
    ///     `pendingMouseReleasePoint`, `pendingGrewDownward`) carry the in-flight
    ///     anchor across rescheduling, OR'd against the freshly computed anchor so
    ///     the best evidence wins. They are cleared only when the debounce task
    ///     completes (after the sleep) — not in the cancel path — so a
    ///     cancel+reschedule within the same gesture always sees them.
    ///   • Problem B: a new mouse-down during the 80ms debounce window cannot
    ///     corrupt the snapshot because it was taken synchronously before the sleep.
    ///
    /// `fromMouseUp` is forwarded to `captureAndEmit` for diagnostic logging
    /// that distinguishes the mouse-up-driven path from the passive AX-notification
    /// path. It is also used by Finding 2's `.inconclusive` guard.
    private func scheduleCapture(pid: pid_t, fromMouseUp: Bool = false) {
        // Take a synchronous snapshot of gesture state NOW (before creating the Task)
        // so the values are frozen at schedule time, not read after the debounce sleep.
        let fresh = gestureAnchor(
            downLocation: lastMouseDownLocation,
            upLocation: lastMouseUpLocation,
            upTime: lastMouseUpTime,
            clickCount: lastMouseUpClickCount,
            now: Date(),
            recencyWindow: Self.doubleClickWindow,
            dragThreshold: Self.dragThreshold
        )
        // Consume the click-count and timestamp so a subsequent scheduleCapture
        // (e.g. from a keyboard AX signal within the window) recomputes from clean
        // state. The locations are intentionally NOT reset — the recency guard
        // (upTime → .distantPast) makes them irrelevant for the next computation.
        lastMouseUpClickCount = 0
        lastMouseUpTime = .distantPast

        // Finding 1 — merge with pending anchor (in-flight task carry-forward).
        // If a pending anchor already carries a double-click or a release point
        // (from the same gesture's mouse-up schedule that is being cancelled right
        // now), preserve the richer value. The pending fields come from the task
        // being cancelled and are already frozen; the fresh values come from the
        // current recomputation against zeroed state (which would downgrade them).
        let merged = mergeGestureAnchor(
            fresh: (fresh.mouseReleasePoint, fresh.grewDownward, fresh.isDoubleClick),
            pending: (pendingMouseReleasePoint, pendingGrewDownward, pendingIsDoubleClick)
        )
        let mergedIsDoubleClick = merged.isDoubleClick
        let mergedMouseReleasePoint = merged.mouseReleasePoint
        let mergedGrewDownward = merged.grewDownward

        // Update the pending anchor to reflect the merge so the next cancelling
        // reschedule (within this gesture) also has the correct values.
        pendingIsDoubleClick = mergedIsDoubleClick
        pendingMouseReleasePoint = mergedMouseReleasePoint
        pendingGrewDownward = mergedGrewDownward

        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: SelectionPipeline.debounceDelay)
            } catch {
                // Task was cancelled (new signal arrived within window).
                // Do NOT clear the pending anchor here — the replacing schedule
                // needs it to survive the cancel. See Finding 1 note above.
                return
            }
            // Task completed normally: clear the pending anchor before emitting
            // so an unrelated gesture later recomputes from clean state (Problem A).
            self.pendingIsDoubleClick = false
            self.pendingMouseReleasePoint = nil
            self.pendingGrewDownward = nil
            await self.captureAndEmit(
                pid: pid,
                mouseReleasePoint: mergedMouseReleasePoint,
                grewDownward: mergedGrewDownward,
                isDoubleClick: mergedIsDoubleClick,
                fromMouseUp: fromMouseUp
            )
        }
    }

    /// Capture the selection for `pid` and emit a `SelectionEvent`.
    ///
    /// All gesture-derived values (`mouseReleasePoint`, `grewDownward`,
    /// `isDoubleClick`) are precomputed at schedule time from physical evidence
    /// (drag distance + recency). This function does not read any `lastMouse*`
    /// state and does not perform any resets — those happen in `scheduleCapture`.
    ///
    /// `fromMouseUp` is used by:
    ///   - Finding 2's `.inconclusive` guard (skip expensive fallback on bare clicks).
    ///   - Phase 3's ⌘C fallback gate (only attempt on the mouse-up path).
    ///
    /// Phase 3 — ⌘C fallback for AX-absent drag-selections:
    ///   When the probe returns `.absent` (or the subsequent captureSelection
    ///   returns `.emptySelection`) for an allowlisted Electron/Chromium editor
    ///   (VSCode, Cursor, etc.) AND a real drag just ended (mouseReleasePoint != nil),
    ///   the function falls back to a synthetic ⌘C via `ClipboardFallback`.
    ///   This is the fix for large Monaco selections where AX returns length=0
    ///   even though text is selected. See `shouldAttemptClipboardFallback` for
    ///   the gate logic.
    ///
    ///   The function is `async` to accommodate the ⌘C pasteboard-poll wait.
    ///   The fast non-fallback paths (`.present`/`.captured`) have no suspension
    ///   points — making the function async adds no latency to them.
    private func captureAndEmit(
        pid: pid_t,
        mouseReleasePoint: CGPoint?,
        grewDownward: Bool?,
        isDoubleClick: Bool,
        fromMouseUp: Bool = false
    ) async {
        // --- Cheap O(1) probe: gate expensive work without reading the text ---
        // .absent    → confirmed no selection per AX; return immediately for most
        //              apps. For allowlisted Electron/Chromium editors on a real
        //              drag-end, AX returns length=0 even when text IS selected
        //              (proven root cause: large Monaco selection). Apply the Phase 3
        //              ⌘C gate below before returning.
        // .present   → proceed to the full capture + emit below.
        //              NOTE: this re-reads the AX attributes (the probe result is
        //              intentionally not threaded through here). Reads are 0 ms
        //              per Phase 1 measurements.
        // .inconclusive → fall through only when a real selection gesture likely
        //              occurred (drag, double-click, or keyboard/AX path). Skip for
        //              bare clicks on mouse-up-driven paths so Electron apps don't
        //              pay the touchDescendants (≤1 s) cost on every bare click
        //              (Finding 2). Criteria: not a mouse-up OR there is a release
        //              point (drag) OR it is a double-click. Passive AX-notification
        //              path (fromMouseUp=false) is always unchanged.
        let probeResult = engine.probeSelection(from: pid)
        switch probeResult {
        case .absent:
            // Phase 3: before giving up, check whether this is a drag-end in an
            // allowlisted editor — if so, AX may just be reporting length=0 for a
            // large selection that it cannot expose. Attempt ⌘C capture.
            if shouldAttemptClipboardFallback(
                fromMouseUp: fromMouseUp,
                mouseReleasePoint: mouseReleasePoint,
                usesEnhancedCapture: TextCaptureEngine.usesEnhancedCapture(pid: pid)
            ) {
                await captureAndEmitViaClipboard(
                    pid: pid,
                    mouseReleasePoint: mouseReleasePoint,
                    grewDownward: grewDownward,
                    isDoubleClick: isDoubleClick
                )
                return
            }
            // Some readers (Apple Books) report .absent on the focused container
            // even though the selection lives on descendant AXStaticText elements.
            // On a deliberate selection gesture (drag or double-click) in a
            // non-enhanced app, descend the tree via captureSelection before
            // giving up. Bare clicks still return here, preserving the cheap-probe
            // optimization (no descend on every click).
            guard fromMouseUp,
                  mouseReleasePoint != nil || isDoubleClick,
                  !TextCaptureEngine.usesEnhancedCapture(pid: pid) else {
                return
            }
            // Fall through to captureSelection below (descending capture).
        case .present:
            break
        case .inconclusive:
            // Finding 2 — skip the expensive captureSelection fallback for bare
            // clicks in the mouse-up-driven path. A bare click produces
            // fromMouseUp=true + mouseReleasePoint=nil + isDoubleClick=false.
            // A drag produces mouseReleasePoint != nil (distance ≥ dragThreshold).
            // A double-click produces isDoubleClick=true.
            // Keyboard/AX path has fromMouseUp=false — always falls through.
            if shouldSkipInconclusiveFallback(
                fromMouseUp: fromMouseUp,
                mouseReleasePoint: mouseReleasePoint,
                isDoubleClick: isDoubleClick
            ) {
                return
            }
        }

        switch engine.captureSelection(from: pid) {
        case .captured(let selection):
            let event = SelectionEvent(
                text: selection.text,
                sourceElement: selection.sourceElement,
                screenRect: selection.screenRect,
                isDoubleClick: isDoubleClick,
                mouseReleasePoint: mouseReleasePoint,
                selectionGrewDownward: grewDownward
            )
            continuation.yield(event)

        case .emptySelection, .unavailable:
            // AX returned no usable selection text:
            //   • .emptySelection — AX API is accessible but the selection is absent or empty.
            //   • .unavailable   — AX cannot read the attribute at all (e.g. WKWebView/Electron
            //                      web content where kAXSelectedTextAttribute is unsupported).
            //
            // In both cases, for allowlisted Electron/Chromium editors on a real drag-end,
            // AX may legitimately return nothing even when text IS selected (large Monaco
            // selection where AX exposes length=0, or an unsupported attribute). Attempt the
            // restore-safe ⌘C fallback when the gate passes.
            //
            // The gate (shouldAttemptClipboardFallback) requires ALL of:
            //   1. fromMouseUp=true  — passive AX-notification path (fromMouseUp=false) is
            //      excluded: it fires on every click, caret move, and keystroke, so a
            //      speculative ⌘C there would make the host emit NSBeep and flash the Edit menu
            //      (the "phantom ⌘C" beep).
            //   2. mouseReleasePoint != nil — bare clicks are excluded (no drag, no selection).
            //   3. usesEnhancedCapture=true — non-allowlisted apps are excluded: falling back
            //      on them would capture whatever is already in the clipboard.
            // Only a real drag-end in an allowlisted editor passes all three.
            if shouldAttemptClipboardFallback(
                fromMouseUp: fromMouseUp,
                mouseReleasePoint: mouseReleasePoint,
                usesEnhancedCapture: TextCaptureEngine.usesEnhancedCapture(pid: pid)
            ) {
                await captureAndEmitViaClipboard(
                    pid: pid,
                    mouseReleasePoint: mouseReleasePoint,
                    grewDownward: grewDownward,
                    isDoubleClick: isDoubleClick
                )
            }
        }
    }

    /// Attempt text capture via a synthetic ⌘C and emit a SelectionEvent when
    /// something non-empty lands on the pasteboard.
    ///
    /// Called only from `captureAndEmit` when `shouldAttemptClipboardFallback`
    /// returns true — i.e. a real mouse drag just ended in an allowlisted editor
    /// whose AX read returned no selection.
    ///
    /// Clipboard hygiene is handled by `ClipboardFallback.capture`: it saves the
    /// current pasteboard, posts ⌘C, polls for the changeCount to advance, reads
    /// the string, then IMMEDIATELY restores the original contents. PopGuy never
    /// leaves a synthetic ⌘C copy behind.
    ///
    /// Positioning: emits `screenRect: nil` so the toolbar anchors to the mouse
    /// pointer via `mouseReleasePoint` (ToolbarController.show already handles nil rect).
    private func captureAndEmitViaClipboard(
        pid: pid_t,
        mouseReleasePoint: CGPoint?,
        grewDownward: Bool?,
        isDoubleClick: Bool
    ) async {
        guard let text = await fallback.capture(from: pid),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            // Nothing useful copied (scroll-drag with no selection, or the
            // pasteboard did not change). No toolbar.
            return
        }

        // AX gave no rect for this selection — anchor to the mouse pointer.
        // The fallback only fires inside an allowlisted editor (see doc above), so
        // the source is editable — show "Paste back".
        let sourceElement = SourceElementRef(element: AXUIElementCreateApplication(pid), isEditable: true)
        let event = SelectionEvent(
            text: text,
            sourceElement: sourceElement,
            screenRect: nil,
            isDoubleClick: isDoubleClick,
            mouseReleasePoint: mouseReleasePoint,
            selectionGrewDownward: grewDownward
        )
        continuation.yield(event)
    }
}
