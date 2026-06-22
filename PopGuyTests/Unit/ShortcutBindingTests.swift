// ShortcutBindingTests.swift
// PopGuyTests
//
// TDD: shortcut-binding persistence round-trips + Carbon modifier conversion.
// All persistence tests use an injected UserDefaults(suiteName:).

import Foundation
import Testing
@testable import PopGuy

// MARK: - ShortcutBindingTests

@Suite("ShortcutBinding")
@MainActor
struct ShortcutBindingTests {

    // MARK: - Helpers

    private func makeSuite() -> (UserDefaults, String) {
        let name = "com.popguy.test.shortcuts.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func removeSuite(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    // MARK: - Default state

    @Test("a fresh store seeds the built-in default shortcuts")
    func freshStoreSeedsBuiltinDefaults() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        #expect(store.shortcutBindings == ShortcutBinding.defaultBuiltins)
    }

    @Test("cleared shortcuts persist as empty and are not reseeded on reload")
    func clearedShortcutsDoNotReseed() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // User clears every shortcut — this persists an empty (non-nil) array.
        let store1 = SettingsStore(defaults: suite)
        store1.shortcutBindings = []

        // Reload: an empty persisted array must NOT fall back to the defaults.
        let store2 = SettingsStore(defaults: suite)
        #expect(store2.shortcutBindings.isEmpty)
    }

    @Test("built-in defaults are the five actions on ⌃⌥⌘ with distinct combos")
    func builtinDefaultsAreValid() {
        let defaults = ShortcutBinding.defaultBuiltins
        #expect(defaults.count == 5)

        let actionIDs = Set(defaults.map(\.actionID))
        #expect(actionIDs == [
            .builtin(.improve), .builtin(.shorten),
            .builtin(.proofread), .builtin(.translate),
            .speak,
        ])

        // Every default uses the ⌃⌥⌘ modifier combo (no shift).
        let expectedMods: UInt = (1 << 18) | (1 << 19) | (1 << 20)
        #expect(defaults.allSatisfy { $0.shortcut.modifierFlags == expectedMods })

        // No two defaults share the same key combo.
        #expect(Set(defaults.map(\.shortcut)).count == 5)
    }

    // MARK: - Set shortcut

    @Test("setShortcut adds a new binding")
    func setShortcutAddsBinding() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        store.shortcutBindings = [] // start from a clean slate (ignore seeded defaults)

        let shortcut = KeyboardShortcut(keyCode: 0, modifierFlags: 1 << 20) // ⌘A
        store.setShortcut(shortcut, for: .builtin(.improve))

        #expect(store.shortcutBindings.count == 1)
        #expect(store.shortcut(for: .builtin(.improve)) == shortcut)
    }

    @Test("setShortcut replaces an existing binding for the same action")
    func setShortcutReplaces() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        store.shortcutBindings = [] // start from a clean slate (ignore seeded defaults)

        let first  = KeyboardShortcut(keyCode: 0, modifierFlags: 1 << 20) // ⌘A
        let second = KeyboardShortcut(keyCode: 1, modifierFlags: 1 << 20) // ⌘S
        store.setShortcut(first,  for: .builtin(.improve))
        store.setShortcut(second, for: .builtin(.improve))

        #expect(store.shortcutBindings.count == 1, "should not accumulate duplicates")
        #expect(store.shortcut(for: .builtin(.improve)) == second)
    }

    @Test("set two different actions produces two bindings")
    func setTwoDifferentActions() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        store.shortcutBindings = [] // start from a clean slate (ignore seeded defaults)

        store.setShortcut(KeyboardShortcut(keyCode: 0, modifierFlags: 1 << 20), for: .builtin(.improve))
        store.setShortcut(KeyboardShortcut(keyCode: 1, modifierFlags: 1 << 20), for: .builtin(.translate))

        #expect(store.shortcutBindings.count == 2)
    }

    // MARK: - Remove shortcut

    @Test("removeShortcut deletes the binding")
    func removeShortcut() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        store.shortcutBindings = [] // start from a clean slate (ignore seeded defaults)

        store.setShortcut(KeyboardShortcut(keyCode: 0, modifierFlags: 1 << 20), for: .builtin(.improve))
        store.removeShortcut(for: .builtin(.improve))

        #expect(store.shortcutBindings.isEmpty)
        #expect(store.shortcut(for: .builtin(.improve)) == nil)
    }

    @Test("removeShortcut is a no-op for unknown action")
    func removeShortcutUnknown() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        store.shortcutBindings = [] // start from a clean slate (ignore seeded defaults)

        store.setShortcut(KeyboardShortcut(keyCode: 0, modifierFlags: 1 << 20), for: .builtin(.improve))
        store.removeShortcut(for: .builtin(.translate)) // not set

        #expect(store.shortcutBindings.count == 1)
    }

    // MARK: - Persistence round-trips

    @Test("shortcut binding persists across store reloads")
    func shortcutBindingPersists() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let shortcut = KeyboardShortcut(keyCode: 13, modifierFlags: (1 << 20) | (1 << 17)) // ⌘⇧W
        let store1 = SettingsStore(defaults: suite)
        store1.setShortcut(shortcut, for: .builtin(.improve))

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.shortcut(for: .builtin(.improve)) == shortcut)
    }

    @Test("custom action shortcut persists across store reloads")
    func customActionShortcutPersists() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let uuid = UUID()
        let shortcut = KeyboardShortcut(keyCode: 8, modifierFlags: 1 << 20) // ⌘C
        let store1 = SettingsStore(defaults: suite)
        store1.setShortcut(shortcut, for: .custom(uuid))

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.shortcut(for: .custom(uuid)) == shortcut)
    }

    // MARK: - Duplicate combo deduplication (P5-2)

    @Test("assigning same combo to a second action removes it from the first")
    func setShortcutDedupsByCombo() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        store.shortcutBindings = [] // start from a clean slate (ignore seeded defaults)

        let combo = KeyboardShortcut(keyCode: 8, modifierFlags: 1 << 20) // ⌘C
        store.setShortcut(combo, for: .builtin(.improve))
        // Bind same combo to translate — should steal it from improve.
        store.setShortcut(combo, for: .builtin(.translate))

        #expect(store.shortcutBindings.count == 1, "no duplicate combo should persist")
        #expect(store.shortcut(for: .builtin(.translate)) == combo, "translate should own the combo")
        #expect(store.shortcut(for: .builtin(.improve)) == nil, "improve should no longer own the combo")
    }

    @Test("assigning same combo to same action replaces without duplication")
    func setShortcutSameActionSameComboNoDuplicate() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }
        let store = SettingsStore(defaults: suite)
        store.shortcutBindings = [] // start from a clean slate (ignore seeded defaults)

        let combo = KeyboardShortcut(keyCode: 0, modifierFlags: 1 << 20)
        store.setShortcut(combo, for: .builtin(.improve))
        store.setShortcut(combo, for: .builtin(.improve)) // same action, same combo

        #expect(store.shortcutBindings.count == 1)
        #expect(store.shortcut(for: .builtin(.improve)) == combo)
    }

    @Test("multiple bindings persist correctly")
    func multipleBindingsPersist() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let s1 = KeyboardShortcut(keyCode: 0, modifierFlags: 1 << 20)  // ⌘A
        let s2 = KeyboardShortcut(keyCode: 1, modifierFlags: 1 << 20)  // ⌘S
        let uuid = UUID()
        let s3 = KeyboardShortcut(keyCode: 2, modifierFlags: (1 << 20) | (1 << 19)) // ⌘⌥D

        let store1 = SettingsStore(defaults: suite)
        store1.setShortcut(s1, for: .builtin(.improve))
        store1.setShortcut(s2, for: .builtin(.translate))
        store1.setShortcut(s3, for: .custom(uuid))

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.shortcut(for: .builtin(.improve))   == s1)
        #expect(store2.shortcut(for: .builtin(.translate)) == s2)
        #expect(store2.shortcut(for: .custom(uuid))        == s3)
    }

    // MARK: - KeyboardShortcut Codable

    @Test("KeyboardShortcut Codable round-trip")
    func keyboardShortcutCodable() throws {
        let shortcut = KeyboardShortcut(keyCode: 13, modifierFlags: (1 << 20) | (1 << 17))
        let data = try JSONEncoder().encode(shortcut)
        let decoded = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        #expect(decoded == shortcut)
    }

    // MARK: - Carbon modifier conversion

    @Test("command modifier converts to Carbon cmdKey")
    func commandModifierToCarbon() {
        let cmdOnly = KeyboardShortcut(keyCode: 0, modifierFlags: 1 << 20)
        // cmdKey in Carbon = 256 = 0x100
        #expect(cmdOnly.carbonModifiers == 256)
    }

    @Test("option modifier converts to Carbon optionKey")
    func optionModifierToCarbon() {
        let optOnly = KeyboardShortcut(keyCode: 0, modifierFlags: 1 << 19)
        // optionKey in Carbon = 2048 = 0x800
        #expect(optOnly.carbonModifiers == 2048)
    }

    @Test("control modifier converts to Carbon controlKey")
    func controlModifierToCarbon() {
        let ctrlOnly = KeyboardShortcut(keyCode: 0, modifierFlags: 1 << 18)
        // controlKey in Carbon = 4096 = 0x1000
        #expect(ctrlOnly.carbonModifiers == 4096)
    }

    @Test("shift modifier converts to Carbon shiftKey")
    func shiftModifierToCarbon() {
        let shiftOnly = KeyboardShortcut(keyCode: 0, modifierFlags: 1 << 17)
        // shiftKey in Carbon = 512 = 0x200
        #expect(shiftOnly.carbonModifiers == 512)
    }

    @Test("combined Cmd+Shift converts to Carbon")
    func cmdShiftToCarbon() {
        let cmdShift = KeyboardShortcut(keyCode: 0, modifierFlags: (1 << 20) | (1 << 17))
        // 256 (cmd) + 512 (shift) = 768
        #expect(cmdShift.carbonModifiers == 768)
    }

    @Test("Carbon modifier round-trip via modifiersFromCarbon")
    func carbonModifierRoundTrip() {
        // ⌘⌥ = cmdKey | optionKey = 256 + 2048 = 2304
        let carbon: UInt32 = 2304
        let ns = KeyboardShortcut.modifiersFromCarbon(carbon)
        let shortcut = KeyboardShortcut(keyCode: 0, modifierFlags: ns)
        #expect(shortcut.carbonModifiers == carbon)
    }

    @Test("no modifiers → zero Carbon mask")
    func noModifiersZeroCarbon() {
        let none = KeyboardShortcut(keyCode: 0, modifierFlags: 0)
        #expect(none.carbonModifiers == 0)
    }
}
