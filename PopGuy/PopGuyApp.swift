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
    private var selectionPipeline: SelectionPipeline?
    private var toolbarController: ToolbarController?
    private var permissionObserver: NSObjectProtocol?

    // MARK: - Shared services (created once, injected into subsystems)

    private let settingsStore = SettingsStore()
    private let keychainManager = KeychainManager()
    private let historyStore = HistoryStore()
    private let licenseGate = LicenseGate()
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

    // MARK: - Upgrade nag

    private var upgradeNagWindow: NSWindow?

    // MARK: - Trial expiry warning

    private var trialExpiryWindow: NSWindow?

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

    /// Combine subscription — warms persisted Babylon BGL indexes when loaded dictionaries change.
    private var babylonIndexWarmupCancellable: AnyCancellable?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI Previews launch the full app; skip the launch side effects
        // (status item, CGEventTap chord, accessibility pipeline) which crash
        // the preview host. The env var is only set while previewing.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }

        #if DEV_MOCK_PRO
        // Dev-distribution build only: scripts/sign-and-share.sh passes the
        // DEV_MOCK_PRO compilation condition so any key unlocks Pro for testers
        // on another Mac. This flag lives ONLY in that script — never add it to
        // the project's build settings, or an official release would ship the
        // mock validator. No env var needed: the validator is forced on.
        licenseGate.validator = MockLicenseValidator()
        #elseif DEBUG
        // DEBUG escape hatch: set POPGUY_MOCK_PRO=1 in the Run scheme to use a
        // fake validator (any non-empty key → Pro) while the Lemon Squeezy
        // account is unverified. Never compiled into Release.
        if ProcessInfo.processInfo.environment["POPGUY_MOCK_PRO"] != nil {
            licenseGate.validator = MockLicenseValidator()
        } else {
            licenseGate.validator = LemonSqueezyLicenseValidator()
        }
        #else
        licenseGate.validator = LemonSqueezyLicenseValidator()
        #endif
        licenseGate.restoreCachedEntitlement()
        licenseGate.bootstrapTrial()
        if licenseGate.shouldPresentTrialExpiryWarning {
            presentTrialExpiryWarning()
        }
        buildStatusMenu()
        Self.warmBabylonIndexes(settingsStore.babylonDictionaries)
        babylonIndexWarmupCancellable = settingsStore.$babylonDictionaries
            .dropFirst()
            .sink { dictionaries in
                Self.warmBabylonIndexes(dictionaries)
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
    }

    // MARK: - Onboarding

    private func presentOnboarding() {
        let view = OnboardingView(
            axPermission: axPermission,
            trialState: licenseGate.trialState,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onGetPro: { NSWorkspace.shared.open(ProConfig.checkoutURL) },
            onFinish: { [weak self] in self?.onboardingWindow?.close() }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to PopGuy"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Upgrade nag popup

    /// Present a soft, dismissable upgrade prompt when a free-tier act milestone is hit.
    ///
    /// Guards: only shown at runtime (no-op in Xcode Previews), only to non-Pro
    /// users, and only when no nag window is already open (no stacking).
    private func presentUpgradeNag() {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        guard !licenseGate.entitlements.isPro else { return }
        guard upgradeNagWindow == nil else { return }

        let actCount = settingsStore.actCount
        let view = UpgradeNagView(
            actCount: actCount,
            onClose: { [weak self] in
                self?.upgradeNagWindow?.close()
            },
            onGetPro: { [weak self] in
                guard let self else { return }
                self.upgradeNagWindow?.close()
                self.settingsNavigator.section = .license
                self.openSettings()
            }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Enjoying PopGuy?"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        upgradeNagWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Trial expiry warning popup

    /// Present a one-time warning that the free trial has ended.
    ///
    /// Acknowledgement is recorded immediately before the window appears so a
    /// crash-before-dismiss never triggers a second presentation.
    private func presentTrialExpiryWarning() {
        guard trialExpiryWindow == nil else { return }
        licenseGate.acknowledgeTrialExpiry()
        let view = TrialExpiryWarningView(
            onGetPro: { [weak self] in
                NSWorkspace.shared.open(ProConfig.checkoutURL)
                self?.trialExpiryWindow?.close()
            },
            onContinue: { [weak self] in
                self?.trialExpiryWindow?.close()
            }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Free Trial Ended"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        trialExpiryWindow = window
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
        if window === upgradeNagWindow {
            upgradeNagWindow = nil
        }
        if window === trialExpiryWindow {
            trialExpiryWindow = nil
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
            licenseGate: licenseGate,
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        toolbarController = controller

        // Wire ActionEngine into the toolbar via the protocol seam.
        let handler = ActionEngineHandler(
            settings: settingsStore,
            keychain: keychainManager,
            history: historyStore
        )
        actionEngineHandler = handler
        controller.setActionHandler(handler)

        // Wire upgrade nag: shown when free-tier act count hits 101, 111, 121, …
        controller.onUpgradeNagDue = { [weak self] in
            self?.presentUpgradeNag()
        }

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
    }

    private static func warmBabylonIndexes(_ dictionaries: [BabylonDictionary]) {
        let enabled = dictionaries.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        Task {
            await BabylonBGLIndexCache.shared.warm(dictionaries: enabled)
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

        menu.addItem(.separator())

        // Settings…
        menu.addItem(NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))

        // History — opens Settings directly on the History tab.
        let historyItem = NSMenuItem(
            title: "History\u{2026}",
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
            title: "About PopGuy\u{2026}",
            action: #selector(openAbout),
            keyEquivalent: ""
        )
        aboutItem.image = NSImage(
            systemSymbolName: "info.circle",
            accessibilityDescription: nil
        )
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Check for Updates — always present; enabled only when Sparkle allows it.
        let checkItem = NSMenuItem(
            title: "Check for Updates\u{2026}",
            action: #selector(performUpdateCheck),
            keyEquivalent: ""
        )
        checkItem.isEnabled = updater.canCheckForUpdates
        checkItem.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: nil
        )
        menu.addItem(checkItem)

        // Pro / activation status.
        if licenseGate.entitlements.isPro {
            let proItem = NSMenuItem(title: "PopGuy Pro — Active", action: nil, keyEquivalent: "")
            proItem.image = NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: nil)
            proItem.isEnabled = false
            menu.addItem(proItem)
        } else {
            let upgradeItem = NSMenuItem(
                title: "Upgrade to Pro\u{2026}",
                action: #selector(openLicense),
                keyEquivalent: ""
            )
            upgradeItem.image = NSImage(systemSymbolName: "crown", accessibilityDescription: nil)
            menu.addItem(upgradeItem)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit PopGuy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
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

    /// Opens Settings on the License tab (called from the "Upgrade to Pro…" menu item).
    @objc private func openLicense() {
        settingsNavigator.section = .license
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
            let view = SettingsView(settings: settingsStore, keychain: keychainManager, history: historyStore, navigator: settingsNavigator, licenseGate: licenseGate, updater: updater)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "PopGuy Settings"
            // Full-height left column: content extends under the title bar so the
            // sidebar column reaches the top and the traffic-light buttons sit
            // over it. Title text is hidden (no toolbar) to avoid overlapping
            // content in the borderless top area.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 760, height: 520))
            window.center()
            window.delegate = self
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        if settingsStore.showDockIconWithSettings {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
