// EmojiPickerController.swift
// PopGuy — EmojiPicker
//
// Owns the emoji picker panel: builds the catalog off the main thread while the feature
// is on, opens the panel at the caret of the frontmost app on the hotkey, hides it, and
// hands the picked emoji to `EmojiInserter` (ported from FastMoji's hotkey picker).
//
// Password guard, two layers: no picker while the system's Secure Input is on (Carbon; macOS
// turns it on while any password field has the focus, web password inputs and Terminal's
// Secure Keyboard Entry included), nor when the focused element reads as a password field
// (Accessibility). Secure Input is checked again at insert time: when it is on, the pick is
// copied instead of typed.
//
// Isolation: MainActor (AppKit windows, SwiftUI models); the Accessibility lookups run in
// detached tasks.

import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI

@MainActor
final class EmojiPickerController {
    /// How long the caret lookup may take before the panel opens at the pointer instead.
    private static let caretDeadline: UInt64 = 250_000_000
    /// Pause between hiding the panel and typing, so the source app has the key focus back.
    private static let insertDelay: UInt64 = 80_000_000
    /// Escape.
    private static let escapeKeyCode: UInt16 = 53

    private let settings: SettingsStore
    private let hideToolbar: () -> Void
    private let onOpenSettings: () -> Void

    /// The picker's model once the catalog is built (nil shows a loading placeholder).
    private let content = EmojiPickerContent()
    private var panel: EmojiPickerPanel?
    private var isShowing = false

    /// Bumped by every catalog build and free, so a stale build is dropped.
    private var loadGeneration = 0
    /// Bumped by every hotkey press (and by `unload()`), so a stale caret lookup is ignored.
    private var lookupRequest = 0
    private var isLocating = false
    /// The app that was frontmost when the picker opened; the pick goes back to it.
    private var targetPID: pid_t?

    private var resignKeyObserver: NSObjectProtocol?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    init(settings: SettingsStore, hideToolbar: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.settings = settings
        self.hideToolbar = hideToolbar
        self.onOpenSettings = onOpenSettings
    }

    // MARK: - Catalog

    /// Builds the catalog and its search index in the background (the feature was turned on,
    /// or it is on at launch). Never called on the key press.
    func preload() {
        guard content.model == nil else { return }
        loadGeneration += 1
        let generation = loadGeneration
        Task { [weak self] in
            let (catalog, search) = await Task.detached(priority: .utility) {
                let index = CatalogIndex(catalog: EmojiCatalog.load())
                return (PickerCatalog(index: index), EmojiSearch(index: index))
            }.value
            guard let self, generation == self.loadGeneration, self.settings.emojiPickerEnabled else { return }
            let model = EmojiPickerModel(catalog: catalog, search: search, frecency: EmojiFrecency())
            model.onConfirm = { [weak self] emoji in self?.confirm(emoji) }
            self.content.model = model
        }
    }

    /// Hides the picker, cancels an opening in flight and frees the catalog (the feature was
    /// turned off).
    func unload() {
        lookupRequest += 1
        isLocating = false
        loadGeneration += 1
        hide()
        content.model = nil
    }

    // MARK: - Toggle

    /// The hotkey: hides a visible picker, cancels an opening in flight, or opens the picker
    /// at the caret of the frontmost app.
    func toggle() {
        if isShowing {
            hide()
            return
        }
        lookupRequest += 1
        let request = lookupRequest
        if isLocating {
            isLocating = false
            return
        }
        // Secure Input on (a password field has the focus somewhere): no picker and no lookup.
        guard !IsSecureEventInputEnabled() else { return }
        hideToolbar()
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        targetPID = pid
        // PopGuy itself (or nothing) frontmost: no host caret to find; a pick is copied.
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else {
            show(at: EmojiCaretLocator.screenRect(fromAX: .none))
            return
        }
        isLocating = true
        Task { [weak self] in
            // Password field (read through Accessibility): no picker, however long the check takes.
            let secure = await Task.detached(priority: .userInitiated) {
                EmojiCaretLocator.focusedIsSecure(pid: pid)
            }.value
            guard let self, request == self.lookupRequest else { return }
            guard !secure else {
                self.isLocating = false
                return
            }
            let lookup = await Self.caretLookup(pid: pid)
            guard request == self.lookupRequest else { return }
            self.isLocating = false
            self.show(at: EmojiCaretLocator.screenRect(fromAX: lookup))
        }
    }

    /// The caret lookup in the background, or `.none` (the pointer) when it takes longer than
    /// `caretDeadline`. A hung lookup is left behind: its late result is dropped.
    private static func caretLookup(pid: pid_t) async -> CaretLookup {
        await withCheckedContinuation { continuation in
            let gate = ResumeOnce()
            Task.detached(priority: .userInitiated) {
                let lookup = EmojiCaretLocator.axCaretRect(pid: pid)
                Task { @MainActor in gate.resume(continuation, returning: lookup) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: caretDeadline)
                gate.resume(continuation, returning: .none)
            }
        }
    }

    // MARK: - Show / hide

    private func show(at caret: NSRect) {
        let panel = self.panel ?? makePanel()
        content.model?.resetWithoutAnimation()
        panel.setFrame(EmojiPickerPanel.frame(caret: caret), display: false)
        isShowing = true
        panel.makeKeyAndOrderFront(nil)
        // Transparent window: recompute the shadow from the rounded content.
        panel.invalidateShadow()
        installMonitors()
    }

    /// Idempotent: hiding the key panel posts its resign-key notification, which calls back here.
    func hide() {
        guard isShowing else { return }
        isShowing = false
        removeMonitors()
        // `orderOut` also drops an attached hover tooltip (see `EmojiPickerPanel`).
        panel?.orderOut(nil)
    }

    private func makePanel() -> EmojiPickerPanel {
        let panel = EmojiPickerPanel(content: EmojiPickerRoot(
            content: content,
            settings: settings,
            onCancel: { [weak self] in self?.hide() },
            onOpenSettings: { [weak self] in
                self?.hide()
                self?.onOpenSettings()
            }
        ))
        // Cmd+Tab, a Space switch or a click elsewhere takes the key status away.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        self.panel = panel
        return panel
    }

    private func installMonitors() {
        removeMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            // Global monitors deliver on the main thread.
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel,
                      !panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }
        // Esc while the catalog is still loading (the picker view handles it afterwards).
        // Local monitors are called on the main thread.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == Self.escapeKeyCode, self.content.model == nil,
                  event.window === self.panel else { return event }
            self.hide()
            return nil
        }
    }

    private func removeMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalClickMonitor = nil
        localKeyMonitor = nil
    }

    // MARK: - Insert

    /// Types the pick into the source app when it still has the focus, else copies it. Never
    /// types while Secure Input is on (a password field took the focus meanwhile): copies instead.
    private func confirm(_ emoji: Emoji) {
        let text = emoji.toned(settings.emojiSkinTone)
        let pid = targetPID
        hide()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.insertDelay)
            if !IsSecureEventInputEnabled(), AXIsProcessTrusted(), let pid, pid != ProcessInfo.processInfo.processIdentifier,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                EmojiInserter.type(text)
            } else {
                EmojiInserter.copy(text)
            }
        }
    }
}

// MARK: - Resume once

/// Resumes a continuation for the first caller only (the caret lookup or its deadline).
private final class ResumeOnce {
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<CaretLookup, Never>, returning lookup: CaretLookup) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: lookup)
    }
}

// MARK: - Panel content

/// The picker's model, set once the catalog is built.
private final class EmojiPickerContent: ObservableObject {
    @Published var model: EmojiPickerModel?
}

/// The picker, or a placeholder of the same card while the catalog loads.
private struct EmojiPickerRoot: View {
    @ObservedObject var content: EmojiPickerContent
    let settings: SettingsStore
    let onCancel: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        if let model = content.model {
            EmojiPickerView(model: model, settings: settings, onCancel: onCancel, onOpenSettings: onOpenSettings)
        } else {
            EmojiPickerPlaceholder()
        }
    }
}

/// Same card shape as `EmojiPickerView`; its spinner fades in only after 150 ms, so a fast
/// load never flashes it.
private struct EmojiPickerPlaceholder: View {
    @State private var showsSpinner = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ProgressView()
            .controlSize(.small)
            .opacity(showsSpinner ? 1 : 0)
            .frame(width: EmojiPickerPanel.contentSize.width, height: EmojiPickerPanel.contentSize.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                withAnimation(.easeIn(duration: 0.2)) { showsSpinner = true }
            }
    }
}
