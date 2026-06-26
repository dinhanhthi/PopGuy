// LemonSqueezyLicenseValidator.swift
// PopGuy — Licensing
//
// Validates license keys against the Lemon Squeezy License API.
//
// Endpoints (base https://api.lemonsqueezy.com/v1/licenses/):
//   POST /activate   — body: license_key, instance_name
//   POST /validate   — body: license_key, instance_id
//   POST /deactivate — body: license_key, instance_id
//
// No bearer token required; Accept: application/json; body is form-urlencoded.
// All responses are treated as untrusted external data (https only, tolerant decoding).
//
// Keychain accounts owned:
//   "license.instanceId"   — LS instance identifier stored after first activation
//   "license.instanceName" — stable per-machine label (UUID, generated once)
//
// Isolation: nonisolated — mirroring KeychainManager. URLSession and Keychain
// Services are thread-safe. Off-main by design so network + Keychain work never
// blocks the MainActor.

import Foundation

// MARK: - LemonSqueezyLicenseValidator

nonisolated struct LemonSqueezyLicenseValidator: LicenseValidating {

    // MARK: - Dependencies

    private let session: URLSession
    private let keychain: KeychainManager

    // MARK: - Constants

    private static let baseURL = "https://api.lemonsqueezy.com/v1/licenses"

    private enum KeychainAccount {
        static let instanceId   = "license.instanceId"
        static let instanceName = "license.instanceName"
    }

    // MARK: - Init

    /// Create a validator.
    ///
    /// - Parameters:
    ///   - session: The URLSession used for network requests. Defaults to `.shared`.
    ///   - keychain: The KeychainManager for instance persistence. Defaults to the
    ///     production instance.
    init(session: URLSession = .shared, keychain: KeychainManager = KeychainManager()) {
        self.session = session
        self.keychain = keychain
    }

    // MARK: - LicenseValidating

    func validate(licenseKey: String) async -> LicenseStatus {
        if let instanceId = keychain.key(account: KeychainAccount.instanceId) {
            return await validateExistingInstance(licenseKey: licenseKey, instanceId: instanceId)
        } else {
            return await activateNewInstance(licenseKey: licenseKey)
        }
    }

    func deactivate(licenseKey: String) async {
        // Capture the instanceId at entry before the network call so a concurrent
        // re-activation that writes a new instanceId is not accidentally deleted.
        guard let capturedInstanceId = keychain.key(account: KeychainAccount.instanceId) else { return }

        // Best-effort: call LS /deactivate; ignore the response.
        _ = try? await deactivateRequest(licenseKey: licenseKey, instanceId: capturedInstanceId)

        // Re-read after the async call; only delete if the value is still ours.
        // If a re-activation ran during the network call it will have stored a
        // new instanceId — leaving it intact avoids wiping a valid fresh seat.
        guard keychain.key(account: KeychainAccount.instanceId) == capturedInstanceId else { return }
        keychain.deleteKey(account: KeychainAccount.instanceId)
        keychain.deleteKey(account: KeychainAccount.instanceName)
    }

    // MARK: - Activate path

    private func activateNewInstance(licenseKey: String) async -> LicenseStatus {
        // Ensure a stable per-machine instance name; generate and persist if absent.
        let instanceName: String
        if let stored = keychain.key(account: KeychainAccount.instanceName) {
            instanceName = stored
        } else {
            let generated = UUID().uuidString
            keychain.setKey(generated, account: KeychainAccount.instanceName)
            instanceName = generated
        }

        let body = formEncode([
            "license_key":   licenseKey,
            "instance_name": instanceName
        ])

        guard let request = makeRequest(path: "activate", body: body) else {
            return .offlineUnverified
        }

        let response: ActivateResponse
        let statusCode: Int
        do {
            (response, statusCode) = try await fetch(ActivateResponse.self, request: request)
        } catch {
            return .offlineUnverified
        }

        // Classify by HTTP status before trusting the decoded verdict.
        // Retryable errors (5xx, 429, 408, unknown) must never downgrade a paying user.
        switch statusCode {
        case 408, 429:
            return .offlineUnverified
        case 200...499:
            break   // 2xx and 4xx: fall through to decode-and-act
        default:
            return .offlineUnverified   // 5xx, 0/unknown
        }

        // Nil-verdict guard: unparseable-but-reachable response should not punish.
        guard response.activated != nil else {
            return .offlineUnverified
        }

        if response.activated == true {
            // Finding 3: activated-but-no-instance.id must not silently grant Pro.
            // Returning without storing instanceId would re-activate every launch and
            // burn seats; treat it as an anomaly instead.
            guard let id = response.instance?.id else {
                return .invalid(reason: "Activation could not be completed. Please try again.")
            }
            keychain.setKey(id, account: KeychainAccount.instanceId)
            return .valid(activatedKeyMasked: LicenseKeyMask.mask(licenseKey))
        }

        // Check for activation limit exhaustion via both usage/limit signals and
        // error message (tolerant of future LS wording changes).
        if isActivationLimitReached(response) {
            return .invalid(reason: "This license is already active on the maximum number of Macs. If you reinstalled or replaced a Mac, deactivate it in Settings → License first, or email me@dinhanhthi.com to free up an activation.")
        }

        let reason = response.error ?? "License key is not valid."
        return .invalid(reason: reason)
    }

    // MARK: - Validate path

    private func validateExistingInstance(licenseKey: String, instanceId: String) async -> LicenseStatus {
        let body = formEncode([
            "license_key": licenseKey,
            "instance_id": instanceId
        ])

        guard let request = makeRequest(path: "validate", body: body) else {
            return .offlineUnverified
        }

        let response: ValidateResponse
        let statusCode: Int
        do {
            (response, statusCode) = try await fetch(ValidateResponse.self, request: request)
        } catch {
            return .offlineUnverified
        }

        // Classify by HTTP status before trusting the decoded verdict.
        switch statusCode {
        case 408, 429:
            return .offlineUnverified
        case 200...499:
            break   // 2xx and 4xx: fall through to decode-and-act
        default:
            return .offlineUnverified   // 5xx, 0/unknown
        }

        // Nil-verdict guard: unparseable-but-reachable response should not punish.
        guard response.valid != nil else {
            return .offlineUnverified
        }

        if response.valid == true {
            // Finding 2: use a denylist rather than an allowlist so unknown/future
            // statuses with valid==true stay .valid (prevents false-negative downgrades).
            let knownBad: Set<String> = ["expired", "disabled", "inactive"]
            let status = (response.licenseKey?.status ?? "").lowercased()
            if !knownBad.contains(status) {
                return .valid(activatedKeyMasked: LicenseKeyMask.mask(licenseKey))
            }
        }

        let reason = response.error ?? "License key is not valid."
        return .invalid(reason: reason)
    }

    // MARK: - Deactivate request

    @discardableResult
    private func deactivateRequest(licenseKey: String, instanceId: String) async throws -> DeactivateResponse {
        let body = formEncode([
            "license_key": licenseKey,
            "instance_id": instanceId
        ])

        guard let request = makeRequest(path: "deactivate", body: body) else {
            throw URLError(.badURL)
        }

        let (resp, _) = try await fetch(DeactivateResponse.self, request: request)
        return resp
    }

    // MARK: - Helpers

    /// Build a URLRequest for a license endpoint.
    ///
    /// Returns `nil` if the URL cannot be constructed or does not use https.
    private func makeRequest(path: String, body: Data) -> URLRequest? {
        guard var components = URLComponents(string: "\(Self.baseURL)/\(path)") else { return nil }
        // Enforce https.
        guard components.scheme == "https" else { return nil }
        components.percentEncodedQuery = nil

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Encode a dictionary as `application/x-www-form-urlencoded` bytes.
    private func formEncode(_ params: [String: String]) -> Data {
        let pairs = params.map { key, value -> String in
            let encodedKey   = percentEncode(key)
            let encodedValue = percentEncode(value)
            return "\(encodedKey)=\(encodedValue)"
        }
        return pairs.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    /// Percent-encode a string for form data (RFC 3986 unreserved characters only).
    private func percentEncode(_ string: String) -> String {
        // Allow unreserved chars; everything else is percent-encoded.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// Fetch and decode a `Decodable` response.
    ///
    /// Returns the decoded value together with the HTTP status code so callers
    /// can classify retryable server errors (5xx, 429, 408) before trusting the
    /// decoded verdict. Throws only on transport failures (URLError) or
    /// undecodable responses; callers must catch and treat as `.offlineUnverified`.
    private func fetch<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> (T, Int) {
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (try JSONDecoder().decode(T.self, from: data), statusCode)
    }

    /// Determine if the server is saying the activation limit is exhausted.
    ///
    /// Uses both the usage/limit numeric fields (most reliable) and a
    /// case-insensitive keyword scan of the error string (resilient to LS
    /// wording changes).
    private func isActivationLimitReached(_ response: ActivateResponse) -> Bool {
        if let limit = response.licenseKey?.activationLimit,
           let usage = response.licenseKey?.activationUsage,
           usage >= limit {
            return true
        }
        if let error = response.error,
           error.localizedCaseInsensitiveContains("activation limit") {
            return true
        }
        return false
    }

}

// MARK: - Codable response models
//
// Marked `nonisolated` to prevent SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor from
// inferring a MainActor-isolated Decodable conformance (InferIsolatedConformances).
// These are plain data bags decoded off-main; they need no actor isolation.

/// Response from POST /activate.
private nonisolated struct ActivateResponse: Decodable {
    var activated: Bool?
    var instance: InstanceInfo?
    var licenseKey: LicenseKeyInfo?
    var error: String?

    private enum CodingKeys: String, CodingKey {
        case activated
        case instance
        case licenseKey = "license_key"
        case error
    }

    nonisolated struct InstanceInfo: Decodable {
        var id: String?
    }

    nonisolated struct LicenseKeyInfo: Decodable {
        var status: String?
        var activationLimit: Int?
        var activationUsage: Int?

        private enum CodingKeys: String, CodingKey {
            case status
            case activationLimit  = "activation_limit"
            case activationUsage  = "activation_usage"
        }
    }
}

/// Response from POST /validate.
private nonisolated struct ValidateResponse: Decodable {
    var valid: Bool?
    var licenseKey: LicenseKeyInfo?
    var error: String?

    private enum CodingKeys: String, CodingKey {
        case valid
        case licenseKey = "license_key"
        case error
    }

    nonisolated struct LicenseKeyInfo: Decodable {
        var status: String?
    }
}

/// Response from POST /deactivate.
private nonisolated struct DeactivateResponse: Decodable {
    var deactivated: Bool?
    var error: String?
}
