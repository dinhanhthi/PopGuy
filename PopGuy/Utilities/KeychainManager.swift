// KeychainManager.swift
// PopGuy — Utilities
//
// Stores, retrieves, and deletes API keys via Keychain Services.
//
// HARD CONSTRAINT: API keys are stored ONLY in the Keychain.
// Never use UserDefaults, plist, or any plaintext store for keys.
//
// Service name = bundle id "dinh.thi.PopGuy" (constant below).
// Account = ProviderKind.rawValue so each provider has a distinct slot.
//
// Isolation: nonisolated — Keychain Services (SecItem* APIs) are documented
// as thread-safe. Marking nonisolated opts out of SWIFT_DEFAULT_ACTOR_ISOLATION
// = MainActor so KeychainManager can be used from ActionEngine and tests
// without a main-thread hop.

import Foundation
import Security

// MARK: - KeychainManager

/// Wraps Keychain Services for storing one API key per provider.
///
/// All methods are synchronous and thread-safe (Keychain Services is thread-safe).
/// Marked `nonisolated` so it can be used from `nonisolated` contexts such as
/// `ActionEngine` without a MainActor hop.
///
/// The service name is injectable so tests can use a unique ephemeral service
/// name without touching the production keychain slots (which are keyed on
/// `defaultServiceName`). Production code uses `KeychainManager()` unchanged.
nonisolated struct KeychainManager: Sendable {

    // MARK: - Constants

    /// Keychain service name for the production app.
    static let defaultServiceName = "dinh.thi.PopGuy"

    // MARK: - State

    /// The Keychain service name this instance operates under.
    let serviceName: String

    // MARK: - Init

    /// Create a KeychainManager.
    ///
    /// - Parameter serviceName: The Keychain service name. Defaults to the
    ///   bundle identifier. Pass a unique ephemeral name in tests to isolate
    ///   from production keychain entries.
    init(serviceName: String = KeychainManager.defaultServiceName) {
        self.serviceName = serviceName
    }

    // MARK: - Store

    /// Save or update an API key in the keychain for a given account string.
    ///
    /// - Parameters:
    ///   - key: The API key string to store.
    ///   - account: The keychain account identifier (must be unique per key slot).
    /// - Returns: `true` on success, `false` if the Keychain operation failed.
    @discardableResult
    func setKey(_ key: String, account: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        // Try an update first; if the item doesn't exist yet, add it.
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        // kSecAttrAccessibleWhenUnlockedThisDeviceOnly: keys are accessible only
        // when the device is unlocked and are never migrated to other devices
        // (no iCloud Keychain, no backups). Appropriate for machine-specific API keys.
        let update: [String: Any] = [
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        // Item doesn't exist — add new.
        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    /// Save or update an API key in the keychain for the given provider.
    ///
    /// - Parameters:
    ///   - key: The API key string to store.
    ///   - provider: The provider whose key slot is being written.
    /// - Returns: `true` on success, `false` if the Keychain operation failed.
    @discardableResult
    func setKey(_ key: String, for provider: ProviderKind) -> Bool {
        setKey(key, account: provider.rawValue)
    }

    // MARK: - Retrieve

    /// Read a stored API key for a given account string.
    ///
    /// - Parameter account: The keychain account identifier.
    /// - Returns: The stored key string, or `nil` if no key is stored or retrieval fails.
    func key(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    /// Read the stored API key for a provider.
    ///
    /// - Parameter provider: The provider whose key to retrieve.
    /// - Returns: The stored key string, or `nil` if no key is stored or retrieval fails.
    func key(for provider: ProviderKind) -> String? {
        key(account: provider.rawValue)
    }

    // MARK: - Delete

    /// Remove a stored API key for a given account string.
    ///
    /// - Parameter account: The keychain account identifier.
    /// - Returns: `true` on success or if no item existed, `false` on unexpected error.
    @discardableResult
    func deleteKey(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound means nothing to delete — treat as success.
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Remove the stored API key for a provider.
    ///
    /// - Parameter provider: The provider whose key to delete.
    /// - Returns: `true` on success or if no item existed, `false` on unexpected error.
    @discardableResult
    func deleteKey(for provider: ProviderKind) -> Bool {
        deleteKey(account: provider.rawValue)
    }
}
