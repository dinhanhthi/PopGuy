// ProConfig.swift
// PopGuy — Licensing
//
// ███ SINGLE SOURCE OF TRUTH for all Pro / Free tunables. ███
//
// Edit the numbers/flags here and rebuild — every Pro/Free threshold in the app
// reads from this one file:
//   • ProEntitlements.free  → free-tier caps + which features are Pro-gated
//   • UsagePolicy           → the usage "acts" nag schedule
//   • LicenseConfig         → the Lemon Squeezy checkout URL
//
// NOT here (configured elsewhere):
//   • Per-license activation limit (number of machines/seats) → Lemon Squeezy
//     dashboard, on the product's License-keys setting.
//
// Why a Swift file and not a runtime JSON: these thresholds must be compiled
// into the binary. A shipped JSON the user could edit would let anyone raise
// their own free limits — worse than the accepted soft protection.
//
// Isolation: nonisolated — pure constants, usable from any context.

import Foundation

// MARK: - ProConfig

nonisolated enum ProConfig {

    // MARK: Free-tier caps (Pro = unlimited)

    /// Max custom actions a free user may create.
    static let freeMaxCustomActions = 8

    /// Max history entries retained/shown for a free user.
    static let freeMaxHistoryRetained = 35

    /// Max ignored apps a free user may add.
    static let freeMaxIgnoredApps = 8

    /// Max ignored domains a free user may add.
    static let freeMaxIgnoredDomains = 8

    /// Max actions (built-in + custom combined) shown as active in the toolbar
    /// for a free user. Enforced at the toolbar-display layer; Settings toggles
    /// stay free to flip, but the floating toolbar surfaces only this many.
    static let freeMaxActiveActions = 5

    // MARK: Toolbar layout caps (universal — not tier-gated)

    /// Max actions shown inline on the floating toolbar (outside the burger menu).
    /// Universal hard cap for Free and Pro. Distinct from `freeMaxActiveActions`,
    /// which limits how many actions a free user actually sees at runtime.
    static let maxPrincipalActions = 6

    /// Max actions inside the burger overflow menu.
    /// Universal hard cap for Free and Pro.
    static let maxBurgerActions = 5

    // MARK: Feature flags (global kill switches — false = hidden for everyone)

    /// Master switch for assigning a default action to the double-click trigger.
    /// When false, the assignment UI is hidden and a double-click always shows
    /// the toolbar, regardless of tier or any stored assignment.
    static let doubleClickActionFeatureEnabled = true

    // MARK: Features gated to Pro (false = locked for free users)

    /// Whether free users may use premium cloud TTS voices.
    static let freeCloudTTSPremiumAllowed = false

    /// Whether free users may import/export custom action sets.
    static let freeImportExportAllowed = false

    /// Whether free users may import plugins/extensions (native JSON + PopClip).
    /// Default `true` — a free acquisition hook so users can install shared
    /// extensions; flip to `false` to gate plugin import behind Pro. Free users
    /// are still bounded by `freeMaxCustomActions`.
    static let freePluginImportAllowed = true

    /// Whether free users may search history.
    static let freeHistorySearchAllowed = false

    /// Whether free users may assign a default action to the double-click trigger.
    static let freeDoubleClickActionAllowed = false

    // MARK: Usage nag schedule (free tier only; Pro is never nagged)

    /// Acts ≤ this are silent (no nag).
    static let actSoftLimit = 100

    /// After the soft limit, show the nag every this-many acts (101, 111, 121, …).
    static let nagInterval = 20

    // MARK: Launch-trial switches
    //
    // These three constants control the time-limited free trial offered at launch.
    // Edit here and rebuild — no other file needs touching to flip the trial on/off
    // or adjust its duration.

    /// Master kill-switch for the launch trial.
    /// `false` ends active trials for everyone on the next published build.
    static let trialEnabled = true

    /// Duration of the free trial in calendar months.
    static let trialDurationMonths = 2

    /// Users whose first launch is strictly before this date are eligible for the trial.
    /// Built from DateComponents so the cut-off is stable in any local timezone.
    static let trialOfferCutoff: Date = {
        var comps = DateComponents()
        comps.year   = 2026
        comps.month  = 8
        comps.day    = 1
        comps.hour   = 0
        comps.minute = 0
        comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }()

    // MARK: Purchase

    /// Master switch for the in-app purchase / "Get Pro" path.
    /// `false` while the Lemon Squeezy store is pending approval — every purchase
    /// button is disabled and shows `purchaseComingSoonNote` instead of opening
    /// checkout. Flip to `true` once the store is live.
    static let purchaseEnabled = false

    /// Short note shown next to disabled purchase buttons while
    /// `purchaseEnabled` is `false`. English only (UI copy).
    static let purchaseComingSoonNote = "Pro purchases are coming soon."

    /// Lemon Squeezy product checkout URL (public buy link).
    static let checkoutURL = URL(string: "https://dinhanhthi.lemonsqueezy.com/checkout/buy/d2dd34c0-d3c7-4be8-9b17-b3f2cbf6c5f8")!
}
