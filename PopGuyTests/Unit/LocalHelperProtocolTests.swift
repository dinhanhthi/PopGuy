// LocalHelperProtocolTests.swift
// PopGuyTests
//
// Tests for the PopGuyMLXHelper stdio wire protocol (HelperRequest / HelperResponse).
// Covers:
//   - Golden JSON: exact "type" discriminator string for every case
//   - Decode → encode → decode identity (round-trip)
//   - Unknown "type" and missing required fields are rejected (throws)
//   - isQwenFamily() detection: positive and negative cases

import Foundation
import Testing
@testable import PopGuy

// MARK: - Helpers

@MainActor
private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = []
    return e
}()

@MainActor
private let decoder = JSONDecoder()

@MainActor
private func json(_ value: some Encodable) throws -> [String: Any] {
    let data = try encoder.encode(value)
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    return obj
}

@MainActor
private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try encoder.encode(value)
    return try decoder.decode(T.self, from: data)
}

// MARK: - HelperRequest

@Suite("HelperRequest wire protocol")
@MainActor
struct HelperRequestTests {

    @Test("ping encodes type=ping")
    func pingTypeDiscriminator() throws {
        let obj = try json(HelperRequest.ping)
        #expect(obj["type"] as? String == "ping")
    }

    @Test("ping round-trip identity")
    func pingRoundTrip() throws {
        #expect(try roundTrip(HelperRequest.ping) == .ping)
    }

    @Test("download encodes type=download and modelID")
    func downloadTypeDiscriminator() throws {
        let obj = try json(HelperRequest.download(modelID: "mlx-community/gemma-4-e2b-it-4bit"))
        #expect(obj["type"] as? String == "download")
        #expect(obj["modelID"] as? String == "mlx-community/gemma-4-e2b-it-4bit")
    }

    @Test("download round-trip identity")
    func downloadRoundTrip() throws {
        let req = HelperRequest.download(modelID: "mlx-community/test-model")
        #expect(try roundTrip(req) == req)
    }

    @Test("generate encodes type=generate and all fields")
    func generateTypeDiscriminator() throws {
        let req = HelperRequest.generate(
            modelID: "mlx-community/Qwen3-1.7B-4bit-DWQ",
            systemPrompt: "You are helpful.",
            input: "Hello",
            maxTokens: 512,
            temperature: 0.7
        )
        let obj = try json(req)
        #expect(obj["type"] as? String == "generate")
        #expect(obj["modelID"] as? String == "mlx-community/Qwen3-1.7B-4bit-DWQ")
        #expect(obj["systemPrompt"] as? String == "You are helpful.")
        #expect(obj["input"] as? String == "Hello")
        #expect(obj["maxTokens"] as? Int == 512)
        #expect(obj["temperature"] as? Double == 0.7)
    }

    @Test("generate omits systemPrompt key when nil")
    func generateOmitsNilSystemPrompt() throws {
        let req = HelperRequest.generate(
            modelID: "m", systemPrompt: nil, input: "q", maxTokens: 1, temperature: 0.5
        )
        let obj = try json(req)
        #expect(obj["systemPrompt"] == nil)
    }

    @Test("generate round-trip identity with systemPrompt")
    func generateRoundTripWithSystemPrompt() throws {
        let req = HelperRequest.generate(
            modelID: "mlx-community/gemma-4-e2b-it-4bit",
            systemPrompt: "Be concise.",
            input: "Summarize this.",
            maxTokens: 256,
            temperature: 0.6
        )
        #expect(try roundTrip(req) == req)
    }

    @Test("generate round-trip identity without systemPrompt")
    func generateRoundTripWithoutSystemPrompt() throws {
        let req = HelperRequest.generate(
            modelID: "m", systemPrompt: nil, input: "q", maxTokens: 100, temperature: 0.0
        )
        #expect(try roundTrip(req) == req)
    }

    @Test("unload encodes type=unload")
    func unloadTypeDiscriminator() throws {
        let obj = try json(HelperRequest.unload)
        #expect(obj["type"] as? String == "unload")
    }

    @Test("unload round-trip identity")
    func unloadRoundTrip() throws {
        #expect(try roundTrip(HelperRequest.unload) == .unload)
    }

    @Test("unknown type throws on decode")
    func unknownTypeThrows() throws {
        let data = Data(#"{"type":"bogus"}"#.utf8)
        #expect(throws: (any Error).self) {
            try decoder.decode(HelperRequest.self, from: data)
        }
    }

    @Test("missing required field throws on decode")
    func missingModelIDForDownloadThrows() throws {
        // "download" without "modelID"
        let data = Data(#"{"type":"download"}"#.utf8)
        #expect(throws: (any Error).self) {
            try decoder.decode(HelperRequest.self, from: data)
        }
    }

    @Test("missing input field for generate throws")
    func missingInputForGenerateThrows() throws {
        let data = Data(#"{"type":"generate","modelID":"m","maxTokens":1,"temperature":0.5}"#.utf8)
        #expect(throws: (any Error).self) {
            try decoder.decode(HelperRequest.self, from: data)
        }
    }
}

// MARK: - HelperResponse

@Suite("HelperResponse wire protocol")
@MainActor
struct HelperResponseTests {

    @Test("ready encodes type=ready")
    func readyTypeDiscriminator() throws {
        let obj = try json(HelperResponse.ready)
        #expect(obj["type"] as? String == "ready")
    }

    @Test("ready round-trip identity")
    func readyRoundTrip() throws {
        #expect(try roundTrip(HelperResponse.ready) == .ready)
    }

    @Test("progress encodes type=progress and all fields")
    func progressTypeDiscriminator() throws {
        let resp = HelperResponse.progress(
            modelID: "mlx-community/gemma-4-e2b-it-4bit",
            fraction: 0.5,
            downloadedBytes: 500,
            totalBytes: 1000
        )
        let obj = try json(resp)
        #expect(obj["type"] as? String == "progress")
        #expect(obj["modelID"] as? String == "mlx-community/gemma-4-e2b-it-4bit")
        #expect(obj["fraction"] as? Double == 0.5)
        #expect(obj["downloadedBytes"] as? Int == 500)
        #expect(obj["totalBytes"] as? Int == 1000)
    }

    @Test("progress round-trip identity")
    func progressRoundTrip() throws {
        let resp = HelperResponse.progress(
            modelID: "m", fraction: 0.25, downloadedBytes: 250, totalBytes: 1000
        )
        #expect(try roundTrip(resp) == resp)
    }

    @Test("token encodes type=token and delta")
    func tokenTypeDiscriminator() throws {
        let obj = try json(HelperResponse.token(delta: "Hello"))
        #expect(obj["type"] as? String == "token")
        #expect(obj["delta"] as? String == "Hello")
    }

    @Test("token round-trip identity")
    func tokenRoundTrip() throws {
        let resp = HelperResponse.token(delta: "world")
        #expect(try roundTrip(resp) == resp)
    }

    @Test("done encodes type=done")
    func doneTypeDiscriminator() throws {
        let obj = try json(HelperResponse.done)
        #expect(obj["type"] as? String == "done")
    }

    @Test("done round-trip identity")
    func doneRoundTrip() throws {
        #expect(try roundTrip(HelperResponse.done) == .done)
    }

    @Test("error encodes type=error and message")
    func errorTypeDiscriminator() throws {
        let obj = try json(HelperResponse.error(message: "Something went wrong"))
        #expect(obj["type"] as? String == "error")
        #expect(obj["message"] as? String == "Something went wrong")
    }

    @Test("error round-trip identity")
    func errorRoundTrip() throws {
        let resp = HelperResponse.error(message: "oops")
        #expect(try roundTrip(resp) == resp)
    }

    @Test("unknown type throws on decode")
    func unknownTypeThrows() throws {
        let data = Data(#"{"type":"unknown"}"#.utf8)
        #expect(throws: (any Error).self) {
            try decoder.decode(HelperResponse.self, from: data)
        }
    }

    @Test("missing delta for token throws")
    func missingDeltaThrows() throws {
        let data = Data(#"{"type":"token"}"#.utf8)
        #expect(throws: (any Error).self) {
            try decoder.decode(HelperResponse.self, from: data)
        }
    }

    @Test("missing message for error throws")
    func missingMessageThrows() throws {
        let data = Data(#"{"type":"error"}"#.utf8)
        #expect(throws: (any Error).self) {
            try decoder.decode(HelperResponse.self, from: data)
        }
    }
}

// MARK: - clampMaxTokens

@Suite("clampMaxTokens input policy")
struct ClampMaxTokensTests {

    @Test("0 clamps to 1")
    func zeroBecomesOne() {
        #expect(clampMaxTokens(0) == 1)
    }

    @Test("negative clamps to 1")
    func negativeBecomesOne() {
        #expect(clampMaxTokens(-100) == 1)
    }

    @Test("16384 is accepted as-is")
    func atLimitPassesThrough() {
        #expect(clampMaxTokens(16384) == 16384)
    }

    @Test("99999 clamps to 16384")
    func aboveLimitCaps() {
        #expect(clampMaxTokens(99999) == 16384)
    }

    @Test("100 passes through unchanged")
    func midRangePassesThrough() {
        #expect(clampMaxTokens(100) == 100)
    }
}

// MARK: - sanitizeTemperature

@Suite("sanitizeTemperature input policy")
struct SanitizeTemperatureTests {

    @Test("NaN → 0.7")
    func nanBecomesDefault() {
        #expect(sanitizeTemperature(.nan) == 0.7)
    }

    @Test("negative → 0.7")
    func negativeBecomesDefault() {
        #expect(sanitizeTemperature(-1.0) == 0.7)
    }

    @Test("+Inf → 0.7")
    func positiveInfinityBecomesDefault() {
        #expect(sanitizeTemperature(.infinity) == 0.7)
    }

    @Test("0.0 passes through (ArgMax branch)")
    func zeroPassesThrough() {
        #expect(sanitizeTemperature(0.0) == 0.0)
    }

    @Test("0.7 passes through")
    func defaultPassesThrough() {
        #expect(sanitizeTemperature(0.7) == 0.7)
    }

    @Test("5.0 clamps to 2.0")
    func aboveCapClamps() {
        #expect(sanitizeTemperature(5.0) == 2.0)
    }
}

// MARK: - isQwenFamily detection

@Suite("isQwenFamily detection")
struct IsQwenFamilyTests {

    // Positive: repos that MUST trigger no-think injection
    @Test("Qwen3-1.7B matches")
    func qwen3DWQ() {
        #expect(isQwenFamily("mlx-community/Qwen3-1.7B-4bit-DWQ"))
    }

    @Test("Qwen3.5-4B matches")
    func qwen35() {
        #expect(isQwenFamily("mlx-community/Qwen3.5-4B-MLX-4bit"))
    }

    @Test("QwQ-32B matches")
    func qwq32B() {
        #expect(isQwenFamily("mlx-community/QwQ-32B-Preview-4bit"))
    }

    @Test("lowercase qwen matches")
    func lowercaseQwen() {
        #expect(isQwenFamily("some-qwen-variant"))
    }

    @Test("lowercase qwq matches")
    func lowercaseQwq() {
        #expect(isQwenFamily("qwq-model"))
    }

    // Negative: repos that must NOT trigger no-think injection
    @Test("gemma-4-e2b does not match")
    func gemmaDoesNotMatch() {
        #expect(!isQwenFamily("mlx-community/gemma-4-e2b-it-4bit"))
    }

    @Test("mistral-7b does not match")
    func mistralDoesNotMatch() {
        #expect(!isQwenFamily("mlx-community/mistral-7b-instruct"))
    }

    @Test("empty string does not match")
    func emptyStringDoesNotMatch() {
        #expect(!isQwenFamily(""))
    }
}
