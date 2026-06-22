// LicenseGate.swift
// PopGuy — Licensing
//
// Single source of truth for the current license tier.
//
// The app delegate injects a `LicenseValidating` implementation (the Lemon
// Squeezy validator) before calling `restoreCachedEntitlement()`. When
// `validator` is nil — e.g. SwiftUI Previews, tests, or if injection is ever
// removed — `entitlements` stays `.free` and `activate` returns `.invalid`
// without a network call, crash, or gating bypass. The nil-validator guards
// below are kept as that defensive fallback, not as the shipping model.
//
// Isolation: @MainActor — `LicenseGate` is app-wide observable state consumed
// by SwiftUI views. All @Published mutations happen on the MainActor.
// Background re-validation Tasks hop back to MainActor before mutating state.
//
// License state is persisted to Keychain only (never UserDefaults):
//   "license.key"             — raw license key (re-validated on launch)
//   "license.maskedKey"       — masked display string for the Settings UI
//   "license.firstLaunchDate" — epoch-seconds string; seeded once on first launch
//   "license.trialStartDate"  — epoch-seconds string; written when trial begins
//   "license.trialExpiryAck"  — one-time flag ("1") written when the trial-expiry warning is acknowledged

import Foundation
import Combine

// MARK: - LicenseKeyMask

/// Shared masking helper used by both `LicenseGate` and `LemonSqueezyLicenseValidator`.
///
/// Centralised here so both sites always produce byte-identical output — required
/// because `LicenseGate.restoreCachedEntitlement` falls back to `mask(rawKey)`
/// and the validator stores the masked form; they MUST agree.
nonisolated enum LicenseKeyMask {
    /// Produce a display-safe masked form of a license key (head=12, tail=10).
    ///
    /// Long keys: "\(head)…\(tail)". Short keys: "\(first-4)…".
    static func mask(_ key: String) -> String {
        let head = 12, tail = 10
        if key.count > head + tail {
            return "\(key.prefix(head))…\(key.suffix(tail))"
        }
        let shortHead = min(4, key.count)
        return "\(key.prefix(shortHead))…"
    }
}

// MARK: - LicenseStatus

/// The outcome of a license-key validation attempt.
enum LicenseStatus: Sendable {
    /// The key is valid; `activatedKeyMasked` is the display-safe form.
    case valid(activatedKeyMasked: String)
    /// The key was rejected by the server. `reason` is user-displayable.
    case invalid(reason: String)
    /// The validation request could not complete (e.g. no network). The
    /// cached entitlement is kept as-is (offline grace).
    case offlineUnverified
}

// MARK: - LicenseValidating

/// Abstraction over the actual license server call.
///
/// The app delegate injects the Lemon Squeezy implementation via
/// `LicenseGate.validator` at startup. Marked `Sendable` so it can be called
/// from async tasks running off-actor.
protocol LicenseValidating: Sendable {
    /// Validate `licenseKey` against the license server.
    ///
    /// - Parameter licenseKey: The raw key entered by the user.
    /// - Returns: A `LicenseStatus` describing the outcome.
    func validate(licenseKey: String) async -> LicenseStatus

    /// Deactivate `licenseKey` on the license server, freeing the machine seat.
    ///
    /// Called from `LicenseGate.deactivate()` on a best-effort Task before the
    /// local Keychain slots are cleared. Default implementation is a no-op so
    /// existing conformers (and the nil-validator case) require no changes.
    func deactivate(licenseKey: String) async
}

extension LicenseValidating {
    /// Default no-op so conformers that don't interact with a seat-based server
    /// need not implement this method.
    func deactivate(licenseKey: String) async {}
}

// MARK: - LicenseGate

/// Observable gateway that controls which `ProEntitlements` preset is active.
///
/// Usage pattern:
/// 1. Inject `validator` at launch before calling `restoreCachedEntitlement()`.
/// 2. Call `restoreCachedEntitlement()` once in the app delegate / on launch.
/// 3. Call `bootstrapTrial()` immediately after `restoreCachedEntitlement()`.
/// 4. Observe `entitlements` in SwiftUI views to gate Pro features.
@MainActor
final class LicenseGate: ObservableObject {

    // MARK: - Published state

    /// The currently active entitlement set.
    ///
    /// The ONLY site that writes this property is `recomputeEntitlements()`.
    /// Precedence: valid paid license → `.pro`; else trial active → `.pro`;
    /// else `.free`.
    @Published private(set) var entitlements: ProEntitlements = .free

    /// Masked display form of the active license key
    /// (e.g. "XXXX-XXXX-sDvg…aoW2WRL8sA"), or `nil` when no key is stored.
    @Published private(set) var activatedKeyMasked: String?

    /// The current free-trial state. Updated by `bootstrapTrial()`.
    @Published private(set) var trialState: TrialState = .none

    // MARK: - Private state

    /// True when a validated paid license is active.
    private var hasValidLicense = false

    // MARK: - Dependencies

    /// Injected license validator. `nil` only in Previews/tests → stays free.
    var validator: LicenseValidating?

    /// Keychain store used to persist the license key.
    private let keychain: KeychainManager

    // MARK: - Keychain account names

    private enum KeychainAccount {
        static let rawKey              = "license.key"
        static let maskedKey           = "license.maskedKey"
        static let firstLaunchDate     = "license.firstLaunchDate"
        static let trialStartDate      = "license.trialStartDate"
        static let trialExpiryAck      = "license.trialExpiryAck"
    }

    // MARK: - Init

    /// Create a `LicenseGate`.
    ///
    /// - Parameter keychain: The `KeychainManager` to use. Defaults to the
    ///   production instance. Pass an ephemeral instance in tests.
    init(keychain: KeychainManager = KeychainManager()) {
        self.keychain = keychain
    }

    // MARK: - Entitlement computation

    /// The ONLY site that assigns `entitlements`.
    ///
    /// Precedence: valid paid license → `.pro`; else trial active → `.pro`;
    /// else `.free`. Call this after mutating `hasValidLicense` or `trialState`.
    private func recomputeEntitlements() {
        entitlements = (hasValidLicense || trialState.isActive) ? .pro : .free
    }

    // MARK: - Trial bootstrap

    /// Seed trial dates and compute the current `trialState`.
    ///
    /// Call once at launch, immediately after `restoreCachedEntitlement()`.
    /// Safe to call repeatedly (subsequent calls are idempotent when dates are
    /// already persisted).
    ///
    /// - Parameter now: The current date. Defaults to `Date()`. Pass a fixed
    ///   date in tests.
    func bootstrapTrial(now: Date = Date()) {
        // Seed firstLaunchDate once (never overwrite once written).
        let firstLaunch: Date
        if let date = parseEpoch(keychain.key(account: KeychainAccount.firstLaunchDate)) {
            firstLaunch = date
        } else {
            firstLaunch = now
            keychain.setKey(String(now.timeIntervalSince1970), account: KeychainAccount.firstLaunchDate)
        }

        // Start the trial on first eligible launch (write once).
        let trialStart: Date?
        if let date = parseEpoch(keychain.key(account: KeychainAccount.trialStartDate)) {
            trialStart = date
        } else if TrialPolicy.eligibleToStart(
            firstLaunch: firstLaunch,
            enabled: ProConfig.trialEnabled,
            cutoff: ProConfig.trialOfferCutoff
        ) {
            // Record trial start as the same moment as first launch.
            keychain.setKey(String(firstLaunch.timeIntervalSince1970), account: KeychainAccount.trialStartDate)
            trialStart = firstLaunch
        } else {
            trialStart = nil
        }

        trialState = TrialPolicy.state(
            now: now,
            trialStartDate: trialStart,
            enabled: ProConfig.trialEnabled,
            durationMonths: ProConfig.trialDurationMonths,
            calendar: TrialPolicy.utcCalendar
        )

        recomputeEntitlements()
    }

    // MARK: - Trial expiry acknowledgement

    /// `true` when the trial is expired, no valid paid license is held, and the
    /// user has not yet acknowledged the expiry warning. Check this once at launch
    /// (after `bootstrapTrial()`) to decide whether to present the warning modal.
    var shouldPresentTrialExpiryWarning: Bool {
        trialState == .expired
            && !hasValidLicense
            && keychain.key(account: KeychainAccount.trialExpiryAck) == nil
    }

    /// Mark the trial-expiry warning as acknowledged. Call immediately before
    /// presenting the modal (not on close) so a crash-before-dismiss never causes
    /// a second presentation.
    func acknowledgeTrialExpiry() {
        keychain.setKey("1", account: KeychainAccount.trialExpiryAck)
    }

    // MARK: - Private helpers

    /// Parse a stored Keychain epoch string into a Date, rejecting crafted values.
    ///
    /// Returns a Date only when the parsed TimeInterval is finite, positive, and
    /// before year 2100 (4_102_444_800). Rejects `"inf"`, `"nan"`, `"1e20"`,
    /// negative epochs, and other malformed inputs that could otherwise produce
    /// dates that permanently satisfy the trial-active check.
    ///
    /// - Parameter string: The raw string from Keychain (may be `nil`).
    /// - Returns: A valid Date, or `nil` when the value is missing or invalid.
    private func parseEpoch(_ string: String?) -> Date? {
        guard let s = string,
              let interval = TimeInterval(s),
              interval.isFinite,
              interval > 0,
              interval < 4_102_444_800   // 2100-01-01 00:00:00 UTC
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    // MARK: - Activation

    /// Attempt to activate a license key.
    ///
    /// - If `validator` is `nil` (Previews/tests fallback), returns `.invalid`
    ///   immediately without crashing or contacting any server.
    /// - On `.valid`, upgrades `entitlements` to `.pro` and persists the masked
    ///   and raw keys to Keychain atomically: maskedKey is written first; if the
    ///   rawKey write subsequently fails, maskedKey is deleted to avoid divergence.
    ///   The in-memory `.pro` state is kept for the current session regardless.
    /// - On `.invalid` or `.offlineUnverified`, leaves `entitlements` unchanged.
    ///
    /// - Parameter licenseKey: The raw key supplied by the user.
    /// - Returns: The validation outcome.
    func activate(licenseKey: String) async -> LicenseStatus {
        guard let validator else {
            return .invalid(reason: "License validation is unavailable right now.")
        }

        let status = await validator.validate(licenseKey: licenseKey)

        if case .valid(let masked) = status {
            hasValidLicense = true
            activatedKeyMasked = masked
            recomputeEntitlements()
            // Atomic write: masked first, then raw; roll back masked on raw failure.
            let maskedWritten = keychain.setKey(masked, account: KeychainAccount.maskedKey)
            if maskedWritten {
                let rawWritten = keychain.setKey(licenseKey, account: KeychainAccount.rawKey)
                if !rawWritten {
                    // Raw write failed — delete masked to keep slots in sync.
                    keychain.deleteKey(account: KeychainAccount.maskedKey)
                    print("[LicenseGate] Keychain write failed for rawKey; rolled back maskedKey.")
                }
            } else {
                print("[LicenseGate] Keychain write failed for maskedKey.")
            }
        }

        return status
    }

    // MARK: - Deactivation

    /// Deactivate the current license.
    ///
    /// Reads the raw key from Keychain and fires a best-effort background Task
    /// asking the validator to free the Lemon Squeezy seat (so the machine slot
    /// is released and can be used elsewhere). The Task is fire-and-forget:
    /// callers are not blocked and the result is ignored.
    ///
    /// After scheduling the Task, both local Keychain slots are cleared and the
    /// in-memory license state is reset to no-valid-license synchronously. The
    /// validator's own Keychain slots (`license.instanceId`, `license.instanceName`)
    /// are cleared by the validator inside its `deactivate(licenseKey:)` call.
    ///
    /// Note: if the free trial is currently active, the user retains `.pro`
    /// entitlements via the trial. The trial is NOT cancelled by deactivation.
    ///
    /// - Returns: `true` when both local Keychain deletes succeeded; `false` when
    ///   at least one slot could not be removed (the key may re-restore on next
    ///   launch). The in-memory state is always reset.
    @discardableResult
    func deactivate() -> Bool {
        // Capture the raw key BEFORE clearing, so the validator can call /deactivate.
        if let rawKey = keychain.key(account: KeychainAccount.rawKey),
           let v = validator {
            Task {
                await v.deactivate(licenseKey: rawKey)
            }
        }
        let rawDeleted    = keychain.deleteKey(account: KeychainAccount.rawKey)
        let maskedDeleted = keychain.deleteKey(account: KeychainAccount.maskedKey)
        hasValidLicense = false
        activatedKeyMasked = nil
        recomputeEntitlements()
        return rawDeleted && maskedDeleted
    }

    // MARK: - Cached entitlement restore

    /// Restore a previously activated license from Keychain on launch.
    ///
    /// Safety: when `validator` is `nil` (Previews/tests), the method returns
    /// immediately after reading the rawKey — `entitlements` and
    /// `activatedKeyMasked` are never mutated, so `.free` is preserved even
    /// if a `license.key` Keychain entry exists.
    ///
    /// With a validator present (normal launch):
    /// - Sets `hasValidLicense = true` and `activatedKeyMasked` optimistically,
    ///   then calls `recomputeEntitlements()` to apply the change.
    /// - Kicks off a background re-validation via `revalidate(rawKey:)`.
    ///   - Offline / `.offlineUnverified` → keeps Pro (grace period).
    ///   - `.invalid` → downgrades and clears Keychain.
    ///   - `.valid` → keeps Pro (masked key may be refreshed from server).
    func restoreCachedEntitlement() {
        guard let rawKey = keychain.key(account: KeychainAccount.rawKey) else { return }

        // Guard validator BEFORE any entitlement mutation: if there is no
        // validator (Previews/tests) a planted Keychain key must NOT elevate to .pro.
        guard validator != nil else { return }

        // Restore masked display string (best-effort; fall back to a freshly
        // computed mask if the Keychain slot is somehow missing).
        let masked = keychain.key(account: KeychainAccount.maskedKey) ?? LicenseKeyMask.mask(rawKey)
        hasValidLicense = true
        activatedKeyMasked = masked
        recomputeEntitlements()

        // Re-validate in the background using the named async method.
        Task {
            await revalidate(rawKey: rawKey)
        }
    }

    /// Re-validate a cached license key against the server and apply the result.
    ///
    /// Called from `restoreCachedEntitlement()`. Extracted as a named, awaitable
    /// method so the downgrade logic is an observable, testable unit.
    ///
    /// - Parameter rawKey: The raw license key previously stored in Keychain.
    func revalidate(rawKey: String) async {
        guard let validator else { return }
        let status = await validator.validate(licenseKey: rawKey)
        // Already on MainActor (inherited from the enclosing actor context).
        switch status {
        case .valid(let refreshedMasked):
            activatedKeyMasked = refreshedMasked
            keychain.setKey(refreshedMasked, account: KeychainAccount.maskedKey)
        case .offlineUnverified:
            // Offline grace: keep the cached Pro entitlement unchanged.
            break
        case .invalid:
            // Explicit rejection → downgrade.
            deactivate()
        }
    }

}
