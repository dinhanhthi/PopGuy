// Action.swift
// PopGuy — ActionEngine
//
// The Action enum represents what the user wants to do with selected text.
//
// Isolation: nonisolated / Sendable — Action is a pure value passed across
// actor boundaries (from @MainActor toolbar handlers to nonisolated dispatch).

import Foundation

// MARK: - Action

/// A user-requested text transformation.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum Action: Sendable {
    /// Improve / rewrite the selected text using a configured AI provider.
    /// `customPrompt` overrides the predefined system prompt when non-nil and non-empty.
    /// `tone` steers the output register (appended to the prompt; `.neutral` is a no-op).
    case improve(customPrompt: String?, tone: TranslateTone)

    /// Shorten / condense the selected text without losing the main ideas.
    /// `customPrompt` overrides the predefined system prompt when non-nil and non-empty.
    /// `tone` steers the output register (appended to the prompt; `.neutral` is a no-op).
    case shorten(customPrompt: String?, tone: TranslateTone)

    /// Proofread the selected text: fix spelling/grammar without rephrasing.
    /// `customPrompt` overrides the predefined system prompt when non-nil and non-empty.
    case proofread(customPrompt: String?)

    /// Translate the selected text to the given BCP-47 target language.
    /// `customPrompt` adds extra instructions on top of the built-in translate
    /// prompt (additive, not a replacement). `tone` steers the output register.
    case translate(targetLanguage: String, customPrompt: String?, tone: TranslateTone)

    /// User-defined action with a custom system prompt (Phase 5).
    case custom(prompt: String)
}
