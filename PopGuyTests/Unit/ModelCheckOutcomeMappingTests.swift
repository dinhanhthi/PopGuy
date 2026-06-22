// ModelCheckOutcomeMappingTests.swift
// PopGuyTests
//
// Unit tests for mapModelCheckOutcome(_:customEndpointMissing:) — the free
// function extracted from ModelField.runCheck() in SettingsView.swift.
//
// Tests the full outcome-mapping contract without any live network calls.

import Foundation
import Testing
@testable import PopGuy

@Suite("ModelCheckOutcomeMapping")
struct ModelCheckOutcomeMappingTests {

    // MARK: - Success

    @Test("nil error, endpoint present → valid")
    func nilErrorReturnsValid() {
        let outcome = mapModelCheckOutcome(error: nil, customEndpointMissing: false)
        #expect(outcome == .valid)
    }

    // MARK: - No endpoint

    @Test("customEndpointMissing=true → noEndpoint regardless of error")
    func missingEndpointReturnsNoEndpoint() {
        let outcome = mapModelCheckOutcome(error: nil, customEndpointMissing: true)
        #expect(outcome == .noEndpoint)
    }

    @Test("customEndpointMissing=true with httpError(401) → noEndpoint (endpoint check is prior)")
    func missingEndpointWithHttpError() {
        let err = ProviderError.httpError(statusCode: 401, body: nil)
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: true)
        #expect(outcome == .noEndpoint)
    }

    // MARK: - Invalid model (400, 401, 403, 404)

    @Test("httpError(400) → invalid (bad request / model not accepted)")
    func httpError400ReturnsInvalid() {
        let err = ProviderError.httpError(statusCode: 400, body: "model_not_found")
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: false)
        #expect(outcome == .invalid)
    }

    @Test("httpError(401) → invalid (key rejected)")
    func httpError401ReturnsInvalid() {
        let err = ProviderError.httpError(statusCode: 401, body: nil)
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: false)
        #expect(outcome == .invalid)
    }

    @Test("httpError(403) → invalid (forbidden)")
    func httpError403ReturnsInvalid() {
        let err = ProviderError.httpError(statusCode: 403, body: "Forbidden")
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: false)
        #expect(outcome == .invalid)
    }

    @Test("httpError(404) → invalid (model not found)")
    func httpError404ReturnsInvalid() {
        let err = ProviderError.httpError(statusCode: 404, body: "Model not found")
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: false)
        #expect(outcome == .invalid)
    }

    // MARK: - Unreachable (non-auth HTTP errors and transport)

    @Test("httpError(500) → unreachable")
    func httpError500ReturnsUnreachable() {
        let err = ProviderError.httpError(statusCode: 500, body: "Internal Server Error")
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: false)
        #expect(outcome == .unreachable)
    }

    @Test("httpError(429) → unreachable")
    func httpError429ReturnsUnreachable() {
        let err = ProviderError.httpError(statusCode: 429, body: "Too Many Requests")
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: false)
        #expect(outcome == .unreachable)
    }

    @Test("ProviderError.transport → unreachable")
    func transportErrorReturnsUnreachable() {
        let err = ProviderError.transport("connection refused")
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: false)
        #expect(outcome == .unreachable)
    }

    @Test("URLError (non-ProviderError) → unreachable")
    func urlErrorReturnsUnreachable() {
        let err = URLError(.notConnectedToInternet)
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: false)
        #expect(outcome == .unreachable)
    }

    // MARK: - default: branch (non-httpError ProviderError variants)

    @Test("ProviderError.decodingFailed → unreachable (default branch)")
    func decodingFailedReturnsUnreachable() {
        let err = ProviderError.decodingFailed("unexpected JSON shape")
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: false)
        #expect(outcome == .unreachable)
    }

    @Test("ProviderError.missingOption → unreachable (default branch)")
    func missingOptionReturnsUnreachable() {
        let err = ProviderError.missingOption("targetLanguage")
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: false)
        #expect(outcome == .unreachable)
    }

    @Test("ProviderError.unexpectedResponse → unreachable (default branch)")
    func unexpectedResponseReturnsUnreachable() {
        let err = ProviderError.unexpectedResponse("empty body")
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: false)
        #expect(outcome == .unreachable)
    }

    @Test("ProviderError.apiError → unreachable (default branch)")
    func apiErrorReturnsUnreachable() {
        let err = ProviderError.apiError("overloaded_error", "Model is overloaded, please retry")
        let outcome = mapModelCheckOutcome(error: err, customEndpointMissing: false)
        #expect(outcome == .unreachable)
    }
}
