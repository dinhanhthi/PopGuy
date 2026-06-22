// TrialPolicy.swift
// PopGuy — Licensing
//
// Pure, testable functions that compute free-trial state.
// No I/O, no Date() inside — all inputs are passed by the caller so tests
// can supply fixed values without mocking system time.
//
// Isolation: nonisolated — mirrors ProEntitlements and ProConfig.
// TrialState is Sendable so it can cross actor boundaries freely.

import Foundation

// MARK: - TrialState

/// The current state of the user's free trial.
nonisolated enum TrialState: Equatable, Sendable {
    /// No trial has been started (trialStartDate was never recorded).
    case none
    /// Trial is active; `daysLeft` ≥ 0, `endDate` is the calendar-month boundary.
    case active(daysLeft: Int, endDate: Date)
    /// Trial was started but has ended (past end date or kill-switch is off).
    case expired

    /// Convenience: true only when the trial is currently active.
    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

// MARK: - TrialPolicy

/// Stateless helpers for free-trial eligibility and state computation.
nonisolated enum TrialPolicy {

    // MARK: Shared calendar

    /// Fixed gregorian/UTC calendar used for all trial month-math in production.
    ///
    /// Defined once here so both `LicenseGate.bootstrapTrial` and tests can
    /// reference the same instance without diverging timezone behavior.
    static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    // MARK: Eligibility

    /// Whether a new user is eligible for the launch trial.
    ///
    /// Eligible when `enabled` is true **and** the user's first launch was
    /// strictly before the offer cut-off date.
    ///
    /// - Parameters:
    ///   - firstLaunch: The date of the user's very first launch.
    ///   - enabled:     `ProConfig.trialEnabled` — the kill-switch.
    ///   - cutoff:      `ProConfig.trialOfferCutoff` — the eligibility deadline.
    /// - Returns: `true` if the trial should be offered to this user.
    static func eligibleToStart(firstLaunch: Date, enabled: Bool, cutoff: Date) -> Bool {
        enabled && firstLaunch < cutoff
    }

    // MARK: State

    /// Compute the current trial state from stored dates and config.
    ///
    /// - Parameters:
    ///   - now:            The current date (pass `Date()` in production).
    ///   - trialStartDate: The persisted trial start date, or `nil` if never started.
    ///   - enabled:        `ProConfig.trialEnabled`.
    ///   - durationMonths: `ProConfig.trialDurationMonths`.
    ///   - calendar:       Calendar used for month arithmetic. Defaults to `.current`;
    ///                     pass a fixed gregorian/UTC calendar in tests.
    /// - Returns: The `TrialState` appropriate for the given inputs.
    static func state(
        now: Date,
        trialStartDate: Date?,
        enabled: Bool,
        durationMonths: Int,
        calendar: Calendar = .current
    ) -> TrialState {
        guard let start = trialStartDate else { return .none }

        // A trial can never legitimately start in the future. A crafted future
        // trialStartDate (e.g. a Keychain edit within the year-2100 epoch bound)
        // would otherwise satisfy `now < end` forever → a perpetual trial. Reject it.
        guard start <= now else { return .none }

        let end = calendar.date(byAdding: .month, value: durationMonths, to: start)!

        // Kill-switch or past end-date → expired.
        guard enabled, now < end else { return .expired }

        // Ceiling division: a partial remaining day counts as 1.
        let secondsLeft = end.timeIntervalSince(now)
        let daysLeft = max(0, Int(ceil(secondsLeft / 86_400)))

        return .active(daysLeft: daysLeft, endDate: end)
    }
}
