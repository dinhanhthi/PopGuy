// UpdaterController.swift
// PopGuy
//
// Observable controller that owns the Sparkle updater lifecycle and surfaces
// lightweight published state for the UI to react to.
//
// GentleUpdaterDriverDelegate implements the SPUStandardUserDriverDelegate
// gentle-reminder contract: scheduled (background) updates light up custom UI
// instead of immediately stealing focus; user-initiated updates are handled
// entirely by Sparkle's standard UI.
//
// Strict concurrency:
//   UpdaterController is @MainActor. SPUStandardUpdaterController is also
//   @MainActor (NS_SWIFT_UI_ACTOR). GentleUpdaterDriverDelegate is
//   nonisolated so its Obj-C callbacks are accepted without actor mismatch;
//   any mutation of UpdaterController state hops back to the main actor via
//   Task { @MainActor in … }. SUAppcastItem is NS_SWIFT_SENDABLE so it can
//   cross actor boundaries without suppression.

import Combine
import Sparkle

// MARK: - UpdaterController

@MainActor
final class UpdaterController: ObservableObject {

    // MARK: - Published state

    @Published private(set) var updateAvailable: Bool = false
    /// Only ever set via `markUpdateAvailable` (which sanitizes) or cleared via `clearUpdate`;
    /// the `private(set)` enforces that the sanitization invariant holds — never assign a raw appcast string here.
    @Published private(set) var pendingVersion: String? = nil
    @Published private(set) var canCheckForUpdates: Bool = false

    /// Mirrors Sparkle's NSUserDefaults-backed automatic-check preference as a
    /// published value so a SwiftUI Toggle can bind to it directly. `didSet` writes
    /// the change back to Sparkle (which persists it); initialized from Sparkle's
    /// current value in `init` (didSet does not fire for the initial in-init assignment).
    @Published var automaticallyChecksForUpdates: Bool = false {
        didSet {
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    // MARK: - Private

    private let updaterController: SPUStandardUpdaterController
    private let driverDelegate = GentleUpdaterDriverDelegate()

    // MARK: - Init

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: driverDelegate
        )

        driverDelegate.controller = self

        updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)

        // Sync the stored mirror from Sparkle's persisted value. didSet does not
        // fire for assignments during init, so this is a plain assignment that
        // does NOT write back to Sparkle — it only initializes the published state.
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
    }

    // MARK: - Lifecycle

    func start() {
        updaterController.startUpdater()
        // Do NOT set automaticallyChecksForUpdates here — that would clobber the
        // user's saved preference every launch. The SUEnableAutomaticChecks key
        // in Info.plist defaults it to true for first-run; Sparkle persists changes.
    }

    // MARK: - User actions

    /// Triggers a user-initiated check; Sparkle shows its own standard UI.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    // MARK: - Internal callbacks (called from GentleUpdaterDriverDelegate)

    func markUpdateAvailable(_ item: SUAppcastItem) {
        updateAvailable = true
        // displayVersionString is appcast-controlled (untrusted input) — sanitize before publishing.
        pendingVersion = Self.sanitizedVersion(item.displayVersionString)
    }

    /// Sanitizes an appcast-supplied version string before surfacing it in UI.
    /// Allows only explicit ASCII letters (A-Z a-z), ASCII digits (0-9), and the
    /// punctuation common in version strings (`.`, `-`, `+`, space). Using an
    /// explicit character set (not CharacterSet.alphanumerics) blocks homograph
    /// and bidi characters. Trims whitespace and caps length at 32 characters.
    nonisolated static func sanitizedVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-+ ")
        let filtered = raw.unicodeScalars
            .filter { allowed.contains($0) }
            .map { Character($0) }
        let trimmed = String(filtered).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(32))
    }

    func clearUpdate() {
        updateAvailable = false
        pendingVersion = nil
    }
}

// MARK: - GentleUpdaterDriverDelegate

/// Nonisolated so that Sparkle's Obj-C callbacks satisfy the protocol without
/// a MainActor requirement. State mutations are dispatched to the main actor.
nonisolated final class GentleUpdaterDriverDelegate: NSObject, SPUStandardUserDriverDelegate {

    weak var controller: UpdaterController?

    // MARK: - Gentle reminder support

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Returning `immediateFocus` lets Sparkle own urgent foreground updates
    /// while the delegate handles quiet background ones.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    /// When Sparkle defers to us (`handleShowingUpdate == false`), light up
    /// custom UI. When Sparkle handles it directly, do nothing.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        Task { @MainActor [controller] in
            controller?.markUpdateAvailable(update)
        }
    }

    /// Sparkle's update session is ending — clear any custom UI badge.
    func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor [controller] in
            controller?.clearUpdate()
        }
    }
}
