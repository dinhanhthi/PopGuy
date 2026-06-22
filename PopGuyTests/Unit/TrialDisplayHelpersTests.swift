// TrialDisplayHelpersTests.swift
// PopGuyTests
//
// Unit tests for the pure formatting helpers used by the trial status displays:
//   trialEndDateString(_:timeZone:) — dd-MMM-yyyy in the given timezone, English abbreviations.
//   trialFooterSuffix(endDate:) — the full footer suffix string.

import Foundation
import Testing
@testable import PopGuy

// MARK: - Helpers

/// Builds a Date from a UTC Gregorian calendar at the given year/month/day and
/// optional hour/minute/second. Default time is midnight UTC.
private func utcDate(year: Int, month: Int, day: Int,
                     hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day
    comps.hour = hour; comps.minute = minute; comps.second = second
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: comps)!
}

// MARK: - trialEndDateString tests

@Suite("trialEndDateString")
struct TrialEndDateStringTests {

    @Test("August 2026 end date formats correctly")
    func augustEndDate() {
        let date = utcDate(year: 2026, month: 8, day: 21)
        let tz = TimeZone(identifier: "UTC")!
        #expect(trialEndDateString(date, timeZone: tz) == "21-Aug-2026")
    }

    @Test("January end date uses correct 3-letter abbreviation")
    func januaryEndDate() {
        let date = utcDate(year: 2027, month: 1, day: 5)
        let tz = TimeZone(identifier: "UTC")!
        #expect(trialEndDateString(date, timeZone: tz) == "05-Jan-2027")
    }

    @Test("December end date formats with leading zero on day")
    func decemberEndDate() {
        let date = utcDate(year: 2026, month: 12, day: 1)
        let tz = TimeZone(identifier: "UTC")!
        #expect(trialEndDateString(date, timeZone: tz) == "01-Dec-2026")
    }

    @Test("month abbreviations are always English regardless of locale")
    func englishMonthAbbreviations() {
        // All 12 months must produce English 3-letter abbreviations.
        // Use explicit UTC timezone and assert the full string for determinism.
        let tz = TimeZone(identifier: "UTC")!
        let expected = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        for (idx, abbr) in expected.enumerated() {
            let date = utcDate(year: 2026, month: idx + 1, day: 15)
            let result = trialEndDateString(date, timeZone: tz)
            #expect(result == "15-\(abbr)-2026",
                    "month \(idx + 1) should be '15-\(abbr)-2026', got '\(result)'")
        }
    }

    // MARK: Timezone rendering tests

    @Test("non-midnight instant renders in Los Angeles local day")
    func losAngelesTimezone() {
        // 2026-08-15 02:30 UTC = 2026-08-14 19:30 PDT (UTC-7 summer)
        let date = utcDate(year: 2026, month: 8, day: 15, hour: 2, minute: 30)
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        // In LA (UTC-7 during PDT), 02:30 UTC is 19:30 on August 14.
        #expect(trialEndDateString(date, timeZone: tz) == "14-Aug-2026")
    }

    @Test("non-midnight instant renders in Tokyo local day")
    func tokyoTimezone() {
        // 2026-08-14 23:00 UTC = 2026-08-15 08:00 JST (UTC+9)
        let date = utcDate(year: 2026, month: 8, day: 14, hour: 23, minute: 0)
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        // In Tokyo (UTC+9), 23:00 UTC is 08:00 on August 15.
        #expect(trialEndDateString(date, timeZone: tz) == "15-Aug-2026")
    }

    @Test("same instant renders differently in two timezones")
    func sameInstantDifferentTimezones() {
        // An instant near midnight UTC produces different calendar days in
        // LA (UTC-7) and Tokyo (UTC+9) — confirms timezone parameter is honoured.
        let date = utcDate(year: 2026, month: 1, day: 1, hour: 1, minute: 0)
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        // 2026-01-01 01:00 UTC = 2025-12-31 17:00 PST → Dec 31 in LA
        // 2026-01-01 01:00 UTC = 2026-01-01 10:00 JST → Jan 01 in Tokyo
        #expect(trialEndDateString(date, timeZone: la) == "31-Dec-2025")
        #expect(trialEndDateString(date, timeZone: tokyo) == "01-Jan-2026")
    }
}

// MARK: - trialFooterSuffix tests

@Suite("trialFooterSuffix")
struct TrialFooterSuffixTests {

    @Test("suffix has the expected format")
    func suffixFormat() {
        // trialFooterSuffix uses the default .current timezone; call
        // trialEndDateString with explicit UTC here so the expected value
        // is deterministic regardless of CI host timezone.
        let date = utcDate(year: 2026, month: 8, day: 21)
        let tz = TimeZone(identifier: "UTC")!
        let dateStr = trialEndDateString(date, timeZone: tz)
        #expect(trialFooterSuffix(endDate: date).hasSuffix(dateStr))
    }

    @Test("suffix starts with em-dash separator")
    func suffixStartsWithDash() {
        let date = utcDate(year: 2026, month: 6, day: 1)
        let result = trialFooterSuffix(endDate: date)
        #expect(result.hasPrefix(" — Trial use until "))
    }
}
