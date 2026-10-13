// PrincipalActionsTests.swift
// PopGuyTests
//
// TDD: principal/burger partition over actionOrder (isPrincipal set).

import Foundation
import Testing
@testable import PopGuy

@Suite("Principal actions")
@MainActor
struct PrincipalActionsTests {

    private func makeSuite() -> (UserDefaults, String) {
        let name = UserDefaults.testSuiteDirectory + "/com.popguy.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func removeSuite(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    @Test("principal and overflow partition enabledOrderedIdentifiers in order")
    func partitionRespectsOrder() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let principal = store.principalOrderedIdentifiers
        let overflow = store.overflowOrderedIdentifiers
        let enabled = store.enabledOrderedIdentifiers

        #expect(principal + overflow == enabled)
        #expect(Set(principal).isDisjoint(with: Set(overflow)))
    }

    @Test("fresh-install migration assigns every enabled action to principal")
    func migrationAssignsAllEnabled() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Enable 7 built-ins (more than the old cap of 6), then drop the saved
        // partition so the next load runs the first-launch migration.
        let store1 = SettingsStore(defaults: suite)
        store1.promptEnabled = true
        store1.dictionaryConfig.isEnabled = true
        suite.removeObject(forKey: "settings.principalActionIDs")

        let store = SettingsStore(defaults: suite)
        #expect(store.enabledOrderedIdentifiers.count == 7)
        #expect(store.principalActionIDs == Set(store.enabledOrderedIdentifiers))
        #expect(store.overflowOrderedIdentifiers.isEmpty)
    }

    @Test("every enabled action can become principal")
    func everyEnabledActionCanBePrincipal() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        store.promptEnabled = true
        store.dictionaryConfig.isEnabled = true
        for i in 0..<5 {
            store.addCustomAction(CustomAction(title: "Custom \(i)", systemPrompt: "p", isEnabled: true))
        }

        for id in store.enabledOrderedIdentifiers {
            store.setPrincipal(id, true)
        }
        #expect(store.principalOrderedIdentifiers.count == 12)
        #expect(store.overflowOrderedIdentifiers.isEmpty)
    }

    @Test("eight or more enabled actions can sit in More actions")
    func manyActionsCanSitInMore() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        for i in 0..<4 {
            store.addCustomAction(CustomAction(title: "More \(i)", systemPrompt: "p", isEnabled: true))
        }

        for id in store.enabledOrderedIdentifiers {
            store.setPrincipal(id, false)
        }
        #expect(store.overflowOrderedIdentifiers.count == 9)
        #expect(store.principalOrderedIdentifiers.isEmpty)

        // A persisted empty principal set is a user choice, not a first launch.
        let reloaded = SettingsStore(defaults: suite)
        #expect(reloaded.principalActionIDs.isEmpty)
        #expect(reloaded.overflowOrderedIdentifiers.count == 9)
    }

    @Test("disabled actions switch zones freely")
    func disabledActionsSwitchZonesFreely() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        store.improveEnabled = false
        store.setPrincipal(.builtin(.improve), false)
        #expect(!store.isPrincipal(.builtin(.improve)))
        store.setPrincipal(.builtin(.improve), true)
        #expect(store.isPrincipal(.builtin(.improve)))
    }

    @Test("migration persists principalActionIDs across reload")
    func migrationPersistsAcrossReload() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store1 = SettingsStore(defaults: suite)
        let expected = store1.principalActionIDs

        let store2 = SettingsStore(defaults: suite)
        #expect(store2.principalActionIDs == expected)
    }

    @Test("loading a saved layout drops stale IDs without trimming")
    func loadDropsStaleWithoutTrimming() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let stale = UUID()
        let principal: Set<ActionIdentifier> = [
            .builtin(.improve),
            .builtin(.shorten),
            .builtin(.proofread),
            .builtin(.prompt),
            .builtin(.translate),
            .dictionary,
            .speak,
            .custom(stale),
        ]
        if let data = try? JSONEncoder().encode(principal) {
            suite.set(data, forKey: "settings.principalActionIDs")
        }

        let store = SettingsStore(defaults: suite)
        #expect(!store.principalActionIDs.contains(.custom(stale)))
        #expect(store.principalActionIDs == Set(SettingsStore.defaultBuiltinOrder))
    }

    @Test("deleteCustomAction removes id from principalActionIDs")
    func deleteCustomActionRemovesPrincipal() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let action = CustomAction(title: "P", systemPrompt: "p", isEnabled: true)
        store.addCustomAction(action)
        store.setPrincipal(.custom(action.id), true)

        store.deleteCustomAction(id: action.id)
        #expect(!store.principalActionIDs.contains(.custom(action.id)))
    }

    @Test("toggling hideToolbarLogo never changes principalActionIDs")
    func toggleLogoKeepsPrincipal() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        #expect(!store.hideToolbarLogo)

        store.hideToolbarLogo = true
        store.promptEnabled = true
        store.dictionaryConfig.isEnabled = true
        for id in store.enabledOrderedIdentifiers {
            store.setPrincipal(id, true)
        }
        let before = store.principalActionIDs
        #expect(store.principalOrderedIdentifiers.count == 7)

        store.hideToolbarLogo = false
        #expect(store.principalActionIDs == before)
        #expect(store.principalOrderedIdentifiers.count == 7)
        #expect(!SettingsStore(defaults: suite).hideToolbarLogo)

        store.hideToolbarLogo = true
        #expect(store.principalActionIDs == before)
        #expect(SettingsStore(defaults: suite).hideToolbarLogo)
    }

    // MARK: - Show label

    @Test("no action is labeled by default")
    func noActionLabeledByDefault() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        store.addCustomAction(CustomAction(title: "C", systemPrompt: "p", isEnabled: true))

        #expect(store.labeledActionIDs.isEmpty)
        for id in store.actionOrder {
            #expect(!store.isLabeled(id))
        }
    }

    @Test("setLabeled persists across reload")
    func setLabeledPersistsAcrossReload() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        store.setLabeled(.builtin(.translate), true)
        #expect(store.isLabeled(.builtin(.translate)))

        let reloaded = SettingsStore(defaults: suite)
        #expect(reloaded.isLabeled(.builtin(.translate)))
        #expect(reloaded.labeledActionIDs.contains(.builtin(.translate)))
    }

    @Test("moving an action into More keeps its label")
    func setPrincipalKeepsLabel() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        store.setLabeled(.builtin(.improve), true)
        store.setPrincipal(.builtin(.improve), false)

        #expect(!store.isPrincipal(.builtin(.improve)))
        #expect(store.isLabeled(.builtin(.improve)))
    }

    @Test("deleteCustomAction removes id from labeledActionIDs")
    func deleteCustomActionRemovesLabel() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let action = CustomAction(title: "L", systemPrompt: "p", isEnabled: true)
        store.addCustomAction(action)
        store.setLabeled(.custom(action.id), true)

        store.deleteCustomAction(id: action.id)
        #expect(!store.labeledActionIDs.contains(.custom(action.id)))
    }
}

// MARK: - Test helpers

private extension SettingsStore {
    func setEnabled(_ id: ActionIdentifier, _ enabled: Bool) {
        switch id {
        case .builtin(.improve):   improveEnabled = enabled
        case .builtin(.shorten):   shortenEnabled = enabled
        case .builtin(.proofread): proofreadEnabled = enabled
        case .builtin(.prompt):    promptEnabled = enabled
        case .builtin(.translate): translateEnabled = enabled
        case .speak:               speakEnabled = enabled
        case .dictionary:
            var config = dictionaryConfig
            config.isEnabled = enabled
            dictionaryConfig = config
        case .custom(let uuid):
            guard var action = customActions.first(where: { $0.id == uuid }) else { return }
            action.isEnabled = enabled
            updateCustomAction(action)
        }
    }
}
