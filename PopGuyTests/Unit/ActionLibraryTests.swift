// ActionLibraryTests.swift
// PopGuyTests
//
// Unit tests for the ActionLibrary aggregator and preset catalog.
//
// Test framework: Swift Testing (@Test / #expect).

import Foundation
import Testing
@testable import PopGuy

@Suite("ActionLibrary")
struct ActionLibraryTests {

    // MARK: - 1. Preset count

    @Test("allPresets() returns at least 90 presets")
    func allPresetsCountAtLeast90() {
        #expect(ActionLibrary.allPresets().count >= 90)
    }

    // MARK: - 2. Unique preset IDs

    @Test("every preset id is unique across allPresets()")
    func allPresetIDsAreUnique() {
        let presets = ActionLibrary.allPresets()
        let ids = presets.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(uniqueIDs.count == ids.count, "duplicate preset ids found: \(ids.count - uniqueIDs.count) collision(s)")
    }

    // MARK: - 3. Fresh UUID on each make() call

    @Test("two calls to make() on the same preset produce different CustomAction.id values")
    func makeReturnsFreshUUID() {
        let presets = ActionLibrary.allPresets()
        // Sample several presets across categories.
        let sampleIDs = ["search.google", "text.uppercase", "dev.base64encode", "apps.bear", "maps.apple"]
        for presetID in sampleIDs {
            guard let preset = presets.first(where: { $0.id == presetID }) else {
                Issue.record("preset '\(presetID)' not found in allPresets()")
                continue
            }
            let a = preset.make()
            let b = preset.make()
            #expect(a.id != b.id, "preset '\(presetID)' returned the same UUID on two consecutive make() calls")
        }
    }

    // MARK: - 4. sanitizeImported passes for every preset

    @Test("every preset's make() passes sanitizeImported and returns non-nil")
    func allPresetsMakeSanitizable() {
        for preset in ActionLibrary.allPresets() {
            let action = preset.make()
            let sanitized = CustomAction.sanitizeImported(action, cloudAllowed: true)
            #expect(sanitized != nil, "sanitizeImported returned nil for preset '\(preset.id)'")
        }
    }

    // MARK: - 5. Valid regex
    // Forward-compatibility guard: currently all presets have empty appliesWhenRegex,
    // so no assertion body executes today. This test will catch invalid patterns if
    // a future preset is added with a non-empty appliesWhenRegex.

    @Test("every preset's appliesWhenRegex is empty or compiles as NSRegularExpression")
    func allPresetRegexesCompile() {
        for preset in ActionLibrary.allPresets() {
            let regex = preset.make().appliesWhenRegex
            guard !regex.isEmpty else { continue }
            do {
                _ = try NSRegularExpression(pattern: regex)
            } catch {
                Issue.record("preset '\(preset.id)' has invalid appliesWhenRegex '\(regex)': \(error)")
            }
        }
    }

    // MARK: - 6. No AppleScript against protected apps
    // Forward-compatibility guard: currently no presets use .appleScript type,
    // so no assertion body executes today. This test will catch violations if
    // a future preset targeting a protected app is added.

    @Test("no appleScript preset targets Apple-protected apps")
    func noAppleScriptTargetsProtectedApps() {
        let protected = ["Reminders", "Notes", "Calendar", "Contacts", "Mail", "Photos"]
        for preset in ActionLibrary.allPresets() {
            let action = preset.make()
            guard action.type == .appleScript else { continue }
            for appName in protected {
                #expect(
                    !action.scriptSource.localizedCaseInsensitiveContains(appName),
                    "preset '\(preset.id)' is appleScript and references protected app '\(appName)'"
                )
            }
        }
    }

    // MARK: - 7. openURL presets contain {text} placeholder

    @Test("every openURL preset's scriptSource contains {text}")
    func openURLPresetsContainTextPlaceholder() {
        for preset in ActionLibrary.allPresets() {
            let action = preset.make()
            guard action.type == .openURL else { continue }
            #expect(
                action.scriptSource.contains("{text}"),
                "openURL preset '\(preset.id)' scriptSource is missing {text} placeholder"
            )
        }
    }

    // MARK: - 8 & 9. shellScript presets feed stdin safely via printf '%s' "$POPGUY_TEXT"
    // Consolidates two weaker checks (POPGUY_TEXT present, no echo) into one positive
    // assertion: the exact literal `printf '%s' "$POPGUY_TEXT"` must appear in every
    // shellScript preset's scriptSource.  The two date presets embed it inside a
    // command substitution ("$(printf '%s' "$POPGUY_TEXT")") which still contains
    // the literal substring.  This also implicitly forbids {text} interpolation and
    // bare echo usage, since neither would satisfy the positive assertion.

    @Test("every shellScript preset feeds stdin via printf '%s' \"$POPGUY_TEXT\"")
    func shellScriptPresetsUseSafePrintf() {
        let safePattern = #"printf '%s' "$POPGUY_TEXT""#
        for preset in ActionLibrary.allPresets() {
            let action = preset.make()
            guard action.type == .shellScript else { continue }
            #expect(
                action.scriptSource.contains(safePattern),
                "shellScript preset '\(preset.id)' does not contain the required safe stdin feed: \(safePattern)"
            )
            #expect(
                !action.scriptSource.contains("{text}"),
                "shellScript preset '\(preset.id)' contains forbidden {text} interpolation"
            )
        }
    }

    // MARK: - 10. Each category is non-empty

    @Test("every LibraryCategory has at least one preset")
    func eachCategoryIsNonEmpty() {
        for category in LibraryCategory.allCases {
            #expect(
                !ActionLibrary.presets(in: category).isEmpty,
                "category '\(category.rawValue)' has no presets"
            )
        }
    }

    // MARK: - 11. isInstalled helper

    @Test("isInstalled returns false when actions list is empty")
    func isInstalledEmptyActions() {
        // Any real catalog preset works; search.google has a non-empty scriptSource.
        guard let preset = ActionLibrary.allPresets().first(where: { $0.id == "search.google" }) else {
            Issue.record("preset 'search.google' not found"); return
        }
        #expect(!ActionLibrary.isInstalled(preset, in: []))
    }

    @Test("isInstalled returns true when actions contains a matching type + scriptSource")
    func isInstalledMatchFound() {
        guard let preset = ActionLibrary.allPresets().first(where: { $0.id == "search.google" }) else {
            Issue.record("preset 'search.google' not found"); return
        }
        let a = preset.make()
        // Build an action that matches type + scriptSource (id is irrelevant to the check).
        let match = CustomAction(
            title: "Anything",
            type: a.type,
            systemPrompt: "",
            scriptSource: a.scriptSource
        )
        #expect(ActionLibrary.isInstalled(preset, in: [match]))
    }

    @Test("isInstalled collision guard: empty scriptSource never yields a false positive")
    func isInstalledCollisionGuard() {
        // Construct a preset whose make() returns an action with scriptSource == ""
        // (simulates a hypothetical non-scriptable preset, e.g. .ai type).
        let emptyPreset = LibraryPreset(id: "test.empty-guard", category: .textTransform) {
            CustomAction(title: "Empty Script", type: .ai, systemPrompt: "x")
        }
        // An existing action of the same type also has scriptSource == "".
        let existingAction = CustomAction(title: "Other AI", type: .ai, systemPrompt: "y")
        // Despite type matching and both having "", the !isEmpty guard must block the match.
        #expect(!ActionLibrary.isInstalled(emptyPreset, in: [existingAction]))
    }
}
