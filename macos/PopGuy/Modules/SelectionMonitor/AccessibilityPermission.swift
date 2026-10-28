// AccessibilityPermission.swift
// PopGuy
//
// Monitors and requests macOS Accessibility permission.
//
// Signing note:
//   The Accessibility grant is keyed to the app's code signature.
//   With Xcode's default "Sign to Run Locally" setting the code signature
//   changes on every rebuild, which causes macOS to revoke the grant after
//   each install. To avoid having to re-grant on every build:
//   1. Open Keychain Access → Certificate Assistant → Create a Certificate.
//   2. Name it "PopGuy Dev", type "Self Signed Root", select "Code Signing".
//   3. In Xcode → Signing & Capabilities, set Signing Certificate to
//      "PopGuy Dev" (the stable local cert, NOT "Sign to Run Locally").
//   Because the certificate identity is now stable, the grant survives
//   rebuilds until the certificate expires or the identity changes.

import AppKit
import ApplicationServices
import Combine

/// Observable state for the macOS Accessibility permission required by PopGuy.
///
/// Observes `NSApplication.didBecomeActiveNotification` so a permission grant
/// is detected automatically when the user returns from System Settings —
/// no relaunch required.
@MainActor
final class AccessibilityPermission: ObservableObject {

    /// `true` when `AXIsProcessTrusted()` returns true.
    @Published private(set) var isTrusted: Bool = false

    // nonisolated(unsafe): only written on MainActor (in init); deinit reads
    // it from a nonisolated context to remove the observer. Safe because deinit
    // runs after the last retain, so no concurrent MainActor write can race it.
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    init() {
        isTrusted = AXIsProcessTrusted()
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

    /// Re-read the current trust state.
    func refresh() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Show the system prompt asking for Accessibility permission.
    /// If the user is coming from a second visit (previously denied) this
    /// opens System Settings directly because macOS ignores a second prompt.
    func requestPermission() {
        // kAXTrustedCheckOptionPrompt is an Objective-C global variable (shared
        // mutable state from the perspective of the Swift compiler). Access it
        // via its raw string key to satisfy strict concurrency.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Open the Privacy & Security → Accessibility pane in System Settings.
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
