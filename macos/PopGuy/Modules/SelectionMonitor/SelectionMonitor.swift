// SelectionMonitor.swift
// PopGuy
//
// Observes AXSelectedTextChanged notifications on the frontmost application's
// focused UI element. When the focused app changes, the AXObserver is
// re-attached to the new app's element automatically.
//
// Strict-concurrency design:
//   AXObserver uses a C callback with a void* refcon. The refcon carries an
//   Unmanaged<SelectionMonitor> pointer (passUnretained). Inside the callback
//   we recover the instance via takeUnretainedValue(), then hop to @MainActor
//   via Task { @MainActor in … } to publish the event.
//   The observer source is added to the main run loop so that the C callback
//   fires on the main thread, making the Task hop lightweight and data-race-free.
//
// Manual-QA note:
//   PopGuy is an LSUIElement accessory app and may not receive
//   NSApplication.didBecomeActiveNotification reliably on return from System
//   Settings. The trust-state line in the menu is therefore best verified by
//   reopening the menu (which calls menuNeedsUpdate) rather than relying on
//   app-activation. The human tester should note this.
//
// deinit / nonisolated(unsafe) rationale:
//   currentObserver and currentObservedElement are declared nonisolated(unsafe)
//   so that the nonisolated deinit can read them to release the AX observer.
//   Safety: both are only mutated on the MainActor (all write sites are
//   @MainActor methods). deinit runs after the last retain is released, at which
//   point no concurrent MainActor mutation can be in flight.

import AppKit
import ApplicationServices
import Combine

/// Emitted every time AXSelectedTextChanged fires on the frontmost element.
struct SelectionChangedSignal: Sendable {
    /// The PID of the application whose selection changed.
    let pid: pid_t
}

/// Observes `kAXSelectedTextChangedNotification` across all applications via
/// the Accessibility API.
///
/// Re-attaches the AXObserver when the frontmost application changes using
/// `NSWorkspace.didActivateApplicationNotification` on
/// `NSWorkspace.shared.notificationCenter` (the workspace-specific centre,
/// not `NotificationCenter.default`).
@MainActor
final class SelectionMonitor {

    // MARK: - Published output

    /// Fires whenever selected text changes in the frontmost application.
    let selectionChanged = PassthroughSubject<SelectionChangedSignal, Never>()

    // MARK: - Private state

    // nonisolated(unsafe): only mutated on MainActor; deinit needs to read
    // them to release the AX observer from a nonisolated context. Safe because
    // deinit runs after the last retain, so no MainActor write can race it.
    nonisolated(unsafe) private var currentObserver: AXObserver?
    // The element the notification was registered on — needed for
    // AXObserverRemoveNotification (must match the element used at AddNotification).
    nonisolated(unsafe) private var currentObservedElement: AXUIElement?
    private var currentPid: pid_t?
    private var activationObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    init() {}

    deinit {
        // deinit is nonisolated under Swift 6; we can only call thread-safe C APIs here.
        // CFRunLoopRemoveSource and AXObserverRemoveNotification are both C APIs safe
        // to call from any thread.
        if let observer = currentObserver, let element = currentObservedElement {
            AXObserverRemoveNotification(
                observer,
                element,
                kAXSelectedTextChangedNotification as CFString
            )
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
    }

    /// Start monitoring. Safe to call multiple times.
    func start() {
        attachToFrontmostApp()

        // NSWorkspace notifications are on `NSWorkspace.shared.notificationCenter`,
        // NOT `NotificationCenter.default`. Using the default center compiles but
        // never fires for workspace events — silent failure.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.attachToFrontmostApp()
            }
        }
    }

    /// Stop monitoring and release the current observer.
    func stop() {
        detachCurrentObserver()
        if let obs = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            activationObserver = nil
        }
    }

    // MARK: - Observer management

    private func attachToFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard pid != currentPid else { return }

        detachCurrentObserver()

        // `refcon` carries `self` as an unretained opaque pointer.
        // The literal closure below is @convention(c)-compatible and captures
        // nothing — context is recovered from refcon on each invocation.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var observer: AXObserver?
        let err = AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<SelectionMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // The source runs on the main run loop, but Task is required to
            // call @MainActor methods from within a @convention(c) callback.
            Task { @MainActor in
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                monitor.selectionChanged.send(SelectionChangedSignal(pid: pid))
            }
        }, &observer)

        guard err == .success, let observer else { return }

        // CRITICAL 2: Register on the focused element if obtainable, else fall
        // back to the app-level element. Some apps fire AXSelectedTextChanged
        // on the focused text control rather than the app root.
        // Limitation: intra-app focus changes (user moves focus to a different
        // text field within the same app) are not re-registered — the worst
        // case is a missed event from the new field until a re-attach fires.
        let appElement = AXUIElementCreateApplication(pid)
        let targetElement: AXUIElement
        var focusedRef: AnyObject?
        let focusErr = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        if focusErr == .success,
           let focusedRef,
           CFGetTypeID(focusedRef as CFTypeRef) == AXUIElementGetTypeID() {
            targetElement = (focusedRef as CFTypeRef) as! AXUIElement
        } else {
            targetElement = appElement
        }

        // FIX 3: If registration on the focused element fails, retry on the
        // app-level element.  Some apps (e.g. Electron-based) report
        // .notificationUnsupported on the focused element but accept the
        // notification on the app root.
        //
        // registeredElement is the element AddNotification actually succeeded
        // on; this is what we must pass to RemoveNotification and what we store
        // in currentObservedElement so deinit/detach remove from the correct element.
        let registeredElement: AXUIElement
        let obsErr = AXObserverAddNotification(
            observer,
            targetElement,
            kAXSelectedTextChangedNotification as CFString,
            selfPtr
        )
        if obsErr == .success {
            // Registration on the focused element succeeded — preferred path.
            registeredElement = targetElement
        } else if targetElement !== appElement {
            // Registration on the focused element failed, and it's a different
            // element from the app root — retry on the app-level element.
            let retryErr = AXObserverAddNotification(
                observer,
                appElement,
                kAXSelectedTextChangedNotification as CFString,
                selfPtr
            )
            guard retryErr == .success else { return }
            registeredElement = appElement
        } else {
            // targetElement was already the appElement and it failed — give up.
            return
        }

        // Run on the main run loop so callbacks fire on the main thread.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        currentObserver = observer
        currentObservedElement = registeredElement
        currentPid = pid
    }

    private func detachCurrentObserver() {
        if let observer = currentObserver, let element = currentObservedElement {
            AXObserverRemoveNotification(
                observer,
                element,
                kAXSelectedTextChangedNotification as CFString
            )
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        currentObserver = nil
        currentObservedElement = nil
        currentPid = nil
    }
}
