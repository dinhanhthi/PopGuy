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

/// Returns the effective set of ignored app bundle IDs to enforce at runtime.
///
/// Pro users get the full list. Non-Pro users only honor the first `maxAllowed`
/// entries by stable insertion order — apps beyond the cap are no longer ignored
/// until Pro is active (the toolbar reappears there). Nothing is removed from
/// storage; this is a display-time cap only. Pure/testable.
func effectiveIgnoredApps(_ all: [String], maxAllowed: Int, isPro: Bool) -> [String] {
    isPro ? all : Array(all.prefix(maxAllowed))
}

@MainActor
final class ToolbarController {

    private static let positionLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PopGuy", category: "positioning")

    // MARK: - Dependencies

    private let pipeline: SelectionPipeline
    private let settings: SettingsStore
    private let keychain: KeychainManager
    private let licenseGate: LicenseGate
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

    /// Called when a free-tier act count triggers a soft nag. Wired by AppDelegate.
    var onUpgradeNagDue: (() -> Void)?

    // MARK: - State

    private var isShowing: Bool = false
    private var pipelineTask: Task<Void, Never>?

    /// Stored so hide() can cancel any in-flight stream (I-E).
    private weak var actionHandler: (any ToolbarActionHandling)?

    // NSEvent monitor tokens — removed on hide() to avoid leaking handlers.
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?

    /// Visible frame of the display that best contains the current selection.
    /// Cached at show() so content-size changes (reposition(forContentSize:)) can
    /// re-clamp the panel without recomputing screen geometry.
    private var currentScreenFrame: CGRect?

    // MARK: - Dimensions

    /// Initial panel frame. SwiftUI's fixedSize() drives actual sizing.
    private static let initialPanelSize = CGSize(width: 280, height: 50)

    // MARK: - Init

    init(
        pipeline: SelectionPipeline,
        settings: SettingsStore,
        keychain: KeychainManager = KeychainManager(),
        licenseGate: LicenseGate = LicenseGate(),
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.pipeline = pipeline
        self.settings = settings
        self.keychain = keychain
        self.licenseGate = licenseGate
        self.onOpenSettings = onOpenSettings
        self.viewModel = ToolbarViewModel()
        self.outputHandler = OutputHandler()
        self.speakCoordinator = SpeakCoordinator(keychain: keychain)
        self.scriptActionEngine = ScriptActionEngine()

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
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        ])
        panel.contentView = container

        // Bind the coordinator once — the Combine subscription is persistent.
        viewModel.bindSpeakCoordinator(speakCoordinator)

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

        // Wire the act counter: fires on every toolbar action run. Pro users are
        // never counted (guard on isPro). When recordAct() returns true the nag
        // is signalled to the AppDelegate via onUpgradeNagDue.
        viewModel.onActPerformed = { [weak self] in
            guard let self, !self.licenseGate.entitlements.isPro else { return }
            if self.settings.recordAct() {
                self.onUpgradeNagDue?()
            }
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
        handleEvent(event)
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
        handleEvent(event)
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
                    // Assigning a default action is feature-flagged + Pro-gated —
                    // otherwise fall back to showing the toolbar regardless of any
                    // stored assignment.
                    if ProConfig.doubleClickActionFeatureEnabled,
                       let assigned = self.settings.doubleClickAssignedAction,
                       self.licenseGate.entitlements.doubleClickActionAllowed {
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
                guard self.settings.triggerOnSelectEnabled else { continue }
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

    private func handleEvent(_ event: SelectionEvent) {
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
        if shouldIgnoreReentrantSelection(
            isShowing: isShowing,
            actionInProgress: viewModel.actionState != .idle || speakInProgress,
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
        // Apply free-tier cap: non-Pro users only honor the first maxIgnoredApps
        // entries by stable insertion order. Apps beyond that cap are no longer
        // ignored until Pro is active — the toolbar reappears in those apps.
        // Nothing is deleted from storage; the cap is a runtime-only suppression.
        let appEnt = licenseGate.entitlements
        let effective = effectiveIgnoredApps(
            settings.ignoredAppBundleIDs,
            maxAllowed: appEnt.maxIgnoredApps,
            isPro: appEnt.isPro
        )
        if let bundleID = sourceBundleID, effective.contains(bundleID) {
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
            // Enforce the free-tier ignored-domains cap on this path too: when the
            // user is at the limit, hide the "Ignore this site" button (Settings
            // disables its add field the same way) so the toolbar cannot bypass the
            // Pro gate. Suppression above still uses the real host.
            let ent = licenseGate.entitlements
            if !ent.isPro, settings.ignoredDomains.count >= ent.maxIgnoredDomains {
                sourceDomain = nil
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
        viewModel.dictionaryTargetLanguage = TargetLanguage(bcp47: settings.dictionaryConfig.definitionLanguage)

        // I-D: push enabled flags into the view model so ToolbarView can conditionally render.
        viewModel.improveEnabled      = improveEnabled
        viewModel.shortenEnabled      = shortenEnabled
        viewModel.proofreadEnabled    = proofreadEnabled
        viewModel.translateEnabled    = translateEnabled
        viewModel.promptEnabled       = promptEnabled
        viewModel.dictionaryEnabled   = settings.dictionaryConfig.isEnabled

        // Phase 5: thread enabled custom actions into the view model.
        // Cap at maxCustomActions when not Pro so a downgraded user cannot access
        // more enabled custom actions than their tier permits.
        let cloudAllowed = licenseGate.entitlements.cloudTTSPremiumAllowed
        // Push the cloud-TTS entitlement into the view model so speech custom
        // actions apply the same gate as the built-in Speak button. Co-located
        // with the customActions push so both are always updated together.
        viewModel.cloudTTSAllowed = cloudAllowed
        let enabledCustom = settings.customActions.filter(\.isEnabled)
        if licenseGate.entitlements.isPro {
            viewModel.customActions = CustomAction.visible(enabledCustom, forSelection: event.text)
        } else {
            // Cap by DISPLAY order (actionOrder), not storage order: keep the first
            // N enabled custom actions as the user ordered them, so reordering a
            // 4th action to the front shows it instead of silently dropping it.
            let cap = licenseGate.entitlements.maxCustomActions
            let allowedIDs = Set(
                settings.enabledOrderedIdentifiers
                    .compactMap { id -> UUID? in
                        if case .custom(let uuid) = id { return uuid }
                        return nil
                    }
                    .prefix(cap)
            )
            viewModel.customActions = CustomAction.visible(
                enabledCustom.filter { allowedIDs.contains($0.id) },
                forSelection: event.text
            )
        }

        // Push the result font size so ToolbarView renders at the configured scale.
        viewModel.resultFontSize = settings.resultFontSize
        viewModel.toolbarZoom = settings.toolbarZoom
        viewModel.includeFontInZoom = settings.zoomIncludesFontSize
        viewModel.preserveFormatting = settings.preserveFormatting

        // Speak: copy enabled flag, settings, and cloud TTS config per presentation.
        // Pass the gated copy of speakSettings (engine forced to .system for non-Pro)
        // so that ToolbarViewModel.triggerSpeak always uses the resolved engine.
        viewModel.speakEnabled  = settings.speakEnabled
        let gatedSpeak = settings.speakSettings.resolvingCloudGate(cloudAllowed: cloudAllowed)
        viewModel.speakSettings = gatedSpeak
        viewModel.selectedSpeakAccent = gatedSpeak.defaultAccent
        if case .cloud(let kind) = gatedSpeak.selectedEngine {
            viewModel.ttsConfig = settings.ttsConfig(for: kind)
        } else {
            viewModel.ttsConfig = .default
        }

        // Dictionary: copy dedicated speech config (gated for cloud TTS).
        let gatedDictionarySpeak = settings.dictionaryConfig.speakSettings
            .resolvingCloudGate(cloudAllowed: cloudAllowed)
        viewModel.dictionarySpeakSettings = gatedDictionarySpeak
        viewModel.dictionaryAccent = settings.dictionaryConfig.accent
        if case .cloud(let kind) = gatedDictionarySpeak.selectedEngine {
            viewModel.dictionaryTTSConfig = settings.ttsConfig(for: kind)
        } else {
            viewModel.dictionaryTTSConfig = .default
        }

        // Drive the action bar from the user's saved order (enabled identifiers only).
        // Free tier: cap the total actions shown in the toolbar (built-in + custom)
        // to maxActiveActions, by display order. Pro is uncapped (Int.max).
        // Additionally, remove any .custom entries that were filtered out by the
        // appliesWhenRegex visibility check so dividers and compactActions counts
        // reflect only the actions that are actually rendered.
        let visibleCustomIDs = Set(viewModel.customActions.map(\.id))
        func filterVisible(_ ids: [ActionIdentifier]) -> [ActionIdentifier] {
            ids.filter { id in
                if case .custom(let uuid) = id { return visibleCustomIDs.contains(uuid) }
                return true
            }
        }
        let principalIDs = filterVisible(settings.principalOrderedIdentifiers)
        let overflowIDs = filterVisible(settings.overflowOrderedIdentifiers)
        let allocated = Self.allocate(
            principal: principalIDs,
            overflow: overflowIDs,
            isPro: licenseGate.entitlements.isPro,
            freeMaxActive: licenseGate.entitlements.maxActiveActions,
            maxPrincipal: ProConfig.maxPrincipalActions,
            maxBurger: ProConfig.maxBurgerActions
        )
        viewModel.orderedActions = allocated.principal
        viewModel.overflowActions = allocated.overflow

        // If already showing, reposition; otherwise show fresh.
        show(for: event)
    }

    /// Apply universal zone caps and the free-tier display budget.
    nonisolated static func allocate(
        principal: [ActionIdentifier],
        overflow: [ActionIdentifier],
        isPro: Bool,
        freeMaxActive: Int,
        maxPrincipal: Int,
        maxBurger: Int
    ) -> (principal: [ActionIdentifier], overflow: [ActionIdentifier]) {
        if isPro {
            return (
                Array(principal.prefix(maxPrincipal)),
                Array(overflow.prefix(maxBurger))
            )
        }
        let cappedPrincipal = Array(principal.prefix(min(maxPrincipal, freeMaxActive)))
        let remaining = max(0, freeMaxActive - cappedPrincipal.count)
        let cappedOverflow = Array(overflow.prefix(min(maxBurger, remaining)))
        return (cappedPrincipal, cappedOverflow)
    }

    // MARK: - Show / Hide

    /// Position the panel near the selection and make it visible.
    func show(for event: SelectionEvent) {
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

        // Panel size after SwiftUI layout — use intrinsic content size if known.
        let panelSize = panel.frame.size == .zero
            ? ToolbarController.initialPanelSize
            : panel.frame.size

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
            grewDownward: event.selectionGrewDownward
        )

        ToolbarController.positionLog.debug("pos: pointer=\(String(describing: cursor)) grewDownward=\(String(describing: event.selectionGrewDownward)) axRect=\(NSStringFromRect(appKitRect)) origin=\(NSStringFromPoint(origin))")

        // A new selection resets manual-move state so auto-positioning applies.
        panel.resetMoveTracking()
        panel.setFrameOriginProgrammatically(origin)

        if !isShowing {
            isShowing = true
            panel.orderFront(nil)
            installEventMonitors()
        }
    }

    /// Called by the SwiftUI content (via onContentResize) whenever its measured
    /// size changes — e.g. when a result/diff expands the body. Resizes the panel
    /// to fit the content, then keeps it on-screen.
    ///
    /// Positioning policy (per product decision):
    ///   • Anchor the top-left: keep the panel's visual top edge fixed as it grows
    ///     downward, so the action bar doesn't jump.
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
        guard contentSize != panel.frame.size else { return }

        let oldFrame = panel.frame
        // Anchor the top edge: in AppKit (Y-up), the top is frame.maxY. Growing
        // the height must extend downward, so the new origin.y drops by the delta.
        let newOrigin = CGPoint(
            x: oldFrame.origin.x,
            y: oldFrame.maxY - contentSize.height
        )
        panel.setContentSize(contentSize)
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
        panel.orderOut(nil)
        panel.resetMoveTracking()
        currentScreenFrame = nil
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
        ) { event in
            // NSEvent global monitors deliver on the main thread when the event
            // loop is running. Dispatch to @MainActor to satisfy the compiler.
            Task { @MainActor [weak self] in
                guard let self else { return }
                // NSEvent.mouseLocation gives reliable screen coordinates for
                // global monitors (no associated window means locationInWindow
                // is unreliable).
                let screenPoint = NSEvent.mouseLocation
                if !self.panel.frame.contains(screenPoint) {
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
            return event
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
