// LicenseGateTrialTests.swift
// PopGuyTests
//
// Integration tests for LicenseGate trial behaviour.
//
// Each test uses an ephemeral KeychainManager (UUID-scoped service name) to
// avoid touching production Keychain slots. All date-sensitive calls pass
// an explicit `now:` argument so results are deterministic.
//
// Kill-switch note: ProConfig.trialEnabled is a compile-time constant and
// cannot be toggled in-process. Kill-switch behaviour is covered at the pure
// TrialPolicy.state level in TrialPolicyTests.swift (killSwitchExpiresActiveTrial).
// The tests here assert the integration path when trialEnabled == true (the
// shipping value); they do not add a production seam just to exercise the false
// branch at the LicenseGate level.
//
// KEYCHAIN RESILIENCE: tests probe the Keychain before asserting, same
// pattern as KeychainManagerTests.swift. Tests are silently skipped (not
// failed) in headless CI environments that lack Keychain entitlements.

import Foundation
import Security
import Testing
@testable import PopGuy

// MARK: - Helpers

private func utcDate(year: Int, month: Int, day: Int) -> Date {
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day
    comps.hour = 0; comps.minute = 0; comps.second = 0
    return TrialPolicy.utcCalendar.date(from: comps)!
}

/// A minimal LicenseValidating stub that returns a fixed status.
private struct StubValidator: LicenseValidating, Sendable {
    let result: LicenseStatus
    func validate(licenseKey: String) async -> LicenseStatus { result }
}

// MARK: - LicenseGateTrialTests

@Suite("LicenseGate — trial integration")
@MainActor
struct LicenseGateTrialTests {

    // MARK: - Helpers

    /// Ephemeral KeychainManager isolated to a single test run.
    private func makeKeychain() -> (KeychainManager, String) {
        let service = "dinh.thi.PopGuy.tests.\(UUID().uuidString)"
        return (KeychainManager(serviceName: service), service)
    }

    /// Probe whether the Keychain is writable in this environment.
    private func keychainIsAvailable(service: String) -> Bool {
        let account = "probe"
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String:   Data("x".utf8)
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            let del: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(del as CFDictionary)
            return true
        }
        return false
    }

    /// A date well within the trial eligibility window (before trialOfferCutoff 2026-08-01).
    private let insideCutoff = utcDate(year: 2026, month: 6, day: 15)
    /// A date after the trial offer cut-off, so eligibleToStart returns false.
    private let afterCutoff  = utcDate(year: 2026, month: 9, day: 1)

    // MARK: - recomputeEntitlements precedence

    @Test("trial active + no license => .pro")
    func trialActiveMeansProEntitlements() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = LicenseGate(keychain: kc)
        // now is inside the cutoff; trialEnabled is true → trial starts and is active
        gate.bootstrapTrial(now: insideCutoff)

        #expect(gate.trialState.isActive == true)
        #expect(gate.entitlements == .pro)
    }

    @Test("valid license => .pro regardless of trial state")
    func validLicenseMeansPro() async {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = LicenseGate(keychain: kc)
        gate.validator = StubValidator(result: .valid(activatedKeyMasked: "XXXX…YYYY"))

        // Bootstrap with no trial (after cutoff)
        gate.bootstrapTrial(now: afterCutoff)
        #expect(gate.entitlements == .free)  // no trial, no license yet

        let status = await gate.activate(licenseKey: "test-key-1234")
        guard case .valid = status else {
            Issue.record("Expected .valid, got \(status)")
            return
        }
        #expect(gate.entitlements == .pro)
    }

    @Test("no trial + no license => .free")
    func noTrialNoLicenseMeansFree() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = LicenseGate(keychain: kc)
        // after cutoff → eligibleToStart returns false → no trial
        gate.bootstrapTrial(now: afterCutoff)

        #expect(gate.trialState == .none)
        #expect(gate.entitlements == .free)
    }

    // MARK: - deactivate() while trial is active

    @Test("deactivate() while trial active keeps .pro via trial")
    func deactivateWhileTrialActiveKeepsPro() async {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = LicenseGate(keychain: kc)
        gate.validator = StubValidator(result: .valid(activatedKeyMasked: "XXXX…YYYY"))

        // Start with an active trial
        gate.bootstrapTrial(now: insideCutoff)
        #expect(gate.trialState.isActive == true)

        // Activate a license on top
        _ = await gate.activate(licenseKey: "test-key-5678")
        #expect(gate.entitlements == .pro)

        // Deactivate the license
        gate.deactivate()

        // Trial is still active → should remain .pro
        #expect(gate.entitlements == .pro, "deactivate() must not downgrade while trial is active")
        #expect(gate.trialState.isActive == true, "trialState must remain active after deactivation")
    }

    // MARK: - bootstrapTrial idempotency

    @Test("second bootstrapTrial call does not move trialStartDate")
    func bootstrapTrialIsIdempotent() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = LicenseGate(keychain: kc)
        let firstNow = insideCutoff  // 2026-06-15

        // First call seeds the dates
        gate.bootstrapTrial(now: firstNow)
        let stateAfterFirst = gate.trialState

        // Second call with a different `now` — dates must not move
        let laterNow = utcDate(year: 2026, month: 7, day: 1)
        gate.bootstrapTrial(now: laterNow)
        let stateAfterSecond = gate.trialState

        // Both states should be active (trial lasts 2 months from firstNow)
        // and the endDate must be identical (start date did not shift)
        guard case .active(_, let end1) = stateAfterFirst,
              case .active(_, let end2) = stateAfterSecond else {
            Issue.record("Expected .active for both calls, got \(stateAfterFirst), \(stateAfterSecond)")
            return
        }
        #expect(end1 == end2, "trialStartDate must not move on second bootstrapTrial call")
    }

    @Test("Keychain epoch round-trips back to the same Date")
    func epochRoundTrips() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = LicenseGate(keychain: kc)
        // 2026-06-15 00:00:00 UTC
        let now = insideCutoff

        gate.bootstrapTrial(now: now)

        // Bootstrap again with the same now — re-reads from Keychain
        gate.bootstrapTrial(now: now)

        // The trial state must be consistent (same endDate both calls)
        guard case .active(_, let endDate) = gate.trialState else {
            Issue.record("Expected .active, got \(gate.trialState)")
            return
        }
        // End date should be exactly 2 months after the first-launch date (which was `now`)
        let expectedEnd = TrialPolicy.utcCalendar.date(
            byAdding: .month, value: ProConfig.trialDurationMonths, to: now
        )!
        #expect(endDate == expectedEnd, "Keychain epoch must round-trip to the same Date")
    }

    // MARK: - Malformed / missing Keychain values

    @Test("bootstrapTrial with malformed Keychain epoch does not crash")
    func malformedEpochDoesNotCrash() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        // Manually plant a crafted epoch that should be rejected by parseEpoch
        kc.setKey("inf", account: "license.firstLaunchDate")
        kc.setKey("1e20", account: "license.trialStartDate")

        let gate = LicenseGate(keychain: kc)
        let now = insideCutoff

        // Must not crash; malformed values are treated as missing → reseeds
        gate.bootstrapTrial(now: now)

        // Since "inf" was rejected, firstLaunch == now (inside cutoff) → trial starts
        #expect(gate.trialState.isActive == true, "Gate should reseed and start trial when epoch is malformed")
        #expect(gate.entitlements == .pro)
    }

    @Test("bootstrapTrial with missing Keychain values does not crash")
    func missingEpochDoesNotCrash() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = LicenseGate(keychain: kc)
        // Nothing stored at all — should behave as first launch
        gate.bootstrapTrial(now: insideCutoff)

        #expect(gate.trialState.isActive == true)
        #expect(gate.entitlements == .pro)
    }

    @Test("bootstrapTrial with negative epoch reseeds as first launch")
    func negativeEpochRejected() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        // Negative epoch should be rejected
        kc.setKey("-1234567890", account: "license.firstLaunchDate")

        let gate = LicenseGate(keychain: kc)
        // Reseeds firstLaunch = now (inside cutoff) → trial starts
        gate.bootstrapTrial(now: insideCutoff)

        #expect(gate.trialState.isActive == true)
        #expect(gate.entitlements == .pro)
    }

    @Test("far-future epoch (year 2101) is rejected, reseeds")
    func farFutureEpochRejected() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        // 2101-01-01 epoch > 4_102_444_800 → should be rejected
        let farFuture = String(TimeInterval(4_102_444_801))  // just past the 2100 boundary
        kc.setKey(farFuture, account: "license.firstLaunchDate")

        let gate = LicenseGate(keychain: kc)
        gate.bootstrapTrial(now: insideCutoff)

        // Rejected → reseeds with insideCutoff → trial starts
        #expect(gate.trialState.isActive == true)
        #expect(gate.entitlements == .pro)
    }

    // MARK: - shouldPresentTrialExpiryWarning

    /// Build a gate whose trial has started inside the cutoff and then expired
    /// by advancing `now` past start + duration.
    private func makeExpiredGate(keychain: KeychainManager) -> LicenseGate {
        let gate = LicenseGate(keychain: keychain)
        // Seed the trial start by bootstrapping inside the cutoff window.
        gate.bootstrapTrial(now: insideCutoff)
        // Re-bootstrap at a date past the end of the 2-month trial so state = .expired.
        let expiredDate = TrialPolicy.utcCalendar.date(
            byAdding: .month, value: ProConfig.trialDurationMonths + 1, to: insideCutoff
        )!
        gate.bootstrapTrial(now: expiredDate)
        return gate
    }

    @Test("expired + no license + not acknowledged => shouldPresentTrialExpiryWarning is true")
    func warningPresentedWhenExpiredAndUnacknowledged() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = makeExpiredGate(keychain: kc)
        #expect(gate.trialState == .expired, "precondition: trial must be expired")
        #expect(gate.shouldPresentTrialExpiryWarning == true)
    }

    @Test("expired + acknowledged => shouldPresentTrialExpiryWarning is false")
    func warningNotPresentedAfterAcknowledgement() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = makeExpiredGate(keychain: kc)
        #expect(gate.trialState == .expired, "precondition: trial must be expired")
        gate.acknowledgeTrialExpiry()
        #expect(gate.shouldPresentTrialExpiryWarning == false)
    }

    @Test("expired + valid license => shouldPresentTrialExpiryWarning is false")
    func warningNotPresentedWhenValidLicenseExists() async {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = makeExpiredGate(keychain: kc)
        gate.validator = StubValidator(result: .valid(activatedKeyMasked: "XXXX…YYYY"))
        _ = await gate.activate(licenseKey: "test-key-9999")
        #expect(gate.shouldPresentTrialExpiryWarning == false)
    }

    @Test("trial active => shouldPresentTrialExpiryWarning is false")
    func warningNotPresentedWhenTrialIsActive() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = LicenseGate(keychain: kc)
        gate.bootstrapTrial(now: insideCutoff)
        #expect(gate.trialState.isActive == true, "precondition: trial must be active")
        #expect(gate.shouldPresentTrialExpiryWarning == false)
    }

    @Test("trialState .none => shouldPresentTrialExpiryWarning is false")
    func warningNotPresentedWhenNoTrial() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = LicenseGate(keychain: kc)
        gate.bootstrapTrial(now: afterCutoff)
        #expect(gate.trialState == .none, "precondition: no trial")
        #expect(gate.shouldPresentTrialExpiryWarning == false)
    }

    @Test("acknowledgeTrialExpiry() is once-only — subsequent checks return false")
    func onceOnlyAcknowledgement() {
        let (kc, service) = makeKeychain()
        guard keychainIsAvailable(service: service) else { return }
        defer { cleanupKeychain(service: service) }

        let gate = makeExpiredGate(keychain: kc)
        #expect(gate.trialState == .expired, "precondition: trial must be expired")
        #expect(gate.shouldPresentTrialExpiryWarning == true, "must be true before acknowledging")
        gate.acknowledgeTrialExpiry()
        #expect(gate.shouldPresentTrialExpiryWarning == false, "must be false after acknowledging")
        // Second call is idempotent; check still false.
        gate.acknowledgeTrialExpiry()
        #expect(gate.shouldPresentTrialExpiryWarning == false, "must stay false on repeated ack")
    }

    // MARK: - Cleanup helper

    /// Delete all trial-related Keychain slots for the ephemeral service.
    private func cleanupKeychain(service: String) {
        let accounts = [
            "license.key",
            "license.maskedKey",
            "license.firstLaunchDate",
            "license.trialStartDate",
            "license.trialExpiryAck"
        ]
        for account in accounts {
            let q: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(q as CFDictionary)
        }
    }
}
