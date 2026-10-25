// SSEDecoderTests.swift
// PopGuyTests
//
// Feeds canned SSE bytes through SSEDecoder and asserts decoded data lines.
// All delivery is at once (not chunked) — sufficient to verify parsing logic;
// chunked delivery adds flakiness with no added value in offline tests.

import Foundation
import Testing
@testable import PopGuy

// .serialized: all tests in this suite share the same mock host key
// ("mock.example.com") — serialising prevents intra-suite concurrent access
// to the same registry slot.
@Suite("SSEDecoder", .serialized)
struct SSEDecoderTests {

    // Host used by all SSEDecoder tests — distinct from every provider host.
    private static let mockHost = "mock.example.com"

    // MARK: - Helpers

    /// Build a mock URLSession that returns the given body data.
    private func mockSession(statusCode: Int = 200, body: Data) -> URLSession {
        MockURLProtocol.register(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: statusCode), body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func sseData(_ text: String) -> Data {
        Data(text.utf8)
    }

    // MARK: - Tests

    @Test("decodes single data line")
    func decodeSingleDataLine() async throws {
        let raw = "data: hello\n\ndata: [DONE]\n\n"
        let session = mockSession(body: sseData(raw))
        let client = HTTPClient(session: session)

        var lines: [String] = []
        let stream = try await client.sseStream(for: makeRequest())
        for try await line in stream { lines.append(line) }

        #expect(lines == ["hello"])
    }

    @Test("decodes multiple data lines")
    func decodeMultipleDataLines() async throws {
        let raw = "data: token1\n\ndata: token2\n\ndata: token3\n\ndata: [DONE]\n\n"
        let session = mockSession(body: sseData(raw))
        let client = HTTPClient(session: session)

        var lines: [String] = []
        let stream = try await client.sseStream(for: makeRequest())
        for try await line in stream { lines.append(line) }

        #expect(lines == ["token1", "token2", "token3"])
    }

    @Test("[DONE] sentinel is not emitted as a data line")
    func doneNotEmitted() async throws {
        let raw = "data: only\n\ndata: [DONE]\n\n"
        let session = mockSession(body: sseData(raw))
        let client = HTTPClient(session: session)

        var lines: [String] = []
        let stream = try await client.sseStream(for: makeRequest())
        for try await line in stream { lines.append(line) }

        #expect(!lines.contains("[DONE]"))
        #expect(lines.count == 1)
    }

    @Test("lines without 'data:' prefix are skipped")
    func nonDataLinesSkipped() async throws {
        // event: and id: lines should not be emitted
        let raw = "event: message_start\nid: 1\ndata: payload\n\ndata: [DONE]\n\n"
        let session = mockSession(body: sseData(raw))
        let client = HTTPClient(session: session)

        var lines: [String] = []
        let stream = try await client.sseStream(for: makeRequest())
        for try await line in stream { lines.append(line) }

        #expect(lines == ["payload"])
    }

    @Test("HTTP 4xx throws httpError")
    func http4xxThrows() async throws {
        let raw = "{\"error\":\"unauthorized\"}"
        let session = mockSession(statusCode: 401, body: Data(raw.utf8))
        let client = HTTPClient(session: session)

        var threw = false
        do {
            _ = try await client.sseStream(for: makeRequest())
        } catch let err as ProviderError {
            if case .httpError(let code, _) = err, code == 401 { threw = true }
        }
        #expect(threw)
    }

    @Test("empty stream (only [DONE]) emits no lines")
    func emptyStream() async throws {
        let raw = "data: [DONE]\n\n"
        let session = mockSession(body: sseData(raw))
        let client = HTTPClient(session: session)

        var lines: [String] = []
        let stream = try await client.sseStream(for: makeRequest())
        for try await line in stream { lines.append(line) }

        #expect(lines.isEmpty)
    }

    @Test("Anthropic message_stop line terminates stream")
    func anthropicMessageStopTerminates() async throws {
        // Anthropic doesn't send [DONE]; it sends event: message_stop.
        // The SSEDecoder itself is neutral — it passes all data: lines through.
        // The AnthropicProvider stops on message_stop, but SSEDecoder just streams.
        // Here we verify the data lines BEFORE message_stop are all emitted.
        let raw = """
        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let session = mockSession(body: sseData(raw))
        let client = HTTPClient(session: session)

        var lines: [String] = []
        let stream = try await client.sseStream(for: makeRequest())
        for try await line in stream { lines.append(line) }

        // Two data lines emitted (decoder doesn't interpret content)
        #expect(lines.count == 2)
        #expect(lines[0].contains("content_block_delta"))
    }

    // FIX 2: SSE data: field without a leading space (no-space form per SSE spec).
    @Test("data: line without space after colon is decoded correctly")
    func dataLineNoSpace() async throws {
        // SSE spec allows both "data: <payload>" and "data:<payload>" (no space).
        // The no-space form must produce the same payload as the space form.
        let raw = "data:{\"token\":\"hello\"}\n\ndata: [DONE]\n\n"
        let session = mockSession(body: sseData(raw))
        let client = HTTPClient(session: session)

        var lines: [String] = []
        let stream = try await client.sseStream(for: makeRequest())
        for try await line in stream { lines.append(line) }

        #expect(lines == ["{\"token\":\"hello\"}"])
    }

    // MARK: - Helpers

    private func makeRequest() -> URLRequest {
        URLRequest(url: URL(string: "https://\(Self.mockHost)/stream")!)
    }
}
