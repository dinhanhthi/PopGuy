// ToolbarController.swift
// PopGuy
//
// @MainActor controller that:
//   • Subscribes to SelectionPipeline.events via `for await` in a Task.
//   • Positions and shows FloatingPanel near each selection event.
//   • Auto-dismisses on outside click, Escape, or next selection event while hidden.
//   • Hosts a SwiftUI ToolbarView inside the panel via NSHostingView.
//
// Event monitor tokens are stored and removed on hide() to prevent leaks.
//
// Strict concurrency:
//   Everything is @MainActor. NSPanel, NSHostingView, NSEvent monitors, and
//   CGRect math all run on the main actor. The `for await` consumption Task is
//   @MainActor so SelectionEvent (also @MainActor) flows without Sendable casts.

import AppKit
import ApplicationServices
import Combine
import SwiftUI
import os

/// Returns true when an incoming text-select event should be IGNORED because it
/// is a re-entrant duplicate of the selection already being acted upon: the
/// toolbar is showing, an action has been dispatched (loading/result/error on
/// screen), and the new text matches the current capture. Suppressing it keeps
/// the in-progress action's view state and panel position stable. A genuinely
/// different selection (text differs) is NOT ignored, so re-showing for new text
/// still works. Pure/testable.
func shouldIgnoreReentrantSelection(isShowing: Bool, actionInProgress: Bool, newText: String, currentText: String) -> Bool {
    isShowing && actionInProgress && newText == currentText
}

/// Returns true when the text-select trigger may show the toolbar for a selection.
/// With `editableOnly` on, only selections inside an editable text area pass —
/// read-only text (web pages, chat messages) is ignored. Pure/testable.
func shouldShowOnTextSelect(isEditable: Bool, editableOnly: Bool) -> Bool {
    !editableOnly || isEditable
}

/// Returns true when a key press in the source app should re-check whether the
/// selection is still there (and close the toolbar if it is gone).
/// `selectionHiddenFromProbe` is true when the cheap AX probe may report the
/// selection as absent while it is there (Monaco editors, whose large selections
/// AX hides, or a probe that did not see the selection when the toolbar showed,
/// e.g. Apple Books): then a shortcut that keeps the selection (⌘C) or a Shift
/// selection key would close the toolbar, so those keys are skipped. Pure/testable.
nonisolated func shouldCheckSelectionClearedOnKey(
    keyCode: UInt16,
    characters: String?,
    flags: NSEvent.ModifierFlags,
    selectionHiddenFromProbe: Bool
) -> Bool {
    guard selectionHiddenFromProbe else { return true }
    if flags.contains(.command) { return false }
    return !isKeyboardSelectionKey(keyCode: keyCode, characters: characters, flags: flags)
}

@MainActor
final class ToolbarController {

    private static let positionLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PopGuy", category: "positioning")

    // MARK: - Dependencies

    private let pipeline: SelectionPipeline
    private let settings: SettingsStore
    private let keychain: KeychainManager
    private let panel: FloatingPanel
    private let viewModel: ToolbarViewModel
    let outputHandler: OutputHandler   // Internal so AppDelegate can reach it if needed.

    /// Owns the speak coordinator for the controller's lifetime; the view model holds a weak ref.
    private let speakCoordinator: SpeakCoordinator

    /// Owns the script action engine for the controller's lifetime; the view model holds a weak ref.
    private let scriptActionEngine: ScriptActionEngine

    /// On-demand capture engine for hotkey-triggered actions when the toolbar is hidden.
    private let captureEngine = TextCaptureEngine()

    /// Synthetic-⌘C fallback for AX-blind apps (WKWebView/Electron), used ONLY on
    /// explicit user triggers (chord/hotkey). Unlike the passive SelectionPipeline
    /// — which must never synthesize ⌘C because it fires on every caret move and
    /// would beep on no-op Copies — an explicit invocation implies the user has a
    /// real selection, so the Copy lands and does not beep.
    private let fallback = ClipboardFallback()

    /// Called when the user taps the Settings button. Provided by AppDelegate.
    private let onOpenSettings: (() -> Void)?

    // MARK: - State

    private var isShowing: Bool = false
    private var pipelineTask: Task<Void, Never>?

    /// Stored so hide() can cancel any in-flight stream (I-E).
    private weak var actionHandler: (any ToolbarActionHandling)?

    // NSEvent monitor tokens — removed on hide() to avoid leaking handlers.
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    /// Makes the panel key when a result offering the Enter action lands, so Enter
    /// reaches the toolbar instead of the source app ("Enter on a result").
    private var enterKeySubscription: AnyCancellable?

    /// The pending "is the selection still there?" check after a key press in the
    /// source app. Cancelled by the next key press and by hide().
    private var selectionClearedCheck: Task<Void, Never>?

    /// True when the AX probe saw the selection as the toolbar showed: only then
    /// is a later "absent" trusted for every key (see `shouldCheckSelectionClearedOnKey`).
    private var selectionProbeConfirmed = false

    /// Visible frame of the display that best contains the current selection.
    /// Cached at show() so content-size changes (reposition(forContentSize:)) can
    /// re-clamp the panel without recomputing screen geometry.
    private var currentScreenFrame: CGRect?

    /// True while the panel still has the logo card's size ("Show logo only").
    /// The panel keeps it after hide(), so the next full presentation must not
    /// position itself from `panel.frame.size`.
    private var panelHoldsCollapsedSize = false

    /// True while the panel has the Menu style's menu size. Like
    /// `panelHoldsCollapsedSize`, the next bar presentation measures the bar
    /// instead of positioning itself from `panel.frame.size`.
    private var panelHoldsMenuSize = false

    /// Set when the panel is pre-sized for content that has not laid out yet
    /// (logo → bar, logo → menu, menu → bar, a fresh menu): the hosting view's
    /// size before the switch. Layout reports of that stale size are skipped
    /// until a different size arrives, so they never resize the panel back.
    private var staleLayoutSize: CGSize?

    /// The inputs Bar style would pass to `panelOrigin` for the current
    /// presentation. Saved when the menu (or its logo card) shows, so a menu pick
    /// lands the horizontal card exactly where Bar style would have put it.
    private struct BarPlacement {
        let selectionRect: CGRect
        let cursor: CGPoint?
        let grewDownward: Bool?
        let mouse: CGPoint
        let screenFrame: CGRect
    }
    private var savedBarPlacement: BarPlacement?

    /// True once an action was picked from the menu (the card switched to the
    /// bar). Guards the picked card against trailing same-text events, like an
    /// expanded logo card.
    private var pickedFromMenu = false

    /// The toolbar's hosting view (the More actions row frame is reported in
    /// its space). Owned by the panel's content view.
    private weak var toolbarHostingView: NSView?

    /// Menu style: the More actions submenu in a child panel.
    private let submenuPresenter: ToolbarSubmenuPresenter

    /// The hosting view is pinned top-leading, or top-trailing after a leftward
    /// expansion from the logo card, so the logo stays put while the panel grows.
    private var hostingLeadingConstraint: NSLayoutConstraint?
    private var hostingTrailingConstraint: NSLayoutConstraint?

    // MARK: - Dimensions

    /// Initial panel frame. SwiftUI's fixedSize() drives actual sizing.
    private static let initialPanelSize = CGSize(width: 280, height: 50)

    // MARK: - Init

    init(
        pipeline: SelectionPipeline,
        settings: SettingsStore,
        keychain: KeychainManager = KeychainManager(),
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.pipeline = pipeline
        self.settings = settings
        self.keychain = keychain
        self.onOpenSettings = onOpenSettings
        self.viewModel = ToolbarViewModel()
        self.outputHandler = OutputHandler()
        self.speakCoordinator = SpeakCoordinator(keychain: keychain)
        self.scriptActionEngine = ScriptActionEngine()
        self.submenuPresenter = ToolbarSubmenuPresenter(viewModel: viewModel)

        // Build the panel.
        let initialFrame = CGRect(origin: .zero, size: ToolbarController.initialPanelSize)
        self.panel = FloatingPanel(
            contentRect: initialFrame,
            styleMask: [],  // FloatingPanel.init overrides the mask
            backing: .buffered,
            defer: false
        )

        // Host the SwiftUI view. The view reports its measured size back via the
        // onContentResize closure. The closures are assigned after init because
        // they capture `self`.
        let toolbarView = ToolbarView(
            viewModel: viewModel,
            outputHandler: outputHandler,
            // Panel sizing is driven by the hosting view's layout callback below
            // (IntrinsicHostingView.onContentSizeChange), not by this closure.
            onContentResize: { _ in },
            onOpenSettings: { [weak self] in
                self?.onOpenSettings?()
                self?.hide()
            },
            onIgnoreApp: { [weak self] in
                guard let self else { return }
                if let bundleID = viewModel.sourceBundleID {
                    settings.addIgnoredApp(bundleID: bundleID)
                }
                self.hide()
            },
            onIgnoreDomain: { [weak self] in
                guard let self else { return }
                if let domain = viewModel.sourceDomain {
                    settings.addIgnoredDomain(domain)
                }
                self.hide()
            },
            onDismiss: { [weak self] in
                self?.hide()
            },
            onDisableCloseConfirmation: { [weak self] in
                guard let self else { return }
                self.settings.confirmCloseAfterResult = false
                self.hide()
            },
            onActivatePromptInput: { [weak self] in
                self?.activatePromptInput()
            }
        )
        // The hosting view sizes itself to the SwiftUI content (intrinsic) and is
        // pinned top-leading inside a plain container. This is what keeps the
        // toolbar from bouncing while the result area appears or streams: a
        // hosting view that fills the panel would let NSHostingView vertically
        // CENTER the card whenever the panel's bounds briefly differ from the
        // card's size during a resize. Sizing to intrinsic + top-leading means the
        // content always fills its own bounds (never centered) and the action bar's
        // top edge stays put while the panel grows downward.
        let hostingView = IntrinsicHostingView(rootView: AnyView(toolbarView))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        toolbarHostingView = hostingView
        // Resize the panel to the content whenever the hosting view re-sizes
        // itself. Deferred to the next runloop tick so we never mutate the window
        // frame in the middle of its own layout pass.
        hostingView.onContentSizeChange = { [weak self] size in
            guard size.width > 0, size.height > 0 else { return }
            DispatchQueue.main.async { self?.reposition(forContentSize: size) }
        }
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear
        container.addSubview(hostingView)
        let leading = hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        hostingLeadingConstraint = leading
        hostingTrailingConstraint = hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            leading,
        ])
        panel.contentView = container

        // Bind the coordinator once — the Combine subscription is persistent.
        viewModel.bindSpeakCoordinator(speakCoordinator)

        // The panel is non-activating: after a hotkey-triggered action it is not
        // key, so Enter would go to the source app and replace its selection with a
        // newline. Take the keyboard when a result lands that the "Enter on a
        // result" action applies to, and only while the source app is frontmost:
        // the user may have switched apps while the action ran, and Enter must not
        // act on a background app. `$actionState` publishes before the stored value
        // changes; the hop lets it (and the source element) settle first.
        enterKeySubscription = viewModel.$actionState
            .map { state -> Bool in
                if case .result = state { return true }
                return false
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isResult in
                guard isResult, let self, self.enterAction != nil else { return }
                self.panel.makeKey()
            }

        // Bind the script action engine and output handler so the view model can
        // dispatch scriptable actions and deliver their output without going through
        // ActionEngine. Both are weak refs in the VM; the controller holds the strong.
        viewModel.scriptActionEngine = scriptActionEngine
        viewModel.outputHandler = outputHandler

        // Scriptable actions with no in-toolbar result (e.g. Reveal in Finder, Open URL)
        // dismiss the toolbar once they finish — nothing is left to interact with.
        viewModel.onRequestDismiss = { [weak self] in
            self?.hide()
        }

        // "Show logo only" mode: a click on the logo card expands the full toolbar
        // out of the logo. Pure state + layout work, so the click reacts at once.
        viewModel.onExpandFromLogo = { [weak self] in
            self?.expandFromLogo(animated: true, opensMenu: true)
        }

        // "Menu" toolbar style: a menu (or submenu) row runs its action in the
        // horizontal card; hovering More actions opens the submenu beside the menu.
        viewModel.onMenuPick = { [weak self] id in
            self?.handleMenuPick(id)
        }
        viewModel.onMenuSubmenuHover = { [weak self] rowFrame in
            self?.updateSubmenu(moreRowFrame: rowFrame)
        }
    }

    // MARK: - Lifecycle

    /// Inject an action handler (Phase 3). Called after init, before start().
    func setActionHandler(_ handler: any ToolbarActionHandling) {
        viewModel.actionHandler = handler
        actionHandler = handler
    }

    /// Show the toolbar for the currently selected text without running any action.
    ///
    /// Called by the Cmd+C+C chord (or its replacement shortcut) to present the
    /// idle toolbar. Bypasses the `triggerOnSelectEnabled` gate — the chord is
    /// always available when `triggerChordEnabled` is true, regardless of whether
    /// the text-select trigger is on. The ignored-apps gate inside `handleEvent`
    /// still applies.
    ///
    /// Capture strategy: Accessibility API first; on `.unavailable` (AX-blind
    /// apps like WKWebView/Electron) fall back to a synthetic ⌘C. The AX path
    /// stays synchronous; only the fallback defers onto a Task (it polls the
    /// pasteboard). `.emptySelection` is a no-op — the user has nothing selected.
    func showToolbarForCurrentSelection(preChordClipboard: PasteboardSnapshot? = nil) {
        guard !isShowing else {
            restorePreChordClipboard(preChordClipboard)
            return
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            restorePreChordClipboard(preChordClipboard)
            return
        }
        switch captureEngine.captureSelection(from: pid) {
        case .captured(let sel):
            handleEvent(SelectionEvent(
                text: sel.text,
                sourceElement: sel.sourceElement,
                screenRect: sel.screenRect
            ))
            restorePreChordClipboard(preChordClipboard)
        case .emptySelection:
            restorePreChordClipboard(preChordClipboard)
        case .unavailable:
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isShowing, let event = await self.fallbackCaptureEvent(pid: pid) {
                    self.handleEvent(event)
                }
                // Restore AFTER the clipboard fallback finishes (it snapshots and
                // restores the post-⌘C board internally) so the pre-chord contents
                // win the final write.
                self.restorePreChordClipboard(preChordClipboard)
            }
        }
    }

    /// Restore the user's pre-chord clipboard a short delay after capture, undoing
    /// both the user's own ⌘C+⌘C clobber and any synthetic ⌘C from the fallback.
    /// The delay lets the second real ⌘C and the fallback's synthetic copy settle
    /// first. Residual race (same class as ClipboardFallback/OutputHandler): the
    /// restore is changeCount-blind, so a deliberate copy the user makes inside
    /// the ~300 ms window is overwritten by the pre-chord contents. Bounded by the
    /// window and accepted. No-op when `snapshot` is nil (non-chord triggers never
    /// clobber the board).
    private func restorePreChordClipboard(_ snapshot: PasteboardSnapshot?) {
        guard let snapshot else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms
            snapshot.restore(to: NSPasteboard.general)
        }
    }

    /// Trigger an action identified by an ActionIdentifier.
    ///
    /// Called by HotkeyManager when a global shortcut fires, or by the
    /// Cmd+C+C chord closure. Works when the toolbar is either hidden or showing:
    ///
    /// - If the toolbar is hidden, an on-demand capture is attempted for the
    ///   frontmost application (AX first, synthetic-⌘C fallback for AX-blind
    ///   apps). If text is found the toolbar is shown (via handleEvent) and the
    ///   action dispatched. If AX reports an empty selection the call is a
    ///   graceful no-op.
    /// - If the toolbar is already showing, the action is dispatched against the
    ///   already-captured text without an additional AX round-trip.
    func triggerAction(for id: ActionIdentifier, customActions: [CustomAction]) {
        // Already showing — dispatch against the existing capture (no round-trip).
        if isShowing {
            guard !viewModel.capturedText.isEmpty else { return }
            dispatchAction(for: id, customActions: customActions)
            return
        }

        // On-demand capture for the frontmost app's focused element.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        switch captureEngine.captureSelection(from: pid) {
        case .captured(let sel):
            showThenDispatch(
                SelectionEvent(text: sel.text, sourceElement: sel.sourceElement, screenRect: sel.screenRect),
                id: id,
                customActions: customActions
            )
        case .emptySelection:
            return
        case .unavailable:
            // AX-blind app — defer onto a Task for the pasteboard-polling fallback.
            Task { @MainActor [weak self] in
                guard let self, !self.isShowing,
                      let event = await self.fallbackCaptureEvent(pid: pid) else { return }
                self.showThenDispatch(event, id: id, customActions: customActions)
            }
        }
    }

    /// Route a captured event through `handleEvent` (which shows the panel and
    /// populates the view model), then dispatch the action if the panel actually
    /// surfaced with non-empty text.
    private func showThenDispatch(_ event: SelectionEvent, id: ActionIdentifier, customActions: [CustomAction]) {
        // Route through handleEvent so enabled-flags, targetLanguage, customActions
        // are all populated consistently with the normal pipeline path.
        // A per-action hotkey skips the logo card ("Show logo only" mode): the full
        // toolbar shows at its normal position and runs the action.
        handleEvent(event, startsCollapsed: false)
        // handleEvent shows the panel and populates viewModel; if no actions are
        // enabled it returns early without showing, so guard here.
        guard isShowing, !viewModel.capturedText.isEmpty else { return }
        dispatchAction(for: id, customActions: customActions)
    }

    /// Inject OCR-extracted text into the toolbar pipeline as if it were a fresh
    /// selection. The source is not an editable AX element (the text came from
    /// pixels), so `isEditable` is false — the toolbar offers Copy only, never
    /// paste-back. `anchorPoint` is the capture's mouse-up location in GLOBAL
    /// QUARTZ coordinates (top-left origin, y down, as produced by the region
    /// overlay); it is converted to AppKit coords here for pointer anchoring.
    func handleOCRCapture(text: String, anchorPoint quartzAnchor: CGPoint, image: CGImage) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Quartz point → AppKit point via the existing rect flip (zero-size rect).
        let appKitAnchor = flipToAppKit(CGRect(origin: quartzAnchor, size: .zero)).origin
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide(), isEditable: false)
        let event = SelectionEvent(
            text: trimmed,
            sourceElement: ref,
            screenRect: nil,
            isDoubleClick: false,
            mouseReleasePoint: appKitAnchor,
            selectionGrewDownward: nil
        )
        // OCR always shows the full toolbar, even in "Show logo only" mode.
        handleEvent(event, startsCollapsed: false)
        // handleEvent (via viewModel.update) clears any stale OCR preview first;
        // only set it here, after the panel has actually surfaced, so a
        // no-actions-enabled early-return in handleEvent never leaves a preview
        // set on a toolbar that never showed.
        guard isShowing else { return }
        // Give the NSImage the capture's pixel dimensions as its size so the
        // preview view can compute the correct aspect ratio.
        viewModel.ocrPreviewImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Synthetic-⌘C fallback capture for explicit triggers in AX-blind apps.
    /// Returns a `SelectionEvent` (no screen rect — AX gave us no geometry) or
    /// nil when nothing was copied. Safe to synthesize ⌘C here: the caller only
    /// reaches this on an explicit user invocation, where a real selection exists.
    private func fallbackCaptureEvent(pid: pid_t) async -> SelectionEvent? {
        guard let text = await fallback.capture(from: pid), !text.isEmpty else { return nil }
        let ref = SourceElementRef(element: AXUIElementCreateApplication(pid))
        return SelectionEvent(text: text, sourceElement: ref, screenRect: nil)
    }

    /// Dispatch a built-in or custom action against the currently-captured text.
    /// Gates built-in dispatch on the enabled flags here — the single chokepoint
    /// both the hotkey and chord paths route through. Without this, a hotkey
    /// bound to a now-disabled built-in still fires it whenever the toolbar is
    /// shown (because some OTHER action is enabled). Custom actions re-check isEnabled.
    private func dispatchAction(for id: ActionIdentifier, customActions: [CustomAction]) {
        // A per-action hotkey always shows the full toolbar: if only the logo card
        // is showing ("Show logo only" mode), it expands first. Likewise an open
        // menu ("Menu" style) turns into the bar before the action runs.
        expandFromLogo(animated: false)
        if viewModel.showsMenu { switchMenuToBar() }
        switch id {
        case .builtin(.improve):
            guard settings.improveEnabled else { return }
            viewModel.triggerImprove()
        case .builtin(.shorten):
            guard settings.shortenEnabled else { return }
            viewModel.triggerShorten()
        case .builtin(.proofread):
            guard settings.proofreadEnabled else { return }
            viewModel.triggerProofread()
        case .builtin(.translate):
            guard settings.translateEnabled else { return }
            viewModel.triggerTranslate()
        case .builtin(.prompt):
            guard settings.promptEnabled else { return }
            viewModel.triggerPromptInput()
            activatePromptInput()
        case .speak:
            guard settings.speakEnabled else { return }
            viewModel.triggerSpeak(accent: nil)
        case .dictionary:
            guard settings.dictionaryConfig.isEnabled else { return }
            viewModel.triggerDictionary()
        case .custom(let uuid):
            if let action = customActions.first(where: { $0.id == uuid && $0.isEnabled }) {
                viewModel.triggerCustomAction(action)
            }
        }
    }

    /// Start consuming pipeline events. Call once after init.
    func start() {
        pipelineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.pipeline.events {
                // Master kill switch: suppress every automatic trigger when off.
                guard self.settings.popGuyEnabled else { continue }
                // Trigger gate: text-select path only — not the chord.
                // Double-click trigger active (a double-click selects a single word):
                // run its assigned default action directly — reusing the captured
                // event, no re-capture — or show the toolbar when none is assigned.
                if event.isDoubleClick && self.settings.triggerDoubleClickEnabled {
                    // Assigning a default action is feature-flagged —
                    // otherwise fall back to showing the toolbar regardless of any
                    // stored assignment.
                    if ToolbarLimits.doubleClickActionFeatureEnabled,
                       let assigned = self.settings.doubleClickAssignedAction {
                        self.showThenDispatch(event, id: assigned, customActions: self.settings.customActions)
                    } else {
                        self.handleEvent(event)
                    }
                    continue
                }
                // Otherwise fall back to the text-select trigger. A range selection
                // (drag/keyboard, many words) is never a double-click, so it fires
                // here even when the double-click trigger is also enabled; a
                // double-click also lands here when the double-click trigger is off.
                // The editable-only option applies to this path alone, so the
                // chord, hotkeys, and the double-click trigger above are unaffected.
                guard self.settings.triggerOnSelectEnabled,
                      shouldShowOnTextSelect(
                          isEditable: event.sourceElement.isEditable,
                          editableOnly: self.settings.triggerOnSelectEditableOnly
                      ) else { continue }
                self.handleEvent(event)
            }
        }
    }

    /// Stop consuming events and hide the panel.
    func stop() {
        pipelineTask?.cancel()
        pipelineTask = nil
        hide()
    }

    // MARK: - Event handling

    /// - Parameter startsCollapsed: false for explicit triggers that must show the
    ///   full toolbar (per-action hotkeys, OCR) even in "Show logo only" mode.
    private func handleEvent(_ event: SelectionEvent, startsCollapsed: Bool = true) {
        guard !event.text.isEmpty else { return }

        // Presentation guard: once the toolbar is showing AND an action has been
        // dispatched (loading / result / error on screen), a re-entrant event for
        // the SAME selection must not reset the view model (losing the loading or
        // result state) or reposition the panel. Such a duplicate arrives from the
        // passive pipeline (e.g. a trailing AX notification or a mouse-up while the
        // user interacts with the toolbar). The chord path is unaffected — it never
        // routes through here. A genuinely different selection still re-shows.
        // "In progress" must also cover the Speak action, which is orthogonal to
        // `actionState` (it never sets it). While speak is loading/playing OR the
        // "Listen again" affordance is on screen (mirrors the speakArea visibility
        // condition `speakPhase != .idle || canReplaySpeak`), a trailing same-text
        // event — e.g. the mouse-up from clicking the Speak button — must NOT
        // re-present the toolbar, which would stop playback and reposition the panel.
        let speakInProgress = viewModel.speakPhase != .idle || viewModel.canReplaySpeak
        // In "Show logo only" mode, a toolbar the user already expanded also counts
        // as in progress: the mouse-up from the logo click must not re-collapse it.
        let expandedFromLogo = settings.showLogoOnly && isShowing && !viewModel.isCollapsed
        // "Menu" style: an open menu, and the card an action was picked into,
        // count as in progress too, so a trailing event never re-presents them.
        let menuInProgress = isShowing && (viewModel.showsMenu || pickedFromMenu)
        if shouldIgnoreReentrantSelection(
            isShowing: isShowing,
            actionInProgress: viewModel.actionState != .idle || speakInProgress || expandedFromLogo || menuInProgress,
            newText: event.text,
            currentText: viewModel.capturedText
        ) {
            return
        }

        // T6.3 ignored-apps gate — shared across ALL paths (text-select + chord).
        // Read the frontmost app ONCE here (before showing the panel) so the bundle
        // ID is always the source app, not PopGuy (the borderless panel never becomes
        // the frontmost application).
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Never treat PopGuy itself as the source app (e.g. when the Settings window is
        // frontmost and the chord fires) — that would let "Ignore this app" disable PopGuy.
        let sourceBundleID = (frontmostBundleID == Bundle.main.bundleIdentifier) ? nil : frontmostBundleID
        if let bundleID = sourceBundleID, settings.isIgnored(bundleID: bundleID) {
            return
        }

        var sourceDomain: String? = nil
        // Only read the browser URL when the user has opted into the ignored-domains
        // feature. While disabled we never send the Apple Event, so macOS never
        // prompts for the Automation permission and sourceDomain stays nil (which
        // also hides the "Ignore this site" toolbar button).
        if settings.ignoredDomainsEnabled,
           let bundleID = sourceBundleID, BrowserURLReader.isSupportedBrowser(bundleID: bundleID) {
            // The currentHost call runs for every supported browser even when
            // ignoredDomains is empty, because sourceDomain must be populated for
            // the "Ignore this site" toolbar button to appear. If latency becomes
            // perceptible, the documented follow-up is a per-(pid, window) cache.
            sourceDomain = BrowserURLReader.currentHost(forBundleID: bundleID)
            if let host = sourceDomain, settings.isIgnoredDomain(host: host) {
                return
            }
        }

        // I-C/I-D: reflect CURRENT settings on each presentation.
        let improveEnabled   = settings.improveEnabled
        let shortenEnabled   = settings.shortenEnabled
        let proofreadEnabled = settings.proofreadEnabled
        let translateEnabled = settings.translateEnabled
        let promptEnabled    = settings.promptEnabled

        // If no actions are enabled (built-in or custom), don't show the toolbar.
        let hasCustom = settings.customActions.contains(where: \.isEnabled)
        guard improveEnabled || shortenEnabled || proofreadEnabled || translateEnabled || promptEnabled || hasCustom || settings.speakEnabled || settings.dictionaryConfig.isEnabled else { return }

        viewModel.update(
            text: event.text,
            sourceElement: event.sourceElement,
            screenRect: event.screenRect,
            sourceBundleID: sourceBundleID,
            sourceDomain: sourceDomain
        )

        // I-C: set default target language from settings (falls back to .english for unknown codes).
        viewModel.targetLanguage = TargetLanguage(bcp47: settings.defaultTargetLanguage)
        viewModel.translateUsesModel = settings.translateConfig.providerKind.usesModel
        viewModel.dictionaryTargetLanguage = TargetLanguage(bcp47: settings.dictionaryConfig.definitionLanguage)

        // I-D: push enabled flags into the view model so ToolbarView can conditionally render.
        viewModel.improveEnabled      = improveEnabled
        viewModel.shortenEnabled      = shortenEnabled
        viewModel.proofreadEnabled    = proofreadEnabled
        viewModel.translateEnabled    = translateEnabled
        viewModel.promptEnabled       = promptEnabled
        viewModel.dictionaryEnabled   = settings.dictionaryConfig.isEnabled

        // Thread enabled custom actions into the view model. Cloud TTS is always
        // allowed here; the provider still requires a configured API key.
        viewModel.cloudTTSAllowed = true
        let enabledCustom = settings.customActions.filter(\.isEnabled)
        viewModel.customActions = CustomAction.visible(enabledCustom, forSelection: event.text)

        // Push the result font size so ToolbarView renders at the configured scale.
        viewModel.resultFontSize = settings.resultFontSize
        viewModel.toolbarZoom = settings.toolbarZoom
        viewModel.includeFontInZoom = settings.zoomIncludesFontSize
        viewModel.preserveFormatting = settings.preserveFormatting

        // Speak: copy enabled flag, settings, and cloud TTS config per presentation.
        viewModel.speakEnabled  = settings.speakEnabled
        let gatedSpeak = settings.speakSettings.resolvingCloudGate(cloudAllowed: true)
        viewModel.speakSettings = gatedSpeak
        viewModel.selectedSpeakAccent = gatedSpeak.defaultAccent
        if case .cloud(let kind) = gatedSpeak.selectedEngine {
            viewModel.ttsConfig = settings.ttsConfig(for: kind)
        } else {
            viewModel.ttsConfig = .default
        }

        // Dictionary: copy dedicated speech config (cloud TTS always allowed).
        let gatedDictionarySpeak = settings.dictionaryConfig.speakSettings
            .resolvingCloudGate(cloudAllowed: true)
        viewModel.dictionarySpeakSettings = gatedDictionarySpeak
        viewModel.dictionaryAccent = settings.dictionaryConfig.accent
        if case .cloud(let kind) = gatedDictionarySpeak.selectedEngine {
            viewModel.dictionaryTTSConfig = settings.ttsConfig(for: kind)
        } else {
            viewModel.dictionaryTTSConfig = .default
        }

        // Drive the action bar from the user's saved order (enabled identifiers only).
        // Remove any .custom entries that were filtered out by the appliesWhenRegex visibility check
        // so dividers and the burger reflect only the actions that are actually
        // rendered.
        let visibleCustomIDs = Set(viewModel.customActions.map(\.id))
        func filterVisible(_ ids: [ActionIdentifier]) -> [ActionIdentifier] {
            ids.filter { id in
                if case .custom(let uuid) = id { return visibleCustomIDs.contains(uuid) }
                return true
            }
        }
        // The logo always shows in "Show logo only" mode: the toolbar expands from it.
        viewModel.showsLogo = !settings.hideToolbarLogo || settings.showLogoOnly
        viewModel.isCollapsed = settings.showLogoOnly && startsCollapsed
        viewModel.expandsLeading = false
        viewModel.showsIgnoreAppButton = settings.ignoredAppsEnabled && settings.showToolbarIgnoreAppButton
        viewModel.showsIgnoreSiteButton = settings.showToolbarIgnoreSiteButton
        viewModel.showsSettingsButton = settings.showToolbarSettingsButton
        viewModel.inlineSystemButtons = settings.inlineToolbarSystemButtons
        viewModel.orderedActions = filterVisible(settings.principalOrderedIdentifiers)
        viewModel.overflowActions = filterVisible(settings.overflowOrderedIdentifiers)
        viewModel.labeledActions = settings.labeledActionIDs
        // "Menu" style replaces the full bar only for the passive triggers and the
        // show-toolbar shortcut (per-action hotkeys and OCR keep the bar). With
        // "Show logo only" the logo card shows first; its click opens the menu.
        // A menu with no rows at all falls back to the bar.
        viewModel.showsMenu = settings.toolbarStyle == .menu && startsCollapsed
            && !settings.showLogoOnly && menuHasRows

        // One cheap AX read: whether a later "no selection" probe can be trusted
        // to mean the user cleared it from the keyboard.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           case .present = captureEngine.probeSelection(from: pid) {
            selectionProbeConfirmed = true
        } else {
            selectionProbeConfirmed = false
        }

        // If already showing, reposition; otherwise show fresh.
        show(for: event)
    }

    // MARK: - Show / Hide

    /// Position the panel near the selection and make it visible.
    func show(for event: SelectionEvent) {
        pinHostingView(toTrailing: false)
        // A (re-)presentation starts without a submenu or a picked menu card.
        submenuPresenter.hide()
        pickedFromMenu = false

        // Derive a screen rect in AppKit coordinates.
        // AX/Quartz coordinates use Y=0 at the top-left of the MAIN screen,
        // increasing downward; AppKit uses Y=0 at the bottom of the main
        // screen, increasing upward.  Convert here.
        // Some apps emit a transient AX rect with zero width/height (e.g. an
        // empty/collapsed selection range), which flips to the screen corner and
        // parks the panel at the bottom-left. Treat any empty rect as "no rect"
        // and fall back to the mouse position, same as a nil screenRect.
        let mouse = NSEvent.mouseLocation
        let appKitRect: CGRect
        if let axRect = event.screenRect, !axRect.isEmpty {
            appKitRect = flipToAppKit(axRect)
        } else {
            // No usable rect — anchor to the mouse position instead.
            appKitRect = CGRect(origin: mouse, size: .zero)
        }

        if viewModel.isCollapsed {
            showCollapsed(for: event, selectionRect: appKitRect)
            return
        }
        if viewModel.showsMenu {
            if showMenu(for: event, selectionRect: appKitRect, mouse: mouse) { return }
            // The menu could not be measured: show the bar instead.
            viewModel.showsMenu = false
        }

        // Panel size after SwiftUI layout — use intrinsic content size if known.
        // After a logo card the panel still has the card's size: measure the full
        // toolbar instead, or panelOrigin would centre a logo-sized panel.
        var panelSize = panel.frame.size == .zero
            ? ToolbarController.initialPanelSize
            : panel.frame.size
        // Same after a Menu-style menu, which is usually much taller than the bar.
        if panelHoldsCollapsedSize || panelHoldsMenuSize {
            let measured = expandedPanelSize()
            if measured.width > 0, measured.height > 0 {
                panelSize = measured
                // Drop a stale logo-card- or menu-sized report until the full layout arrives.
                if panelHoldsCollapsedSize {
                    staleLayoutSize = ToolbarView.collapsedPanelSize(zoom: settings.toolbarZoom.scale)
                } else {
                    markStaleLayout(switchingTo: measured)
                }
                panel.setContentSize(measured)
                panelHoldsCollapsedSize = false
                panelHoldsMenuSize = false
            }
        }

        // Find the best screen for this selection.
        let screenFrame = visibleFrameForSelection(appKitRect)

        // Cache the screen frame for content-size re-clamping (reposition(forContentSize:)).
        currentScreenFrame = screenFrame

        // Use the mouse-release point carried by the event as the cursor anchor
        // (drag-select and double-click). Keyboard/chord events carry nil, so
        // they fall through to selection-centred/near-end positioning in panelOrigin.
        let cursor = event.mouseReleasePoint

        // Compute clamped origin.
        let origin = panelOrigin(
            panelSize: panelSize,
            near: appKitRect,
            within: screenFrame,
            cursor: cursor,
            grewDownward: event.selectionGrewDownward,
            mouse: mouse
        )

        ToolbarController.positionLog.debug("pos: pointer=\(String(describing: cursor)) grewDownward=\(String(describing: event.selectionGrewDownward)) axRect=\(NSStringFromRect(appKitRect)) origin=\(NSStringFromPoint(origin))")

        // A new selection resets manual-move state so auto-positioning applies.
        panel.resetMoveTracking()
        panel.setFrameOriginProgrammatically(origin)
        orderFrontIfHidden()
    }

    /// "Show logo only" mode: place the logo card right next to the mouse pointer.
    /// The size comes from the toolbar metrics, not `panel.frame.size`, which
    /// still holds the last (expanded) presentation's size.
    private func showCollapsed(for event: SelectionEvent, selectionRect: CGRect) {
        let zoom = settings.toolbarZoom.scale
        let panelSize = ToolbarView.collapsedPanelSize(zoom: zoom)
        let mouse = event.mouseReleasePoint ?? NSEvent.mouseLocation
        let screenFrame = visibleFrameForSelection(CGRect(origin: mouse, size: .zero))
        currentScreenFrame = screenFrame
        // "Menu" style: the logo click opens the menu; a pick from it places the
        // card as Bar style would, anchored on the pointer the logo used.
        savedBarPlacement = BarPlacement(
            selectionRect: selectionRect,
            cursor: mouse,
            grewDownward: event.selectionGrewDownward,
            mouse: mouse,
            screenFrame: screenFrame
        )

        let origin = collapsedPanelOrigin(
            panelSize: panelSize,
            cardTopInset: ToolbarView.outerTopPadding * zoom,
            cardBottomInset: ToolbarView.outerBottomPadding * zoom,
            mouse: mouse,
            grewDownward: event.selectionGrewDownward,
            within: screenFrame
        )

        ToolbarController.positionLog.debug("pos (logo only): mouse=\(NSStringFromPoint(mouse)) grewDownward=\(String(describing: event.selectionGrewDownward)) origin=\(NSStringFromPoint(origin))")

        panel.resetMoveTracking()
        panel.setContentSize(panelSize)
        panelHoldsCollapsedSize = true
        panel.setFrameOriginProgrammatically(origin)
        orderFrontIfHidden()
    }

    // MARK: - Menu style

    /// "Menu" style: show the menu beside the pointer release point, or below the
    /// selection for keyboard/chord triggers (above when there is no room), or
    /// beside the mouse when there is no usable selection rect. Saves the bar's
    /// placement inputs for the card shown after a pick. Returns false when the
    /// menu cannot be measured.
    private func showMenu(for event: SelectionEvent, selectionRect: CGRect, mouse: CGPoint) -> Bool {
        let screenFrame = visibleFrameForSelection(selectionRect)
        let anchor: CGRect
        let preferUp: Bool
        if let pointer = event.mouseReleasePoint {
            anchor = pointerMenuAnchor(pointer)
            preferUp = event.selectionGrewDownward == false
        } else if let axRect = event.screenRect, !axRect.isEmpty {
            // Same x rule as the bar: the mouse x when it sits on the selection
            // (some apps report an over-wide rect), else the selection's left edge.
            let mouseZone = selectionRect.insetBy(dx: 0, dy: -mouseOnSelectionTolerance)
            let anchorX = mouseZone.contains(mouse) ? mouse.x : selectionRect.minX
            anchor = CGRect(
                x: anchorX,
                y: selectionRect.minY - panelVerticalGap,
                width: 0,
                height: selectionRect.height + 2 * panelVerticalGap
            )
            preferUp = false
        } else {
            anchor = pointerMenuAnchor(mouse)
            preferUp = false
        }

        panel.resetMoveTracking()
        guard placeMenu(anchor: anchor, preferUp: preferUp, coversAnchor: false, within: screenFrame) else {
            return false
        }
        currentScreenFrame = screenFrame
        savedBarPlacement = BarPlacement(
            selectionRect: selectionRect,
            cursor: event.mouseReleasePoint,
            grewDownward: event.selectionGrewDownward,
            mouse: mouse,
            screenFrame: screenFrame
        )
        orderFrontIfHidden()
        return true
    }

    /// The menu anchor for a pointer: the point padded vertically by
    /// `pointerVerticalGap`, zero width, so the menu opens beside the pointer.
    private func pointerMenuAnchor(_ point: CGPoint) -> CGRect {
        CGRect(x: point.x, y: point.y - pointerVerticalGap, width: 0, height: 2 * pointerVerticalGap)
    }

    /// Sizes the panel for the menu (measured offscreen) and places its card
    /// against `anchor` with `menuCardOrigin`. Returns false when unmeasurable.
    private func placeMenu(anchor: CGRect, preferUp: Bool, coversAnchor: Bool, within screenFrame: CGRect) -> Bool {
        let zoom = settings.toolbarZoom.scale
        let size = expandedPanelSize(forceMenu: true)
        guard size.width > 0, size.height > 0 else { return false }
        let cardSize = CGSize(
            width: size.width - 2 * ToolbarView.outerHorizontalPadding * zoom,
            height: size.height - (ToolbarView.outerTopPadding + ToolbarView.outerBottomPadding) * zoom
        )
        let cardOrigin = menuCardOrigin(
            cardSize: cardSize,
            anchor: anchor,
            preferUp: preferUp,
            within: screenFrame,
            coversAnchor: coversAnchor
        )
        let origin = CGPoint(
            x: cardOrigin.x - ToolbarView.outerHorizontalPadding * zoom,
            y: cardOrigin.y - ToolbarView.outerBottomPadding * zoom
        )

        ToolbarController.positionLog.debug("pos (menu): anchor=\(NSStringFromRect(anchor)) preferUp=\(preferUp) coversAnchor=\(coversAnchor) size=\(NSStringFromSize(size)) origin=\(NSStringFromPoint(origin))")

        // A programmatic resize must never count as a user drag.
        let userHasMoved = panel.userHasMoved
        markStaleLayout(switchingTo: size)
        panel.setContentSize(size)
        panel.setFrameOriginProgrammatically(origin)
        if !userHasMoved { panel.resetMoveTracking() }
        panelHoldsCollapsedSize = false
        panelHoldsMenuSize = true
        return true
    }

    /// Opens the menu in place of the logo card ("Show logo only" + "Menu"
    /// style): top-left on the logo's top-left, flipped right-/bottom-aligned
    /// with it when there is no room. Returns false when unmeasurable.
    private func openMenuFromLogo() -> Bool {
        let screenFrame = currentScreenFrame ?? visibleFrameForSelection(panel.frame)
        viewModel.expandsLeading = false
        pinHostingView(toTrailing: false)
        guard placeMenu(anchor: visibleCardFrame(), preferUp: false, coversAnchor: true, within: screenFrame) else {
            return false
        }
        // A short fade, no spring: the menu replaces the logo in place.
        withAnimation(.easeOut(duration: 0.15)) {
            viewModel.showsMenu = true
            viewModel.isCollapsed = false
        }
        return true
    }

    /// Turns the open menu into the horizontal card: closes the submenu and,
    /// unless the user dragged the panel, re-places it where Bar style would
    /// have put the bar for this presentation.
    private func switchMenuToBar() {
        submenuPresenter.hide()
        pickedFromMenu = true
        let size = expandedPanelSize()
        if size.width > 0, size.height > 0 {
            let oldFrame = panel.frame
            // A dragged panel keeps its top-left edge, like any content resize.
            var origin = CGPoint(x: oldFrame.minX, y: oldFrame.maxY - size.height)
            if !panel.userHasMoved, let placement = savedBarPlacement {
                origin = panelOrigin(
                    panelSize: size,
                    near: placement.selectionRect,
                    within: placement.screenFrame,
                    cursor: placement.cursor,
                    grewDownward: placement.grewDownward,
                    mouse: placement.mouse
                )
            }
            ToolbarController.positionLog.debug("pos (menu pick): moved=\(self.panel.userHasMoved) size=\(NSStringFromSize(size)) origin=\(NSStringFromPoint(origin))")
            markStaleLayout(switchingTo: size)
            panel.setContentSize(size)
            panel.setFrameOriginProgrammatically(origin)
            let screenFrame = currentScreenFrame ?? visibleFrameForSelection(panel.frame)
            let clamped = clampOnScreen(panel.frame, within: screenFrame)
            if clamped != panel.frame.origin {
                panel.setFrameOriginProgrammatically(clamped)
            }
        }
        panelHoldsMenuSize = false
        viewModel.showsMenu = false
    }

    /// A menu or submenu row was clicked: run its action in the horizontal card.
    private func handleMenuPick(_ id: ActionIdentifier) {
        guard isShowing, viewModel.showsMenu else { return }
        // A click on a submenu row made the submenu panel key; it closes below,
        // so the main panel takes key back (as after a click on the bar).
        // A pick is a click, so the pointer tells which panel was clicked.
        let pickedInSubmenu = submenuPresenter.visibleFrame?.contains(NSEvent.mouseLocation) ?? false
        switchMenuToBar()
        viewModel.triggerAction(id)
        // Prompt needs the panel key for its text field.
        if id == .builtin(.prompt) || pickedInSubmenu {
            activatePromptInput()
        }
    }

    /// Opens (or re-places) the More actions submenu beside the menu card, or
    /// closes it when `moreRowFrame` is nil (another row is hovered).
    private func updateSubmenu(moreRowFrame: CGRect?) {
        guard let rowFrame = moreRowFrame, rowFrame.width > 0, rowFrame.height > 0,
              isShowing, viewModel.showsMenu,
              let hostView = toolbarHostingView else {
            submenuPresenter.hide()
            return
        }
        submenuPresenter.show(
            moreRowFrameInHost: rowFrame,
            hostView: hostView,
            menuCardFrameOnScreen: visibleCardFrame(),
            zoom: settings.toolbarZoom.scale
        )
    }

    /// True when the menu has at least one row (actions, More actions, or a
    /// system row); an empty menu falls back to the bar.
    private var menuHasRows: Bool {
        !viewModel.orderedActions.isEmpty || viewModel.hasOverflow || viewModel.hasSystemButtons
    }

    /// The visible card's frame on screen: the panel frame minus the outer paddings.
    private func visibleCardFrame() -> CGRect {
        let zoom = settings.toolbarZoom.scale
        return CGRect(
            x: panel.frame.minX + ToolbarView.outerHorizontalPadding * zoom,
            y: panel.frame.minY + ToolbarView.outerBottomPadding * zoom,
            width: panel.frame.width - 2 * ToolbarView.outerHorizontalPadding * zoom,
            height: panel.frame.height - (ToolbarView.outerTopPadding + ToolbarView.outerBottomPadding) * zoom
        )
    }

    /// Before pre-sizing the panel for content that has not laid out yet:
    /// remember the hosting view's current size, so `reposition(forContentSize:)`
    /// skips reports of it until the new layout arrives. Nothing to skip when
    /// the sizes already match.
    private func markStaleLayout(switchingTo newSize: CGSize) {
        let current = toolbarHostingView?.bounds.size ?? panel.frame.size
        staleLayoutSize = abs(current.width - newSize.width) < 0.5 && abs(current.height - newSize.height) < 0.5
            ? nil
            : current
    }

    /// Pins the hosting view to the container's leading (default) or trailing edge.
    private func pinHostingView(toTrailing: Bool) {
        guard let leading = hostingLeadingConstraint,
              let trailing = hostingTrailingConstraint,
              leading.isActive == toTrailing else { return }
        leading.isActive = !toTrailing
        trailing.isActive = toTrailing
    }

    private func orderFrontIfHidden() {
        if !isShowing {
            isShowing = true
            panel.orderFront(nil)
            installEventMonitors()
        }
    }

    /// Expands the full toolbar out of the logo card. No-op unless collapsed.
    ///
    /// Picks the expand side first: rightward (logo's left edge fixed) when the
    /// expanded bar fits right of the logo, else leftward (logo moves to the
    /// trailing end, the panel keeps its right edge fixed). The expanded card
    /// width is measured synchronously by laying out an offscreen hosting view of
    /// the same toolbar forced expanded; pure layout work on the main thread.
    ///
    /// - Parameter opensMenu: true for the logo click: in "Menu" style the menu
    ///   replaces the logo instead of the bar. Per-action hotkeys pass false.
    private func expandFromLogo(animated: Bool, opensMenu: Bool = false) {
        guard viewModel.isCollapsed else { return }
        if opensMenu, settings.toolbarStyle == .menu, menuHasRows, openMenuFromLogo() {
            return
        }

        let zoom = settings.toolbarZoom.scale
        let logoCardFrame = CGRect(
            x: panel.frame.minX + ToolbarView.outerHorizontalPadding * zoom,
            y: panel.frame.minY + ToolbarView.outerBottomPadding * zoom,
            width: panel.frame.width - 2 * ToolbarView.outerHorizontalPadding * zoom,
            height: panel.frame.height - (ToolbarView.outerTopPadding + ToolbarView.outerBottomPadding) * zoom
        )
        let screenFrame = currentScreenFrame ?? visibleFrameForSelection(panel.frame)
        let expandedSize = expandedPanelSize()
        let expandedWidth = max(0, expandedSize.width - 2 * ToolbarView.outerHorizontalPadding * zoom)
        viewModel.expandsLeading = expandedWidth > 0
            ? logoExpandsLeading(logoCardFrame: logoCardFrame, expandedCardWidth: expandedWidth, within: screenFrame)
            : logoCardFrame.midX > screenFrame.midX

        // Size the panel for the expanded bar before the content switches, so no
        // frame clips the growing card (the panel otherwise resizes a runloop tick
        // after layout). Leftward: keep the right edge and pin the content
        // trailing, so the logo card stays exactly where it is meanwhile.
        if expandedWidth > 0 {
            pinHostingView(toTrailing: viewModel.expandsLeading)
            let oldFrame = panel.frame
            let newSize = CGSize(width: expandedSize.width, height: max(expandedSize.height, oldFrame.height))
            panel.setContentSize(newSize)
            panel.setFrameOriginProgrammatically(CGPoint(
                x: viewModel.expandsLeading ? oldFrame.maxX - newSize.width : oldFrame.minX,
                y: oldFrame.maxY - newSize.height
            ))
            panelHoldsCollapsedSize = false
            staleLayoutSize = ToolbarView.collapsedPanelSize(zoom: zoom)
            // A bar that fits on neither side of the logo is clamped on-screen here:
            // reposition(forContentSize:) skips the matching expanded layout report.
            let clamped = clampOnScreen(panel.frame, within: screenFrame)
            if clamped != panel.frame.origin {
                panel.setFrameOriginProgrammatically(clamped)
            }
        }

        guard animated else {
            viewModel.isCollapsed = false
            return
        }
        let animation: Animation = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.32, dampingFraction: 0.82)
        withAnimation(animation) {
            viewModel.isCollapsed = false
        }
    }

    /// Size of the panel for the expanded toolbar (outer padding included),
    /// measured from an offscreen hosting view of the toolbar forced expanded
    /// (the bar), or forced to the Menu-style menu with `forceMenu`.
    /// Zero when unmeasurable.
    private func expandedPanelSize(forceMenu: Bool = false) -> CGSize {
        let measuringView = NSHostingView(rootView: ToolbarView(
            viewModel: viewModel,
            outputHandler: outputHandler,
            onContentResize: { _ in },
            onOpenSettings: {},
            onIgnoreApp: {},
            onIgnoreDomain: {},
            onDismiss: {},
            onDisableCloseConfirmation: {},
            onActivatePromptInput: {},
            forceExpanded: true,
            forceMenu: forceMenu
        ))
        return measuringView.fittingSize
    }

    /// Called by the SwiftUI content (via onContentResize) whenever its measured
    /// size changes — e.g. when a result/diff expands the body. Resizes the panel
    /// to fit the content, then keeps it on-screen.
    ///
    /// Positioning policy (per product decision):
    ///   • Anchor the top-left: keep the panel's visual top edge fixed as it grows
    ///     downward, so the action bar doesn't jump. After a leftward expansion
    ///     from the logo card (`viewModel.expandsLeading`), anchor the top-right
    ///     instead, so the logo stays put.
    ///   • Only nudge the origin inward if the resized panel would spill off-screen.
    ///   • If the user has manually dragged the panel, never auto-reposition —
    ///     only clamp back on-screen when a resize would push it off-edge.
    func reposition(forContentSize contentSize: CGSize) {
        guard isShowing else { return }
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        // The panel is borderless, so its frame size equals its content size.
        // Skip when nothing changed — the hosting view reports its size on every
        // layout pass, and resizing the panel triggers another layout, so without
        // this guard the two would ping-pong.
        if let stale = staleLayoutSize {
            if abs(contentSize.width - stale.width) < 0.5, abs(contentSize.height - stale.height) < 0.5 {
                return
            }
            staleLayoutSize = nil
        }
        guard contentSize != panel.frame.size else { return }

        let oldFrame = panel.frame
        // Anchor the top edge: in AppKit (Y-up), the top is frame.maxY. Growing
        // the height must extend downward, so the new origin.y drops by the delta.
        let newOrigin = CGPoint(
            x: viewModel.expandsLeading ? oldFrame.maxX - contentSize.width : oldFrame.origin.x,
            y: oldFrame.maxY - contentSize.height
        )
        panel.setContentSize(contentSize)
        if !viewModel.isCollapsed { panelHoldsCollapsedSize = false }
        if !viewModel.showsMenu { panelHoldsMenuSize = false }
        panel.setFrameOriginProgrammatically(newOrigin)

        // Clamp on-screen. Use the cached screen frame (the selection's display).
        let screenFrame = currentScreenFrame ?? visibleFrameForSelection(panel.frame)
        let clamped = clampOnScreen(panel.frame, within: screenFrame)
        if clamped != panel.frame.origin {
            panel.setFrameOriginProgrammatically(clamped)
        }
    }

    /// Clamp a frame's origin so the whole frame stays within `screenFrame`
    /// (minus the standard edge inset). Returns the adjusted origin.
    private func clampOnScreen(_ frame: CGRect, within screenFrame: CGRect) -> CGPoint {
        let minX = screenFrame.minX + panelEdgeInset
        let maxX = screenFrame.maxX - frame.width - panelEdgeInset
        let minY = screenFrame.minY + panelEdgeInset
        let maxY = screenFrame.maxY - frame.height - panelEdgeInset
        // Guard against panels taller/wider than the screen: prefer the top/left edge.
        let x = maxX >= minX ? min(max(frame.origin.x, minX), maxX) : minX
        let y = maxY >= minY ? min(max(frame.origin.y, minY), maxY) : maxY
        return CGPoint(x: x, y: y)
    }

    /// Hide the panel and remove event monitors.
    func hide() {
        guard isShowing else { return }
        isShowing = false
        // A tooltip child panel would otherwise reappear with the toolbar:
        // orderOut does not fire the SwiftUI hover/disappear teardown.
        HoverTooltipPanelPresenter.shared.hide(anchor: nil)
        submenuPresenter.hide()
        panel.orderOut(nil)
        panel.resetMoveTracking()
        currentScreenFrame = nil
        staleLayoutSize = nil
        pickedFromMenu = false
        savedBarPlacement = nil
        removeEventMonitors()
        // I-E: cancel any in-flight stream before resetting view state.
        actionHandler?.cancel()
        // reset() calls stopSpeaking() which routes to speakCoordinator.stop().
        viewModel.reset()
    }

    // MARK: - Coordinate conversion

    /// Convert a CGRect from Quartz/AX screen coordinates (Y=0 top, increasing down)
    /// to AppKit screen coordinates (Y=0 bottom of main screen, increasing up).
    private func flipToAppKit(_ rect: CGRect) -> CGRect {
        guard let mainScreenHeight = NSScreen.screens.first?.frame.height else {
            return rect
        }
        // In Quartz coords: rect.origin.y is the top-left Y of the rect (from the
        // top of the main screen). In AppKit coords, the same top-left Y is:
        //   appKitY = screenHeight - quartzY - rect.height
        let flippedY = mainScreenHeight - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }

    // MARK: - Event monitors (auto-dismiss, Task 2.3)

    /// True while an action is mid-stream. Outside-click / Escape must NOT close
    /// the toolbar in this state — they are silently ignored so the in-flight
    /// stream keeps running and the panel stays put (no confirmation prompt).
    private var isActionRunning: Bool {
        if case .running = viewModel.actionState { return true }
        return false
    }

    /// True once a result has finished generating. When the confirm-on-close
    /// setting is on, outside-click / Escape ask for confirmation in this state
    /// so a ready result isn't dismissed by accident.
    private var isResultReady: Bool {
        if case .result = viewModel.actionState { return true }
        return false
    }

    /// True when the shown result offers Paste back (an editable source, not a
    /// dictionary lookup).
    private var offersPasteBack: Bool {
        isResultReady
            && !viewModel.isDictionaryAction
            && viewModel.sourceElement?.isEditable == true
    }

    /// True when the source app is the frontmost app. The panel is non-activating,
    /// so it stays the source app while the panel is key.
    private var isSourceAppFrontmost: Bool {
        guard let element = viewModel.sourceElement?.element else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0 else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// True when the shown result offers `action` (its button shows).
    private func offers(_ action: EnterResultAction) -> Bool {
        switch action {
        case .pasteBack:  return offersPasteBack
        case .copy:       return isResultReady && !viewModel.isDictionaryAction
        case .regenerate: return viewModel.canRegenerate && !viewModel.isEditing
        case .nothing:    return false
        }
    }

    /// What Enter does now: the "Enter on a result" action, else its fallback,
    /// when the result offers it, the source app is frontmost, and no text input
    /// or confirmation needs the key (editor, prompt, refine field). Nil when
    /// Enter is left alone, always when the action is "Do nothing" (its fallback
    /// is then off).
    private var enterAction: EnterResultAction? {
        guard settings.enterResultAction != .nothing,
              isShowing,
              isSourceAppFrontmost,
              !viewModel.isEditing,
              !viewModel.isPromptInputActive,
              !viewModel.isRefineInputActive,
              !viewModel.isShowingCloseConfirmation else { return nil }
        return [settings.enterResultAction, settings.enterResultFallback].first(where: offers)
    }

    /// Enter in the panel: asks the view to run `enterAction`. Returns true when
    /// the key was used.
    private func handleEnterKey(windowNumber: Int) -> Bool {
        guard windowNumber == panel.windowNumber, let action = enterAction else { return false }
        viewModel.enterKeyRequests.send(action)
        return true
    }

    /// Decide what an outside-click / Escape should do given the current state,
    /// then act: ignore while running, confirm when a result is ready (and the
    /// setting is on), otherwise close.
    private func handleDismissRequest() {
        // While the user is typing a prompt (non-empty draft), keep the toolbar open so
        // an accidental outside-click or Escape doesn't discard their text. An empty
        // draft falls through to normal dismiss handling.
        if viewModel.isPromptInputActive,
           !viewModel.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        // Same rule for a non-empty Refine instruction draft.
        if viewModel.isRefineInputActive,
           !viewModel.refineDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        if isActionRunning {
            // Keep the toolbar open and the stream running; no prompt.
            return
        }
        if settings.confirmCloseAfterResult, isResultReady {
            requestCloseConfirmation()
        } else {
            hide()
        }
    }

    /// Surface the close-confirmation dialog. The panel is made key (without
    /// activating PopGuy, since it is a non-activating panel) so SwiftUI has a
    /// key window to present against after the user clicked into another app.
    private func requestCloseConfirmation() {
        panel.makeKeyAndOrderFront(nil)
        viewModel.isShowingCloseConfirmation = true
    }

    /// Make the panel key so the inline prompt TextField can receive keystrokes.
    /// The panel is non-activating, so this gains keyboard focus without activating
    /// PopGuy (same mechanism as `requestCloseConfirmation`). Called when the prompt
    /// input area opens (button tap or hotkey).
    private func activatePromptInput() {
        panel.makeKeyAndOrderFront(nil)
    }

    private func installEventMonitors() {
        // Global monitor: hide on any left/right mouse-down outside the panel.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            // NSEvent global monitors deliver on the main thread when the event
            // loop is running. Dispatch to @MainActor to satisfy the compiler.
            Task { @MainActor [weak self] in
                guard let self else { return }
                // NSEvent.mouseLocation gives reliable screen coordinates for
                // global monitors (no associated window means locationInWindow
                // is unreliable).
                let screenPoint = NSEvent.mouseLocation
                // The Menu style's submenu panel counts as inside too.
                let inSubmenu = self.submenuPresenter.visibleFrame?.contains(screenPoint) ?? false
                if !self.panel.frame.contains(screenPoint), !inSubmenu {
                    self.handleDismissRequest()
                }
            }
        }

        // Local monitor: hide on Escape when the panel is key.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // ESC = keyCode 53
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in
                    self?.handleDismissRequest()
                }
                return nil // consume the event
            }
            // Return = 36, keypad Enter = 76, without modifiers: "Enter on a result".
            // Local monitors run on the main thread.
            let windowNumber = event.windowNumber
            if event.keyCode == 36 || event.keyCode == 76,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               MainActor.assumeIsolated({ self.handleEnterKey(windowNumber: windowNumber) }) {
                return nil // consume the event
            }
            return event
        }

        // Global monitor: key presses in the source app (the panel is
        // non-activating, so keys normally go there and the local monitor above
        // never sees them). Escape closes like an outside click; any other key may
        // have cleared the selection, which closes the toolbar too. The source app
        // still gets the key: a global monitor cannot consume it.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let characters = event.charactersIgnoringModifiers
            let flags = event.modifierFlags
            Task { @MainActor [weak self] in
                self?.handleSourceAppKeyDown(keyCode: keyCode, characters: characters, flags: flags)
            }
        }
    }

    /// True while the toolbar only offers its actions: nothing dispatched, spoken,
    /// typed or confirmed yet, and not an OCR capture (no source selection). Only
    /// then does a cleared selection close the toolbar — a result stays up.
    private var isAwaitingAction: Bool {
        viewModel.actionState == .idle
            && viewModel.speakPhase == .idle
            && !viewModel.canReplaySpeak
            && !viewModel.isPromptInputActive
            && !viewModel.isRefineInputActive
            && !viewModel.isShowingCloseConfirmation
            && viewModel.ocrPreviewImage == nil
    }

    /// A key press in another app while the toolbar shows. Escape requests a
    /// dismiss (same rules as an outside click). Any other key re-checks the
    /// selection once the app has handled it (80 ms, like the pipeline's
    /// debounce; key repeats check once): when AX reports no selection any more,
    /// the toolbar hides. A new selection made by the key re-shows the toolbar
    /// through the pipeline instead; an inconclusive read keeps it.
    private func handleSourceAppKeyDown(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) {
        guard isShowing else { return }
        if keyCode == 53 { // Escape
            handleDismissRequest()
            return
        }
        guard isAwaitingAction,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              shouldCheckSelectionClearedOnKey(
                  keyCode: keyCode,
                  characters: characters,
                  flags: flags,
                  selectionHiddenFromProbe: !selectionProbeConfirmed
                      || TextCaptureEngine.usesClipboardFallback(pid: pid)
              ) else { return }
        selectionClearedCheck?.cancel()
        selectionClearedCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self, self.isShowing, self.isAwaitingAction else { return }
            if case .absent = self.captureEngine.probeSelection(from: pid) {
                self.hide()
            }
        }
    }

    private func removeEventMonitors() {
        if let token = globalMouseMonitor {
            NSEvent.removeMonitor(token)
            globalMouseMonitor = nil
        }
        if let token = localKeyMonitor {
            NSEvent.removeMonitor(token)
            localKeyMonitor = nil
        }
        if let token = globalKeyMonitor {
            NSEvent.removeMonitor(token)
            globalKeyMonitor = nil
        }
        selectionClearedCheck?.cancel()
        selectionClearedCheck = nil
    }
}

// MARK: - IntrinsicHostingView

/// An `NSHostingView` that reports its size after every layout pass.
///
/// Used with `sizingOptions = .intrinsicContentSize` and top-leading constraints
/// so the hosting view always matches its SwiftUI content. Reporting the size on
/// each layout lets the controller resize the floating panel to fit. This avoids
/// a plain `NSHostingView`, which fills the panel and vertically centers the card
/// whenever the bounds briefly differ from the content during a resize — making
/// the toolbar bounce.
///
/// Non-generic (uses `AnyView`) on purpose: a generic `NSHostingView` subclass
/// crashes the Swift optimizer's EarlyPerfInliner on its synthesized `deinit`
/// under `-O` (Release/Archive). Erasing to `AnyView` keeps this a concrete type.
@MainActor
private final class IntrinsicHostingView: NSHostingView<AnyView> {
    /// Called after each layout with the hosting view's current size.
    var onContentSizeChange: ((CGSize) -> Void)?

    required init(rootView: AnyView) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        onContentSizeChange?(bounds.size)
    }
}
