// ComposerController.swift
// PopGuy
//
// Runs the Terminal Composer: owns the socket server, the one reused composer window
// and its model, and the draft store.
//
//   - CLI session (popguy-edit): "open" shows the composer with the file's text;
//     Done replies "done", Cancel / Esc / close button reply "cancel". The client
//     going away while the composer is open shows the "Session ended" state.
//     Done & Submit waits for the CLI to confirm the write ("written") and exit,
//     then presses Return in the source app.
//   - Compose (hotkey): an empty composer whose footer names the target app; Done
//     pastes into it, Done & Submit pastes and presses Return. A failed paste copies
//     the text instead. Without a target, Done is Copy & Close.
//
// Drafts: autosaved while the text differs from the opening text; saved at Done and
// deleted once the text was delivered (the CLI confirmed the write after "done", or a
// successful paste); kept otherwise.
// Prompt text is never logged; only states, byte counts and session ids.

import AppKit
import Combine
import os

@MainActor
final class ComposerController: NSObject, ComposerServerDelegate, NSWindowDelegate {

    /// Pause between the text arriving (CLI exit or paste) and the auto-submit Return.
    static let autoSubmitDelay: Duration = .milliseconds(300)
    /// How long Done & Submit / draft cleanup waits for the CLI to exit after "done".
    private static let sessionEndTimeout: Duration = .seconds(5)
    /// How long auto-submit waits for the source app to become frontmost.
    private static let activationTimeout: Duration = .seconds(1)
    private static let activationPollInterval: Duration = .milliseconds(30)

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PopGuy", category: "composer")

    /// The open composer, if any.
    private enum State {
        case idle
        case cli(session: ComposerSession, sourcePID: pid_t?, draftID: UUID)
        case compose(sourcePID: pid_t?, draftID: UUID)
    }

    /// A CLI session that got its "done" reply and has not ended yet.
    private struct Delivery {
        let draftID: UUID
        let submit: Bool
        let sourcePID: pid_t?
    }

    private let outputHandler: OutputHandler
    private let server = ComposerServer()
    private let store = ComposerDraftStore()
    private let model = ComposerModel()
    private lazy var window: ComposerWindow = {
        let window = ComposerWindow(rootView: ComposerView(model: model))
        window.delegate = self
        return window
    }()

    private var state: State = .idle
    private var awaitingEnd: [ComposerSession: Delivery] = [:]
    private var autosave: AnyCancellable?
    private(set) var isServerRunning = false

    init(outputHandler: OutputHandler) {
        self.outputHandler = outputHandler
        super.init()
        server.delegate = self
        model.onDone = { [weak self] in self?.done(submit: false) }
        model.onDoneAndSubmit = { [weak self] in self?.done(submit: true) }
        model.onCancel = { [weak self] in self?.cancel() }
        model.onCopyAndClose = { [weak self] in self?.cancel() }
        model.onRestoreDraft = { [weak self] in self?.restoreDraft() }
    }

    // MARK: Server lifecycle

    @discardableResult
    func startServer() -> Bool {
        isServerRunning = server.start()
        return isServerRunning
    }

    /// Stops listening; an open CLI composer switches to "Session ended".
    func stopServer() {
        server.stop()
        isServerRunning = false
    }

    /// App quit: writes pending drafts and removes the socket.
    func applicationWillTerminate() {
        store.flush()
        server.stop()
        isServerRunning = false
    }

    // MARK: Opening

    /// Compose mode: an empty composer whose Done pastes into `sourcePID`.
    /// If a composer is already open, brings it forward instead.
    func beginCompose(sourcePID: pid_t?) {
        guard case .idle = state else {
            bringForward()
            return
        }
        let target = sourcePID
            .flatMap { $0 == ProcessInfo.processInfo.processIdentifier ? nil : NSRunningApplication(processIdentifier: $0) }
            .flatMap { $0.isTerminated ? nil : $0 }
        let draftID = UUID()
        state = .compose(sourcePID: target?.processIdentifier, draftID: draftID)
        Self.log.info("Composer: compose opened (source \(target == nil ? "none" : "app", privacy: .public))")
        open(text: "", sourceAppName: nil, draftID: draftID,
             compose: (noTarget: target == nil, targetName: target?.localizedName))
    }

    /// Brings the open composer to the front (no-op when none is open).
    func bringForward() {
        if case .idle = state { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// `compose` is set for Compose mode: whether it has no target, and the target's name.
    private func open(text: String, sourceAppName: String?, draftID: UUID,
                      compose: (noTarget: Bool, targetName: String?)? = nil) {
        model.text = text
        model.sourceAppName = sourceAppName
        model.sessionEnded = false
        model.noTarget = compose?.noTarget ?? false
        model.pasteTargetName = compose?.targetName
        model.draftAvailable = false
        // One window is reused: drop the previous composer's undo history.
        window.undoManager?.removeAllActions()
        autosave = model.$text.dropFirst().sink { [weak self] newText in
            self?.saveDraftIfChanged(newText, draftID: draftID, openedText: text)
        }
        store.prune()
        window.show()
        Task { [weak self] in
            guard let self else { return }
            let available = await store.latestDraft(excluding: draftID) != nil
            guard currentDraftID == draftID else { return }
            model.draftAvailable = available
        }
    }

    private func saveDraftIfChanged(_ text: String, draftID: UUID, openedText: String) {
        if text != openedText {
            store.scheduleSave(id: draftID, text: text)
        } else {
            store.delete(id: draftID)
        }
    }

    private func restoreDraft() {
        guard let draftID = currentDraftID else { return }
        Task { [weak self] in
            guard let self, let draft = await store.latestDraft(excluding: draftID),
                  currentDraftID == draftID else { return }
            model.text = draft.text
            model.draftAvailable = false
            window.undoManager?.removeAllActions()
            // The text now lives on as this composer's draft.
            store.delete(id: draft.id)
            Self.log.info("Composer: draft restored (\(draft.text.utf8.count) bytes)")
        }
    }

    private var currentDraftID: UUID? {
        switch state {
        case .idle: nil
        case .cli(_, _, let draftID), .compose(_, let draftID): draftID
        }
    }

    // MARK: Done / Cancel

    private func done(submit: Bool) {
        switch state {
        case .idle:
            return
        case .cli(let session, let sourcePID, let draftID):
            let text = ComposerFileRules.normalizeLineEndings(model.text)
            // The final text is on disk before the reply (flush waits for the save on the
            // store's serial queue), so a failed write loses nothing.
            store.save(id: draftID, text: text)
            store.flush()
            server.reply(.done(text: text, submit: submit), to: session)
            Self.log.info("Composer: session done (\(text.utf8.count) bytes, submit \(submit))")
            awaitingEnd[session] = Delivery(draftID: draftID, submit: submit, sourcePID: sourcePID)
            closeWindow()
            Task { [weak self] in
                try? await Task.sleep(for: Self.sessionEndTimeout)
                guard self?.awaitingEnd.removeValue(forKey: session) != nil else { return }
                Self.log.info("Composer: session did not end in time; draft kept, no auto-submit")
            }
        case .compose(let sourcePID, let draftID):
            let text = model.text
            closeWindow()
            guard let sourcePID, !text.isEmpty else {
                Self.log.info("Composer: compose done without a target or text; nothing pasted")
                return
            }
            Task { [weak self] in
                guard let self else { return }
                switch await outputHandler.pasteIntoApp(text, pid: sourcePID) {
                case .pasted:
                    break
                case .busy:
                    // Another paste owns the pasteboard; writing to it now would
                    // race that paste's Cmd+V and restore. Keep the draft only.
                    Self.log.info("Composer: compose paste busy; draft kept, not copied")
                    return
                case .targetUnavailable:
                    // Explicit fallback, like Copy & Close: the text stays on the
                    // clipboard (no restore), the draft is kept, no Return. The
                    // nspasteboard.org markers keep it out of clipboard managers.
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                    pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                    Self.log.info("Composer: compose paste failed; text copied, draft kept")
                    return
                }
                store.delete(id: draftID)
                Self.log.info("Composer: compose pasted (\(text.utf8.count) bytes)")
                guard submit else { return }
                try? await Task.sleep(for: Self.autoSubmitDelay)
                await pressReturn(in: sourcePID)
            }
        }
    }

    /// Cancel, Esc, close button, and Copy & Close (which copied the text already).
    private func cancel() {
        switch state {
        case .idle:
            return
        case .cli(let session, _, _):
            server.reply(.cancel, to: session)
        case .compose:
            break
        }
        store.flush()
        Self.log.info("Composer: cancelled; draft kept")
        closeWindow()
    }

    /// Hides the window (focus returns to the source app) and stops autosave.
    private func closeWindow() {
        autosave = nil
        state = .idle
        model.draftAvailable = false
        window.close()
    }

    // MARK: Auto-submit

    /// Reactivates `pid`, waits until it is frontmost, then presses Return. Any failed
    /// check skips the Return silently.
    private func pressReturn(in pid: pid_t) async {
        guard case .idle = state else {
            Self.log.info("Composer: auto-submit skipped (a composer is open)")
            return
        }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            Self.log.info("Composer: auto-submit skipped (source app gone)")
            return
        }
        if !Self.isFrontmost(pid) {
            if #available(macOS 14, *) {
                NSApp.yieldActivation(to: app)
            }
            app.activate(options: [])
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.activationTimeout)
        while !Self.isFrontmost(pid), clock.now < deadline {
            try? await Task.sleep(for: Self.activationPollInterval)
        }
        let posted = outputHandler.postReturn(to: pid)
        Self.log.info("Composer: auto-submit \(posted ? "sent" : "skipped (source not frontmost)", privacy: .public)")
    }

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    // MARK: ComposerServerDelegate

    func composerServer(_ server: ComposerServer, didOpen session: ComposerSession, text: String, fileName: String) {
        guard case .idle = state else {
            server.reply(.busy, to: session)
            bringForward()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let source = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        let draftID = UUID()
        state = .cli(session: session, sourcePID: source?.processIdentifier, draftID: draftID)
        open(text: text, sourceAppName: source?.localizedName, draftID: draftID)
    }

    func composerServer(_ server: ComposerServer, sessionDidEnd session: ComposerSession, delivered: Bool) {
        if let delivery = awaitingEnd.removeValue(forKey: session) {
            guard delivered else {
                // The CLI ended without confirming the write: keep the draft, no Return.
                store.flush()
                Self.log.info("Composer: session ended without a confirmed write; draft kept, no auto-submit")
                return
            }
            // Normal end after "done": the CLI wrote the file and exited.
            store.delete(id: delivery.draftID)
            Self.log.info("Composer: delivered session ended; draft deleted")
            if delivery.submit, let pid = delivery.sourcePID {
                Task { [weak self] in
                    try? await Task.sleep(for: Self.autoSubmitDelay)
                    await self?.pressReturn(in: pid)
                }
            }
            return
        }
        guard case .cli(let current, _, _) = state, current == session else { return }
        Self.log.info("Composer: session ended while open")
        model.sessionEnded = true
    }

    func composerServerDidRejectBusy(_ server: ComposerServer) {
        bringForward()
    }

    // MARK: NSWindowDelegate

    /// The close button (and Cmd+W) cancel; programmatic `close()` does not come here.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }
}
