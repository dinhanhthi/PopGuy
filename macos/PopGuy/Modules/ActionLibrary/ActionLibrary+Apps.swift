// ActionLibrary+Apps.swift
// PopGuy — ActionLibrary
//
// Third-party app-capture presets for the Action Library.
// Each preset opens the selected text in a supported third-party application
// via its registered URL scheme.
//
// URL-scheme presets use {text} in scriptSource — the engine percent-encodes
// the selection before substituting it into the URL.
//
// ⚠ All URL schemes are marked "verify scheme" because schemes can change
// between app versions or vary by distribution (Mac App Store vs direct).
// Always test against the installed app version before shipping.
//
// afterRun: .closeToolbar — these actions hand off to another app; no result
// needs to be shown in the toolbar.
//
// Isolation: nonisolated / Sendable value-type namespace — pure factory, no state.

import Foundation

// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum ActionLibraryApps: Sendable {

    /// Returns all Apps presets.
    /// Each call returns fresh CustomAction instances with new UUIDs.
    nonisolated static func all() -> [LibraryPreset] {
        [
            bear(),
            drafts(),
            obsidian(),
            things(),
            todoist(),
            tot(),
            craft(),
            dayOne(),
            goodLinks(),
            anybox(),
            raindrop(),
            pocket(),
            instapaper(),
            omniFocus(),
            callPhone(),
            facetime(),
        ]
    }

    // MARK: - Notes

    nonisolated private static func bear() -> LibraryPreset {
        LibraryPreset(id: "apps.bear", category: .apps) {
            // ⚠ verify scheme — Bear URL scheme requires Bear 1.x or 2.x to be installed.
            var action = CustomAction(
                title: "Bear",
                icon: .sfSymbol("note.text"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "bear://x-callback-url/create?text={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Create a new Bear note with the selected text."
            return action
        }
    }

    nonisolated private static func drafts() -> LibraryPreset {
        LibraryPreset(id: "apps.drafts", category: .apps) {
            // ⚠ verify scheme — requires Drafts for Mac (App Store).
            var action = CustomAction(
                title: "Drafts",
                icon: .sfSymbol("note.text"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "drafts://x-callback-url/create?text={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Create a new Drafts draft with the selected text."
            return action
        }
    }

    nonisolated private static func obsidian() -> LibraryPreset {
        LibraryPreset(id: "apps.obsidian", category: .apps) {
            // ⚠ verify scheme — requires Obsidian to be installed; vault must be open.
            var action = CustomAction(
                title: "Obsidian",
                icon: .sfSymbol("note.text"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "obsidian://new?content={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Create a new Obsidian note with the selected text."
            return action
        }
    }

    nonisolated private static func craft() -> LibraryPreset {
        LibraryPreset(id: "apps.craft", category: .apps) {
            // ⚠ verify scheme — requires Craft (direct or App Store); scheme may vary by version.
            var action = CustomAction(
                title: "Craft",
                icon: .sfSymbol("note.text"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "craftdocs://createdocument?content={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Create a new Craft document with the selected text."
            return action
        }
    }

    nonisolated private static func dayOne() -> LibraryPreset {
        LibraryPreset(id: "apps.dayone", category: .apps) {
            // ⚠ verify scheme — requires Day One for Mac (App Store).
            var action = CustomAction(
                title: "Day One",
                icon: .sfSymbol("book"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "dayone://post?entry={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Create a new Day One journal entry with the selected text."
            return action
        }
    }

    nonisolated private static func tot() -> LibraryPreset {
        LibraryPreset(id: "apps.tot", category: .apps) {
            // ⚠ verify scheme — requires Tot (App Store); appends to the active dot.
            var action = CustomAction(
                title: "Tot",
                icon: .sfSymbol("note.text"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "tot://new?text={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Send the selected text to Tot."
            return action
        }
    }

    // MARK: - Task managers

    nonisolated private static func things() -> LibraryPreset {
        LibraryPreset(id: "apps.things", category: .apps) {
            // ⚠ verify scheme — requires Things 3 for Mac (App Store).
            var action = CustomAction(
                title: "Things",
                icon: .sfSymbol("checklist"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "things:///add?title={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Add a new to-do to Things with the selected text as the title."
            return action
        }
    }

    nonisolated private static func todoist() -> LibraryPreset {
        LibraryPreset(id: "apps.todoist", category: .apps) {
            // ⚠ verify scheme — requires Todoist for Mac (App Store or direct).
            var action = CustomAction(
                title: "Todoist",
                icon: .sfSymbol("checklist"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "todoist://addtask?content={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Add the selected text as a new Todoist task."
            return action
        }
    }

    nonisolated private static func omniFocus() -> LibraryPreset {
        LibraryPreset(id: "apps.omnifocus", category: .apps) {
            // ⚠ verify scheme — requires OmniFocus 3 or 4 for Mac (direct or App Store).
            var action = CustomAction(
                title: "OmniFocus",
                icon: .sfSymbol("checklist"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "omnifocus:///add?name={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Add the selected text as a new OmniFocus task."
            return action
        }
    }

    // MARK: - Read-later / Bookmarks

    nonisolated private static func goodLinks() -> LibraryPreset {
        LibraryPreset(id: "apps.goodlinks", category: .apps) {
            // ⚠ verify scheme — requires GoodLinks (App Store); selection must be a URL.
            var action = CustomAction(
                title: "GoodLinks",
                icon: .sfSymbol("link"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "goodlinks://x-callback-url/save?url={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Save the selected URL to GoodLinks."
            return action
        }
    }

    nonisolated private static func anybox() -> LibraryPreset {
        LibraryPreset(id: "apps.anybox", category: .apps) {
            // ⚠ verify scheme — requires Anybox (App Store); selection must be a URL.
            var action = CustomAction(
                title: "Anybox",
                icon: .sfSymbol("link"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "anybox://save?url={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Save the selected URL to Anybox."
            return action
        }
    }

    nonisolated private static func raindrop() -> LibraryPreset {
        LibraryPreset(id: "apps.raindrop", category: .apps) {
            // ⚠ verify scheme — opens raindrop.io in the browser; selection must be a URL.
            var action = CustomAction(
                title: "Raindrop",
                icon: .sfSymbol("link"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://app.raindrop.io/add?link={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Save the selected URL to Raindrop.io."
            return action
        }
    }

    nonisolated private static func pocket() -> LibraryPreset {
        LibraryPreset(id: "apps.pocket", category: .apps) {
            // ⚠ verify scheme — opens getpocket.com in the browser; selection must be a URL.
            var action = CustomAction(
                title: "Pocket",
                icon: .sfSymbol("link"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://getpocket.com/save?url={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Save the selected URL to Pocket."
            return action
        }
    }

    nonisolated private static func instapaper() -> LibraryPreset {
        LibraryPreset(id: "apps.instapaper", category: .apps) {
            // ⚠ verify scheme — opens instapaper.com in the browser; selection must be a URL.
            var action = CustomAction(
                title: "Instapaper",
                icon: .sfSymbol("link"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.instapaper.com/hello2?url={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Save the selected URL to Instapaper."
            return action
        }
    }

    // MARK: - Phone

    nonisolated private static func callPhone() -> LibraryPreset {
        LibraryPreset(id: "apps.call", category: .apps) {
            // ⚠ verify scheme — opens the default calling app (FaceTime on macOS);
            // selection must be a phone number. The engine percent-encodes {text} as-is;
            // a formatted number like "+1 (555) 123-4567" is not normalised — verify
            // that the scheme accepts the encoded form on a real device.
            var action = CustomAction(
                title: "Call",
                icon: .sfSymbol("phone"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "tel:{text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Call the selected phone number."
            return action
        }
    }

    nonisolated private static func facetime() -> LibraryPreset {
        LibraryPreset(id: "apps.facetime", category: .apps) {
            // ⚠ verify scheme — initiates a FaceTime call; selection must be a phone number
            // or Apple ID email address. The engine percent-encodes {text} as-is;
            // a formatted number like "+1 (555) 123-4567" is not normalised — verify
            // that the scheme accepts the encoded form on a real device.
            var action = CustomAction(
                title: "FaceTime",
                icon: .sfSymbol("video"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "facetime:{text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Start a FaceTime call with the selected phone number or Apple ID."
            return action
        }
    }
}
