// ScriptActionPresets.swift
// PopGuy — ScriptActionEngine
//
// Starter presets for scriptable custom actions.
// Each call to `all()` returns fresh CustomAction instances with new UUIDs so
// adding the same preset twice never collides with an existing action.
//
// Isolation: nonisolated / Sendable value-type namespace — pure factory, no state.

import Foundation

// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum ScriptActionPresets: Sendable {

    /// Returns one fresh instance of every built-in preset.
    /// Each call generates new UUIDs — safe to call multiple times.
    nonisolated static func all() -> [CustomAction] {
        [revealInFinder(), searchGoogle(), newTextEditDocument()]
    }

    // MARK: - Individual factory functions

    /// Opens the selected file path in Finder.
    /// Visible only when the selection looks like a file path.
    nonisolated static func revealInFinder() -> CustomAction {
        CustomAction(
            title: "Reveal in Finder",
            icon: .sfSymbol("folder"),
            type: .shellScript,
            systemPrompt: "",
            scriptSource: #"open -R "$POPGUY_TEXT""#,
            afterRun: .closeToolbar,
            appliesWhenRegex: #"^(/|~|file:).+"#
        )
    }

    /// Opens a Google search for the selected text.
    nonisolated static func searchGoogle() -> CustomAction {
        CustomAction(
            title: "Search Google",
            icon: .sfSymbol("magnifyingglass"),
            type: .openURL,
            systemPrompt: "",
            scriptSource: "https://www.google.com/search?q={text}",
            afterRun: .closeToolbar,
            appliesWhenRegex: ""
        )
    }

    /// Opens the selected text as a new TextEdit document.
    /// `{text}` expands to a fully-quoted AppleScript string literal, so it sits
    /// directly inside the record without surrounding quotes.
    ///
    /// Targets TextEdit deliberately: data-protected apps (Reminders, Calendar,
    /// Notes, Contacts, Mail) reject Apple events with errAEEventNotPermitted on
    /// recent macOS even when Automation is granted, so they make poor starter
    /// examples. TextEdit is freely scriptable.
    nonisolated static func newTextEditDocument() -> CustomAction {
        CustomAction(
            title: "New TextEdit Document",
            icon: .sfSymbol("doc.badge.plus"),
            type: .appleScript,
            systemPrompt: "",
            scriptSource: #"tell application "TextEdit" to make new document with properties {text:{text}}"#,
            afterRun: .closeToolbar,
            appliesWhenRegex: ""
        )
    }
}
