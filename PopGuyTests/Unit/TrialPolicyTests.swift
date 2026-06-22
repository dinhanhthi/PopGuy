// TrialPolicyTests.swift
// PopGuyTests
//
// Unit tests for TrialPolicy — pure state functions.
// All tests use fixed Dates and a fixed Calendar (gregorian, UTC) so the
// real system clock is never consulted.

import Foundation
import Testing
@testable import PopGuy

// MARK: - Helpers

private func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

/// Build a fixed UTC Date from year/month/day/hour components.
private func utcDate(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day; comps.hour = hour
    comps.minute = 0; comps.second = 0
    return utcCalendar().date(from: comps)!
}

// MARK: - TrialPolicyTests

struct TrialPolicyTests {

    private let cal = utcCalendar()

    // Fixed reference dates
    private let cutoff      = utcDate(year: 2026, month: 8, day: 1)  // 2026-08-01 00:00 UTC
    private let earlyLaunch = utcDate(year: 2026, month: 6, day: 1)  // before cutoff ✓
    private let lateLaunch  = utcDate(year: 2026, month: 8, day: 1)  // == cutoff, not eligible

    // MARK: eligibleToStart — cutoff boundary

    @Test func eligibleJustBeforeCutoff() {
        let justBefore = utcDate(year: 2026, month: 7, day: 31, hour: 23)
        #expect(TrialPolicy.eligibleToStart(firstLaunch: justBefore, enabled: true, cutoff: cutoff) == true)
    }

    @Test func ineligibleAtCutoff() {
        // firstLaunch == cutoff is NOT eligible (strict less-than)
        #expect(TrialPolicy.eligibleToStart(firstLaunch: cutoff, enabled: true, cutoff: cutoff) == false)
    }

    @Test func ineligibleJustAfterCutoff() {
        let justAfter = utcDate(year: 2026, month: 8, day: 1, hour: 1)
        #expect(TrialPolicy.eligibleToStart(firstLaunch: justAfter, enabled: true, cutoff: cutoff) == false)
    }

    @Test func ineligibleWhenDisabled() {
        // Even with a pre-cutoff launch, kill-switch off → ineligible.
        #expect(TrialPolicy.eligibleToStart(firstLaunch: earlyLaunch, enabled: false, cutoff: cutoff) == false)
    }

    // MARK: state — .none when start is nil

    @Test func stateNoneWhenNoStartDate() {
        let result = TrialPolicy.state(
            now: earlyLaunch,
            trialStartDate: nil,
            enabled: true,
            durationMonths: 2,
            calendar: cal
        )
        #expect(result == .none)
    }

    @Test func stateNoneWhenStartIsInFuture() {
        // A crafted future trialStartDate (within the year-2100 epoch bound) must NOT
        // yield a perpetual active trial — a trial cannot start in the future.
        let now    = utcDate(year: 2026, month: 6, day: 1)
        let future = utcDate(year: 2099, month: 1, day: 1)
        let result = TrialPolicy.state(
            now: now,
            trialStartDate: future,
            enabled: true,
            durationMonths: 2,
            calendar: cal
        )
        #expect(result == .none)
    }

    // MARK: state — .active mid-trial

    @Test func stateActiveMidTrial() {
        let start = utcDate(year: 2026, month: 6, day: 1)
        let now   = utcDate(year: 2026, month: 7, day: 1)  // 1 month in; 1 month left
        let result = TrialPolicy.state(
            now: now,
            trialStartDate: start,
            enabled: true,
            durationMonths: 2,
            calendar: cal
        )
        guard case .active(let daysLeft, _) = result else {
            Issue.record("Expected .active, got \(result)")
            return
        }
        // 31 days from 2026-07-01 to 2026-08-01
        #expect(daysLeft == 31)
    }

    @Test func stateActiveDaysLeftCeilsPartialDay() {
        // 12 hours before end → daysLeft should be 1 (ceiling), not 0
        let start = utcDate(year: 2026, month: 6, day: 1)
        let expectedEnd = utcCalendar().date(byAdding: .month, value: 2, to: start)!
        let now = expectedEnd.addingTimeInterval(-12 * 3600)  // 12 h before end
        let result = TrialPolicy.state(
            now: now,
            trialStartDate: start,
            enabled: true,
            durationMonths: 2,
            calendar: cal
        )
        guard case .active(let daysLeft, _) = result else {
            Issue.record("Expected .active, got \(result)")
            return
        }
        #expect(daysLeft == 1)
    }

    // MARK: state — .expired at/after end

    @Test func stateExpiredAtExactEndDate() {
        let start = utcDate(year: 2026, month: 6, day: 1)
        // End date is exactly 2 months later = 2026-08-01
        let end = cal.date(byAdding: .month, value: 2, to: start)!
        let result = TrialPolicy.state(
            now: end,
            trialStartDate: start,
            enabled: true,
            durationMonths: 2,
            calendar: cal
        )
        #expect(result == .expired)
    }

    @Test func stateExpiredAfterEnd() {
        let start = utcDate(year: 2026, month: 6, day: 1)
        let afterEnd = utcDate(year: 2026, month: 9, day: 1)  // 3 months later
        let result = TrialPolicy.state(
            now: afterEnd,
            trialStartDate: start,
            enabled: true,
            durationMonths: 2,
            calendar: cal
        )
        #expect(result == .expired)
    }

    // MARK: state — kill-switch

    @Test func killSwitchExpiresActiveTrial() {
        // Trial would still be active by date, but kill-switch is off → expired.
        let start = utcDate(year: 2026, month: 6, day: 1)
        let now   = utcDate(year: 2026, month: 7, day: 1)   // mid-trial
        let result = TrialPolicy.state(
            now: now,
            trialStartDate: start,
            enabled: false,        // kill-switch off
            durationMonths: 2,
            calendar: cal
        )
        #expect(result == .expired)
    }

    // MARK: state — end-date math (2-month span)

    @Test func twoMonthEndDateMath() {
        let start = utcDate(year: 2026, month: 6, day: 1)
        let now   = utcDate(year: 2026, month: 6, day: 15)  // mid-first-month
        let expectedEnd = utcDate(year: 2026, month: 8, day: 1)  // 2 calendar months later
        let result = TrialPolicy.state(
            now: now,
            trialStartDate: start,
            enabled: true,
            durationMonths: 2,
            calendar: cal
        )
        guard case .active(_, let endDate) = result else {
            Issue.record("Expected .active, got \(result)")
            return
        }
        #expect(endDate == expectedEnd)
    }

    // MARK: TrialState.isActive

    @Test func isActiveOnlyForActiveCase() {
        let futureDate = utcDate(year: 2026, month: 8, day: 1)
        #expect(TrialState.active(daysLeft: 5, endDate: futureDate).isActive == true)
        #expect(TrialState.none.isActive == false)
        #expect(TrialState.expired.isActive == false)
    }
}
