// UsagePolicy.swift
// PopGuy — Licensing
//
// Stateless policy for the free-tier usage "acts" counter and soft nag logic.
//
// Isolation: nonisolated — pure value computation, no UI dependency.
// Mirrors the pattern used by ProEntitlements and ResultFontSize.

import Foundation

// MARK: - UsagePolicy

/// Stateless predicate for the free-tier act counter. The thresholds live in
/// `ProConfig` (`actSoftLimit`, `nagInterval`) — the single source of truth.
///
/// An "act" is each time a toolbar action actually runs (Improve, Shorten,
/// Proofread, Translate, Prompt-submit, Speak, custom). Pro users are never
/// counted or nagged.
///
/// Nag schedule: silent for acts 1–`actSoftLimit`; from the next act, and every
/// `nagInterval` acts after that (101, 111, 121, … by default), show a soft
/// dismissable upgrade popup.
nonisolated enum UsagePolicy {

    /// Returns `true` when the given act count should trigger a nag popup.
    ///
    /// True exactly at actCount `actSoftLimit+1`, `+1+nagInterval`, … (the first
    /// act after the limit, and every `nagInterval` thereafter). False at/below
    /// the soft limit.
    static func isNagDue(actCount: Int) -> Bool {
        actCount > ProConfig.actSoftLimit &&
            (actCount - ProConfig.actSoftLimit - 1) % ProConfig.nagInterval == 0
    }
}
