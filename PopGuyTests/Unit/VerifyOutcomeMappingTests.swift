// VerifyOutcomeMappingTests.swift
// PopGuyTests
//
// Unit tests for mapVerifyOutcome(_:hasKey:customEndpointMissing:) — the free
// function extracted from APIKeysTab.verifyKey(for:) in SettingsView.swift.
//
// These tests lock in the HTTP 400 fix (Google Translate API_KEY_INVALID) and
// the full outcome-mapping contract without any live network calls.

import Foundation
import Testing
@testable import PopGuy

@Suite("VerifyOutcomeMapping")
struct VerifyOutcomeMappingTests {

    // MARK: - Success

    @Test("nil error with key present → valid")
    func nilErrorReturnsValid() {
        let outcome = mapVerifyOutcome(error: nil, hasKey: true, customEndpointMissing: false)
        #expect(outcome == .valid)
    }

    // MARK: - No key

    @Test("hasKey=false → noKey regardless of error")
    func noKeyReturnsNoKey() {
        let outcome = mapVerifyOutcome(error: nil, hasKey: false, customEndpointMissing: false)
        #expect(outcome == .noKey)
    }

    @Test("hasKey=false with httpError(401) → noKey (key check is prior)")
    func noKeyWithHttpError() {
        let err = ProviderError.httpError(statusCode: 401, body: nil)
        let outcome = mapVerifyOutcome(error: err, hasKey: false, customEndpointMissing: false)
        #expect(outcome == .noKey)
    }

    // MARK: - No endpoint

    @Test("customEndpointMissing=true with key → noEndpoint")
    func missingEndpointReturnsNoEndpoint() {
        let outcome = mapVerifyOutcome(error: nil, hasKey: true, customEndpointMissing: true)
        #expect(outcome == .noEndpoint)
    }

    // MARK: - Invalid key (400, 401, 403)

    @Test("httpError(400) → invalid (Google Translate API_KEY_INVALID)")
    func httpError400ReturnsInvalid() {
        let err = ProviderError.httpError(statusCode: 400, body: "API_KEY_INVALID")
        let outcome = mapVerifyOutcome(error: err, hasKey: true, customEndpointMissing: false)
        #expect(outcome == .invalid)
    }

    @Test("httpError(401) → invalid")
    func httpError401ReturnsInvalid() {
        let err = ProviderError.httpError(statusCode: 401, body: nil)
        let outcome = mapVerifyOutcome(error: err, hasKey: true, customEndpointMissing: false)
        #expect(outcome == .invalid)
    }

    @Test("httpError(403) → invalid")
    func httpError403ReturnsInvalid() {
        let err = ProviderError.httpError(statusCode: 403, body: "Forbidden")
        let outcome = mapVerifyOutcome(error: err, hasKey: true, customEndpointMissing: false)
        #expect(outcome == .invalid)
    }

    // MARK: - Unreachable (non-auth HTTP errors and transport)

    @Test("httpError(500) → unreachable")
    func httpError500ReturnsUnreachable() {
        let err = ProviderError.httpError(statusCode: 500, body: "Internal Server Error")
        let outcome = mapVerifyOutcome(error: err, hasKey: true, customEndpointMissing: false)
        #expect(outcome == .unreachable)
    }

    @Test("httpError(429) → unreachable")
    func httpError429ReturnsUnreachable() {
        let err = ProviderError.httpError(statusCode: 429, body: "Too Many Requests")
        let outcome = mapVerifyOutcome(error: err, hasKey: true, customEndpointMissing: false)
        #expect(outcome == .unreachable)
    }

    @Test("transport error → unreachable")
    func transportErrorReturnsUnreachable() {
        let err = ProviderError.transport("connection refused")
        let outcome = mapVerifyOutcome(error: err, hasKey: true, customEndpointMissing: false)
        #expect(outcome == .unreachable)
    }

    @Test("URLError (non-ProviderError) → unreachable")
    func urlErrorReturnsUnreachable() {
        let err = URLError(.notConnectedToInternet)
        let outcome = mapVerifyOutcome(error: err, hasKey: true, customEndpointMissing: false)
        #expect(outcome == .unreachable)
    }
}
