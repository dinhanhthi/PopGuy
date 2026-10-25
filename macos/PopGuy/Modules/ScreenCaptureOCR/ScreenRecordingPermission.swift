// ScreenRecordingPermission.swift
// PopGuy
//
// Monitors and requests macOS Screen Recording permission, required to
// capture screen regions for the OCR feature.

import AppKit
import CoreGraphics
import Combine

/// Observable state for the macOS Screen Recording permission required by
/// PopGuy's OCR feature.
///
/// Observes `NSApplication.didBecomeActiveNotification` so a permission grant
/// is detected automatically when the user returns from System Settings —
/// no relaunch required.
@MainActor
final class ScreenRecordingPermission: ObservableObject {

    /// `true` when `CGPreflightScreenCaptureAccess()` returns true.
    @Published private(set) var isGranted: Bool = false

    // nonisolated(unsafe): only written on MainActor (in init); deinit reads
    // it from a nonisolated context to remove the observer. Safe because deinit
    // runs after the last retain, so no concurrent MainActor write can race it.
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    init() {
        isGranted = CGPreflightScreenCaptureAccess()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    // Note: addObserver(forName:object:queue:using:) RETAINS the observation
    // block internally; the returned token MUST be explicitly removed to stop
    // delivery. The [weak self] inside the block prevents a reference cycle /
    // use-after-free, but does NOT automatically remove the registration.
    // deinit removes it explicitly below.
    // deinit is nonisolated under Swift 6; NotificationCenter.removeObserver
    // is thread-safe, so calling it here is correct.
    deinit {
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Re-read the current grant state.
    func refresh() {
        isGranted = CGPreflightScreenCaptureAccess()
    }

    /// Show the system prompt asking for Screen Recording permission.
    /// Must NOT be called at launch — only lazily, in response to a user
    /// action that actually needs to capture the screen.
    @discardableResult
    func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Open the Privacy & Security → Screen Recording pane in System Settings.
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording")!
        NSWorkspace.shared.open(url)
    }
}
