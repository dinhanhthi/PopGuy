// HotkeyManager.swift
// PopGuy — HotkeyManager
//
// Registers per-action global keyboard shortcuts via Carbon RegisterEventHotKey.
//
// Carbon hotkey bridging (strict concurrency):
//   RegisterEventHotKey is a C API that installs a Carbon event handler on the
//   application's event target. The handler callback is @convention(c) and
//   cannot be actor-isolated. Context is recovered from the `userData` field
//   of the EventHandlerCallRef via GetEventParameter (Carbon).
//   The event handler is installed on the main thread (start() is @MainActor)
//   and Carbon event handlers fire on the main thread, so
//   MainActor.assumeIsolated is safe in the callback.
//
// nonisolated(unsafe) rationale:
//   `registrations` and `eventHandlerRef` are declared nonisolated(unsafe) so
//   that the nonisolated deinit can unregister hotkeys and remove the handler.
//   Safety: all writes happen on the MainActor (register/unregisterAll). deinit
//   runs after the last retain is released, at which point no concurrent
//   MainActor mutation can be in flight.
//
// Isolation: @MainActor — registration and the action dispatch happen on the
// main actor. The @convention(c) handler uses MainActor.assumeIsolated.

import Carbon
import Foundation

// MARK: - HotkeyAction type

/// Called on the main actor when a registered shortcut fires.
typealias HotkeyAction = @MainActor () -> Void

// MARK: - HotkeyRegistration (internal)

/// Tracks one registered Carbon hotkey.
///
/// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor so the
/// nonisolated deinit of HotkeyManager can read hotKeyRef to call
/// UnregisterEventHotKey (a C API safe from any thread).
/// The `action` field (a @MainActor closure) is only called from
/// MainActor.assumeIsolated in the event handler callback — never in deinit.
nonisolated private struct HotkeyRegistration: @unchecked Sendable {
    let actionID: ActionIdentifier
    let hotKeyRef: EventHotKeyRef
    let action: HotkeyAction
}

// MARK: - HotkeyManager

/// Manages global keyboard shortcuts via Carbon RegisterEventHotKey.
///
/// Isolation: @MainActor — Carbon registration, the event handler, and action
/// dispatch all run on the main thread.
@MainActor
final class HotkeyManager {

    // MARK: - State

    // nonisolated(unsafe): written only on MainActor; deinit reads them.
    // Safe because deinit runs after the last retain — no concurrent write.
    nonisolated(unsafe) private var registrations: [UInt32: HotkeyRegistration] = [:]
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?

    /// Monotonically increasing counter for Carbon hotkey IDs.
    private var nextHotKeyID: UInt32 = 1

    // MARK: - Init / deinit

    init() {}

    deinit {
        // deinit is nonisolated — call only C APIs.
        for reg in registrations.values {
            UnregisterEventHotKey(reg.hotKeyRef)
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    // MARK: - Start / Stop

    /// Install the Carbon event handler on the application event target.
    /// Must be called once before any shortcuts are registered.
    func start() {
        guard eventHandlerRef == nil else { return }

        // The `userData` pointer carries `self` as an unretained opaque pointer.
        // The callback is @convention(c) — it captures nothing; context is
        // recovered from `userData` on each invocation.
        var eventSpec = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    UInt32(kEventParamDirectObject),
                    UInt32(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return OSStatus(eventNotHandledErr) }

                // MainActor.assumeIsolated: safe — Carbon event handlers fire on the
                // main thread when installed on the application event target.
                MainActor.assumeIsolated {
                    if let reg = manager.registrations[hotKeyID.id] {
                        reg.action()
                    }
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &handlerRef
        )

        eventHandlerRef = handlerRef
    }

    /// Remove all hotkeys and the event handler.
    func stop() {
        unregisterAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    // MARK: - Register / Unregister

    /// Register a global shortcut for the given action identifier.
    ///
    /// If a shortcut is already registered for this `actionID`, it is replaced.
    ///
    /// - Parameters:
    ///   - shortcut:  The key combination to register.
    ///   - actionID:  The action this shortcut should trigger.
    ///   - action:    The closure to call on the main actor when the shortcut fires.
    func register(shortcut: KeyboardShortcut, for actionID: ActionIdentifier, action: @escaping HotkeyAction) {
        // Remove any existing binding for this action.
        unregister(actionID: actionID)

        let hotKeyID = nextHotKeyID
        nextHotKeyID += 1

        var hotKeyRef: EventHotKeyRef?
        let carbonID = EventHotKeyID(signature: fourCharCodeForHotKey, id: hotKeyID)

        let err = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            carbonID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard err == noErr, let hotKeyRef else { return }

        registrations[hotKeyID] = HotkeyRegistration(
            actionID: actionID,
            hotKeyRef: hotKeyRef,
            action: action
        )
    }

    /// Unregister the shortcut for the given action identifier.
    func unregister(actionID: ActionIdentifier) {
        guard let (id, reg) = registrations.first(where: { $0.value.actionID == actionID }) else { return }
        UnregisterEventHotKey(reg.hotKeyRef)
        registrations.removeValue(forKey: id)
    }

    /// Unregister all currently registered shortcuts.
    func unregisterAll() {
        for reg in registrations.values {
            UnregisterEventHotKey(reg.hotKeyRef)
        }
        registrations.removeAll()
    }

    // MARK: - Re-register from SettingsStore

    /// Re-register all shortcuts from the given bindings array.
    ///
    /// Typically called after the user changes bindings in ShortcutsView or
    /// on app launch to restore saved shortcuts.
    func applyBindings(_ bindings: [ShortcutBinding], actionMap: [ActionIdentifier: HotkeyAction]) {
        unregisterAll()
        for binding in bindings {
            if let action = actionMap[binding.actionID] {
                register(shortcut: binding.shortcut, for: binding.actionID, action: action)
            }
        }
    }
}

// MARK: - Carbon signature helper

/// A stable 4-byte signature for PopGuy hotkeys ('PopG').
private let fourCharCodeForHotKey: FourCharCode = {
    let bytes: [UInt8] = [0x50, 0x6F, 0x70, 0x47] // "PopG"
    return FourCharCode(bytes[0]) << 24
        | FourCharCode(bytes[1]) << 16
        | FourCharCode(bytes[2]) << 8
        | FourCharCode(bytes[3])
}()
