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
        let name = "com.popguy.test.\(UUID().uuidString)"
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

    @Test("migration assigns first maxPrincipalActions enabled actions to principal")
    func migrationDefaults() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let expectedPrincipal = Set(store.enabledOrderedIdentifiers.prefix(ProConfig.maxPrincipalActions))
        #expect(store.principalActionIDs == expectedPrincipal)
        #expect(store.principalActionCount <= ProConfig.maxPrincipalActions)
    }

    @Test("setPrincipal rejects when enabled principal zone is full")
    func setPrincipalRejectsPrincipalCap() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        store.promptEnabled = true
        _ = store.setPrincipal(.builtin(.prompt), true)
        store.dictionaryConfig.isEnabled = true
        #expect(store.principalActionCount == ProConfig.maxPrincipalActions)

        #expect(!store.setPrincipal(.dictionary, true))
        #expect(!store.isPrincipal(.dictionary))
    }

    @Test("setPrincipal rejects when enabled burger zone is full")
    func setPrincipalRejectsBurgerCap() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        store.promptEnabled = true
        _ = store.setPrincipal(.builtin(.prompt), true)
        store.dictionaryConfig.isEnabled = true

        for i in 0..<4 {
            store.addCustomAction(CustomAction(title: "Burger \(i)", systemPrompt: "p", isEnabled: true))
        }
        #expect(store.overflowActionCount == ProConfig.maxBurgerActions)

        guard let principalID = store.principalOrderedIdentifiers.first else {
            Issue.record("Expected a principal action")
            return
        }
        #expect(!store.setPrincipal(principalID, false))
        #expect(store.isPrincipal(principalID))
    }

    @Test("disabled actions switch zones without cap check")
    func disabledActionsSwitchZonesFreely() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        store.improveEnabled = false
        #expect(store.setPrincipal(.builtin(.improve), false))
        #expect(!store.isPrincipal(.builtin(.improve)))
        #expect(store.setPrincipal(.builtin(.improve), true))
        #expect(store.isPrincipal(.builtin(.improve)))
    }

    @Test("disabled overflow assignments do not block moving enabled actions to More")
    func disabledOverflowDoesNotBlockEnabledDemotion() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        // Fill burger zone with disabled assignments (not visible in overflowActionCount).
        store.shortenEnabled = false
        store.proofreadEnabled = false
        _ = store.setPrincipal(.builtin(.shorten), false)
        _ = store.setPrincipal(.builtin(.proofread), false)

        let disabledOverflow = store.actionOrder.filter { !store.isPrincipal($0) }.count
        #expect(disabledOverflow >= 2)
        #expect(store.overflowActionCount < ProConfig.maxBurgerActions)

        guard let principalID = store.principalOrderedIdentifiers.first else {
            Issue.record("Expected a principal action")
            return
        }
        #expect(store.setPrincipal(principalID, false))
        #expect(!store.isPrincipal(principalID))
        #expect(store.overflowActionCount <= ProConfig.maxBurgerActions)
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

    @Test("reconcilePrincipal drops stale IDs and trims over-cap principal set")
    func reconcilePrincipalTrimsAndDropsStale() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let stale = UUID()
        var principal: Set<ActionIdentifier> = [
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
        #expect(store.principalActionIDs.count <= ProConfig.maxPrincipalActions)
        let ordered = store.actionOrder.filter { store.isPrincipal($0) }
        #expect(ordered.count == store.principalActionIDs.count)
    }

    @Test("deleteCustomAction removes id from principalActionIDs")
    func deleteCustomActionRemovesPrincipal() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite)
        let action = CustomAction(title: "P", systemPrompt: "p", isEnabled: true)
        store.addCustomAction(action)
        _ = store.setPrincipal(.custom(action.id), true)

        store.deleteCustomAction(id: action.id)
        #expect(!store.principalActionIDs.contains(.custom(action.id)))
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
