// HTTPClient.swift
// PopGuy — ProviderLayer
//
// Lightweight URLSession wrapper that issues HTTP requests and hands back
// an SSE data-line stream or a plain JSON response body.
//
// URLSession is injected at construction time so adapters are testable
// offline via MockURLProtocol. The default initializer uses the shared
// ephemeral session (no credentials caching, no disk caching).
//
// Sendable: HTTPClient captures an immutable URLSession reference;
// URLSession is Sendable in Swift 6 on Apple platforms.

import Foundation

/// Issues HTTP requests; returns streams or raw data.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target)
// so all network I/O runs on the appropriate executor, not the main thread.
nonisolated struct HTTPClient: Sendable {

    private let session: URLSession

    /// Create a client with an injected session (for testing).
    init(session: URLSession) {
        self.session = session
    }

    /// Convenience: create a client backed by a shared ephemeral session
    /// (no disk caching, no credential storage).
    init() {
        self.session = URLSession(configuration: .ephemeral)
    }

    // MARK: - SSE stream

    /// Begin a streaming request and return an `AsyncThrowingStream` of SSE
    /// data-line payloads.
    ///
    /// - Throws: `ProviderError.httpError` if the HTTP status is not 2xx.
    /// - Returns: Stream emitting each raw data-line payload (JSON strings).
    ///            Each adapter parses its own JSON from these strings.
    func sseStream(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.transport("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Collect the error body for the error message.
            var bodyBytes: [UInt8] = []
            for try await byte in bytes { bodyBytes.append(byte) }
            let bodyString = String(bytes: bodyBytes, encoding: .utf8)
            throw ProviderError.httpError(statusCode: http.statusCode, body: bodyString)
        }

        let decoder = SSEDecoder()
        return decoder.decode(lines: bytes.lines as AsyncLineSequence<URLSession.AsyncBytes>)
    }

    // MARK: - Plain data request

    /// Send a request and return the raw response body as `Data`.
    ///
    /// - Throws: `ProviderError.httpError` on non-2xx.
    func rawData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.transport("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            throw ProviderError.httpError(statusCode: http.statusCode, body: bodyString)
        }
        return data
    }
}
