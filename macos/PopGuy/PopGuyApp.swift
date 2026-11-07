// PopGuyApp.swift
// PopGuy

import Combine
import SwiftUI
import AppKit

@main
struct PopGuyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

enum StatusMenuTrigger {
    case textSelection
    case doubleClick

    var title: String {
        switch self {
        case .textSelection:
            "Show on Text Selection"
        case .doubleClick:
            "Show on Double-Click"
        }
    }

    private var iconSymbolNames: [String] {
        switch self {
        case .textSelection:
            ["text.cursor", "textformat"]
        case .doubleClick:
            ["cursorarrow.click.2", "cursorarrow.click"]
        }
    }

    @MainActor
    func makeIcon() -> NSImage? {
        for symbolName in iconSymbolNames {
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                return image
            }
        }
        return nil
    }
}

@MainActor
func makeStatusTriggerMenuItem(
    _ trigger: StatusMenuTrigger,
    isOn: Bool,
    action: Selector
) -> NSMenuItem {
    let item = NSMenuItem(
        title: trigger.title,
        action: action,
        keyEquivalent: ""
    )
    item.state = isOn ? .on : .off
    item.image = trigger.makeIcon()
    return item
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    let axPermission = AccessibilityPermission()
    /// Screen Recording permission state for the OCR feature. Safe to create at
    /// launch — its init only preflights the current grant state, never prompts.
    let screenRecordingPermission = ScreenRecordingPermission()
    private var selectionPipeline: SelectionPipeline?
    private var toolbarController: ToolbarController?
    private var ocrCaptureController: OCRCaptureController?
    private var composerController: ComposerController?
    private var permissionObserver: NSObjectProtocol?

    // MARK: - Shared services (created once, injected into subsystems)

    private let settingsStore = SettingsStore()
    private let keychainManager = KeychainManager()
    private let historyStore = HistoryStore()
    private var actionEngineHandler: ActionEngineHandler?
    private var settingsWindow: NSWindow?

    /// Drives which Settings tab is shown; lets the menu open a specific tab
    /// even when the Settings window already exists.
    private let settingsNavigator = SettingsNavigator()

    // MARK: - Auto-update

    private let updater = UpdaterController()

    /// Combine subscription — refreshes the status icon and menu when update availability changes.
    private var updaterCancellable: AnyCancellable?
    private var popGuyEnabledCancellable: AnyCancellable?
    private var showDockIconCancellable: AnyCancellable?

    // MARK: - Onboarding

    private var onboardingWindow: NSWindow?

    // MARK: - Phase 5: Hotkeys and double-tap chord

    /// Global shortcut manager. Started once when AX is first trusted.
    private var hotkeyManager: HotkeyManager?

    /// CGEventTap-based Cmd+C+C chord detector. Started once when AX is first trusted.
    private var doubleTapChord: DoubleTapChord?

    /// Combine subscription — re-registers hotkeys when shortcut bindings change.
    private var shortcutBindingsCancellable: AnyCancellable?

    /// Combine subscription — re-registers hotkeys when custom actions change.
    private var customActionsCancellable: AnyCancellable?

    /// Combine subscription — re-applies chord/hotkey wiring when chord enabled flag changes.
    private var chordEnabledCancellable: AnyCancellable?

    /// Combine subscription — re-applies chord/hotkey wiring when replacement shortcut changes.
    private var chordReplacementCancellable: AnyCancellable?

    /// Combine subscription — re-applies hotkey wiring when the OCR shortcut changes.
    private var ocrShortcutCancellable: AnyCancellable?

    /// Combine subscription — re-applies hotkey wiring when the OCR opt-in toggle changes.
    private var ocrEnabledCancellable: AnyCancellable?

    /// Combine subscription — re-applies hotkey wiring when the Compose shortcut changes.
    private var composeShortcutCancellable: AnyCancellable?

    /// Combine subscription — starts/stops the Terminal Composer server and re-applies
    /// hotkey wiring when its opt-in toggle changes.
    private var terminalComposerEnabledCancellable: AnyCancellable?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI Previews launch the full app; skip the launch side effects
        // (status item, CGEventTap chord, accessibility pipeline) which crash
        // the preview host. The env var is only set while previewing.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }

        buildStatusMenu()
        // One-time background conversion of legacy Babylon indexes to SQLite; a no-op
        // (stat + meta read per dictionary) once every dictionary is converted.
        // Skipped when the app is the unit-test host so tests never rewrite the
        // user's real index files.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let babylonDictionaries = isTestHost ? [] : settingsStore.babylonDictionaries
        Task(priority: .utility) {
            for dictionary in babylonDictionaries {
                _ = try? await BabylonBGLIndexCache.shared.prepareIndex(for: dictionary)
            }
        }

        // Start the Sparkle updater and subscribe to availability changes.
        updater.start()
        // Task { @MainActor } provides actor isolation; only the badge needs
        // immediate refresh — the menu items are rebuilt lazily on open.
        updaterCancellable = updater.$updateAvailable
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshStatusIcon()
                }
            }

        // Dim the menu-bar icon when the master switch turns PopGuy off.
        popGuyEnabledCancellable = settingsStore.$popGuyEnabled
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshStatusIcon()
                }
            }

        showDockIconCancellable = settingsStore.$showDockIconWithSettings
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.applyDockPolicy()
                }
            }

        // Observe trust-state changes to rebuild the menu and (re-)start the pipeline.
        // Note: LSUIElement apps may not reliably receive didBecomeActiveNotification
        // when returning from System Settings. menuNeedsUpdate (below) handles the
        // reliable refresh path when the user opens the status menu.
        permissionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.axPermission.refresh()
                self?.buildStatusMenu()
                self?.startPipelineIfTrusted()
            }
        }

        startPipelineIfTrusted()

        // Show first-launch onboarding once.
        if !settingsStore.hasOnboarded {
            presentOnboarding()
        }

        // DEBUG-only QA hook: `--open-settings [--settings-section=<rawValue>]
        // [--settings-screen=<display name>] [--appearance=light|dark]` opens the
        // Settings window at launch, for screenshots from a shell;
        // `--snapshot-out=` (below) writes one without screencapture.
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let arg = args.first(where: { $0.hasPrefix("--appearance=") }) {
            // QA: force light or dark without touching the system setting.
            NSApp.appearance = NSAppearance(named: arg.hasSuffix("light") ? .aqua : .darkAqua)
        }
        if args.contains("--open-settings") {
            if let arg = args.first(where: { $0.hasPrefix("--settings-section=") }),
               let section = SettingsSection(rawValue: String(arg.dropFirst("--settings-section=".count))) {
                settingsNavigator.section = section
            }
            openSettings()
        }
        if args.contains("--open-composer") || args.contains("--composer-session-ended") {
            // QA: opens a test composer with Markdown sample text, drafts autosaved;
            // `--composer-session-ended` opens it in the "Session ended" state.
            openDebugComposer(sessionEnded: args.contains("--composer-session-ended"))
        }
        if let arg = args.first(where: { $0.hasPrefix("--snapshot-out=") }) {
            // QA: `--snapshot-out=<png> [--snapshot-delay=<seconds>]` renders
            // the Settings window's content into a PNG after the delay, then
            // quits. Works while the screen is locked (no screencapture).
            let path = String(arg.dropFirst("--snapshot-out=".count))
            let delay = args.first(where: { $0.hasPrefix("--snapshot-delay=") })
                .flatMap { Double($0.dropFirst("--snapshot-delay=".count)) } ?? 3
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.writeDebugSnapshot(to: path)
                NSApp.terminate(nil)
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        composerController?.applicationWillTerminate()
    }

    // MARK: - Onboarding

    @objc private func presentOnboarding() {
        if let existing = onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(
            axPermission: axPermission,
            settings: settingsStore,
            keychain: keychainManager,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onFinish: { [weak self] in self?.onboardingWindow?.close() }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to PopGuy"
        window.styleMask = [.titled, .closable]
        // SwiftUI `.frame` on OnboardingView is 560×560, but NSWindow + ScrollView
        // often ignores that intrinsic size and keeps a smaller default.
        window.setContentSize(NSSize(width: 560, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            settingsStore.hasOnboarded = true
            onboardingWindow = nil
        }
        if window === settingsWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Pipeline

    private func startPipelineIfTrusted() {
        guard axPermission.isTrusted, selectionPipeline == nil else { return }
        let pipeline = SelectionPipeline()
        selectionPipeline = pipeline
        pipeline.start()

        // Wire the toolbar controller to the pipeline.
        // ToolbarController is THE single consumer of pipeline.events
        // (AsyncStream bufferingNewest(1) — single consumer by design).
        let controller = ToolbarController(
            pipeline: pipeline,
            settings: settingsStore,
            keychain: keychainManager,
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        toolbarController = controller

        // Wire the OCR capture controller: onText hands the recognized text off
        // to the toolbar (copy-only), anchored at the mouse-up point.
        let ocr = OCRCaptureController(permission: screenRecordingPermission)
        ocr.onText = { [weak controller] text, anchor, image in
            controller?.handleOCRCapture(text: text, anchorPoint: anchor, image: image)
        }
        ocrCaptureController = ocr

        // Wire the Terminal Composer: its socket server runs only while opted in.
        let composer = ComposerController(outputHandler: controller.outputHandler)
        composerController = composer
        if settingsStore.terminalComposerEnabled {
            composer.startServer()
        }

        // Wire ActionEngine into the toolbar via the protocol seam.
        let handler = ActionEngineHandler(
            settings: settingsStore,
            keychain: keychainManager,
            history: historyStore
        )
        actionEngineHandler = handler
        controller.setActionHandler(handler)

        controller.start()

        // Phase 5: start global hotkeys and double-tap chord.
        startHotkeysIfNeeded()
    }

    // MARK: - Phase 5 wiring

    /// Start HotkeyManager and DoubleTapChord; subscribe to settings changes.
    /// Called once after AX trust is established. Idempotent.
    private func startHotkeysIfNeeded() {
        guard hotkeyManager == nil else { return }

        // HotkeyManager: Carbon RegisterEventHotKey for per-action shortcuts.
        let hkm = HotkeyManager()
        hotkeyManager = hkm
        hkm.start()
        applyShortcutBindings()

        // Re-apply whenever the saved bindings change (user edits in ShortcutsView).
        shortcutBindingsCancellable = settingsStore.$shortcutBindings
            .dropFirst()           // skip initial value — applyShortcutBindings() handles that
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyShortcutBindings() }

        // Re-apply whenever custom actions change (their IDs must remain valid in the map).
        customActionsCancellable = settingsStore.$customActions
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyShortcutBindings() }

        // DoubleTapChord: CGEventTap listening for Cmd+C+C.
        // The chord shows the toolbar (show-only, no auto-run).
        // Guards: chord must be enabled AND no replacement shortcut is set.
        // When a replacement shortcut is configured, the chord is a no-op and the
        // replacement is registered as a Carbon hotkey via applyShortcutBindings().
        let chord = DoubleTapChord(
            captureArmSnapshot: { [weak self] in
                // Snapshot the clipboard on the first ⌘C so the user's pre-chord
                // contents can be restored afterward. Only pay the cost when the
                // chord is the active trigger.
                //
                // Cost tradeoff: this runs on every single ⌘C while the chord is
                // enabled (most are not followed by a second tap, so the snapshot
                // is discarded). For text clipboards it is negligible; a very
                // large image/file clipboard pays a main-thread copy per ⌘C. Kept
                // simple deliberately — revisit with a size guard only if it bites.
                guard let self,
                      self.settingsStore.popGuyEnabled,
                      self.settingsStore.triggerChordEnabled,
                      self.settingsStore.chordReplacementShortcut == nil else { return nil }
                return PasteboardSnapshot.capture(from: .general)
            },
            onChord: { [weak self] preChordClipboard in
                guard let self, let controller = self.toolbarController else { return }
                guard self.settingsStore.popGuyEnabled else { return }
                guard self.settingsStore.triggerChordEnabled else { return }
                guard self.settingsStore.chordReplacementShortcut == nil else { return }
                controller.showToolbarForCurrentSelection(preChordClipboard: preChordClipboard)
            }
        )
        doubleTapChord = chord
        chord.start()

        // Re-apply when chord enabled flag or replacement shortcut changes.
        chordEnabledCancellable = settingsStore.$triggerChordEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyShortcutBindings() }

        chordReplacementCancellable = settingsStore.$chordReplacementShortcut
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyShortcutBindings() }

        // Re-apply when the OCR shortcut or its opt-in toggle changes.
        ocrShortcutCancellable = settingsStore.$ocrShortcut
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyShortcutBindings() }

        ocrEnabledCancellable = settingsStore.$ocrEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyShortcutBindings() }

        // Re-apply when the Compose shortcut or the Terminal Composer toggle changes;
        // the toggle also starts/stops the composer's socket server.
        composeShortcutCancellable = settingsStore.$composeShortcut
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyShortcutBindings() }

        terminalComposerEnabledCancellable = settingsStore.$terminalComposerEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.composerController?.startServer()
                } else {
                    self.composerController?.stopServer()
                }
                self.applyShortcutBindings()
            }
    }

    /// A fixed sentinel ActionIdentifier for the chord-replacement shortcut.
    ///
    /// Using a stable UUID ensures this registration never collides with a real
    /// custom action (which uses random UUIDs) or with `.builtin` identifiers.
    /// `register(shortcut:for:action:)` unregisters any previous registration
    /// for this ID before re-registering, so repeated `applyShortcutBindings()`
    /// calls are idempotent.
    private static let chordReplacementActionID: ActionIdentifier =
        .custom(UUID(uuidString: "00000000-0000-0000-0000-000000504F50")!)

    /// A fixed sentinel ActionIdentifier for the OCR screen-text-capture shortcut.
    /// Same rationale as `chordReplacementActionID`: a stable UUID distinct from
    /// both real custom-action UUIDs and the chord-replacement sentinel above.
    private static let ocrCaptureActionID: ActionIdentifier =
        .custom(UUID(uuidString: "00000000-0000-0000-0000-00004F4352AA")!)

    /// A fixed sentinel ActionIdentifier for the Terminal Composer's Compose shortcut.
    /// Same rationale as `chordReplacementActionID` ("COMP" in the last bytes).
    private static let composeActionID: ActionIdentifier =
        .custom(UUID(uuidString: "00000000-0000-0000-0000-0000434F4D50")!)

    /// Build the action map from current settings and call HotkeyManager.applyBindings.
    ///
    /// Single chokepoint: called on init AND on every settings change that affects
    /// hotkeys (bindings, custom actions, chord-enabled, replacement shortcut).
    /// `applyBindings` calls `unregisterAll()` first, so the replacement shortcut
    /// must be re-registered here — otherwise it would be silently cleared on any
    /// binding change.
    private func applyShortcutBindings() {
        guard let hkm = hotkeyManager, let controller = toolbarController else { return }
        let bindings = settingsStore.shortcutBindings

        // Build actionID → HotkeyAction map for all user-configured bindings.
        // Each closure captures `id` by value and reads settingsStore.customActions
        // freshly at fire time so renamed/deleted custom actions are handled correctly.
        var actionMap: [ActionIdentifier: HotkeyAction] = [:]
        for binding in bindings {
            let id = binding.actionID
            actionMap[id] = { [weak controller, weak self] in
                guard let controller, let self else { return }
                guard self.settingsStore.popGuyEnabled else { return }
                controller.triggerAction(for: id, customActions: self.settingsStore.customActions)
            }
        }
        hkm.applyBindings(bindings, actionMap: actionMap)

        // Register the chord-replacement shortcut when set and chord is enabled.
        // applyBindings called unregisterAll() above, so we must re-register here.
        if let replacementShortcut = settingsStore.chordReplacementShortcut,
           settingsStore.triggerChordEnabled {
            hkm.register(
                shortcut: replacementShortcut,
                for: AppDelegate.chordReplacementActionID
            ) { [weak controller, weak self] in
                guard self?.settingsStore.popGuyEnabled == true else { return }
                controller?.showToolbarForCurrentSelection()
            }
        }

        // Register the OCR capture shortcut when set and opted in.
        if let ocrShortcut = settingsStore.ocrShortcut {
            hkm.register(
                shortcut: ocrShortcut,
                for: AppDelegate.ocrCaptureActionID
            ) { [weak self] in
                guard self?.settingsStore.popGuyEnabled == true else { return }
                guard self?.settingsStore.ocrEnabled == true else { return }
                self?.ocrCaptureController?.beginCapture()
            }
        }

        // Register the Compose shortcut only while the Terminal Composer is on, so
        // the key combo is never swallowed with the module off.
        if settingsStore.terminalComposerEnabled, let composeShortcut = settingsStore.composeShortcut {
            hkm.register(
                shortcut: composeShortcut,
                for: AppDelegate.composeActionID
            ) { [weak self] in
                guard let self, self.settingsStore.popGuyEnabled else { return }
                // Read the source app before anything activates PopGuy.
                let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                self.composerController?.beginCompose(sourcePID: sourcePID)
            }
        }
    }

    // MARK: - NSMenuDelegate

    /// Called each time the user opens the status menu. Guarantees the
    /// accessibility state and menu items are current — important for LSUIElement
    /// apps that may not receive didBecomeActiveNotification after returning from
    /// System Settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        axPermission.refresh()
        rebuildMenuItems(in: menu)
        startPipelineIfTrusted()
    }

    // MARK: - Dock icon policy

    /// Applies the correct activation policy based on the showDockIconWithSettings
    /// setting and whether the Settings window is currently visible.
    private func applyDockPolicy() {
        guard let window = settingsWindow, window.isVisible else { return }
        let policy: NSApplication.ActivationPolicy = settingsStore.showDockIconWithSettings ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
    }

    // MARK: - Menu

    func buildStatusMenu() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.imagePosition = .imageOnly
            }
            statusItem = item
        }

        refreshStatusIcon()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        rebuildMenuItems(in: menu)
        statusItem?.menu = menu
    }

    /// Refreshes the status-bar button image to reflect current update-available state.
    /// Called on first build and whenever update availability changes.
    private func refreshStatusIcon() {
        statusItem?.button?.image = statusBarImage(
            updateAvailable: updater.updateAvailable,
            enabled: settingsStore.popGuyEnabled
        )
    }

    /// Builds the status-bar icon. When an update is available, composites a
    /// small accent-colored badge dot onto a copy of the base icon so the tint
    /// remains visible (the composed image is not a template image). When PopGuy
    /// is disabled, the icon is dimmed (grayscale, reduced opacity) to signal the
    /// idle state.
    private func statusBarImage(updateAvailable: Bool, enabled: Bool) -> NSImage? {
        guard let base = NSImage(named: "MenuBarIcon") else { return nil }
        let size = NSSize(width: 18, height: 18)

        if !enabled {
            // Render the template glyph as fixed gray at low opacity so the
            // menu-bar icon reads as "off" rather than auto-tinting to full color.
            let dimmed = NSImage(size: size, flipped: false) { rect in
                base.draw(
                    in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 0.7
                )
                NSColor.secondaryLabelColor.withAlphaComponent(0.6).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            dimmed.isTemplate = false
            dimmed.accessibilityDescription = "PopGuy \u{2014} disabled"
            return dimmed
        }

        if !updateAvailable {
            guard let plain = base.copy() as? NSImage else { return base }
            plain.size = size
            plain.accessibilityDescription = "PopGuy"
            return plain
        }

        // Compose badge: draw the base icon, then a filled accent dot at top-right.
        let composed = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)

            let dotDiameter: CGFloat = 6
            let dotOrigin = NSPoint(
                x: rect.maxX - dotDiameter - 1,
                y: rect.maxY - dotDiameter - 1
            )
            let dotRect = NSRect(origin: dotOrigin, size: NSSize(width: dotDiameter, height: dotDiameter))
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        composed.isTemplate = false
        composed.accessibilityDescription = "PopGuy \u{2014} update available"
        return composed
    }

    /// Populate (or repopulate) the menu items reflecting current trust state.
    /// Extracted so both buildStatusMenu and menuNeedsUpdate share the same logic.
    private func rebuildMenuItems(in menu: NSMenu) {
        menu.removeAllItems()

        // "Update available" banner — shown at the top when an update is pending.
        if updater.updateAvailable {
            let versionLabel = updater.pendingVersion.map { "Update to v\($0)\u{2026}" } ?? "Update available\u{2026}"
            let updateItem = NSMenuItem(
                title: versionLabel,
                action: #selector(performUpdateCheck),
                keyEquivalent: ""
            )
            updateItem.image = NSImage(
                systemSymbolName: "arrow.down.circle",
                accessibilityDescription: nil
            )
            menu.addItem(updateItem)
            menu.addItem(.separator())
        }

        // Accessibility status (informational, always disabled).
        let accessibilityTitle = axPermission.isTrusted
            ? "Accessibility: granted"
            : "Accessibility: not granted"
        let accessibilityItem = NSMenuItem(title: accessibilityTitle, action: nil, keyEquivalent: "")
        accessibilityItem.isEnabled = false
        menu.addItem(accessibilityItem)

        // "Grant Accessibility…" shown only while not trusted.
        if !axPermission.isTrusted {
            menu.addItem(NSMenuItem(
                title: "Grant Accessibility…",
                action: #selector(grantAccessibility),
                keyEquivalent: ""
            ))
        }

        menu.addItem(.separator())

        // Master kill switch — disables every automatic trigger at once.
        let popGuyEnabled = settingsStore.popGuyEnabled
        let disableItem = NSMenuItem(
            title: popGuyEnabled ? "Disable PopGuy" : "Enable PopGuy",
            action: #selector(togglePopGuyEnabled),
            keyEquivalent: ""
        )
        disableItem.image = NSImage(
            systemSymbolName: popGuyEnabled ? "pause.circle" : "play.circle",
            accessibilityDescription: nil
        )
        menu.addItem(disableItem)

        menu.addItem(.separator())

        // Trigger toggles — quick on/off without opening Settings. Greyed out
        // while the master switch is off.
        let selectItem = makeStatusTriggerMenuItem(
            .textSelection,
            isOn: settingsStore.triggerOnSelectEnabled,
            action: #selector(toggleTriggerOnSelect)
        )
        selectItem.isEnabled = popGuyEnabled
        menu.addItem(selectItem)

        let doubleClickItem = makeStatusTriggerMenuItem(
            .doubleClick,
            isOn: settingsStore.triggerDoubleClickEnabled,
            action: #selector(toggleTriggerDoubleClick)
        )
        doubleClickItem.isEnabled = popGuyEnabled
        menu.addItem(doubleClickItem)

        // Show Logo Only — appearance toggle (not a trigger), so it stays enabled
        // while the master switch is off.
        let logoOnlyItem = NSMenuItem(
            title: "Show Logo Only",
            action: #selector(toggleShowLogoOnly),
            keyEquivalent: ""
        )
        logoOnlyItem.state = settingsStore.showLogoOnly ? .on : .off
        logoOnlyItem.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: nil)
        menu.addItem(logoOnlyItem)

        // Capture Screen Text (OCR) — opt-in trigger. Users who have not opted
        // in yet are routed to Settings → Triggers to enable it (and grant
        // Screen Recording permission); once opted in, it directly starts a
        // capture.
        let ocrItem = NSMenuItem(
            title: "Capture Screen Text\u{2026}",
            action: #selector(captureScreenTextOCR),
            keyEquivalent: ""
        )
        ocrItem.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        // Always actionable: when OCR is not yet opted in, the action routes
        // to Settings → the OCR section instead of capturing, so the item
        // never silently does nothing.
        ocrItem.isEnabled = true
        menu.addItem(ocrItem)

        // New Composer — shown only while the Terminal Composer is on. The menu
        // is rebuilt on every open (menuNeedsUpdate), so toggling it needs no refresh.
        if settingsStore.terminalComposerEnabled {
            let composeItem = NSMenuItem(
                title: "New Composer",
                action: #selector(newComposer),
                keyEquivalent: ""
            )
            composeItem.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
            // Show the Compose shortcut for letter keys (the same glyph table as Settings);
            // multi-character glyphs such as "Space" or "F1" are not key equivalents.
            if let shortcut = settingsStore.composeShortcut {
                let glyph = KeyboardShortcut.keyCodeToGlyph(shortcut.keyCode)
                if glyph.count == 1, let letter = glyph.first, letter.isASCII, letter.isLetter {
                    composeItem.keyEquivalent = glyph.lowercased()
                    composeItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
                }
            }
            composeItem.isEnabled = composerController != nil
            menu.addItem(composeItem)
        }

        menu.addItem(.separator())

        // Settings
        menu.addItem(NSMenuItem(
            title: "Settings",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))

        // History — opens Settings directly on the History tab.
        let historyItem = NSMenuItem(
            title: "History",
            action: #selector(openHistory),
            keyEquivalent: ""
        )
        historyItem.image = NSImage(
            systemSymbolName: "clock.arrow.circlepath",
            accessibilityDescription: nil
        )
        menu.addItem(historyItem)

        // About PopGuy — opens Settings directly on the About tab.
        let aboutItem = NSMenuItem(
            title: "About PopGuy",
            action: #selector(openAbout),
            keyEquivalent: ""
        )
        aboutItem.image = NSImage(
            systemSymbolName: "info.circle",
            accessibilityDescription: nil
        )
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem(
            title: "Setup Guide",
            action: #selector(presentOnboarding),
            keyEquivalent: ""
        ))

        menu.addItem(.separator())

        // Check for Updates — always present; enabled only when Sparkle allows it.
        let checkItem = NSMenuItem(
            title: "Check for Updates",
            action: #selector(performUpdateCheck),
            keyEquivalent: ""
        )
        checkItem.isEnabled = updater.canCheckForUpdates
        checkItem.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: nil
        )
        menu.addItem(checkItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit PopGuy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        // macOS 27+ hides menu item images by default; opt our icons back in.
        if #available(macOS 27, *) {
            for item in menu.items where item.image != nil {
                item.preferredImageVisibility = .visible
            }
        }
    }

    @objc private func togglePopGuyEnabled() {
        settingsStore.popGuyEnabled.toggle()
    }

    @objc private func toggleTriggerOnSelect() {
        settingsStore.triggerOnSelectEnabled.toggle()
    }

    @objc private func toggleTriggerDoubleClick() {
        settingsStore.triggerDoubleClickEnabled.toggle()
    }

    @objc private func toggleShowLogoOnly() {
        settingsStore.showLogoOnly.toggle()
    }

    /// Starts an OCR screen-region capture, or routes to Settings → Triggers
    /// when the user has not opted in yet. `beginCapture()` self-guards on
    /// Screen Recording permission (prompts lazily on first use).
    @objc private func captureScreenTextOCR() {
        guard settingsStore.ocrEnabled else {
            settingsNavigator.focusOCRSection = true
            settingsNavigator.section = .triggers
            openSettings()
            return
        }
        ocrCaptureController?.beginCapture()
    }

    /// Opens an empty composer that pastes into the app that was frontmost when the
    /// menu opened (a status menu does not activate PopGuy).
    @objc private func newComposer() {
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        composerController?.beginCompose(sourcePID: sourcePID)
    }

    @objc private func performUpdateCheck() {
        updater.checkForUpdates()
    }

    @objc private func grantAccessibility() {
        axPermission.requestPermission()
    }

    // MARK: - Settings window

    /// Opens Settings on the History tab.
    @objc private func openHistory() {
        settingsNavigator.section = .history
        openSettings()
    }

    /// Opens Settings on the About tab.
    @objc private func openAbout() {
        settingsNavigator.section = .about
        openSettings()
    }

    // MARK: - Open-file handler (Finder double-click / drag-to-app)

    /// Called by AppKit when the user opens a .popclipext bundle or .json file
    /// via Finder double-click or drag-to-dock. Routes the file through the plugin
    /// import consent flow by publishing the URL on SettingsNavigator, then
    /// navigating to the Actions tab and opening Settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        let ext = url.pathExtension.lowercased()
        guard ext == "popclipext" || ext == "json" else { return }
        settingsNavigator.pendingPluginImportURL = url
        settingsNavigator.section = .actions
        openSettings()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settingsStore, keychain: keychainManager, history: historyStore, navigator: settingsNavigator, updater: updater, screenRecordingPermission: screenRecordingPermission, onReplayOnboarding: { [weak self] in self?.presentOnboarding() })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "PopGuy Settings"
            // Full-height left column: content extends under the title bar so the
            // sidebar column reaches the top and the traffic-light buttons sit
            // over it. Title text is hidden so it doesn't overlap the page
            // header rows in the titlebar band.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // An empty unified toolbar (no items) makes the titlebar band ~52 pt
            // tall with the traffic lights vertically centered in it; SwiftUI
            // page header rows sit inside that band.
            window.toolbar = NSToolbar(identifier: "SettingsHeader")
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            // Default size, at most 90% of the screen it opens on (no frame
            // autosave: every new Settings window opens at this size).
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            window.setContentSize(NSSize(width: min(1040, (visible?.width ?? 1040) * 0.9),
                                         height: min(760, (visible?.height ?? 760) * 0.9)))
            window.center()
            window.delegate = self
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        #if DEBUG
        if let size = Self.debugQASettingsSize {
            // QA: `--settings-size=<W>x<H>` sets the content size (AppKit
            // clamps it to the SwiftUI minimum: 720 wide, ~450 tall).
            settingsWindow?.setContentSize(size)
        }
        if let screen = Self.debugQAScreen, let window = settingsWindow {
            // QA screenshots: show the window on the named display without
            // activating the app, so it never takes the user's focus.
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
            window.orderFrontRegardless()
            return
        }
        #endif
        settingsWindow?.makeKeyAndOrderFront(nil)
        if settingsStore.showDockIconWithSettings {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    #if DEBUG
    /// QA hook `--open-composer`: the open test composer and its autosave (kept alive while shown).
    private var debugComposerWindow: ComposerWindow?
    private var debugComposerAutosave: AnyCancellable?

    private func openDebugComposer(sessionEnded: Bool) {
        let store = ComposerDraftStore()
        let draftID = UUID()
        let model = ComposerModel(text: """
            # Composer sample

            Some prose with `inline code` and **bold** text.

            - first item
            - second item
            1. numbered item

            ```swift
            let greeting = "Hello"
            print(greeting)
            ```
            """, sourceAppName: "Terminal")
        model.sessionEnded = sessionEnded
        store.prune()

        // Logs states only, never the text.
        let close: (String) -> Void = { [weak self] state in
            NSLog("PopGuy composer (debug): %@", state)
            self?.debugComposerAutosave = nil
            self?.debugComposerWindow?.close()
        }
        model.onDone = { store.delete(id: draftID); close("done, draft deleted") }
        model.onDoneAndSubmit = { store.delete(id: draftID); close("done and submit, draft deleted") }
        model.onCancel = { store.flush(); close("cancel, draft kept") }
        model.onCopyAndClose = { store.flush(); close("copy and close, draft kept") }
        model.onRestoreDraft = { [weak model] in
            Task { @MainActor in
                guard let draft = await store.latestDraft(excluding: draftID) else { return }
                model?.text = draft.text
                model?.draftAvailable = false
                NSLog("PopGuy composer (debug): draft restored (%ld bytes)", draft.text.utf8.count)
            }
        }
        debugComposerAutosave = model.$text.dropFirst().sink { store.scheduleSave(id: draftID, text: $0) }
        Task { @MainActor [weak model] in
            let available = await store.latestDraft(excluding: draftID) != nil
            model?.draftAvailable = available
            NSLog("PopGuy composer (debug): draft available %@", available ? "yes" : "no")
        }

        let window = ComposerWindow(rootView: ComposerView(model: model))
        debugComposerWindow = window
        window.show()
    }

    /// QA hook: `--settings-screen=<name substring>` (e.g. "Built-in") places the
    /// Settings window on that display and does not activate the app.
    private static var debugQAScreen: NSScreen? {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--settings-screen=") }) else { return nil }
        let name = String(arg.dropFirst("--settings-screen=".count))
        return NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains(name) }
    }

    /// QA hook: `--settings-size=<W>x<H>` (e.g. 720x460) sets the Settings
    /// window's content size, so its minimum can be screenshotted.
    private static var debugQASettingsSize: NSSize? {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--settings-size=") }) else { return nil }
        let parts = arg.dropFirst("--settings-size=".count).split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
        return NSSize(width: w, height: h)
    }

    /// QA hook for `--snapshot-out=`: draws the Settings window's content view
    /// into a PNG at `path` (visual-effect blur may render flat).
    private func writeDebugSnapshot(to path: String) {
        guard let view = settingsWindow?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("PopGuy snapshot: no Settings window")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            NSLog("PopGuy snapshot: %@", error.localizedDescription)
        }
    }
    #endif
}
