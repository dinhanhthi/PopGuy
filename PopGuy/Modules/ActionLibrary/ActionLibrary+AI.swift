// ActionLibrary+AI.swift
// PopGuy — ActionLibrary
//
// AI Writing presets for the Action Library.
// Each preset is an `.ai` CustomAction with a fixed system prompt. The prompt must
// not contain {{text}}: the engine would then move it into the user message.
//
// providerKind/model stay at the CustomAction defaults here — the install path
// (`ActionLibrary.installableAction`) replaces them with the Improve action's.
//
// Isolation: nonisolated / Sendable value-type namespace — pure factory, no state.

import Foundation

// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum ActionLibraryAI: Sendable {

    /// Stable catalog key of the Humanize preset. Also referenced by
    /// `LocalModelCatalog` to dedicate the humanizer model to this preset.
    nonisolated static let humanizePresetID = "ai.humanize"

    /// Returns all AI Writing presets.
    /// Each call returns fresh CustomAction instances with new UUIDs.
    nonisolated static func all() -> [LibraryPreset] {
        [
            humanize(),
        ]
    }

    // MARK: - Rewrite

    nonisolated private static func humanize() -> LibraryPreset {
        LibraryPreset(id: humanizePresetID, category: .aiWriting) {
            var action = CustomAction(
                title: "Humanize",
                icon: .sfSymbol("person.wave.2"),
                type: .ai,
                systemPrompt: """
                Rewrite the text below so it reads like a person wrote it, not a language model.

                Reorganize it as you see fit. Vary sentence length on purpose. Cut hedging, throat-clearing, and any sentence that only announces what comes next. Prefer the concrete word over the abstract one. It is fine to sound uneven.

                Every fact, number, unit, date, name and quotation must survive unchanged. Keep the original language. Return only the rewritten text, with no commentary.
                """
            )
            action.actionDescription = "Rewrite AI-sounding text so it reads like a person wrote it."
            return action
        }
    }
}
